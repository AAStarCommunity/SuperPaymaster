import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
// Archived EIP-1898 requests and raw ABI replies from two distinct endpoints.
import { baselineFor } from './baseline.mjs';
import { decodeFunctionResult, encodeFunctionData, parseAbi, keccak256 } from 'viem';
export const STATE_ABI = parseAbi([
  'function tokenPaymasterConfig() view returns (uint256 priceMarkup,uint128 minEntryPointBalance,uint48 refundPostopCost,uint48 priceMaxAge)',
  'function cachedPrice() view returns (uint256)',
  'function operators(address) view returns (uint128 aPNTsBalance,bool isConfigured,bool isPaused,address xPNTsToken,uint32 reputation,uint48 minTxInterval,address treasury,uint256 totalSpent,uint256 totalTxSponsored)',
]);
export class EvidenceError extends Error {
  constructor(reason, diagnostic) { super(`${reason}: ${diagnostic}`); this.invalid_reason = reason; }
}
export const check = (condition, diagnostic, reason = 'collector_corruption') => {
  if (!condition) throw new EvidenceError(reason, diagnostic);
};
export function dualRead(records, address, blockHash, functionName, args = []) {
  check(records?.length === 2 && records[0].endpoint && records[1].endpoint &&
    records[0].endpoint !== records[1].endpoint, 'two distinct RPC archives required');
  const data = encodeFunctionData({abi:STATE_ABI, functionName, args});
  for (const r of records) {
    check(r.method === 'eth_call' && r.params.length === 2 &&
      r.params[0].to.toLowerCase() === address.toLowerCase() && r.params[0].data === data &&
      r.params[1].blockHash === blockHash && r.params[1].requireCanonical === true,
    'hash-bound state read mismatch');
  }
  check(records[0].result === records[1].result, 'state replies disagree', 'rpc_mismatch');
  return decodeFunctionResult({abi:STATE_ABI, functionName, data:records[0].result});
}
export function checkRuntime(baseline, records, address, blockHash) {
  check(baseline?.tpm_runtime_codehash && baseline?.frozen_build_sha256,
    'TPM baseline binding missing');
  const expected=baselineFor(baseline.immutables);
  check(baseline.frozen_build_sha256===expected.frozen_build_sha256 &&
    baseline.tpm_runtime_codehash===expected.tpm_runtime_codehash, 'TPM frozen build binding mismatch');
  check(records?.length === 2 && records[0].endpoint !== records[1].endpoint,
    'two runtime RPC archives required');
  for (const r of records) {
    check(r.method === 'eth_getCode' && r.params[0].toLowerCase() === address.toLowerCase() &&
      r.params[1].blockHash === blockHash && r.params[1].requireCanonical === true,
    'hash-bound runtime read mismatch');
    check(keccak256(r.result) === baseline.tpm_runtime_codehash, 'TPM runtime codehash mismatch');
  }
}

// EP v0.7 EntryPoint.sol:716-726. Write d=L+preOpGas-G>0:
// A=L+preOpGas-ceil(9*d/10); 10*(B-A-1)<9*d<=10*(B-A).
export function invertPenalty(actual, preOp, limit) {
  const A=BigInt(actual), P=BigInt(preOp), L=BigInt(limit), B=P+L;
  const candidates=[];
  const q=B-A;
  if(q>0n) {
    const lo=10n*(q-1n)/9n+1n, hi=10n*q/9n;
    for(let d=lo;d<=hi;d++) {
      const G=B-d;
      if(G>=P && d>0n && G+d/10n===A) candidates.push(G);
    }
  }
  if(A>=B && A>=P) candidates.push(A);
  candidates.sort((a,b)=>a<b?-1:a>b?1:0);
  check(candidates.length>0, 'no consistent gasBeforePenalty');
  check(candidates.length<=2, 'penalty inverse cardinality');
  const penalties=candidates.map(g=>A-g);
  return {gasBeforePenalty:candidates.length===1?candidates[0]:null,
    gasBeforePenaltyCandidates:candidates.map(String).join(';'),
    unusedGasPenaltyMin:penalties.reduce((a,b)=>a<b?a:b),
    unusedGasPenaltyMax:penalties.reduce((a,b)=>a>b?a:b)};
}

export const CHAINS=JSON.parse(readFileSync(new URL('./chain-params.json',import.meta.url)));
const canonical=v=>JSON.stringify(v, Object.keys(v).sort());
export function qualificationFor(chain) {
  const payload={schema:'rq3-qualification-v1',chain,...CHAINS[chain]};
  return {payload,sha256:createHash('sha256').update(canonical(payload)).digest('hex')};
}
export function receiptReady(archive) {
  const q=archive.qualification, c=archive.confirmation, receipt=archive.receipt;
  check(q && CHAINS[q.payload.chain] && q.sha256===qualificationFor(q.payload.chain).sha256 &&
    canonical(q.payload)===canonical(qualificationFor(q.payload.chain).payload), 'qualification manifest mismatch');
  check(c && Number.isFinite(c.broadcastAt) && Number.isFinite(c.observedAt) && c.observedAt>=c.broadcastAt,
    'receipt timing evidence required');
  // A finalised timeout must show that the frozen deadline had elapsed when it was declared.
  if(archive.finalTimeout) check(Number.isFinite(c.timeoutDeclaredAt) &&
    c.timeoutDeclaredAt-c.broadcastAt>=q.payload.receipt_timeout_seconds, 'final timeout declared before frozen deadline');
  if(c.observedAt-c.broadcastAt>=q.payload.receipt_timeout_seconds || archive.finalTimeout)
    return {success:false,failure_reason:'receipt_timeout',supplemental_only:!!receipt};
  check(receipt, 'receipt_timeout before frozen deadline');
  check(Number.isSafeInteger(c.headNumber) && Number.isSafeInteger(receipt.blockNumber) &&
    c.headNumber-receipt.blockNumber>=q.payload.confirmation_depth, 'receipt confirmation depth');
  check(c.rereadBlockNumber===receipt.blockNumber && c.rereadHeadNumber>=c.headNumber,
    'confirmation block hash reread required');
  check(c.rereadBlockHash===receipt.blockHash, 'confirmation block hash changed', 'chain_reorg');
  return null;
}
