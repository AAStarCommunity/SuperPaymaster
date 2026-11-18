"""Offline regression probes for Daybreak's scoped fixes."""
import copy
import hashlib
import json
import unittest
from types import SimpleNamespace
from unittest.mock import patch
import plan_three_arm as q
import test_three_arm as fixtures

class Daybreak(unittest.TestCase):
    def test_checker_is_executed_and_exact_count_required(self):
        cfg={'commit':'a'*40,'guardianN':2,'deployer':'d','governanceOwner':'s'}
        for code,log in [(1,'SUMMARY 186 passed, 0 failed, 186 total'),(0,'SUMMARY 187 passed, 0 failed, 187 total'),(0,'SUMMARY 185 passed, 1 failed, 186 total'),(0,'PASS no summary'),(0,'SUMMARY 186 passed, 0 failed, 186 total\nSUMMARY 186 passed, 0 failed, 186 total')]:
            with self.assertRaises(q.a.Gate):
                q.run_checker('config',cfg,'rpc',10,runner=lambda *a,**k:SimpleNamespace(returncode=code,stdout=log),commit_reader=lambda:cfg['commit'])
        result=q.run_checker('config',cfg,'rpc',10,runner=lambda *a,**k:SimpleNamespace(returncode=0,stdout='PASS gate\nSUMMARY 186 passed, 0 failed, 186 total'),commit_reader=lambda:cfg['commit'])
        self.assertEqual(result['total'],186)
        self.assertNotIn('stdout',result)
    def test_dirty_or_wrong_commit_refused(self):
        with self.assertRaises(q.a.Gate):
            q.run_checker('config',{'commit':'a'*40},'rpc',10,commit_reader=lambda:'b'*40)
    def test_calibration_file_binding(self):
        path=q.ROOT/'cache/3arm/fix/evidence-test.json'
        evidence=dict(chainId=10,superPaymaster='sp',commit='a'*40,blockNumber='0x20',blockHash='0x'+'12'*32,arms={'SP':{'call':1}},setup={'C':1},ownerPreparation={'O':1},ownerMaintenance=[],bundlerMaintenance=[],safeTransactions={'C1':1})
        raw=json.dumps(evidence).encode(); path.write_bytes(raw)
        cal={k:copy.deepcopy(evidence[k]) for k in ('arms','setup','ownerPreparation','ownerMaintenance','bundlerMaintenance','safeTransactions')}
        cal['source']=dict(evidenceFile=str(path),evidenceSha256=hashlib.sha256(raw).hexdigest(),blockHash=evidence['blockHash'])
        cfg=dict(superPaymaster='sp',commit='a'*40)
        rpc=lambda *a:dict(number='0x20',hash=evidence['blockHash'])
        try:
            q.verify_calibration(cfg,cal,10,rpc)
            for key,value in [('chainId',1),('superPaymaster','fake'),('commit','b'*40),('blockHash','0x'+'34'*32),('arms',{'SP':{'call':2}})]:
                altered=dict(evidence,**{key:value}); data=json.dumps(altered).encode();path.write_bytes(data)
                changed=copy.deepcopy(cal);changed['source']['evidenceSha256']=hashlib.sha256(data).hexdigest()
                with self.assertRaises(q.a.Gate):q.verify_calibration(cfg,changed,10,rpc)
            path.write_bytes(raw+b' ')
            with self.assertRaises(q.a.Gate):q.verify_calibration(cfg,cal,10,rpc)
        finally:path.unlink()
    def test_zero_arm_limit(self):
        # Any zero limit is refused, except VPM postOp, which is structurally zero.
        for arm,field in (('VPM','call'),('TPM','postOp'),('SP','verification')):
            f=fixtures.ThreeArm();f.setUp();f.cal['arms'][arm][field]=0
            with self.assertRaises(q.a.Gate):f.build()
    def test_vpm_postop_structurally_zero(self):
        f=fixtures.ThreeArm();f.setUp();f.cal['arms']['VPM']['postOp']=0
        f.build()
        f=fixtures.ThreeArm();f.setUp();f.cal['arms']['VPM']['postOp']=5
        with self.assertRaisesRegex(q.a.Gate,'rq3_structural_zero'):f.build()
    def test_output_credentials_refused(self):
        for value in ['https://rpc.invalid/key','Bearer abcdef123456','-----BEGIN PRIVATE KEY-----','api_key=abcdef123456', {'apiKey':'abcdef123456'}]:
            with self.assertRaises(Exception):q.output_bytes({'extra':value})
    def test_normalized_output_and_funding(self):
        f=fixtures.ThreeArm();f.setUp();f.cfg['rpc']='https://rpc.invalid/secret';f.evidence['configSha256']=q.digest(f.cfg)
        result=f.build()
        self.assertNotIn('https://',json.dumps(result))
        self.assertNotIn('stdout',result['checker'])
        senders={s['tx']['from'] for s in result['steps']}|{f.cfg['governanceOwner']}
        self.assertEqual(set(result['funding']['senders']),senders)
        for who,row in result['funding']['senders'].items():
            txs=[s['tx'] for s in result['steps'] if s['tx']['from']==who]
            self.assertGreaterEqual(row['valueTotal'],sum(int(t['value'],16) for t in txs))
            self.assertEqual(row['totalRequired'],row['valueTotal']+row['maxGasCost'])
        self.assertTrue(result['funding']['tokens'])
        self.assertGreater(result['funding']['senders'][f.cfg['governanceOwner']]['maxGasCost'],0)
    def test_forged_system_address(self):
        cfg={'entryPoint':'0x'+'11'*20}
        with self.assertRaises(Exception):q.verify_system(cfg,lambda *a:'0x','0x20')

class DeploymentIdentity(unittest.TestCase):
    def test_versions_and_nonempty_code_for_every_system(self):
        cfg={k:fixtures.address(i+1) for i,k in enumerate(q.SYSTEM_SOURCES)}
        versions={}
        import re
        for key,source in q.SYSTEM_SOURCES.items():
            if source:
                text=(q.ROOT/'contracts/src'/source).read_text()
                match=re.search(r'function\s+version\s*\([^)]*\)[^{]*\{\s*return\s+"([^"\n]+)"',text)
                if match:
                    value=match[1].encode();versions[cfg[key]]='0x'+(32).to_bytes(32,'big').hex()+len(value).to_bytes(32,'big').hex()+value.hex()
        def rpc(method,params):return '0x6000' if method=='eth_getCode' else versions[params[0]['to']]
        q.verify_system(cfg,rpc,'0x20')
        for key in cfg:
            forged=dict(cfg,**{key:fixtures.address(999)})
            def fake(method,params):
                if method=='eth_getCode' and params[0]==fixtures.address(999):return '0x'
                return rpc(method,params)
            with self.assertRaises(q.a.Gate):q.verify_system(forged,fake,'0x20')
        for who in versions:
            original=versions[who];versions[who]='0x'+(32).to_bytes(32,'big').hex()+(1).to_bytes(32,'big').hex()+'78'
            with self.assertRaises(q.a.Gate):q.verify_system(cfg,rpc,'0x20')
            versions[who]=original
    def test_gate_worker_association(self):
        import gate_worker
        step=dict(id='C20',tx={'to':'legitimate'},readbacks=[])
        plan=dict(planIndex=0,steps=[step])
        bundle=dict(plans={'S':plan},steps=[dict(copy.deepcopy(step),id='0/C20')])
        self.assertEqual(gate_worker.associated_plan(bundle,0),(plan,step))
        for change in ('ordinal','tx','duplicate'):
            bad=copy.deepcopy(bundle)
            if change=='ordinal':bad['steps'][0]['id']='1/C20'
            if change=='tx':bad['steps'][0]['tx']['to']='attacker'
            if change=='duplicate':bad['plans']['other']=copy.deepcopy(plan)
            with self.assertRaises(ValueError):gate_worker.associated_plan(bad,0)

class AdditionalGates(unittest.TestCase):
    def test_safe_zero(self):
        f=fixtures.ThreeArm();f.setUp();f.cal['safeTransactions']['C1']=0
        with self.assertRaises(q.a.Gate):f.build()
    def test_configured_secret_patterns(self):
        with self.assertRaises(q.a.Gate):q.output_bytes({'x':'custom-value'},secrets=['custom-value'])
        with self.assertRaises(q.a.Gate):q.output_bytes({'x':'custom-value'},patterns=['custom-.*'])
    def test_calibration_positive_all_groups(self):
        path=q.ROOT/'cache/3arm/fix/positive-evidence.json'
        cfg={'superPaymaster':'sp','commit':'a'*40}
        base=dict(chainId=10,**cfg,blockNumber='0x20',blockHash='0x'+'12'*32,
            arms={'SP':{'call':1}},setup={'S':1},ownerPreparation={'O':1},
            ownerMaintenance=[{'name':'O','gas':1}],bundlerMaintenance=[{'name':'B','gas':1}],safeTransactions={'C1':1})
        try:
            for group in ('arms','setup','ownerPreparation','ownerMaintenance','bundlerMaintenance','safeTransactions'):
                evidence=copy.deepcopy(base)
                if group=='arms':evidence[group]['SP']['call']=0
                elif group.endswith('Maintenance'):evidence[group][0]['gas']=0
                else:evidence[group][next(iter(evidence[group]))]=0
                raw=json.dumps(evidence).encode();path.write_bytes(raw)
                cal=dict(evidence,source=dict(evidenceFile=str(path),evidenceSha256=hashlib.sha256(raw).hexdigest(),blockHash=base['blockHash']))
                with self.assertRaises(q.a.Gate):q.verify_calibration(cfg,cal,10,lambda *a:dict(number='0x20',hash=base['blockHash']))
        finally:path.unlink()

class FrozenChecker(unittest.TestCase):
    def test_checker_reads_original_block(self):
        import checker_runner as c
        for command in ('call','code','balance','storage'):
            self.assertEqual(c.pin_command(['cast',command,'address'],'0x20')[-2:],['--block','0x20'])
        self.assertEqual(c.pin_command(['cast','rpc','eth_call','{}','latest'],'0x20')[-1],'0x20')
        command=c.pin_command(['cast','rpc','eth_getLogs','{"fromBlock":"0x1","toBlock":"latest"}'],'0x20')
        self.assertEqual(json.loads(command[3])['toBlock'],'0x20')
        with self.assertRaises(ValueError):c.pin_command(['cast','rpc','eth_sendTransaction','{}'],'0x20')

class Generation(unittest.TestCase):
    def test_verified_generation_reconstructs_exact_bytes_after_head_moves(self):
        import tempfile
        import re
        f=fixtures.ThreeArm();f.setUp();f.cfg['guardianN']=2
        original=copy.deepcopy(f.rpc.head)
        for key,source in q.SYSTEM_SOURCES.items():
            if source:
                match=re.search(r'function\s+version\s*\([^)]*\)[^{]*\{\s*return\s+"([^"\n]+)"',(q.ROOT/'contracts/src'/source).read_text())
                if match:
                    value=match[1].encode()
                    f.rpc.set(f.cfg[key],'version()',value='0x'+(32).to_bytes(32,'big').hex()+len(value).to_bytes(32,'big').hex()+value.hex())
        def rpc(method,params):
            if method=='eth_getCode' and params[0] in [f.cfg[k] for k in q.SYSTEM_SOURCES]:return '0x6000'
            if method=='eth_getBlockByNumber' and params[0]==original['number']:return original
            return f.rpc(method,params)
        with tempfile.TemporaryDirectory(dir=q.ROOT/'cache/3arm/fix') as directory:
            root=q.Path(directory);evidence={k:v for k,v in f.cal.items() if k!='source'}
            evidence.update(chainId=10,superPaymaster=f.cfg['superPaymaster'],commit=f.cfg['commit'],blockNumber=original['number'],blockHash=original['hash'])
            raw=json.dumps(evidence).encode();(root/'evidence').write_bytes(raw)
            f.cal['source'].update(evidenceFile=str(root/'evidence'),evidenceSha256=hashlib.sha256(raw).hexdigest())
            f.inputs['calibration']=str(root/'calibration')
            for name,value in [('config',f.cfg),('inputs',f.inputs),('calibration',f.cal)]: (root/name).write_text(json.dumps(value))
            calls=[]
            def runner(command,**kwargs):
                calls.append(command)
                return SimpleNamespace(returncode=0,stdout='PASS offline\nSUMMARY 186 passed, 0 failed, 186 total')
            def generate(block=None):
                with patch.object(q,'load_baselines',return_value=f.bases),patch.object(q.m,'collect_phase_c',side_effect=copy.deepcopy(f.pins)):
                    return q.generate(root/'config',root/'inputs',rpc,rpc,'unused',block,runner,lambda:f.cfg['commit'])
            first=generate()
            forged=dict(f.cfg,superPaymaster=fixtures.address(999))
            (root/'config').write_text(json.dumps(forged))
            with self.assertRaises(q.a.Gate) as caught:generate()
            self.assertEqual(caught.exception.record['gate'],'rq3_system_code')
            (root/'config').write_text(json.dumps(f.cfg))
            f.rpc.head=dict(original,number='0x21',hash='0x'+'34'*32)
            f.rpc.pending=9
            self.assertEqual(first,generate(original['number']))
            self.assertTrue(all('checker_runner.py' in command[2] and command[3]=='0x20' for command in calls))

class SourceVersion(unittest.TestCase):
    def test_unparseable_version_refused(self):
        cfg={k:fixtures.address(i+1) for i,k in enumerate(q.SYSTEM_SOURCES)}
        with patch.object(q.Path,'read_text',return_value='function version() external returns (string memory) { return dynamic; }'):
            with self.assertRaises(q.a.Gate):q.verify_system(cfg,lambda *args:'0x6000','0x20')
