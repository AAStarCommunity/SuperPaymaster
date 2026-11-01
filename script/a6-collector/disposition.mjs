export function dispositionErrors(row) {
  const errors = [];
  const reason = typeof row.exclusion === 'string' ? row.exclusion.trim() : row.exclusion?.reason;
  const failure = row.stoppedBy?.reason ?? row.failingCheck;
  const excluded = row.included === false || row.exclusion != null || (row.verdict && row.verdict !== 'USEROP_SUCCESS') || row.stoppedBy;
  if (excluded && !reason) errors.push('exclusion reason required');
  if (row.verdict === 'NOT_SENT' && !(row.reason || row.failingCheck || row.stoppedBy?.reason)) errors.push('NOT_SENT requires pause/failure reason');
  if (reason && failure) {
    const normalized = reason.toLowerCase();
    const aliases = { preflight_revert:['not_sent:preflight_undecoded','not_sent:infra_aa31'] };
    if (![failure.toLowerCase(), `not_sent:${failure.toLowerCase()}`].includes(normalized) && !(normalized === 'stopped' && row.stoppedBy) && !(normalized === 'fixture' && row.fixture) && !aliases[failure]?.includes(normalized)) errors.push('exclusion contradicts failure reason');
  }
  return errors;
}
export function feePauseErrors(row) {
  if (row.failingCheck !== 'basefee_above_cap') return [];
  try {
    if (row.sent !== false || row.verdict !== 'NOT_SENT' || row.reason !== 'basefee_above_cap' || !/^0x[0-9a-f]{64}$/i.test(row.feeBlock?.hash) || BigInt(row.feeBlock.number) < 0n || BigInt(row.baseFeePerGas) <= BigInt(row.gas.maxFeePerGas)) return ['invalid fee pause evidence'];
  } catch { return ['invalid fee pause evidence']; }
  return [];
}
