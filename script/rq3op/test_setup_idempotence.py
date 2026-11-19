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
            target=copy.deepcopy(step['target'])
            for p in target:
                if p['kind']=='eta':p['expected']=123+p['delay']
            for state in ('initial','target','unlogged-target','partial','logged-initial'):
                with self.subTest(step=step['id'],state=state):
                    source=step['initial'] if state in ('initial','logged-initial') else target
                    completion=dict(timestamp=123) if state in ('target','logged-initial') else None
                    def read(rpc,p):
                        match=next((x for x in source if g.predicate_key(x)==g.predicate_key(p)),None)
                        return copy.deepcopy(match['expected']) if match and state!='partial' else 'unexpected'
                    from unittest.mock import patch
                    with patch.object(g,'observe',side_effect=read):
                        same=step['initial']==target
                        if state in ('partial','unlogged-target') or (not same and state=='logged-initial'):
                            with self.assertRaises(a.Gate):g.precheck_state(None,step,completion)
                        else:
                            result=g.precheck_state(None,step,completion)
                            self.assertEqual(result['status'],'already-satisfied' if completion is not None else 'initial')

    def test_projected_operator_and_noop_nonce(self):
        bundle=self.build(); steps=bundle['steps']
        deploy=next(s for s in steps if s['id']=='0/C3.deploy')
        operator=next(p for p in deploy['initial'] if p.get('signature')=='operators(address)')
        deposit=next(s for s in steps if s['id']=='0/C2.deposit')
        self.assertEqual(operator['expected'][m.OP['aPNTsBalance']],deposit['target'][0]['expected'])
        self.assertFalse(any(s['id'].endswith('/C9.mode') for s in steps))
        self.assertTrue(all(s['initial']!=s['target'] for s in steps+bundle['safeTransactions']))
        for sender in {s['tx']['from'] for s in steps}:
            nonces=[int(s['tx']['nonce'],16) for s in steps if s['tx']['from']==sender]
            self.assertEqual(nonces,list(range(nonces[0],nonces[0]+len(nonces))))

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
                self.assertEqual(g.precheck_state(rpc,step,{} if state=='target' else None)['status'],'initial' if state=='initial' else 'already-satisfied')
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
