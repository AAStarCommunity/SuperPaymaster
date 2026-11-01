import { toFunctionSelector, keccak256, toBytes } from 'viem';
const selector = toFunctionSelector('postOp(uint8,bytes,uint256,uint256)');
const oracleSelector = toFunctionSelector('latestRoundData()');
const priceUpdated = keccak256(toBytes('TokenPriceUpdated(uint256,uint256,uint48)'));
// Conservatively exclude any TPM storage change, plus oracle calls under postOp.
// This includes cachedPrice writes even when the value is refreshed to the same price.
export function postOpRefreshed(call, diff, paymaster, oracle) {
  if (!call || typeof call.type !== 'string' || !diff?.pre || !diff?.post) throw new Error('TPM trace unavailable');
  let found = false, refresh = false;
  function visit(frame, inside = false) {
    inside ||= frame.to?.toLowerCase() === paymaster.toLowerCase() && frame.input?.slice(0,10) === selector;
    if (inside) { found = true; if ((oracle && frame.to?.toLowerCase()===oracle.toLowerCase()) || frame.input?.slice(0,10) === oracleSelector || frame.logs?.some(log=>log.topics?.[0]===priceUpdated)) refresh = true; }
    for (const child of frame.calls ?? []) visit(child,inside);
  }
  visit(call);
  if (!found) throw new Error('TPM postOp trace missing');
  const address = paymaster.toLowerCase();
  for (const side of ['pre','post']) if (Object.keys(diff[side][address]?.storage ?? {}).length) refresh = true;
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
