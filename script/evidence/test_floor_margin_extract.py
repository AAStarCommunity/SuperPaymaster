import hashlib
import unittest
from floor_margin_extract import extract

HEADER = 'Ran 24 tests for contracts/test/measure/AmsterdamHandleOpsFloor.t.sol:AmsterdamHandleOpsFloorTest\n'
SUMMARY = 'Suite result: ok. 24 passed; 0 failed; 0 skipped; finished in 1s\n'


def fixture():
    blocks = []
    for s in (450000, 600000, 1000000):
        minimum = max(500000, s + s//63 + 20000)
        for credit in (0, 1):
            blocks.append(f'[PASS] test_handleOps_scaled_{s}_{credit}()\nSETTLE: {s}\nCREDIT: {credit}\nscaled minimum minPost: {minimum}\nreal guard crossing: {minimum-7000}\nscaled margin: 7000\n')
    for s in (450000, 600000):
        minimum = max(500000, s + s//63 + 20000)
        for v in range(3):
            for p in (range(3) if v == 0 else [0]):
                blocks.append(f'[PASS] test_variance_{s}_{v}_{p}()\nvariance SETTLE: {s}\nvariance variant: {v}\nvariance position: {p}\nvariance minimum: {minimum}\nvariance crossing: {minimum-7000+p}\n')
    return blocks


def parse(log):
    return extract([log], 'Amsterdam', 'a'*40, 'nightly fixture', 'verbatim argv')


class FloorTests(unittest.TestCase):
    def test_complete_bound_report(self):
        log = HEADER + ''.join(fixture()) + SUMMARY
        r = parse(log)
        self.assertEqual(r['input_sha256'], [hashlib.sha256(log.encode()).hexdigest()])
        self.assertEqual(r['head'], 'a'*40)
        self.assertEqual(r['argv'], 'verbatim argv')
        self.assertEqual([p['spread'] for p in r['position_spread']], [2, 2])
        self.assertEqual(r['summary']['min_margin'], 6998)

    def test_union_rams_and_conflicting_controls(self):
        blocks = fixture()
        full = HEADER + ''.join(blocks) + SUMMARY
        rams = 'Analysis SETTLE: 600000\nSynthetic callback guard crossing (not settlement exhaustion): 622533'
        r = extract([full, full, rams], 'Amsterdam', 'a'*40, 'version', 'argv')
        self.assertEqual(r['measurements'][1]['fork_minus_fixture_crossing'], {'balance': 10, 'credit': 10})
        for bad in (full.replace('scaled margin: 7000', 'scaled margin: 1', 1),
                    HEADER + blocks[0].replace('scaled margin: 7000\n', '') + ''.join(blocks[1:]) + SUMMARY,
                    HEADER + ''.join(blocks) + blocks[0].replace('493000', '493001').replace('7000', '6999') + SUMMARY):
            with self.assertRaises(ValueError):
                parse(bad)

    def test_failed_partial_unbound_controls(self):
        good = HEADER + ''.join(fixture()) + SUMMARY
        bad = [good.replace('Suite result: ok.', 'Suite result: FAILED.'),
               good.replace(SUMMARY, ''),
               HEADER + ''.join(fixture()[1:]) + SUMMARY,
               good.replace('scaled minimum minPost: 629523', 'scaled minimum minPost: 629524'),
               fixture()[0], HEADER + fixture()[0] + SUMMARY,
               good.replace('[PASS]', '[FAIL: broken]', 1),
               good.replace('[PASS]', '[SKIP]', 1),
               good.replace(HEADER, ''),
               HEADER + ''.join(fixture()[:-1]) + SUMMARY]
        for log in bad:
            with self.subTest(log=log[:100]), self.assertRaises(ValueError):
                parse(log)
        with self.assertRaises(ValueError):
            extract([good], 'Amsterdam', 'bad', 'version', 'argv')


if __name__ == '__main__':
    unittest.main()
