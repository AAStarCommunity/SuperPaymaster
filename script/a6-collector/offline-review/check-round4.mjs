import { syntheticAnchors } from './synthetic-anchors.mjs';
// Round-4 raw JSONL tampering. All endpoints are labels, never contacted.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { spawnSync, execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { keccak256, toBytes } from 'viem';
import { localUserOpHash } from '../gauge-lib.mjs';
const out='script/a6-collector/offline-review', root=process.env.A6_REVIEW_ARCHIVE ?? 'docs/design/aoa-balance-mode/data/a6-gauge-local';
const oldFile=`${out}/validate-round4-old.mjs`;
assert.equal(createHash('sha256').update(readFileSync(oldFile)).digest('hex'), '2e703559157c474cefeb54a7ba9e987d7d0555e43baef0a8280596e5c228812a');
const load=n=>readFileSync(`${root}/${n}.jsonl`,'utf8').trim().split('\n').map(JSON.parse);
const base=load('positive'), n50=load('n50-mechanism');
for(const a of [base,n50].map(syntheticAnchors)) {
  a[0].rpcA='http://a.invalid:8545';a[0].rpcB='http://b.invalid:8545';
  a[0].allowSameEndpointLocal=false;
  for(const p of [a[0].passport,a.at(-1).passport])p.allowSameEndpointLocal=false;
  a[0].protocolConformant=a[0].count===50;
}
const sig=s=>keccak256(toBytes(s));
const UOE=sig('UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)'), LC=sig('LockCreated(address,bytes32,address,uint256,uint256)'), LS=sig('LockSettled(address,bytes32,uint256,uint256)'), SP=sig('TransactionSponsored(address,address,uint256,uint256)');
const event=(r,t)=>r.logs.find(l=>l.topics[0]===t), word=n=>BigInt(n).toString(16).padStart(64,'0');
const passports=a=>[a[0].passport,a.at(-1).passport];
const set=(r,side,f,v)=>{for(const rpc of ['A','B'])r.readbacks[side][rpc][f]=String(v);};
function rehash(r){
  const prev=r.expectedUserOpHash,h=localUserOpHash(r.packedOp,r.entryPoint,r.chainId);
  r.expectedUserOpHash=r.localUserOpHash=r.epUserOpHash=h;r.bundledOps=[structuredClone(r.packedOp)];r.bundledUserOpHashes=[h];
  for(const l of r.logs)l.topics=l.topics.map(t=>t.toLowerCase()===prev.toLowerCase()?h:t);
}
function nonce(r,n){r.nonce=r.packedOp.nonce=String(n);rehash(r);const u=event(r,UOE);u.data='0x'+word(n)+u.data.slice(66);}
mkdirSync(`${out}/fixtures`,{recursive:true});
const run=(f,old=false)=>{const r=spawnSync(process.execPath,[old?oldFile:'script/a6-collector/validate.mjs',f],{encoding:'utf8',maxBuffer:16*1024*1024});assert.ifError(r.error);return {exit:r.status,report:JSON.parse(r.stdout)};};
const results=[];
function save(name,a){const f=`${out}/fixtures/r4-${name}.jsonl`;writeFileSync(f,a.map(JSON.stringify).join('\n')+'\n');return f;}
function control(name,change,proof,source=base){const a=structuredClone(source);change(a);const f=save(name,a),old=run(f,true),fresh=run(f);assert.equal(old.exit,0,`${name} old: ${JSON.stringify(old.report)}`);assert.ok([1,2,3].includes(fresh.exit),`${name} new: ${JSON.stringify(fresh.report)}`);assert.match(fresh.report.missing??fresh.report.errors.join(';'),proof,`${name} specific rejection`);results.push([name,old.exit,fresh.exit,fresh.report.missing??fresh.report.errors.join('; ')]);}
for(const [name,a] of [['positive',base],['n50',n50]])assert.equal(run(save(name,a)).exit,0,`${name} baseline`);
for(const host of ['[::]','[::0]','[::ffff:0.0.0.0]','[::ffff:0:0]','localhost..','localhost...','0.0.0.0..','foo..invalid','_foo.invalid','-foo.invalid','foo-.invalid'])
  control(`endpoint-${host.replaceAll(/[^a-z0-9]/g,'_')}`,a=>a[0].rpcB=`http://${host}:8545`,/RPC identities|malformed RPC hostname/,n50);
// 0.0.0.0 was already rejected; keep a regression for it without claiming old acceptance.
const unspecified=structuredClone(n50);unspecified[0].rpcB='http://0.0.0.0:8545';const uf=save('ipv4-unspecified',unspecified);assert.equal(run(uf,true).exit,1);assert.equal(run(uf).exit,1);
control('nonce-reuse-cross-arm',a=>nonce(a[2],BigInt(a[1].nonce)),/nonce sequence/);
control('nonce-decrease-cross-attempt',a=>nonce(a[4],0n),/nonce sequence/,n50);
control('nonce-reuse-same-arm',a=>{a[4].packedOp.paymasterAndData+='00';nonce(a[4],BigInt(a[1].nonce));},/nonce sequence/,n50);
for(const [path,value] of [['paused',true],['senderEligible',false],['operator.isConfigured',false],['operator.isPaused',true],['xPNTs.emergencyDisabled',true]])
  control(`sponsor-${path}`,a=>{for(const p of passports(a)){const ks=path.split('.');let o=path.startsWith('xPNTs.')?p.invariant:p.invariant.superPaymaster;for(const k of ks.slice(0,-1))o=o[k];o[ks.at(-1)]=value;}},/not sponsor-able/);
control('price-end-expired',a=>a.at(-1).passport.volatile.cachedPriceUpdatedAt='0',/cached price expires/);
control('price-expired',a=>passports(a).forEach(p=>p.volatile.cachedPriceUpdatedAt='0'),/cached price expires/);
control('price-threshold-too-short',a=>{for(const p of passports(a))p.invariant.superPaymaster.priceStalenessThreshold='1';a.at(-1).passport.block.timestamp=String(BigInt(a[0].passport.block.timestamp)+2n);},/cached price expires/);
control('missing-end-balance-anchor',a=>{for(const rpc of ['A','B'])delete a.at(-2).readbacks.after[rpc].operatorBalance;},/end passport requires operatorBalance readback/);
control('passport-start-balance',a=>a[0].passport.volatile.operatorBalance=String(BigInt(a[0].passport.volatile.operatorBalance)+1n),/passport\/readback operatorBalance/);
control('passport-end-balance',a=>a.at(-1).passport.volatile.operatorBalance=String(BigInt(a.at(-1).passport.volatile.operatorBalance)+1n),/passport\/readback operatorBalance/);
control('all-sp-balances-shift',a=>{for(const r of a.slice(1,-1).filter(r=>r.arm==='SP'))for(const side of ['before','after'])set(r,side,'operatorBalance',BigInt(r.readbacks[side].A.operatorBalance)+10n**18n);},/passport\/readback operatorBalance/,n50);
control('sponsored-aPNTsCost-zero',a=>{const l=event(a[1],SP);l.data='0x'+word(0)+l.data.slice(66);},/C9.aPNTsCost_fee/);
control('sponsored-aPNTsCost-rounding',a=>{const l=event(a[1],SP);l.data='0x'+word(BigInt('0x'+l.data.slice(2,66))+1n)+l.data.slice(66);},/C9.aPNTsCost_fee/);
for(const [name,value] of [['uint96',1n<<96n],['max-limit',5001n*10n**18n]])control(`lock-${name}`,a=>{const l=event(a[1],LC);l.data='0x'+word(value)+word(value);set(a[1],'after','totalSpent',value);},/admission.a0_bounds/);
control('lock-exchange-rate',a=>{const l=event(a[1],LC);l.data='0x'+word(BigInt('0x'+l.data.slice(2,66))+1n)+l.data.slice(66);const settled=event(a[1],LS),burn=BigInt('0x'+settled.data.slice(2,66))+1n;settled.data='0x'+word(burn)+settled.data.slice(66);for(const f of ['userXPNTs','totalSupply'])set(a[1],'after',f,BigInt(a[1].readbacks.before.A[f])-burn);},/admission.exchange_rate/);
control('lock-insufficient-user',a=>{const l=event(a[1],LS),burn=BigInt('0x'+l.data.slice(2,66));set(a[1],'before','userXPNTs',burn);set(a[1],'after','userXPNTs',0);},/admission.available_balance/);
control('packed-initCode',a=>{a[1].packedOp.initCode='0x1234';rehash(a[1]);},/initCode for deployed account/);
control('packed-operator',a=>{const r=a[1],d=r.packedOp.paymasterAndData;r.packedOp.paymasterAndData=d.slice(0,106)+'22'.repeat(20)+d.slice(146);rehash(r);},/packed operator passport mismatch/);
// Append a sent NO_EVENT row after the complete triplet, with fresh tx/op identity.
function appendNoEvent(a){const r=structuredClone(a[2]);r.attemptIndex=3;r.tripletIndex=1;nonce(r,BigInt(a[3].nonce)+1n);r.logs=[];r.verdict='NO_EVENT';r.conservation={evaluated:false,ok:null,checks:[]};r.tx.hash='0x'+'ab'.repeat(32);r.tx.blockHash='0x'+'ac'.repeat(32);r.tx.headBefore=a[3].tx.blockNumber;r.tx.blockNumber=String(BigInt(r.tx.headBefore)+1n);for(const rpc of ['A','B']){r.readbacks.before[rpc]={...r.readbacks.after[rpc],blockNumber:a[3].tx.blockNumber,blockHash:a[3].tx.blockHash};r.readbacks.after[rpc]={...r.readbacks.before[rpc],blockNumber:r.tx.blockNumber,blockHash:r.tx.blockHash};}a.splice(-1,0,r);a.at(-1).passport.block.number=r.tx.blockNumber;a.at(-1).passport.block.hash=r.tx.blockHash;return r;}
control('no-uoe-bracket',a=>{const r=appendNoEvent(a);r.tx.headBefore='999998';r.tx.blockNumber='999999';},/readback_blocks_bracket_tx/);
control('no-uoe-after-hash',a=>{const r=appendNoEvent(a);for(const rpc of ['A','B'])r.readbacks.after[rpc].blockHash='0x'+'ad'.repeat(32);a.at(-1).passport.block.hash=r.readbacks.after.A.blockHash;},/readback_after_blockhash_eq_tx_block/);
// Distinct nonce keys may have independent sequences, including sequence zero.
const keys=structuredClone(base);nonce(keys[2],1n<<64n);nonce(keys[3],2n<<64n);assert.equal(run(save('independent-nonce-keys',keys)).exit,0);
writeFileSync(`${out}/round4-results.tsv`,'control\told_exit\tnew_exit\tproof\n'+results.map(r=>r.join('\t')).join('\n')+'\n');
console.log(`PASS: ${results.length} round-4 controls old exit 0 -> reject; independent nonce keys and explicitly anchored synthetic baselines pass`);

// Read the actual source at the requested pin, not the moving checkout.
const pinned = path => execFileSync('git',['show',`1ac0e1c5:${path}`],{encoding:'utf8'}).split('\n');
const sp = pinned('contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol');
const xt = pinned('contracts/src/tokens/v2/xPNTsTokenV2.sol');
const ep = pinned('singleton-paymaster/lib/account-abstraction-v7/contracts/core/EntryPoint.sol');
const nm = pinned('singleton-paymaster/lib/account-abstraction-v7/contracts/core/NonceManager.sol');
for (const [lines,n,text] of [
  [sp,233,'if (paused)'],[sp,242,'if (!config.isConfigured)'],[sp,248,'uint48(cachedPrice.updatedAt + priceStalenessThreshold)'],
  [sp,252,'if (config.isPaused)'],[sp,257,'if (!isEligibleForSponsorship(userOp.sender))'],
  [sp,313,'uint256(config.aPNTsBalance) < aPNTsAmount'],[sp,324,'uint96(aPNTsAmount)'],
  [sp,433,'Math.mulDiv(aGas, BPS_DENOMINATOR + feeBps, BPS_DENOMINATOR, Math.Rounding.Ceil)'],
  [sp,434,'if (charge > c.a0) charge = c.a0;'],[sp,450,'TransactionSponsored(c.operator, c.user, aGas, charge)'],
  [sp,489,'userOp.paymasterAndData[PAYMASTER_DATA_OFFSET:PAYMASTER_DATA_OFFSET+20]'],
  [xt,194,'if (emergencyDisabled)'],[xt,196,'reserveAPNTs > maxSingleTxLimit'],
  [xt,210,'Math.mulDiv(reserveAPNTs, exchangeRate, 1e18, Math.Rounding.Ceil)'],[xt,212,'bal - locked < x'],
  [nm,38,'uint192 key = uint192(nonce >> 64)'],[nm,39,'uint64 seq = uint64(nonce)'],[nm,40,'nonceSequenceNumber[sender][key]++ == seq'],
  [ep,427,'if (initCode.length != 0)'],[ep,430,'AA10 sender already constructed'],[ep,605,'block.timestamp > data.validUntil']
]) assert.ok(lines[n-1].includes(text),`pin citation line ${n}: ${text}`);
assert.ok(pinned('contracts/src/paymasters/superpaymaster/v3/SuperPaymasterStorage.sol').some(l=>/PAYMASTER_DATA_OFFSET = 52/.test(l)), 'operator starts at byte 52');
console.log('PASS: round-4 rules verified against git show 1ac0e1c5 source (21 line assertions plus operator offset)');
