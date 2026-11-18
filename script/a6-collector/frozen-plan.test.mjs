import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { encodeAbiParameters, keccak256, toHex } from 'viem';
import { createFrozenPlan, persistSettlement } from './frozen-plan.mjs';
const bytes=execFileSync('python3.11',['-B','script/a6-collector/frozen-fixture.py']);
const sha=createHash('sha256').update(bytes).digest('hex');
const account='0x'+(200).toString(16).padStart(40,'0');
const adapter=()=>createFrozenPlan({readBundle:()=>bytes,bundleSha256:sha,account});
const hash='0x'+'33'.repeat(32);
function runtime(a, change={}) {
 const pc=a.plan.phaseC;
 const block={number:32n,hash:'0x'+'12'.repeat(32),baseFeePerGas:100000000n,...change.block};
 const client={getChainId:async()=>change.chainId??10,getBlock:async()=>block,
 readContract:async ({functionName,blockNumber})=>{
 assert.equal(blockNumber,32n);
 if(functionName==='gasParams') return change.gas??pc.gasTuple.map(BigInt);
 return change.stake??[0n,true,1000000000000000000n,86400,0n];
 }};
 return {refreshPin:async()=>block,pubA:client,pubB:change.pubB??client};
}
function receipt(a,branch='balance') {
 return {status:'success',logs:[{address:a.plan.phaseC.addresses.X,topics:[keccak256(toHex(branch==='balance'?'LockSettled(address,bytes32,uint256,uint256)':'CreditSettled(address,bytes32,uint256)')),'0x'+account.slice(2).padStart(64,'0'),hash],data:encodeAbiParameters(branch==='balance'?[{type:'uint256'},{type:'uint256'}]:[{type:'uint256'}],branch==='balance'?[1n,0n]:[1n])}]};
}
const persist=row=>JSON.parse(JSON.stringify(row,(_,v)=>typeof v==='bigint'?v.toString():v));
test('real planner matched triplet carries exact gas, fees, provenance and allocation through receipt persistence',async()=>{
 const a=adapter(), rows=[];
 for(const arm of ['SP','VPM','TPM']) {
 const row=a.row(arm,0);
 const rt=runtime(a); rt.writeContract=async args=>{assert.equal(args.gas,BigInt(a.plan.phaseC.bounds[arm].outer)); return receipt(a);};
 const rc=await a.send(rt,arm,{functionName:"handleOps"});
 row.gas=a.frozen.gas[arm]; row.pmGas=a.frozen.pmGas[arm];
 persistSettlement(row,rc,{arm,token:a.plan.phaseC.addresses.X,user:account,hash,planned:a.plan.phaseC.spBranch},r=>rows.push(persist(r)));
 assert.deepEqual(row.gasSources,a.plan.phaseC.gasSources[arm]);
 assert.deepEqual(row.spPostOpRule,a.plan.phaseC.spPostOpRule);
 assert.deepEqual(row.feeRule,a.plan.phaseC.feeRule);
 assert.equal(row.planDigest,a.digest); assert.equal(row.bundleSha256,sha);
 assert.deepEqual(row.allocation,{S:account,arm,tripletIndex:0,attempts:34});
 assert.equal(row.gas.callGasLimit,BigInt(a.plan.phaseC.bounds[arm].call));
 assert.equal(row.gas.maxFeePerGas,BigInt(a.plan.phaseC.feeCap));
 assert.equal(row.pmGas.post,BigInt(a.plan.phaseC.bounds[arm].postOp));
 }
 assert.deepEqual(rows[0].spBranch,{planned:'balance',observed:'balance',event:'LockSettled(address,bytes32,uint256,uint256)'});
 assert.equal(rows.length,3);
});
for(const [name,change,code] of [
 ['minPostOpGas',{gas:[1n,400000n,10000n,10000n,0n,0n,0n,0n,0n]},'PLAN_GAS_CHANGED'],
 ['stake',{stake:[0n,true,1000000000000000001n,86400,0n]},'PLAN_STAKE_CHANGED'],
 ['base fee',{block:{baseFeePerGas:999999999999n}},'PLAN_FEE_CHANGED'],
 ['chain',{chainId:1},'PLAN_CHAIN_CHANGED'],
 ['endpoint disagreement',{pubB:{getChainId:async()=>1}},'PLAN_CHAIN_CHANGED']]) test(`stops before send on ${name}`,async()=>{
 const a=adapter(); await assert.rejects(a.beforeSend(runtime(a,change)),{message:code});
});
test('whole plan and bundle mutation stop before every send',async()=>{
 const a=adapter(); await a.beforeSend(runtime(a)); a.plan.commit='b'.repeat(40);
 await assert.rejects(a.beforeSend(runtime(a)),{message:'PLAN_DIGEST_MISMATCH'});
 assert.throws(()=>createFrozenPlan({readBundle:()=>Buffer.concat([bytes,Buffer.from(' ')]),bundleSha256:sha,account}),/BUNDLE_DIGEST_MISMATCH/);
});
test('allocation cannot exceed frozen attempt budget',()=>assert.throws(()=>adapter().row('SP',34),/PLAN_ALLOCATION/));
for(const mode of ['missing','duplicate','wrong']) test(`receipt ${mode} stops and persists branch and receipt evidence`,()=>{
 const a=adapter(), rc=receipt(a,mode==='wrong'?'credit':'balance'), rows=[];
 if(mode==='missing') rc.logs=[];
 if(mode==='duplicate') rc.logs.push(rc.logs[0]);
 assert.throws(()=>persistSettlement(a.row('SP',0),rc,{arm:'SP',token:a.plan.phaseC.addresses.X,user:account,hash,planned:'balance'},r=>rows.push(persist(r))),{message:'SP_BRANCH_MISMATCH'});
 assert.equal(rows.length,1); assert.deepEqual(rows[0].receipt,persist(rc));
 assert.deepEqual(rows[0].spBranch,{planned:'balance',observed:mode==='wrong'?'credit':null,event:mode==='wrong'?'CreditSettled(address,bytes32,uint256)':null});
 assert.equal(rows[0].stoppedBy.reason,'SP_BRANCH_MISMATCH');
});
function binding(a) {
 const p=a.plan,pc=p.phaseC,input=p.externalInputs.data.phaseC;
 return [{sender:account,operator:p.deploymentContext.operator,factory:p.deploymentContext.accountFactory,
 accounts:{owner:{address:input.accountOwner},bundler:{address:input.bundler},verifyingSigner:{address:input.verifyingSigner}},
 task:{token:pc.addresses.T,recipient:pc.recipient},salt:input.salt,chainId:p.chainId},
 {entryPoint:p.addresses.entryPoint,superPaymaster:pc.addresses.SP},
 {verifyingPaymaster:{address:pc.addresses.VPM},tokenPaymaster:{address:pc.addresses.TPM,token:pc.addresses.Q}}];
}
test('binds collector identities and budgets without legacy fee substitution',()=>{
 const a=adapter(), args=binding(a);
 assert.equal(a.bind(...args,1n,34),a.frozen);
 assert.equal(args[0].fees.maxFeePerGas,BigInt(a.plan.phaseC.feeCap));
 args[0].sender='0x'+'ff'.repeat(20);
 assert.throws(()=>a.bind(...args,1n,34),/PLAN_CONFIG_MISMATCH/);
 assert.throws(()=>a.bind(...binding(a),1n,35),/PLAN_ALLOCATION/);
 assert.throws(()=>a.bind(...binding(a),2n,34),/PLAN_ALLOCATION/);
 args[0]=binding(a)[0]; args[0].salt=999;
 assert.throws(()=>a.bind(...args,1n,34),/PLAN_CONFIG_MISMATCH/);
});
test('rejects missing account, unfrozen schema and absent planned branch',()=>{
 assert.throws(()=>createFrozenPlan({readBundle:()=>bytes,bundleSha256:sha,account:'none'}),/PLAN_ACCOUNT_MISSING/);
 for(const [from,to,code] of [['"frozen":true','"frozen":false','PLAN_SCHEMA'],['"spBranch":"balance"','"spBranch":"unknown"','PLAN_BRANCH_MISSING']]) {
 const changed=Buffer.from(String(bytes).replaceAll(from,to));
 assert.throws(()=>createFrozenPlan({readBundle:()=>changed,bundleSha256:createHash('sha256').update(changed).digest('hex'),account}),new RegExp(code));
 }
});
test('changed block, unstaking or delay stops at pinned reads',async()=>{
 const a=adapter();
 const r=runtime(a); r.pubB={...r.pubA,getBlock:async()=>({hash:'wrong'})};
 await assert.rejects(a.beforeSend(r),/PLAN_BLOCK_CHANGED/);
 for(const stake of [[0n,false,1000000000000000000n,86400,0n],[0n,true,1000000000000000000n,86401,0n],[0n,true,1000000000000000000n,86400,1n]])
 await assert.rejects(a.beforeSend(runtime(a,{stake})),/PLAN_STAKE_CHANGED/);
});

test('send refuses setup and changed state without invoking transport',async()=>{
 const a=adapter(), rt=runtime(a,{chainId:1}); let sent=0;
 rt.writeContract=async()=>{sent++;};
 await assert.rejects(a.send(rt,'SP',{functionName:'handleOps'}),/PLAN_CHAIN_CHANGED/);
 await assert.rejects(a.send(runtime(a),'SP',{functionName:'createAccount'}),/PLAN_SETUP_REQUIRED/);
 assert.equal(sent,0);
});
