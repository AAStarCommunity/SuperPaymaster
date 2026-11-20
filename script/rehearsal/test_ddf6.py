"""Offline deploy-day regression tests; process and RPC boundaries are mocked."""
import contextlib
import copy
import hashlib
import io
import json
import sys
import unittest
from types import SimpleNamespace
from unittest.mock import patch
import test_ddf5 as previous
import deploylive_controls as c
import deploylive_deploy_day as d
import deploylive_fork_deploy as f
import deploylive_rehearse as r
import dvt_pop_to_guardians as converter


class Ddf6Test(unittest.TestCase):
    setUp = previous.Ddf5Test.setUp
    driver = previous.Ddf5Test.driver

    def convert(self):
        c.write_manifest(self.env,self.root)
        export=self.root/'dvt-export.json'; export.write_text('{}')
        with patch.object(sys,'argv',['convert',str(export),str(self.root/'pop-request.json'),'--sp-root','.', '--inputs','unused']), patch.object(c,'load_inputs',return_value=self.env), patch.object(converter,'convert',return_value='0x00'), patch.object(converter.shutil,'which',return_value='cast'), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(converter.main(),0)

    def test_conversion_binds_all_inputs(self):
        self.convert()
        record=json.loads((self.root/'conversion.json').read_text())
        self.assertEqual(record['manifest'],c.manifest_digest(self.root))
        for key,name in [('export','dvt-export.json'),('request','pop-request.json'),('guardians','guardians.hex')]:
            self.assertEqual(record[key+'Sha256'],hashlib.sha256((self.root/name).read_bytes()).hexdigest())

    def test_guardians_swap_before_any_forge(self):
        original=c.write_conversion
        def swapped(*args):
            # Run the converter after the driver has assembled its approved inputs.
            with patch.object(c,'write_conversion',side_effect=original): self.convert()
            (self.root/'guardians.hex').write_text('0xdead')
        with patch.object(c,'write_conversion',side_effect=swapped):
            with self.assertRaisesRegex(RuntimeError,'conversion'): self.driver()
        self.assertEqual(self.calls,[])

    def test_guardians_swap_before_final_and_broadcast(self):
        for phase in (1,2):
            def mutate(plan,index):
                if index == phase: (self.root/'guardians.hex').write_text('0xdead')
            with self.assertRaisesRegex(RuntimeError,'conversion'):
                self.driver(mutate)
            self.assertEqual(len(self.calls),phase)
            self.assertFalse(any('--broadcast' in argv for argv in self.calls))

    def test_transaction_type_swap(self):
        plan=json.loads(previous.FIX.read_text()); bad=copy.deepcopy(plan)
        bad['transactions'][0]['transactionType']='CALL'
        self.assertTrue(c.plan_diff(plan,bad))
        bad=copy.deepcopy(plan); bad['transactions'][0]['transaction']['type']='0x1'
        self.assertTrue(c.plan_diff(plan,bad))

    def test_nonce_gap_even_when_both_plans_agree(self):
        plan=json.loads(previous.FIX.read_text())
        plan['transactions'][1]['transaction']['nonce']='0x99'
        self.assertTrue(c.plan_diff(plan,plan))

    def test_gated_plan_replaced_after_pass(self):
        self.driver()
        (self.root/'gated-plan.json').write_text('{}')
        with self.assertRaisesRegex(RuntimeError,'gated plan'):
            c.archive(self.root,self.root.parent/(self.root.name+'-archive'))

    def test_gated_plan_replaced_before_pass(self):
        original=c.write_success
        def replaced(*args):
            (self.root/'gated-plan.json').write_text('{}')
            return original(*args)
        with patch.object(c,'write_success',side_effect=replaced):
            with self.assertRaisesRegex(RuntimeError,'gated plan'): self.driver()
        self.assertFalse((self.root/'checker.PASS.json').exists())

    def test_digest_in_all_records(self):
        self.driver()
        plan=json.loads((self.root/'gated-plan.json').read_text())
        digest=hashlib.sha256(json.dumps(plan,sort_keys=True,separators=(',',':')).encode()).hexdigest()
        for name in ('prebroadcast.diff.json','postbroadcast.diff.json','checker.PASS.json'):
            self.assertEqual(json.loads((self.root/name).read_text())['gatedPlanSha256'],digest)

    def test_rehearsal_checker_no_url_argv_and_scan_before_write(self):
        url='http://127.0.0.1:8545'
        with patch.object(r.subprocess,'run',return_value=SimpleNamespace(stdout='ok',stderr='',returncode=0)) as run:
            r.run_checker(url,self.root/'config.json','sender','owner',self.root,{})
            self.assertFalse(any(url in arg for arg in run.call_args.args[0]))
            self.assertEqual(run.call_args.kwargs['env']['ETH_RPC_URL'],url)
        (self.root/'checker.log').unlink()
        with patch.object(r.subprocess,'run',return_value=SimpleNamespace(stdout=url,stderr='',returncode=0)):
            with self.assertRaises(RuntimeError): r.run_checker(url,self.root/'config.json','sender','owner',self.root,{})
        self.assertFalse((self.root/'checker.log').exists())

    def test_gas_equal_and_inside_range(self):
        plan=json.loads(previous.FIX.read_text())
        limits=[int(t['transaction']['gas'],16) for t in plan['transactions']]
        bounds=d.gas_bounds([100]*len(limits),max(limits)+100, chain=11155111)
        for changed in (False,True):
            def mutate(obj,index):
                if changed and index==3: obj['transactions'][0]['transaction']['gas']=hex(limits[0]+1)
            output=io.StringIO()
            with contextlib.redirect_stdout(output):
                self.driver(mutate, bounds=bounds)
            self.assertIn('limit(s) differ from the gated plan, all inside the gated range' if changed else 'GAS post-broadcast limits equal to gated plan',output.getvalue())
            gas=json.loads((self.root/'postbroadcast.gas.json').read_text())
            self.assertEqual(len(gas),int(changed))
            if changed: self.assertEqual(gas[0],dict(index=0,gated=limits[0],broadcast=limits[0]+1,range=bounds[0]))

    def test_gas_outside_range_and_reservoir(self):
        plan=json.loads(previous.FIX.read_text())
        cap=2**24
        for real,limit in [(100,99),(100,30_000_001),(int(cap*.9)+1,cap)]:
            bounds=d.gas_bounds([real]*len(plan['transactions']),30_000_000, chain=11155111)
            bad=copy.deepcopy(plan); bad['transactions'][0]['transaction']['gas']=hex(limit)
            self.assertTrue(any('index=0 gas outside' in item for item in c.plan_diff(plan,bad,bounds)))
