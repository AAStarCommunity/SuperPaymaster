// Offline archive extraction. No clients, transport, signer, or chain calls.
import { decodeAbiParameters, decodeEventLog, decodeFunctionData, parseAbi, toFunctionSelector } from 'viem';
import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { EP_EVENTS_ABI, SP_EVENTS_ABI } from '../a6-collector/gauge-lib.mjs';

export const POSTOP_ABI = parseAbi(['function postOp(uint8 mode, bytes context, uint256 actualGasCost, uint256 actualUserOpFeePerGas)']);
export const TASK_ABI = parseAbi(['function execute(address dest, uint256 value, bytes func)', 'function transfer(address to, uint256 amount) returns (bool)', 'event Transfer(address indexed from, address indexed to, uint256 value)']);
export const TPM_ABI = parseAbi(['event UserOperationSponsored(address indexed user, uint256 actualTokenCharge, uint256 actualGasCost, uint256 actualTokenPriceWithMarkup)']);
const POSTOP = toFunctionSelector('postOp(uint8,bytes,uint256,uint256)');
const INNER = '0x0042dc53';
const lower = v => String(v).toLowerCase();
const eq = (a, b) => lower(a) === lower(b);
const requireValue = (condition, reason) => { if (!condition) throw new Error(reason); };
const ceil = (n, d) => (n + d - 1n) / d;
export const json = value => JSON.stringify(value, (_, v) => typeof v === 'bigint' ? v.toString() : v, 2);

export function spFormula(context, cPreWei, pOp, liveFeeBps) {
  // 8de39026 SuperPaymaster.sol:40-86,393-434. Do not use current config
  // for snapshot contexts. Legacy fee is the fee live AT postOp, not validation.
  const length = (context.length - 2) / 2;
  requireValue([352, 384].includes(length), 'invalid context length');
  const types = ['address', 'address', 'uint256', 'bytes32', 'address', 'uint8',
    'uint128', 'uint128', 'int256', 'uint8', 'uint256', ...(length === 384 ? ['uint256'] : [])];
  const c = decodeAbiParameters(types.map(type => ({ type })), context);
  const [token, user, a0, opHash, operator, mode, call, post, price, decimals, aPriceUSD] = c;
  requireValue(price > 0n && aPriceUSD > 0n, 'invalid price');
  const snap = length === 384 ? c[11] : 0n;
  const feeSnap = snap >> 128n;
  requireValue(feeSnap !== 0n || liveFeeBps != null, 'postOp live fee evidence required');
  const feeBps = feeSnap === 0n ? BigInt(liveFeeBps) : feeSnap - 1n;
  const wrap = snap === 0n ? 30000n : (snap >> 64n) & 0xffffffffn;
  const postop = snap === 0n ? post : (snap >> 96n) & 0xffffffffn;
  const bufGas = wrap + postop;
  const bufWei = (bufGas + ceil((call + post) * 10n, 100n)) * BigInt(pOp);
  const num = price * 10n ** 18n, den = 10n ** BigInt(decimals) * aPriceUSD;
  const aGas = ceil((BigInt(cPreWei) + bufWei) * num, den);
  const hat = ceil(aGas * (10000n + feeBps), 10000n);
  return { contextLength: length, token, user, opHash, operator, mode, a0APNTs: a0,
    callGasLimit: call, paymasterPostOpGasLimit: post, price, decimals, aPriceUSD,
    feeSnap, feeBps, C_POSTOP: snap === 0n ? null : postop, C_WRAP: wrap,
    bufGas, gBufGas: bufGas, bufWei, aPNTsPerWeiNum: num, aPNTsPerWeiDen: den,
    aGas, chargeHatAPNTs: hat, expectedChargeAPNTs: hat < a0 ? hat : a0 };
}

function frames(root) {
  return [root, ...(root.calls ?? []).flatMap(frames)];
}
function events(receipt, address, abi) {
  return (receipt.logs ?? []).filter(l => eq(l.address, address)).flatMap(log => {
    try { return [{ ...decodeEventLog({ abi, ...log, strict: true }), logIndex: log.logIndex }]; }
    catch { return []; }
  });
}

export function extract(archive) {
  // Metadata is caller-owned; measured fields are always reset, never accepted
  // from a previous summary. Preserve raw archive separately alongside CSV.
  const { metadata, operation: op, receipt, trace, state = {} } = archive;
  const row = { ...metadata, sender: op.sender, userOpHash: op.userOpHash,
    callGasLimit: op.callGasLimit, paymasterPostOpGasLimit: op.paymasterPostOpGasLimit,
    preVerificationGas: op.preVerificationGas, success: false,
    txGasUsed: null, actualGasUsed: null, actualGasCostWei: null, l1FeeWei: null,
    gasBeforePenalty: null, preOpGas: null, cPreWei: null, actualUserOpFeePerGas: null,
    contextLength: null, bufWei: null, gBufGas: null, bufGas: null, feeSnap: null,
    C_POSTOP: null, C_WRAP: null, price: null, decimals: null, aPriceUSD: null,
    aPNTsPerWeiNum: null, aPNTsPerWeiDen: null, feeBps: null,
    chargeAPNTs: null, chargeHatAPNTs: null, a0APNTs: null,
    refundPostopCost: null, actualTokenNeeded: null, tokenChargeWei: null };
  if (metadata.precheck_refused) {
    requireValue(metadata.arm === 'SP' && !receipt && !trace && !archive.validationContext,
      'refused attempt has broadcast evidence');
    return { ...row, failure_reason: 'precheck_refused' };
  }
  if (!receipt) return { ...row, failure_reason: metadata.failure_reason || 'receipt_timeout' };
  requireValue(eq(receipt.transactionHash, archive.transactionHash), 'receipt transaction mismatch');
  row.txGasUsed = BigInt(receipt.gasUsed);
  row.l1FeeWei = receipt.l1Fee == null ? null : BigInt(receipt.l1Fee);
  const uoes = events(receipt, op.entryPoint, EP_EVENTS_ABI).filter(e => e.eventName === 'UserOperationEvent');
  requireValue(uoes.length <= 1, 'one UserOperation per transaction required');
  if (!uoes.length) return { ...row, failure_reason: 'missing_user_operation_event' };
  const uoe = uoes[0].args;
  requireValue(eq(uoe.userOpHash, op.userOpHash) && eq(uoe.sender, op.sender) &&
    eq(uoe.paymaster, op.paymaster) && uoe.nonce === BigInt(op.nonce), 'UserOperationEvent binding mismatch');
  row.success = BigInt(receipt.status) === 1n && uoe.success;
  row.failure_reason = row.success ? '' : 'user_operation_failed';
  if (row.success) {
    const task = archive.task;
    requireValue(task && BigInt(task.amount) > 0n && BigInt(task.recipientBalanceBefore) > 0n,
      'real ERC20 task with nonzero recipient balance required');
    const execution = decodeFunctionData({ abi: TASK_ABI, data: op.callData });
    requireValue(execution.functionName === 'execute' && eq(execution.args[0], task.token) &&
      execution.args[1] === 0n, 'account execution task mismatch');
    const transfer = decodeFunctionData({ abi: TASK_ABI, data: execution.args[2] });
    requireValue(transfer.functionName === 'transfer' && eq(transfer.args[0], task.recipient) &&
      transfer.args[1] === BigInt(task.amount), 'ERC20 transfer calldata mismatch');
    const transfers = events(receipt, task.token, TASK_ABI).filter(e => e.eventName === 'Transfer' &&
      eq(e.args.from, op.sender) && eq(e.args.to, task.recipient) && e.args.value === BigInt(task.amount));
    requireValue(transfers.length === 1, 'missing or ambiguous task Transfer event');
  }
  row.actualGasUsed = uoe.actualGasUsed;
  row.actualGasCostWei = uoe.actualGasCost;
  if (archive.finalTimeout) {
    // A late receipt belongs in a supplemental cost archive, never in this row.
    throw new Error('late receipt must be archived separately from final timeout row');
  }
  if (!trace) return row;
  requireValue(eq(trace.transactionHash, receipt.transactionHash) && eq(trace.blockHash, receipt.blockHash), 'trace anchor mismatch');
  requireValue(trace.tracer === 'callTracer' && eq(trace.result.to, op.entryPoint) && !trace.result.error,
    'unsupported or reverted trace root');
  const all = frames(trace.result);
  const inner = all.filter(f => eq(f.from, op.entryPoint) && eq(f.to, op.entryPoint) && f.input?.startsWith(INNER));
  requireValue(inner.length === 1, 'need unique innerHandleOp');
  const input = inner[0].input;
  const word = i => BigInt('0x' + input.slice(10 + i * 64, 10 + (i + 1) * 64));
  requireValue(input.length >= 10 + 16 * 64 && word(11) === BigInt(op.userOpHash) &&
    word(1) === BigInt(op.sender) && word(2) === BigInt(op.nonce) && word(8) === BigInt(op.paymaster) &&
    word(4) === BigInt(op.callGasLimit) && word(6) === BigInt(op.paymasterPostOpGasLimit), 'innerHandleOp binding mismatch');
  row.preOpGas = word(14); // EntryPoint.sol:318 ABI UserOpInfo.preOpGas.
  // callTracer does NOT expose actualGas at EntryPoint.sol:716. Do not invert
  // the event's penalty equation or substitute the earlier postOp argument.
  const calls = frames(inner[0]).filter(f => eq(f.from, op.entryPoint) && eq(f.to, op.paymaster) && f.input?.startsWith(POSTOP));
  if (calls.length !== 1) return row;
  const post = calls[0];
  const [, context, cPre, pOp] = decodeFunctionData({ abi: POSTOP_ABI, data: post.input }).args;
  row.cPreWei = cPre;
  row.actualUserOpFeePerGas = pOp;
  if (archive.validationContext != null) requireValue(eq(context, archive.validationContext), 'validation/postOp context disagreement');
  const requirePostOpState = () => requireValue(state.phase === 'postOp' &&
    eq(state.transactionHash, receipt.transactionHash) && eq(state.blockHash, receipt.blockHash),
    'state snapshot must be bound to this postOp transaction/block');
  if (metadata.arm === 'SP') {
    if ((context.length - 2) / 2 === 352 || BigInt('0x' + context.slice(-64)) >> 128n === 0n) requirePostOpState();
    const formula = spFormula(context, cPre, pOp, state.postOpProtocolFeeBPS);
    requireValue(eq(formula.user, op.sender) && eq(formula.opHash, op.userOpHash), 'SP context operation mismatch');
    requireValue(formula.callGasLimit === BigInt(op.callGasLimit) && formula.paymasterPostOpGasLimit === BigInt(op.paymasterPostOpGasLimit), 'SP context gas mismatch');
    for (const key of Object.keys(row)) if (key in formula) row[key] = formula[key];
    const sponsored = events(receipt, op.paymaster, SP_EVENTS_ABI).filter(e => e.eventName === 'TransactionSponsored');
    if (sponsored.length) {
      requireValue(!inner[0].error && !post.error && sponsored.length === 1, 'ambiguous/reverted SP sponsorship');
      const args = sponsored[0].args;
      requireValue(eq(args.user, op.sender) && eq(args.operator, formula.operator) && args.aPNTsCost === formula.aGas &&
        args.debtAPNTs === formula.expectedChargeAPNTs, 'SP sponsored charge mismatch');
      row.chargeAPNTs = args.debtAPNTs;
    }
  } else if (metadata.arm === 'TokenPaymaster') {
    // Pinned TPM.sol:167-191; UniswapHelper.sol:74-79. The snapshot must
    // identify the postOp-updated price BEFORE markup, never validation price.
    const sponsored = events(receipt, op.paymaster, TPM_ABI);
    if (sponsored.length) {
      requireValue(sponsored.length === 1 && !post.error && !inner[0].error, 'ambiguous/reverted TPM sponsorship');
      const args = sponsored[0].args;
      requireValue(eq(args.user, op.sender) && args.actualGasCost === cPre, 'TPM event mismatch');
      row.actualTokenNeeded = args.actualTokenCharge;
      if (state.refundPostopCost != null || state.postOpCachedPrice != null) requirePostOpState();
      if (state.refundPostopCost != null) row.refundPostopCost = BigInt(state.refundPostopCost);
      if (state.postOpCachedPrice != null && state.priceMarkup != null) {
        const price = BigInt(state.postOpCachedPrice), markup = BigInt(state.priceMarkup), unit = 10n ** 26n;
        requireValue(price > 0n && markup >= unit && markup <= 2n * unit, 'invalid TPM price configuration');
        const marked = price * unit / markup;
        requireValue(marked > 0n && marked === args.actualTokenPriceWithMarkup, 'TPM updated price mismatch');
        row.tokenChargeWei = args.actualTokenCharge * price / unit;
        if (row.refundPostopCost != null) requireValue(args.actualTokenCharge ===
          (cPre + row.refundPostopCost * pOp) * unit / marked, 'TPM token charge mismatch');
      }
    }
  }
  return row;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [source, target] = process.argv.slice(2);
  if (!source || !target) throw new Error('usage: node extract.mjs archives.json records.json');
  writeFileSync(target, json(JSON.parse(readFileSync(source, 'utf8')).map(extract)) + '\n');
}
