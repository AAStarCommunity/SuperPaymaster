// The same rule applies at the frozen block and immediately before sending.
export function feesWithinRule(fees, rule, baseFee = rule?.baseFee) {
  if (baseFee == null || rule?.ceiling == null) return false;
  const base=BigInt(baseFee), cap=BigInt(fees.maxFeePerGas), priority=BigInt(fees.maxPriorityFeePerGas);
  return base>=0n && priority>=0n && priority<=cap && base+priority<=cap && cap<=BigInt(rule.ceiling);
}
export function deriveFees(baseFee, priorityFee, rule) {
  if (baseFee == null || priorityFee == null) throw Error('chain fee unavailable');
  const base=BigInt(baseFee), priority=BigInt(priorityFee);
  const n=BigInt(rule.factor.numerator), d=BigInt(rule.factor.denominator);
  if (n<d || d<=0n) throw Error('invalid fee factor');
  const requested=(base*n+d-1n)/d+priority, ceiling=BigInt(rule.ceiling);
  const fees={maxFeePerGas:requested<ceiling?requested:ceiling,maxPriorityFeePerGas:priority};
  if (!feesWithinRule(fees,rule,base)) throw Error('chain fee exceeds ceiling');
  return fees;
}
