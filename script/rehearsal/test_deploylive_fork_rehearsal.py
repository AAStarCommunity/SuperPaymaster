"""Fork-rehearsal single-provider mode: DEPLOYLIVE_FORK_REHEARSAL=1 on a 127.0.0.1 fork of a real chain.

(a) flag + 127.0.0.1 + chain 10 -> single provider allowed, REHEARSAL header, record mode REHEARSAL
(b) flag + production (DEPLOYLIVE_REHEARSAL='0') -> refused before any check
(c) flag + DEPLOYER_ACCOUNT set -> refused before any check
(d) flag + non-loopback RPC -> not allowed, second provider still required
(e) no flag, chain 10 -> unchanged, second provider still required
"""
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
        self.assertTrue(r.fork_rehearsal_active(FLAG, 10, LOOPBACK))
        self.assertTrue(r.single_provider_allowed(10, LOOPBACK, FLAG))

    def test_default_env_is_process_environ(self):
        # The checker call sites pass no env; the process environment must be consulted.
        with patch.dict(os.environ, FLAG):
            self.assertTrue(r.single_provider_allowed(10, LOOPBACK))
        with patch.dict(os.environ, {'DEPLOYLIVE_FORK_REHEARSAL': '0'}):
            self.assertFalse(r.single_provider_allowed(10, LOOPBACK))

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


if __name__ == '__main__':
    unittest.main()
