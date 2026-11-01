import { bindReceiptSummaries, evidenceEqual } from './derived-evidence.mjs';
import { decodeErrorResult, encodeFunctionData, parseAbi } from 'viem';
import { archivedParamsAllowed } from './state-evidence.mjs';
import { tpmAttemptRefreshed } from './trace-policy.mjs';
import { feePauseErrors } from './disposition.mjs';
import { readFileSync, writeFileSync, mkdirSync, openSync, writeSync, fsyncSync, closeSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { createHash } from 'node:crypto';
export const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');
export const stringify = x => JSON.stringify(x, (_, v) => typeof v === 'bigint' ? String(v) : v);
export function verifyPin(pin) {
  if (!pin?.path || !/^[a-f0-9]{64}$/.test(pin.sha256) || sha256(readFileSync(pin.path)) !== pin.sha256) throw new Error('invalid pin or SHA-256 mismatch');
  return pin;
}
export function loadPins(path) {
  const pins = JSON.parse(readFileSync(path));
  for (const key of ['collector', 'validator', 'dependencies', 'contractSources', 'abi', 'config']) {
    if (!Array.isArray(pins[key]) || !pins[key].length) throw new Error(`missing pins: ${key}`);
    pins[key] = pins[key].map(pin => ({ ...verifyPin(pin), path:resolve(pin.path) }));
  }
  return pins;
}
export function loadRegistry(path) {
  const r = JSON.parse(readFileSync(path));
  if (r.schemaVersion !== 'a6-rpc-identity/1') throw new Error('RPC identity registry version required');
  for (const e of ['A', 'B']) {
    for (const k of ['operatorName', 'backendIdentity', 'upstream', 'endpointLabel', 'registeredAt']) if (typeof r[e]?.[k] !== 'string' || !r[e][k].trim()) throw new Error(`RPC identity ${e}.${k} required`);
    if (!/^[\w .-]+$/.test(r[e].endpointLabel) || !Number.isFinite(Date.parse(r[e].registeredAt))) throw new Error('credential-free label and registration time required');
    if (!r[e].evidence?.length) throw new Error('RPC identity evidence required');
    r[e].evidence.forEach(verifyPin);
  }
  for (const k of ['operatorName', 'backendIdentity', 'upstream']) if (r.A[k].trim().toLowerCase() === r.B[k].trim().toLowerCase()) throw new Error(`RPC identities share ${k}`);
  return r;
}
export function rawArchive(window, endpoint) {
  const records = [], ids = [];
  mkdirSync(resolve(window, 'raw'), { recursive: true });
  mkdirSync(resolve(window, 'raw', endpoint));
  return { records, ids, append(row) {
    const ts = row.requestedAtUtc;
    const path = `raw/${endpoint}/${ts.slice(0, 10).replaceAll('-', '')}.ndjson`;
    const id = records.length + 1;
    const record = { ...row, id, ts, blockAnchor: row.anchor ? { number: String(BigInt(row.anchor.number)), hash: row.anchor.hash } : null,
      request: row.requestBase64, response: row.responseBase64 };
    const fd = openSync(resolve(window, path), 'a', 0o600);
    try { writeSync(fd, stringify(record) + '\n'); fsyncSync(fd); } finally { closeSync(fd); }
    records.push({ ...record, path }); ids.push(id);
  } };
}
const refs = rs => rs.map(({ path, id }) => ({ path, id }));
const pair = (archives, predicate) => Object.fromEntries(archives.map((a, i) => [i ? 'B' : 'A', refs(a.records.filter(predicate))]));
const stateFields = { entryPointDeposit: 'epDeposit', operatorBalance: 'operatorBalance', protocolRevenue: 'protocolRevenue', inflightOf: 'inflightOf', userXPNTs: 'userXPNTs', totalSupply: 'totalSupply', lockedOf: 'lockedOf', debts: 'debts', creditReservedOf: 'creditReservedOf', operatorTotalSpent: 'totalSpent', operatorTotalTxSponsored: 'totalTxSponsored', tpmTokenBalances: 'tpmTokenBalances', tpmCachedPriceTimestamp: 'tpmCachedPriceTimestamp', vpmDeposit: 'epDeposit' };
export function evidenceIndex(row, context) {
  const { windowId, archives, pins, rpcIdentity, passports, stopReason } = context;
  const missing = {};
  const value = (path, v, reason = 'not collected before attempt ended') => { if (v == null) { missing[path] = reason; return null; } return v; };
  const out = { schemaVersion: 'a6-evidence-index/1', windowId, tripleIndex: row.tripletIndex, attempt: row.attemptIndex, arm: row.arm,
    armOrder: row.armOrder ?? ['SP','VPM','TPM'], included: false, verdict: row.verdict,
    failureReason: row.failingCheck ?? null, notSentReason: row.verdict === 'NOT_SENT' ? row.reason ?? row.failingCheck ?? row.stoppedBy?.reason ?? 'unknown failure' : null,
    exclusionReason: exclusionReason(row,archives),
    stopReason: row.stoppedBy?.reason ?? (stopReason === 'COMPLETE' ? null : stopReason), replaces: context.replaces ?? null, replacedBy: null };
  for (const k of ['chainId','entryPoint','sender','nonce','paymaster','bundler','packedOp','callDataHash','expectedUserOpHash']) out[k] = value('/'+k, row[k]);
  if (out.chainId != null) out.chainId = String(out.chainId);
  if (out.nonce != null) out.nonce = String(out.nonce);
  out.bundle = value('/bundle', row.bundledOps);
  out.gas = value('/gas', row.gas && { ...row.gas, paymasterVerificationGasLimit: row.pmGas.ver, paymasterPostOpGasLimit: row.pmGas.post });
  out.tx = row.tx ? { txHash: row.tx.hash, ...Object.fromEntries(['blockNumber','blockHash','raw','input','handleOpsIndex','gasLimit','maxFeePerGas','maxPriorityFeePerGas'].map(k => [k, value('/tx/'+k, row.tx[k])])) } : value('/tx', null, 'transaction not submitted');
  const observed = row.observedUserOpEvent ?? row.userOpEvent;
  const event = row.logs?.find(l => l.logIndex === observed?.logIndex);
  const transactionRecord = archives[0].records.find(r => r.method === 'eth_getTransactionByHash' && r.params[0] === row.tx?.hash && r.response);
  if (out.tx && transactionRecord) {
    try { out.tx.raw = JSON.parse(Buffer.from(transactionRecord.response,'base64').toString()).result; delete missing['/tx/raw']; } catch {}
  }
  out.observedUserOpHash = value('/observedUserOpHash', observed?.userOpHash);
  out.uoe = value('/uoe', event && { txHash: observed.txHash ?? event.transactionHash ?? row.tx.hash, logIndex: event.logIndex, address: event.address, topics: event.topics, data: event.data });
  out.endpoints = Object.fromEntries(archives.map((a,i) => {
    const receipt = a.records.filter(r => r.method === 'eth_getTransactionReceipt' && r.params[0] === row.tx?.hash);
    const transaction = a.records.filter(r => r.method === 'eth_getTransactionByHash' && r.params[0] === row.tx?.hash);
    const stateReads = a.records.filter(r => ['eth_call','eth_getCode','eth_getStorageAt','eth_getBalance','eth_getTransactionCount'].includes(r.method) && r.id > (row.evidenceStart?.[i] ?? 0) && r.id <= (row.evidenceEnd?.[i] ?? Infinity));
    for (const [k, rs] of Object.entries({ receipt, logs: receipt, transaction, stateReads })) if (!rs.length) missing[`/endpoints/${i?'B':'A'}/${k}`] = 'no response collected';
    return [i ? 'B':'A', { receipt: refs(receipt), logs: refs(receipt), transaction: refs(transaction), stateReads: refs(stateReads) }];
  }));
  out.state = Object.fromEntries(['before','after'].map(side => [side, Object.fromEntries(Object.entries(stateFields).map(([k, source]) => {
    const applicable = ['entryPointDeposit','operatorBalance'].includes(k) || (k.startsWith('tpm') ? row.arm === 'TPM' : k === 'vpmDeposit' ? row.arm === 'VPM' : row.arm === 'SP');
    const s = row.readbacks?.[side]?.A;
    const v = k === 'inflightOf' && s ? { operator:s.inflightOperator, a0:s.inflightA0 } : s?.[source];
    const raw = pair(archives, r => applicable && s && r.method === 'eth_call' && r.blockAnchor && BigInt(r.blockAnchor.number) === BigInt(s.blockNumber) && r.blockAnchor.hash === s.blockHash && BigInt(r.params[1]) === BigInt(s.blockNumber));
    if (applicable && s) for (const e of ['A','B']) if (!raw[e].length) missing[`/state/${side}/${k}/raw/${e}`] = 'fixed-block raw state response unavailable';
    return [k, value(`/state/${side}/${k}`, applicable && v != null && s ? { value:v, anchor:{ number:s.blockNumber, hash:s.blockHash }, raw } : null, applicable ? 'fixed-block state unavailable' : `not applicable to ${row.arm}`)];
  }))]));
  out.passports = Object.fromEntries(['start','attempt','end'].map(k => [k, value('/passports/'+k, passports[k])]));
  out.trace = row.arm === 'TPM' && row.traces ? {oracle:row.tpmOracle,postOpRefreshed:row.postOpRefreshed,raw:pair(archives,r=>r.method==='debug_traceTransaction' && r.params[0]===row.tx?.hash)} : null;
  out.pins = pins; out.rpcIdentity = rpcIdentity; out.missing = missing;
  return JSON.parse(stringify(out));
}
export function writeArtifact(window, path, object) {
  mkdirSync(dirname(resolve(window,path)), { recursive:true });
  writeFileSync(resolve(window,path), stringify(object)+'\n', { flag:'wx', mode:0o600 });
}

export const EXCLUSION_REASONS = ['AA32', 'price_stale', 'not_included', 'op_failed_nongas', 'bundler_error', 'basefee_above_cap', 'tpm_postop_refresh'];
const preflightAbi = parseAbi(['error FailedOp(uint256 opIndex,string reason)', 'error FailedOpWithRevert(uint256 opIndex,string reason,bytes inner)']);
const simulationAbi = parseAbi(['function handleOps((address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData,bytes signature)[] ops,address beneficiary)']);
export function bindPreflight(row,archives) {
  const fail=()=>{throw new Error('UNAPPROVED_ABANDONMENT: raw preflight evidence missing or inconsistent');};
  let data;
  try { data=encodeFunctionData({abi:simulationAbi,functionName:'handleOps',args:[row.bundledOps,row.bundler]}); } catch { fail(); }
  const lower=v=>typeof v==='string'?v.toLowerCase():null;
  if (!archives?.[0]?.records.some(raw=>{
    if (raw.endpoint!=='A' || !(raw.id>row.evidenceStart?.[0] && raw.id<=row.evidenceEnd?.[0]) || raw.method!=='eth_call' || !archivedParamsAllowed(raw)) return false;
    const call=raw.params[0];
    if (lower(call.to)!==lower(row.entryPoint) || lower(call.from)!==lower(row.bundler) || lower(call.data)!==lower(data)) return false;
    try {
      const request=JSON.parse(Buffer.from(raw.request,'base64'));
      const response=JSON.parse(Buffer.from(raw.response,'base64'));
      if (request.method!==raw.method || JSON.stringify(request.params)!==JSON.stringify(raw.params) || response.id!==request.id || !response.error || 'result' in response) return false;
      let error=response.error;
      for (let i=0;i<8 && error;i++,error=error.cause) if (typeof error.data==='string') {
        const decoded=decodeErrorResult({abi:preflightAbi,data:error.data});
        const reason=decoded.errorName==='Panic' ? error.data : decoded.args[1];
        const expected={infraFailure:reason.startsWith('AA31'),sponsorshipFailed:!reason.startsWith('AA31'),revertReason:reason,...(decoded.errorName==='FailedOpWithRevert'?{inner:decoded.args[2]}:{})};
        return evidenceEqual(row.preflight,expected);
      }
    } catch {}
    return false;
  })) fail();
}
export function replacementReason(row,archives) {
  const reason=exclusionReason(row,archives);
  // A successful TPM refresh is a measured exclusion, not a preflight failure.
  return reason ?? (row.arm==='TPM' && row.traces && tpmAttemptRefreshed(row) ? 'tpm_postop_refresh' : null);
}
export function exclusionReason(row,archives) {
  if (row.sent===true && row.verdict==='USEROP_SUCCESS' && (row.preflight || row.failingCheck || row.revertKind || row.execRevert?.length || row.postOpRevert?.length || row.prefundTooLow?.length || row.submissionException || (row.reason != null && row.reason!=='tpm_postop_refresh'))) throw new Error('successful attempt contradicts failure evidence');
  if (row.preflight || (row.verdict==='NOT_SENT' && row.failingCheck==='preflight_revert')) bindPreflight(row,archives);
  if (row.logs || row.execRevert || row.postOpRevert || row.prefundTooLow || row.revertKind) bindReceiptSummaries(row);
  const unsupported = () => { throw new Error('UNAPPROVED_ABANDONMENT: unsupported exclusion reason'); };
  const preflight = row.preflight?.undecoded ? '' : row.preflight?.revertReason ?? '';
  let reason = null;
  if (row.failingCheck === 'basefee_above_cap' && row.feeBlock && !feePauseErrors(row).length) reason = 'basefee_above_cap';
  else if (/^AA32/.test(preflight)) reason = 'AA32';
  else if (/^(?:AA33 reverted: )?(?:price_stale|PriceStale|price stale)$/.test(preflight)) reason = 'price_stale';
  else if (/^0x4e487b71[0-9a-f]{62}(11|12)$/i.test(preflight)) reason = 'op_failed_nongas';
  else if (row.revertKind === 'executionReverted' && row.execRevert?.some(e =>
    /^0x4e487b71[0-9a-f]{62}(11|12)$/i.test(e.revertReason))) reason = 'op_failed_nongas';
  else if (row.sent !== true && !row.tx && typeof row.submissionException?.message === 'string' && row.submissionException.message.length) reason = 'bundler_error';
  else if (row.sent === true && row.tx?.hash && row.tx.blockHash == null && row.tx.blockNumber == null && row.tx.status == null && !row.userOpEvent && !row.observedUserOpEvent && Array.isArray(row.logs) && !row.logs.length) reason = 'not_included';
  else if (row.arm === 'TPM' && row.traces && tpmAttemptRefreshed(row)) reason = 'tpm_postop_refresh';
  if (row.reason != null && row.reason !== reason) unsupported();
  // A successful op may still refresh TPM; the replacement edge carries that exclusion.
  if (row.verdict === 'USEROP_SUCCESS') return null;
  if (reason === null) unsupported();
  return reason;
}
export function appendIndex(window, row) {
  const fd = openSync(resolve(window, 'index.ndjson'), 'a', 0o600);
  try { writeSync(fd, stringify(row) + '\n'); fsyncSync(fd); } finally { closeSync(fd); }
}
export function armCounts(rows, triples, replacements = []) {
  const abandoned = new Map(replacements.map(e => [e.abandoned.tripleIndex, e.reason]));
  const included = new Set(triples.filter(t => t.included).flatMap(t => t.attempts));
  return Object.fromEntries(['SP','VPM','TPM'].map(arm => {
    const rs = rows.filter(r => r.arm === arm), excluded = {};
    for (const r of rs) if (!included.has(r.attempt)) {
      const reason = r.exclusionReason ?? abandoned.get(r.tripleIndex);
      if (reason != null) excluded[reason] = (excluded[reason] ?? 0) + 1;
    }
    return [arm, { attempts:rs.length, included:rs.filter(r => included.has(r.attempt)).length, excluded, notSent:rs.filter(r => r.tx === null).length }];
  }));
}
export function writeTrailer(window, trailer) {
  const fd = openSync(resolve(window, 'trailer.json'), 'wx', 0o600);
  try { writeSync(fd, stringify(trailer) + '\n'); fsyncSync(fd); } finally { closeSync(fd); }
}
