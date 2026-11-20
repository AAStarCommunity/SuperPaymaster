"""Offline coverage for real DeployLive serialization and transaction limits."""
import unittest
import copy
import shutil
import json
from types import SimpleNamespace
from unittest.mock import patch
import test_three_arm as t
import test_artifacts as artifacts
import plan_three_arm as q

class DeployLiveInputs(unittest.TestCase):
    def setUp(self):
        self.f=t.ThreeArm(); self.f.setUp()
        f=self.f
        cfg=json.loads((q.ROOT/'script/rq3op/fixtures/attempt1.config.sepolia.json').read_text())
        replacements={f.cfg[k]:cfg[k].lower() for k in q.CONFIG_ADDRESSES}
        def remap(value):
            if isinstance(value,str):
                if value in replacements:return replacements[value]
                return value
            if isinstance(value,list):return [remap(v) for v in value]
            if isinstance(value,dict):return {k:remap(v) for k,v in value.items()}
            return value
        f.inputs=remap(f.inputs);f.pins=remap(f.pins)
        def abi(value):
            for old,new in replacements.items():value=value.replace('0'*24+old[2:],'0'*24+new[2:])
            return value
        f.rpc.values={(remap(who),abi(data)):abi(value) for (who,data),value in f.rpc.values.items()}
        f.cfg=cfg
        for pin in f.pins:pin['capped']['cap']=int(cfg['expectedCap'])
        for base in f.bases.values():base['commit']=cfg['commit']
        original=f.rpc
        original.chainId=hex(11155111)
        def rpc(method,params):
            if method=='eth_getCode' and params[0]==cfg['entryPoint'].lower():
                return (q.ROOT/'contracts/test/fixtures/entrypoint-v0.7.runtime.hex').read_text().strip()
            return original(method,params)
        f.rpc=rpc;self.transport=original
        f.evidence.update(configSha256=q.digest(cfg),commit=cfg['commit'],chainId=11155111)

    def test_checksummed_config_and_inputs(self):
        f=self.f
        for key in q.CONFIG_ADDRESSES:
            f.cfg[key]=q.a.cast('to-check-sum-address',f.cfg[key])
        for checksum in (False,True):
            f.inputs['genesis']=f.cfg['genesisOperator'] if checksum else f.cfg['genesisOperator'].lower()
            f.inputs['experiment']=q.a.cast('to-check-sum-address',f.inputs['experiment'])
            f.evidence['configSha256']=q.digest(f.cfg)
            result=f.build()
            self.assertEqual(result['configSha256'],q.digest(f.cfg))
            self.assertEqual(result['shared']['SP'],f.cfg['superPaymaster'].lower())

    def test_genesis_case_and_identity(self):
        f=self.f
        f.cfg['genesisOperator']='0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed'
        f.evidence['configSha256']=q.digest(f.cfg)
        for genesis in (f.cfg['genesisOperator'],f.cfg['genesisOperator'].lower()):
            f.inputs['genesis']=genesis
            q.check_inputs(f.cfg,f.inputs,f.evidence)
        f.inputs['genesis']=t.address(999)
        f.stop('rq3_genesis',lambda:q.check_inputs(f.cfg,f.inputs,f.evidence))

    def test_recipient_and_extra_addresses_get_the_same_checksum_rule(self):
        # The SDK account enters the planner through these two lists (DSR review of fc59e8d3).
        good='0xE8Eaad6A4802300F33E53c40e65863CCcDA6898b'
        bad=good[:-1]+('B' if good[-1]=='b' else 'b')  # flips one letter's case: an invalid EIP-55 checksum
        for field,entry in (('taskRecipients',dict(address=bad,amount=301)),('extraEndUsers',dict(address=bad,xAmount=1))):
            with self.subTest(field=field):
                cfg,inputs=copy.deepcopy(self.f.cfg),copy.deepcopy(self.f.inputs)
                inputs[field]=[entry]
                with self.assertRaises(q.a.Gate) as caught: q.normalized_addresses(cfg,inputs)
                self.assertEqual(caught.exception.record['gate'],'rq3_address')
        for value in (good,good.lower()):
            cfg,inputs=copy.deepcopy(self.f.cfg),copy.deepcopy(self.f.inputs)
            inputs['taskRecipients']=[dict(address=value,amount=301)]; inputs['extraEndUsers']=[dict(address=value,xAmount=1)]
            _,out=q.normalized_addresses(cfg,inputs)
            self.assertEqual(out['taskRecipients'][0]['address'],good.lower())
            self.assertEqual(out['extraEndUsers'][0]['address'],good.lower())

    def test_fresh_address_keys_never_collide_silently(self):
        low='0xe8eaad6a4802300f33e53c40e65863cccda6898b'; mixed='0xE8Eaad6A4802300F33E53c40e65863CCcDA6898b'
        self.assertEqual(q.m.fresh_addresses({mixed:1,'other':2}),{low:1,'other':2})
        with self.assertRaises(q.a.Gate) as caught: q.m.fresh_addresses({low:1,mixed:2})
        self.assertEqual(caught.exception.record['gate'],'fresh_address_key_collision')
        with self.assertRaises(q.a.Gate): q.m.fresh_addresses({'x':[{low:1,mixed:2}]})

    def test_wrong_checksum(self):
        self.f.cfg['gToken']='0x52908400098527886E0F7030069857D2E4169Ee7'
        self.f.evidence['configSha256']=q.digest(self.f.cfg)
        self.f.stop('rq3_address',self.f.build)

    def test_decimal_cap(self):
        self.assertIsInstance(self.f.cfg['expectedCap'],str)
        self.f.evidence['configSha256']=q.digest(self.f.cfg)
        self.f.build()

    def test_invalid_caps(self):
        for value in ('1','-1',' 1','1 ','1.0',1.0,-1,str(2**256),'١'):
            with self.subTest(value=value):
                self.f.cfg['expectedCap']=value
                self.f.evidence['configSha256']=q.digest(self.f.cfg)
                self.f.stop('rq3_cap_headroom',self.f.build)

    def test_transaction_cap(self):
        f=self.f; f.inputs['gasFactor']={'numerator':1,'denominator':1}
        f.cal['setup']['C14']=30000000
        f.build()
        f.cal['setup']['C14']+=1
        with self.assertRaises(q.a.Gate) as caught:f.build()
        self.assertIn('C14',str(caught.exception.record))
        self.assertIn('rq3_transaction_gas',str(caught.exception.record))

    def test_registered_stricter_cap(self):
        f=self.f; f.inputs['gasFactor']={'numerator':1,'denominator':1}
        f.cal['setup']['C14']=20000001
        original=q.json.loads
        def caps(value, *args, **kwargs):
            if value == (q.Path(q.__file__).with_name('tx-gas-caps.json')).read_text():
                return {'11155111': {'gasLimit':20000000,'source':'offline test parameter'}}
            return original(value,*args,**kwargs)
        with patch.object(q.json,'loads',side_effect=caps):
            with self.assertRaises(q.a.Gate) as caught:f.build()
        self.assertIn('rq3_transaction_gas/0/C14',str(caught.exception.record))

    def test_auxiliary_caps(self):
        for category in ('ownerPreparation','ownerMaintenance','bundlerMaintenance','safeTransactions','arms'):
            with self.subTest(category=category):
                self.setUp(); f=self.f
                values=f.cal[category]
                if category=='arms':values['TPM']['outer']=30000001
                elif isinstance(values,list):values[0]['gas']=30000001
                else:values[next(iter(values))]=30000001
                with self.assertRaises(q.a.Gate) as caught:f.build()
                self.assertIn('rq3_transaction_gas',str(caught.exception.record))

    def test_unregistered_chain(self):
        for chain in (10,11155420,31337):
            self.transport.chainId=hex(chain);self.f.evidence['chainId']=chain
            self.f.build()

    def test_local_chain_has_its_own_cap(self):
        self.transport.chainId=hex(31337);self.f.evidence['chainId']=31337
        self.f.inputs['gasFactor']={'numerator':1,'denominator':1}
        self.f.cal['setup']['C14']=20000000
        self.f.build()

    def test_recipient_and_extra_boundary(self):
        who=self.f.cfg['priceFeed'] if 'priceFeed' in self.f.cfg else '0x694AA1769357215DE4FAC081bf1f309aDC325306'
        self.f.inputs['taskRecipients']=[dict(address=who,amount=301)]
        self.f.inputs['extraEndUsers']=[dict(address=who,xAmount=1)]
        cfg,inputs=q.check_inputs(self.f.cfg,self.f.inputs,self.f.evidence)
        self.assertEqual(inputs['taskRecipients'][0]['address'],who.lower())
        self.assertEqual(inputs['extraEndUsers'][0]['address'],who.lower())

    def test_chain_address_readbacks(self):
        for pin in self.f.pins:
            for group,key in [('capped','minter'),('owner','address'),('account','counterfactual'),
                              ('account','implementationEntryPoint'),('account','implementation')]:
                pin[group][key]=q.a.cast('to-check-sum-address',pin[group][key])
        self.f.build()

    def test_all_principals_and_accounts_are_normalized(self):
        f=self.f
        for key in ('experiment','genesis','bundler','verifyingSigner'):
            f.inputs[key]=q.a.cast('to-check-sum-address',f.inputs[key])
        for account in f.inputs['accounts']:
            for key in ('account','accountOwner','accountImplementation'):
                account[key]=q.a.cast('to-check-sum-address',account[key])
        result=f.build()
        for plan in result['plans'].values():
            c=plan['externalInputs']['data']['phaseC']
            for key in ('account','accountOwner','accountImplementation','bundler','verifyingSigner'):
                self.assertEqual(c[key],c[key].lower())

    def test_recipient_execution_uses_one_canonical_key(self):
        f=self.f;who='0x694AA1769357215DE4FAC081bf1f309aDC325306'
        amount=f.build()['shared']['sdkLive']['perUserFloor']
        f.inputs['taskRecipients']=[dict(address=who,amount=301)]
        f.inputs['extraEndUsers']=[dict(address=who.lower(),xAmount=amount)]
        f.cal['setup'].update({'C11.extra.0':100000,
            **{f'C8.extra.0.{suffix}':100000 for suffix in ('approve','role','mint')}})
        result=f.build()
        self.assertEqual(result['shared']['recipientPurposes'],{who.lower():['task recipient','RQ2 live E2E']})
        self.assertEqual(result['shared']['taskRecipients'][0]['address'],who.lower())

    def test_fresh_manifest_pin_boundary(self):
        f=self.f;account=f.inputs['accounts'][0]
        c=dict(account,bundler=f.inputs['bundler'],verifyingSigner=f.inputs['verifyingSigner'])
        pin=dict(phaseC=copy.deepcopy(f.pins[0]),immutables=dict(entryPoint=f.cfg['entryPoint']))
        pin['phaseC']['capped']['minter']=f.cfg['governanceOwner']
        pin['phaseC']['account']['implementationEntryPoint']=f.cfg['entryPoint']
        q.m.phase_c_pin_gates(pin,c,context=dict(fresh=True,safe=f.cfg['governanceOwner'].lower()))

class FixtureHistory(unittest.TestCase):
    def fixture(self):
        f=artifacts.Artifacts();f.setUp()
        f.cfg=json.loads((q.ROOT/'script/rq3op/fixtures/attempt1.config.sepolia.json').read_text())
        f.cfg['commit']=f.pins['commit']
        return f

    def test_real_ancestor(self):
        f=self.fixture()
        f.cfg['commit']=q.m.subprocess.run(['git','rev-parse','HEAD'],cwd=q.ROOT,capture_output=True,text=True,check=True).stdout.strip()
        runner=q.m.subprocess.run
        with patch.object(q.m.subprocess,'run',wraps=runner) as run:
            f.load()
        self.assertTrue(any(call.args[0]==['git','merge-base','--is-ancestor',f.pins['commit'],f.cfg['commit']] for call in run.call_args_list))

    def test_unknown_commit(self):
        f=self.fixture();f.pins['commit']='f'*40
        f.stop('rq3_fixture_commit')

    def test_descendant_is_not_ancestor(self):
        f=self.fixture()
        f.pins['commit']=q.m.subprocess.run(['git','rev-parse','HEAD'],cwd=q.ROOT,capture_output=True,text=True,check=True).stdout.strip()
        self.assertNotEqual(f.pins['commit'],f.cfg['commit'])
        f.stop('rq3_fixture_commit')

    def test_malformed(self):
        f=self.fixture();f.pins['commit']='nope'
        f.stop('rq3_fixture_commit')
