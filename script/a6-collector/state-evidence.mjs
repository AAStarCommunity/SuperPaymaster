import { toFunctionSelector, encodeAbiParameters } from 'viem';
export function stateCalls(row,key,value) {
  const {superPaymaster,token,tpmToken,operator}=row.stateTargets ?? {};
  const call=(to,signature,args,expected,index=0)=>({to,data:toFunctionSelector(signature)+encodeAbiParameters(args.map(([type])=>({type})),args.map(([,v])=>v)).slice(2),expected,index});
  const addr=a=>['address',a], hash=['bytes32',row.expectedUserOpHash];
  if (['entryPointDeposit','vpmDeposit'].includes(key)) return [call(row.entryPoint,'balanceOf(address)',[addr(row.paymaster)],value)];
  if (['operatorBalance','operatorTotalSpent','operatorTotalTxSponsored'].includes(key)) return [call(superPaymaster,'operators(address)',[addr(operator)],value,{operatorBalance:0,operatorTotalSpent:7,operatorTotalTxSponsored:8}[key])];
  if (key==='protocolRevenue') return [call(superPaymaster,'protocolRevenue()',[],value)];
  if (key==='inflightOf') return [call(superPaymaster,'inflightOf(bytes32)',[hash],value.operator,0),call(superPaymaster,'inflightOf(bytes32)',[hash],value.a0,1)];
  if (key==='tpmCachedPriceTimestamp') return [call(row.paymaster,'cachedPriceTimestamp()',[],value)];
  if (key==='tpmTokenBalances') return [call(tpmToken,'balanceOf(address)',[addr(row.sender)],value.sender),call(tpmToken,'balanceOf(address)',[addr(row.paymaster)],value.paymaster)];
  const signature={userXPNTs:'balanceOf(address)',totalSupply:'totalSupply()',lockedOf:'lockedOf(address)',debts:'debts(address)',creditReservedOf:'creditReservedOf(address)'}[key];
  if (!signature) throw new Error('unknown state field');
  return [call(token,signature,key==='totalSupply'?[]:[addr(row.sender)],value)];
}
// Only shapes emitted by the collector are admissible evidence.
export function archivedParamsAllowed({method,params:p}) {
  if (!Array.isArray(p)) return false;
  const hex=v=>typeof v==='string' && /^0x[0-9a-f]+$/i.test(v);
  const address=v=>typeof v==='string' && /^0x[0-9a-f]{40}$/i.test(v);
  const hash=v=>typeof v==='string' && /^0x[0-9a-f]{64}$/i.test(v);
  if (['eth_chainId','eth_blockNumber','evm_mine'].includes(method)) return p.length===0;
  if (method==='eth_call') return p.length===2 && p[0] && !Array.isArray(p[0]) && Object.keys(p[0]).every(k=>['to','data','from'].includes(k)) && address(p[0].to) && /^0x(?:[0-9a-f]{2})*$/i.test(p[0].data ?? '') && (!('from' in p[0]) || address(p[0].from)) && hex(p[1]);
  if (['eth_getCode','eth_getBalance','eth_getTransactionCount'].includes(method)) return p.length===2 && address(p[0]) && hex(p[1]);
  if (method==='eth_getStorageAt') return p.length===3 && address(p[0]) && hex(p[1]) && hex(p[2]);
  // getBlock uses false; waitForTransactionReceipt replacement detection requests full transactions (true).
  if (method==='eth_getBlockByNumber') return p.length===2 && (hex(p[0]) || p[0]==='latest') && typeof p[1]==='boolean';
  if (['eth_getTransactionByHash','eth_getTransactionReceipt'].includes(method)) return p.length===1 && hash(p[0]);
  if (method==='eth_sendRawTransaction') return p.length===1 && hex(p[0]);
  if (method==='debug_traceTransaction') return p.length===2 && hash(p[0]);
  if (method==='anvil_setStorageAt') return p.length===3 && address(p[0]) && hash(p[1]) && hash(p[2]);
  return false;
}
export function supportsCall(record,call,anchor) {
  if (!archivedParamsAllowed(record) || !call.to || record.method!=='eth_call' || record.params?.[0]?.to?.toLowerCase()!==call.to.toLowerCase() || (record.params[0].data ?? record.params[0].input)?.toLowerCase()!==call.data.toLowerCase()) return false;
  if (!record.blockAnchor || BigInt(record.params[1])!==BigInt(anchor.number) || BigInt(record.blockAnchor.number)!==BigInt(anchor.number) || record.blockAnchor.hash!==anchor.hash) return false;
  try {
    const result=JSON.parse(Buffer.from(record.response,'base64').toString()).result;
    const word=result.slice(2+call.index*64,2+(call.index+1)*64);
    return word.length===64 && BigInt('0x'+word)===BigInt(call.expected);
  } catch { return false; }
}
