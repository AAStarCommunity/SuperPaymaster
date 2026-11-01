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
  const { windowId, archives, pins, rpcIdentity, passports, included, stopReason } = context;
  const missing = {};
  const value = (path, v, reason = 'not collected before attempt ended') => { if (v == null) { missing[path] = reason; return null; } return v; };
  const out = { schemaVersion: 'a6-evidence-index/1', windowId, tripleIndex: row.tripletIndex, attempt: row.attemptIndex, arm: row.arm,
    armOrder: row.armOrder ?? ['SP','VPM','TPM'], included, verdict: row.verdict,
    failureReason: row.failingCheck ?? null, notSentReason: row.verdict === 'NOT_SENT' ? row.reason ?? row.failingCheck ?? row.stoppedBy?.reason ?? 'unknown failure' : null,
    exclusionReason: included ? null : row.exclusion ?? row.stoppedBy?.reason ?? row.failingCheck ?? stopReason ?? 'unmatched_triple',
    stopReason: row.stoppedBy?.reason ?? (stopReason === 'COMPLETE' ? null : stopReason), replaces: null, replacedBy: null };
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
    const raw = pair(archives, r => r.method === 'eth_call' && r.blockAnchor?.number === String(s?.blockNumber) && r.blockAnchor?.hash === s?.blockHash);
    if (applicable && s) for (const e of ['A','B']) if (!raw[e].length) missing[`/state/${side}/${k}/raw/${e}`] = 'fixed-block raw state response unavailable';
    return [k, value(`/state/${side}/${k}`, applicable && v != null && s ? { value:v, anchor:{ number:s.blockNumber, hash:s.blockHash }, raw } : null, applicable ? 'fixed-block state unavailable' : `not applicable to ${row.arm}`)];
  }))]));
  out.passports = Object.fromEntries(['start','attempt','end'].map(k => [k, value('/passports/'+k, passports[k])]));
  out.pins = pins; out.rpcIdentity = rpcIdentity; out.missing = missing;
  if (out.included && Object.entries(missing).some(([p,r]) => !r.startsWith('not applicable'))) { out.included = false; out.exclusionReason = 'incomplete_evidence'; }
  return JSON.parse(stringify(out));
}
export function writeArtifact(window, path, object) {
  mkdirSync(dirname(resolve(window,path)), { recursive:true });
  writeFileSync(resolve(window,path), stringify(object)+'\n', { flag:'wx', mode:0o600 });
}
