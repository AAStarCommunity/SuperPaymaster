import copy
import hashlib
import json
import unittest
from unittest.mock import patch
import plan_three_arm as q

class Artifacts(unittest.TestCase):
    def setUp(self):
        self.pins=q.load('script/rq3op/fixture-pins.json')
        self.cfg={'commit':self.pins['commit']}
        self.inputs={'fixturePins':'script/rq3op/fixture-pins.json',
            'baselineSha256':{n:hashlib.sha256(q.inside(p).read_bytes()).hexdigest() for n,p in q.m.BASELINE_ARTIFACTS.items()}}
    def load(self):
        with patch.object(q,'load',return_value=self.pins): return q.load_baselines(self.cfg,self.inputs)
    def test_real_separate_pins(self):
        base=self.load(); self.assertEqual(set(base),{'F1TestToken','F1Oracle','VerifyingPaymaster','TokenPaymaster'})
        self.assertEqual(base['VerifyingPaymaster']['constructor'],q.m.VPM_CONSTRUCTOR)
        self.assertEqual(base['TokenPaymaster']['constructor'],q.m.TPM_CONSTRUCTOR)
    def stop(self,gate):
        with self.assertRaises(q.a.Gate) as c:self.load()
        self.assertEqual(c.exception.record['gate'],gate)
    def test_commit(self):
        self.pins['commit']='f'*40; self.stop('rq3_fixture_commit')
    def test_fixture_artifact(self):
        self.pins['contracts']['F1Oracle']['artifactSha256']='0'*64; self.stop('rq3_fixture_artifact')
    def test_fixture_creation(self):
        self.pins['contracts']['F1Oracle']['creationKeccak']='0x'+'0'*64; self.stop('rq3_fixture_creation')
    def test_fixture_source(self):
        self.pins['sourceSha256']='0'*64; self.stop('rq3_fixture_source')
    def test_baseline_artifact(self):
        self.inputs['baselineSha256']['TokenPaymaster']='0'*64; self.stop('rq3_baseline_artifact')
    def test_fixture_runtime(self):
        self.pins['contracts']['F1TestToken']['runtimeIdentity']['ranges'][0]['start']+=1
        self.stop('rq3_fixture_runtime')
    def test_release_commit_binding(self):
        self.cfg['commit']='0'*40;self.pins['commit']=self.cfg['commit']
        self.stop('rq3_baseline_commit')

    def test_baseline_source(self):
        original=q.inside
        source=json.loads(original(q.m.BASELINE_ARTIFACTS['VerifyingPaymaster']).read_text())['source']
        class BadSource:
            def read_bytes(self): return b'changed source'
        with patch.object(q,'inside',side_effect=lambda p:BadSource() if str(p)==source else original(p)):
            self.stop('rq3_baseline_source')
    def test_baseline_constructor(self):
        original=q.inside; path=q.m.BASELINE_ARTIFACTS['VerifyingPaymaster']
        art=json.loads(original(path).read_bytes());art['abi']=[x for x in art['abi'] if x.get('type')!='constructor']
        raw=json.dumps(art).encode(); self.inputs['baselineSha256']['VerifyingPaymaster']=hashlib.sha256(raw).hexdigest()
        class BadArtifact:
            def read_bytes(self): return raw
        from types import SimpleNamespace
        real_run=q.m.subprocess.run
        def run(cmd,**kw):
            if cmd==['git','show',self.cfg['commit']+':'+path]: return SimpleNamespace(returncode=0,stdout=raw)
            return real_run(cmd,**kw)
        with patch.object(q,'inside',side_effect=lambda p:BadArtifact() if str(p)==path else original(p)),patch.object(q.m.subprocess,'run',side_effect=run):
            self.stop('rq3_baseline_constructor')
