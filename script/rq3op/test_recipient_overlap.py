"""Offline regressions for #670 item 5: independent recipient lists."""
import unittest
import test_three_arm as t
from test_three_arm import address, q, m, a


class RecipientOverlap(unittest.TestCase):
    setUp = t.ThreeArm.setUp
    build = t.ThreeArm.build

    def test_both_lists_generate_both_groups_in_nonce_order(self):
        who = address(0xabc)
        amount = self.build()['shared']['sdkLive']['perUserFloor']
        self.inputs['extraEndUsers'] = [dict(address=who, xAmount=amount)]
        self.inputs['taskRecipients'] = [dict(address=who, amount=301)]
        self.cal['setup'].update({'C11.extra.0': 100000,
            **{f'C8.extra.0.{suffix}': 100000 for suffix in ('approve', 'role', 'mint')}})
        for recipient in (who, '0x' + who[2:].upper()):
            with self.subTest(recipient=recipient):
                self.inputs['taskRecipients'][0]['address'] = recipient
                bundle = self.build()
                steps = bundle['steps']
                expected = ['0/C11.extra.0', '0/C8.extra.0.approve',
                            '0/C8.extra.0.role', '0/C8.extra.0.mint']
                groups = [s for s in steps if 'C11.extra.' in s['id'] or 'C8.extra.' in s['id']]
                self.assertEqual([s['id'] for s in groups], expected)
                self.assertLess(next(i for i, s in enumerate(steps) if s['id'] == '0/C11.R'),
                                steps.index(groups[0]))
                self.assertEqual([s['tx']['from'] for s in groups],
                                 [self.inputs['experiment']] + [self.inputs['genesis']] * 3)
                pc = next(iter(bundle['plans'].values()))['phaseC']
                self.assertEqual(groups[0]['tx']['to'], bundle['shared']['T'])
                self.assertEqual(groups[0]['tx']['data'], a.calldata('mint(address,uint256)', who, 301))
                self.assertEqual(groups[2]['tx']['data'], a.calldata('safeMintForRole(bytes32,address,bytes)',
                    m.role_id('ENDUSER'), who, a.cast('abi-encode', 'c(address,uint256)',
                    self.inputs['genesis'], pc['endUserStake'])))
                self.assertEqual(groups[3]['tx']['to'], pc['addresses']['X'])
                self.assertEqual(groups[3]['tx']['data'], a.calldata('mint(address,uint256)', who, amount))
                self.assertEqual(bundle['shared']['recipientPurposes'][recipient],
                                 ['task recipient', 'RQ2 live E2E'])
                for sender in {s['tx']['from'] for s in steps}:
                    nonces = [a.qty(s['tx']['nonce']) for s in steps if s['tx']['from'] == sender]
                    self.assertEqual(nonces, list(range(nonces[0], nonces[0] + len(nonces))))

    def test_each_list_rejects_reserved_and_principal_addresses(self):
        forbidden = q.addresses_in(self.cfg) | q.addresses_in(self.inputs) | {a.ZERO, m.DEAD}
        for field, amount_key, gate in (('extraEndUsers', 'xAmount', 'rq3_extra_endusers'),
                                        ('taskRecipients', 'amount', 'rq3_task_recipients')):
            for who in sorted(forbidden):
                with self.subTest(field=field, who=who):
                    self.inputs[field] = [dict(address='0x' + who[2:].upper(), **{amount_key: 301})]
                    with self.assertRaisesRegex(a.Gate, gate):
                        q.check_inputs(self.cfg, self.inputs, self.evidence)
            self.inputs[field] = []

    def test_each_list_rejects_case_insensitive_duplicates(self):
        for field, amount_key, gate in (('extraEndUsers', 'xAmount', 'rq3_extra_endusers'),
                                        ('taskRecipients', 'amount', 'rq3_task_recipients')):
            with self.subTest(field=field):
                who = address(0xabc)
                self.inputs[field] = [dict(address=value, **{amount_key: 301})
                                      for value in (who, '0x' + who[2:].upper())]
                with self.assertRaisesRegex(a.Gate, gate):
                    q.check_inputs(self.cfg, self.inputs, self.evidence)
                self.inputs[field] = []
