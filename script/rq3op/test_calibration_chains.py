import ast
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import calibrate as c
import derive_inputs as d
import tpm_gas_probe as probe


FIXTURES = Path(__file__).parent/'fixtures'
KEYS_FILE = FIXTURES/'deploylive-config-keys.op-sepolia.json'
SOURCE_SHA256 = 'fff5d2395a2b7e9e43dd00509f6e52aa2e2849537f571a677303e4cdb2176f94'


def full_deploylive_config():
    keys = json.loads(KEYS_FILE.read_text())['keys']
    attempt = json.loads((FIXTURES/'attempt1.config.sepolia.json').read_text())
    # Types follow DeployLive's serialization; key membership comes only from the manifest.
    integers = set(('defaultThreshold deployerCodeLength deployerGTokenAllowance '
        'deployerGTokenBalance deployerSBTBalance deploymentStartBlock gTokenMintCount '
        'guardianN handoverBootstrapNonce minThreshold observedBootstrapNonce '
        'slashThreshold0 slashThreshold1 slashThreshold2 treasuryGTokenBefore').split())
    arrays = set(('gTokenMintAmounts gTokenMintRecipients guardians stakeAccounts '
        'stakeAmounts stakeRoles ticketAmounts ticketTreasuries').split())
    strings = dict.fromkeys(('deployerGTokenTransferred deployerRemainderToRecipient '
        'expectedCap gTokenTotalSupply ticketsToTreasury').split(), '0')
    strings.update(artifactDirectory='fixture-artifacts', executionEvmVersion='cancun',
        commit='0'*40, creationPinsSha256='0'*64, srcHash='0'*64,
        handoverCreationCode='0x', updateTime='1970-01-01T00:00:00Z')
    def placeholder(key):
        if key in integers:
            return 0
        if key in arrays:
            return []
        if key in ('enableAgentRegistries', 'genesisIsConfigured'):
            return False
        if key == 'artifactCompileSettings':
            return {}
        return strings.get(key, '0x' + '0'*40)
    return {key: attempt[key] if key in attempt else placeholder(key) for key in keys}


def postop_floor_spans(text):
    """Spans of sp_postop_limit and the one SP postOp rule= literal. Nothing else."""
    lines = text.splitlines(keepends=True)
    offsets, pos = [], 0
    for line in lines:
        offsets.append(pos)
        pos += len(line)
    fns = [node for node in ast.parse(text).body
           if isinstance(node, ast.FunctionDef) and node.name == 'sp_postop_limit']
    if len(fns) != 1:
        raise AssertionError('sp_postop_limit')
    fn = fns[0]
    fn_span = (offsets[fn.lineno - 1], offsets[fn.end_lineno] if fn.end_lineno < len(offsets) else len(text))
    hits = [i for i, line in enumerate(lines) if "sources['SP']['postOp'].update(" in line]
    if len(hits) != 1:
        raise AssertionError("sources['SP']['postOp'].update")
    found = list(re.finditer(r"rule='[^']*'", lines[hits[0]]))
    if len(found) != 1:
        raise AssertionError('rule=')
    rule = found[0]
    rule_span = (offsets[hits[0]] + rule.start(), offsets[hits[0]] + rule.end())
    if not (fn_span[1] <= rule_span[0] or rule_span[1] <= fn_span[0]):
        raise AssertionError('rule overlaps sp_postop_limit')
    return fn_span, rule_span


def rewind_postop_floor(current, baseline):
    """Swap those two spans for the 99a38d8d text. Any other byte stays put."""
    current_text, baseline_text = current.decode(), baseline.decode()
    pairs = zip(postop_floor_spans(current_text), postop_floor_spans(baseline_text))
    out = current_text
    for (start, end), (old_start, old_end) in sorted(pairs, key=lambda item: item[0][0], reverse=True):
        out = out[:start] + baseline_text[old_start:old_end] + out[end:]
    return out.encode()


class DeployLiveConfigKeys(unittest.TestCase):
    def test_manifest_shape_and_provenance(self):
        record = json.loads(KEYS_FILE.read_text())
        self.assertEqual(set(record), {'schema', 'sourceSha256', 'keys'})
        self.assertEqual(record['schema'], 'deploylive-config-keys/1')
        self.assertEqual(record['sourceSha256'], SOURCE_SHA256)
        self.assertEqual(len(record['keys']), 92)
        self.assertTrue(all(isinstance(key, str) for key in record['keys']))
        self.assertEqual(record['keys'], sorted(set(record['keys'])))
        self.assertNotIn('chainId', record['keys'])

    def test_generator_round_trip_and_exact_byte_digest(self):
        keys = json.loads(KEYS_FILE.read_text())['keys']
        with tempfile.TemporaryDirectory() as tmp:
            source, out = Path(tmp)/'config.json', Path(tmp)/'keys.json'
            raw = json.dumps(dict.fromkeys(reversed(keys), 'VALUE_MUST_NOT_LEAK'), indent=3).encode() + b'\n'
            source.write_bytes(raw)
            subprocess.run([sys.executable, '-B', str(FIXTURES/'gen_config_keys.py'), str(source), str(out)], check=True)
            self.assertEqual(json.loads(out.read_text()), dict(schema='deploylive-config-keys/1',
                sourceSha256=hashlib.sha256(raw).hexdigest(), keys=keys))
            self.assertNotIn('VALUE_MUST_NOT_LEAK', out.read_text())

    def test_sanitized_fixture_is_subset(self):
        keys = json.loads(KEYS_FILE.read_text())['keys']
        attempt = json.loads((FIXTURES/'attempt1.config.sepolia.json').read_text())
        self.assertLessEqual(set(attempt), set(keys))
        self.assertEqual(set(full_deploylive_config()), set(keys))


class CalibrationChains(unittest.TestCase):
    def test_fork_parameters(self):
        for chain, hardfork, flags in [(11155111, 'amsterdam', []), (11155420, 'op:karst', ['--optimism'])]:
            self.assertEqual(c.fork_parameters(chain), dict(hardfork=hardfork, flags=flags))
        with self.assertRaisesRegex(SystemExit, 'STOP'):
            c.fork_parameters(31337)

    def test_start_uses_chain_parameters_without_launching_anvil(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            (path/'upstream').write_text('unused-test-upstream')
            for chain in (11155111, 11155420):
                fork = c.Fork(18555)
                with patch.object(c.subprocess, 'Popen') as popen, patch.object(c.threading, 'Thread'), patch.object(c, 'choose_port', return_value=18555), patch.object(c.Fork, '__call__', side_effect=lambda method, params: {'eth_chainId': hex(chain), 'web3_clientVersion': 'anvil/v1', 'anvil_nodeInfo': {'forkConfig': {'forkBlockNumber': 123}}}[method]):
                    popen.return_value.poll.return_value = None
                    fork.start(path/'upstream', 123, path/'log', chain)
                    argv = popen.call_args.args[0]
                    self.assertEqual(argv[argv.index('--chain-id') + 1], str(chain))
                    self.assertEqual(argv[argv.index('--hardfork') + 1], c.fork_parameters(chain)['hardfork'])
                    self.assertEqual('--optimism' in argv, chain == 11155420)
            with patch.object(c.subprocess, 'Popen') as popen:
                with self.assertRaisesRegex(SystemExit, 'STOP'):
                    c.Fork(18555).start(path/'missing', 123, path/'log', 31337)
                popen.assert_not_called()

    def test_derive_chain_guard(self):
        for chain in (11155111, 11155420):
            d.validate_chain(chain, chain)
        for cfg, pin in [(31337, 31337), (11155111, 11155420)]:
            with self.assertRaisesRegex(SystemExit, 'STOP'):
                d.validate_chain(cfg, pin)

    def test_probe_defaults_and_override_refusal(self):
        for chain in (11155111, 11155420):
            self.assertEqual(probe.case_parameters({}, chain), c.fork_parameters(chain))
        for case in ({'flags': ['--chain-id', '31337']}, {'hardfork': 'amsterdam'}):
            with self.assertRaisesRegex(SystemExit, 'STOP'):
                probe.case_parameters(case, 11155420)

    def test_provisional_identity(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)
            for chain in (11155111, 11155420):
                raw = json.dumps(dict(superPaymaster='0x123', commit='abc')).encode()
                (p/'config').write_bytes(raw)
                args = SimpleNamespace(chain=chain, config=p/'config', pin=123, pin_hash='0xabc', evidence=p/'evidence', out=p/'cal', evidence_rel='evidence')
                with patch('builtins.print'):
                    c.cmd_provisional(args)
                evidence = json.loads((p/'evidence').read_text())
                self.assertEqual(evidence['chainId'], chain)
                self.assertIn(str(chain), evidence['label'])
                self.assertIn(hashlib.sha256(raw).hexdigest(), evidence['label'])
                self.assertEqual(evidence['fork'], c.fork_parameters(chain))

    def test_deployment_planner_unchanged(self):
        root = Path(__file__).resolve().parents[2]
        # The session driver is not a deploy-commit setup module: it imports the 99a38d8d setup.mjs by path
        # and checks its blob. Only these two files are excluded, and they must not exist at 99a38d8d.
        driver = ('script/rq3op/setup-session.mjs', 'script/rq3op/setup-session.test.mjs')
        for path in driver:
            absent = subprocess.run(['git', 'cat-file', '-e', f'99a38d8d:{path}'], cwd=root, capture_output=True)
            self.assertNotEqual(absent.returncode, 0, path + ' exists at 99a38d8d')
        for path in ('script/upgrade/manifest_exec.py',
                     *(str(p.relative_to(root)) for p in sorted((root/'script/rq3op').glob('setup*.mjs'))
                       if str(p.relative_to(root)) not in driver)):
            baseline = subprocess.check_output(['git', 'show', f'99a38d8d:{path}'], cwd=root)
            self.assertEqual((root/path).read_bytes(), baseline, path)
        # DSR: plan_three_arm.py may differ from 99a38d8d only in the postOp floor rule.
        plan = 'script/rq3op/plan_three_arm.py'
        baseline = subprocess.check_output(['git', 'show', f'99a38d8d:{plan}'], cwd=root)
        current = (root/plan).read_bytes()
        self.assertEqual(rewind_postop_floor(current, baseline), baseline, plan)
        # A mutation inside sp_postop_limit itself is invisible to the swap-back above, so pin
        # the exact bytes of the current planner as well.
        self.assertEqual(hashlib.sha256(current).hexdigest(),
            '892c4738dc856834fd2749dfd23c610c6f52d46a0a0ac3fabe301d39e9bfd719', plan)
        text = current.decode()
        needle = 'def check_inputs('
        begin = text.index(needle)
        for span in postop_floor_spans(text):
            self.assertTrue(begin + len(needle) <= span[0] or begin >= span[1])
        mutated = current.replace(needle.encode(), b'def check_inputs( ', 1)
        self.assertNotEqual(rewind_postop_floor(mutated, baseline), baseline)


class ExplicitCalibrationChain(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.p = Path(self.tmp.name)
        self.cfg = full_deploylive_config()
        raw = json.dumps(self.cfg, indent=2).encode()
        self.assertNotIn('chainId', self.cfg)
        (self.p/'config').write_bytes(raw)
        for name in ('inputs', 'calibration', 'checker_record', 'principals'):
            (self.p/name).write_text('{}')
        (self.p/'upstream').write_text('unused-test-upstream')
        self.args = SimpleNamespace(chain=11155420, config=self.p/'config', pin=123, pin_hash='0xabc',
            evidence=self.p/'evidence', out=self.p/'cal', evidence_rel='evidence', planner_root='unused',
            rpc_a_file=self.p/'upstream', upstream_file=self.p/'upstream', port=18555,
            inputs=self.p/'inputs', calibration=self.p/'calibration', checker_record=self.p/'checker_record',
            out_dir=self.p, mode='measure', rounds=2, extra_task_recipient=None,
            measurements=self.p/'measurements.measure.json', evidence_prefix='evidence')

    def assert_identity(self, record):
        self.assertIn('11155420', record['label'])
        self.assertIn(hashlib.sha256((self.p/'config').read_bytes()).hexdigest(), record['label'])

    def test_provisional_without_config_chain(self):
        with patch('builtins.print'):
            c.cmd_provisional(self.args)
        record = json.loads(self.args.evidence.read_text())
        self.assert_identity(record)
        self.assertEqual(record['chainId'], self.args.chain)

    def test_checker_without_config_chain(self):
        from unittest.mock import MagicMock
        q = MagicMock()
        q.run_checker.return_value = dict(summary='ok', snapshotBlockHash='0xabc')
        with patch.object(c, 'load_planner', return_value=(q, None, None)), patch('builtins.print'):
            c.cmd_checker(self.args)
        self.assertEqual(q.run_checker.call_args.args[3], self.args.chain)

    def test_plan_without_config_chain(self):
        from unittest.mock import MagicMock
        q = MagicMock()
        q.build.return_value = dict(plans={})
        with patch.object(c, 'load_planner', return_value=(q, None, None)):
            runner = c.Runner(self.args)
            runner.plan(self.cfg, {}, {}, dict(summary='ok'))
        self.assertEqual(q.verify_calibration.call_args.args[2], self.args.chain)

    def test_prepare_and_refresh_without_config_chain(self):
        from unittest.mock import MagicMock
        q = MagicMock()
        self.args.fund_wei = 10**18
        with patch.object(c, 'load_planner', return_value=(q, None, None)), \
             patch.object(c.Runner, 'rpc') as rpc, patch.object(c.Runner, 'send', return_value=({}, None)) as send, \
             patch.object(c.Runner, 'safe_owners', return_value=[self.cfg['governanceOwner']]):
            runner = c.Runner(self.args)
            runner.prepare(self.cfg, dict(experiment=self.cfg['deployer'],
                genesis=self.cfg['genesisOperator'], stakeWei=1))
        self.assertEqual(send.call_args.args[0]['to'], self.cfg['superPaymaster'])
        self.assertTrue(rpc.called)

    def test_run_without_config_chain(self):
        from unittest.mock import MagicMock
        q = MagicMock()
        q.a.qty.side_effect = lambda x: int(x, 16)
        head = dict(number='0x7b', hash='0xabc')
        q.a.block_data.return_value = head
        bundle = dict(safeTransactions=[], plans={'0': dict(taskRecipients=['unused'],
            steps=[dict(id='C9.mode')], planIndex=0, phaseC=dict(gasTuple=[1]))})
        (self.p/'inputs').write_text('{"gasFactor": [3, 2]}')
        (self.p/'ops.measure.json').write_text('{}')
        with patch.object(c, 'load_planner', return_value=(q, None, None)), patch.object(c, 'Fork') as fork, \
             patch.object(c.Runner, 'prepare'), patch.object(c.Runner, 'refresh_price'), \
             patch.object(c.Runner, 'plan', return_value=(json.dumps(bundle).encode(), head)), \
             patch.object(c.Runner, 'run_steps', return_value=[]), patch.object(c.subprocess, 'run') as run, \
             patch('builtins.print'):
            fork.return_value.anvil = 'mock-anvil'
            fork.return_value.proc.pid = 123
            fork.return_value.url = 'http://127.0.0.1:18555'
            q.m.sp_attempt_precheck.return_value = True
            q.pre_send.return_value = True
            run.return_value = SimpleNamespace(returncode=0, stdout='', stderr='')
            c.cmd_run(self.args)
            self.assertEqual(fork.return_value.start.call_args.args[-1], self.args.chain)
            fork.return_value.stop.assert_called_once()
        record = json.loads(self.args.measurements.read_text())
        self.assert_identity(record)
        self.assertEqual(record['pin']['chainId'], self.args.chain)
        self.assert_identity(json.loads((self.p/'fork-transactions.measure.json').read_text()))

    def test_run_verify_mode_stops_on_failed_op_row(self):
        from unittest.mock import MagicMock
        q = MagicMock()
        q.a.qty.side_effect = lambda x: int(x, 16)
        head = dict(number='0x7b', hash='0xabc')
        q.a.block_data.return_value = head
        bundle = dict(safeTransactions=[], plans={'0': dict(taskRecipients=['unused'],
            steps=[dict(id='C9.mode')], planIndex=0, phaseC=dict(gasTuple=[1]))})
        (self.p/'inputs').write_text('{"gasFactor": [3, 2]}')
        bad = dict(sender='0x1', arm='SP', round=0, nonce='0', verdict='TX_FAILED',
                   tx=dict(hash='0xtx', status='0x0'), uoe=None)
        (self.p/'ops.verify.json').write_text(json.dumps({'ops': [bad]}))
        self.args.mode = 'verify'
        with patch.object(c, 'load_planner', return_value=(q, None, None)), patch.object(c, 'Fork') as fork, \
             patch.object(c.Runner, 'prepare'), patch.object(c.Runner, 'refresh_price'), \
             patch.object(c.Runner, 'plan', return_value=(json.dumps(bundle).encode(), head)), \
             patch.object(c.Runner, 'run_steps', return_value=[]), patch.object(c.subprocess, 'run') as run, \
             patch('builtins.print'):
            fork.return_value.anvil = 'mock-anvil'
            fork.return_value.proc.pid = 123
            fork.return_value.url = 'http://127.0.0.1:18555'
            q.m.sp_attempt_precheck.return_value = True
            q.pre_send.return_value = True
            run.return_value = SimpleNamespace(returncode=0, stdout='', stderr='')
            with self.assertRaisesRegex(SystemExit, 'STOP verify op not successful: sender=0x1 arm=SP round=0'):
                c.cmd_run(self.args)

    def test_assemble_without_config_chain_and_identity_refusals(self):
        fields = ('call', 'verification', 'paymasterVerification', 'postOp', 'outer')
        row = dict(gasUsed=1, estimate=1, hash='0xtx', innerEstimate=1)
        record = dict(pin=dict(chainId=self.args.chain, number=123, hash='0xabc'),
            configSha256=hashlib.sha256((self.p/'config').read_bytes()).hexdigest(),
            steps=[dict(row, sid=s) for s in ('C9.allowance', 'C9.total', 'C9.mode', 'C18.approve')],
            extraSteps=[], safe={s: row for s in ('C1', 'GToken.transfer', 'SP.stake.schedule', 'SP.stake.execute')},
            ops=dict(ops=[dict(verdict='USEROP_SUCCESS', arm='SP', sender='0x1', round=-1, warmup=True,
                                warmupMinima={'verification': '41129'}, minima=None, measurement=None, tx=dict(hash='0xw'))] +
                          [dict(verdict='USEROP_SUCCESS', arm=arm, sender='0x1', round=1,
                minima=dict.fromkeys(fields, 1), measurement=dict.fromkeys(fields, 1), tx=dict(hash='0xtx'))
                for arm in ('SP', 'VPM', 'TPM')]), anvil='mock-anvil', plan=dict(sha256='abc'), notes=[])
        self.args.measurements.write_text(json.dumps(record))
        with patch('builtins.print'):
            c.cmd_assemble(self.args)
        evidence = json.loads((self.p/'calibration-evidence.json').read_text())
        self.assert_identity(evidence)
        self.assertEqual(evidence['chainId'], self.args.chain)
        for key, value in [('chain', 11155111), ('config', self.p/'different')]:
            with self.subTest(key=key):
                (self.p/'different').write_text(json.dumps(self.cfg))
                args = SimpleNamespace(**vars(self.args))
                setattr(args, key, value)
                with self.assertRaisesRegex(SystemExit, 'STOP'):
                    c.cmd_assemble(args)

    def derive(self, chains=(11155420, 11155420), chain=11155420):
        from unittest.mock import MagicMock
        addr = '0x' + '1'*40
        pr = dict.fromkeys(('gasFactor', 'feeFactor', 'priorityRule', 'feeCeiling', 'stakeWei', 'unstakeDelay',
            'fixturePins', 'minTxInterval', 'sdkRuns', 'sdkMaxOps', 'priceHeadroomBPS', 'sdkMaxCostPerOp',
            'sdkCostCapCommit', 'taskRecipientAmount'), 1)
        pr.update(experiment=addr, bundler=addr, verifyingSigner=addr, owners=[], salts=[],
            sdk=dict(owner=addr, salt=0, account=addr), baselineSha256=dict(VerifyingPaymaster='abc', TokenPaymaster='abc'))
        (self.p/'principals').write_text(json.dumps(pr))
        providers = []
        for observed in chains:
            provider = MagicMock()
            provider.name = 'mock-provider'
            provider.side_effect = lambda method, params, observed=observed: hex(observed) if method == 'eth_chainId' else dict(
                number='0x7b', hash='0xabc', timestamp='0x1', parentHash='0xdef')
            providers.append(provider)
        argv = ['derive_inputs.py', '--chain', str(chain), '--config', str(self.args.config),
            '--rpc-a-file', 'unused', '--rpc-b-file', 'unused', '--principals', str(self.p/'principals'),
            '--block', '123', '--out-dir', str(self.p)]
        with patch('sys.argv', argv), patch.object(d, 'Provider', side_effect=providers), \
             patch.object(d.Pinned, 'code', return_value='0x12'), \
             patch.object(d.Pinned, 'address', side_effect=lambda to, sig, *args: d.EP if sig == 'entryPoint()' else addr), \
             patch.object(d.Pinned, 'word', return_value=1), patch.object(d, 'keccak_code', return_value='0xhash'), \
             patch.object(d, 'find_account_runtime', return_value=dict(value='0xhash')), \
             patch.object(d, 'artifact', return_value=({}, 'mock-artifact', 'abc')), \
             patch.object(d.a, 'keccak', return_value='0xhash'), \
             patch.object(d.q, 'cost_bounds', return_value=(1, 1, 1)), patch('builtins.print'):
            d.main()

    def test_derive_without_config_chain(self):
        self.derive()
        record = json.loads((self.p/'derived-values.provisional.json').read_text())
        self.assert_identity(record)
        self.assertEqual(record['chainId'], self.args.chain)
        self.assertIn('11155420', json.loads((self.p/'inputs.dsr.provisional.json').read_text())['rehearsal'])

    def test_derive_rpc_chain_mismatch_and_unknown(self):
        for chains, chain in [((11155111, 11155111), 11155420), ((11155420, 11155111), 11155420),
                              ((11155111, 11155420), 11155420), ((31337, 31337), 31337)]:
            with self.subTest(chains=chains, chain=chain), self.assertRaisesRegex(SystemExit, 'STOP'):
                self.derive(chains, chain)

    def test_fork_rpc_chain_mismatch(self):
        with patch.object(c.subprocess, 'Popen') as popen, patch.object(c.threading, 'Thread'), patch.object(c, 'choose_port', return_value=18555), \
             patch.object(c.Fork, '__call__', return_value=hex(11155111)), patch.object(c.Fork, 'stop') as stop:
            popen.return_value.poll.return_value = None
            with self.assertRaisesRegex(SystemExit, 'STOP fork chainId mismatch'):
                c.Fork(18555).start(self.p/'upstream', 123, self.p/'log', self.args.chain)
            stop.assert_called_once()

    def test_unknown_chain_stops_every_calibration_command(self):
        self.args.chain = 31337
        self.args.measurements.write_text('{}')
        for fn in (c.cmd_provisional, c.cmd_checker, c.cmd_run, c.cmd_assemble):
            with self.subTest(command=fn.__name__), patch.object(c, 'load_planner'), \
                 patch.object(c.Fork, 'start') as start, self.assertRaisesRegex(SystemExit, 'STOP'):
                fn(self.args)
            start.assert_not_called()

    def test_chain_is_required_on_every_cli(self):
        commands = [(['calibrate.py', cmd], c.main) for cmd in ('provisional', 'checker', 'run', 'assemble')]
        commands.append((['derive_inputs.py'], d.main))
        import io
        for argv, main in commands:
            with self.subTest(argv=argv), patch('sys.argv', argv), patch('sys.stderr', new_callable=io.StringIO) as err:
                with self.assertRaises(SystemExit):
                    main()
                self.assertIn('--chain', err.getvalue())


class AssembleSpVerificationMinima(unittest.TestCase):
    """H1: cmd_assemble folds the round -1 SP warm-up nonce-0 verification minimum into
    arms.SP.verification = max(nonce0, nonceAtLeast1) and records spVerificationMinima as a new
    top-level key of both calibration.json and calibration-evidence.json."""

    ARM_VALUES = {'SP': dict(call=11, verification=24029, paymasterVerification=12, postOp=13, outer=14),
                  'VPM': dict(call=21, verification=24, paymasterVerification=22, postOp=0, outer=24),
                  'TPM': dict(call=31, verification=34, paymasterVerification=32, postOp=33, outer=35)}

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.p = Path(self.tmp.name)
        self.cfg = full_deploylive_config()
        (self.p/'config').write_bytes(json.dumps(self.cfg, indent=2).encode())
        self.args = SimpleNamespace(chain=11155420, config=self.p/'config',
            measurements=self.p/'measurements.json', out_dir=self.p, evidence_prefix='evidence')

    def write_record(self, sp_warmup_verification):
        row = dict(gasUsed=1, estimate=1, hash='0xtx', innerEstimate=1)
        ops = [dict(verdict='USEROP_SUCCESS', arm=arm, sender='0x1', round=0, warmup=False,
                    minima=dict(vals), measurement=dict(vals), tx=dict(hash='0xtx'))
               for arm, vals in self.ARM_VALUES.items()]
        if sp_warmup_verification is not None:
            ops.append(dict(verdict='USEROP_SUCCESS', arm='SP', sender='0x1', round=-1, warmup=True,
                            warmupMinima={'verification': str(sp_warmup_verification)}, minima=None,
                            measurement=None, tx=dict(hash='0xw')))
        record = dict(pin=dict(chainId=11155420, number=123, hash='0xabc'),
            configSha256=hashlib.sha256((self.p/'config').read_bytes()).hexdigest(),
            steps=[dict(row, sid=s) for s in ('C9.allowance', 'C9.total', 'C9.mode', 'C18.approve')],
            extraSteps=[], safe={s: row for s in ('C1', 'GToken.transfer', 'SP.stake.schedule', 'SP.stake.execute')},
            ops=dict(ops=ops), anvil='mock-anvil', plan=dict(sha256='abc'), notes=[])
        self.args.measurements.write_text(json.dumps(record))

    def assemble(self):
        with patch('builtins.print'):
            c.cmd_assemble(self.args)
        return (json.loads((self.p/'calibration.json').read_text()),
                json.loads((self.p/'calibration-evidence.json').read_text()))

    def test_nonce0_dominates_and_is_recorded_in_both_files(self):
        self.write_record(41129)
        cal, ev = self.assemble()
        self.assertEqual(cal['arms']['SP']['verification'], 41129)
        self.assertEqual(ev['arms']['SP']['verification'], 41129)
        minima = dict(nonce0=41129, nonceAtLeast1=24029, rule='SP.verification = max(nonce0, nonceAtLeast1)')
        self.assertEqual(cal['spVerificationMinima'], minima)
        self.assertEqual(ev['spVerificationMinima'], minima)
        self.assertNotIn('spVerificationMinima', cal['arms']['SP'])  # top-level, not inside arms
        for arm, vals in self.ARM_VALUES.items():
            for field, value in vals.items():
                if arm == 'SP' and field == 'verification': continue
                self.assertEqual(cal['arms'][arm][field], value, f'{arm}.{field} unchanged')
                self.assertEqual(ev['arms'][arm][field], value, f'{arm}.{field} unchanged')
        sources = ev['provenance']['arms']['SP.verification']['sources']
        self.assertTrue(any(s.get('round') == -1 and 'nonce 0' in s['rule'] and 'first-use' in s['rule']
                            for s in sources), sources)

    def test_nonce_at_least_1_still_wins_when_larger(self):
        self.write_record(1000)
        cal, ev = self.assemble()
        self.assertEqual(cal['arms']['SP']['verification'], 24029)
        self.assertEqual(cal['spVerificationMinima'], dict(nonce0=1000, nonceAtLeast1=24029,
            rule='SP.verification = max(nonce0, nonceAtLeast1)'))
        self.assertEqual(ev['spVerificationMinima']['nonce0'], 1000)

    def test_missing_warmup_sp_row_stops(self):
        self.write_record(None)
        with patch('builtins.print'), self.assertRaisesRegex(SystemExit, 'STOP no SP warm-up'):
            c.cmd_assemble(self.args)


class VerifyOpsConservation(unittest.TestCase):
    """M2: check_verify_ops accepts an all-success consecutive-nonce set and refuses a failed op
    row, a bad tx status / uoe, or a nonce gap, naming the failing sender/arm/round."""

    def op(self, sender='0x1', arm='SP', round=0, nonce='0', verdict='USEROP_SUCCESS', status='0x1', success=True):
        return dict(sender=sender, arm=arm, round=round, nonce=nonce, verdict=verdict,
                    tx=dict(hash='0xtx', status=status), uoe=dict(success=success))

    def test_accepts_all_success_consecutive_nonces(self):
        c.check_verify_ops([self.op(nonce='0'), self.op(arm='VPM', nonce='1'), self.op(arm='TPM', nonce='2'),
                           self.op(round=1, nonce='3'), self.op(round=1, arm='VPM', nonce='4'),
                           self.op(sender='0x2', nonce='0'), self.op(sender='0x2', arm='VPM', nonce='1')])

    def test_refuses_tx_failed_row(self):
        with self.assertRaisesRegex(SystemExit, 'STOP verify op not successful: sender=0x1 arm=TPM round=1'):
            c.check_verify_ops([self.op(nonce='0'), self.op(arm='VPM', nonce='1'),
                                self.op(arm='TPM', round=1, nonce='2', verdict='TX_FAILED', status='0x0', success=False)])

    def test_refuses_bad_status_or_uoe(self):
        for kwargs in (dict(status='0x0'), dict(success=False)):
            with self.subTest(kwargs=kwargs), self.assertRaisesRegex(SystemExit, 'STOP verify op not successful: sender=0x1 arm=VPM round=0'):
                c.check_verify_ops([self.op(nonce='0'), self.op(arm='VPM', nonce='1', **kwargs)])

    def test_refuses_nonce_gap(self):
        with self.assertRaisesRegex(SystemExit, 'STOP verify nonce not conserved: sender=0x1 arm=TPM round=0 nonce=3 expected=2'):
            c.check_verify_ops([self.op(nonce='0'), self.op(arm='VPM', nonce='1'), self.op(arm='TPM', nonce='3')])
