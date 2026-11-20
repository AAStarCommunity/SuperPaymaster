import copy
import json
import unittest
from unittest.mock import patch
import test_three_arm as t
from test_three_arm import q, a
import setup_state as g

class Round5(unittest.TestCase):
    setUp=t.ThreeArm.setUp
    build=t.ThreeArm.build
    def test_target_without_completion_stops(self):
        p=dict(kind='balance',target=t.address(1),expected=10)
        step=dict(id='C20',initial=[dict(p,expected=0)],target=[p])
        with patch.object(g,'observe',return_value=10):
            with self.assertRaises(a.Gate): g.precheck_state(None,step)
    def test_completed_eta(self):
        p=dict(kind='eta',target=t.address(1),signature='cachedPriceTimestamp()',delay=0)
        step=dict(id='C15',initial=[dict(p,expected=0)],target=[p])
        with patch.object(g,'observe',return_value=123):
            self.assertEqual(g.precheck_state(None,step,dict(timestamp=123))['status'],'already-satisfied')
    def test_sdk_limits(self):
        for key,value in [('sdkRuns',10001),('sdkMaxCostPerOp',10**18+1)]:
            self.setUp();self.inputs[key]=value
            with self.assertRaises(a.Gate):self.build()
    def test_old_alias_refused(self):
        self.inputs['priceHeadroomBPS']=1000
        self.inputs['sdkPriceHeadroomBPS']=1000
        with self.assertRaises(a.Gate):self.build()
    def test_derived_exclusions(self):
        bundle=self.build()
        for who in set(v for p in bundle['plans'].values() for v in p['phaseC']['addresses'].values() if isinstance(v,str) and v.startswith('0x') and len(v)==42):
            self.inputs['extraEndUsers']=[dict(address=who,xAmount=bundle['shared']['sdkLive']['perUserFloor'])]
            self.cal['setup'].update({f'C8.extra.0.{s}':100000 for s in ('approve','role','mint')})
            with self.subTest(who=who),self.assertRaises(a.Gate):self.build()
    def test_fee_vectors(self):
        vectors=json.loads((q.ROOT/'script/fee-rule-vectors.json').read_text())
        for v in vectors:
            with self.subTest(v=v['name']):
                self.assertEqual(q.fees_within_rule(v['fees'],v['rule'],v['current']),v['valid'])

    def test_sdk_downstream_allowance_budget(self):
        self.inputs['sdkRuns']=10000
        self.inputs['sdkMaxCostPerOp']=10**18
        with self.assertRaises(a.Gate):self.build()

    def test_sdk_product_overflow(self):
        pc=self.build()['plans'][self.inputs['accounts'][0]['account']]['phaseC']
        pc['priceCap']=2**256
        self.inputs['sdkMaxCostPerOp']=10**18
        with self.assertRaises(a.Gate):q.sdk_live(self.inputs,pc)

    def test_unlogged_noop_target_stops(self):
        p=dict(kind='balance',target=t.address(1),expected=10)
        step=dict(id='noop',initial=[p],target=[p])
        with patch.object(g,'observe',return_value=10):
            with self.assertRaises(a.Gate):g.precheck_state(None,step)
