import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

import deploylive_deploy_day as d

ROOT = Path(__file__).resolve().parents[2]
(ROOT / 'cache/ddf').mkdir(parents=True, exist_ok=True)

class DeployDayTest(unittest.TestCase):
    def setUp(self):
        capture = contextlib.redirect_stdout(io.StringIO())
        capture.__enter__()
        self.addCleanup(capture.__exit__, None, None, None)

    def test_config_present_checker_failure(self):
        with tempfile.TemporaryDirectory(dir=ROOT/'cache/ddf') as tmp:
            path = Path(tmp)/'config.json'
            path.write_text('{}')
            for rc, output in [(1, 'SUMMARY 1 passed, 0 failed, 1 total'), (0, 'SUMMARY 1 passed, 1 failed, 2 total'), (0, '')]:
                with self.subTest(rc=rc, output=output), self.assertRaisesRegex(RuntimeError, 'checker'):
                    d.checker_pass(SimpleNamespace(returncode=rc, stdout=output))
            d.checker_pass(SimpleNamespace(returncode=0, stdout='SUMMARY 188 passed, 0 failed, 188 total\n'))

    def test_separate_build_directories(self):
        for env in ({'FOUNDRY_OUT':'out', 'FOUNDRY_CACHE_PATH':'prague/cache'},
                    {'FOUNDRY_OUT':'prague/out', 'FOUNDRY_CACHE_PATH':'cache'},
                    {'FOUNDRY_OUT':'out/child', 'FOUNDRY_CACHE_PATH':'prague/cache'}):
            with self.subTest(env=env), self.assertRaisesRegex(RuntimeError, 'separate'):
                d.build_paths(env)
        d.build_paths({'FOUNDRY_OUT':'prague/out', 'FOUNDRY_CACHE_PATH':'prague/cache'})

    def test_stamp_detects_version_path_and_hash_change(self):
        with tempfile.TemporaryDirectory(dir=ROOT/'cache/ddf') as tmp:
            env = {'FOUNDRY_OUT':tmp+'/out', 'FOUNDRY_CACHE_PATH':tmp+'/cache', 'DEFAULT_ARTIFACTS_OUT':tmp+'/release', 'DEFAULT_CACHE_PATH':tmp+'/release-cache'}
            identity = dict(path='/forge', version='forge 4e8874b nightly', sha256='a'*64)
            with patch.object(d, 'forge_identity', return_value=identity), patch.object(d.subprocess, 'run', return_value=SimpleNamespace(returncode=0)), patch.object(d, 'check_pin'):
                d.build(env, False)
                d.verify_build(env, False)
                for key in identity:
                    with patch.object(d, 'forge_identity', return_value=dict(identity, **{key:'changed'})):
                        with self.subTest(key=key), self.assertRaisesRegex(RuntimeError, 'build.*differs'):
                            d.verify_build(env, False)

    def test_production_pin(self):
        pin = json.loads(d.PIN.read_text())
        d.check_pin(dict(path='/forge', version='forge nightly '+pin['commit'], sha256=pin['sha256']), True)
        for version, sha in [('stable', pin['sha256']), ('nightly '+pin['commit'], 'a'*64)]:
            with self.assertRaisesRegex(RuntimeError, 'pin'):
                d.check_pin(dict(path='/forge', version=version, sha256=sha), True)

    def plan(self):
        rows = [dict(transactionType='CREATE', contractName=n, transaction={'from':'0x1', 'input':'0x6000', 'gas':'0x64', 'nonce':hex(i)}) for i,n in enumerate(d.LARGE_CREATES)]
        rows.insert(2, dict(transactionType='CALL', contractName='SuperPaymaster', function='updatePrice()', transaction={'to':'0x2','input':subprocess.check_output(['cast', 'sig', 'updatePrice()'], text=True).strip(),'gas':'0x64'}))
        return dict(transactions=rows)

    def rpc(self, updated=1000, real=100, gas_limit=200_000_000, reals=None):
        def transport(method, *args):
            if method == 'eth_getBlockByNumber':
                number = 200 if args[0] == 'latest' else int(args[0],16)
                return dict(number=hex(number), hash='0xabc', timestamp=hex(1000+(number-100)*12), gasLimit=hex(gas_limit), baseFeePerGas='0x64')
            if method == 'eth_call':
                self.assertEqual(args[1], '0xc8')
                return '0x'+''.join(f'{v:064x}' for v in [1,100,1,updated,1])
            if method == 'eth_simulateV1':
                self.assertTrue(args[0]['validation'])
                calls = [b['calls'] for b in args[0]['blockStateCalls']]
                self.assertEqual(sum(map(len,calls)), len(self.plan()['transactions']))
                self.assertEqual(args[1], '0xc8')
                values = reals or [real]*len(calls)
                return [dict(calls=[dict(status='0x1',gasUsed=hex(values[i])) for _ in block]) for i,block in enumerate(calls)]
            self.fail(method)
        return transport

    def test_price_pass_boundary_and_margin(self):
        lines=[]
        # Index 2, measured 12s: required 72 + age 1200 = 1272.
        d.price_window(self.plan(), self.rpc(), self.rpc(), '0xfeed', 1272, lines.append, sp_proxy='0x2')
        self.assertIn('price_init_index=2', lines[0])
        for term in ('block_time=12', 'age=1200', 'threshold=1272', 'margin=0', 'factor=3'):
            self.assertIn(term, lines[0])
        with self.assertRaisesRegex(RuntimeError, 'wait for the next feed update'):
            d.price_window(self.plan(), self.rpc(), self.rpc(), '0xfeed', 1271, lines.append, sp_proxy='0x2')

    def test_price_endpoint_disagreement(self):
        with self.assertRaisesRegex(RuntimeError, 'endpoints disagree'):
            d.price_window(self.plan(), self.rpc(), self.rpc(updated=1001), '0xfeed', 4200, sp_proxy='0x2')

    def test_gas_sequence_and_tolerance(self):
        for real in (100, 96):
            d.gas_crosscheck(self.plan(), self.rpc(real=real), '0xc8', 0.05)
        for real in (101, 95):
            with self.subTest(real=real), self.assertRaisesRegex(RuntimeError, 'gas mismatch'):
                d.gas_crosscheck(self.plan(), self.rpc(real=real), '0xc8', 0.05)
        with self.assertRaisesRegex(RuntimeError, 'eth_simulateV1.*required'):
            d.gas_crosscheck(self.plan(), lambda *a: (_ for _ in ()).throw(RuntimeError('unsupported')), '0xc8', .05)

    def test_multiplier_130_recovers_the_estimate(self):
        # forge writes limit = estimate * 130 / 100; the gate compares ceil(limit * 100 / 130) with real.
        plan = self.plan()
        for tx in plan['transactions']: tx['transaction']['gas'] = hex(130)
        d.gas_crosscheck(plan, self.rpc(real=100), '0xc8', .05, multiplier=130)
        with self.assertRaisesRegex(RuntimeError, 'gas mismatch'):
            d.gas_crosscheck(plan, self.rpc(real=100), '0xc8', .05, multiplier=100)

    def test_limit_at_or_below_cap_needs_total_headroom(self):
        # A limit <= 2^24 has no EIP-8037 reservoir: total gas counts against the regular cap.
        cap = d.TX_GAS_CAP
        plan = self.plan(); n = len(plan['transactions'])
        plan['transactions'][1]['transaction']['gas'] = hex(cap)
        tight = [100]*n; tight[1] = int(cap*0.95)
        with self.assertRaisesRegex(RuntimeError, 'leaves under 10% headroom'):
            d.gas_crosscheck(plan, self.rpc(reals=tight), '0xc8', .05)
        plan['transactions'][1]['transaction']['gas'] = hex(cap + 1)  # above the cap: reservoir available
        with self.assertRaisesRegex(RuntimeError, 'gas mismatch'):  # passes the cap rule, then the tolerance check applies
            d.gas_crosscheck(plan, self.rpc(reals=tight), '0xc8', .05)

    def test_limit_above_block_gas_limit(self):
        with self.assertRaisesRegex(RuntimeError, 'above block gas limit'):
            d.gas_crosscheck(self.plan(), self.rpc(gas_limit=99), '0xc8', .05)

    def test_multiplier_range(self):
        for bad in (99, 201, 1.3):
            with self.assertRaisesRegex(RuntimeError, 'multiplier'):
                d.gas_crosscheck(self.plan(), self.rpc(), '0xc8', .05, multiplier=bad)

    def test_h_gas_mismatch_and_exact_five_percent(self):
        plan = self.plan()
        for tx in plan['transactions']: tx['transaction']['gas'] = '0x69'
        d.gas_crosscheck(plan, self.rpc(), '0xc8', .05)
        plan['transactions'][-1]['transaction']['gas'] = '0x6a'
        with self.assertRaisesRegex(RuntimeError, 'gas mismatch: TimelockHandoverBootstrap'):
            d.gas_crosscheck(plan, self.rpc(), '0xc8', .05)

    def test_price_rechecked_after_gas_simulation(self):
        env = {'PRICE_STALENESS_THRESHOLD':'4200', 'ETH_USD_FEED':'feed'}
        with patch.object(d, 'price_window', side_effect=[('0xc8', 12), RuntimeError('STOP wait for the next feed update')]) as price, patch.object(d, 'gas_crosscheck') as gas:
            with self.assertRaisesRegex(RuntimeError, 'wait for the next feed update'):
                d.broadcast_gates(env, self.plan(), self.rpc(), self.rpc())
            self.assertEqual(price.call_count, 2)
            gas.assert_called_once()

    def test_missing_gas_target(self):
        plan=self.plan(); plan['transactions'].pop()
        with self.assertRaisesRegex(RuntimeError, 'CREATE inventory'):
            d.gas_crosscheck(plan, self.rpc(), '0xc8', .05)

    def test_converter_missing_cast(self):
        fixture=ROOT/'script/rehearsal/fixtures/dvt-pop'
        result=subprocess.run([sys.executable, str(ROOT/'script/rehearsal/dvt_pop_to_guardians.py'), str(fixture/'SYNTHETIC.export.json'), str(fixture/'SYNTHETIC.request.json'), '--sp-root', str(ROOT)], env=dict(os.environ, PATH='/nonexistent'), capture_output=True, text=True)
        self.assertEqual(result.returncode, 3)
        self.assertIn('STOP cast_not_found: install foundry or add it to PATH', result.stderr)

class NestedArtifactTest(unittest.TestCase):
    def test_flat_other_profile_does_not_hide_nested_release(self):
        import creation_pins
        import deploylive_runtime
        with tempfile.TemporaryDirectory(dir=ROOT/'cache/ddf') as tmp:
            directory = Path(tmp)
            for prefix, runs in [('', 200), ('governance', 500)]:
                path = directory/prefix/'TimelockController.sol/TimelockController.json'
                path.parent.mkdir(parents=True)
                obj = dict(metadata=dict(settings=dict(compilationTarget={'TimelockController.sol':'TimelockController'},
                           optimizer=dict(runs=runs), evmVersion='cancun', viaIR=True)),
                           bytecode=dict(object='0x6000'), deployedBytecode=dict(object='0x6000'))
                path.write_text(json.dumps(obj))
            with patch.object(deploylive_runtime, 'ROOT', directory), patch.object(deploylive_runtime, 'artifact_directory', return_value='.'):
                self.assertEqual(deploylive_runtime.release_artifact('TimelockController')['metadata']['settings']['optimizer']['runs'], 500)
            self.assertEqual(creation_pins.creation_bytes(directory, 'TimelockController', 500), '0x6000')
