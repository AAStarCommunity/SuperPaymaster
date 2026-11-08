"""DSR part 2: a single scoped producer double, with original-value control."""
import ast
import copy
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'a3a'))
import a3a_exec as a
from gate_assertions import assert_stop

GATE = 'rpc_result_scheduled_eta_data'


def schedule_fixture():
    """Offline boundary data; no production functions replaced during setup."""
    tl, capped, op = '0x'+'12'*20, '0x'+'34'*20, '0x'+'56'*32
    h, bh, number, delay, timestamp = '0x'+'78'*32, '0x'+'90'*32, '0x2', 172800, 1000
    tx = dict(to=tl, nonce='0x0', value='0x0', chainId='0x1',
              maxFeePerGas='0x1', maxPriorityFeePerGas='0x1', data='0x1234')
    tx['from'] = '0x'+'ab'*20
    mined = dict(tx, hash=h, blockHash=bh, blockNumber=number, type='0x2', input=tx['data'])
    log = dict(address=tl, transactionHash=h, blockHash=bh, blockNumber=number,
               topics=[a.keccak('CallScheduled(bytes32,uint256,address,uint256,bytes,bytes32,uint256)'), op, a.ZERO32],
               data=a.cast('abi-encode', 'c(address,uint256,bytes,bytes32,uint256)',
                           capped, 0, a.calldata('acceptOwnership()'), a.ZERO32, delay))
    receipt = dict(transactionHash=h, blockHash=bh, blockNumber=number, status='0x1', logs=[log])
    block = dict(hash=bh, number=number, timestamp=hex(timestamp), transactions=[mined])
    plan = dict(pin=dict(timelock=tl, capped=capped, block='0x1'), operationId=op,
                steps=[{} for _ in range(5)]+[dict(tx=tx)])
    queries = {
        a.calldata('getMinDelay()'): delay,
        a.calldata('getTimestamp(bytes32)', op): timestamp+delay,
    }
    def remote(method, params):
        if method == 'eth_call':
            assert params[0]['to'] == tl
            return '0x'+format(queries[params[0]['data']], '064x')
        values = {'eth_getLogs': [log], 'eth_getTransactionByHash': mined,
                  'eth_getTransactionReceipt': receipt, 'eth_getBlockByNumber': block}
        return copy.deepcopy(values[method])
    return remote, plan, timestamp+delay


def prove_schedule_flow():
    tree = ast.parse(Path(a.__file__).read_text())
    fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'scheduled_eta')
    stores = [n for n in ast.walk(fn) if isinstance(n, ast.Name) and n.id == 'log' and isinstance(n.ctx, ast.Store)]
    assert len(stores) == 1
    assignment = next(n for n in fn.body if isinstance(n, ast.Assign) and stores[0] in list(ast.walk(n)))
    assert ast.unparse(assignment.targets[0]) == '(r, log, block)'
    assert ast.unparse(assignment.value) == 'find_step_schedule(remote, plan, 5, with_block=True)'
    targets = [n for n in ast.walk(fn) if isinstance(n, ast.Call)
               and any(k.arg == 'gate' and isinstance(k.value, ast.Constant) and k.value.value == GATE for k in n.keywords)]
    assert len(targets) == 1
    assert ast.unparse(targets[0].args[0]) == "log['data']"
    outer = next(n for n in ast.walk(fn) if isinstance(n, ast.Call)
                 and ast.unparse(n.func) == 'need' and n.args
                 and isinstance(n.args[0], ast.Constant) and n.args[0].value == 'schedule_log_data')
    assert targets[0] in list(ast.walk(outer.args[1]))
    # No mutation, alias escape, or other consumer of log before the target.
    intervening = [n for n in fn.body if assignment.lineno < n.lineno < targets[0].lineno]
    log_uses = [n for stmt in intervening for n in ast.walk(stmt) if isinstance(n, ast.Name) and n.id == 'log']
    assert len(log_uses) == 3
    assert [ast.unparse(n) for n in intervening[:3]] == [
        "need('schedule_log_removed', log.get('removed', False), False)",
        "need('schedule_log_topics', log['topics'], [topic, op, ZERO32])",
        "need('schedule_log_address', log['address'].lower(), tl)"]
    return targets[0]


def prove_compile_flow():
    tree = ast.parse(Path(a.__file__).read_text())
    fn = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'rebuild_artifacts')
    assignments = [n for n in ast.walk(fn) if isinstance(n, ast.Assign)]
    for name, expected in (
        ('rebuilt', 'rebuilt, config = compile_commit(commit, version.stdout)'),
        ('fresh', 'current, fresh = (artifacts[name], rebuilt[name])'),
    ):
        writes = [n for n in ast.walk(fn) if isinstance(n, ast.Name)
                  and n.id == name and isinstance(n.ctx, ast.Store)]
        assert len(writes) == 1
        assignment = next(n for n in assignments if writes[0] in list(ast.walk(n)))
        assert ast.dump(assignment) == ast.dump(ast.parse(expected).body[0])
    targets = [n for n in ast.walk(fn) if isinstance(n, ast.Call)
               and any(k.arg == 'gate' and isinstance(k.value, ast.Constant)
                       and k.value.value == 'rpc_result_rebuild_artifacts_object_2' for k in n.keywords)]
    assert len(targets) == 1
    target = targets[0]
    assert ast.unparse(target.args[0]) == "fresh[field]['object']"
    # Only the unpacked producer return and the indexed fresh assignment use
    # rebuilt; fresh is neither passed to another call nor mutated before T.
    assert len([n for n in ast.walk(fn) if isinstance(n, ast.Name) and n.id == 'rebuilt']) == 2
    uses = [n for n in ast.walk(fn) if isinstance(n, ast.Name) and n.id == 'fresh'
            and n.lineno <= target.lineno]
    assert len(uses) == 2
    return target


class ProducerTests(unittest.TestCase):
    def test_flow(self):
        prove_schedule_flow()

    def test_compile_flow(self):
        prove_compile_flow()

    def exercise(self, malformed, expected=GATE):
        chain, plan, eta = schedule_fixture()
        original = a.find_step_schedule
        real = original(chain, plan, 5, with_block=True)
        value = copy.deepcopy(real)
        if malformed:
            # bytes.fromhex-compatible, but violates the required 0x wire prefix.
            value[1]['data'] = value[1]['data'][2:]
        with patch.object(a, 'find_step_schedule', return_value=value) as double:
            if malformed:
                with assert_stop(self, expected):
                    a.scheduled_eta(chain, plan)
            else:
                self.assertEqual(a.scheduled_eta(chain, plan), eta)
            double.assert_called_once_with(chain, plan, 5, with_block=True)
        self.assertIs(a.find_step_schedule, original)

    def test_real_return(self):
        self.exercise(False)

    def test_malformed_return(self):
        self.exercise(True)

    def test_original_restored(self):
        original = a.find_step_schedule
        self.exercise(False)
        self.exercise(True)
        self.assertIs(a.find_step_schedule, original)

    def probe_shadow_e(self):
        # Invoked explicitly by the probe driver, not included in the green suite.
        # This records whether the proposed E actually precedes T for this input.
        self.exercise(True, 'schedule_log_data')


class CompileProducerTests(unittest.TestCase):
    GATE = 'rpc_result_rebuild_artifacts_object_2'

    def exercise(self, malformed):
        # Exact return captured from the undoubled offline compile_commit at
        # the pinned commit. No compiler/artifact validation is stubbed here.
        capture = json.loads((Path(__file__).parent/'fixtures/gate-producer-compile.json').read_text())
        real = tuple(capture['returned'])
        value = copy.deepcopy(real)
        if malformed:
            # Keep the decoded bytes intact when T is deleted, avoiding a
            # parser ERROR or a change to the subsequent equality check.
            name = a.CONTRACT_NAMES[0]
            value[0][name]['bytecode']['object'] = 'zz'+value[0][name]['bytecode']['object'][2:]
        original = a.compile_commit
        with patch.object(a, 'compile_commit', return_value=value) as double:
            if malformed:
                with assert_stop(self, self.GATE):
                    a.rebuild_artifacts(copy.deepcopy(real[0]), capture['commit'])
            else:
                result = a.rebuild_artifacts(copy.deepcopy(real[0]), capture['commit'])
                self.assertEqual(result['commit'], capture['commit'])
                self.assertEqual(result['forgeVersion'].splitlines()[0], capture['forgeVersion'])
            self.assertEqual(double.call_count, 1)
            self.assertEqual(double.call_args.args[0], capture['commit'])
        self.assertIs(a.compile_commit, original)

    def test_real_return(self):
        self.exercise(False)

    def test_malformed_return(self):
        self.exercise(True)

    def test_original_restored(self):
        original = a.compile_commit
        self.exercise(False)
        self.exercise(True)
        self.assertIs(a.compile_commit, original)


def load_tests(loader, tests, pattern):
    suite = unittest.TestSuite(ProducerTests(name) for name in
        ('test_flow', 'test_compile_flow', 'test_real_return', 'test_malformed_return', 'test_original_restored'))
    suite.addTests(loader.loadTestsFromTestCase(CompileProducerTests))
    return suite


if __name__ == '__main__':
    unittest.main()
