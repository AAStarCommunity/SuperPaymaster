import { readFileSync } from 'node:fs';
export const MAX_FEE = BigInt(JSON.parse(readFileSync(new URL('../fee-limits.json', import.meta.url))).MAX_FEE);
function integer(value) {
  if (typeof value === 'bigint') return value;
  if (typeof value === 'number' && Number.isSafeInteger(value)) return BigInt(value);
  if (typeof value === 'string' && /^\d+$/.test(value)) return BigInt(value);
  throw Error('invalid fee integer');
}
function expectedCap(baseFee, priorityFee, rule) {
  if ([rule.ceiling,rule.factor.numerator,rule.factor.denominator].some(v=>typeof v!=='bigint' && (typeof v!=='number' || !Number.isSafeInteger(v)))) throw Error('invalid fee integer');
  const base=integer(baseFee), priority=integer(priorityFee), ceiling=integer(rule.ceiling);
  const n=integer(rule.factor.numerator), d=integer(rule.factor.denominator);
  if (base<0n || priority<0n || d<=0n || n<d || ceiling<=0n || ceiling>MAX_FEE) throw Error('invalid fee rule');
  const requested=(base*n+d-1n)/d+priority;
  return requested<ceiling?requested:ceiling;
}
// Frozen derivation uses the planning base; inclusion uses the current base.
export function feesWithinRule(fees, rule, baseFee = rule?.baseFee) {
  try {
    const base=integer(baseFee), cap=integer(fees.maxFeePerGas), priority=integer(fees.maxPriorityFeePerGas);
    return cap===expectedCap(rule.baseFee,priority,rule) && base>=0n && base+priority<=cap;
  } catch { return false; }
}
export function deriveFees(baseFee, priorityFee, rule) {
  const fees={maxFeePerGas:expectedCap(baseFee,priorityFee,rule),maxPriorityFeePerGas:integer(priorityFee)};
  if (!feesWithinRule(fees,{...rule,baseFee},baseFee)) throw Error('chain fee exceeds ceiling');
  return fees;
}
