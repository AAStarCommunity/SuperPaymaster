// EntryPoint v0.7 innerHandleOp ABI (EntryPoint.sol:285-318). UserOpInfo is static:
// head word 0 is the bytes offset, words 1..10 MemoryUserOp, 11 hash, 12 prefund,
// 13 contextOffset, 14 preOpGas, 15 context bytes offset.
export const INNER_HANDLE_OP = '0x0042dc53';
const lower = v => String(v).toLowerCase();
const uint = v => {
  if (!/^(0|[1-9][0-9]*)$/.test(String(v))) throw new Error('invalid unsigned decimal');
  return BigInt(v);
};

export function decomposeGas(row, uoe) {
  const result = {
    actualGasUsed: uoe?.actualGasUsed == null ? null : String(uoe.actualGasUsed),
    unusedGasPenalty: null, executionGasUsed: null, preOpGas: null,
    callGasLimit: row.gas?.callGasLimit == null ? null : String(row.gas.callGasLimit),
    paymasterPostOpGasLimit: row.pmGas?.post == null ? null : String(row.pmGas.post),
    executionGasLimit: null, status: 'unavailable', reason: null,
    bounds: null, reconstructionMatches: null,
  };
  const unavailable = reason => ({ ...result, reason });
  const mismatch = reason => ({ ...result, status: 'mismatch', reason, reconstructionMatches: false });
  if (!uoe || uoe.actualGasUsed == null) return unavailable('no unique UserOperationEvent');
  const trace = row.gasTrace;
  if (!trace?.result) return unavailable(trace?.reason || 'no debug_traceTransaction callTracer trace');
  try {
    const A = uint(result.actualGasUsed), L = uint(result.callGasLimit) + uint(result.paymasterPostOpGasLimit);
    result.executionGasLimit = String(L);
    if (trace.tracer !== 'callTracer' || lower(trace.transactionHash) !== lower(row.tx?.hash)
      || lower(trace.blockHash) !== lower(row.tx?.blockHash)) return mismatch('trace transaction/block binding mismatch');
    const root = trace.result;
    if (root.error || lower(root.to) !== lower(row.entryPoint)) return unavailable('trace root is not a successful EntryPoint transaction');
    const frames = [];
    const walk = frame => {
      if (lower(frame.from) === lower(row.entryPoint) && lower(frame.to) === lower(row.entryPoint)
        && lower(frame.input).startsWith(INNER_HANDLE_OP)) frames.push(frame);
      for (const child of frame.calls || []) walk(child);
    };
    walk(root);
    const word = (input, i) => input.slice(10 + 64 * i, 10 + 64 * (i + 1));
    const hits = frames.filter(f => lower('0x' + word(f.input, 11)) === lower(row.expectedUserOpHash));
    if (hits.length !== 1 || hits[0].error) return unavailable('need one non-reverted innerHandleOp for this userOpHash; fallback paths unsupported');
    const f = hits[0], input = f.input;
    if (f.type !== 'CALL' || !/^0x[0-9a-f]+$/i.test(input) || input.length < 10 + 16 * 64) return mismatch('malformed innerHandleOp trace');
    const n = i => BigInt('0x' + word(input, i));
    if (n(0) !== 512n || n(15) < 544n || n(15) % 32n !== 0n
      || n(15) * 2n + 10n + 64n > BigInt(input.length)) return mismatch('invalid innerHandleOp dynamic offsets');
    if (n(4) !== uint(result.callGasLimit) || n(6) !== uint(result.paymasterPostOpGasLimit)
      || n(2) !== uint(row.nonce) || lower('0x' + word(input, 1).slice(24)) !== lower(row.sender)
      || lower('0x' + word(input, 8).slice(24)) !== lower(row.paymaster)) return mismatch('innerHandleOp operation binding mismatch');
    const P = n(14);
    result.preOpGas = String(P);
    const total = E => P + E + (L > E ? (L - E) / 10n : 0n);
    // Invert A=P+E+floor(max(L-E,0)/10). It is monotone, with plateaus of at
    // most two consecutive integers. Binary search avoids loops proportional to gas.
    let lo = 0n, hi = A + 1n;
    while (lo < hi) {
      const mid = (lo + hi) / 2n;
      if (total(mid) < A) lo = mid + 1n; else hi = mid;
    }
    if (total(lo) !== A) return mismatch('N-2 reconstruction mismatch: no nonnegative executionGasUsed');
    const upper = total(lo + 1n) === A ? lo + 1n : lo;
    const penalty = E => L > E ? (L - E) / 10n : 0n;
    if (upper !== lo) {
      return { ...result, status: 'bounded', reason: 'integer rounding admits two execution-gas values; preOpGas and limits are exact',
        bounds: { executionGasUsed: [String(lo), String(upper)], unusedGasPenalty: [String(penalty(upper)), String(penalty(lo))] },
        reconstructionMatches: true };
    }
    return { ...result, executionGasUsed: String(lo), unusedGasPenalty: String(penalty(lo)),
      status: 'exact', reason: null, reconstructionMatches: total(lo) === A };
  } catch {
    return mismatch('malformed gas or trace evidence');
  }
}

// A stored exact claim is evidence to cross-check, never a substitute for re-derivation.
export function exactClaimMatches(claim, derived) {
  if (claim?.status !== 'exact') return true;
  try {
    return derived.status === 'exact' && derived.reconstructionMatches === true
      && ['actualGasUsed', 'preOpGas', 'executionGasUsed', 'unusedGasPenalty', 'callGasLimit', 'paymasterPostOpGasLimit']
        .every(k => String(claim[k]) === derived[k])
      && uint(claim.actualGasUsed) === uint(claim.preOpGas) + uint(claim.executionGasUsed) + uint(claim.unusedGasPenalty);
  } catch { return false; }
}
