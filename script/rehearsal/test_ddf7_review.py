"""Round-seven review regressions; all external execution is faked."""
import contextlib
import sys
import hashlib
import io
import json
import os
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import deploylive_controls as c
import deploylive_fork_deploy as f
import test_ddf5 as prev


class ReviewTest(unittest.TestCase):
    setUp = prev.Ddf5Test.setUp
    driver = prev.Ddf5Test.driver

    def test_stop_shorter_sequence(self):
        out = io.StringIO()
        with contextlib.redirect_stdout(out): self.driver(chain=31337, stop=True)
        self.assertIn('PREPARED', out.getvalue())
        self.assertEqual([e['DEPLOYLIVE_STOP_BEFORE_BOOTSTRAP'] for e in self.script_envs], ['0','0','1','1'])
        self.assertEqual(json.loads((self.root/'postbroadcast.diff.json').read_text())['diff'], [])
        self.assertFalse((self.root/'checker.PASS.json').exists())
        self.assertEqual(len(json.loads((self.root/'gated-plan.json').read_text())['transactions']),97)
        self.assert_alias_envs()

    def test_stop_changed_prefix_refused_before_broadcast(self):
        def change(p): p['transactions'][0]['transaction']['input']='0xbad'
        with self.assertRaisesRegex(RuntimeError, 'stop simulation differs'):
            self.driver(chain=31337,stop=True,stopped_mutate=change)
        self.assertFalse(any('--broadcast' in a for a in self.calls))

    def test_stop_requires_bootstrap_tail(self):
        def change(p, n):
            if n <= 2: p['transactions'][-1]['contractName']='Other'
        with self.assertRaisesRegex(RuntimeError, 'bootstrap tail'):
            self.driver(chain=31337,stop=True,mutate=change)
        self.assertFalse(any('--broadcast' in a for a in self.calls))

    def assert_alias_envs(self):
        for env in self.script_envs:
            self.assertEqual(env['DEPLOYLIVE_FORGE_RPC_URL'],'https://primary.alchemy.com/key')
            self.assertNotIn('ETH_RPC_URL',env)

    def test_all_deploy_envs(self):
        self.driver()
        self.assertEqual(len(self.script_envs),3)
        self.assert_alias_envs()

    def test_predict_env(self):
        env={key:'value' for key in c.input_keys() if not key.endswith('_FILE')}
        env.update(self.env,DEPLOYLIVE_RPC='primary',ETH_RPC_URL='stale',DEPLOYLIVE_PRICE_SOURCE='chain',FOUNDRY_VERBOSITY='2',REHEARSAL_BLS_SCALARS='[]')
        second = self.root/'predict-second-rpc'
        second.write_text('https://secondary.infura.io/key')
        env.update(DEPLOYLIVE_EXPECTED_CHAIN_ID='11155111', DEPLOYLIVE_ENDPOINT_PROVIDER='Alchemy',
                   DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER='Infura', DEPLOYLIVE_RPC='https://primary.alchemy.com/key',
                   DEPLOYLIVE_SECOND_RPC=second.read_text(), DEPLOYLIVE_SECOND_RPC_FILE=str(second), CAST_1_7_1=sys.executable)
        captured=[]
        def predict(argv, **kw):
            captured.append(kw['env'])
            (self.root/f.REQUEST_PATH).write_text('{}')
            return SimpleNamespace(returncode=0,stdout='',stderr='')
        with patch('deploylive_cast.stable_cast', return_value=True), patch.dict(os.environ,env,clear=True), patch.object(f,'ROOT',self.root), patch.object(f,'clean_source_commit',return_value='a'*40), patch.object(f,'verify_build',return_value='forge'), patch.object(f,'config_path',return_value=self.root/'config.json'), patch.object(f.subprocess,'run',side_effect=predict):
            f.stage('predict',['--production','--evidence',str(self.root)])
        self.assertEqual(len(captured),1)
        self.script_envs=captured; self.assert_alias_envs()

    def test_destination_symlink(self):
        self.driver()
        victim=self.root.parent/(self.root.name+'-victim'); victim.write_bytes(b'untouched')
        self.addCleanup(victim.unlink)
        (self.root/'config.test.json').symlink_to(victim)
        with self.assertRaisesRegex(RuntimeError,'symlink'): c.archive_records(self.root)
        self.assertEqual(victim.read_bytes(),b'untouched')

    def test_record_symlink(self):
        self.driver()
        config=self.root/'config.json'; config.rename(self.root/'original')
        config.symlink_to(self.root/'original')
        with self.assertRaisesRegex(RuntimeError,'missing deployment record'): c.archive_records(self.root)

    def test_config_changed_after_pass(self):
        self.driver()
        (self.root/'config.json').write_text('{"changed":true}')
        with self.assertRaisesRegex(RuntimeError,'deployment record changed since PASS'):
            c.archive(self.root,self.root.parent/(self.root.name+'-archive'))

    def test_export_swapped_after_convert(self):
        c.write_manifest(self.env,self.root)
        c.write_conversion(self.root,b'{}',(self.root/'pop-request.json').read_bytes(),b'0x00')
        (self.root/'dvt-export.json').write_text('{"swapped":true}')
        with self.assertRaisesRegex(RuntimeError,'conversion digest mismatch: dvt-export'): c.verify_conversion(self.env,self.root)

    def test_conversion_reads_guardians_once(self):
        c.write_manifest(self.env,self.root)
        c.write_conversion(self.root,b'{}',(self.root/'pop-request.json').read_bytes(),b'0x00')
        original=Path.open; reads=[]
        def opened(p,*a,**kw):
            if p == self.root/'guardians.hex': reads.append(p)
            return original(p,*a,**kw)
        with patch.object(Path,'open',opened): self.assertEqual(c.verify_conversion(self.env,self.root),'0x00')
        self.assertEqual(len(reads),1)

    def test_archive_records_reads_once(self):
        self.driver()
        original=Path.read_bytes
        config=self.root/'config.json'
        approved=config.read_bytes()
        def read(p):
            data=original(p)
            if p == config: p.write_bytes(b'changed after read')
            return data
        with patch.object(Path,'read_bytes',read): c.archive_records(self.root)
        self.assertEqual((self.root/'config.test.json').read_bytes(),approved)

    def test_archive_uses_hashed_snapshot(self):
        self.driver()
        dest=self.root.parent/(self.root.name+'-archive')
        self.addCleanup(lambda: __import__('shutil').rmtree(dest,ignore_errors=True))
        original=Path.read_bytes; reads={}
        def read(p):
            if p.is_relative_to(self.root): reads[p]=reads.get(p,0)+1
            return original(p)
        with patch.object(Path,'read_bytes',read): c.archive(self.root,dest)
        self.assertEqual(reads[self.root/'guardians.hex'],1)
        for line in (dest/'SHA256SUMS').read_text().splitlines():
            digest,name=line.split('  ',1)
            self.assertEqual(hashlib.sha256((dest/name).read_bytes()).hexdigest(),digest)

    def test_url_before_broadcast_refused(self):
        with self.assertRaisesRegex(RuntimeError,'refusing write'):
            self.driver(output=lambda a:'https://example.invalid/secret')
        self.assertFalse(any('--broadcast' in a for a in self.calls))

    def test_url_after_broadcast_keeps_diff(self):
        def mutate(p,n):
            if n == 3: p['transactions'][0]['transaction']['input']='0xbad'
        with self.assertRaisesRegex(RuntimeError,'post-broadcast diff'):
            self.driver(mutate,output=lambda a:'sent https://example.invalid/secret' if '--broadcast' in a else '')
        self.assertTrue((self.root/'REDACTED_AFTER_BROADCAST').is_file())
        self.assertNotIn('https://',(self.root/'forge.stdout.log').read_text())
        self.assertTrue(json.loads((self.root/'postbroadcast.diff.json').read_text())['diff'])

    def test_url_after_broadcast_continues(self):
        self.driver(output=lambda a:'sent https://example.invalid/secret' if '--broadcast' in a else '')
        self.assertTrue((self.root/'REDACTED_AFTER_BROADCAST').is_file())
        self.assertTrue((self.root/'checker.PASS.json').is_file())

    def test_handoff_type_claim_removed(self):
        self.assertFalse('envelope type' in (c.ROOT/'script/rehearsal/DEPLOYLIVE_HANDOFF.md').read_text())

    def test_hash_threat_model(self):
        for name in ('DEPLOYLIVE_HANDOFF.md','deploylive_controls.py'):
            text=(c.ROOT/'script/rehearsal'/name).read_text()
            self.assertTrue('drift checks' in text, name)
            self.assertTrue("operator's machine" in text, name)
