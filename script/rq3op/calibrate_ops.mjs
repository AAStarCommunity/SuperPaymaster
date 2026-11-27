// REHEARSAL calibration helper: send one UserOperation per arm per sender through
// EntryPoint.handleOps on a LOCAL ANVIL FORK and record per-field gas from a callTracer trace.
//
// The operation bytes follow the frozen-plan collector exactly:
//   - gas, paymaster gas, fees and callData come from frozen-plan.mjs createFrozenPlan(...).frozen
//     (the collector's own adapter), checked against the bundle SHA-256;
//   - packing / signing mirrors collector.mjs signAndHash (lines 329-345) and pmDataFor (347-362):
//     collector.mjs is a top-level-await CLI script with no exports, so those 30 lines are
//     reproduced here verbatim in behaviour and checked with the collector's own helpers
//     (pvg.mjs finalizePVG with the plan's pvgLengths/pvgReserve, gauge-lib localUserOpHash,
//     classifyAttempt, branch.mjs settlementBranch);
//   - the outer transaction gas is pc.bounds[arm].outer (frozen-plan.mjs send()).
// Fork-only substitutions (no real key is available or wanted): each S's owner storage slot is
// set to a public fork-only key, and the VerifyingPaymaster's verifyingSigner immutable bytes are
// replaced by a fork-only signer. Both keep code paths and gas-relevant shapes identical
// (same SLOAD/PUSH20 and ecrecover; same calldata lengths, checked by checkPVGLengths).
// Never point this at a real chain: it refuses anything but chainId 11155111 or 11155420 on 127.0.0.1.
import { redact, requireFork } from './calibration_safety.mjs';
import { readFileSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { concat, encodeAbiParameters, encodeFunctionData, getAddress, keccak256, pad, toHex, parseAbi, decodeEventLog } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { createFrozenPlan, parse } from '../a6-collector/frozen-plan.mjs';
import { finalizePVG, measurePVG, checkPVGLengths } from '../a6-collector/pvg.mjs';
import { localUserOpHash, classifyAttempt, VERDICTS } from '../a6-collector/gauge-lib.mjs';
import { settlementBranch, settlementSignatures } from './branch.mjs';

const [requestPath] = process.argv.slice(2);
const req = JSON.parse(readFileSync(requestPath, 'utf8'));
const url = req.forkUrl;
if (!/^http:\/\/127\.0\.0\.1:\d+$/.test(url)) throw Error('fork URL must be http://127.0.0.1:<port>');
let id = 0;
async function rawRpc(method, params = []) {
  let body;
  try {
  const res = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params }, (_, v) => typeof v === 'bigint' ? toHex(v) : v) });
  body = await res.json();
  } catch { throw Error(`${method}: RPC transport failure; details redacted`); }
  if (body.error) throw Error(`${method}: ${redact(body.error, true)}`);
  return body.result;
}
async function rpc(method, params = []) {
  if (/^(anvil_|evm_)/.test(method) || method === 'eth_sendTransaction') await requireFork(req, rawRpc);
  return rawRpc(method, params);
}
const u128 = v => pad(toHex(v), { size: 16 });
const EP = getAddress('0x0000000071727De22E5E9d8BAf0edAc6f37da032');
const EP_ABI = parseAbi([
  'function getNonce(address sender, uint192 key) view returns (uint256)',
  'function getUserOpHash((address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData,bytes signature) op) view returns (bytes32)',
  'function handleOps((address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData,bytes signature)[] ops,address beneficiary)',
]);
const VPM_ABI = parseAbi([
  'function getHash((address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData,bytes signature) userOp,uint48 validUntil,uint48 validAfter) view returns (bytes32)',
  'function verifyingSigner() view returns (address)']);
const OWNER_ABI = parseAbi(['function owner() view returns (address)']);
async function call(to, abi, functionName, args = []) {
  const { decodeFunctionResult } = await import('viem');
  const data = encodeFunctionData({ abi, functionName, args });
  return decodeFunctionResult({ abi, functionName, data: await rpc('eth_call', [{ to, data }, 'latest']) });
}
// Freeze fork time to block-by-block +1 s: wall-clock drift during the limit search would otherwise age SP's
// cached price past priceStalenessThreshold (SP returns it as validUntil -> AA32). Explicit evm_increaseTime is
// still used where the plan requires elapsed time (SP minTxInterval between rounds).
async function pinNextTimestamp() {
  const b = await rpc('eth_getBlockByNumber', ['latest', false]);
  await rpc('evm_setNextBlockTimestamp', [Number(BigInt(b.timestamp) + 1n)]);
}
const SEL = { validateUserOp: '0x19822f7c', validatePaymasterUserOp: '0x52b7512c', postOp: '0x7c627b21', innerHandleOp: '0x0042dc53', execute: '0xb61d27f6' };
const lower = v => String(v).toLowerCase();

const chain = BigInt(await rpc('eth_chainId'));
if (chain !== 11155111n && chain !== 11155420n) throw Error('fork chainId must be 11155111 or 11155420');
await requireFork(req, rawRpc);
const bytes = readFileSync(req.bundlePath);
const bundleSha256 = createHash('sha256').update(bytes).digest('hex');
if (bundleSha256 !== req.bundleSha256) throw Error('BUNDLE_DIGEST_MISMATCH');
const bundle = parse(bytes);
const forkKey = label => keccak256(toHex(`rq3-calib/fork-only/${label}`));
const vSigner = privateKeyToAccount(forkKey('verifying-signer'));
const out = { forkSubstitutions: [], ops: [] };

// VerifyingPaymaster: replace verifyingSigner immutable bytes (fork only), after its C12 readback passed.
const plan0 = Object.values(bundle.plans).find(p => Number(p.planIndex) === 0);
const pc0 = plan0.phaseC;
const VPM = getAddress(pc0.addresses.VPM), TPM = getAddress(pc0.addresses.TPM), SP = getAddress(pc0.addresses.SP), X = getAddress(pc0.addresses.X);
const realSigner = lower(plan0.externalInputs.data.phaseC.verifyingSigner).slice(2);
const code = lower(await rpc('eth_getCode', [VPM, 'latest']));
const codeHashBefore = keccak256(code);
const hits = code.split(realSigner).length - 1;
if (hits < 1) throw Error('verifyingSigner bytes not found in VPM runtime');
await rpc('anvil_setCode', [VPM, code.split(realSigner).join(lower(vSigner.address).slice(2))]);
if (lower(await call(VPM, VPM_ABI, 'verifyingSigner')) !== lower(vSigner.address)) throw Error('VPM signer patch failed');
out.forkSubstitutions.push({ kind: 'VPM.verifyingSigner immutable', address: VPM, occurrences: hits, codeHashBefore,
  codeHashAfter: keccak256(await rpc('eth_getCode', [VPM, 'latest'])), forkSigner: vSigner.address });

const bundler = getAddress(plan0.externalInputs.data.phaseC.bundler);
await rpc('anvil_impersonateAccount', [bundler]);
const operator = getAddress(plan0.deploymentContext.operator);

function frames(root) {
  const list = [];
  const walk = (f, parent) => { list.push({ ...f, parent }); for (const c of f.calls || []) walk(c, f); };
  walk(root, null);
  return list;
}

const senders = Object.keys(bundle.plans);
for (let si = 0; si < senders.length; si++) {
  const key = senders[si];
  const fp = createFrozenPlan({ readBundle: () => bytes, bundleSha256, account: key });
  const plan = fp.plan, pc = plan.phaseC, frozen = fp.frozen;
  const S = getAddress(pc.addresses.S);
  const O = getAddress(plan.externalInputs.data.phaseC.accountOwner);
  const owner = privateKeyToAccount(forkKey(`owner-${si}`));
  const slot0 = await rpc('eth_getStorageAt', [S, '0x0', 'latest']);
  if (lower('0x' + slot0.slice(-40)) !== lower(O)) throw Error(`S ${S} owner slot 0 is not O`);
  await rpc('anvil_setStorageAt', [S, '0x0', pad(owner.address, { size: 32 })]);
  if (lower(await call(S, OWNER_ABI, 'owner')) !== lower(owner.address)) throw Error('owner substitution failed');
  out.forkSubstitutions.push({ kind: 'SimpleAccount owner slot 0', account: S, realOwner: O, forkOwner: owner.address });
  const pms = { SP, VPM, TPM };
  // Round -1 is the warm-up pass: one op per arm at the frozen bounds, SP first, so every
  // measurement round runs at EntryPoint nonce >= 1 (the nonce 0->1 SSTORE is only covered by
  // SP's verificationGasLimit). Warm-up rows are recorded for audit but carry no minima.
  for (let round = -1; round < req.rounds; round++) {
    const warmup = round === -1;
    for (const arm of ['SP', 'VPM', 'TPM']) {
      if (arm === 'SP' && round >= 0) {
        const b = await rpc('eth_getBlockByNumber', ['latest', false]);
        await rpc('evm_mine', [Number(BigInt(b.timestamp) + BigInt(pc.minTxInterval) + 1n)]);
      }
      const GAS = { ...frozen.gas[arm] }, PM_GAS = { ...frozen.pmGas[arm] }, callData = frozen.callData, pmAddr = pms[arm];
      const nonce = (await call(EP, EP_ABI, 'getNonce', [S, 0n]));
      // collector.mjs:347-362 pmDataFor
      const pmDataFor = async () => {
        if (arm === 'SP') return concat([operator, pad(toHex((1n << 256n) - 1n), { size: 32 }), X, '0x00']);
        if (arm === 'VPM') {
          const validUntil = 0n, validAfter = 0n;
          const partial = { sender: S, nonce, initCode: '0x', callData,
            accountGasLimits: concat([u128(GAS.verificationGasLimit), u128(GAS.callGasLimit)]),
            preVerificationGas: GAS.preVerificationGas, gasFees: concat([u128(GAS.maxPriorityFeePerGas), u128(GAS.maxFeePerGas)]),
            paymasterAndData: concat([VPM, u128(PM_GAS.ver), u128(PM_GAS.post)]), signature: '0x' };
          const h = await call(VPM, VPM_ABI, 'getHash', [partial, validUntil, validAfter]);
          const sig = await vSigner.signMessage({ message: { raw: h } });
          return concat([encodeAbiParameters([{ type: 'uint48' }, { type: 'uint48' }], [validUntil, validAfter]), sig]);
        }
        return '0x';
      };
      // collector.mjs:329-345 signAndHash
      const sign = async value => {
        GAS.preVerificationGas = value;
        const packed = { sender: S, nonce, initCode: '0x', callData,
          accountGasLimits: concat([u128(GAS.verificationGasLimit), u128(GAS.callGasLimit)]),
          preVerificationGas: GAS.preVerificationGas,
          gasFees: concat([u128(GAS.maxPriorityFeePerGas), u128(GAS.maxFeePerGas)]),
          paymasterAndData: concat([pmAddr, u128(PM_GAS.ver), u128(PM_GAS.post), await pmDataFor()]), signature: '0x' };
        const epHash = await call(EP, EP_ABI, 'getUserOpHash', [packed]);
        if (lower(epHash) !== lower(localUserOpHash(packed, EP, chain))) throw Error('HASH_SELF_CHECK');
        packed.signature = await owner.signMessage({ message: { raw: epHash } });
        return { packed, hash: epHash };
      };
      let ours, pvgNote = null;
      try { ours = await finalizePVG(sign, bundler, { lengths: pc.pvgLengths[arm], reserve: pc.pvgReserve[arm] }); }
      catch (error) {
        if (error.message !== 'PVG_SIGNED_FIXED_POINT') throw error;
        // The collector STOPs here (pvg.mjs finalizePVG). Signatures are deterministic (RFC 6979), so replay the
        // same iteration to record the cycle, then (calibration only) sign at the cycle maximum and continue:
        // Measurements are conditional on the PVG used: it affects prefund/reservation,
        // postOp settlement cost/branches, and outer calldata gas. Verify the final frozen op.
        const sequence = []; let value = 0n;
        for (let i = 0; i < 64; i++) {
          const r = await sign(value); const pvg = measurePVG(r.packed, bundler);
          sequence.push(String(value)); if (sequence.slice(0, -1).includes(String(pvg.value))) { sequence.push(String(pvg.value)); break; }
          value = pvg.value;
        }
        const top = sequence.map(BigInt).reduce((x, y) => x > y ? x : y);
        const r = await sign(top); checkPVGLengths(r.packed, pc.pvgLengths[arm]);
        ours = { ...r, pvg: measurePVG(r.packed, bundler) };
        pvgNote = { collectorResult: 'PVG_SIGNED_FIXED_POINT (collector would STOP before sending)', sequence, usedForCalibration: String(top),
          ruleValueAtUsed: String(ours.pvg.value) };
      }
      let minima = null;
      if (req.search && !warmup) {
        // EntryPoint v0.7 charges more against each limit than the callee frame uses (e.g. AA26 counts the nonce
        // update and prefund bookkeeping, EntryPoint.sol _validatePrepayment). Measure each limit as EntryPoint
        // enforces it: the smallest value for which this exact op (re-signed per candidate) still succeeds,
        // each candidate sent inside evm_snapshot / evm_revert, others held at their generous plan values.
        const base = { verification: GAS.verificationGasLimit, call: GAS.callGasLimit, paymasterVerification: PM_GAS.ver, postOp: PM_GAS.post };
        const pvgFixed = ours.pvg.value;
        const apply = lim => { GAS.verificationGasLimit = lim.verification; GAS.callGasLimit = lim.call; PM_GAS.ver = lim.paymasterVerification; PM_GAS.post = lim.postOp; };
        const trial = async (lim, outerGas) => {
          apply(lim); const r = await sign(pvgFixed); apply(base);
          const snap = await rpc('evm_snapshot');
          try {
            await pinNextTimestamp();
            const h = await rpc('eth_sendTransaction', [{ from: bundler, to: EP, gas: toHex(outerGas),
              data: encodeFunctionData({ abi: EP_ABI, functionName: 'handleOps', args: [[r.packed], bundler] }),
              maxFeePerGas: toHex(frozen.fees.maxFeePerGas), maxPriorityFeePerGas: toHex(frozen.fees.maxPriorityFeePerGas) }]);
            let rc = null; for (let i = 0; i < 50 && !rc; i++) rc = await rpc('eth_getTransactionReceipt', [h]);
            const lg = rc.logs.map(l => ({ ...l, address: getAddress(l.address), logIndex: Number(l.logIndex) }));
            const c = classifyAttempt({ sent: true, txStatus: rc.status === '0x1' ? 'success' : 'reverted', logs: lg, entryPoint: EP,
              expectedHash: r.hash, sender: S, nonce, paymaster: pmAddr });
            const ok = rc.status === '0x1' && c.verdict === VERDICTS.USEROP_SUCCESS;
            let reason = null;
            if (!ok) {
              const t = await rpc('debug_traceTransaction', [h, { tracer: 'callTracer' }]);
              reason = { verdict: c.verdict, failingCheck: c.failingCheck ?? null, output: (t.output || '').slice(0, 400), error: t.error ? redact(t.error, true) : null };
            }
            return { ok, gasUsed: BigInt(rc.gasUsed), reason };
          } catch (error) { return { ok: false, reason: redact(error.message, true) }; }
          finally { if (await rpc('evm_revert', [snap]) !== true) throw Error('evm_revert failed'); }
        };
        const generousOuter = BigInt(pc.bounds[arm].outer);
        const least = async (test, lo, hi, label) => {
          const top = await test(hi, true);
          if (!top.ok) throw Error(`search upper bound fails for ${arm} ${label}: ${JSON.stringify(top.reason)}`);
          while (lo < hi) { const mid = (lo + hi) / 2n; if ((await test(mid)).ok) hi = mid; else lo = mid + 1n; }
          return hi;
        };
        minima = {};
        for (const field of ['verification', 'paymasterVerification', 'call', 'postOp']) {
          if (field === 'postOp' && arm === 'VPM') { minima.postOp = 0n; continue; }
          minima[field] = await least(v => trial({ ...base, [field]: v }, generousOuter), 1n, base[field], field);
        }
        const scaled = v => (v * BigInt(req.gasFactor.numerator) + BigInt(req.gasFactor.denominator) - 1n) / BigInt(req.gasFactor.denominator);
        const frozenLike = { verification: scaled(minima.verification), call: scaled(minima.call),
          paymasterVerification: scaled(minima.paymasterVerification),
          postOp: arm === 'VPM' ? 0n : arm === 'SP' ? (scaled(minima.postOp) > BigInt(req.spPostOpFloor) ? scaled(minima.postOp) : BigInt(req.spPostOpFloor)) : scaled(minima.postOp) };
        minima.outer = await least(v => trial(frozenLike, v), 21000n, generousOuter, 'outer');
        minima.outerWithLimits = Object.fromEntries(Object.entries(frozenLike).map(([k, v]) => [k, String(v)]));
        minima.gasUsedAtMinimalLimits = String((await trial(frozenLike, generousOuter)).gasUsed);
        apply(base);
      }
      const data = encodeFunctionData({ abi: EP_ABI, functionName: 'handleOps', args: [[ours.packed], bundler] });
      const outerLimit = BigInt(pc.bounds[arm].outer);
      const row = { sender: S, arm, round, warmup, planIndex: Number(plan.planIndex), userOpHash: ours.hash, nonce: String(nonce), pvgNote,
        minima: minima && Object.fromEntries(Object.entries(minima).map(([k, v]) => [k, typeof v === 'bigint' ? Number(v) : v])),
        limits: { call: String(GAS.callGasLimit), verification: String(GAS.verificationGasLimit), paymasterVerification: String(PM_GAS.ver),
          postOp: String(PM_GAS.post), outer: String(outerLimit), preVerification: String(ours.pvg.value) } };
      let txHash;
      try {
        await pinNextTimestamp();
        txHash = await rpc('eth_sendTransaction', [{ from: bundler, to: EP, data, gas: toHex(outerLimit),
          maxFeePerGas: toHex(frozen.fees.maxFeePerGas), maxPriorityFeePerGas: toHex(frozen.fees.maxPriorityFeePerGas) }]);
      } catch (error) {
        row.sendError = redact(error.message, true); row.verdict = 'SEND_REJECTED';
        out.ops.push(row); continue;
      }
      let receipt = null;
      for (let i = 0; i < 50 && !receipt; i++) receipt = await rpc('eth_getTransactionReceipt', [txHash]);
      row.tx = { hash: txHash, blockNumber: String(BigInt(receipt.blockNumber)), blockHash: receipt.blockHash, status: receipt.status, gasUsed: String(BigInt(receipt.gasUsed)) };
      const logs = receipt.logs.map(l => ({ ...l, address: getAddress(l.address), logIndex: Number(l.logIndex) }));
      const cls = classifyAttempt({ sent: true, txStatus: receipt.status === '0x1' ? 'success' : 'reverted', logs, entryPoint: EP,
        expectedHash: ours.hash, sender: S, nonce, paymaster: pmAddr });
      row.verdict = cls.verdict; row.failingCheck = cls.failingCheck ?? null;
      if (arm === 'SP' && receipt.status === '0x1') {
        try { row.spBranch = settlementBranch(logs, { token: X, user: S, hash: ours.hash, planned: pc.spBranch,
          topics: Object.fromEntries(Object.entries(settlementSignatures).map(([k, v]) => [k, keccak256(toHex(v))])) }); }
        catch (error) { row.spBranch = error.branch; }
      }
      const trace = await rpc('debug_traceTransaction', [txHash, { tracer: 'callTracer' }]);
      const fs = frames(trace);
      const pick = (pred, label) => {
        const hit = fs.filter(pred);
        if (hit.length > 1) throw Error(`ambiguous ${label} frame`);
        return hit[0] ? { gasUsed: String(BigInt(hit[0].gasUsed)), gas: String(BigInt(hit[0].gas)), error: hit[0].error ? redact(hit[0].error, true) : null } : null;
      };
      const fromEP = f => lower(f.from) === lower(EP);
      const inner = f => f.parent && lower(f.parent.input || '').startsWith(SEL.innerHandleOp);
      row.frames = {
        verification: pick(f => fromEP(f) && lower(f.to) === lower(S) && lower(f.input).startsWith(SEL.validateUserOp), 'validateUserOp'),
        paymasterVerification: pick(f => fromEP(f) && lower(f.to) === lower(pmAddr) && lower(f.input).startsWith(SEL.validatePaymasterUserOp), 'validatePaymasterUserOp'),
        call: pick(f => fromEP(f) && inner(f) && lower(f.to) === lower(S) && lower(f.input) === lower(callData), 'execute'),
        postOp: pick(f => fromEP(f) && lower(f.to) === lower(pmAddr) && lower(f.input).startsWith(SEL.postOp), 'postOp'),
      };
      row.traceError = trace.error ? redact(trace.error, true) : null;
      if (receipt.status !== '0x1') {
        row.revertData = trace.output ?? null;
        try {
          const { decodeErrorResult } = await import('viem');
          const ERR = parseAbi(['error FailedOp(uint256 opIndex, string reason)', 'error FailedOpWithRevert(uint256 opIndex, string reason, bytes inner)']);
          const decoded = decodeErrorResult({ abi: ERR, data: trace.output });
          row.revertReason = { error: decoded.errorName, args: decoded.args.map(String) };
        } catch { row.revertReason = null; }
      }
      row.uoe = cls.event ? { success: cls.event.success, actualGasUsed: String(cls.event.actualGasUsed), actualGasCost: String(cls.event.actualGasCost) } : null;
      row.measurement = !warmup && row.verdict === VERDICTS.USEROP_SUCCESS ? {
        call: Number(row.frames.call.gasUsed), verification: Number(row.frames.verification.gasUsed),
        paymasterVerification: Number(row.frames.paymasterVerification.gasUsed),
        postOp: row.frames.postOp ? Number(row.frames.postOp.gasUsed) : 0, outer: Number(row.tx.gasUsed) } : null;
      out.ops.push(row);
    }
  }
}
writeFileSync(req.out, JSON.stringify(out, (_, v) => typeof v === 'bigint' ? v.toString() : typeof v === 'string' ? redact(v) : v, 2) + '\n');
console.log(redact(JSON.stringify(out.ops.map(r => [r.arm, r.sender.slice(0, 8), r.round, r.verdict, r.failingCheck, r.measurement, r.minima]))));
