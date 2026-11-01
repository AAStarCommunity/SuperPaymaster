import { decodeEventLog, parseAbi, parseTransaction, encodeFunctionData } from 'viem';
import { tpmAttemptRefreshed } from './trace-policy.mjs';
const abi = parseAbi([
  'event UserOperationEvent(bytes32 indexed userOpHash,address indexed sender,address indexed paymaster,uint256 nonce,bool success,uint256 actualGasCost,uint256 actualGasUsed)',
  'event UserOperationRevertReason(bytes32 indexed userOpHash,address indexed sender,uint256 nonce,bytes revertReason)',
  'event PostOpRevertReason(bytes32 indexed userOpHash,address indexed sender,uint256 nonce,bytes revertReason)',
  'event UserOperationPrefundTooLow(bytes32 indexed userOpHash,address indexed sender,uint256 nonce)',
]);
const bundleAbi=parseAbi(['function handleOps((address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData,bytes signature)[] ops,address beneficiary)']);
const lower = x => typeof x === 'string' ? x.toLowerCase() : x;
const canonical = x => typeof x === 'bigint' ? String(x) : Array.isArray(x) ? x.map(canonical) : x && typeof x === 'object' ? Object.fromEntries(Object.keys(x).sort().map(k=>[k,canonical(x[k])])) : typeof x==='string' && x.startsWith('0x') ? x.toLowerCase() : x;
export const evidenceEqual = (a,b) => JSON.stringify(canonical(a)) === JSON.stringify(canonical(b));
const requireEqual = (field, actual, expected) => { if (!evidenceEqual(actual,expected)) throw Error(`UNAPPROVED_ABANDONMENT: derived evidence mismatch: ${field}`); };

// Summaries are assertions, never evidence. Absence is allowed only for an empty
// optional summary in older journals; absence cannot hide a decoded event.
export function bindReceiptSummaries(row) {
  const events = [];
  for (const log of row.logs ?? []) {
    if (lower(log.address)!==lower(row.entryPoint)) continue;
    try { const d=decodeEventLog({abi,data:log.data,topics:log.topics,strict:true}); events.push({...d,log}); } catch { }
  }
  const ours = events.filter(e=>lower(e.args.userOpHash)===lower(row.expectedUserOpHash));
  for (const [field,name] of [['execRevert','UserOperationRevertReason'],['postOpRevert','PostOpRevertReason'],['prefundTooLow','UserOperationPrefundTooLow']]) {
    const value=ours.filter(e=>e.eventName===name).map(e=>e.args);
    requireEqual(field,row[field] ?? [],value);
  }
  const uoes=ours.filter(e=>e.eventName==='UserOperationEvent');
  const u=uoes.length===1 ? uoes[0] : null;
  if (row.sent && row.tx?.status) {
    let verdict, failure;
    if (row.tx.status!=='success') { verdict='TX_FAILED'; failure='receipt_status'; }
    else if (!uoes.length) {
      const same=events.some(e=>e.eventName==='UserOperationEvent' && lower(e.args.sender)===lower(row.sender) && String(e.args.nonce)===String(row.nonce));
      verdict=same?'HASH_MISMATCH':'NO_EVENT'; failure=same?'expected_hash_in_events':'user_operation_event_present';
    } else if (uoes.length>1) { verdict='DUPLICATE_EVENT'; failure='single_event'; }
    else if (lower(u.args.sender)!==lower(row.sender) || String(u.args.nonce)!==String(row.nonce) || lower(u.args.paymaster)!==lower(row.paymaster)) { verdict='EVENT_FIELD_MISMATCH'; failure='event_sender_nonce_paymaster'; }
    else if (!u.args.success) { verdict='USEROP_REVERTED'; failure='user_operation_success'; }
    else if (ours.some(e=>e.eventName!=='UserOperationEvent')) { verdict='USEROP_REVERTED'; failure='revert_reason_with_success_true'; }
    else { verdict='USEROP_SUCCESS'; failure=null; }
    requireEqual('verdict',row.verdict,verdict);
    requireEqual('failingCheck',row.failingCheck,failure);
  }
  const kind=u && !u.args.success ? (ours.some(e=>e.eventName==='PostOpRevertReason')?'postOpReverted':ours.some(e=>e.eventName==='UserOperationPrefundTooLow')?'prefundTooLow':'executionReverted') : null;
  requireEqual('revertKind',row.revertKind ?? null,kind);
  if (row.userOpEvent != null || u) requireEqual('userOpEvent',row.userOpEvent,u ? {...u.args,...(('logIndex' in (row.userOpEvent ?? {}) || u.log.transactionHash)?{logIndex:Number(u.log.logIndex)}:{})} : null);
  const observed=events.find(e=>e.eventName==='UserOperationEvent' && lower(e.args.sender)===lower(row.sender) && String(e.args.nonce)===String(row.nonce));
  // Legacy non-formal journals did not record this summary.
  if ('observedUserOpEvent' in row || observed?.log.transactionHash) requireEqual('observedUserOpEvent',row.observedUserOpEvent,observed ? {...observed.args,logIndex:Number(observed.log.logIndex),txHash:observed.log.transactionHash} : null);
}

export function bindArchivedDisposition(row,archives) {
  const records=archives[0].records.filter(r=>r.id>row.evidenceStart?.[0] && r.id<=row.evidenceEnd?.[0]);
  const response=r=>r.response ? JSON.parse(Buffer.from(r.response,'base64')) : null;
  const sends=records.filter(r=>r.method==='eth_sendRawTransaction');
  const submitted=sends.filter(r=>typeof response(r)?.result==='string');
  if (submitted.length) {
    requireEqual('sent',row.sent,true);
    requireEqual('tx.hash',row.tx?.hash,response(submitted.at(-1)).result);
  } else requireEqual('sent',row.sent,false);
  const failed=sends.filter(r=>response(r)?.error);
  for (const raw of failed) {
    const tx=parseTransaction(raw.params[0]);
    requireEqual('submission target',tx.to,row.entryPoint);
    requireEqual('submission input',tx.data,encodeFunctionData({abi:bundleAbi,functionName:'handleOps',args:[row.bundledOps,row.bundler]}));
  }
  const exception=failed.length ? {message:response(failed.at(-1)).error.message} : null;
  requireEqual('submissionException',row.submissionException ?? null,exception);
  if (row.failingCheck==='basefee_above_cap' || row.feeBlock || row.baseFeePerGas!=null) {
    const blocks=records.filter(r=>r.method==='eth_getBlockByNumber').map(response).map(r=>r?.result).filter(Boolean);
    const block=blocks.find(b=>lower(b.hash)===lower(row.feeBlock?.hash) && String(BigInt(b.number))===String(row.feeBlock?.number));
    if (!block) throw Error('derived evidence mismatch: feeBlock');
    requireEqual('baseFeePerGas',row.baseFeePerGas,String(BigInt(block.baseFeePerGas)));
    if (BigInt(block.baseFeePerGas)<=BigInt(row.gas.maxFeePerGas)) throw Error('derived evidence mismatch: fee pause');
  }
  if (row.traces || row.postOpRefreshed!=null) {
    for (const [i,arc] of archives.entries()) for (const [tracer,key] of [['callTracer','call'],['prestateTracer','state']]) {
      const raw=arc.records.find(r=>r.id>row.evidenceStart?.[i] && r.id<=row.evidenceEnd?.[i] && r.method==='debug_traceTransaction' && lower(r.params[0])===lower(row.tx?.hash) && r.params[1]?.tracer===tracer);
      if (!raw) throw Error('TPM raw trace missing or inconsistent');
      requireEqual(`traces.${i}.${key}`,row.traces?.[i]?.[key],response(raw)?.result);
    }
    const refresh=tpmAttemptRefreshed(row);
    for (const t of row.traces) requireEqual('traces.postOpRefreshed',t.postOpRefreshed,refresh);
  }
}
