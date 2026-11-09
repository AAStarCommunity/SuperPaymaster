// Offline window-level config verification. No RPC transport.
import { decodeEventLog, parseAbi } from 'viem';
import { check, decodeExternal, dualRead } from './evidence.mjs';

export class WindowStop extends Error {
  constructor(reason, diagnostic) {
    super(`window_stop: ${reason}: ${diagnostic}`);
    this.stop_reason = reason;
  }
}
export function settlementCheck(condition, diagnostic) {
  if (!condition) throw new WindowStop('settlement_mismatch', diagnostic);
}
export const CONFIG_ABI = parseAbi([
  'event ConfigUpdated((uint256 priceMarkup,uint128 minEntryPointBalance,uint48 refundPostopCost,uint48 priceMaxAge) tokenPaymasterConfig)',
]);

export function archivedLogs(records, address, blockHash) {
  check(records?.length === 2 && records.every(r => r.endpoint) &&
    records[0].endpoint !== records[1].endpoint, 'two distinct log RPC archives required');
  for (const r of records) {
    const filter = r.params?.[0];
    check(r.method === 'eth_getLogs' && r.params.length === 1 && filter &&
      Object.keys(filter).sort().join(',') === 'address,blockHash' &&
      filter.address.toLowerCase() === address.toLowerCase() && filter.blockHash === blockHash,
    'hash-bound complete log scan required');
    check(Array.isArray(r.result) && r.result.every(l => l.blockHash === blockHash &&
      l.address.toLowerCase() === address.toLowerCase() && l.removed !== true), 'log anchor mismatch');
  }
  check(JSON.stringify(records[0].result) === JSON.stringify(records[1].result),
    'log replies disagree', 'rpc_mismatch');
  return records[0].result;
}

export function validateTPMWindow(window, address, windowId) {
  check(window?.window_id === windowId && window.address?.toLowerCase() === address.toLowerCase(),
    'TPM window binding mismatch');
  const blocks = window.blocks;
  check(blocks?.length > 0 && blocks[0].hash === window.firstBlockHash &&
    blocks.at(-1).hash === window.lastBlockHash, 'complete TPM window blocks required');
  for (let i = 0; i < blocks.length; i++) {
    const b = blocks[i];
    check(/^0x[0-9a-f]{64}$/i.test(b.hash) && Number.isSafeInteger(b.number) &&
      (!i || (b.number === blocks[i-1].number + 1 && b.parentHash === blocks[i-1].hash)),
    'contiguous TPM window required');
    for (const log of archivedLogs(b.logs, address, b.hash)) {
      let event;
      try { event = decodeEventLog({abi: CONFIG_ABI, ...log, strict: true}); }
      catch (error) {
        if (['AbiEventSignatureNotFoundError', 'AbiEventSignatureEmptyTopicsError'].includes(error.name)) continue;
        decodeExternal(() => { throw error; }, 'malformed ConfigUpdated log');
      }
      if (event?.eventName === 'ConfigUpdated')
        throw new WindowStop('baseline_config_changed', `ConfigUpdated in block ${b.hash}`);
    }
  }
  const first = dualRead(window.configFirst, address, window.firstBlockHash, 'tokenPaymasterConfig');
  const last = dualRead(window.configLast, address, window.lastBlockHash, 'tokenPaymasterConfig');
  if (!first.every((v, i) => v === last[i]))
    throw new WindowStop('baseline_config_changed', 'TPM first/last config differs');
  return {priceMarkup: first[0], refundPostopCost: BigInt(first[2]), blocks};
}
