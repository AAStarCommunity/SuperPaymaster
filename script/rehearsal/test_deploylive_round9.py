import deploylive_controls as controls
import json
import os
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch, Mock
import creation_pins as pins
import deploylive_fork_deploy as fork
import deploylive_rehearse as rehearsal
import deploylive_runtime as runtime
import deploylive_deploy_day as day

ROOT = rehearsal.ROOT
OUTPUT = ROOT/'cache/deploylive-tests/round9'
# Fresh checkouts have no cache/ tree; the tests must not depend on an earlier run creating it.
OUTPUT.mkdir(parents=True, exist_ok=True)

class Round9Test(unittest.TestCase):
    def test_artifacts_check_does_not_build(self):
        with tempfile.TemporaryDirectory(dir=OUTPUT) as tmp:
            file = Path(tmp)/'pins.json'
            file.write_text('{}')
            with patch.object(sys, 'argv', ['pins', '--check', str(file), '--artifacts', tmp]), patch.object(pins, 'clean_build_pins', side_effect=AssertionError('must not build')), patch.object(pins, 'artifact_pins', return_value={}) as read:
                pins.main()
                read.assert_called_once_with(Path(tmp))

    def test_creation_rejects_via_ir_false(self):
        with tempfile.TemporaryDirectory(dir=OUTPUT) as tmp:
            obj = dict(metadata=dict(settings=dict(optimizer=dict(runs=500), evmVersion='cancun', viaIR=False, compilationTarget={'C.sol':'C'})), bytecode=dict(object='0xaa'))
            (Path(tmp)/'C.json').write_text(json.dumps(obj))
            with self.assertRaises(ValueError):
                pins.creation_bytes(tmp, 'C', 500)

    def test_runtime_uses_environment_directory(self):
        with patch.dict(os.environ, DEFAULT_ARTIFACTS_OUT='cache/deploylive-tests/round9/missing'):
            with self.assertRaises(ValueError):
                runtime.artifact('Registry', json.loads((ROOT/'deployments/creation-pins.10.json').read_text())['Registry'], lambda *a: (0, json.loads((ROOT/'deployments/creation-pins.10.json').read_text())['Registry']))

    def run_fork(self, chain, extra=()):
        rpc = Mock(side_effect=lambda method, *a: hex(chain) if method == 'eth_chainId' else None)
        env = {'FOUNDRY_VERBOSITY':'2', 'ENV':'round9', 'DEPLOYLIVE_EVIDENCE_DIR':str(OUTPUT),
               'DEPLOYLIVE_SOURCE_RPC':'source', 'DEPLOYLIVE_SECOND_RPC':'second',
               'DEPLOYLIVE_HARDFORK':'prague', 'GOVERNANCE_OWNER':'safe', 'DEPLOYLIVE_EXPECTED_CHAIN_ID':str(chain)}
        second = OUTPUT/'second-rpc'
        second.write_text('https://secondary.infura.io/key')
        env.update(DEPLOYLIVE_RPC='https://primary.alchemy.com/key', DEPLOYLIVE_SECOND_RPC=second.read_text(),
                   DEPLOYLIVE_SECOND_RPC_FILE=str(second), DEPLOYLIVE_ENDPOINT_PROVIDER='Alchemy',
                   DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER='Infura')
        stamp = OUTPUT/'out.build-stamp.json'
        stamp.write_text('{"forge":{}}')
        (OUTPUT/'pop-request.json').write_text('{"pin":{"senders":{"deployer":{"nonce":0}}}}')
        (OUTPUT/'guardians.hex').write_text('0x')
        def invoke(command, **kwargs):
            if 'script' in command:
                plan = OUTPUT/f'broadcast/DeployLive.s.sol/{chain}/dry-run/run-latest.json'
                plan.parent.mkdir(parents=True, exist_ok=True)
                transactions = [dict(transactionType='CREATE', contractName=name, transaction=dict(nonce=hex(i), to=None, input='0x00', value='0x0', **{'from':'deployer', 'chainId':hex(chain), 'gas':'0x100'})) for i, name in enumerate(('Registry', 'TimelockHandoverBootstrap'))]
                if kwargs['env']['DEPLOYLIVE_STOP_BEFORE_BOOTSTRAP'] == '1': transactions = transactions[:-1]
                plan.write_text(json.dumps(dict(transactions=transactions)))
                (plan.parent.parent/'run-latest.json').write_text(plan.read_text())
            if any('postdeploy_check' in str(part) for part in command):
                # Like the real checker, write readback into the directory the driver hands it.
                directory = Path(kwargs['env']['DEPLOYLIVE_EVIDENCE_DIR']); directory.mkdir(parents=True, exist_ok=True)
                (directory/'readback.json').write_text('{}')
            return SimpleNamespace(returncode=0, stdout='forge stdout', stderr='forge stderr')
        with patch.object(controls,'verify_manifest'), patch.object(controls,'verify_conversion',return_value='0x'), patch.object(controls,'deployment_rule'), patch.object(controls,'check_start_nonce'), patch.object(controls,'write_success'), patch.object(fork, 'clean_source_commit', return_value='a' * 40), patch.object(sys, 'argv', ['fork', env['DEPLOYLIVE_RPC'], 'deployer', *extra]), patch.dict(os.environ, env), patch.object(fork, 'RPC', return_value=rpc), patch.object(fork.subprocess, 'run', side_effect=invoke) as run, patch.object(fork, 'ROOT', OUTPUT), patch.object(fork, 'build', side_effect=lambda e, p: day.build_paths(e)), patch.object(fork, 'verify_build', return_value='forge'), patch.object(fork, 'ReadOnlyRPC', return_value=lambda *a: hex(10 if chain == 31337 else chain)), patch.object(fork, 'broadcast_gates', return_value=[[256,256],[256,256]]), patch.object(fork, 'checker_pass'), patch.object(day, 'stamp_path', return_value=stamp):
            fork.main()
        return rpc, run

    def test_happy_chain10_clears_delegation_and_logs(self):
        rpc, run = self.run_fork(10)
        self.assertEqual(run.call_args.kwargs['env']['SP_COMMIT'], 'a' * 40)
        rpc.assert_any_call('anvil_setCode', 'deployer', '0x')
        self.assertEqual((OUTPUT/'forge.stdout.log').read_text(), 'forge stdout')
        self.assertEqual((OUTPUT/'forge.stderr.log').read_text(), 'forge stderr')

    def test_execution_output_cannot_overwrite_release(self):
        with patch.dict(os.environ, FOUNDRY_OUT='out', DEFAULT_ARTIFACTS_OUT='out'):
            with self.assertRaises(RuntimeError):
                self.run_fork(31337)

    def test_driver_failure_chain10_refused_before_deployment(self):
        with patch.object(controls,'verify_manifest'), patch.object(controls,'verify_conversion',return_value='0x'), patch.object(controls,'deployment_rule'), patch.object(controls,'check_start_nonce'), patch.object(controls,'write_success'), patch.object(fork, 'clean_source_commit', return_value='a' * 40), patch.object(sys, 'argv', ['driver', 'failure', 'http://127.0.0.1:1', str(OUTPUT/'config.json'), 'deployer', 'safe']), patch.dict(os.environ, FOUNDRY_VERBOSITY='2', DEPLOYLIVE_EVIDENCE_DIR=str(OUTPUT), REHEARSAL_BLS_SCALARS='[]', REHEARSAL_SOURCE_RPC='https://unused.invalid/unused'), patch.object(rehearsal, 'clean_source_commit', return_value='a' * 40), patch.object(rehearsal, 'RPC', return_value=lambda *a: '0xa'), patch.object(rehearsal.subprocess, 'run', return_value=SimpleNamespace(returncode=1)) as run, patch.object(rehearsal, 'scan_evidence'):
            with self.assertRaisesRegex(RuntimeError, '31337'):
                rehearsal.main()
            run.assert_not_called()

    def test_failure_chain10_refused(self):
        with self.assertRaises(RuntimeError):
            self.run_fork(10, ['--stop'])

    def test_failure_31337(self):
        rpc, run = self.run_fork(31337, ['--stop'])
        self.assertEqual(run.call_args.kwargs['env']['DEPLOYLIVE_STOP_BEFORE_BOOTSTRAP'], '1')

    def test_unknown_argument_refused(self):
        with self.assertRaises(RuntimeError):
            self.run_fork(31337, ['--unknown'])

    def test_external_evidence_scan(self):
        # Simulate an external location without accessing anything outside this worktree.
        with tempfile.TemporaryDirectory(dir=OUTPUT) as tmp:
            with patch.object(Path, 'is_relative_to', return_value=False):
                rehearsal.scan_evidence(tmp, 'https://source.invalid/token', [123456789])


class ScanFragmentTests(unittest.TestCase):
    def test_short_path_segment_is_not_a_needle_but_a_long_one_is(self):
        with tempfile.TemporaryDirectory(dir=OUTPUT) as tmp:
            (Path(tmp)/'forge.stdout.log').write_text('compiling v2 artifacts\n')
            rehearsal.scan_evidence(tmp, 'https://rpc.provider.example/v2/abcdef123456', [123456789])
            (Path(tmp)/'leak.log').write_text('key abcdef123456 leaked\n')
            with self.assertRaises(BaseException):
                rehearsal.scan_evidence(tmp, 'https://rpc.provider.example/v2/abcdef123456', [123456789])
