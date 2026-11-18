// Topics are supplied by the collector's keccak implementation; no RPC is needed.
export const settlementSignatures = {
  balance: 'LockSettled(address,bytes32,uint256,uint256)',
  credit: 'CreditSettled(address,bytes32,uint256)',
};
export function settlementBranch(logs, {token, user, hash, topics, planned}) {
  const lower = value => String(value).toLowerCase();
  const matches = [];
  for (const log of logs) for (const branch of ['balance','credit']) {
    if (lower(log.address) === lower(token) && log.topics?.length === 3 &&
        lower(log.topics[0]) === lower(topics[branch]) &&
        lower(log.topics[1]) === lower('0x'+user.slice(2).padStart(64,'0')) &&
        lower(log.topics[2]) === lower(hash) &&
        new RegExp('^0x[0-9a-f]{'+(branch==='balance'?128:64)+'}$','i').test(log.data)) matches.push(branch);
  }
  const observed = matches.length === 1 ? matches[0] : null;
  const result = {planned, observed, event: observed ? settlementSignatures[observed] : null};
  if (!['balance','credit'].includes(planned) || observed !== planned) {
    const error = Error('SP settlement branch mismatch'); error.branch = result; throw error;
  }
  return result;
}
