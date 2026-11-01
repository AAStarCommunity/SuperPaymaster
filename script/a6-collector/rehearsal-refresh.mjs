import { toHex } from 'viem';
// OracleHelper slots 3/4 are cache price/time; slot 5 packs cacheTimeToLive in its low 48 bits.
// Age only this cache, not the chain clock or SP quote. Halving the quote crosses the 10% update threshold,
// so postOp writes a fresh timestamp and subsequent attempts use the cache again.
export async function rehearsalTpmRefresh({rehearsal,config,arm,attemptIndex,client,paymaster,abi}) {
  if (!rehearsal || config?.rehearsalForceTpmRefresh!==true || arm!=='TPM' || attemptIndex!==4) return null;
  if (config.chainId!==31337 || await client.getChainId()!==31337) throw Error('TPM refresh control requires chain 31337');
  const block=await client.getBlock(), at={address:paymaster,blockNumber:block.number};
  const ttl=BigInt(await client.getStorageAt({...at,slot:toHex(5n,{size:32})})) & ((1n<<48n)-1n);
  const pmConfig=await client.readContract({...at,abi,functionName:'tokenPaymasterConfig'});
  if (BigInt(pmConfig[3])<=ttl+60n || block.timestamp<=ttl+1n) throw Error('TPM refresh control has no valid inclusion interval');
  const price=await client.readContract({...at,abi,functionName:'cachedPrice'});
  await client.request({method:'anvil_setStorageAt',params:[paymaster,toHex(4n,{size:32}),toHex(block.timestamp-ttl-1n,{size:32})]});
  await client.request({method:'anvil_setStorageAt',params:[paymaster,toHex(3n,{size:32}),toHex(price/2n,{size:32})]});
  await client.request({method:'evm_mine',params:[]});
  // Declared intervention: the row carries it so continuity of exactly these cache slots is not claimed for this attempt.
  return {kind:'tpmCacheAged',paymaster,slots:[3,4],atBlock:String(block.number),cachedPrice:{from:String(price),to:String(price/2n)},cachedPriceTimestamp:{to:String(block.timestamp-ttl-1n)}};
}
