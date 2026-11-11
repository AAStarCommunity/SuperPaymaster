import unittest
from floor_margin_extract import extract

# Verbatim scaled measurement lines from the local Amsterdam run.
HEADER = 'Ran 14 tests for contracts/test/measure/AmsterdamHandleOpsFloor.t.sol:AmsterdamHandleOpsFloorTest\n'
BALANCE = '''[PASS] test_handleOps_scaled_600k_balance() (gas: 14980823)
Logs:
  SETTLE: 600000
  CREDIT: 0
  scaled minimum minPost: 629523
  real guard crossing: 621730
  scaled margin: 7793
'''
CREDIT = '''[PASS] test_handleOps_scaled_600k_credit() (gas: 14969277)
Logs:
  SETTLE: 600000
  CREDIT: 1
  scaled minimum minPost: 629523
  real guard crossing: 621730
  scaled margin: 7793
'''


class FloorTests(unittest.TestCase):
    def test_real_lines_and_union(self):
        report = extract([HEADER + BALANCE, HEADER + CREDIT, HEADER + BALANCE], 'Amsterdam')
        group = report['measurements'][0]
        self.assertEqual(group['workloads']['balance'], dict(min_post=629523, crossing=621730, margin=7793))
        self.assertEqual(len(group['workloads']), 2)
        self.assertEqual(report['bisection_resolution_gas'], 1)
        self.assertEqual(report['summary']['min_margin'], 7793)
        self.assertEqual(report['summary']['max_observed_spread'], 0)
        self.assertIsNone(report['summary']['ratio'])

    def test_rams_same_settle_and_nonzero_spread(self):
        credit = CREDIT.replace('621730', '621732').replace('7793', '7791')
        rams = 'Analysis SETTLE: 600000\nSynthetic callback guard crossing (not settlement exhaustion): 621740'
        report = extract([HEADER + BALANCE + credit, rams], 'Amsterdam')
        self.assertEqual(report['summary']['ratio'], 7791 / 2)
        self.assertEqual(report['measurements'][0]['fork_minus_fixture_crossing'], {'balance': 10, 'credit': 8})

    def test_invalid_incomplete_conflicting_or_failed(self):
        for log in (BALANCE, HEADER + BALANCE.replace('[PASS]', '[FAIL: broken]'),
                    HEADER + BALANCE.replace('7793', '1'), HEADER + BALANCE.split('  scaled margin')[0],
                    HEADER + BALANCE + BALANCE.replace('621730', '621731').replace('7793', '7792')):
            with self.subTest(log=log), self.assertRaises(ValueError):
                extract([log], 'Amsterdam')

    def test_recap_ignored(self):
        report = extract([HEADER + BALANCE + '\nFailing tests:\n' + CREDIT], 'Amsterdam')
        self.assertEqual(list(report['measurements'][0]['workloads']), ['balance'])


if __name__ == '__main__':
    unittest.main()
