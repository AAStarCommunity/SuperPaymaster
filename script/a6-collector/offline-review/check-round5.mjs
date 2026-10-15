import { syntheticSummary } from './synthetic-summary.mjs';
// Independent round-5 JSONL tampering; no RPC. Frozen old validator is HEAD 7eb0c693.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { spawnSync, execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { keccak256, toBytes } from 'viem';
import { localUserOpHash } from '../gauge-lib.mjs';
import { syntheticAnchors } from './synthetic-anchors.mjs';
import { freshEnd, unfinishedTarget } from './current-fixture.mjs';
const out='script/a6-collector/offline-review', root=process.env.A6_REVIEW_ARCHIVE??'docs/design/aoa-balance-mode/data/a6-gauge-local';
const oldFile=`${out}/validate-round5-old.mjs`;
assert.equal(createHash('sha256').update(readFileSync(oldFile)).digest('hex'),createHash('sha256').update(execFileSync('git',['show','7eb0c693:script/a6-collector/validate.mjs'])).digest('hex'));
const load=n=>syntheticAnchors(readFileSync(`${root}/${n}.jsonl`,'utf8').trim().split('\n').map(JSON.parse));
const base=load('positive'), n50=load('n50-mechanism');
for(const a of [base,n50]) {
  // The frozen comparator requires its historical same-block end anchor.
  // Current-validator controls use freshEnd below; archive evidence is untouched.
  a.at(-1).passport.block.number=a.at(-2).tx.blockNumber;
  a.at(-1).passport.block.hash=a.at(-2).tx.blockHash;
  a[0].rpcA='http://a.invalid:8545';a[0].rpcB='http://b.invalid:8545';a[0].allowSameEndpointLocal=false;a[0].protocolConformant=a[0].count===50;
  for(const p of [a[0].passport,a.at(-1).passport])p.allowSameEndpointLocal=false;
}
const sig=s=>keccak256(toBytes(s)), UOE=sig('UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)');
const word=n=>BigInt(n).toString(16).padStart(64,'0');
const passports=a=>[a[0].passport,a.at(-1).passport];
function rehash(r){const prev=r.expectedUserOpHash,h=localUserOpHash(r.packedOp,r.entryPoint,r.chainId);r.expectedUserOpHash=r.localUserOpHash=r.epUserOpHash=h;r.bundledOps=[structuredClone(r.packedOp)];r.bundledUserOpHashes=[h];for(const l of r.logs)l.topics=l.topics.map(t=>t.toLowerCase()===prev.toLowerCase()?h:t);}
function nonce(r,n){r.nonce=r.packedOp.nonce=String(n);rehash(r);const u=r.logs.find(l=>l.topics[0]===UOE);u.data='0x'+word(n)+u.data.slice(66);}
function bytes(r,offset,count,hex){const d=r.packedOp.paymasterAndData;r.packedOp.paymasterAndData=d.slice(0,2+offset*2)+hex+d.slice(2+(offset+count)*2);rehash(r);}
function run(name,a,old=false){a=structuredClone(a);if(!old && name.startsWith('noexec-'))unfinishedTarget(a);syntheticSummary(a);const f=`${out}/fixtures/r5-${name}.jsonl`;writeFileSync(f,a.map(JSON.stringify).join('\n')+'\n');const r=spawnSync(process.execPath,[old?oldFile:'script/a6-collector/validate.mjs',f],{encoding:'utf8',maxBuffer:16*1024*1024});assert.ifError(r.error);return {exit:r.status,report:JSON.parse(r.stdout)};}
const results=[];
function control(name,mutate,proof,source=base,{modern=true}={}) {
  const legacy=structuredClone(source);mutate(legacy);
  const old=run(name,legacy,true), fresh=run(name,legacy);
  assert.equal(old.exit,0,`${name} old: ${JSON.stringify(old.report)}`);
  assert.ok([1,2].includes(fresh.exit),`${name} fresh: ${JSON.stringify(fresh.report)}`);
  assert.match(fresh.report.missing??fresh.report.errors.join(';'),proof,name);
  // Also exercise the isolated finding with a valid current end envelope.
  if(modern){const a=freshEnd(structuredClone(source));mutate(a);if(name.startsWith('noexec-'))freshEnd(a);const r=run(name+'-isolated',a);assert.ok([1,2].includes(r.exit),name);assert.match(r.report.missing??r.report.errors.join(';'),proof,name);}
  results.push([name,old.exit,fresh.exit,fresh.report.missing??fresh.report.errors.join('; ')]);
}
for(const [n,a] of [['positive',base],['n50',n50]])assert.equal(run(n,freshEnd(structuredClone(a))).exit,0,n+' current positive');
control('nonce-gap',a=>nonce(a[3],5n),/nonce sequence/);
control('nonce-gap-n50',a=>nonce(a.at(-2),BigInt(a.at(-2).nonce)+10n),/nonce sequence/,n50);
for(const [field,value] of [['cachedPrice.price','0'],['cachedPrice.price','1'],['aPNTsPriceUSD','0'],['aPNTsPriceUSD','1'],['cachedPrice.decimals',9]])
  control(`quote-${field}-${value}`,a=>{for(const p of passports(a)){const ks=field.split('.');let o=p.invariant.superPaymaster;for(const k of ks.slice(0,-1))o=o[k];o[ks.at(-1)]=value;}},/admission.quote/);
control('minTxInterval',a=>passports(a).forEach(p=>p.invariant.superPaymaster.operator.minTxInterval=999999999),/minTxInterval/,n50);
for(const post of [0,1,174999,199999])control('post-gas-'+post,a=>{passports(a).forEach(p=>p.invariant.pmGas.SP.post=String(post));a[1].pmGas.post=String(post);bytes(a[1],36,16,BigInt(post).toString(16).padStart(32,'0'));},/below contract floor/);
control('configured-post-floor',a=>passports(a).forEach(p=>p.invariant.superPaymaster.minPostOpGas='200001'),/below contract floor/);
const fields=['epDeposit','operatorBalance','totalSpent','totalTxSponsored','protocolRevenue','inflightOperator','inflightA0','userXPNTs','totalSupply','lockedOf','debts','creditReservedOf','lockXLocked'];
function appendSP(a,status='success'){
 const r=structuredClone(a[1]), last=a.at(-2);r.attemptIndex=a.length-2;r.tripletIndex=50;nonce(r,BigInt(last.nonce)+1n);r.logs=[];r.verdict=status==='success'?'NO_EVENT':'TX_FAILED';r.tx.status=status;r.conservation={evaluated:false,ok:null,checks:[]};r.tx.hash='0x'+'ab'.repeat(32);r.tx.blockHash='0x'+'ac'.repeat(32);r.tx.headBefore=last.tx.blockNumber;r.tx.blockNumber=String(BigInt(r.tx.headBefore)+1n);
 for(const rpc of ['A','B']){r.readbacks.before[rpc]={...r.readbacks.after[rpc],blockNumber:last.tx.blockNumber,blockHash:last.tx.blockHash,lockXLocked:'0'};r.readbacks.after[rpc]={...r.readbacks.before[rpc],blockNumber:r.tx.blockNumber,blockHash:r.tx.blockHash};}
 a.splice(-1,0,r);a.at(-1).passport.block.number=r.tx.blockNumber;a.at(-1).passport.block.hash=r.tx.blockHash;return r;
}
for(const status of ['success','reverted']) {const a=structuredClone(base);appendSP(a,status);freshEnd(a);assert.equal(run('noexec-unchanged-'+status,a).exit,3,'unchanged no-execution row');}
const bounds=freshEnd(structuredClone(base));
bytes(bounds[1],72,32,word(bounds[0].passport.invariant.xPNTs.exchangeRate));
bytes(bounds[1],124,1,'01');bytes(bounds[2],52,32,word(bounds[2].tx.blockTimestamp));bytes(bounds[2],84,32,word(bounds[2].tx.blockTimestamp));
assert.equal(run('inclusive-bounds',bounds).exit,0,'inclusive maxRate and VPM timestamp boundaries');
for(const status of ['success','reverted'])for(const f of fields)control(`noexec-${status}-${f}`,a=>{const r=appendSP(a,status);for(const rpc of ['A','B'])r.readbacks.after[rpc][f]=f==='inflightOperator'?'0x'+'22'.repeat(20):String(BigInt(r.readbacks.after[rpc][f])+1n);if(f==='operatorBalance')a.at(-1).passport.volatile.operatorBalance=r.readbacks.after.A.operatorBalance;},new RegExp('no_execution\\.'+f));
for(const index of [0,1,2])control('end-reuses-'+index,a=>{const p=a.at(-1).passport, rb=index===0?{blockHash:a[0].passport.block.hash,operatorBalance:a[0].passport.volatile.operatorBalance}:a[index].readbacks.after.A;p.block.number=String(BigInt(a.at(-2).tx.blockNumber)+5n);p.block.hash=rb.blockHash;p.volatile.operatorBalance=rb.operatorBalance??a.at(-1).passport.volatile.operatorBalance;},/end passport reuses earlier block hash/,base,{modern:false});
control('end-same-last-block',a=>{a.at(-1).passport.block.number=a.at(-2).tx.blockNumber;a.at(-1).passport.block.hash=a.at(-2).tx.blockHash;},/strictly after/,base,{modern:false});
control('maxRate',a=>bytes(a[1],72,32,word(0)),/maxRate/);
control('token',a=>bytes(a[1],104,20,'22'.repeat(20)),/packed token/);
control('flags',a=>bytes(a[1],124,1,'03'),/conflicting renewal flags/);
control('VPM-expired',a=>bytes(a[2],52,32,word(1)),/VPM validity/);
control('VPM-not-yet-valid',a=>bytes(a[2],84,32,word(BigInt(a.at(-1).passport.block.timestamp)+1n)),/VPM validity/);
control('VPM-uint48-overflow',a=>bytes(a[2],52,32,word(1n<<48n)),/VPM validity/);
control('account-size-initCode',a=>{passports(a).forEach(p=>p.invariant.code.account.size=0);a[1].packedOp.initCode='0x1234';rehash(a[1]);},/size\/codehash/);
control('account-nonempty-size-empty-hash',a=>passports(a).forEach(p=>p.invariant.code.account.codehash=keccak256('0x')),/size\/codehash/);
// New evidence omissions fail closed and are not falsely called old acceptance holes.
for(const field of ['minPostOpGas','tx.blockTimestamp']){const a=freshEnd(structuredClone(base));if(field==='minPostOpGas')passports(a).forEach(p=>delete p.invariant.superPaymaster.minPostOpGas);else delete a[1].tx.blockTimestamp;const r=run('missing-'+field,a);assert.equal(r.exit,2);assert.match(r.report.missing,new RegExp(field.replace('.','\\.')));}
writeFileSync(`${out}/round5-results.tsv`,'control\told_exit\tnew_exit\tproof\n'+results.map(r=>r.join('\t')).join('\n')+'\n');
// Read and assert exact source lines at the user-specified pin.
const pinned=p=>execFileSync('git',['show',`1ac0e1c5:${p}`],{encoding:'utf8'}).split('\n');
const sp=pinned('contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol'), st=pinned('contracts/src/paymasters/superpaymaster/v3/SuperPaymasterStorage.sol'), ep=pinned('singleton-paymaster/lib/account-abstraction-v7/contracts/core/EntryPoint.sol'), nm=pinned('singleton-paymaster/lib/account-abstraction-v7/contracts/core/NonceManager.sol'), vp=pinned('singleton-paymaster/lib/account-abstraction-v7/contracts/samples/VerifyingPaymaster.sol');
const hp=pinned('singleton-paymaster/lib/account-abstraction-v7/contracts/core/Helpers.sol');
const admin=pinned('contracts/src/paymasters/superpaymaster/v3/SuperPaymasterAdmin.sol');
const citations=[
 [ep,132,'emitUserOperationEvent(opInfo, false'],[ep,200,'_executeUserOp'],[ep,126,'revert FailedOp'],[hp,48,'validUntil == 0'],[hp,49,'type(uint48).max'],[admin,331,'function gasParams()'],[admin,332,'_gp()'],
 [nm,40,'nonceSequenceNumber[sender][key]++ == seq'],[sp,217,'ethUsdPrice <= 0'],[sp,219,'ethAmountWei * uint256(ethUsdPrice)'],[sp,221,'aPNTsPriceUSD'],[sp,305,'_calculateAPNTsAmount(maxCost)'],[sp,309,'VALIDATION_BUFFER_BPS'],[sp,310,'Math.Rounding.Ceil'],
 [ep,406,'verificationGasLimit'],[ep,408,'paymasterVerificationGasLimit'],[ep,409,'paymasterPostOpGasLimit'],[ep,412,'requiredGas * mUserOp.maxFeePerGas'],
 [sp,282,'config.minTxInterval > 0'],[sp,286,'lastTime + config.minTxInterval'],[sp,411,'lastTimestamp = uint48(block.timestamp)'],
 [st,193,'MIN_POST_OP_GAS = 200_000'],[st,197,'GP_SETTLE_MIN = 155_000'],[st,199,'GP_MINPOST_OVER_SETTLE = 20_000'],[st,319,'if (raw == 0)'],[st,320,'MIN_POST_OP_GAS |'],[sp,267,'bytes16'],[sp,268,'pmPostOpGas < uint32(gpRaw)'],
 [sp,294,'token != config.xPNTsToken'],[sp,296,'FLAG_SP_RENEW | FLAG_ACCOUNT_RENEW'],[sp,299,'RATE_OFFSET + 32'],[sp,302,'rate > maxRate'],[vp,93,'abi.decode'],[ep,605,'block.timestamp > data.validUntil || block.timestamp < data.validAfter'],[ep,429,'sender.code.length != 0'],[ep,430,'AA10 sender already constructed']
];for(const [lines,n,text] of citations)assert.ok(lines[n-1].includes(text),`pin:${n} ${text}`);
console.log(`PASS: ${results.length} round-5 controls old exit 0 -> reject, isolated current-envelope checks, positive/N=50 baselines, required evidence omissions; ${citations.length} pinned line assertions`);
