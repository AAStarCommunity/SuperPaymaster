import unittest
import test_three_arm as fixtures
import plan_three_arm as q


class PVG(unittest.TestCase):
    def fixture(self):
        f = fixtures.ThreeArm(); f.setUp()
        for arm in q.m.ARMS:
            f.cal['arms'][arm].pop('preVerification', None)
        return f

    def test_rule_frozen_independent_of_factor(self):
        f = self.fixture()
        previous = None
        for numerator, denominator in [(1, 1), (3, 2), (2, 1)]:
            f.inputs['gasFactor'] = dict(numerator=numerator, denominator=denominator)
            pc = next(iter(f.build()['plans'].values()))['phaseC']
            records = [pc['gasSources'][arm]['preVerification'] for arm in q.m.ARMS]
            for arm, record in zip(q.m.ARMS, records):
                self.assertEqual(record['factor'], dict(numerator=1, denominator=1))
                self.assertEqual(record['mode'], 'sign-time')
                self.assertIsNone(pc['bounds'][arm]['preVerification'])
                for field in ('verification', 'paymasterVerification', 'call'):
                    self.assertEqual(pc['bounds'][arm][field], q.scale(f.cal['arms'][arm][field], f.inputs['gasFactor']))
            if previous is not None:
                self.assertEqual(previous, records)
            previous = records

    def test_old_calibration_pvg_stops(self):
        f = self.fixture()
        for arm in q.m.ARMS:
            f.cal['arms'][arm]['preVerification'] = 60000
            f.stop('rq3_calibration_pvg', f.build)
            del f.cal['arms'][arm]['preVerification']

    def test_legacy_full_calibration_cannot_charge_scaled_pvg(self):
        f = self.fixture()
        for arm in q.m.ARMS:
            f.cal['arms'][arm]['preVerification'] = 60000
        f.stop('rq3_calibration_pvg', f.build)

    def test_reserve_excludes_outer_and_freezes_lengths(self):
        f = self.fixture()
        pc = next(iter(f.build()['plans'].values()))['phaseC']
        for arm in q.m.ARMS:
            lengths = dict(initCode=0, callData=(len(pc['taskCallData'])-2)//2,
                           paymasterAndData={'SP':125, 'VPM':181, 'TPM':52}[arm], signature=65)
            self.assertEqual(pc['pvgLengths'][arm], lengths)
            self.assertEqual(pc['gasSources'][arm]['preVerification']['fixedLengths'], lengths)
            self.assertEqual(pc['gasSources'][arm]['preVerification']['reserve'], pc['pvgReserve'][arm])
            self.assertEqual(pc['maxPrefund'][arm], (sum(v for k,v in pc['bounds'][arm].items()
                if k not in ('outer','preVerification')) + pc['pvgReserve'][arm])*pc['feeCap'])
        for arm in q.m.ARMS:
            f.cal['arms'][arm]['outer'] *= 2
        changed = next(iter(f.build()['plans'].values()))['phaseC']
        self.assertEqual(changed['maxPrefund'], pc['maxPrefund'])
        self.assertEqual(changed['pvgReserve'], pc['pvgReserve'])
        self.assertGreater(changed['bundlerTarget'], pc['bundlerTarget'])
