import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { bindReceiptSummaries, bindArchivedDisposition } from './derived-evidence.mjs';
import { exclusionReason } from './evidence.mjs';
// Captured from an offline rehearsal window.
const fixture=JSON.parse(readFileSync(new URL('./derived-fixture.json',import.meta.url)));
const fresh=()=>structuredClone(fixture);
test('real rehearsal summaries and archived disposition are consistent',()=>{
  const {attempts,archives}=fresh();
  for(const a of attempts) {bindReceiptSummaries(a);bindArchivedDisposition(a,archives);exclusionReason(a,archives);}
});
test('delete row.preflight on a NOT_SENT attempt, add revertKind:"executionReverted" and an invented execRevert Panic(0x11) → op_failed_nongas',()=>{
  const {attempts,archives}=fresh(),a=attempts[1];
  delete a.preflight;a.revertKind='executionReverted';a.execRevert=[{revertReason:'0x4e487b71'+'0'.repeat(62)+'11'}];
  assert.throws(()=>exclusionReason(a,archives));
});
for(const field of ['execRevert','postOpRevert','prefundTooLow']) test(`nonempty ${field} arrays on a successful included attempt are checked`,()=>{
  const {attempts,archives}=fresh(),a=attempts[0];a[field]=[{revertReason:'0x4e487b71'+'0'.repeat(62)+'11'}];
  assert.throws(()=>exclusionReason(a,archives));
});
for(const field of ['revertReason','infraFailure','sponsorshipFailed','undecoded']) test(`preflight ${field} must equal decoded archived error`,()=>{
  const {attempts,archives}=fresh(),a=attempts[1];a.preflight[field]=field==='revertReason'?'price stale':!a.preflight[field];
  assert.throws(()=>exclusionReason(a,archives));
});
for(const field of ['userOpEvent','observedUserOpEvent']) test(`${field} cannot change decoded success or disappear`,()=>{
  for(const remove of [false,true]) {
    const {attempts}=fresh(),a=attempts[0];if(remove) a[field]=null;else a[field].success=false;
    assert.throws(()=>bindReceiptSummaries(a));
  }
});
test('submission exception requires archived send error',()=>{
  const {attempts,archives}=fresh(),a=attempts[1];a.submissionException={message:'fabricated'};
  assert.throws(()=>bindArchivedDisposition(a,archives),/submissionException/);
});
test('fee pause requires archived baseFee rather than invented numeric inequality',()=>{
  const {attempts,archives}=fresh(),a=attempts[1];a.failingCheck='basefee_above_cap';a.feeBlock={number:'130',hash:archives[0].records.find(r=>r.id===723).blockAnchor.hash};a.baseFeePerGas='999999999999';
  assert.throws(()=>bindArchivedDisposition(a,archives),/baseFeePerGas|feeBlock/);
});
test('refresh summaries must equal archived traces',()=>{
  const {attempts,archives}=fresh(),a=attempts[2];a.traces[0].call.calls=[];
  assert.throws(()=>bindArchivedDisposition(a,archives),/traces/);
});
test('sent flag must equal archived submission',()=>{
  const {attempts,archives}=fresh(),a=attempts[0];a.sent=false;
  assert.throws(()=>bindArchivedDisposition(a,archives),/sent/);
});
for(const field of ['verdict','failingCheck','revertKind']) test(`${field} must equal receipt classification`,()=>{
  const {attempts}=fresh(),a=attempts[0];a[field]='invented';assert.throws(()=>bindReceiptSummaries(a));
});
import { encodeAbiParameters, keccak256, toBytes } from 'viem';
for(const [field,event] of [['execRevert','UserOperationRevertReason'],['postOpRevert','PostOpRevertReason'],['prefundTooLow','UserOperationPrefundTooLow']]) test(`missing ${field} cannot hide a raw event`,()=>{
  const {attempts}=fresh(),a=attempts[0],u=a.logs.find(l=>l.topics[1]===a.expectedUserOpHash);
  const reason='0x4e487b71'+'0'.repeat(62)+'11';
  const args={userOpHash:a.expectedUserOpHash,sender:a.sender,nonce:a.nonce,...(field==='prefundTooLow'?{}:{revertReason:reason})};
  a.logs.push({...u,topics:[keccak256(toBytes(`${event}(bytes32,address,uint256${field==='prefundTooLow'?'':',bytes'})`)),u.topics[1],u.topics[2]],data:encodeAbiParameters(field==='prefundTooLow'?[{type:'uint256'}]:[{type:'uint256'},{type:'bytes'}],field==='prefundTooLow'?[BigInt(a.nonce)]:[BigInt(a.nonce),reason])});
  a[field]=[args];a.verdict='USEROP_REVERTED';a.failingCheck='revert_reason_with_success_true';
  bindReceiptSummaries(a);
  delete a[field];assert.throws(()=>bindReceiptSummaries(a),new RegExp(field));
});
import { encodeErrorResult, parseAbi } from 'viem';
test('FailedOpWithRevert inner bytes and Panic preflight are decoded from archived error bytes',()=>{
  const {attempts,archives}=fresh(),a=attempts[1],raw=archives[0].records.find(r=>r.id===723);
  const response=JSON.parse(Buffer.from(raw.response,'base64'));
  const panic='0x4e487b71'+'0'.repeat(62)+'11';
  response.error.data=encodeErrorResult({abi:parseAbi(['error FailedOpWithRevert(uint256 opIndex,string reason,bytes inner)']),errorName:'FailedOpWithRevert',args:[0n,'AA32 expired',panic]});
  raw.response=Buffer.from(JSON.stringify(response)).toString('base64');
  a.preflight={infraFailure:false,sponsorshipFailed:true,revertReason:'AA32 expired',inner:panic};
  assert.equal(exclusionReason(a,archives),'AA32');
  delete a.preflight.inner;assert.throws(()=>exclusionReason(a,archives));
  response.error.data=panic;raw.response=Buffer.from(JSON.stringify(response)).toString('base64');
  a.preflight={infraFailure:false,sponsorshipFailed:true,revertReason:panic};
  assert.equal(exclusionReason(a,archives),'op_failed_nongas');
  delete a.preflight;assert.throws(()=>exclusionReason(a,archives));
});
test('submission error message is derived from a matching archived signed handleOps',()=>{
  const {attempts,archives}=fresh(),a=attempts[0];
  const raw=archives[0].records.find(r=>r.method==='eth_sendRawTransaction' && r.id>a.evidenceStart[0] && r.id<=a.evidenceEnd[0]);
  const response=JSON.parse(Buffer.from(raw.response,'base64'));delete response.result;response.error={code:-32000,message:'transaction rejected'};
  raw.response=Buffer.from(JSON.stringify(response)).toString('base64');
  a.sent=false;a.tx=null;a.submissionException={message:response.error.message};
  bindArchivedDisposition(a,archives);
  delete a.submissionException;assert.throws(()=>bindArchivedDisposition(a,archives),/submissionException/);
  a.submissionException={message:'invented'};assert.throws(()=>bindArchivedDisposition(a,archives),/submissionException/);
});
