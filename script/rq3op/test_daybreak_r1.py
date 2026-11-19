"""Round 3 offline refusal and exact arithmetic regressions."""
import copy
import json
import unittest
from unittest.mock import patch
import test_three_arm as t
from test_three_arm import q, a, m, address

class Round3(unittest.TestCase):
    setUp=t.ThreeArm.setUp
    build=t.ThreeArm.build
    stop=t.ThreeArm.stop

    def test_sdk_required_integer_inputs(self):
        for key in ('sdkRuns','sdkMaxOps','sdkMaxCostPerOp'):
            for value in (None,False,0,-1,1.5,'1'):
                with self.subTest(key=key,value=value):
                    self.setUp()
                    if value is None:self.inputs.pop(key,None)
                    else:self.inputs[key]=value
                    self.stop('rq3_sdk_inputs',self.build)
        self.setUp();self.inputs['sdkMaxOps']=33
        self.stop('rq3_sdk_inputs',self.build)

    def test_all_config_and_input_addresses_excluded(self):
        for who in list(self.cfg[k] for k in q.CONFIG_ADDRESSES)+[address(890),address(891)]:
            self.setUp()
            self.cfg['futureSystem']={'nested':[address(890)]}
            self.evidence['configSha256']=q.digest(self.cfg)
            self.inputs['futureRole']={'nested':[address(891)]}
            self.inputs['extraEndUsers']=[dict(address=who.upper().replace('0X','0x'),xAmount=1)]
            self.stop('rq3_extra_endusers',self.build)

    def test_malformed_amounts(self):
        for value in (True,-1,0,1.5,'1','1e18',10**100):
            self.inputs['extraEndUsers']=[dict(address=address(900),xAmount=value)]
            self.stop('rq3_extra_endusers',self.build)

    def test_sdk_status_cleared_only_with_cost_cap_commit(self):
        live=self.build()['shared']['sdkLive']
        self.assertTrue(live['status'].startswith('provisional'))
        self.assertIsNone(live['sdkCostCapCommit'])
        self.inputs['sdkCostCapCommit']='a'*40
        live=self.build()['shared']['sdkLive']
        self.assertEqual(live['status'],'cleared')
        self.assertEqual(live['sdkCostCapCommit'],'a'*40)
        for bad in ('A'*40,'a'*39,'xyz',40):
            self.inputs['sdkCostCapCommit']=bad
            with self.subTest(bad=bad): self.stop('rq3_sdk_cost_cap_commit',self.build)

    def test_sdk_bounds_and_aggregate(self):
        live=self.build()['shared']['sdkLive']
        self.assertEqual(live['opsPerUser'],self.inputs['sdkRuns']*(4+self.inputs['sdkMaxOps']))
        self.assertEqual(live['perUserFloor'],(live['opsPerUser']+1)*live['Xmax'])
        self.assertEqual(live['perUserCap'],(live['opsPerUser']+m.PC_BETA)*live['Xmax'])
        for amount in (live['perUserFloor']-1,live['perUserCap']+1):
            self.inputs['extraEndUsers']=[dict(address=address(900),xAmount=amount)]
            self.cal['setup'].update({f'C8.extra.0.{s}':100000 for s in ('approve','role','mint')})
            self.stop('rq3_sdk_amount',self.build)
        self.inputs['extraEndUsers']=[dict(address=address(900+i),xAmount=amount) for i,amount in enumerate((live['perUserFloor'],live['perUserCap']))]
        self.cal['setup'].update({f'C8.extra.{i}.{s}':100000 for i in range(2) for s in ('approve','role','mint')})
        b=self.build()
        self.assertEqual(b['shared']['extraEndUsersXTotal'],live['perUserFloor']+live['perUserCap'])
        for plan in b['plans'].values():
            for key in ('priceCap','priceDecimals','aPNTsPriceUSD','protocolFeeBPS','validationBufferBPS','exchangeRate'):
                self.assertEqual(live[key],plan['phaseC'][key])

    def test_shared_vector(self):
        v=json.loads((q.ROOT/'script/rq3op/sdk-cost-vector.json').read_text())
        self.assertEqual(q.cost_bounds(**v['inputs']),tuple(int(v[k]) for k in ('a0','Amax','Xmax')))

    def test_shared_unsafe_integer_vector(self):
        # Above 2^53 with a non-zero low bit (DSR 2026-11-19): Python ints are exact; the JS side is pinned in
        # script/a6-collector/unsafe-integer.test.mjs.
        v=json.loads((q.ROOT/'script/rq3op/sdk-cost-vector.json').read_text())['unsafeIntegerVector']
        self.assertGreater(int(v['inputs']['maxCost']),2**53)
        self.assertEqual(q.cost_bounds(**v['inputs']),tuple(int(v[k]) for k in ('a0','Amax','Xmax')))
        # The planner serializes it as a JSON number whose digits are exactly the decimal string.
        text=json.dumps({'maxCostPerOpWei':int(v['inputs']['maxCost'])})
        self.assertIn(v['inputs']['maxCost'],text)

    def test_pin_schema(self):
        for mutate in (lambda p:p.update(extra=1),lambda p:p.pop('codehash'),lambda p:p.update(codehash=''),
                       lambda p:p.update(version='0.6'),lambda p:p.update(chainIds=[1]),lambda p:p.update(chainIds=[10,10,11155111])):
            pin=copy.deepcopy(q.ENTRYPOINT_PIN);mutate(pin)
            with patch.object(q,'ENTRYPOINT_PIN',pin):self.stop('rq3_entrypoint_schema',self.build)

    def test_release_and_fee_sources_agree(self):
        limits=json.loads((q.ROOT/'script/fee-limits.json').read_text())
        self.assertEqual(q.MAX_FEE,int(limits['MAX_FEE']))
        self.assertEqual(q.MAX_FEE,a.MAX_FEE)
        release=json.loads((q.ROOT/'docs/release/rq3-runtime-expectations.json').read_text())
        source=(q.ROOT/release['source']).read_text()
        import re
        self.assertEqual(int(re.search(r'GP_MINPOST_MIN = ([\d_]+)',source)[1].replace('_','')),release['GP_MINPOST_MIN'])

    def test_pin_missing_malformed_and_empty_fields(self):
        from tempfile import TemporaryDirectory
        from pathlib import Path
        with TemporaryDirectory() as directory:
            path=Path(directory)/'pin.json'
            for raw in (None,'{', '{}',json.dumps(dict(q.ENTRYPOINT_PIN,source=''))):
                if raw is not None:path.write_text(raw)
                with self.assertRaises((OSError,ValueError,a.Gate)):q.load_entrypoint_pin(path)

    def test_send_refuses_factor_drift(self):
        plan=t.SendGates.ready(self)
        plan['phaseC']['feeCap']+=1
        self.stop('rq3_send_fee',lambda:q.pre_send(self.rpc,plan))
