import { currentFixture } from './current-fixture.mjs';
import { syntheticAnchors } from './synthetic-anchors.mjs';
// Round-2 controls use the validator immediately before these fixes, not the round-1 pin.
// All inputs are JSONL mutations of the CURRENT archive. No RPC requests are made.
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { keccak256, toBytes } from 'viem';
import { localUserOpHash } from '../gauge-lib.mjs';
const out = 'script/a6-collector/offline-review';
const root = process.env.A6_REVIEW_ARCHIVE ?? 'docs/design/aoa-balance-mode/data/a6-gauge-local';
const load = name => readFileSync(`${root}/${name}.jsonl`, 'utf8').trim().split('\n').map(JSON.parse);
const base = load('positive'), n50 = load('n50-mechanism');
for (const a of [base,n50].map(syntheticAnchors)) { a[0].rpcA='http://a.invalid:8545'; a[0].rpcB='http://b.invalid:8545'; }
const rows = a => a.slice(1, -1);
const passports = a => [a[0].passport, a.at(-1).passport];
const topic = s => keccak256(toBytes(s));
const UOE = topic('UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)');
const LOCK = topic('LockCreated(address,bytes32,address,uint256,uint256)');
const addr = '0x' + '12'.repeat(20), addrTopic = '0x' + '0'.repeat(24) + addr.slice(2);
const run = (file, old) => {
  const r = spawnSync(process.execPath, [`${out}/${old ? 'validate-round2-old.mjs' : '../validate.mjs'}`, old ? file : currentFixture(file)], { encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 });
  assert.ifError(r.error);
  return { exit: r.status, report: JSON.parse(r.stdout) };
};
const results = [];
mkdirSync(`${out}/fixtures`, { recursive: true });
function control(name, mutate, source = base, expected = 1) {
  const a = structuredClone(source); mutate(a);
  const file = `${out}/fixtures/r2-${name}.jsonl`;
  writeFileSync(file, a.map(JSON.stringify).join('\n') + '\n');
  const old = run(file, true), fresh = run(file, false);
  assert.equal(old.exit, 0, `${name}: old must accept: ${JSON.stringify(old.report)}`);
  assert.equal(fresh.exit, expected, `${name}: new must reject: ${JSON.stringify(fresh.report)}`);
  assert.equal(fresh.report.accepted ?? false, false);
  results.push([name, old.exit, fresh.exit, fresh.report.missing ?? (fresh.report.errors.join('; ') || 'not accepted: recomputed conformance false')]);
}
function rehash(r) {
  const prior = r.expectedUserOpHash, h = localUserOpHash(r.packedOp, r.entryPoint, r.chainId);
  r.expectedUserOpHash = r.localUserOpHash = r.epUserOpHash = h;
  r.bundledOps = [structuredClone(r.packedOp)]; r.bundledUserOpHashes = [h];
  for (const l of r.logs) l.topics = l.topics.map(t => t.toLowerCase() === prior.toLowerCase() ? h : t);
}
control('sp-cloned-into-all-arms-n50', a => {
  for (let i = 1; i < a.length - 1; i += 3) for (let j = 1; j <= 2; j++) {
    const { arm, attemptIndex } = a[i+j]; a[i+j] = { ...structuredClone(a[i]), arm, attemptIndex };
  }
}, n50);
control('event-and-row-paymaster-outside-packed', a => {
  a[1].paymaster = addr; a[1].logs.find(l => l.topics[0] === UOE).topics[3] = addrTopic;
});
control('packed-paymaster-outside-passport', a => {
  const r = a[2]; r.packedOp.paymasterAndData = addr + r.packedOp.paymasterAndData.slice(42);
  r.paymaster = addr; rehash(r); r.logs.find(l => l.topics[0] === UOE).topics[3] = addrTopic;
});
control('passport-arm-paymasters-duplicated', a => passports(a).forEach(p => p.invariant.code.verifyingPaymaster.address = p.invariant.code.tokenPaymaster.address));
control('duplicate-tx-hash', a => a[2].tx.hash = a[1].tx.hash);
control('duplicate-userOpHash', a => {
  const index = 2, arm = a[index].arm; a[index] = { ...structuredClone(a[1]), arm, attemptIndex: index-1 };
});
control('packed-op-not-bundled', a => {
  const r = a[2], op = structuredClone(r.packedOp); op.nonce = String(BigInt(op.nonce)+1n);
  r.bundledOps = [op]; r.bundledUserOpHashes = [localUserOpHash(op,r.entryPoint,r.chainId)];
});
control('extra-uoe', a => {
  const l = structuredClone(a[1].logs.find(l => l.topics[0] === UOE)); l.topics[1] = '0x'+'13'.repeat(32); a[1].logs.push(l);
});
for (const [name, value] of Object.entries({ query:'http://127.0.0.1:8545?x=1', path:'http://127.0.0.1:8545/rpc', userinfo:'http://user:pass@127.0.0.1:8545', fragment:'http://127.0.0.1:8545#frag', ipv6:'http://[::1]:8545', localhost:'http://localhost:8545' })) {
  // localhost alone was already rejected; decoration makes it a round-2 old=0 case.
  control(`endpoint-${name}`, a => { a[0].rpcA='http://127.0.0.1:8545'; a[0].rpcB = name === 'localhost' ? value+'/rpc' : value; }, n50);
}
control('same-endpoint-recorded-nonconformant', a => { a[0].rpcB=a[0].rpcA; a[0].protocolConformant=false; }, n50, 1);
control('n50-override-recorded-nonconformant', a => {
  a[0].allowSameEndpointLocal=true; a[0].protocolConformant=false; passports(a).forEach(p=>p.allowSameEndpointLocal=true);
}, n50, 3);
control('canonical-flag', a => passports(a).forEach(p => p.invariant.entryPoint.isCanonicalV07Address=true));
control('passport-entrypoint-address', a => passports(a).forEach(p => p.invariant.entryPoint.address=addr));
control('passport-entrypoint-code-address', a => passports(a).forEach(p => p.invariant.code.entryPoint.address=addr));
for (const arm of ['SP','VPM','TPM','account']) {
  control(`passport-arm-ep-${arm}`, a => passports(a).forEach(p => p.invariant.armEntryPoints[arm]=addr));
  control(`passport-arm-ep-malformed-${arm}`, a => passports(a).forEach(p => p.invariant.armEntryPoints[arm]='not-an-address'), base, 2);
}
control('passport-sender', a => passports(a).forEach(p => p.invariant.sender=addr));
control('passport-sender-account-together', a => passports(a).forEach(p => {p.invariant.sender=addr;p.invariant.code.account.address=addr;}));
control('passport-sp-ep', a => passports(a).forEach(p => p.invariant.superPaymaster.entryPoint=addr));
control('passport-token-clone', a => passports(a).forEach(p => p.invariant.code.xPNTsClone.address=addr));
control('passport-operator-token', a => passports(a).forEach(p => p.invariant.superPaymaster.operator.xPNTsToken=addr));
control('passport-token-sp', a => passports(a).forEach(p => p.invariant.xPNTs.superPaymaster=addr));
control('passport-gas', a => passports(a).forEach(p => p.invariant.gas.callGasLimit='1'));
control('passport-callData', a => passports(a).forEach(p => p.invariant.callDataHash='0x'+'11'.repeat(32)));
control('passport-pm-gas', a => passports(a).forEach(p => p.invariant.pmGas.SP.ver='1'));
control('row-pm-gas', a => a[1].pmGas.ver='1');
for (const [field, value] of [['protocolFeeBPS',''],['protocolFeeBPS',true],['protocolFeeBPS','-1'],['protocolFeeBPS','1.5'],['paused','false'],['registry','not-an-address'],['version','']]) {
  control(`config-${field}-${String(value).replaceAll('.','_') || 'empty'}`, a => passports(a).forEach(p => p.invariant.superPaymaster[field]=value), base, 2);
}
for (const [field, value] of [['exchangeRate',''],['emergencyDisabled',0],['version','']]) control(`token-config-${field}`, a => passports(a).forEach(p => p.invariant.xPNTs[field]=value), base, 2);
control('passport-override-type', a => passports(a).forEach(p => p.allowSameEndpointLocal='false'), base, 2);
control('passport-override-start-mismatch', a => passports(a).forEach(p => p.allowSameEndpointLocal=!a[0].allowSameEndpointLocal));
control('passport-override-end-drift', a => a.at(-1).passport.allowSameEndpointLocal=!a[0].passport.allowSameEndpointLocal);
for (const index of [1,3]) control(`success-lock-topic-${index}`, a => a[1].logs.find(l=>l.topics[0]===LOCK).topics[index]=addrTopic);
// Keep one complete triplet and append one correctly modelled failed postOp transaction.
const post = structuredClone(base), r = structuredClone(base[1]);
r.tripletIndex=1; r.attemptIndex=3; r.verdict='USEROP_REVERTED';
const u = r.logs.find(l => l.topics[0] === UOE);
u.data=u.data.slice(0,66)+'0'.repeat(64)+u.data.slice(130);
r.logs=r.logs.filter(l=>l.topics[0]!==topic('TransactionSponsored(address,address,uint256,uint256)') && l.topics[0]!==topic('LockSettled(address,bytes32,uint256,uint256)'));
r.logs.push({address:r.entryPoint,topics:[topic('PostOpRevertReason(bytes32,address,uint256,bytes)'),r.expectedUserOpHash,u.topics[2]],data:'0x'});
const lock=r.logs.find(l=>l.topics[0]===LOCK), x=BigInt('0x'+lock.data.slice(2,66)), a0=BigInt('0x'+lock.data.slice(66,130));
for (const side of ['A','B']) {
  const b=r.readbacks.before[side], z=r.readbacks.after[side];
  Object.assign(z,{inflightA0:String(a0),inflightOperator:post[0].passport.invariant.superPaymaster.operator.address,
    operatorBalance:String(BigInt(b.operatorBalance)-a0),protocolRevenue:b.protocolRevenue,
    lockedOf:String(BigInt(b.lockedOf)+x),lockXLocked:String(x),totalSpent:String(BigInt(b.totalSpent)+a0),
    userXPNTs:b.userXPNTs,totalSupply:b.totalSupply,totalTxSponsored:b.totalTxSponsored});
}
r.tx.hash='0x'+'ab'.repeat(32);
// A new nonce gives the appended transaction its own operation identity.
r.packedOp.nonce=String(BigInt(post[3].nonce)+1n); r.nonce=r.packedOp.nonce; rehash(r);
u.data='0x'+BigInt(r.nonce).toString(16).padStart(64,'0')+u.data.slice(66);
for (const side of ['A','B']) {
  const b=r.readbacks.before[side], z=r.readbacks.after[side], prev=post[1].readbacks.after[side];
  for (const f of Object.keys(prev).filter(f=>!['blockNumber','blockHash','lockXLocked'].includes(f))) {
    if (f==='inflightOperator') { b[f]=prev[f]; continue; }
    const delta=BigInt(z[f])-BigInt(b[f]); b[f]=prev[f]; z[f]=String(BigInt(b[f])+delta);
  }
  b.blockNumber=post[3].tx.blockNumber; b.blockHash=post[3].tx.blockHash;
  z.blockNumber=String(BigInt(b.blockNumber)+1n); z.blockHash='0x'+'ac'.repeat(32);
}
r.tx.headBefore=r.readbacks.before.A.blockNumber; r.tx.blockNumber=r.readbacks.after.A.blockNumber; r.tx.blockHash=r.readbacks.after.A.blockHash;
post.at(-1).passport.block.number=r.tx.blockNumber; post.at(-1).passport.block.hash=r.tx.blockHash;
post.at(-1).passport.volatile.operatorBalance=r.readbacks.after.A.operatorBalance;
post.splice(-1,0,r);
const validPost=`${out}/fixtures/r2-postop-valid.jsonl`;
writeFileSync(validPost,post.map(JSON.stringify).join('\n')+'\n');
assert.equal(run(validPost,false).exit,0,'valid postOp branch must remain evaluable and consistent');
for (const f of ['totalSpent','userXPNTs','totalSupply','totalTxSponsored']) control(`postop-${f}`, a => {
  const r=a.at(-2); for(const side of ['A','B']) r.readbacks.after[side][f]=String(BigInt(r.readbacks.after[side][f])+1n);
},post);
for (const f of ['inflightA0','inflightOperator']) {
  // These are regressions already closed before round 2, verified in check-library.mjs.
  const broken=structuredClone(post);for(const side of ['A','B']) broken.at(-2).readbacks.after[side][f]=f==='inflightA0'?'7':addr;
  const file=`${out}/fixtures/r2-postop-${f}.jsonl`;writeFileSync(file,broken.map(JSON.stringify).join('\n')+'\n');assert.equal(run(file,false).exit,1);
}
control('zero-target-no-events', a => {
  a[0].count=0; a.at(-1).matchedTriplets=0; a.at(-1).stop={reason:'COMPLETE',code:0}; a.at(-1).exitCode=0;
},load('b-drop-op'),2);
writeFileSync(`${out}/round2-results.tsv`,'control\told_exit\tnew_exit\tproof\n'+results.map(r=>r.join('\t')).join('\n')+'\n');
console.log(`PASS: ${results.length} round-2 JSONL controls: old exit 0 -> new reject; valid postOp and inflight regressions pass`);
