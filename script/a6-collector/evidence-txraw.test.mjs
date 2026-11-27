// Index tx.raw must come from the included eth_getTransactionByHash observation (non-null result whose
// blockHash is the row's inclusion block), not from the first archived record: 1 s receipt polling archives
// pre-inclusion polls (null result) before the included response.
import test from 'node:test';
import assert from 'node:assert/strict';
import { evidenceIndex } from './evidence.mjs';

const txHash='0x'+'ab'.repeat(32), blockHash='0x'+'CD'.repeat(32);
const categories=['collector','validator','dependencies','contractSources','abi','config'];
const pins=Object.fromEntries(categories.map(k=>[k,[{path:'/offline/fixture',sha256:'a'.repeat(64)}]]));
const rpcIdentity={path:'rpc-identity.json',sha256:'b'.repeat(64)};
const p={path:'passports/start.json',raw:{A:[],B:[]}};

function mkArchives() {
  return ['A','B'].map(endpoint=>({endpoint,path:`raw/${endpoint}/20261125.ndjson`,records:[]}));
}
// Same record shape as sent-window-fixture.mjs append(): base64 JSON-RPC request/response in `request`/`response`.
function append(archives,i,method,params,result) {
  const arc=archives[i], id=arc.records.length+1, ts=new Date().toISOString();
  const response=Buffer.from(JSON.stringify({jsonrpc:'2.0',id,result})).toString('base64');
  arc.records.push({path:arc.path,endpoint:arc.endpoint,id,ts,requestedAtUtc:ts,receivedAtUtc:ts,method,params,
    request:'e30=',response,requestBase64:'e30=',responseBase64:response});
}
function row(txRaw=null) {
  return {tripletIndex:0,attemptIndex:0,arm:'SP',armOrder:['SP','VPM','TPM'],verdict:'USEROP_SUCCESS',sent:true,
    chainId:10,entryPoint:'0x'+'11'.repeat(20),sender:'0x'+'22'.repeat(20),nonce:'0',paymaster:'0x'+'33'.repeat(20),
    bundler:'0x'+'44'.repeat(20),packedOp:{},callDataHash:'0x'+'ef'.repeat(32),expectedUserOpHash:'0x'+'12'.repeat(32),
    bundledOps:[{}],gas:{maxFeePerGas:'1',maxPriorityFeePerGas:'1',callGasLimit:'1',verificationGasLimit:'1',preVerificationGas:'1'},
    pmGas:{ver:'1',post:'1'},
    tx:{hash:txHash,blockNumber:'0x10',blockHash,raw:txRaw,input:'0x1234',handleOpsIndex:0,gasLimit:'21000',maxFeePerGas:'1',maxPriorityFeePerGas:'1'}};
}
const index=(r,archives)=>evidenceIndex(r,{schedule:true,windowId:'w',archives,pins,rpcIdentity,
  passports:{start:p,attempt:p,end:p},stopReason:'COMPLETE'});

test('two null pre-inclusion polls before the included response: tx.raw is the included result',()=>{
  const archives=mkArchives();
  append(archives,0,'eth_getTransactionByHash',[txHash],null);
  append(archives,0,'eth_getTransactionByHash',[txHash],null);
  const included={hash:txHash,blockHash:blockHash.toLowerCase(),blockNumber:'0x10',input:'0x1234'};
  append(archives,0,'eth_getTransactionByHash',[txHash],included);
  const x=index(row(null),archives);
  assert.deepEqual(x.tx.raw,included);
  assert.equal(x.missing['/tx/raw'],undefined);
  assert.equal(x.endpoints.A.transaction.length,3);
});

test('a non-null result with a different (or null) blockHash is not used',()=>{
  const archives=mkArchives();
  append(archives,0,'eth_getTransactionByHash',[txHash],null);
  append(archives,0,'eth_getTransactionByHash',[txHash],{hash:txHash,blockHash:'0x'+'99'.repeat(32),blockNumber:'0x11'});
  append(archives,0,'eth_getTransactionByHash',[txHash],{hash:txHash,blockHash:null,blockNumber:null});
  const kept=index(row('row-raw'),archives);
  assert.equal(kept.tx.raw,'row-raw');
  assert.equal(kept.missing['/tx/raw'],undefined);
  const absent=index(row(null),archives);
  assert.equal(absent.tx.raw,null);
  assert.equal(absent.missing['/tx/raw'],'not collected before attempt ended');
  // An earlier wrong-block record must not shadow a later included one.
  const later=mkArchives();
  append(later,0,'eth_getTransactionByHash',[txHash],{hash:txHash,blockHash:'0x'+'99'.repeat(32)});
  const included={hash:txHash,blockHash:blockHash.toLowerCase(),blockNumber:'0x10'};
  append(later,0,'eth_getTransactionByHash',[txHash],included);
  assert.deepEqual(index(row('row-raw'),later).tx.raw,included);
});

test('all-null polls keep today\'s behaviour and never overwrite tx.raw with null',()=>{
  const archives=mkArchives();
  append(archives,0,'eth_getTransactionByHash',[txHash],null);
  append(archives,0,'eth_getTransactionByHash',[txHash],null);
  const kept=index(row('row-raw'),archives);
  assert.equal(kept.tx.raw,'row-raw');
  assert.equal(kept.missing['/tx/raw'],undefined);
  const absent=index(row(null),archives);
  assert.equal(absent.tx.raw,null);
  assert.equal(absent.missing['/tx/raw'],'not collected before attempt ended');
});
