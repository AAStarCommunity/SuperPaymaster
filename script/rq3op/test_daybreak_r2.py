"""Round-2 controls; all transports are offline."""
import hashlib
import json
import re
import unittest
from types import SimpleNamespace
from unittest.mock import patch
import plan_three_arm as q
import test_three_arm as fixtures

class Round2(unittest.TestCase):
    def test_provider_name_reaches_checker_environment(self):
        import os
        from pinned_tools import PinnedTools
        with patch.dict(os.environ, DEPLOYLIVE_ENDPOINT_PROVIDER='Fixture'):
            tools = PinnedTools()
        self.assertEqual(tools.env.get('DEPLOYLIVE_ENDPOINT_PROVIDER'), 'Fixture')

    def test_pinned_tools_environment_and_metadata(self):
        tools=q.pinned_tools()
        calls=[]
        tools.runner=lambda cmd,**kw: calls.append((cmd,kw)) or SimpleNamespace(returncode=0,stdout='')
        tools.run(['git','status'],env={'PATH':'/accidental','GIT_DIR':'wrong'})
        tools.run(['cast','--version'])
        for name,(cmd,kw) in zip(('git','cast'),calls):
            self.assertEqual(cmd[0],tools.records[name]['path'])
            self.assertEqual(kw['env']['PATH'],tools.env['PATH'])
            self.assertNotIn('/accidental',kw['env']['PATH'])
            self.assertNotIn('GIT_DIR',kw['env'])
            record=tools.records[name]
            self.assertTrue(q.Path(record['path']).is_absolute())
            self.assertTrue(record['version'])
            self.assertEqual(record['sha256'],hashlib.sha256(q.Path(record['path']).read_bytes()).hexdigest())

    def test_checker_and_runner_git_blobs(self):
        for changed in ('script/rehearsal/deploylive_postdeploy_check.py','script/rq3op/checker_runner.py'):
            tools=q.pinned_tools()
            def run(cmd,**kw):
                path=cmd[-1].split(':',1)[1]
                raw=(q.ROOT/path).read_bytes()
                return SimpleNamespace(returncode=0,stdout=raw+b'changed' if path==changed else raw)
            tools.runner=run
            with self.assertRaisesRegex(q.a.Gate,'rq3_checker_blob'):
                q.run_checker('config',{'commit':'a'*40},'unused',10,block='0x'+'12'*32,
                    runner=lambda *args,**kwargs:self.fail('checker executed after blob mismatch'),
                    commit_reader=lambda:'a'*40,tools=tools)

    def test_release_table_matches_source_literals(self):
        expected={}
        names = 'AOAProtocolRegistry APNTsCapped BLSAggregator DVTValidator GToken GTokenAuthorization GTokenStaking GlobalTierSource MicroPaymentChannel MySBT Paymaster PaymasterFactory PolicyRegistry Registry ReputationSystem SuperPaymaster SuperPaymasterLens X402Facilitator xPNTsFactory xPNTsFactoryV2 xPNTsToken xPNTsTokenV2'.split()
        for name in names:
            paths = list((q.ROOT/'contracts/src').rglob(name + '.sol'))
            self.assertEqual(len(paths), 1)
            text = paths[0].read_text()
            expected[name]=re.search(r'function\s+version\s*\([^)]*\)[^{]*\{\s*return\s+"([^"\n]+)"',text)[1]
        self.assertEqual(json.loads((q.ROOT/'deployments/release-versions.rc8.json').read_text()),expected)

    def test_planner_task_collisions(self):
        for token in ('X','Q','aPNTs'):
            f=fixtures.ThreeArm();f.setUp()
            original=q.m.build_phase_c
            def altered(**kw):
                pc,n=original(**kw)
                pc['addresses']['T']=f.cfg['aPNTs'] if token=='aPNTs' else pc['addresses'][token]
                return pc,n
            with patch.object(q.m,'build_phase_c',side_effect=altered):
                with self.assertRaisesRegex(q.a.Gate,'C_task_token_distinct'):f.build()

    def test_ci_suites(self):
        workflow=(q.ROOT/'.github/workflows/a3a-executor.yml').read_text()
        self.assertIn("python3 -B -m unittest discover -s script/rq3op -p 'test_*.py'",workflow)
        self.assertIn('mkdir -p cache/3arm/fix cache/3arm/r2',workflow)
        self.assertIn('node --test script/rq3op/*.test.mjs script/a6-collector/*.test.mjs',workflow)

    def test_forged_code_and_matching_versions_stop_at_runtime(self):
        import sys
        sys.path.insert(0,str(q.ROOT/'script/rehearsal'))
        from test_deploylive_postdeploy_check import CheckerTest
        cfg={k:fixtures.address(i+1) for i,k in enumerate(q.SYSTEM_SOURCES)}
        versions=json.loads((q.ROOT/'deployments/release-versions.rc8.json').read_text())
        encoded={}
        for key,name in q.RELEASE_NAMES.items():
            value=versions[name].encode()
            encoded[cfg[key]]='0x'+(32).to_bytes(32,'big').hex()+len(value).to_bytes(32,'big').hex()+value.hex()
        q.verify_system(cfg,lambda method,params:'0x6000' if method=='eth_getCode' else encoded[params[0]['to']],'0x20')
        # The checker consumes injected release artifacts so this control also runs
        # on a clean CI checkout with no ignored out/ directory. matches() is real.
        def artifact(name, directory=None):
            pin = json.loads((q.ROOT/'deployments/runtime-pins.31337.json').read_text())['artifacts'][name]
            prefix = '60806040525f80fd' if name == 'TimelockHandoverBootstrap' else '60'
            code = '0x' + prefix + '00' * (int(pin['runtimeLength']) - len(prefix)//2)
            refs = {}
            for ref in pin['immutableRanges']:
                refs.setdefault(ref['id'], []).append({'start': int(ref['start']), 'length': int(ref['length'])})
            abi_path = q.ROOT/'abis'/f'{name}.json'
            abi = json.loads(abi_path.read_text()) if abi_path.exists() else []
            if isinstance(abi, dict): abi = abi['abi']
            return dict(abi=abi, bytecode={'object':'0x60'+hashlib.sha256(name.encode()).hexdigest()},deployedBytecode={'object':code,'immutableReferences':refs},
                metadata={'settings':{'evmVersion':'cancun','viaIR':True,
                    'optimizer':{'runs':200 if name in ('Registry','TimelockHandoverBootstrap') else 500}}})
        with patch('deploylive_runtime.release_artifact',side_effect=artifact):
            rc,out=CheckerTest().run_checker(release_versions=versions)
            self.assertEqual(rc,0,out)
            rc,out=CheckerTest().run_checker('runtime_spImpl', release_versions=versions)
        self.assertEqual(rc,1,out)
        self.assertIn('sp="SuperPaymaster-5.5.3"',out)
        self.assertEqual([line.split(' ::')[0] for line in out.splitlines() if line.startswith('FAIL')],['FAIL  readback snapshot policy', 'FAIL  runtime spImpl'])
