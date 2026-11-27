"""Fork-rehearsal single-provider mode: DEPLOYLIVE_FORK_REHEARSAL=1 on a 127.0.0.1 fork of a real chain.

(a) flag + 127.0.0.1 + chain 10 -> single provider allowed, REHEARSAL header, record mode REHEARSAL
(b) flag + production (DEPLOYLIVE_REHEARSAL='0') -> refused before any check
(c) flag + DEPLOYER_ACCOUNT set -> refused before any check
(d) flag + non-loopback RPC -> not allowed, second provider still required
(e) no flag, chain 10 -> unchanged, second provider still required
"""
import json
import os
import unittest
from unittest.mock import patch

import deploylive_readback as r
from test_deploylive_postdeploy_check import CheckerTest

LOOPBACK = 'http://127.0.0.1:8545'
FLAG = {'DEPLOYLIVE_FORK_REHEARSAL': '1'}
# Neutralise any ambient keystore so only the variables under test decide the refusal.
CLEAN = dict(FLAG, DEPLOYLIVE_REHEARSAL='1', DEPLOYER_ACCOUNT='')


class ForkRehearsalGateTest(unittest.TestCase):
    def test_a_flag_loopback_chain10_allows_single_provider(self):
        self.assertTrue(r.fork_rehearsal_active(CLEAN, 10, LOOPBACK))
        self.assertTrue(r.single_provider_allowed(10, LOOPBACK, CLEAN))

    def test_default_env_is_process_environ(self):
        # The checker call sites pass no env; the process environment must be consulted.
        with patch.dict(os.environ, CLEAN):
            self.assertTrue(r.single_provider_allowed(10, LOOPBACK))
        with patch.dict(os.environ, {'DEPLOYLIVE_FORK_REHEARSAL': '0', 'DEPLOYLIVE_REHEARSAL': '1'}):
            self.assertFalse(r.single_provider_allowed(10, LOOPBACK))

    def test_rehearsal_unset_or_other_is_not_active(self):
        self.assertFalse(r.fork_rehearsal_active(FLAG, 10, LOOPBACK))
        self.assertFalse(r.single_provider_allowed(10, LOOPBACK, FLAG))
        for value in ('', '0', 'true', 'yes', '2'):
            with self.subTest(value=value):
                env = dict(FLAG, DEPLOYLIVE_REHEARSAL=value)
                self.assertFalse(r.fork_rehearsal_active(env, 10, LOOPBACK))

    def test_userinfo_url_is_not_active(self):
        for endpoint in ('http://user:pass@127.0.0.1:8545', 'http://user@127.0.0.1:8545', 'http://@127.0.0.1:8545'):
            with self.subTest(endpoint=endpoint):
                self.assertFalse(r.fork_rehearsal_active(CLEAN, 10, endpoint))
                self.assertFalse(r.single_provider_allowed(10, endpoint, CLEAN))

    def test_d_flag_non_loopback_not_allowed(self):
        for endpoint in ('https://fork.example.com:8545', 'http://localhost:8545', 'http://[::1]:8545', 'http://127.0.0.2:8545', ''):
            with self.subTest(endpoint=endpoint):
                self.assertFalse(r.single_provider_allowed(10, endpoint, FLAG))

    def test_e_no_flag_unchanged(self):
        for chain in (10, 11155111, 11155420):
            with self.subTest(chain=chain):
                self.assertFalse(r.single_provider_allowed(chain, LOOPBACK, {}))
        self.assertTrue(r.single_provider_allowed(31337, 'https://any.example.com', {}))
        # Chain 31337 stays plain local mode even with the flag set.
        self.assertFalse(r.fork_rehearsal_active(FLAG, 31337, LOOPBACK))
        self.assertTrue(r.single_provider_allowed(31337, LOOPBACK, FLAG))


class ForkRehearsalCheckerTest(unittest.TestCase):
    run_checker = CheckerTest.run_checker

    def test_a_flag_loopback_chain10_rehearsal_header_and_record(self):
        records = []
        rc, out = self.run_checker(op=True, env_rpc=True, rpc_url=LOOPBACK, extra_env=CLEAN, capture_record=records)
        self.assertEqual(rc, 0, out)
        first = out.splitlines()[0]
        self.assertTrue(first.startswith('MODE REHEARSAL'), out)
        self.assertIn('not evidence of on-chain state', first)
        self.assertIn('SUMMARY', out)
        self.assertIn('PASS  second provider', out)
        self.assertEqual(len(records), 1, out)
        self.assertEqual(records[0]['mode'], 'REHEARSAL')
        self.assertTrue(records[0]['singleProvider'])
        self.assertIsNone(records[0]['secondProvider'])
        self.assertEqual(records[0]['singleProviderNote'], 'single provider: not evidence of on-chain state')

    def test_b_flag_plus_production_refused_before_any_check(self):
        rc, out = self.run_checker(op=True, env_rpc=True, rpc_url=LOOPBACK,
                                   extra_env=dict(FLAG, DEPLOYLIVE_REHEARSAL='0', DEPLOYER_ACCOUNT=''))
        self.assertEqual(rc, 1, out)
        self.assertIn('FAIL DEPLOYLIVE_FORK_REHEARSAL refused', out)
        self.assertNotIn('MODE REHEARSAL', out)
        self.assertNotIn('SUMMARY', out)
        self.assertNotIn('PASS  ', out)
        self.assertNotIn('FAIL  ', out)

    def test_c_flag_plus_keystore_refused_before_any_check(self):
        rc, out = self.run_checker(op=True, env_rpc=True, rpc_url=LOOPBACK,
                                   extra_env=dict(FLAG, DEPLOYLIVE_REHEARSAL='1', DEPLOYER_ACCOUNT='deployer-keystore'))
        self.assertEqual(rc, 1, out)
        self.assertIn('FAIL DEPLOYLIVE_FORK_REHEARSAL refused', out)
        self.assertNotIn('MODE REHEARSAL', out)
        self.assertNotIn('SUMMARY', out)

    def test_d_flag_non_loopback_still_requires_second_provider(self):
        rc, out = self.run_checker(op=True, env_rpc=True, rpc_url='https://fork.example.com:8545', extra_env=CLEAN)
        self.assertEqual(rc, 1, out)
        self.assertIn('FAIL  second provider', out)
        self.assertNotIn('MODE REHEARSAL', out)

    def test_e_no_flag_chain10_unchanged(self):
        rc, out = self.run_checker('second_missing', op=True, env_rpc=True, rpc_url=LOOPBACK,
                                   extra_env={'DEPLOYLIVE_REHEARSAL': '1', 'DEPLOYER_ACCOUNT': ''})
        self.assertEqual(rc, 1, out)
        self.assertIn('FAIL  second provider', out)
        self.assertNotIn('MODE REHEARSAL', out)

    def test_rehearsal_unset_requires_second_provider(self):
        saved = os.environ.pop('DEPLOYLIVE_REHEARSAL', None)
        try:
            self.assertFalse(r.fork_rehearsal_active(FLAG, 10, LOOPBACK))
            rc, out = self.run_checker('second_missing', op=True, env_rpc=True, rpc_url=LOOPBACK,
                                       extra_env={'DEPLOYLIVE_FORK_REHEARSAL': '1', 'DEPLOYER_ACCOUNT': ''})
        finally:
            if saved is not None: os.environ['DEPLOYLIVE_REHEARSAL'] = saved
        self.assertEqual(rc, 1, out)
        self.assertIn('FAIL  second provider', out)
        self.assertNotIn('MODE REHEARSAL', out)

    def test_userinfo_url_not_active_on_checker(self):
        rc, out = self.run_checker('second_missing', op=True, env_rpc=True, rpc_url='http://user:pass@127.0.0.1:8545', extra_env=CLEAN)
        self.assertEqual(rc, 1, out)
        self.assertIn('FAIL  second provider', out)
        self.assertNotIn('MODE REHEARSAL', out)


class ForkRehearsalRecordTest(unittest.TestCase):
    def setUp(self):
        import tempfile
        from pathlib import Path
        import deploylive_controls as c
        self.c = c
        base = c.ROOT / 'cache' / 'h2-rehearsal'
        base.mkdir(parents=True, exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=base)
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.env = {'SP_COMMIT': 'a' * 40, 'ENV': 'test', 'DEPLOYLIVE_EVIDENCE_DIR': str(self.root),
                    'DEPLOYLIVE_FORK_REHEARSAL': '1', 'DEPLOYLIVE_REHEARSAL': '1',
                    'DEPLOYLIVE_EXPECTED_CHAIN_ID': '10', 'DEPLOYLIVE_RPC': LOOPBACK}
        (self.root / 'pop-request.json').write_text('{}')
        (self.root / 'gated-plan.json').write_text('{}')
        (self.root / 'readback.json').write_text('{"mode": "REHEARSAL", "singleProvider": true, "chainId": "10"}')
        self.config = self.root / 'external-config.json'
        self.broadcast = self.root / 'external-broadcast.json'
        self.config.write_text('{}')
        self.broadcast.write_text('{}')
        c.write_manifest(self.env, self.root)

    def test_rehearsal_run_writes_only_rehearsal_pass(self):
        (self.root / 'checker.PASS.json').write_text('stale')
        self.c.write_success(self.root, self.env, self.config, self.broadcast, {})
        self.assertFalse((self.root / 'checker.PASS.json').exists())
        self.assertTrue((self.root / 'checker.REHEARSAL_PASS.json').is_file())
        record = json.loads((self.root / 'checker.REHEARSAL_PASS.json').read_text())
        self.assertEqual(record['status'], 'REHEARSAL_PASS')
        self.assertEqual(record['mode'], 'REHEARSAL')
        self.assertIs(record['singleProvider'], True)

    def test_archive_refuses_rehearsal_readback(self):
        self.c.write_success(self.root, self.env, self.config, self.broadcast, {})
        with self.assertRaisesRegex(RuntimeError, 'rehearsal readback'):
            self.c.archive_records(self.root)

    def test_archive_refuses_single_provider_off_local_chain(self):
        (self.root / 'readback.json').write_text('{"singleProvider": true, "chainId": "10"}')
        plain = dict(self.env)
        plain.pop('DEPLOYLIVE_FORK_REHEARSAL')
        self.c.write_success(self.root, plain, self.config, self.broadcast, {})
        self.assertTrue((self.root / 'checker.PASS.json').is_file())
        with self.assertRaisesRegex(RuntimeError, 'rehearsal readback'):
            self.c.archive_records(self.root)

    def test_archive_allows_chain_31337_single_provider(self):
        (self.root / 'readback.json').write_text('{"singleProvider": true, "chainId": "31337"}')
        plain = dict(self.env)
        plain.pop('DEPLOYLIVE_FORK_REHEARSAL')
        self.c.write_success(self.root, plain, self.config, self.broadcast, {})
        self.c.archive_records(self.root)


class ForkRehearsalCliPreflightTest(unittest.TestCase):
    def test_flag_with_production_or_keystore_refused_before_forge(self):
        import deploylive_controls as c
        import deploylive_fork_deploy as f
        calls = []
        base = {'DEPLOYER_ACCOUNT': '', 'DEPLOYLIVE_EVIDENCE_DIR': 'cache/h2-should-not-run'}

        def boom(*args, **kwargs):
            calls.append(args)
            raise AssertionError('forge called')

        with patch.object(f.subprocess, 'run', side_effect=boom):
            with patch.object(c, 'load_inputs', return_value=dict(base, DEPLOYER_ACCOUNT='keystore')), patch.dict(os.environ, FLAG):
                with self.assertRaisesRegex(RuntimeError, 'DEPLOYLIVE_FORK_REHEARSAL refused'):
                    f.cli(['predict', '--inputs', 'unused'])
            with patch.object(c, 'load_inputs', return_value=dict(base)), patch.dict(os.environ, FLAG):
                with self.assertRaisesRegex(RuntimeError, 'DEPLOYLIVE_FORK_REHEARSAL refused'):
                    f.cli(['deploy', '--inputs', 'unused', '--production'])
        self.assertEqual(calls, [])


if __name__ == '__main__':
    unittest.main()
