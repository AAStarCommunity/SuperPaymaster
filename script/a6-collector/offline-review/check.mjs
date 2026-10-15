// Offline JSONL mutations of the current archive, without repairs or invented transaction fields. Never connects to an RPC.
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { spawnSync, execFileSync } from 'node:child_process';
import { localUserOpHash } from '../gauge-lib.mjs';
import { keccak256, toBytes } from 'viem';
const root = 'docs/design/aoa-balance-mode/data/a6-gauge-local';
const out = 'script/a6-collector/offline-review';
mkdirSync(`${out}/fixtures`, { recursive: true });
const base = readFileSync(`${root}/positive.jsonl`, 'utf8').trim().split('\n').map(JSON.parse);
const run = (file, old) => spawnSync(process.execPath, [old ? `${out}/validate-old.mjs` : 'script/a6-collector/validate.mjs', file], {encoding:'utf8'});
const cleanFile=`${out}/fixtures/complete-positive.jsonl`;
writeFileSync(cleanFile,base.map(JSON.stringify).join('\n')+'\n');
if(run(cleanFile,false).status!==0) throw Error(run(cleanFile,false).stdout);
const results = [];
function control(name, mutate, expected = 1, source = base, expectedOld = 0) {
  const a = structuredClone(source); mutate(a);
  const file = `${out}/fixtures/${name}.jsonl`;
  writeFileSync(file, a.map(r => JSON.stringify(r)).join('\n')+'\n');
  const old = run(file,true), fresh = run(file,false);
  results.push([name,old.status,fresh.status]);
  if (old.status !== expectedOld || fresh.status !== expected) throw Error(`${name}: ${old.status}/${fresh.status}\n${old.stdout}\n${fresh.stdout}`);
}
const rows = a => a.slice(1,-1);
control('row-fixture-hash', a => {
  const r=a[1], h=r.expectedUserOpHash, fake='0x'+'11'.repeat(32);
  r.fixture='wrong-hash'; r.expectedUserOpHash=fake;
  for (const l of r.logs) l.topics=l.topics.map(t=>t.toLowerCase()===h.toLowerCase()?fake:t);
});
function leaves(o,p='') {return Object.entries(o).flatMap(([k,v])=>v && typeof v==='object' ? leaves(v,p+k+'.') : [p+k]);}
// Every emitted passport leaf, not merely one example per class; delete at both ends.
for (const path of process.env.SKIP_PASSPORT ? [] : leaves(base[0].passport)) {
  control('missing-'+path.replaceAll('.','-'), a => {
    for (const p of [a[0].passport,a.at(-1).passport]) {
      const ks=path.split('.'), last=ks.pop(); let o=p; for (const k of ks) o=o[k]; delete o[last];
    }
  },2,base,['chainId','invariant.code.superPaymasterProxy.address','invariant.xPNTs.address','invariant.superPaymaster.operator.address'].includes(path)?2:0);
}
control('callDataHash', a=>rows(a).forEach(r=>r.callDataHash='0x'+'11'.repeat(32)));
control('gas-record', a=>rows(a).forEach(r=>Object.keys(r.gas).forEach(k=>r.gas[k]='1')));
control('bundler-record', a=>rows(a).forEach(r=>r.bundler='0x'+'00'.repeat(19)+'01'));
control('tx-from-arm-diff', a=>a[2].tx.from='0x'+'00'.repeat(19)+'01');
control('same-endpoint-conformant', a=>a[0].rpcB=a[0].rpcA,1,
  readFileSync(`${root}/n50-mechanism.jsonl`,'utf8').trim().split('\n').map(JSON.parse));
control('conformant-override', a=>{a[0].protocolConformant=true; a[0].allowSameEndpointLocal=true;});
control('false-conformance', a=>a[0].protocolConformant=true);
control('citation-C6', a=>{a[1].conservation.checks.find(c=>c.id==='C6.locked_unchanged').src='XT:239,263';});
// Construct a non-success postOp record; old validator accepts COMPLETE with target 0.
function extraTriplet(a) {
 const more=structuredClone(base.slice(1,-1));
 more.forEach((r,i)=>{r.tripletIndex=1;r.attemptIndex=3+i;});
 a.splice(a.length-1,0,...more);
}
const post=structuredClone(base); extraTriplet(post);
const r=post[1];r.verdict='USEROP_REVERTED';
const topic=s=>keccak256(toBytes(s));
const u=r.logs.find(l=>l.topics[0]===topic('UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)'));
u.data=u.data.slice(0,66)+'0'.repeat(64)+u.data.slice(130);
r.logs=r.logs.filter(l=>l.topics[0]!==topic('TransactionSponsored(address,address,uint256,uint256)'));
r.logs.push({address:r.entryPoint,topics:[topic('PostOpRevertReason(bytes32,address,uint256,bytes)'),r.expectedUserOpHash,u.topics[2]],data:'0x'});
for(const side of ['A','B']) {
 const b=r.readbacks.before[side],z=r.readbacks.after[side];
 z.inflightA0='7';z.inflightOperator=post[0].passport.invariant.superPaymaster.operator.address;
 z.operatorBalance=(BigInt(b.operatorBalance)-7n).toString();z.protocolRevenue=b.protocolRevenue;
}
control('postop-a0-from-inflight',()=>{},1,post);
control('postop-R2-lock-delta', a=>{
 const r=a[1],l=r.logs.find(l=>l.topics[0]===topic('LockCreated(address,bytes32,address,uint256,uint256)'));
 const a0=BigInt('0x'+l.data.slice(66,130));
 for(const side of ['A','B']) {const b=r.readbacks.before[side],z=r.readbacks.after[side];z.inflightA0=String(a0);z.operatorBalance=String(BigInt(b.operatorBalance)-a0);}
},1,post);
control('postop-missing-lock', a=>{a[1].logs=a[1].logs.filter(l=>l.topics[0]!==topic('LockCreated(address,bytes32,address,uint256,uint256)'));},1,post);
control('unevaluated-ok-true', a=>{
 extraTriplet(a);
 for(const r of a.slice(1,4)){r.logs=[];r.verdict='NO_EVENT';r.conservation={evaluated:false,ok:true,checks:[]};}
});
control('citation-credit', a=>a[1].conservation.checks.push({id:"C5'.credit_reserved_unchanged",src:'XT:304,322',ok:true}));
control('missing-tx-from',a=>delete a[1].tx.from,2);
for (const field of ['callData','preVerificationGas']) control(`packed-arm-${field}`, a=>{
 const r=a[2], oldHash=r.expectedUserOpHash;
 r.packedOp[field]=field==='callData' ? '0x1234' : '60001';
 r.bundledOps[0]=structuredClone(r.packedOp);
 const hash=localUserOpHash(r.packedOp,r.entryPoint,r.chainId);
 r.expectedUserOpHash=r.epUserOpHash=r.localUserOpHash=hash;r.bundledUserOpHashes=[hash];
 for(const l of r.logs) l.topics=l.topics.map(t=>t.toLowerCase()===oldHash.toLowerCase()?hash:t);
});
const gate = spawnSync(process.execPath,['script/a6-collector/collector.mjs','--rpc-a','http://127.0.0.1:8545','--rpc-b','http://localhost:8545'],{encoding:'utf8'});
if(gate.status!==2 || !gate.stderr.includes('identical RPC endpoints')) throw Error('collector endpoint gate failed');
const overrideGate=spawnSync(process.execPath,['script/a6-collector/collector.mjs','--rpc-a','http://127.0.0.1:8545','--rpc-b','http://localhost:8545','--allow-same-endpoint-local'],{encoding:'utf8'});
if(overrideGate.status!==2 || !overrideGate.stderr.includes('--count is required')) throw Error('collector override gate failed');
const archive=[];
for(const f of execFileSync('git',['ls-files','*.jsonl'],{encoding:'utf8'}).trim().split('\n').filter(f => f && !f.startsWith(`${out}/`))) {
 const old=run(f,true), fresh=run(f,false);
 archive.push([f,old.status,fresh.status,JSON.parse(fresh.stdout).missing ?? (JSON.parse(fresh.stdout).errors?.join('; ') || '-')]);
}
writeFileSync(`${out}/passport-fields.txt`,leaves(base[0].passport).join('\n')+'\n');
writeFileSync(`${out}/results.tsv`,'control\told_exit\tnew_exit\n'+results.map(r=>r.join('\t')).join('\n')+'\n');
writeFileSync(`${out}/archives.tsv`,'archive\told_exit\tnew_exit\treason\n'+archive.map(r=>r.join('\t')).join('\n')+'\n');
console.log(`${results.length} controls passed (${results.filter(r=>r[1]===0).length} newly rejected old=0 cases); ${archive.length} archives rechecked`);
