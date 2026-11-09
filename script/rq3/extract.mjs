// Offline archive extraction. No clients, transport, signer, or chain calls.
import { decodeAbiParameters, decodeEventLog, decodeFunctionData, parseAbi, toFunctionSelector } from 'viem';
import { readFileSync, writeFileSync } from 'node:fs';
import { pathToFileURL } from 'node:url';
import { dualRead, checkRuntime, check, invertPenalty, receiptReady } from './evidence.mjs';
export { invertPenalty } from './evidence.mjs';
import { EP_EVENTS_ABI, SP_EVENTS_ABI } from '../a6-collector/gauge-lib.mjs';

export const POSTOP_ABI = parseAbi(['function postOp(uint8 mode, bytes context, uint256 actualGasCost, uint256 actualUserOpFeePerGas)']);
export const TASK_ABI = parseAbi(['function execute(address dest, uint256 value, bytes func)', 'function transfer(address to, uint256 amount) returns (bool)', 'event Transfer(address indexed from, address indexed to, uint256 value)']);
export const LOCK_ABI = parseAbi(['event LockCreated(address indexed user, bytes32 indexed opHash, address indexed locker, uint256 xLocked, uint256 aReserved)', 'event LockSettled(address indexed user, bytes32 indexed opHash, uint256 xBurned, uint256 aCharged)']);
export const TPM_ABI = parseAbi(['event UserOperationSponsored(address indexed user, uint256 actualTokenCharge, uint256 actualGasCost, uint256 actualTokenPriceWithMarkup)']);
const POSTOP = toFunctionSelector('postOp(uint8,bytes,uint256,uint256)');
const INNER = '0x0042dc53';
const lower = v => String(v).toLowerCase();
const eq = (a, b) => lower(a) === lower(b);
// Every data check classifies: a failed binding/settlement check is a collector_corruption row,
// never an aborted extraction (DSR ruling 6). Programming errors still throw plain Errors.
const requireValue = (condition, reason) => check(condition, reason);
const ceil = (n, d) => (n + d - 1n) / d;
export const json = value => JSON.stringify(value, (_, v) => typeof v === 'bigint' ? v.toString() : v, 2);

export function spFormula(context, cPreWei, pOp) {
  // 8de39026 SuperPaymaster.sol:40-86,393-434. Do not use current config
  // for snapshot contexts. Formal windows stop on legacy fee contexts.
  const length = (context.length - 2) / 2;
  requireValue([352, 384].includes(length), 'invalid context length');
  const types = ['address', 'address', 'uint256', 'bytes32', 'address', 'uint8',
    'uint128', 'uint128', 'int256', 'uint8', 'uint256', ...(length === 384 ? ['uint256'] : [])];
  const c = decodeAbiParameters(types.map(type => ({ type })), context);
  const [token, user, a0, opHash, operator, mode, call, post, price, decimals, aPriceUSD] = c;
  requireValue(price > 0n && aPriceUSD > 0n, 'invalid price');
  const snap = length === 384 ? c[11] : 0n;
  const feeSnap = snap >> 128n;
  if (feeSnap === 0n) {
    const error = new Error('window_stop: legacy_sp_context');
    error.stop_reason = 'legacy_sp_context';
    throw error;
  }
  const feeBps = feeSnap - 1n;
  const wrap = (snap >> 64n) & 0xffffffffn;
  const postop = (snap >> 96n) & 0xffffffffn;
  const bufGas = wrap + postop;
  const bufWei = (bufGas + ceil((call + post) * 10n, 100n)) * BigInt(pOp);
  const num = price * 10n ** 18n, den = 10n ** BigInt(decimals) * aPriceUSD;
  const aGas = ceil((BigInt(cPreWei) + bufWei) * num, den);
  const hat = ceil(aGas * (10000n + feeBps), 10000n);
  return { contextLength: length, token, user, opHash, operator, mode, a0APNTs: a0,
    callGasLimit: call, paymasterPostOpGasLimit: post, price, decimals, aPriceUSD,
    feeSnap, feeBps, C_POSTOP: postop, C_WRAP: wrap,
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

function extractChecked(archive) {
  // Metadata is caller-owned; measured fields are always reset, never accepted
  // from a previous summary. Preserve raw archive separately alongside CSV.
  const { metadata, operation: op, receipt, trace, state = {} } = archive;
  const row = { ...metadata, sender: op.sender, userOpHash: op.userOpHash,
    callGasLimit: op.callGasLimit, paymasterPostOpGasLimit: op.paymasterPostOpGasLimit,
    preVerificationGas: op.preVerificationGas, success: false,
    txGasUsed: null, actualGasUsed: null, actualGasCostWei: null, l1FeeWei: null,
    unusedGasPenaltyMin: null, unusedGasPenaltyMax: null, gasBeforePenaltyCandidates: null,
    gasBeforePenalty: null, preOpGas: null, cPreWei: null, actualUserOpFeePerGas: null,
    contextLength: null, bufWei: null, gBufGas: null, bufGas: null, feeSnap: null,
    C_POSTOP: null, C_WRAP: null, price: null, decimals: null, aPriceUSD: null,
    aPNTsPerWeiNum: null, aPNTsPerWeiDen: null, feeBps: null,
    chargeAPNTs: null, chargeHatAPNTs: null, a0APNTs: null,
    refundPostopCost: null, actualTokenNeeded: null, actualTokenPriceWithMarkup: null, tokenChargeWei: null,
    tokenChargeWeiVerified: false, unverified_columns: [], stop_reason: null };
  if (metadata.precheck_refused) {
    requireValue(metadata.arm === 'SP' && !receipt && !trace && !archive.validationContext,
      'refused attempt has broadcast evidence');
    return { ...row, failure_reason: 'precheck_refused' };
  }
  if (!receipt) {
    if(metadata.failure_reason && metadata.failure_reason!=='receipt_timeout')
      return {...row,failure_reason:metadata.failure_reason};
    return {...row,...receiptReady(archive)};
  }
  if(metadata.arm==='SP' && archive.validationContext) {
    const c=archive.validationContext;
    if((c.length-2)/2===352 || ((c.length-2)/2===384 && BigInt('0x'+c.slice(-64))>>128n===0n))
      spFormula(c,0n,0n);
  }
  const receiptDecision=receiptReady(archive);
  if(receiptDecision) return {...row,...receiptDecision};
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
  const settlement = metadata.arm === 'SP' ? ['TransactionSponsored', SP_EVENTS_ABI] :
    metadata.arm === 'TokenPaymaster' ? ['UserOperationSponsored', TPM_ABI] : null;
  const sponsored = settlement ? events(receipt, op.paymaster, settlement[1])
    .filter(e => e.eventName === settlement[0]) : [];
  if (settlement) {
    requireValue(sponsored.length <= 1, 'ambiguous settlement event');
    if (sponsored.length) requireValue(eq(sponsored[0].args.user, op.sender), 'settlement operation mismatch');
    else {
      row.success = false;
      row.failure_reason = 'missing_settlement_event';
    }
  }
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
  if (metadata.arm === 'TokenPaymaster' && sponsored.length) {
    row.actualTokenNeeded = sponsored[0].args.actualTokenCharge;
    row.actualTokenPriceWithMarkup = sponsored[0].args.actualTokenPriceWithMarkup;
    check(eq(archive.baseline?.immutables?.entryPoint,op.entryPoint), 'TPM baseline EntryPoint mismatch');
    checkRuntime(archive.baseline, state.runtime, op.paymaster, receipt.blockHash);
  }
  if (!trace) {
    // Ruling 1 applies to every arm (EntryPoint.sol:720-726): a successful row needs the trace.
    check(!row.success, 'trace required to invert the penalty');
    return row;
  }
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
  if (row.success) Object.assign(row, invertPenalty(row.actualGasUsed, row.preOpGas,
    BigInt(op.callGasLimit) + BigInt(op.paymasterPostOpGasLimit)));
  const calls = frames(inner[0]).filter(f => eq(f.from, op.entryPoint) && eq(f.to, op.paymaster) && f.input?.startsWith(POSTOP));
  check(calls.length===1 || !row.success || metadata.arm==='VerifyingPaymaster', 'unique postOp call required');
  if (calls.length !== 1) return row;
  const post = calls[0];
  const [, context, cPre, pOp] = decodeFunctionData({ abi: POSTOP_ABI, data: post.input }).args;
  row.cPreWei = cPre;
  row.actualUserOpFeePerGas = pOp;
  if (archive.validationContext != null) requireValue(eq(context, archive.validationContext), 'validation/postOp context disagreement');
  if (metadata.arm === 'SP') {
    const formula = spFormula(context, cPre, pOp);
    requireValue(eq(formula.user, op.sender) && eq(formula.opHash, op.userOpHash), 'SP context operation mismatch');
    requireValue(formula.callGasLimit === BigInt(op.callGasLimit) && formula.paymasterPostOpGasLimit === BigInt(op.paymasterPostOpGasLimit), 'SP context gas mismatch');
    for (const key of Object.keys(row)) if (key in formula) row[key] = formula[key];
    if (sponsored.length) {
      requireValue(!inner[0].error && !post.error && sponsored.length === 1, 'ambiguous/reverted SP sponsorship');
      const args = sponsored[0].args;
      check(eq(args.user, op.sender) && eq(args.operator, formula.operator) && args.aPNTsCost === formula.aGas &&
        args.debtAPNTs === formula.expectedChargeAPNTs, 'SP sponsored charge mismatch');
      row.chargeAPNTs = args.debtAPNTs;
      const locks=events(receipt,formula.token,LOCK_ABI).filter(e=>
        eq(e.args.user,op.sender) && eq(e.args.opHash,op.userOpHash));
      const created=locks.filter(e=>e.eventName==='LockCreated');
      const settled=locks.filter(e=>e.eventName==='LockSettled');
      check(created.length===1 && settled.length===1, 'unique matching LockCreated/LockSettled required');
      const c=created[0].args, t=settled[0].args;
      check(eq(c.locker,op.paymaster), 'lock locker mismatch');
      const charge=args.debtAPNTs<c.aReserved?args.debtAPNTs:c.aReserved;
      let burned=c.aReserved===0n?0n:ceil(charge*c.xLocked,c.aReserved);
      if(burned>c.xLocked) burned=c.xLocked;
      check(t.aCharged===charge && t.aCharged===args.debtAPNTs, 'SP lock charge mismatch');
      check(t.xBurned===burned, 'SP lock burn mismatch');
      check(archive.receiptBlock?.hash===receipt.blockHash && archive.receiptBlock?.parentHash,
        'receipt parent block required');
      // Parent-to-block delta is attributable to this op only when it is the block's sole
      // transaction. Otherwise the check is recorded as not performed (never as corruption):
      // other transactions in the block may move the same operator's balance.
      row.reserveDeltaVerified=archive.receiptBlock.transactions?.length===1 &&
        eq(archive.receiptBlock.transactions[0],receipt.transactionHash);
      if (row.reserveDeltaVerified) {
        const before=dualRead(state.reserveBefore,op.paymaster,archive.receiptBlock.parentHash,'operators',[formula.operator]);
        const after=dualRead(state.reserveAfter,op.paymaster,receipt.blockHash,'operators',[formula.operator]);
        check(after[0]-before[0]===-args.debtAPNTs, 'SP operator reserve delta mismatch');
      }
    }
  } else if (metadata.arm === 'TokenPaymaster') {
    // Pinned TPM.sol:167-191; UniswapHelper.sol:74-79. The snapshot must
    // identify the postOp-updated price BEFORE markup, never validation price.
    if (sponsored.length) {
      requireValue(sponsored.length === 1 && !post.error && !inner[0].error, 'ambiguous/reverted TPM sponsorship');
      const args = sponsored[0].args;
      requireValue(eq(args.user, op.sender) && args.actualGasCost === cPre, 'TPM event mismatch');
      row.actualTokenNeeded = args.actualTokenCharge;
      const config=dualRead(state.config,op.paymaster,receipt.blockHash,'tokenPaymasterConfig');
      const price=dualRead(state.cachedPrice,op.paymaster,receipt.blockHash,'cachedPrice');
      const [markup,,refund]=config, unit=10n**26n, marked=args.actualTokenPriceWithMarkup;
      check(markup>=unit && markup<=2n*unit && marked>0n, 'invalid TPM price configuration');
      check((args.actualGasCost+BigInt(refund)*pOp)*unit < 2n**256n &&
        price*unit < 2n**256n, 'TPM arithmetic overflow');
      // Block-end reads equal the postOp state only when this is the block's sole transaction and
      // the op itself wrote no config. In a shared block a later transaction may move cachedPrice
      // (OracleHelper.sol:88,118-121) or the config: a mismatch there leaves the state-derived
      // columns UNVERIFIED instead of discarding a valid settlement as corruption.
      const configSetter=toFunctionSelector('setTokenPaymasterConfig((uint256,uint128,uint48,uint48))');
      const isolated=archive.receiptBlock?.hash===receipt.blockHash &&
        archive.receiptBlock.transactions?.length===1 && eq(archive.receiptBlock.transactions[0],receipt.transactionHash);
      const configWrites=all.some(f=>eq(f.to,op.paymaster) && f.input?.startsWith(configSetter));
      const exact=isolated && !configWrites;
      const chargeOk=args.actualTokenCharge===(args.actualGasCost+BigInt(refund)*pOp)*unit/marked;
      const low=ceil(marked*markup,unit), high=ceil((marked+1n)*markup,unit)-1n;
      const priceOk=price>=low && price<=high && price*unit/markup===marked;
      if (exact) {
        check(chargeOk, 'TPM token charge mismatch');
        check(priceOk, 'TPM updated price mismatch');
      }
      row.refundPostopCost=chargeOk ? BigInt(refund) : null;
      row.tokenChargeWei=priceOk ? args.actualTokenCharge*price/unit : null;
      row.tokenChargeWeiVerified=exact && priceOk && low===high;
      // The exact integer charge equation is itself the proof of refundPostopCost.
      row.unverified_columns=[...(chargeOk ? [] : ['refundPostopCost']),
        ...(row.tokenChargeWeiVerified ? [] : ['tokenChargeWei'])];
    }
  }
  return row;
}

export function extract(archive) {
  try { return extractChecked(archive); }
  catch(error) {
    if (!error.invalid_reason && !error.stop_reason) throw error;
    return {...archive.metadata, sender:archive.operation.sender, userOpHash:archive.operation.userOpHash,
      callGasLimit:archive.operation.callGasLimit, paymasterPostOpGasLimit:archive.operation.paymasterPostOpGasLimit,
      preVerificationGas:archive.operation.preVerificationGas, success:false,
      invalid_reason:error.invalid_reason || '', stop_reason:error.stop_reason || '',
      failure_reason:error.stop_reason || error.invalid_reason, diagnostic:error.message};
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const [source, target] = process.argv.slice(2);
  if (!source || !target) throw new Error('usage: node extract.mjs archives.json records.json');
  writeFileSync(target, json(JSON.parse(readFileSync(source, 'utf8')).map(extract)) + '\n');
}
