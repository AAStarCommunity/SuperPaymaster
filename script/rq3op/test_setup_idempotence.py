"""Tri-state decisions use observed state, including interrupted sends."""
import copy
import unittest
import test_three_arm as t
from test_three_arm import q, a, m
import setup_state as g

class Idempotence(unittest.TestCase):
    setUp=t.ThreeArm.setUp
    build=t.ThreeArm.build
    def test_every_step_has_predicates(self):
        bundle=self.build()
        for step in bundle['steps']+bundle['safeTransactions']:
            with self.subTest(step=step['id']):
                self.assertTrue(step['initial'])
                self.assertTrue(step['target'])

    def test_three_cells_each_step(self):
        bundle=self.build()
        for step in bundle['steps']+bundle['safeTransactions']:
            for state in ('initial','target','partial'):
                with self.subTest(step=step['id'],state=state):
                    def read(rpc,p):
                        source=step['initial'] if state=='initial' else step['target']
                        match=next((x for x in source if g.predicate_key(x)==g.predicate_key(p)),None)
                        return copy.deepcopy(match.get('expected','unresolved timestamp')) if match and state!='partial' else 'unexpected'
                    from unittest.mock import patch
                    with patch.object(g,'observe',side_effect=read):
                        if state=='partial' or (state=='target' and step.get('rerunStop')):
                            with self.assertRaises(a.Gate):g.precheck_state(None,step)
                        else:
                            result=g.precheck_state(None,step)
                            expected='already-satisfied' if state=='target' or step['initial']==step['target'] else 'initial'
                            self.assertEqual(result['status'],expected)

    def test_projected_operator_and_noop_nonce(self):
        bundle=self.build(); steps=bundle['steps']
        deploy=next(s for s in steps if s['id']=='0/C3.deploy')
        operator=next(p for p in deploy['initial'] if p.get('signature')=='operators(address)')
        deposit=next(s for s in steps if s['id']=='0/C2.deposit')
        self.assertEqual(operator['expected'][m.OP['aPNTsBalance']],deposit['target'][0]['expected'])
        for i,s in enumerate(steps):
            if s['id'].endswith('/C9.mode'):
                self.assertEqual(s['initial'],s['target'])
                following=next(x for x in steps[i+1:] if x['tx']['from']==s['tx']['from'])
                self.assertEqual(s['tx']['nonce'],following['tx']['nonce'])

    def test_extra_predicates_and_real_reads(self):
        who=t.address(900)
        amount=self.build()['shared']['sdkLive']['perUserFloor']
        self.inputs['extraEndUsers']=[dict(address=who,xAmount=amount)]
        self.cal['setup'].update({f'C8.extra.0.{s}':100000 for s in ('approve','role','mint')})
        bundle=self.build()
        mint=next(s for s in bundle['steps'] if s['id']=='0/C8.extra.0.mint')
        self.assertEqual(mint['initial'][0]['expected'],0)
        self.assertEqual(mint['target'][0]['expected'],amount)
        for suffix in ('mint','role','approve'):
            step=next(s for s in bundle['steps'] if s['id']=='0/C8.extra.0.'+suffix)
            for state in ('initial','target'):
                rpc=t.Fake()
                for p in step[state]:rpc.set(p['target'],p['signature'],*p.get('args',[]),value=p['expected'])
                self.assertEqual(g.precheck_state(rpc,step)['status'],'initial' if state=='initial' else 'already-satisfied')
            first=step['target'][0]
            rpc.set(first['target'],first['signature'],*first.get('args',[]),value=999)
            with self.assertRaises(a.Gate) as caught:g.precheck_state(rpc,step)
            self.assertIn('observed',str(caught.exception.record))

    def test_constructor_defaults_are_not_assumed_zero(self):
        steps=self.build()['steps']
        for sid,sig,expected in [('C9.allowance','autoAllowance(address,address)',[5000*10**18,0]),
                                 ('C9.total','userTotal(address)',[5000*10**18,0]),
                                 ('C15','cachedPrice()',2**256-1)]:
            step=next(s for s in steps if s['id']=='0/'+sid)
            self.assertEqual(next(p['expected'] for p in step['initial'] if p.get('signature')==sig),expected)

    def test_eth_funding_uses_recorded_before_plus_value(self):
        for step in self.build()['steps']:
            if step['id'].endswith(('/C19','/C20')):
                self.assertEqual(step['target'][0]['expected'],step['initial'][0]['expected']+a.qty(step['tx']['value']))
