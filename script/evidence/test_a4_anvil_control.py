#!/usr/bin/env python3
"""One local Anvil control; default ON. Only A4_SKIP_ANVIL=1 permits a skip."""
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
import a4_state_check as state

ROOT=Path(__file__).resolve().parents[2]
BIN=Path(os.environ.get('A4_FOUNDRY_BIN',Path.home()/'.foundry/bin'))

class AnvilControl(unittest.TestCase):
    @unittest.skipIf(os.environ.get('A4_SKIP_ANVIL')=='1','explicit A4_SKIP_ANVIL=1')
    def test_anvil_reserve_release_rereserve(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            # Isolate Forge from the repository's submodule auto-installation and build cache.
            for name in ('contracts/src','singleton-paymaster/lib/openzeppelin-contracts-v5.0.2/contracts'):
                shutil.copytree(ROOT/name,root/name)
            dest=root/'script/evidence/fixtures'; dest.mkdir(parents=True)
            shutil.copy(ROOT/'script/evidence/fixtures/A4CreditControl.sol',dest)
            (root/'foundry.toml').write_text('''[profile.default]
src = "script/evidence/fixtures"
libs = []
solc_version = "0.8.33"
evm_version = "cancun"
optimizer = true
optimizer_runs = 10000
via_ir = true
remappings = ["src/=contracts/src/", "@openzeppelin-v5.0.2/=singleton-paymaster/lib/openzeppelin-contracts-v5.0.2/"]
''')
            version=subprocess.check_output([str(BIN/'forge'),'--version'],text=True).splitlines()[0]
            self.assertIn('1.7.1',version)
            subprocess.run([str(BIN/'forge'),'build','--offline','--root',str(root)],check=True,capture_output=True)
            artifact=json.loads((root/'out/A4CreditControl.sol/A4CreditControl.json').read_text())
            with socket.socket() as sock:
                try:
                    sock.bind(('127.0.0.1',0))
                except OSError as error:
                    (ROOT/'script/evidence/a4-anvil-control-result.json').write_text(json.dumps({
                        'scope':'local-anvil-instrument-control', 'result':'BLOCKED',
                        'forge':version, 'build':'PASS', 'anvilStarted':False, 'skipped':False,
                        'reason':'sandbox denied localhost socket bind', 'errno':error.errno,
                        'tests':{'run':1,'passed':0,'errors':1,'skipped':0}},indent=2)+'\n')
                    raise
                port=sock.getsockname()[1]
            url=f'http://127.0.0.1:{port}'
            with (root/'anvil.log').open('w') as output:
                proc=subprocess.Popen([str(BIN/'anvil'),'--host','127.0.0.1','--port',str(port),'--chain-id','31337','--hardfork','cancun'],stdout=output,stderr=output)
                try:
                    for _ in range(100):
                        if proc.poll() is not None: self.fail('Anvil exited')
                        try:
                            accounts=state.logs.rpc(url,'eth_accounts',[]); break
                        except state.logs.RpcFailure: time.sleep(.05)
                    else: self.fail('Anvil startup timeout')
                    sender,user=accounts[:2]; op='0x'+'ab'*32
                    def mine(n):
                        # anvil_mine returns a JSON null result, which the strict scanner rpc() rejects by design.
                        import urllib.request as request
                        body=json.dumps({'jsonrpc':'2.0','id':1,'method':'anvil_mine','params':[n]}).encode()
                        with request.urlopen(request.Request(url,body,{'Content-Type':'application/json'}),timeout=30) as r:
                            reply=json.load(r)
                        self.assertNotIn('error',reply); self.assertIsNone(reply.get('result'))
                    def send(data,to=None):
                        tx={'from':sender,'data':data,'gas':'0x989680'}
                        if to: tx['to']=to
                        h=state.logs.rpc(url,'eth_sendTransaction',[tx])
                        # Anvil 1.7 mines asynchronously after accepting the transaction: poll, bounded.
                        for _ in range(200):
                            try:
                                receipt=state.logs.rpc(url,'eth_getTransactionReceipt',[h]); break
                            except state.logs.RpcFailure: time.sleep(.05)
                        else: self.fail('receipt not mined within 10 s: '+h)
                        self.assertEqual(receipt['status'],'0x1')
                        return receipt
                    deployed=send(artifact['bytecode']['object']+state.word(user))
                    token=deployed['contractAddress']; start=int(deployed['blockNumber'],16)
                    def reserve(): return send(state.cast('sig','tryReserveCredit(address,bytes32,uint256)')+state.word(user)+state.word(op)+f'{0:064x}',token)
                    def release(): return send(state.cast('sig','releaseStaleCredit(address,bytes32)')+state.word(user)+state.word(op),token)
                    reserve(); release(); last=reserve()
                    end=int(last['blockNumber'],16)
                    # Same local node via two URL paths is instrumentation only, not independence evidence.
                    mine('0x40')
                    opened=state.logs.scan([url,url+'/'],[token],start,end)
                    self.assertTrue(opened['complete'],opened.get('C7'))
                    self.assertEqual((opened['C7']['verdict'],opened['C7']['openCount'],opened['C7']['counts']['CreditReserved']),('fail',1,2))
                    closed_receipt=release(); end2=int(closed_receipt['blockNumber'],16)
                    mine('0x40')
                    closed=state.logs.scan([url,url+'/'],[token],start,end2)
                    self.assertEqual((closed['complete'],closed['C7']['verdict'],closed['C7']['openCount']),(True,'pass',0))
                    record={'scope':'local-anvil-instrument-control','forge':version,'chainId':31337,
                            'sequence':['reserve(0)','release','re-reserve(0)','release'],
                            'productionMethods':True,'independentProviders':False,
                            'open':opened['C7'],'closed':closed['C7'],'result':'PASS'}
                    # Discard addresses/tx hashes from the portable run record.
                    for c in ('open','closed'): record[c].pop('openReservations',None)
                    (ROOT/'script/evidence/a4-anvil-control-result.json').write_text(json.dumps(record,indent=2)+'\n')
                finally:
                    proc.terminate()
                    try: proc.wait(timeout=5)
                    except subprocess.TimeoutExpired: proc.kill(); proc.wait()

if __name__=='__main__': unittest.main()
