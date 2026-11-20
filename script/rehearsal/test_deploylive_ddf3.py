"""Regression evidence from e6f5c7a8; no network transport is used."""
import contextlib
import copy
import io
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, patch
from urllib.error import HTTPError
import deploylive_deploy_day as d
import deploylive_fork_deploy as f

FIX = Path(__file__).parent/'fixtures/deploy-day'


def plan():
    obj = json.loads((FIX/'plan.shape.json').read_text())
    for i, record in json.loads((FIX/'records.verbatim.json').read_text()).items():
        obj['transactions'][int(i)] = record
    return obj


def error_fixture():
    text = json.loads((FIX/'simulate.alchemy.json').read_text())['simulate-fullseq-alchemy.txt']
    return json.loads(re.search(r'ERROR (\{.*\})', text)[1])


class Ddf3Test(unittest.TestCase):
    def price_rpc(self, method, *args):
        if method == 'eth_getBlockByNumber':
            number = 12163279 if args[0] == 'latest' else int(args[0], 16)
            return dict(number=hex(number), timestamp=hex(1795027368-(12163279-number)*12), hash=hex(number))
        return '0x'+''.join(f'{v:064x}' for v in [1, 100, 1, 1795027368, 1])

    def test_price_real_proxy_selector(self):
        p=plan(); lines=[]
        self.assertIsNone(p['transactions'][45]['function'])
        self.assertEqual(p['transactions'][45]['contractName'], 'ERC1967Proxy.default')
        selector=subprocess.check_output(['cast','sig','updatePrice()'],text=True).strip()
        self.assertEqual(p['transactions'][45]['transaction']['input'], selector)
        d.price_window(p, self.price_rpc, self.price_rpc, 'feed', 4200, lines.append)
        self.assertIn('price_init_index=45', lines[0])
        # Matching calldata at another proxy must not count; two at SP must STOP.
        other=copy.deepcopy(p['transactions'][45]); other['transaction']['to']=p['transactions'][1]['contractAddress']
        p['transactions'].append(other)
        d.price_window(p,self.price_rpc,self.price_rpc,'feed',4200,lambda s:None)
        p['transactions'].append(copy.deepcopy(p['transactions'][45]))
        with self.assertRaisesRegex(RuntimeError,'exactly once'):
            d.price_window(p,self.price_rpc,self.price_rpc,'feed',4200)
        p=plan(); p['transactions'][45]['transaction']['to']=p['transactions'][1]['contractAddress']
        with self.assertRaisesRegex(RuntimeError,'exactly once'):
            d.price_window(p,self.price_rpc,self.price_rpc,'feed',4200)

    def test_inventory_real_shape_and_profiles(self):
        p=json.loads((FIX/'plan.shape.json').read_text())
        self.assertEqual([i for i,_ in d.large_creates(p)], [0,2,6,15,23,24,29,96])
        for profile in ('default','registry-size','tokens','v3-only'):
            self.assertEqual(d.contract_name('Registry.'+profile),'Registry')
        self.assertEqual(d.contract_name('Registry.unknown'),'Registry.unknown')
        p['transactions'].append(copy.deepcopy(p['transactions'][96]))
        with self.assertRaisesRegex(RuntimeError,'inventory'):
            d.large_creates(p)

    def test_fees_real_success_observations(self):
        text=json.loads((FIX/'simulate.alchemy.json').read_text())['simulate-fullseq-alchemy.txt']
        self.assertIn('97 calls; non-success: []',text)
        p=json.loads((FIX/'broadcast-97.json').read_text()); lines=[]
        observed={i:int(r['gasUsed'],16) for i,r in enumerate(p['receipts'])}
        # All 97 gas observations come from the actual broadcast receipts.
        results=[dict(calls=[dict(status='0x1',gasUsed=hex(observed[i]))]) for i in range(97)]
        p['transactions'][0]['transaction'].update(maxFeePerGas='0x1234',maxPriorityFeePerGas='0x12')
        p['transactions'][1]['transaction']['maxPriorityFeePerGas']='0x23'
        def rpc(method,*args):
            if method=='eth_getBlockByNumber':return dict(baseFeePerGas='0x64',gasLimit=hex(200_000_000))
            payload=args[0]; self.assertTrue(payload['validation'])
            calls=[b['calls'][0] for b in payload['blockStateCalls']]
            self.assertEqual(calls[0]['maxFeePerGas'],'0x1234')
            self.assertEqual(calls[0]['maxPriorityFeePerGas'],'0x12')
            self.assertEqual(calls[1]['maxFeePerGas'],hex(200+0x23))
            self.assertEqual(calls[1]['maxPriorityFeePerGas'],'0x23')
            self.assertEqual(calls[45]['maxPriorityFeePerGas'],hex(1_000_000_000))
            self.assertEqual(calls[45]['maxFeePerGas'],hex(200+1_000_000_000))
            return results
        d.gas_crosscheck(p,rpc,'0xb99f61',.05,lines.append,multiplier=130)
        self.assertTrue(any('single-endpoint' in s for s in lines))
        self.assertTrue(any('maxFeePerGas=' in s and 'maxPriorityFeePerGas=' in s for s in lines))

    def test_real_error_survives_stop_and_redacts(self):
        err=error_fixture(); rpc=f.ReadOnlyRPC('https://user:secret@example.invalid/key-secret')
        response=io.StringIO(json.dumps({'error':dict(err,message=err['message']+' https://user:secret@example.invalid/key-secret api_key=secret')}))
        rpc.opener=Mock(); rpc.opener.open.return_value=response
        with self.assertRaises(RuntimeError) as caught:rpc('eth_simulateV1',{},'latest')
        self.assertIn(str(err['code']),str(caught.exception))
        self.assertIn(err['message'],str(caught.exception))
        self.assertNotIn('secret',str(caught.exception))
        p=plan()
        def fail(method,*args):
            if method=='eth_getBlockByNumber':return dict(baseFeePerGas='0x64',gasLimit=hex(200_000_000))
            raise RuntimeError(json.dumps(err))
        with self.assertRaisesRegex(RuntimeError,'-38012.*max fee per gas less than block base fee'):
            d.gas_crosscheck(p,fail,'latest',.05,lambda s:None)

    def test_http_429_bounded_retry_and_code(self):
        rpc=f.ReadOnlyRPC('https://unused.invalid/key')
        rpc.opener=Mock()
        def limited(*args,**kwargs):
            raise HTTPError(rpc.url,429,'Too Many Requests',{},io.BytesIO(b''))
        rpc.opener.open.side_effect=limited
        with patch.object(f.time,'sleep') as sleep:
            with self.assertRaisesRegex(RuntimeError,'429.*Too Many Requests'):rpc('eth_simulateV1',{},'latest')
        self.assertEqual(rpc.opener.open.call_count,4)
        self.assertEqual([c.args[0] for c in sleep.call_args_list],[1,2,4])
        rpc.opener.open.side_effect=[HTTPError(rpc.url,429,'Too Many Requests',{},None),io.StringIO('{"result":[]}')]
        with patch.object(f.time,'sleep'):
            self.assertEqual(rpc('eth_simulateV1',{},'latest'),[])

    def test_http_body_and_bearer_redaction(self):
        rpc=f.ReadOnlyRPC('https://unused.invalid/key')
        rpc.opener=Mock()
        body=dict(error=dict(error_fixture(),data='Authorization: Bearer hidden-credential'))
        rpc.opener.open.side_effect=HTTPError(rpc.url,400,'Bad Request',{},io.BytesIO(json.dumps(body).encode()))
        with self.assertRaises(RuntimeError) as caught:rpc('eth_call',{},'latest')
        message=str(caught.exception)
        self.assertIn('400',message)
        self.assertIn('-38012',message)
        self.assertIn('max fee per gas less than block base fee',message)
        self.assertNotIn('hidden-credential',message)
        self.assertNotIn('hidden-credential',d.redact_error('Authorization: Bearer hidden-credential'))

    def test_anvil_observed_errors_retained(self):
        fixture=json.loads((FIX/'simulate.anvil-error.json').read_text())
        text=fixture['simulate-fullseq-fork.txt']
        self.assertIn('first failing index 3',text)
        for raw in re.findall(r'ERROR (\{.*\})',text):
            err=json.loads(raw)
            rpc=f.ReadOnlyRPC('https://unused.invalid')
            rpc.opener=Mock(); rpc.opener.open.return_value=io.StringIO(json.dumps(dict(error=err)))
            with self.assertRaises(RuntimeError) as caught:rpc('eth_simulateV1',{},'latest')
            self.assertIn(str(err['code']),str(caught.exception))
            self.assertIn(err['message'],str(caught.exception))

    def test_fork_price_single_endpoint_real_gas(self):
        chain,second,fork=Mock(),Mock(),Mock(side_effect=self.price_rpc)
        primary,secondary=d.price_sources({'DEPLOYLIVE_PRICE_SOURCE':'fork'},False,chain,second,fork)
        self.assertIs(primary,fork); self.assertIs(secondary,fork)
        lines=[]
        d.price_window(plan(),primary,secondary,'feed',4200,lines.append)
        self.assertEqual(fork.call_count,3)
        self.assertTrue(any('corroboration not applicable on a fork' in s for s in lines))
        chain.return_value={'number':'0x123'}
        with patch.object(d,'gas_crosscheck',return_value=([],200_000_000)) as gas:
            d.broadcast_gates({'PRICE_STALENESS_THRESHOLD':'4200','ETH_USD_FEED':'feed'},plan(),chain,None,lambda s:None,price_rpcs=(fork,None))
        self.assertIs(gas.call_args.args[1],chain)
        self.assertEqual(gas.call_args.args[2],'0x123')
        # No second URL is needed in fork-price mode, and gas retains its own real source.
        chain.return_value='0xaa36a7'
        with patch.object(f,'ReadOnlyRPC',return_value=chain) as make:
            real,other=f.gate_sources({'DEPLOYLIVE_SOURCE_RPC':'real','DEPLOYLIVE_PRICE_SOURCE':'fork'},False,11155111)
        make.assert_called_once_with('real'); self.assertIs(real,chain); self.assertIsNone(other)

    def test_fork_pin_enforced(self):
        with self.assertRaisesRegex(RuntimeError,'pin mismatch'):
            d.check_pin(dict(version='wrong',sha256='wrong'),False)

    def test_deploy_never_builds_missing_or_mismatched_stamp(self):
        for failure in ('missing build stamp','build forge/settings differs'):
            (d.ROOT/'cache/ddf3').mkdir(parents=True, exist_ok=True)  # cache/ is gitignored: absent on a fresh checkout
            with tempfile.TemporaryDirectory(dir=d.ROOT/'cache/ddf3') as tmp:
                env=dict(DEPLOYLIVE_RPC='unused',DEPLOYLIVE_EVIDENCE_DIR=tmp,ENV='ddf3',FOUNDRY_VERBOSITY='2',DEPLOYLIVE_EXPECTED_CHAIN_ID='11155111')
                cast = Path(tmp)/'cast'
                cast.symlink_to(sys.executable)
                second = Path(tmp)/'second-rpc'
                second.write_text('https://secondary.infura.io/key')
                env.update(DEPLOYLIVE_RPC='https://primary.alchemy.com/key', DEPLOYLIVE_SECOND_RPC=second.read_text(),
                           DEPLOYLIVE_SECOND_RPC_FILE=str(second), DEPLOYLIVE_ENDPOINT_PROVIDER='Alchemy',
                           DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER='Infura', CAST_1_7_1=str(cast), GOVERNANCE_OWNER='0x'+'22'*20)
                with patch('deploylive_cast.stable_cast', return_value=True), patch('deploylive_controls.verify_manifest'), patch('deploylive_controls.verify_conversion',return_value='0x'), patch.dict(f.os.environ,env,clear=True), patch.object(sys,'argv',['driver','deploy','--production','0x'+'11'*20]), patch.object(f,'clean_source_commit',return_value='a'*40), patch.object(f,'ReadOnlyRPC',return_value=lambda *a:'0xaa36a7'), patch.object(f,'build') as build, patch.object(f,'verify_build',side_effect=RuntimeError('STOP '+failure)), patch.object(f.subprocess,'run') as run:
                    with self.assertRaisesRegex(RuntimeError,failure):f.main()
                    build.assert_not_called(); run.assert_not_called()

    def test_handoff_converter_pin(self):
        text=(d.ROOT/'script/rehearsal/DEPLOYLIVE_HANDOFF.md').read_text()
        self.assertIn('cast 1.7.1',text)
        self.assertIn('CAST_1_7_1',text)
        self.assertIn('single-endpoint',text)
