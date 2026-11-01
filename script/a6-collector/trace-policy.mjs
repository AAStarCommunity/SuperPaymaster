import { toFunctionSelector, keccak256, toBytes } from 'viem';
const selector = toFunctionSelector('postOp(uint8,bytes,uint256,uint256)');
const oracleSelector = toFunctionSelector('latestRoundData()');
const priceUpdated = keccak256(toBytes('TokenPriceUpdated(uint256,uint256,uint256)'));
// v0.7 TokenPaymaster: Ownable slot 0, UniswapHelper slots 1–2,
// OracleHelper cachedPrice slot 3 and cachedPriceTimestamp slot 4.
export const TPM_CACHE_SLOTS = [3n, 4n];
export function postOpRefreshed(call, diff, paymaster, oracle, entryPoint = call?.to) {
  if (!call || typeof call.type !== 'string' || !diff?.pre || !diff?.post) throw new Error('TPM trace unavailable');
  const ep = entryPoint?.toLowerCase();
  if (!ep || call.to?.toLowerCase()!==ep || ep===paymaster.toLowerCase() || !['pre','post'].every(side=>Object.keys(diff[side]).length && Object.keys(diff[side]).some(a=>a.toLowerCase()===ep))) throw new Error('TPM trace incomplete');
  let found = false, refresh = false;
  function visit(frame, inside = false) {
    inside ||= frame.to?.toLowerCase() === paymaster.toLowerCase() && frame.input?.slice(0,10) === selector;
    if (inside) { found = true; if ((oracle && frame.to?.toLowerCase()===oracle.toLowerCase()) || frame.input?.slice(0,10) === oracleSelector || frame.logs?.some(log=>log.topics?.[0]===priceUpdated)) refresh = true; }
    for (const child of frame.calls ?? []) visit(child,inside);
  }
  visit(call);
  if (!found) throw new Error('TPM postOp trace missing');
  const address = paymaster.toLowerCase();
  for (const side of ['pre','post']) if (Object.keys(diff[side][address]?.storage ?? {}).some(slot=>TPM_CACHE_SLOTS.includes(BigInt(slot)))) refresh = true;
  return refresh;
}
export async function traceTPM(clients, hash, paymaster, oracle) {
  const traces = [];
  for (const client of clients) {
    const call = await client.request({method:'debug_traceTransaction',params:[hash,{tracer:'callTracer',tracerConfig:{withLog:true}}]});
    const state = await client.request({method:'debug_traceTransaction',params:[hash,{tracer:'prestateTracer',tracerConfig:{diffMode:true}}]});
    traces.push({call,state,postOpRefreshed:postOpRefreshed(call,state,paymaster,oracle)});
  }
  if (traces[0].postOpRefreshed !== traces[1].postOpRefreshed) throw new Error('TPM trace disagreement');
  return {tpmOracle:oracle,traces,postOpRefreshed:traces[0].postOpRefreshed};
}

export function tpmAttemptRefreshed(row) {
  if (row.arm!=='TPM') return false;
  if (row.traces?.length!==2) throw new Error('TPM trace incomplete');
  const flags=row.traces.map(t=>postOpRefreshed(t.call,t.state,row.paymaster,row.tpmOracle,row.entryPoint));
  if (flags[0]!==flags[1] || row.postOpRefreshed!==flags[0]) throw new Error('TPM trace disagreement');
  return flags[0];
}
