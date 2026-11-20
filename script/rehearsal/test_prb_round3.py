"""Offline regressions for PR B round three."""
import unittest
from pathlib import Path
import deploylive_readback as r
import test_deploylive_postdeploy_check as fixture

class RoundThree(unittest.TestCase):
    def test_expected_production_chain_rejects_local_answer(self):
        code, output = fixture.CheckerTest().run_checker(expected_chain=10)
        self.assertEqual(code, 1, output)
        self.assertIn('FAIL external dependencies: expected chain mismatch', output)

    def test_env_url_never_enters_effective_argv(self):
        for expected, status in ((31337, 0), (10, 1)):
            with self.subTest(expected=expected):
                captured = []
                code, output = fixture.CheckerTest().run_checker(env_rpc=True, argv_capture=captured, expected_chain=expected)
                self.assertEqual(code, status, output)
                self.assertTrue(captured)
                self.assertFalse(any('://' in arg for argv in captured for arg in argv))
                self.assertNotIn('private-token', output)

    def test_canonical_header_quantity(self):
        for selector in ('0x020', '0x00', '0xA'):
            with self.subTest(selector=selector), self.assertRaises(ValueError):
                r.validate_snapshot_request(dict(hash='0x'+'12'*32, number=hex(int(selector,16))),
                                            ('eth_getBlockByNumber', selector, 'false'))
        for selector in ('0x0', '0xa', '0x20'):
            r.validate_snapshot_request(dict(hash='0x'+'12'*32, number=selector),
                                        ('eth_getBlockByNumber', selector, 'false'))

    def test_non_string_header_selector(self):
        for block in (None, dict(hash='0x'+'12'*32, number='0x20')):
            for method in ('eth_getBlockByNumber', 'eth_getBlockByHash'):
                for selector in ({}, None, 32):
                    with self.subTest(block=block, method=method, selector=selector), self.assertRaisesRegex(ValueError, 'selector must be a string'):
                        r.validate_snapshot_request(block, (method, selector, 'false'), requested_hash='0x'+'12'*32)

    def test_ci_detects_planner_and_collector(self):
        text = (Path(__file__).resolve().parents[2]/'.github/workflows/test.yml').read_text()
        pattern = text.split('detect-contract-changes.sh "DeployLive Python rehearsals + local Anvil"',1)[1].split("'",2)[1]
        for path in ('script/rq3op/plan_three_arm.py', 'script/a6-collector/foo.mjs'):
            self.assertRegex(path, pattern)
