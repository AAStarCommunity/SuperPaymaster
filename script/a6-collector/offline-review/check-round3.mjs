import { currentFixture } from './current-fixture.mjs';
import { syntheticAnchors } from './synthetic-anchors.mjs';
// Round-3 JSONL tampering only. Host labels are offline test inputs; no RPC calls.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { keccak256, toBytes } from 'viem';
const out='script/a6-collector/offline-review', root=process.env.A6_REVIEW_ARCHIVE ?? 'docs/design/aoa-balance-mode/data/a6-gauge-local';
const load=f=>readFileSync(f,'utf8').trim().split('\n').map(JSON.parse);
const base=load(`${root}/positive.jsonl`), n50=load(`${root}/n50-mechanism.jsonl`);
for(const a of [base,n50].map(syntheticAnchors)) {a[0].rpcA='http://a.invalid:8545';a[0].rpcB='http://b.invalid:8545';a[0].allowSameEndpointLocal=false;for(const p of [a[0].passport,a.at(-1).passport])p.allowSameEndpointLocal=false;if(a[0].count===50)a[0].protocolConformant=true;}
const sig=s=>keccak256(toBytes(s));
const UOE=sig('UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)'), LC=sig('LockCreated(address,bytes32,address,uint256,uint256)'), LS=sig('LockSettled(address,bytes32,uint256,uint256)'), CR=sig('CreditReserved(address,bytes32,address,uint256)'), CS=sig('CreditSettled(address,bytes32,uint256)');
const addr='0x'+'12'.repeat(20), at='0x'+'0'.repeat(24)+addr.slice(2);
const word=n=>BigInt(n).toString(16).padStart(64,'0');
const event=(r,t)=>r.logs.find(l=>l.topics[0]===t);
const set=(r,side,f,v)=>{for(const rpc of ['A','B'])r.readbacks[side][rpc][f]=v;};
const results=[];
function run(file,old=false){const r=spawnSync(process.execPath,[old?`${out}/validate-round3-old.mjs`:'script/a6-collector/validate.mjs',old?file:currentFixture(file)],{encoding:'utf8',maxBuffer:16*1024*1024});assert.ifError(r.error);return {exit:r.status,report:JSON.parse(r.stdout)};}
function control(name,mutate,source=base){const a=structuredClone(source);mutate(a);const f=`${out}/fixtures/r3-${name}.jsonl`;writeFileSync(f,a.map(JSON.stringify).join('\n')+'\n');const old=run(f,true), fresh=run(f);assert.equal(old.exit,0,`${name}: old ${JSON.stringify(old.report)}`);assert.ok([1,2,3].includes(fresh.exit),`${name}: fresh ${JSON.stringify(fresh.report)}`);assert.equal(fresh.report.accepted??false,false);results.push([name,old.exit,fresh.exit,fresh.report.missing??fresh.report.errors.join('; ')]);}
control('replay-triplet-50',a=>{const triple=a.slice(1,4);a.splice(1,150,...Array.from({length:50},(_,i)=>triple.map((r,j)=>({...structuredClone(r),attemptIndex:3*i+j,tripletIndex:i}))).flat());},n50);
control('reused-single-tx-block',a=>{for(let j=0;j<3;j++){const r=a[4+j],p=a[1+j];for(const f of ['blockNumber','blockHash','headBefore'])r.tx[f]=p.tx[f];for(const side of ['before','after'])for(const rpc of ['A','B'])for(const f of ['blockNumber','blockHash'])r.readbacks[side][rpc][f]=p.readbacks[side][rpc][f];}},n50);
for(const f of ['operatorBalance','totalSpent','userXPNTs','totalSupply','debts','creditReservedOf','protocolRevenue','totalTxSponsored','lockedOf','epDeposit'])control(`continuity-${f}`,a=>{for(const side of ['before','after'])for(const rpc of ['A','B'])a[4].readbacks[side][rpc][f]=String(BigInt(a[4].readbacks[side][rpc][f])+10n**18n);},n50);
for(const host of ['localhost.','foo.localhost','127.0.0.2','127.255.255.254','[::ffff:127.0.0.1]','[::ffff:7f00:1]','0.0.0.0'])control(`endpoint-${host.replaceAll(/[^a-z0-9]/g,'_')}`,a=>{a[0].rpcA='http://127.0.0.1:8545';a[0].rpcB=`http://${host}:8545`;},n50);
control('local-ports-without-override',a=>{a[0].rpcA='http://127.0.0.1:8545';a[0].rpcB='http://localhost:8546';},n50);
for(const fixture of ['',false,0])control(`fixture-${JSON.stringify(fixture).replaceAll('"','empty')}`,a=>{a[0].fixture=fixture;for(const r of a.slice(1,-1))r.fixture=fixture;const l=structuredClone(event(a[1],UOE));l.topics[1]='0x'+'11'.repeat(32);a[1].logs.push(l);for(const p of [a[0].passport,a.at(-1).passport])p.invariant.callDataHash='0x'+'11'.repeat(32);});
for(const side of ['before','after'])control(`balance-inflight-${side}`,a=>set(a[1],side,'inflightOperator',addr));
for(const f of ['debts','creditReservedOf'])control(`balance-${f}`,a=>set(a[1],'after',f,'1'));
control('lock-settled-user',a=>event(a[1],LS).topics[1]=at);
// Coherent synthetic credit branch: reservation is a0, settlement is the sponsored charge.
const credit=structuredClone(base), r=credit[1], lock=event(r,LC), settled=event(r,LS), reservation=BigInt('0x'+lock.data.slice(66,130)), charge=BigInt('0x'+settled.data.slice(66,130));
r.logs=r.logs.filter(l=>![LC,LS].includes(l.topics[0]));
r.logs.push({...structuredClone(lock),topics:[CR,...lock.topics.slice(1)],data:'0x'+word(reservation)}, {...structuredClone(settled),topics:[CS,...settled.topics.slice(1)],data:'0x'+word(charge)});
for(const rpc of ['A','B']){const b=r.readbacks.before[rpc],a=r.readbacks.after[rpc];a.debts=String(BigInt(b.debts)+charge);a.userXPNTs=b.userXPNTs;a.totalSupply=b.totalSupply;}
const cf=`${out}/fixtures/r3-credit-valid.jsonl`;writeFileSync(cf,credit.map(JSON.stringify).join('\n')+'\n');assert.equal(run(cf).exit,0,'valid credit branch');
control('credit-totalSpent',a=>set(a[1],'after','totalSpent',a[1].readbacks.before.A.totalSpent),credit);
control('credit-reservation-small',a=>event(a[1],CR).data='0x'+word(1),credit);
control('credit-reservation-zero',a=>event(a[1],CR).data='0x'+word(0),credit);
control('credit-reservation-overflow',a=>event(a[1],CR).data='0x'+word(1n<<96n),credit);
control('credit-settled-user',a=>event(a[1],CS).topics[1]=at,credit);
control('credit-reserved-user',a=>event(a[1],CR).topics[1]=at,credit);
control('credit-reserved-locker',a=>event(a[1],CR).topics[3]=at,credit);
const post=load(`${out}/fixtures/r2-postop-valid.jsonl`);
for(const f of ['debts','creditReservedOf'])control(`postop-${f}`,a=>set(a.at(-2),'after',f,'1'),post);
for(const t of [LS,CS])control(`postop-settle-${t===LS?'lock':'credit'}`,a=>{const l=structuredClone(event(base[1],LS));l.topics[0]=t;l.topics[2]=a.at(-2).expectedUserOpHash;if(t===CS)l.data='0x'+word(1);a.at(-2).logs.push(l);},post);
control('end-chain',a=>a.at(-1).passport.chainId=1);
control('end-before-last',a=>a.at(-1).passport.block.number='0');
control('end-blockhash',a=>a.at(-1).passport.block.hash=a[0].passport.block.hash);
control('end-future-reused-hash',a=>a.at(-1).passport.block.number=String(BigInt(a.at(-1).passport.block.number)+1n));
control('end-exitCode',a=>a.at(-1).exitCode=7);
// Existing ::1 alias protection remains closed under both validators.
const ipv6=structuredClone(n50); ipv6[0].rpcA='http://127.0.0.1:8545';ipv6[0].rpcB='http://[::1]:8545';
const ipf=`${out}/fixtures/r3-existing-ipv6-alias.jsonl`;writeFileSync(ipf,ipv6.map(JSON.stringify).join('\n')+'\n');assert.equal(run(ipf,true).exit,1);assert.equal(run(ipf).exit,1);
// An explicit override allows local distinct ports for a mechanism run, never conformance.
const local=structuredClone(base);local[0].rpcA='http://127.0.0.1:8545';local[0].rpcB='http://localhost.:8546';local[0].allowSameEndpointLocal=true;for(const p of [local[0].passport,local.at(-1).passport])p.allowSameEndpointLocal=true;
const lf=`${out}/fixtures/r3-local-override-valid.jsonl`;writeFileSync(lf,local.map(JSON.stringify).join('\n')+'\n');assert.equal(run(lf).exit,0);assert.equal(run(lf).report.protocolConformant,false);
writeFileSync(`${out}/round3-results.tsv`,'control\told_exit\tnew_exit\tproof\n'+results.map(r=>r.join('\t')).join('\n')+'\n');
console.log(`PASS: ${results.length} round-3 controls old exit 0 -> reject; valid credit and local override pass`);
