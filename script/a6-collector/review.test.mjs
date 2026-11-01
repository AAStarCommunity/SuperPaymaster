import { archivedParamsAllowed, supportsCall } from './state-evidence.mjs';
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, realpathSync, rmSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { repairFixture } from './repair-fixture.mjs';
import { artifactErrors } from './artifact-validate.mjs';
import { windowErrors } from './evidence-validate.mjs';
import { exclusionReason, EXCLUSION_REASONS } from './evidence.mjs';
import { parseAbi, decodeErrorResult, encodeErrorResult } from 'viem';
const H='0x'+'ab'.repeat(32);
function temp(fn) {const d=realpathSync(mkdtempSync('/tmp/a6-review-'));try{return fn(d);}finally{rmSync(d,{recursive:true,force:true});}}
function editRaw(d,path,fn) {
  const records=readFileSync(join(d,path),'utf8').trim().split('\n').map(JSON.parse);fn(records);
  writeFileSync(join(d,path),records.map(JSON.stringify).join('\n')+'\n');
}
function request(raw) {const q=JSON.parse(Buffer.from(raw.request,'base64'));Object.assign(q,{method:raw.method,params:raw.params});raw.request=raw.requestBase64=Buffer.from(JSON.stringify(q)).toString('base64');}
function fixture(d) {
  const f=repairFixture(d,3),trailer={finalBlockCheck:f.finalBlockCheck,endPassport:f.passport,triples:[{tripleIndex:0,included:false,attempts:[0,1,2]}]};
  return {...f,trailer,check:()=>artifactErrors(d,f.rows,trailer,[f.start,...f.attempts])};
}
test('H continuity rejects TPM token/cache changes and limits rehearsal timestamp exemption',()=>temp(d=>{
  const rows=readFileSync(new URL('../../docs/design/aoa-balance-mode/data/a6-gauge-local/n50-mechanism.jsonl',import.meta.url),'utf8').trim().split('\n').map(JSON.parse);
  const tpm=rows.filter(r=>r.kind==='attempt' && r.arm==='TPM');assert.ok(tpm.length>1);
  for(const r of tpm) for(const side of ['before','after']) for(const e of ['A','B']) Object.assign(r.readbacks[side][e],{tpmCachedPriceTimestamp:'10',tpmTokenBalances:{sender:'5',paymaster:'7'}});
  const run=()=>{const p=join(d,'run.jsonl');writeFileSync(p,rows.map(JSON.stringify).join('\n')+'\n');const out=spawnSync(process.execPath,['script/a6-collector/validate.mjs',p],{encoding:'utf8'});return JSON.parse(out.stdout);};
  assert.equal(run().consistent,true);
  for(const [field,value] of [['tpmCachedPriceTimestamp','11'],['tpmTokenBalances',{sender:'6',paymaster:'7'}],['tpmTokenBalances',{sender:'5',paymaster:'8'}]]) {
    const r=tpm[1],old=r.readbacks.before.A[field];
    for(const e of ['A','B'])r.readbacks.before[e][field]=value;
    assert.match(run().errors.join(';'),new RegExp('balance continuity failed: '+field));
    for(const e of ['A','B'])r.readbacks.before[e][field]=old;
  }
  const vpm=rows.filter(r=>r.kind==='attempt' && r.arm==='VPM')[1];
  for(const field of ['epDeposit','operatorBalance']) {
    const old=vpm.readbacks.before.A[field];
    for(const e of ['A','B'])vpm.readbacks.before[e][field]=String(BigInt(old)+1n);
    assert.match(run().errors.join(';'),new RegExp('balance continuity failed: '+field));
    for(const e of ['A','B'])vpm.readbacks.before[e][field]=old;
  }
  rows[0].rehearsal=true;rows.at(-1).rehearsal=true;
  tpm[1].rehearsalControl={kind:'tpmCacheAged',cachedPriceTimestamp:{to:'11'}};
  assert.match(run().errors.join(';'),/rehearsal cache timestamp mismatch/);
  // The collector reads the uint48 back as a JSON number; the control records a decimal string (real rehearsal shape).
  for(const e of ['A','B'])tpm[1].readbacks.before[e].tpmCachedPriceTimestamp=11;
  assert.doesNotMatch(run().errors.join(';'),/rehearsal cache timestamp mismatch|balance continuity failed: tpmCachedPriceTimestamp/);
  for(const e of ['A','B'])tpm[1].readbacks.before[e].tpmTokenBalances.sender='99';
  assert.match(run().errors.join(';'),/balance continuity failed: tpmTokenBalances/);
}));
test('H archive allowlist rejects mutation and scopes rehearsal writes to controlled attempt blocks',()=>temp(d=>{
  const f=fixture(d);assert.deepEqual(f.check(),[]);
  const path=f.archives[0].records[0].path,saved=readFileSync(join(d,path));
  const extraPath=f.archives[0].records.at(-1).path,extraSaved=readFileSync(join(d,extraPath));
  const insert=method=>editRaw(d,extraPath,rs=>{
    const raw=structuredClone(rs.at(-1));Object.assign(raw,{id:raw.id+1,method,params:[],blockAnchor:null,anchor:null});request(raw);rs.push(raw);
  });
  for(const method of ['anvil_setStorageAt','evm_mine','hardhat_setBalance','debug_setHead','eth_sendTransaction','personal_unlockAccount','unknown_method']) {
    insert(method);assert.match(f.check().join(';'),/archived RPC method forbidden/);writeFileSync(join(d,extraPath),extraSaved);
  }
  f.start.rehearsal=f.trailer.rehearsal=true;
  const a=f.attempts[2];a.rehearsalControl={kind:'tpmCacheAged',atBlock:'103',cachedPriceTimestamp:{to:'10'}};
  // Replace an existing nonessential send record, preserving strict archive ID order.
  for(const method of ['anvil_setStorageAt','evm_mine']) for(const number of ['102','103','104']) {
    editRaw(d,path,rs=>{const raw=rs.find(r=>r.method==='eth_sendRawTransaction' && r.id>a.evidenceStart[0]);Object.assign(raw,{method,params:[],blockAnchor:{number,hash:H},anchor:null});request(raw);});
    if(number==='103') assert.doesNotMatch(f.check().join(';'),/archived RPC method forbidden/);
    else assert.match(f.check().join(';'),/archived RPC method forbidden/);
    writeFileSync(join(d,path),saved);
  }
  delete a.rehearsalControl;insert('evm_mine');assert.match(f.check().join(';'),/archived RPC method forbidden/);
}));
test('M1 exact archived tracer options reject extra nested and top-level options',()=>temp(d=>{
  const f=fixture(d);assert.deepEqual(f.check(),[]);
  for(const endpoint of ['A','B']) for(const tracer of ['callTracer','prestateTracer']) for(const [key,value,nested] of [['disableStorage',true,true],['disableCode',true,true],['onlyTopCall',true,true],['timeout','1s',false]]) {
    const path=f.rows[2].trace.raw[endpoint][0].path,saved=readFileSync(join(d,path));
    editRaw(d,path,rs=>{for(const raw of rs)if(raw.method==='debug_traceTransaction' && raw.params[1].tracer===tracer){(nested?raw.params[1].tracerConfig:raw.params[1])[key]=value;request(raw);}});
    assert.match(f.check().join(';'),/exact tracer config required/);writeFileSync(join(d,path),saved);
  }
}));
test('M2 labels cannot manufacture exclusion evidence or override decoded reasons',()=>{
  for(const reason of EXCLUSION_REASONS) assert.throws(()=>exclusionReason({reason,verdict:'NOT_SENT'}),/UNAPPROVED_ABANDONMENT/,reason);
  assert.throws(()=>exclusionReason({reason:'AA32',preflight:{revertReason:'price stale'}}),/UNAPPROVED_ABANDONMENT/);
  assert.throws(()=>exclusionReason({reason:'not_included',sent:true,verdict:'NO_EVENT',logs:[],tx:{hash:H,blockHash:H,blockNumber:'1',status:'success'}}),/UNAPPROVED_ABANDONMENT/);
  assert.equal(exclusionReason({reason:'bundler_error',submissionException:{message:'submission threw'}}),'bundler_error');
  assert.equal(exclusionReason({sent:true,tx:{hash:H},logs:[],verdict:'NO_EVENT'}),'not_included');
});
test('M2 artifact validation recomputes indexed exclusion labels',()=>temp(d=>{
  const f=fixture(d);assert.deepEqual(f.check(),[]);
  f.rows[0].exclusionReason='AA32';assert.match(f.check().join(';'),/exclusionReason mismatch/);
}));
test('M2 row and replacement validators reject unsupported exclusion labels',()=>temp(d=>{
  const f=fixture(d),a=f.attempts[0];a.reason='AA32';a.verdict='NOT_SENT';f.rows[0].verdict='NOT_SENT';f.rows[0].exclusionReason='AA32';
  const trailer={...f.trailer,schemaVersion:'a6-evidence-trailer/1',windowId:'w',stopAttempt:2,replacements:[{abandoned:{windowId:'w',tripleIndex:0},replacement:{windowId:'w',tripleIndex:1},reason:'AA32'}]};
  const errors=windowErrors(f.rows,trailer,[f.start,...f.attempts,{kind:'run_end',stop:{code:0}}]);
  assert.match(errors.join(';'),/UNAPPROVED_ABANDONMENT/);assert.match(errors.join(';'),/unsupported replacement exclusion reason/);
}));

// Concrete request/response JSON copied from a6-rehearsal.z9J5vF/window/raw/A/20261101.ndjson.
// IDs identify the source records; attempt 1 owns (558, 723], including the FailedOp at 723.
// Keep these literal wire shapes: synthesizing them previously hid collector incompatibilities.
const rehearsalRpc = {
  "eth_call": {
    "endpoint": "A",
    "id": 5,
    "blockAnchor": {
      "number": "119",
      "hash": "0x033248ae345db49621fef1f231da31e9479252cc162e7e2b45d8488f35427b7b"
    },
    "request": {
      "jsonrpc": "2.0",
      "id": "A-5",
      "method": "eth_call",
      "params": [
        {
          "data": "0x8cb84e18000000000000000000000000f39fd6e51aad88f6f4ce6ab8827279cfffb922660000000000000000000000000000000000000000000000000000000000002329",
          "to": "0xa82fF9aFd8f496c3d6ac40E2a0F282E47488CFc9"
        },
        "0x77"
      ]
    },
    "response": {
      "jsonrpc": "2.0",
      "id": "A-5",
      "result": "0x00000000000000000000000043a71246698e5be1d9fb04183589eda602ea06f1"
    }
  },
  "eth_getCode": {
    "endpoint": "A",
    "id": 24,
    "blockAnchor": {
      "number": "119",
      "hash": "0x033248ae345db49621fef1f231da31e9479252cc162e7e2b45d8488f35427b7b"
    },
    "request": {
      "jsonrpc": "2.0",
      "id": "A-24",
      "method": "eth_getCode",
      "params": [
        "0xDC17C27Ae8bE831AF07CC38C02930007060020F4",
        "0x77"
      ]
    },
    "response": {
      "jsonrpc": "2.0",
      "id": "A-24",
      "result": "0x363d3d373d3d3d363d734a679253410272dd5232b3ff7cf5dbb88f2953195af43d82803e903d91602b57fd5bf3"
    }
  },
  "eth_getStorageAt": {
    "endpoint": "A",
    "id": 50,
    "blockAnchor": {
      "number": "119",
      "hash": "0x033248ae345db49621fef1f231da31e9479252cc162e7e2b45d8488f35427b7b"
    },
    "request": {
      "jsonrpc": "2.0",
      "id": "A-50",
      "method": "eth_getStorageAt",
      "params": [
        "0x68B1D87F95878fE05B998F19b66F4baba5De1aed",
        "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc",
        "0x77"
      ]
    },
    "response": {
      "jsonrpc": "2.0",
      "id": "A-50",
      "result": "0x0000000000000000000000009a9f2ccfde556a7e9ff0848998aa4a0cfd8863ae"
    }
  },
  "eth_chainId": {
    "endpoint": "A",
    "id": 1,
    "blockAnchor": null,
    "request": {
      "jsonrpc": "2.0",
      "id": "A-1",
      "method": "eth_chainId",
      "params": []
    },
    "response": {
      "jsonrpc": "2.0",
      "id": "A-1",
      "result": "0x7a69"
    }
  },
  "blockHashes": {
    "endpoint": "A",
    "id": 3,
    "blockAnchor": {
      "number": "119",
      "hash": "0x033248ae345db49621fef1f231da31e9479252cc162e7e2b45d8488f35427b7b"
    },
    "request": {
      "jsonrpc": "2.0",
      "id": "A-3",
      "method": "eth_getBlockByNumber",
      "params": [
        "0x77",
        false
      ]
    },
    "response": {
      "jsonrpc": "2.0",
      "id": "A-3",
      "result": {
        "hash": "0x033248ae345db49621fef1f231da31e9479252cc162e7e2b45d8488f35427b7b",
        "parentHash": "0xea52bb3cb289cec640405b711c19d335e6dbce67725e7220949dc43499970dc2",
        "sha3Uncles": "0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347",
        "miner": "0x0000000000000000000000000000000000000000",
        "stateRoot": "0x34dbb8d7398f13f63deaaf9175ddeebf503199b9683ec22a1781968d73ac8775",
        "transactionsRoot": "0x0eefe2ae32f1da4d02cde156ce6a150a99cc09702098d4d478e95c7c729ecd36",
        "receiptsRoot": "0x2f5f8cd25052eb8d61af92bcd85d5cfd75b368763eeaec1afe3b6cceedcd59e7",
        "logsBloom": "0x00000000000000000000000002000020000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000040000000000000000000000000000000000",
        "difficulty": "0x0",
        "number": "0x77",
        "gasLimit": "0x1c9c380",
        "gasUsed": "0x846c",
        "timestamp": "0x6ae6eee9",
        "extraData": "0x",
        "mixHash": "0x818b0dc276fcddf328ea6ff62999b299a6cc683787ac8fbed7e9ec3d67918402",
        "nonce": "0x0000000000000000",
        "baseFeePerGas": "0x131",
        "withdrawalsRoot": "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421",
        "blobGasUsed": "0x0",
        "excessBlobGas": "0x0",
        "parentBeaconBlockRoot": "0x0000000000000000000000000000000000000000000000000000000000000000",
        "requestsHash": "0xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "totalDifficulty": "0x0",
        "size": "0x35e",
        "uncles": [],
        "transactions": [
          "0xe9ac878a28c69a5e7500f89e89b9d4e09d5bd606f1efcbc985a38527826e1853"
        ],
        "withdrawals": []
      }
    }
  },
  "blockTransactions": {
    "endpoint": "A",
    "id": 345,
    "blockAnchor": {
      "number": "122",
      "hash": "0x95ba82edb0f6283b7a680f0c09b74c9f89e83f51eb64455b021e747c4e68b3cc"
    },
    "request": {
      "jsonrpc": "2.0",
      "id": "A-345",
      "method": "eth_getBlockByNumber",
      "params": [
        "0x7a",
        true
      ]
    },
    "response": {
      "jsonrpc": "2.0",
      "id": "A-345",
      "result": {
        "hash": "0x95ba82edb0f6283b7a680f0c09b74c9f89e83f51eb64455b021e747c4e68b3cc",
        "parentHash": "0x0cdfa90fffd52e7c09847b07ab7ab1763d983ed881b4467b0cdf47d5face39de",
        "sha3Uncles": "0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347",
        "miner": "0x0000000000000000000000000000000000000000",
        "stateRoot": "0x37cd6910f5a678d0b748837452fa61947e11b9d266c79317a819219f70ac81bc",
        "transactionsRoot": "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421",
        "receiptsRoot": "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421",
        "logsBloom": "0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        "difficulty": "0x0",
        "number": "0x7a",
        "gasLimit": "0x1c9c380",
        "gasUsed": "0x0",
        "timestamp": "0x6ae6eeec",
        "extraData": "0x",
        "mixHash": "0x4a618b42e185508178e4e8c971e25944a57d573219db49b65c409fb0a7eab174",
        "nonce": "0x0000000000000000",
        "baseFeePerGas": "0xcd",
        "withdrawalsRoot": "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421",
        "blobGasUsed": "0x0",
        "excessBlobGas": "0x0",
        "parentBeaconBlockRoot": "0x0000000000000000000000000000000000000000000000000000000000000000",
        "requestsHash": "0xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "totalDifficulty": "0x0",
        "size": "0x264",
        "uncles": [],
        "transactions": [],
        "withdrawals": []
      }
    }
  },
  "latest": {
    "endpoint": "A",
    "id": 1437,
    "blockAnchor": {
      "number": "145",
      "hash": "0x73ed70d6a6bf6e26ee945d9db1e8491495b8065fd5fe840b95d980293b0999e8"
    },
    "request": {
      "jsonrpc": "2.0",
      "id": "A-1437",
      "method": "eth_getBlockByNumber",
      "params": [
        "latest",
        false
      ]
    },
    "response": {
      "jsonrpc": "2.0",
      "id": "A-1437",
      "result": {
        "hash": "0x73ed70d6a6bf6e26ee945d9db1e8491495b8065fd5fe840b95d980293b0999e8",
        "parentHash": "0x1c7a0104ec993b3d8cbf602b3522b73d5abb5aa8f36715d3671699198d1dac42",
        "sha3Uncles": "0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347",
        "miner": "0x0000000000000000000000000000000000000000",
        "stateRoot": "0x27663fd5256cda0f8f31c2a2f74a3a24d8de4fcd3eb6932b7a7a0b95ece3bd8e",
        "transactionsRoot": "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421",
        "receiptsRoot": "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421",
        "logsBloom": "0x00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
        "difficulty": "0x0",
        "number": "0x91",
        "gasLimit": "0x1c9c380",
        "gasUsed": "0x0",
        "timestamp": "0x6ae6ef03",
        "extraData": "0x",
        "mixHash": "0x601ca546d86edc394e0b1d2d06e81903b6c5de1194670b98056c96f561a55e4b",
        "nonce": "0x0000000000000000",
        "baseFeePerGas": "0xd",
        "withdrawalsRoot": "0x56e81f171bcc55a6ff8345e692c0f86e5b48e01b996cadc001622fb5e363b421",
        "blobGasUsed": "0x0",
        "excessBlobGas": "0x0",
        "parentBeaconBlockRoot": "0x0000000000000000000000000000000000000000000000000000000000000000",
        "requestsHash": "0xe3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "totalDifficulty": "0x0",
        "size": "0x264",
        "uncles": [],
        "transactions": [],
        "withdrawals": []
      }
    }
  },
  "preflight": {
    "endpoint": "A",
    "id": 723,
    "blockAnchor": {
      "number": "130",
      "hash": "0xa6dbabb7e7784ec7b3b0877d1c0053f39953bd27afb843c7eb81d7b67dd33bb4"
    },
    "request": {
      "jsonrpc": "2.0",
      "id": "A-723",
      "method": "eth_call",
      "params": [
        {
          "data": "0x765e827f000000000000000000000000000000000000000000000000000000000000004000000000000000000000000070997970c51812dc3a010c7d01b50e0d17dc79c80000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000002000000000000000000000000043a71246698e5be1d9fb04183589eda602ea06f1000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000001200000000000000000000000000000000000000000000000000000000000000140000000000000000000000000000493e000000000000000000000000000030d40000000000000000000000000000000000000000000000000000000000000ea600000000000000000000000003b9aca000000000000000000000000012a05f20000000000000000000000000000000000000000000000000000000000000002600000000000000000000000000000000000000000000000000000000000000340000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e4b61d27f60000000000000000000000005067457698fd6fa1c6964e416b3f42713513b3dd000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000044a9059cbb00000000000000000000000090f79bf6eb2c4f870365e785982e1f101e93b9060000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b5f4B146FbA71F41E0592668ffbF264F1D186b2Ca80000000000000000000000000006ddd000000000000000000000000000075300000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000007a5b9b39e7fe2599a2c53ec594bf210462a55e867b602b02279aa1fc13e19e591197f96008a973aa9d6612d6068b447fcec80ade6a1f051fe8a2b9af51827ccb1b00000000000000000000000000000000000000000000000000000000000000000000000000000000000041a089367a9cbdaa4ce5311368048c7be3f837b9b594d28a6b492e005175d1a82e60020bb05767072f913b721981ff8176610918b0d4bb1e04e8e68cbfae7449aa1c00000000000000000000000000000000000000000000000000000000000000",
          "from": "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
          "to": "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"
        },
        "0x82"
      ]
    },
    "response": {
      "jsonrpc": "2.0",
      "id": "A-723",
      "error": {
        "code": 3,
        "message": "execution reverted: custom error 0x220266b6: \u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000@\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000!AA32 paymaster expired or not due\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000\u0000",
        "data": "0x220266b600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000040000000000000000000000000000000000000000000000000000000000000002141413332207061796d61737465722065787069726564206f72206e6f742064756500000000000000000000000000000000000000000000000000000000000000"
      }
    }
  }
};
const rehearsalAttempt = {
  "attemptIndex": 1,
  "chainId": 31337,
  "expectedUserOpHash": "0xdd9bf6bb881b9c98f1d28c1b78a5c8ac0bfcae98ede4041e6a02a6229f0b273a",
  "evidenceStart": [
    558,
    537
  ],
  "evidenceEnd": [
    723,
    695
  ],
  "bundledOps": [
    {
      "sender": "0x43a71246698E5bE1D9fb04183589edA602EA06F1",
      "nonce": "4",
      "initCode": "0x",
      "callData": "0xb61d27f60000000000000000000000005067457698fd6fa1c6964e416b3f42713513b3dd000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000600000000000000000000000000000000000000000000000000000000000000044a9059cbb00000000000000000000000090f79bf6eb2c4f870365e785982e1f101e93b906000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000",
      "accountGasLimits": "0x000000000000000000000000000493e000000000000000000000000000030d40",
      "preVerificationGas": "60000",
      "gasFees": "0x0000000000000000000000003b9aca000000000000000000000000012a05f200",
      "paymasterAndData": "0xf4B146FbA71F41E0592668ffbF264F1D186b2Ca80000000000000000000000000006ddd000000000000000000000000000075300000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000007a5b9b39e7fe2599a2c53ec594bf210462a55e867b602b02279aa1fc13e19e591197f96008a973aa9d6612d6068b447fcec80ade6a1f051fe8a2b9af51827ccb1b",
      "signature": "0xa089367a9cbdaa4ce5311368048c7be3f837b9b594d28a6b492e005175d1a82e60020bb05767072f913b721981ff8176610918b0d4bb1e04e8e68cbfae7449aa1c"
    }
  ],
  "bundler": "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",
  "entryPoint": "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",
  "sender": "0x43a71246698E5bE1D9fb04183589edA602EA06F1",
  "preflight": {
    "infraFailure": false,
    "sponsorshipFailed": true,
    "revertReason": "AA32 paymaster expired or not due"
  },
  "sent": false,
  "tx": null,
  "verdict": "NOT_SENT"
};
function archived(sample) {
  const {request:q,response,...metadata}=structuredClone(sample);
  const encode=v=>Buffer.from(JSON.stringify(v)).toString('base64');
  return {...metadata,method:q.method,params:q.params,request:encode(q),response:encode(response)};
}

test('H-A real collector requests accept both block modes and reject extra params',()=>{
  for(const [name,sample] of Object.entries(rehearsalRpc)) {
    const raw=archived(sample);
    assert.equal(archivedParamsAllowed(raw),true,name);
    raw.params.push({});
    assert.equal(archivedParamsAllowed(raw),false,name);
  }
  for(const name of ['blockHashes','blockTransactions','latest']) for(const value of [0,1,'false','true',null,{}]) {
    const raw=archived(rehearsalRpc[name]);raw.params[1]=value;
    assert.equal(archivedParamsAllowed(raw),false,name);
  }
});
test('H-A real calls reject overrides and non-collector transaction fields',()=>{
  for(const name of ['eth_call','preflight']) for(const key of ['input','gas','value','stateOverride','blockOverride']) {
    const raw=archived(rehearsalRpc[name]);raw.params[0][key]='0x00';
    assert.equal(archivedParamsAllowed(raw),false,key);
  }
});
test('H-A real state evidence cannot use overridden calls',()=>{
  const raw=archived(rehearsalRpc.eth_call),anchor=raw.blockAnchor;
  const call={...raw.params[0],expected:BigInt(rehearsalRpc.eth_call.response.result),index:0};
  assert.equal(supportsCall(raw,call,anchor),true);
  raw.params.push({});assert.equal(supportsCall(raw,call,anchor),false);
  raw.params.pop();raw.params[0].gas='0x1';assert.equal(supportsCall(raw,call,anchor),false);
});
test('H-B real FailedOp binds to the attempt simulation on A, not invented reasons',()=>{
  const a=structuredClone(rehearsalAttempt),raw=archived(rehearsalRpc.preflight);
  const check=r=>exclusionReason(a,[{records:[r]},{records:[]}]);
  assert.equal(check(raw),'AA32');
  assert.throws(()=>exclusionReason(a),/raw preflight evidence/);
  assert.throws(()=>exclusionReason(a,[{records:[]},{records:[raw]}]),/raw preflight evidence/);
  // Re-encode metadata mutations so rejection proves binding, not stale request bytes.
  for(const mutate of [
    r=>r.endpoint='B',
    r=>r.id=a.evidenceStart[0],
    r=>r.id=a.evidenceEnd[0]+1,
    r=>r.params[0].from=a.sender,
    r=>r.params[0].to=a.sender,
    r=>r.params[0].data='0x12345678',
    r=>r.params.push({}),
    r=>r.params[0].gas='0x1',
    r=>r.response=archived(rehearsalRpc.eth_call).response,
    r=>{const response=structuredClone(rehearsalRpc.preflight.response);response.id='wrong-id';r.response=Buffer.from(JSON.stringify(response)).toString('base64');},
    r=>{const response=structuredClone(rehearsalRpc.preflight.response);delete response.error.data;r.response=Buffer.from(JSON.stringify(response)).toString('base64');},
    r=>{const response=structuredClone(rehearsalRpc.preflight.response);response.result='0x';r.response=Buffer.from(JSON.stringify(response)).toString('base64');},
  ]) {
    const bad=structuredClone(raw);mutate(bad);request(bad);
    assert.throws(()=>check(bad),/raw preflight evidence/);
  }
  // A FailedOp naming another bundle index does not describe the selected operation (round-7 counterexample).
  {
    const bad=structuredClone(raw),response=structuredClone(rehearsalRpc.preflight.response);
    const failedOp=parseAbi(['error FailedOp(uint256 opIndex,string reason)']);
    const {args}=decodeErrorResult({abi:failedOp,data:response.error.data});
    response.error.data=encodeErrorResult({abi:failedOp,errorName:'FailedOp',args:[1n,args[1]]});
    bad.response=Buffer.from(JSON.stringify(response)).toString('base64');request(bad);
    assert.throws(()=>check(bad),/raw preflight evidence/);
  }
  for(const reason of ['price_stale','AA32 invented reason']) {
    a.preflight.revertReason=reason;assert.throws(()=>check(raw),/raw preflight evidence/);
  }
});
test('H-B successful attempts cannot manufacture preflight exclusions',()=>{
  const a=structuredClone(rehearsalAttempt);
  a.sent=true;a.verdict='USEROP_SUCCESS';
  assert.throws(()=>exclusionReason(a,[{records:[archived(rehearsalRpc.preflight)]}]),/successful attempt contradicts failure evidence/);
});
