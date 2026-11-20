"""Offline mutation regressions for clestons R1."""
import unittest
import test_three_arm as t
from test_three_arm import q, a, m, address


class Clestons(unittest.TestCase):
    setUp = t.ThreeArm.setUp
    build = t.ThreeArm.build
    stop = t.ThreeArm.stop

    def extras(self):
        amount = self.build()['shared']['sdkLive']['perUserFloor']
        self.inputs['extraEndUsers'] = [dict(address=address(900), xAmount=amount)]
        self.cal['setup'].update({f'C8.extra.0.{s}': 100000 for s in ('approve', 'role', 'mint')})
        return amount

    def test_existing_extra_role_stops_planning(self):
        self.extras()
        self.rpc.set(self.cfg['registry'], 'hasRole(bytes32,address)',
                     m.role_id('ENDUSER'), address(900), value=1)
        self.stop('rq3_extra_role_absent', self.build)

    def test_extra_tickets_are_in_safe_transfer(self):
        self.extras()
        for pin in self.pins:
            pin['endUser']['deployerGToken'] = 1
        bundle = self.build()
        pcs = [p['phaseC'] for p in bundle['plans'].values()]
        ticket = pcs[0]['endUserStake'] + pcs[0]['endUserTicket']
        expected = sum(p['endUserStake'] + p['endUserTicket'] for p in pcs) + ticket - 1
        self.assertEqual(bundle['funding']['genesisGToken']['safeTransfer'], expected)
        tx = next(s for s in bundle['safeTransactions'] if s['id'] == 'GToken.transfer')
        self.assertEqual(tx['data'], a.calldata('transfer(address,uint256)', self.inputs['genesis'], expected))

    def test_extra_tickets_reduce_later_plan_balance(self):
        self.extras()
        for pin in self.pins:
            pin['endUser']['deployerGToken'] = 1
        bundle = self.build()
        plans = list(bundle['plans'].values())
        ticket = plans[0]['phaseC']['endUserStake'] + plans[0]['phaseC']['endUserTicket']
        funded = 1 + bundle['funding']['genesisGToken']['safeTransfer']
        for i, plan in enumerate(plans[1:], 1):
            self.assertEqual(plan['pin']['phaseC']['endUser']['deployerGToken'], funded - (i + 1) * ticket)

    def test_extra_supply_is_carried_to_later_mints(self):
        amount = self.extras()
        bundle = self.build()
        supply = amount
        for i, plan in enumerate(bundle['plans'].values()):
            supply += plan['phaseC']['userTarget']
            if i:
                step = next(s for s in plan['steps'] if s['id'] == 'C8')
                self.assertEqual(next(p['expected'] for p in step['readbacks']
                                      if p.get('signature') == 'totalSupply()'), supply)

    def test_extra_calibration_requires_positive_integers(self):
        self.extras()
        for suffix in ('approve', 'role', 'mint'):
            key = f'C8.extra.0.{suffix}'
            for value in (None, 0, -1, True, 1.5):
                with self.subTest(suffix=suffix, value=value):
                    self.cal['setup'][key] = value
                    self.stop('rq3_extra_calibration', self.build)
            self.cal['setup'][key] = 100000

    def test_plan_zero_interval_window(self):
        plan = t.SendGates.ready(self)
        steps = plan['steps']
        boundary = next(i for i, s in enumerate(steps) if s['id'] == 'C3.limits')
        for step, interval in ((steps[boundary-1], 0), (steps[boundary], 0), (steps[boundary+1], 60)):
            self.rpc.set(self.cfg['superPaymaster'], 'operators(address)', self.inputs['genesis'],
                         value=[0, 1, 0, 0, 0, interval, 0, 0, 0])
            q.pre_send(self.rpc, plan, step)
            self.rpc.set(self.cfg['superPaymaster'], 'operators(address)', self.inputs['genesis'],
                         value=[0, 1, 0, 0, 0, 60-interval, 0, 0, 0])
            self.stop('rq3_send_interval', lambda: q.pre_send(self.rpc, plan, step))
