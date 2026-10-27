#!/usr/bin/env node
// Export one a6-gauge/1 collector run (JSONL) as a DSR `aoa-m3-receive-v1` package (CC-127 / AOA-SP-02 item 2).
//
//   node script/a6-collector/to-aoa-m3-receive.mjs <run.jsonl> <out-dir> [--window-id <id>]
//
// The collector JSONL stays the primary record; the package is a view of it plus the raw per-attempt files the
// DSR checker (scripts/aoa_m3_check.py, DSR repo) hashes. Nothing is read from a chain: every value comes from
// the archive. Before writing anything this script requires validate.mjs to report the run `consistent`, then
// decodes each attempt's UserOperationEvent from its own receipt logs (not from the collector's summary) and
// refuses the run if the two disagree. It never upgrades an attempt: an attempt is `included` only if the
// collector's verdict is USEROP_SUCCESS, it is not a fixture or excluded row, the receipt succeeded, the decoded
// UOE says success, SP/VPM/TPM conservation was evaluated and held, and its triplet was matched. Everything else
// is listed with its exclusion reason, so no attempt is dropped.
//
// runType is `rehearsal` unless the run is protocolConformant; this view never makes a run formal.
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
// keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)"), EntryPoint v0.7.
export const UOE_TOPIC = '0x49628fd1471006c1482da88028e9ce4dbb080b815c9b0344d39e5a8e6ec1419f';
const KIND = { SP: 'SP', VPM: 'VerifyingPaymaster', TPM: 'TokenPaymaster' };
const RUNTIME = { SP: 'superPaymasterImpl', VPM: 'verifyingPaymaster', TPM: 'tokenPaymaster' };
const EXECUTE = '0xb61d27f6'; // SimpleAccount execute(address,uint256,bytes)
const HEX32 = /^0x[0-9a-fA-F]{64}$/;

export class ExportError extends Error {}
const fail = (msg) => { throw new ExportError(msg); };
const sha256 = (buf) => createHash('sha256').update(buf).digest('hex');
// Canonical JSON: sorted keys at every level, so a hash names content, not key order.
export const canon = (v) => Array.isArray(v) ? `[${v.map(canon).join(',')}]`
  : v && typeof v === 'object' ? `{${Object.keys(v).sort().map((k) => `${JSON.stringify(k)}:${canon(v[k])}`).join(',')}}`
  : JSON.stringify(v);
const hashOf = (v) => '0x' + sha256(canon(v));
const word = (data, i) => data.slice(2 + 64 * i, 2 + 64 * (i + 1));
const dec = (hexWord) => BigInt('0x' + hexWord).toString();
const DECIMAL = /^(0|[1-9][0-9]*)$/;
const num = (v, what) => (typeof v === 'string' && DECIMAL.test(v)) ? BigInt(v) : fail(`${what} is not a decimal string`);

// EntryPoint v0.7 charges actualGasCost = actualGasUsed * min(maxFeePerGas, basefee + maxPriorityFeePerGas).
// The basefee is not in the row, so the check is: cost is an exact multiple of a positive gasUsed, the per-gas price
// is at most maxFeePerGas, and it implies a basefee in [0, the bundle tx's effective price] (when capped at maxFee:
// a basefee of at least maxFee - priority, so maxFee <= priority + that price).
export function gasConsistent(uoe, gas, txEffectivePrice) {
  const cost = BigInt(uoe.actualGasCost), used = BigInt(uoe.actualGasUsed);
  const maxFee = num(gas.maxFeePerGas, 'maxFeePerGas'), prio = num(gas.maxPriorityFeePerGas, 'maxPriorityFeePerGas');
  if (used <= 0n || cost % used !== 0n) return false;
  const price = cost / used;
  if (price > maxFee) return false;
  // Capped at maxFee needs basefee + priority >= maxFee, and basefee <= the bundle tx's effective price.
  if (price === maxFee) return maxFee <= prio + txEffectivePrice;
  const basefee = price - prio;
  return basefee >= 0n && basefee <= txEffectivePrice;
}

export function decodeUoe(logs, entryPoint, userOpHash) {
  const hits = logs.filter((l) => l.address.toLowerCase() === entryPoint.toLowerCase()
    && (l.topics[0] || '').toLowerCase() === UOE_TOPIC && (l.topics[1] || '').toLowerCase() === userOpHash.toLowerCase());
  if (hits.length !== 1) return { count: hits.length };
  const l = hits[0];
  if (l.topics.length !== 4 || !/^0x[0-9a-fA-F]{256}$/.test(l.data)) fail(`malformed UserOperationEvent at logIndex ${l.logIndex}`);
  // Indexed addresses are canonical only with 12 zero bytes of padding.
  for (const i of [2, 3]) if (!/^0x0{24}[0-9a-fA-F]{40}$/.test(l.topics[i])) fail(`non-canonical address topic ${i} at logIndex ${l.logIndex}`);
  const flag = word(l.data, 1);
  if (!/^0{63}[01]$/.test(flag)) fail(`non-boolean success word at logIndex ${l.logIndex}`);
  return {
    count: 1, logIndex: l.logIndex, userOpHash: l.topics[1].toLowerCase(),
    sender: '0x' + l.topics[2].slice(26).toLowerCase(), paymaster: '0x' + l.topics[3].slice(26).toLowerCase(),
    nonce: dec(word(l.data, 0)), success: flag.endsWith('1'),
    actualGasCost: dec(word(l.data, 2)), actualGasUsed: dec(word(l.data, 3)),
  };
}

function target(callData) {
  if (!callData.toLowerCase().startsWith(EXECUTE) || callData.length < 10 + 64) fail('callData is not execute(address,uint256,bytes)');
  return '0x' + callData.slice(10 + 24, 10 + 64).toLowerCase();
}

export function exportRun(jsonlPath, outDir, { windowId, validate = true } = {}) {
  const raw = readFileSync(jsonlPath, 'utf8');
  const rows = raw.split('\n').filter(Boolean).map((l) => JSON.parse(l));
  const starts = rows.filter((r) => r.kind === 'run_start'), ends = rows.filter((r) => r.kind === 'run_end');
  if (starts.length !== 1 || ends.length !== 1) fail('need exactly one run_start and one run_end');
  const [start, end] = [starts[0], ends[0]];
  if (rows.some((r) => r.schema !== 'a6-gauge/1' || r.runId !== start.runId)) fail('mixed schema or runId');
  if (!start.passport || !end.passport) fail('run has no start/end passport (stopped before read-back)');
  if (validate) {
    const scratch = mkdtempSync(join(tmpdir(), 'aoa-m3-validate-'));
    const reportPath = join(scratch, 'report.json');
    let report;
    try {
      try {
        execFileSync('node', [join(HERE, 'validate.mjs'), jsonlPath, '--json', reportPath], { stdio: 'ignore' });
      } catch (e) {
        // 3 = consistent, not accepted. Anything else (1 inconsistent, 2 missing field, or validate.mjs itself
        // could not run, e.g. without node_modules) refuses the export.
        if (e.status !== 3) fail(`validate.mjs exit ${e.status}: run not shown consistent (inconsistent, or validator did not run)`);
      }
      report = JSON.parse(readFileSync(reportPath, 'utf8'));
    } finally {
      rmSync(scratch, { recursive: true, force: true });
    }
    if (report.consistent !== true) fail('validate.mjs: run is not consistent');
  }
  const inv = start.passport.invariant;
  if (canon(inv) !== canon(end.passport.invariant)) fail('passport invariant drifted between run_start and run_end');
  if (start.passport.chainId !== end.passport.chainId) fail('passport chainId drifted');
  const matched = new Set((end.triplets || []).filter((t) => t.matched).map((t) => t.tripletIndex));
  // Two kinds of control field. Per-arm ones are derived from each attempt's own data, so the checker's
  // per-group equality is a real test of the arms (entryPoint, target, calldataHash, accountImplementation,
  // bundlerConfigHash). Run-level ones (tokenStateProtocol, windowId, samplingProtocolHash) name the run's
  // procedure and are equal by construction: the checker's equality says nothing about them.
  const runControls = {
    tokenStateProtocol: hashOf({ setupLog: start.setupLog, xPNTs: inv.xPNTs }),
    windowId: windowId || start.runId,
    samplingProtocolHash: hashOf({ argv: start.argv, count: start.count, bMax: start.bMax, maxAttempts: start.maxAttempts,
      arms: start.arms, head: start.head, codeSha256: start.codeSha256 }),
  };
  const accountImpl = (r) => {
    // The account is resolved from the attempt's sender against the passport's code inventory.
    if (String(r.sender).toLowerCase() !== inv.code.account.address.toLowerCase()) fail(`attempt ${r.arm}/${r.attemptIndex}: sender is not the passport account`);
    return `${r.sender.toLowerCase()}->${inv.code.accountImpl.address.toLowerCase()}@${inv.code.accountImpl.codehash}`;
  };
  // Bundler-side configuration shared by all arms: who bundles, who receives, and the op's own gas limits and
  // fee caps. Paymaster gas limits (pmGas) differ by design between SP, VPM and TPM, so they are a recorded
  // necessary difference (pmGas on each row), not part of this hash.
  const bundlerConfig = (r) => hashOf({ bundler: String(r.bundler).toLowerCase(), txFrom: String(r.tx.from).toLowerCase(),
    beneficiary: String(inv.beneficiary).toLowerCase(), opGas: r.gas });
  const files = {}, attempts = [];
  const put = (name, value) => {
    const body = typeof value === 'string' ? value : JSON.stringify(value, null, 1) + '\n';
    writeFileSync(join(outDir, name), body);
    files[name] = sha256(body);
    return name;
  };
  mkdirSync(join(outDir, 'raw'), { recursive: true });
  put('raw/collector.jsonl', raw);
  const passportFile = put('raw/passport.json', { start: start.passport, end: end.passport });
  for (const r of rows.filter((x) => x.kind === 'attempt')) {
    const id = `${start.runId}/${r.arm}/${r.attemptIndex}`;
    const base = `raw/${r.arm}-${r.attemptIndex}`;
    const row = { attemptId: id, paymasterKind: KIND[r.arm] || fail(`unknown arm ${r.arm}`), included: false };
    const reasons = [];
    if (r.verdict !== 'USEROP_SUCCESS') reasons.push(`VERDICT:${r.verdict}`);
    if (r.fixture != null) reasons.push(`FIXTURE:${JSON.stringify(r.fixture)}`);
    if (r.exclusion) reasons.push(`COLLECTOR:${r.exclusion}`);
    let uoe = null;
    if (r.sent && r.tx) {
      put(`${base}.receipt.json`, { tx: r.tx, logs: r.logs });
      uoe = decodeUoe(r.logs, r.entryPoint, r.expectedUserOpHash);
      put(`${base}.uoe.json`, uoe);
      put(`${base}.state.json`, { readbacks: r.readbacks, conservation: r.conservation, spMode: r.spMode ?? null, charge: r.charge ?? null });
      if (r.verdict === 'USEROP_SUCCESS') {
        // The collector says success: its own logs must say exactly the same, or the archive is refused.
        if (uoe.count !== 1) fail(`${id}: verdict USEROP_SUCCESS but ${uoe.count} matching UserOperationEvent logs`);
        const e = r.userOpEvent || {};
        const same = uoe.success === e.success && uoe.actualGasCost === String(e.actualGasCost)
          && uoe.actualGasUsed === String(e.actualGasUsed) && uoe.userOpHash === String(e.userOpHash).toLowerCase()
          && uoe.nonce === String(e.nonce) && uoe.nonce === String(r.nonce)
          && uoe.sender === String(e.sender).toLowerCase() && uoe.sender === String(r.sender).toLowerCase()
          && uoe.paymaster === String(e.paymaster).toLowerCase() && uoe.paymaster === String(r.paymaster).toLowerCase();
        if (!same) fail(`${id}: decoded UserOperationEvent disagrees with the collector's record`);
      }
      if (r.tx.status !== 'success') reasons.push('RECEIPT_FAILED');
      const txGasUsed = num(r.tx.gasUsed, `${id}: tx.gasUsed`), txPrice = num(r.tx.effectiveGasPrice, `${id}: tx.effectiveGasPrice`);
      const txGasLimit = num(r.tx.gasLimit, `${id}: tx.gasLimit`);
      if (txGasUsed <= 0n || txGasUsed > txGasLimit) fail(`${id}: tx.gasUsed must be positive and at most tx.gasLimit`);
      // Only a successful UOE must satisfy cost = used x price: when prefund falls short, EntryPoint v0.7 emits
      // success=false with actualGasCost = the prefund (singleton-paymaster/lib/account-abstraction-v7/contracts/
      // core/EntryPoint.sol:127-133 and :732-737), which need not divide. Such an attempt is excluded
      // (UOE_FAILED) rather than refusing the whole run.
      if (uoe.count === 1 && uoe.success && !gasConsistent(uoe, r.gas, txPrice)) fail(`${id}: actualGasCost/actualGasUsed inconsistent with the op's fee caps and the bundle tx price`);
      if (uoe.count === 1 && !uoe.success) reasons.push('UOE_FAILED');
      if (!(r.conservation && r.conservation.evaluated && r.conservation.ok)) reasons.push('CONSERVATION_NOT_VERIFIED');
    } else {
      reasons.push('NOT_SENT');
    }
    if (!matched.has(r.tripletIndex)) reasons.push('TRIPLET_INCOMPLETE');
    if (reasons.length) { attempts.push({ ...row, exclusionReason: reasons.join(';') }); continue; }
    const code = inv.code[RUNTIME[r.arm]];
    if (!code || !HEX32.test(code.codehash)) fail(`${id}: no runtime codehash for ${r.arm}`);
    if (!HEX32.test(r.tx.hash) || !HEX32.test(r.tx.blockHash)) fail(`${id}: malformed tx/block hash`);
    attempts.push({
      ...row, included: true, pairId: `${start.runId}/${r.tripletIndex}`, chainId: r.chainId,
      txHash: r.tx.hash, userOpHash: uoe.userOpHash, blockHash: r.tx.blockHash, runtimeCodeHash: code.codehash,
      receiptStatus: 1, userOpSuccess: true, settlementVerified: true,
      actualGasUsed: uoe.actualGasUsed, actualGasCostWei: uoe.actualGasCost,
      txGasUsed: num(r.tx.gasUsed, 'tx.gasUsed').toString(), effectiveGasPriceWei: num(r.tx.effectiveGasPrice, 'tx.effectiveGasPrice').toString(),
      receiptFile: `${base}.receipt.json`, uoeFile: `${base}.uoe.json`, passportFile, stateFile: `${base}.state.json`,
      entryPoint: r.entryPoint.toLowerCase(), target: target(r.packedOp.callData), calldataHash: r.callDataHash.toLowerCase(),
      accountImplementation: accountImpl(r), bundlerConfigHash: bundlerConfig(r), ...runControls,
      paymasterGas: r.pmGas, injectedScenario: null,
    });
  }
  const pkg = {
    schema: 'aoa-m3-receive-v1', runType: start.protocolConformant ? 'formal-candidate' : 'rehearsal',
    source: { runId: start.runId, collectorHead: start.head, collectorDirty: start.collectorDirty,
      jsonlSha256: sha256(raw), stop: end.stop, protocolConformant: start.protocolConformant,
      allowSameEndpointLocal: start.allowSameEndpointLocal },
    files, attempts,
  };
  writeFileSync(join(outDir, 'receive.json'), JSON.stringify(pkg, null, 1) + '\n');
  return pkg;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [jsonl, out, ...rest] = process.argv.slice(2);
  const w = rest.indexOf('--window-id');
  if (!jsonl || !out) { console.error('usage: to-aoa-m3-receive.mjs <run.jsonl> <out-dir> [--window-id <id>]'); process.exit(2); }
  try {
    if (existsSync(out) && readdirSync(out).length) fail(`output directory not empty: ${out}`);
    mkdirSync(out, { recursive: true });
    const pkg = exportRun(jsonl, out, { windowId: w >= 0 ? rest[w + 1] : undefined });
    const inc = pkg.attempts.filter((a) => a.included).length;
    console.log(JSON.stringify({ runType: pkg.runType, attempts: pkg.attempts.length, included: inc, files: Object.keys(pkg.files).length }));
  } catch (e) {
    console.error(`EXPORT REFUSED: ${e instanceof ExportError ? e.message : e.stack}`);
    process.exit(1);
  }
}
