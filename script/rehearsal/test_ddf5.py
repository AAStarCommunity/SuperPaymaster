"""Deploy-day binding checks, offline against the complete acceptance broadcast."""
import copy
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch, Mock
import deploylive_controls as c
import deploylive_fork_deploy as f
import deploylive_deploy_day as d

FIX = Path(__file__).parent/'fixtures/deploy-day/broadcast-97.json'

class Ddf5Test(unittest.TestCase):
    def setUp(self):
        base=c.ROOT/'cache/ddf5'; base.mkdir(parents=True, exist_ok=True)
        self.tmp=tempfile.TemporaryDirectory(dir=base); self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)
        cast = self.root/'cast'; cast.write_text('#!/bin/sh\necho "cast Version: 1.7.1-stable"\n'); cast.chmod(0o755)
        checker = self.root/'script/rehearsal/deploylive_postdeploy_check.py'
        checker.parent.mkdir(parents=True); checker.write_text('# checker fixture\n')
        self.env={'PATH':'/usr/bin:/bin', 'CAST_1_7_1':str(cast),'SP_COMMIT':'a'*40,'GOVERNANCE_OWNER':'0x'+'22'*20,'ENV':'test',
                  'DEPLOYLIVE_EVIDENCE_DIR':str(self.root),'DEFAULT_CACHE_PATH':str(self.root/'build')}
        (self.root/'pop-request.json').write_text('{"pin":{"senders":{"deployer":{"nonce":39}}}}')

    def test_owner_change_refuses_before_forge(self):
        from types import SimpleNamespace
        env={key:'value' for key in c.input_keys() if not key.endswith('_FILE')}
        env.update(self.env, DEPLOYLIVE_RPC='https://rpc.invalid/token',
                   DEPLOYLIVE_PRICE_SOURCE='chain', FOUNDRY_VERBOSITY='2', REHEARSAL_BLS_SCALARS='[]')
        second = self.root/'predict-second-rpc'
        second.write_text('https://secondary.infura.io/key')
        env.update(DEPLOYLIVE_EXPECTED_CHAIN_ID='11155111', DEPLOYLIVE_ENDPOINT_PROVIDER='Alchemy',
                   DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER='Infura', DEPLOYLIVE_RPC='https://primary.alchemy.com/key',
                   DEPLOYLIVE_SECOND_RPC=second.read_text(), DEPLOYLIVE_SECOND_RPC_FILE=str(second))
        def predict(argv, **kwargs):
            if argv[1:] == ['--version']:
                return SimpleNamespace(returncode=0, stdout='cast Version: 1.7.1-stable', stderr='')
            self.assertNotIn('--broadcast',argv)
            self.assertNotIn(env['DEPLOYLIVE_RPC'],argv)
            (self.root/f.REQUEST_PATH).write_text('{"pin":{"senders":{"deployer":{"nonce":39}}}}')
            return SimpleNamespace(returncode=0,stdout='',stderr='')
        with patch.dict(os.environ,env,clear=True), patch.object(f,'ROOT',self.root), patch.object(f,'clean_source_commit',return_value='a'*40), patch.object(f,'verify_build',return_value='forge'), patch.object(f,'config_path',return_value=self.root/'config.json'), patch.object(f.subprocess,'run',side_effect=predict):
            f.stage('predict',['--production','--evidence',str(self.root)])
        env['GOVERNANCE_OWNER']='other'
        with patch.object(c,'load_inputs',return_value=env), patch.object(f.subprocess,'run') as run:
            with self.assertRaisesRegex(RuntimeError,'input manifest'):
                f.cli(['deploy','--inputs','unused','--production'])
            run.assert_not_called()

    def test_manifest_request_digest_and_canonical_values(self):
        env=dict(self.env,DEPLOYER_ACCOUNT='secret',PRIVATE_KEY_ANNI='secret',DEPLOYLIVE_RPC='https://secret')
        c.write_manifest(env,self.root)
        text=(self.root/'inputs.manifest').read_text()
        self.assertNotIn('secret',text); self.assertEqual(text.splitlines(),sorted(text.splitlines()))
        c.verify_manifest(env,self.root)
        (self.root/'pop-request.json').write_text('{}')
        with self.assertRaisesRegex(RuntimeError,'input manifest'): c.verify_manifest(env,self.root)

    def test_plan_fields_order_count_nonce_and_block_context(self):
        plan=json.loads(FIX.read_text()); other=copy.deepcopy(plan)
        other['timestamp']+=1
        for receipt in other['receipts']: receipt['blockHash']='0x'+'12'*32
        self.assertEqual(c.plan_diff(plan,other),[])
        for key,value in [('to','0x'+'34'*20),('input','0x1234'),('value','0x1'),('from','0x'+'56'*20),('chainId','0xa'),('nonce','0x28')]:
            with self.subTest(key=key):
                bad=copy.deepcopy(other); bad['transactions'][0]['transaction'][key]=value
                self.assertTrue(c.plan_diff(plan,bad))
        for txs in (other['transactions'][:-1],list(reversed(other['transactions']))):
            self.assertTrue(c.plan_diff(plan,dict(other,transactions=txs)))
        c.check_start_nonce(plan,39,lambda *a:'0x27','sender')
        with self.assertRaisesRegex(RuntimeError,'nonce'): c.check_start_nonce(plan,39,lambda *a:'0x28','sender')

    def test_postbroadcast_gas_bounds(self):
        plan=json.loads(FIX.read_text()); bounds=[[int(t['transaction']['gas'],16)]*2 for t in plan['transactions']]
        self.assertEqual(c.plan_diff(plan,plan,bounds),[])
        for delta in (-1,1):
            bad=copy.deepcopy(plan); bad['transactions'][80]['transaction']['gas']=hex(bounds[80][0]+delta)
            self.assertTrue(c.plan_diff(plan,bad,bounds))

    def test_raw_output_refused_before_write(self):
        env=dict(self.env,DEPLOYLIVE_RPC='https://rpc.invalid/secret123')
        for value in ('https://rpc.invalid/secret123','secret123','https://other.invalid/token'):
            with self.assertRaises(RuntimeError): c.safe_logs(self.root,'forge',Mock(stdout=value,stderr=''),env)
            self.assertFalse((self.root/'forge.stdout.log').exists())

    def test_argv_has_no_endpoint(self):
        # Behaviour change (acceptance at 6146e343): forge script ignores ETH_RPC_URL, so the URL
        # goes through the foundry.toml alias and DEPLOYLIVE_FORGE_RPC_URL instead.
        cmd,env=c.forge_endpoint(['forge','script'],{'DEPLOYLIVE_RPC':'https://rpc.invalid/secret'})
        self.assertFalse(any('https://' in arg for arg in cmd)); self.assertEqual(cmd[-2:],['--rpc-url','deploylive'])
        self.assertEqual(env['DEPLOYLIVE_FORGE_RPC_URL'],'https://rpc.invalid/secret'); self.assertNotIn('ETH_RPC_URL',env)

    def test_endpoint_permissions_type_owner_lines(self):
        # Fixture URL carries a credential-like segment: the start-up self-check refuses a URL the
        # scanner could not guard (DSR 2026-11-19).
        p=self.root/'rpc'; p.write_text('https://rpc.invalid/k3yAbc123def456\n'); p.chmod(0o600)
        self.assertEqual(c.read_endpoint_file('RPC',str(p)),'https://rpc.invalid/k3yAbc123def456')
        for mode in (0o644,0o610):
            p.chmod(mode)
            with self.assertRaises(RuntimeError): c.read_endpoint_file('RPC',str(p))
        p.chmod(0o600)
        q=self.root/'link'; q.symlink_to(p)
        with self.assertRaises(RuntimeError): c.read_endpoint_file('RPC',str(q))
        with patch.object(c.os,'getuid',return_value=os.getuid()+1):
            with self.assertRaises(RuntimeError): c.read_endpoint_file('RPC',str(p))
        for text in ('https://rpc.invalid\n\n','\nhttps://rpc.invalid\n'):
            p.write_text(text)
            with self.assertRaises(RuntimeError): c.read_endpoint_file('RPC',str(p))

    def test_archive_requires_current_pass_and_copies_records(self):
        c.write_manifest(self.env,self.root)
        with self.assertRaises(RuntimeError): c.archive(self.root,self.root.parent/(self.root.name+'-archive'))
        config=self.root/'external-config.json'; config.write_text('{}')
        broadcast=self.root/'external-broadcast.json'; broadcast.write_text('{}')
        (self.root/'gated-plan.json').write_text(FIX.read_text())
        (self.root/'readback.json').write_text('{}')
        c.write_success(self.root,dict(self.env,DEPLOYLIVE_SECOND_RPC_NO_CREDENTIAL='1'),config,broadcast,json.loads(FIX.read_text()))
        # The operator's credential-free declaration is recorded in the PASS record (DSR 2026-11-19).
        self.assertEqual(json.loads((self.root/'checker.PASS.json').read_text())['noCredentialEndpoints'],['DEPLOYLIVE_SECOND_RPC'])
        self.assertEqual(json.loads((self.root/'checker.PASS.json').read_text())['redactedStreams'],[])
        dest=self.root.parent/(self.root.name+'-archive'); self.addCleanup(lambda: __import__('shutil').rmtree(dest,ignore_errors=True))
        c.archive(self.root,dest)
        for name in ('config.test.json','run-latest.json','readback.json'):
            self.assertEqual((dest/name).read_text(),'{}'); self.assertIn(name,(dest/'SHA256SUMS').read_text())
        (self.root/'inputs.manifest').write_text('changed')
        with self.assertRaises(RuntimeError): c.archive(self.root,dest.with_name(dest.name+'2'))

    def test_source_stamp_changes_with_head_or_config(self):
        (self.root/'foundry.toml').write_text('one')
        with patch.object(d,'ROOT',self.root), patch.object(d,'clean_source_commit',return_value='a'*40):
            first=d.source_stamp()
            self.assertEqual(first['commit'],'a'*40)
            (self.root/'foundry.toml').write_text('two')
            self.assertNotEqual(first,d.source_stamp())
        with patch.object(d,'ROOT',self.root), patch.object(d,'clean_source_commit',return_value='b'*40):
            self.assertNotEqual(first,d.source_stamp())

    def test_deploy_rule_both_chains(self):
        for chain in (10,11155111):
            env=dict(self.env,DEPLOYLIVE_SOURCE_RPC='a',DEPLOYLIVE_SECOND_RPC='b')
            with patch.object(c,'hardfork_check',return_value={'chainId':chain}) as check:
                c.deployment_rule(env,self.root,lambda url: url,chain)
                check.assert_called_once_with('a','b',self.root)

    def driver(self, mutate=None, checker_ok=True, chain=11155111, bounds=None, stop=False, output=None, stopped_mutate=None, env_overrides=None, broadcast_result=None, nonce_after_broadcast=None):
        import sys
        from types import SimpleNamespace
        plan=json.loads(FIX.read_text()); evidence=self.root
        self.env.update(FOUNDRY_VERBOSITY='2',FOUNDRY_OUT=str(evidence/'execution'),FOUNDRY_CACHE_PATH=str(evidence/'exec-cache'),DEPLOYLIVE_RPC='primary',DEPLOYLIVE_SOURCE_RPC='primary',DEPLOYLIVE_SECOND_RPC='secondary',
            DEPLOYLIVE_HARDFORK='amsterdam',DEPLOYLIVE_PRICE_SOURCE='chain',DEPLOYER_ACCOUNT='unused',
            DEPLOYER_ADDRESS=plan['transactions'][0]['transaction']['from'],DEFAULT_ARTIFACTS_OUT=str(evidence/'out'),
            DEPLOYLIVE_EXPECTED_CHAIN_ID=str(chain))
        self.env.update(DEPLOYLIVE_ENDPOINT_PROVIDER='Alchemy', DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER='Infura',
                        DEPLOYLIVE_RPC='https://primary.alchemy.com/key', DEPLOYLIVE_SOURCE_RPC='https://primary.alchemy.com/key',
                        DEPLOYLIVE_SECOND_RPC='https://secondary.infura.io/key', DEPLOYLIVE_SECOND_RPC_FILE=str(evidence/'second-rpc'))
        (evidence/'second-rpc').write_text(self.env['DEPLOYLIVE_SECOND_RPC'])
        for key, value in (env_overrides or {}).items():
            if value is None: self.env.pop(key, None)
            else: self.env[key] = value
        c.write_manifest(self.env,evidence)
        c.write_conversion(evidence,b'{}',(evidence/'pop-request.json').read_bytes(),b'0x00')
        stamp=evidence/'out.build-stamp.json'; stamp.write_text('{"forge":{}}')
        cfg=evidence/'config.json'; cfg.write_text('{}')
        dry=evidence/f'broadcast/DeployLive.s.sol/{chain}/dry-run/run-latest.json'
        actual=dry.parent.parent/'run-latest.json'
        calls=[]
        self.script_envs=[]
        def run(argv,**kwargs):
            if argv[1:] == ['--version']:
                return SimpleNamespace(returncode=0, stdout='cast Version: 1.7.1-stable', stderr='')
            self.assertFalse(any('primary' in x or 'secondary' in x for x in argv))
            calls.append(argv)
            if 'script' in argv:
                self.script_envs.append(dict(kwargs['env']))
                obj=copy.deepcopy(plan)
                if kwargs['env']['DEPLOYLIVE_STOP_BEFORE_BOOTSTRAP'] == '1':
                    obj['transactions'] = obj['transactions'][:-1]
                    if stopped_mutate: stopped_mutate(obj)
                if mutate: mutate(obj,len(calls))
                target=actual if '--broadcast' in argv else dry
                target.parent.mkdir(parents=True,exist_ok=True); target.write_text(json.dumps(obj))
                return SimpleNamespace(returncode=broadcast_result[0] if broadcast_result and '--broadcast' in argv else 0,stdout=output(argv) if output else '',stderr=broadcast_result[1] if broadcast_result and '--broadcast' in argv else '')
            self.checker_env = dict(kwargs['env'])
            if checker_ok:
                # The driver hands the checker its own cache/ subdirectory (DEPLOYLIVE_EVIDENCE_DIR).
                checker_dir=Path(kwargs['env']['DEPLOYLIVE_EVIDENCE_DIR']); checker_dir.mkdir(parents=True,exist_ok=True)
                (checker_dir/'readback.json').write_text('{}')
            return SimpleNamespace(returncode=0 if checker_ok else 1,stdout='SUMMARY 238 passed, 0 failed, 238 total' if checker_ok else 'FAIL checker',stderr='')
        def make_rpc(url):
            # nonce_after_broadcast(url, tag) -> hex nonce or Exception, consulted only after --broadcast.
            def rpc(method,*args):
                if method=='eth_getTransactionCount' and nonce_after_broadcast is not None and any('--broadcast' in c for c in calls):
                    value = nonce_after_broadcast(url, args[-1])
                    if isinstance(value, Exception): raise value
                    return value
                return hex(chain) if method=='eth_chainId' else '0x27'
            return rpc
        rpc = make_rpc('local')
        with patch.dict(os.environ,self.env,clear=True), patch.object(sys,'argv',(['driver',self.env['DEPLOYLIVE_RPC'],self.env['DEPLOYER_ADDRESS'],'--stop'] if stop else ['driver','--production',self.env['DEPLOYER_ADDRESS']])), patch.object(f,'ROOT',evidence), patch.object(f,'clean_source_commit',return_value='a'*40), patch.object(f,'ReadOnlyRPC',side_effect=(lambda url: (lambda method,*args: hex(11155111) if method == 'eth_chainId' else '0x27')) if stop else make_rpc), patch.object(f,'RPC',return_value=rpc), patch.object(f,'verify_build',return_value='forge'), patch.object(f,'config_path',return_value=cfg), patch.object(d,'stamp_path',return_value=stamp), patch.object(c,'hardfork_check',return_value={'chainId':chain}) as rule, patch.object(f,'broadcast_gates',return_value=bounds if bounds is not None else [[int(t['transaction']['gas'],16)]*2 for t in plan['transactions']]), patch.object(f.subprocess,'run',side_effect=run):
            try: f.main()
            finally: self.calls=calls; self.rule=rule

    def test_driver_unmined_broadcast_never_reports_gas(self):
        import contextlib
        import io
        for code in (1, 0):
            def mutate(plan, index):
                if index == 3: plan['receipts'] = []
            output = io.StringIO()
            with contextlib.redirect_stdout(output), self.assertRaisesRegex(RuntimeError, 'deployment failed'):
                self.driver(mutate, broadcast_result=(code, 'Failed to decrypt keystore: incorrect password https://secret.invalid/key'))
            self.assertIn('NOT BROADCAST: forge failed before signing (keystore unlock failed)', output.getvalue())
            self.assertNotIn('GAS post-broadcast', output.getvalue())
            self.assertNotIn('secret.invalid', output.getvalue())

    def test_driver_no_receipts_never_not_broadcast_unless_every_read_is_unchanged(self):
        # forge's record is written before signing; NOT BROADCAST needs a pre-signing cause AND
        # latest+pending on both providers equal to the start nonce (0x27). Anything else is UNKNOWN.
        import contextlib
        import io
        def mutate(plan, index):
            if index == 3: plan['receipts'] = []
        second = self.env.get('DEPLOYLIVE_SECOND_RPC', 'https://secondary.infura.io/key')
        pw = 'Failed to decrypt keystore: incorrect password https://secret.invalid/key'
        cases = (
            ('providers disagree', pw, lambda url, tag: '0x2c' if url == second else '0x27'),
            ('latest unchanged, pending moved', pw, lambda url, tag: '0x28' if tag == 'pending' else '0x27'),
            ('all moved', pw, lambda url, tag: '0x2c'),
            ('unreadable', pw, lambda url, tag: RuntimeError('rpc down')),
            ('not a pre-signing cause', 'boom https://secret.invalid/key', lambda url, tag: '0x27'),
        )
        for name, stderr, reader in cases:
            output = io.StringIO()
            with self.subTest(name), contextlib.redirect_stdout(output), self.assertRaisesRegex(RuntimeError, 'deployment failed'):
                self.driver(mutate, broadcast_result=(1, stderr), nonce_after_broadcast=reader)
            text = output.getvalue()
            self.assertIn('BROADCAST STATE UNKNOWN — do not retry', text)
            self.assertNotIn('NOT BROADCAST', text)
            self.assertNotIn('GAS post-broadcast', text)
            self.assertNotIn('secret.invalid', text)
        output = io.StringIO()
        with contextlib.redirect_stdout(output), self.assertRaisesRegex(RuntimeError, 'deployment failed'):
            self.driver(mutate, broadcast_result=(1, pw), nonce_after_broadcast=lambda url, tag: '0x27')
        self.assertIn('NOT BROADCAST: forge failed before signing (keystore unlock failed)', output.getvalue())
        self.assertEqual(output.getvalue().count('advanced by 0'), 4)

    def test_driver_failed_exit_with_receipts_has_no_gas_conclusion(self):
        import contextlib
        import io
        output = io.StringIO()
        with contextlib.redirect_stdout(output), self.assertRaisesRegex(RuntimeError, 'deployment failed'):
            self.driver(broadcast_result=(7, 'https://secret.invalid/key'))
        self.assertEqual(output.getvalue().splitlines().count('BROADCAST MINED: all transactions mined; forge exited non-zero; deployment NOT successful'),1)
        self.assertEqual(json.loads((self.root/'postbroadcast.diff.json').read_text())['diff'],[])
        self.assertEqual(json.loads((self.root/'postbroadcast.gas.json').read_text()),[])
        self.assertFalse((self.root/'checker.PASS.json').exists())
        self.assertNotIn('GAS post-broadcast', output.getvalue())
        self.assertNotIn('NOT BROADCAST', output.getvalue())
        self.assertNotIn('secret.invalid', output.getvalue())

    def test_failed_forge_with_mined_diff_preserves_gas(self):
        import contextlib
        import io
        def mutate(plan,index):
            if index == 3: plan['transactions'][0]['transaction']['input']='0x1234'
        output=io.StringIO()
        with contextlib.redirect_stdout(output), self.assertRaisesRegex(RuntimeError,'post-broadcast diff'):
            self.driver(mutate,broadcast_result=(7,'failed'))
        self.assertTrue(json.loads((self.root/'postbroadcast.diff.json').read_text())['diff'])
        self.assertEqual(json.loads((self.root/'postbroadcast.gas.json').read_text()),[])
        self.assertIn('BROADCAST MINED:',output.getvalue())
        self.assertFalse((self.root/'checker.PASS.json').exists())

    def test_driver_partial_broadcast_is_not_success(self):
        import contextlib
        import io
        def mutate(plan, index):
            if index == 3: plan['receipts'] = plan['receipts'][:1]
        output = io.StringIO()
        with contextlib.redirect_stdout(output), self.assertRaisesRegex(RuntimeError, 'deployment failed'):
            self.driver(mutate)
        self.assertIn('PARTIAL BROADCAST: forge recorded 1/', output.getvalue())
        self.assertIn('GAS partial post-broadcast', output.getvalue())
        self.assertFalse((self.root/'checker.PASS.json').exists())

    def test_driver_success_and_rule_is_mandatory(self):
        self.driver()
        self.rule.assert_called_once()
        self.assertTrue((self.root/'checker.PASS.json').is_file())
        self.assertEqual(json.loads((self.root/'postbroadcast.diff.json').read_text())['diff'],[])

    def test_driver_final_simulation_change_never_broadcasts(self):
        def mutate(plan,index):
            if index==2: plan['transactions'][45]['transaction']['input']='0x1234'
        with self.assertRaisesRegex(RuntimeError,'final simulation differs'): self.driver(mutate)
        self.assertFalse(any('--broadcast' in argv for argv in self.calls))
        self.assertFalse((self.root/'checker.PASS.json').exists())

    def test_daybreak_final_gas_outside_bounds_never_broadcasts(self):
        def mutate(plan, index):
            if index == 2: plan['transactions'][45]['transaction']['gas'] = '0x1'
        with self.assertRaisesRegex(RuntimeError, 'index=45.*gas'):
            self.driver(mutate)
        self.assertFalse(any('--broadcast' in argv for argv in self.calls))

    def test_driver_postbroadcast_difference_prevents_success(self):
        def mutate(plan,index):
            if index==3: plan['transactions'][45]['transaction']['gas']='0x1'
        with self.assertRaisesRegex(RuntimeError,'post-broadcast diff'): self.driver(mutate)
        self.assertTrue(json.loads((self.root/'postbroadcast.diff.json').read_text())['diff'])
        self.assertFalse((self.root/'checker.PASS.json').exists())

    def test_driver_malformed_broadcast_diff_is_evidence(self):
        def mutate(plan,index):
            if index==3: del plan['transactions']
        with self.assertRaises(RuntimeError): self.driver(mutate)
        self.assertTrue(json.loads((self.root/'postbroadcast.diff.json').read_text())['diff'])

    def test_driver_checker_failure_prevents_pass(self):
        with self.assertRaisesRegex(RuntimeError,'checker'): self.driver(checker_ok=False)
        self.assertFalse((self.root/'checker.PASS.json').exists())

    def test_build_stamp_refuses_head_and_foundry_change(self):
        from types import SimpleNamespace
        env=dict(FOUNDRY_OUT=str(self.root/'execution'),FOUNDRY_CACHE_PATH=str(self.root/'exec-cache'),DEFAULT_ARTIFACTS_OUT=str(self.root/'release'),DEFAULT_CACHE_PATH=str(self.root/'release-cache'))
        (self.root/'foundry.toml').write_text('approved')
        identity=dict(path='forge',version='v',sha256='a'*64)
        with patch.object(d,'ROOT',self.root), patch.object(d,'clean_source_commit',return_value='a'*40), patch.object(d,'forge_identity',return_value=identity), patch.object(d,'check_pin'), patch.object(d.subprocess,'run',return_value=SimpleNamespace(returncode=0)):
            d.build(env,False); d.verify_build(env,False)
            with patch.object(d,'clean_source_commit',return_value='b'*40):
                with self.assertRaisesRegex(RuntimeError,'differs'): d.verify_build(env,False)
            (self.root/'foundry.toml').write_text('changed')
            with self.assertRaisesRegex(RuntimeError,'differs'): d.verify_build(env,False)

    def test_converter_input_change_refuses_before_conversion(self):
        import sys
        import dvt_pop_to_guardians as converter
        c.write_manifest(self.env,self.root)
        self.env['GOVERNANCE_OWNER']='other'
        with patch.object(sys,'argv',['convert','unused',str(self.root/'pop-request.json'),'--sp-root','.', '--inputs','unused']), patch.object(c,'load_inputs',return_value=self.env), patch.object(converter,'convert') as convert:
            self.assertEqual(converter.main(),3)
            convert.assert_not_called()

    def test_endpoint_special_mode_refused(self):
        p=self.root/'rpc'; p.write_text('https://rpc.invalid\n'); p.chmod(0o600)
        info=p.lstat()
        with patch.object(Path,'lstat',return_value=Mock(st_mode=info.st_mode | 0o4000,st_uid=info.st_uid)):
            with self.assertRaises(RuntimeError): c.read_endpoint_file('RPC',str(p))

    def test_gas_gate_uses_all_97_real_receipts(self):
        import test_deploylive_ddf3 as previous
        original=d.gas_crosscheck
        expected=json.loads(FIX.read_text())
        def checked(plan,rpc,*args,**kwargs):
            def observed(method,*params):
                result=rpc(method,*params)
                if method=='eth_simulateV1':
                    self.assertEqual([int(block['calls'][0]['gasUsed'],16) for block in result],
                                     [int(receipt['gasUsed'],16) for receipt in expected['receipts']])
                return result
            return original(plan,observed,*args,**kwargs)
        with patch.object(d,'gas_crosscheck',side_effect=checked):
            previous.Ddf3Test('test_fees_real_success_observations').test_fees_real_success_observations()
