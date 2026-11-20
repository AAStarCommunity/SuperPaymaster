"""Final checker explicit snapshot and row-cardinality controls."""
import os
import sys
import unittest
from unittest.mock import patch
import test_deploylive_postdeploy_check as fixture
CHECKER = fixture.CHECKER
import deploylive_readback as readback

PIN = '0x'+'12'*32

class PlannerChecker(unittest.TestCase):
    def test_explicit_hash_is_used_and_reported(self):
        for production in (False, True):
            with self.subTest(production=production):
                records, requests = [], []
                with patch.dict(os.environ, DEPLOYLIVE_SNAPSHOT_BLOCK_HASH=PIN):
                    rc, output = fixture.CheckerTest().run_checker(capture_record=records, op=production, request_trace=requests)
                self.assertEqual(rc, 0, output)
                self.assertIn('SNAPSHOT_BLOCK_HASH '+PIN, output)
                self.assertEqual(records[0]['block']['hash'], PIN)
                self.assertFalse(any(args[:2] == ['eth_getBlockByNumber', 'latest'] for args, _ in requests))
                first_state = next(i for i, (args, _) in enumerate(requests) if args[0] == 'eth_getCode')
                for secondary in ((False, True) if production else (False,)):
                    self.assertTrue(any(args[:2] == ['eth_getBlockByNumber', '0x2a'] and other == secondary
                                        for args, other in requests[:first_state]))
                import json
                for args, _ in requests:
                    if args[0] in ('eth_call', 'eth_getCode', 'eth_getStorageAt', 'eth_getBalance'):
                        self.assertEqual(json.loads(args[-1]), dict(blockHash=PIN, requireCanonical=True))

    def test_invalid_or_different_hash_refused(self):
        for pin in ('0x2a', 'latest', '0x'+'34'*32):
            with self.subTest(pin=pin), patch.dict(os.environ, DEPLOYLIVE_SNAPSHOT_BLOCK_HASH=pin):
                rc, output = fixture.CheckerTest().run_checker()
                self.assertEqual(rc, 1, output)
                self.assertIn('FAIL pinned block', output)

    def test_extra_or_missing_assertion_fails_checker(self):
        # Alter actual emitted rows, independently of the expected-count function.
        for delta in (-1, 1):
            with self.subTest(delta=delta):
                changed = []
                def trace(frame, event, arg):
                    if (event == 'line' and frame.f_code.co_filename == str(CHECKER)
                            and frame.f_globals.get('cast') is not None
                            and getattr(frame.f_globals['cast'], 'frozen', False)
                            and frame.f_globals.get('hash_ok') is True and not changed):
                        rows = frame.f_globals['results']
                        rows.append(True) if delta == 1 else rows.pop()
                        changed.append(True)
                    return trace
                sys.settrace(trace)
                try: rc, output = fixture.CheckerTest().run_checker()
                finally: sys.settrace(None)
                self.assertTrue(changed)
                self.assertEqual(rc, 1, output)
                self.assertIn('FAIL  check count', output)

    def test_unknown_or_unpinned_rpc_rejected_before_transport(self):
        for args in (('eth_sendTransaction', '{}'), ('eth_getCode', '0x'+'11'*20, '"latest"')):
            with self.subTest(args=args), self.assertRaises(ValueError):
                readback.validate_snapshot_request(dict(hash=PIN, number='0x2a'), args)
