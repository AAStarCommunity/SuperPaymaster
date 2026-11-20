"""Offline acceptance: all RPC and archive destinations are injected."""
import contextlib
import io
import hashlib
import json
from pathlib import Path
import re
import tempfile
import shutil
import unittest
from unittest.mock import Mock, patch
import deploylive_fork_deploy as f


class Ddf4Test(unittest.TestCase):
    def setUp(self):
        base=Path(__file__).resolve().parents[2]/'cache/ddf4'
        base.mkdir(parents=True,exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(dir=base)
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def api(self):
        import deploylive_controls as c
        return c

    def rpc(self, unsupported=False, field='0x1'):
        def call(method, *args):
            if method == 'eth_chainId': return hex(11155111)
            if method == 'eth_config':
                if unsupported: raise RuntimeError('RPC error -32601 method not found')
                return {'current': {'forkId':'0x6c1d9423', 'activationTime':1791294816}}
            if method == 'eth_blockNumber': return hex(100)
            return dict(number=args[0], hash='0x'+'ab'*32, timestamp=hex(1791295000), blockAccessListHash=field, slotNumber='0x2')
        return Mock(side_effect=call)

    def test_hardfork_same_block_and_unsupported_b(self):
        c=self.api(); a,b=self.rpc(),self.rpc(True)
        result=c.hardfork_check(a,b,self.root)
        self.assertEqual(result['blockNumber'],98)
        self.assertIn('unsupported',result['endpointB']['eth_config'])
        a.assert_any_call('eth_getBlockByNumber','0x62',False)
        b.assert_any_call('eth_getBlockByNumber','0x62',False)
        self.assertEqual(json.loads((self.root/'hardfork-check.json').read_text()),result)

    def test_hardfork_mismatch_and_missing_fields(self):
        c=self.api()
        for b in (self.rpc(field='0x3'), self.rpc(field=None)):
            with self.assertRaises(RuntimeError): c.hardfork_check(self.rpc(),b,self.root)
        with self.assertRaises(RuntimeError): c.hardfork_check(self.rpc(True),self.rpc(),self.root)
        bad=self.rpc(); original=bad.side_effect
        bad.side_effect=lambda m,*p: {'current':{'forkId':'wrong','activationTime':1791294816}} if m=='eth_config' else original(m,*p)
        with self.assertRaises(RuntimeError): c.hardfork_check(bad,self.rpc(),self.root)

    def cap_rpc(self, status='0x0', gas=16777216):
        return Mock(side_effect=lambda m,*p: {'eth_chainId':hex(31337),'evm_snapshot':'snap','evm_revert':True,'eth_sendTransaction':'tx',
            'eth_getTransactionReceipt':dict(status=status,gasUsed=hex(gas)),
            'eth_getBlockByNumber':dict(hash='head')}.get(m,True))

    def test_cap_control_receipt_and_revert(self):
        c=self.api(); rpc=self.cap_rpc()
        c.cap_control(rpc,self.root)
        tx=next(call.args[1] for call in rpc.call_args_list if call.args[0]=='eth_sendTransaction')
        self.assertEqual(tx['data'],'0x5b600056'); self.assertEqual(int(tx['gas'],16),20000000)
        self.assertNotIn('to',tx)
        rpc.assert_any_call('evm_revert','snap')
        self.assertTrue(json.loads((self.root/'cap-control.json').read_text())['passed'])

    def test_cap_failures_cleanup_and_production(self):
        c=self.api()
        for status,gas in [('0x1',16777216),('0x0',20000000)]:
            rpc=self.cap_rpc(status,gas)
            with self.assertRaises(RuntimeError): c.cap_control(rpc,self.root)
            rpc.assert_any_call('evm_revert','snap')
        rpc=Mock()
        with self.assertRaises(RuntimeError): c.cap_control(rpc,self.root,production=True)
        rpc.assert_not_called()

    def test_archive_hashes_and_refuse_existing(self):
        c=self.api(); source=self.root/'evidence'; source.mkdir(); (source/'a.json').write_text('{}')
        dest=self.root/'archive'
        copier=Mock(wraps=shutil.copytree)
        with patch.object(c,'archive_records'):
            c.archive(source,dest,copy=copier)
        copier.assert_called_once_with(source,dest)
        self.assertEqual((dest/'SHA256SUMS').read_text(),hashlib.sha256(b'{}').hexdigest()+'  a.json\n')
        with self.assertRaises(RuntimeError): c.archive(source,dest)
        (source/'link').symlink_to(source/'a.json')
        with patch.object(c,'archive_records'), self.assertRaises(RuntimeError): c.archive(source,self.root/'other')

    def test_inputs_exact_keys_no_execution_and_commit(self):
        c=self.api(); template=c.TEMPLATE.read_text(); path=self.root/'approved.inputs'
        keys=c.input_keys(); values={k:'value' for k in keys}
        values.update({k:'' for k in keys if k.endswith('_NO_CREDENTIAL')})  # only '' or '1' accepted
        values.update(self.endpoint_files(keys))
        self.assertNotIn('SP_COMMIT',keys)
        values['DEPLOYLIVE_EVIDENCE_DIR']=str(self.root/'evidence')
        values['DEFAULT_CACHE_PATH']=str(self.root/'build-cache')
        def write(v): path.write_text('\n'.join(k+'='+json.dumps(x) for k,x in v.items()))
        write(values)
        env=c.load_inputs(path,{'UNLISTED':'no','DEPLOYLIVE_ENDPOINT_PROVIDER':'Fixture'},commit_reader=lambda:'a'*40)
        self.assertNotIn('UNLISTED',env); self.assertEqual(env['SP_COMMIT'],'a'*40)
        with self.assertRaises(RuntimeError): c.load_inputs(path,{'SP_COMMIT':'b'*40,'DEPLOYLIVE_ENDPOINT_PROVIDER':'Fixture'},commit_reader=lambda:'a'*40)
        with self.assertRaises(RuntimeError): c.load_inputs(path,{'SP_COMMIT':'','DEPLOYLIVE_ENDPOINT_PROVIDER':'Fixture'},commit_reader=lambda:'a'*40)
        for change in ('missing','extra'):
            altered=dict(values)
            if change=='missing': altered.pop('ENV')
            else: altered['EXTRA']='bad'
            write(altered)
            with self.assertRaises(RuntimeError): c.load_inputs(path,{'DEPLOYLIVE_ENDPOINT_PROVIDER':'Fixture'},commit_reader=lambda:'a'*40)
        self.assertIn('DEPLOYER_ACCOUNT',template)

    def endpoint_files(self, keys):
        out={}
        for k in keys:
            if k.endswith('_RPC_FILE'):
                path=self.root/(k.lower()+'.url'); path.write_text('http://127.0.0.1:1/'+k.lower()+'\n'); path.chmod(0o600); out[k]=str(path)
        return out

    def test_endpoint_urls_only_via_files(self):
        # DSR 2026-11-19: inputs never hold endpoint URLs; files are read in-process.
        c=self.api(); path=self.root/'approved.inputs'; keys=c.input_keys()
        self.assertTrue({'DEPLOYLIVE_RPC_FILE','DEPLOYLIVE_SOURCE_RPC_FILE','DEPLOYLIVE_SECOND_RPC_FILE'} <= keys)
        self.assertFalse({'DEPLOYLIVE_RPC','DEPLOYLIVE_SOURCE_RPC','DEPLOYLIVE_SECOND_RPC'} & keys)
        base={k:'value' for k in keys}; base.update(self.endpoint_files(keys))
        base.update({k:'' for k in keys if k.endswith('_NO_CREDENTIAL')})
        base.update(DEPLOYLIVE_EVIDENCE_DIR=str(self.root/'evidence'),DEFAULT_CACHE_PATH=str(self.root/'build'))
        write=lambda v: path.write_text('\n'.join(k+'='+json.dumps(x) for k,x in v.items()))
        write(base); env=c.load_inputs(path,{'DEPLOYLIVE_ENDPOINT_PROVIDER':'Fixture'},commit_reader=lambda:'a'*40)
        self.assertEqual(env['DEPLOYLIVE_SOURCE_RPC'],'http://127.0.0.1:1/deploylive_source_rpc_file')
        self.assertNotIn('DEPLOYLIVE_SOURCE_RPC_FILE',env)
        for url in ('https://x.invalid/k','wss://x.invalid/k','HTTP://x.invalid/k'):
            bad=dict(base,ENV=url); write(bad)
            with self.assertRaisesRegex(RuntimeError,'must not contain endpoint URLs'): c.load_inputs(path,{'DEPLOYLIVE_ENDPOINT_PROVIDER':'Fixture'},commit_reader=lambda:'a'*40)
        bad=dict(base,DEPLOYLIVE_RPC_FILE='http://127.0.0.1:1'); write(bad)
        with self.assertRaisesRegex(RuntimeError,'set DEPLOYLIVE_RPC_FILE to its path') as e: c.load_inputs(path,{'DEPLOYLIVE_ENDPOINT_PROVIDER':'Fixture'},commit_reader=lambda:'a'*40)
        self.assertNotIn('_FILE_FILE',str(e.exception))
        for content in ('','not-a-url','http://a\nhttp://b'):
            f=self.root/'bad.url'; f.write_text(content); f.chmod(0o600); write(dict(base,DEPLOYLIVE_SECOND_RPC_FILE=str(f)))
            with self.assertRaisesRegex(RuntimeError,'must hold one URL'): c.load_inputs(path,{'DEPLOYLIVE_ENDPOINT_PROVIDER':'Fixture'},commit_reader=lambda:'a'*40)
        write(dict(base,DEPLOYLIVE_SECOND_RPC_FILE=str(self.root/'missing.url')))
        with self.assertRaises(RuntimeError) as e: c.load_inputs(path,{'DEPLOYLIVE_ENDPOINT_PROVIDER':'Fixture'},commit_reader=lambda:'a'*40)
        self.assertNotIn('127.0.0.1',str(e.exception))

    def test_handoff_paths_and_pinned_fork(self):
        text=(Path(__file__).parent/'DEPLOYLIVE_HANDOFF.md').read_text()
        mentions=re.findall(r'[\w/$.-]*request\.json',text)
        self.assertTrue(mentions)
        self.assertEqual(set(mentions),{f.REQUEST_PATH,'$DEPLOYLIVE_EVIDENCE_DIR/'+f.REQUEST_NAME})
        self.assertIn('--fork-block-number "$PINNED_BLOCK"',text)
        self.assertNotIn('may be an existing directory outside the worktree',text)
        for action in ('hardfork-check','cap-control','archive'):
            self.assertRegex(text,action+r' --inputs')

    def test_cli_routes_every_command_with_inputs(self):
        c=self.api()
        env={'DEPLOYLIVE_EVIDENCE_DIR':str(self.root/'evidence'), 'DEFAULT_CACHE_PATH':str(self.root/'build'),
             'DEPLOYLIVE_SOURCE_RPC':'source', 'DEPLOYLIVE_SECOND_RPC':'second', 'DEPLOYLIVE_RPC':'fork'}
        with patch.object(c,'load_inputs',return_value=env) as load, patch.object(f,'ReadOnlyRPC',return_value=self.rpc()) as ro:
            f.cli(['hardfork-check','--inputs','approved.inputs'])
            load.assert_called_once_with('approved.inputs')
            self.assertEqual(ro.call_count,2)
        with patch.object(c,'load_inputs',return_value=env), patch.object(f,'RPC',return_value=self.cap_rpc()):
            f.cli(['cap-control','--inputs','approved.inputs'])
        with patch.object(c,'load_inputs',return_value=env), patch.object(f,'RPC') as rpc:
            with self.assertRaises(RuntimeError): f.cli(['cap-control','--inputs','approved.inputs','--production'])
            rpc.assert_not_called()
        with patch.object(c,'load_inputs',return_value=env), patch.object(c,'archive_records'):
            f.cli(['archive','--inputs','approved.inputs','--to',str(self.root/'copy')])
        for action in ('build','predict','deploy','hardfork-check','cap-control','archive'):
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit): f.cli([action])

    def test_cap_rpc_error_and_revert_failure(self):
        c=self.api(); rpc=self.cap_rpc(); original=rpc.side_effect
        def fail(method,*args):
            if method=='eth_sendTransaction': raise RuntimeError('injected send failure')
            return original(method,*args)
        rpc.side_effect=fail
        with self.assertRaisesRegex(RuntimeError,'send failure'): c.cap_control(rpc,self.root)
        rpc.assert_any_call('evm_revert','snap')
        self.assertFalse(json.loads((self.root/'cap-control.json').read_text())['passed'])
        rpc=self.cap_rpc(); original=rpc.side_effect
        rpc.side_effect=lambda m,*p: False if m=='evm_revert' else original(m,*p)
        with self.assertRaisesRegex(RuntimeError,'revert failed'): c.cap_control(rpc,self.root)

    def test_inputs_empty_required_and_source_inventory(self):
        c=self.api(); path=self.root/'approved.inputs'
        values={k:'value' for k in c.input_keys()}
        values.update(self.endpoint_files(c.input_keys()))
        values.update(ENV='',DEPLOYLIVE_EVIDENCE_DIR=str(self.root/'evidence'),DEFAULT_CACHE_PATH=str(self.root/'build'))
        path.write_text('\n'.join(k+'='+v for k,v in values.items()))
        with self.assertRaisesRegex(RuntimeError,'empty required input ENV'):
            c.load_inputs(path,{'DEPLOYLIVE_ENDPOINT_PROVIDER':'Fixture'},commit_reader=lambda:'a'*40)
        source='\n'.join((f.ROOT/p).read_text() for p in ('contracts/script/v3/DeployLive.s.sol','contracts/script/v3/DeployLiveInputs.sol'))
        keys=set(re.findall(r'(?:vm.env\w+|_requiredAddress|_requiredUint|_addressInput|_uintInput|_stringInput)\("([A-Z][A-Z0-9_]*)"',source))
        derived={'SP_COMMIT','DEPLOYLIVE_EVM_VERSION','DEPLOYLIVE_REHEARSAL','DEPLOYLIVE_STOP_BEFORE_BOOTSTRAP','DEPLOYLIVE_POP_REQUEST_OUT'}
        self.assertLessEqual(keys-derived,c.input_keys())

    def test_op_header_rule_and_other_rpc_error(self):
        c=self.api()
        def op(method,*args):
            if method=='eth_chainId': return '0xa'
            if method=='eth_config': raise RuntimeError('-32601 method not found')
            if method=='eth_blockNumber': return '0x64'
            return dict(number=args[0],hash='0x'+'ab'*32,timestamp=hex(1783526401))
        result=c.hardfork_check(Mock(side_effect=op),Mock(side_effect=op),self.root)
        self.assertEqual(result['chainId'],10)
        b=self.rpc(); old=b.side_effect
        def denied(m,*p):
            if m=='eth_config': raise RuntimeError('-32000 access denied')
            return old(m,*p)
        b.side_effect=denied
        with self.assertRaises(RuntimeError): c.hardfork_check(self.rpc(),b,self.root)

    def test_readonly_config_transport_and_build_input_route(self):
        rpc=f.ReadOnlyRPC('https://unused.invalid')
        rpc.opener=Mock(); rpc.opener.open.return_value=io.StringIO('{"result":{"current":{}}}')
        self.assertEqual(rpc('eth_config'), {'current':{}})
        request=rpc.opener.open.call_args.args[0]
        self.assertEqual(json.loads(request.data)['method'],'eth_config')
        c=self.api(); env={'DEPLOYLIVE_EVIDENCE_DIR':str(self.root/'evidence'),'DEFAULT_CACHE_PATH':str(self.root/'build')}
        with patch.object(c,'load_inputs',return_value=env), patch.object(f,'stage') as stage:
            f.cli(['build','--inputs','approved.inputs'])
            stage.assert_called_once_with('build',[])
            stage.reset_mock()
            f.cli(['predict','--inputs','approved.inputs'])
            stage.assert_called_once_with('predict',['--evidence',str(self.root/'evidence')])
