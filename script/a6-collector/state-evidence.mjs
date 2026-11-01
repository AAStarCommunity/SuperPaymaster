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
export function supportsCall(record,call,anchor) {
  if (!call.to || record.method!=='eth_call' || record.params?.[0]?.to?.toLowerCase()!==call.to.toLowerCase() || (record.params[0].data ?? record.params[0].input)?.toLowerCase()!==call.data.toLowerCase()) return false;
  if (!record.blockAnchor || BigInt(record.params[1])!==BigInt(anchor.number) || BigInt(record.blockAnchor.number)!==BigInt(anchor.number) || record.blockAnchor.hash!==anchor.hash) return false;
  try {
    const result=JSON.parse(Buffer.from(record.response,'base64').toString()).result;
    const word=result.slice(2+call.index*64,2+(call.index+1)*64);
    return word.length===64 && BigInt('0x'+word)===BigInt(call.expected);
  } catch { return false; }
}
