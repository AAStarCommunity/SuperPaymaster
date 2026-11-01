import { toFunctionSelector, encodeAbiParameters, decodeAbiParameters, keccak256 } from 'viem';
export const IMPL_SLOT='0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';
const lower=x=>String(x).toLowerCase();
const same=(a,b)=>typeof a==='boolean'||typeof b==='boolean'?a===b:typeof a==='string' && a.startsWith('0x')?lower(a)===lower(b):String(a)===String(b);
// Every on-chain gate leaf has a target, selector, argument list and output position. Missing responses fail closed.
export function passportCalls(p) {
  const i=p.invariant,s=i.superPaymaster,t=i.xPNTs,c=i.code,calls=[];
  const add=(to,signature,expected,index=0,type='uint256',args=[])=>calls.push({to,data:toFunctionSelector(signature)+encodeAbiParameters(args.map(([type])=>({type})),args.map(([,v])=>v)).slice(2),expected,index,type});
  const sp=(sig,v,index=0,type='uint256',args=[])=>add(c.superPaymasterProxy.address,sig,v,index,type,args), token=(sig,v,type='uint256')=>add(t.address,sig,v,0,type);
  for(const [arm,name] of [['SP','superPaymasterProxy'],['VPM','verifyingPaymaster'],['TPM','tokenPaymaster']]) {
    for(const [index,field] of ['deposit','staked','stake','unstakeDelaySec','withdrawTime'].entries()) {
      add(i.entryPoint.address,'getDepositInfo(address)',p.volatile.depositInfo[arm][field],index,field==='staked'?'bool':'uint256',[['address',c[name].address]]);
      if(field!=='deposit') add(i.entryPoint.address,'getDepositInfo(address)',i.stakes[arm][field],index,field==='staked'?'bool':'uint256',[['address',c[name].address]]);
    }
    add(c[name].address,'entryPoint()',i.armEntryPoints[arm],0,'address');
  }
  add(i.sender,'entryPoint()',i.armEntryPoints.account,0,'address');
  add(c.verifyingPaymaster.address,'verifyingSigner()',i.verifyingSigner,0,'address');
  for(const [field,sig,type] of [['version','version','string'],['entryPoint','entryPoint','address'],['registry','REGISTRY','address'],['aPNTs','APNTS_TOKEN','address'],['protocolFeeBPS','protocolFeeBPS','uint256'],['aPNTsPriceUSD','aPNTsPriceUSD','uint256'],['priceStalenessThreshold','priceStalenessThreshold','uint256'],['paused','paused','bool']]) sp(sig+'()',s[field],0,type);
  sp('cachedPrice()',s.cachedPrice.price,0,'int256');sp('cachedPrice()',s.cachedPrice.decimals,3);sp('cachedPrice()',p.volatile.cachedPriceUpdatedAt,1);
  sp('gasParams()',s.minPostOpGas);sp('ETH_USD_PRICE_FEED()',c.priceFeed.address,0,'address');sp('isEligibleForSponsorship(address)',s.senderEligible,0,'bool',[['address',i.sender]]);
  for(const [index,value,type] of [[0,p.volatile.operatorBalance,'uint256'],[1,s.operator.isConfigured,'bool'],[2,s.operator.isPaused,'bool'],[3,s.operator.xPNTsToken,'address'],[5,s.operator.minTxInterval,'uint256']]) sp('operators(address)',value,index,type,[['address',s.operator.address]]);
  for(const [field,sig,type] of [['version','version','string'],['exchangeRate','exchangeRate','uint256'],['superPaymaster','SUPERPAYMASTER_ADDRESS','address'],['maxSingleTxLimit','maxSingleTxLimit','uint256'],['emergencyDisabled','emergencyDisabled','bool']]) token(sig+'()',t[field],type);
  token('EXTENSION()',c.xPNTsExt.address,'address');
  for(const [field,sig,type] of [['policy','creditPolicy','uint256'],['hasPendingPolicy','hasPendingPolicy','bool'],['pendingPolicy','pendingPolicy','uint256'],['pendingPolicyEta','pendingPolicyEta','uint256'],['policyEpoch','policyEpoch','uint256']]) token(sig+'()',i.credit[field],type);
  return calls;
}
export function verifyPassport(p,records) {
  const result=r=>JSON.parse(Buffer.from(r.response,'base64').toString()).result;
  const raw=(method,params)=>records.filter(r=>r.method===method && params.every((v,k)=>same(r.params[k],v)));
  const requireValue=(rs,check,label)=>{if(!rs.length || !rs.every(r=>check(result(r)))) throw Error('Passport raw value mismatch: '+label);};
  requireValue(raw('eth_chainId',[]),id=>BigInt(id)===BigInt(p.chainId),'chainId');
  requireValue(raw('eth_getBlockByNumber',['0x'+BigInt(p.block.number).toString(16)]),b=>b && same(b.hash,p.block.hash) && BigInt(b.number)===BigInt(p.block.number) && BigInt(b.timestamp)===BigInt(p.block.timestamp),'block');
  for(const call of passportCalls(p)) {
    const rs=records.filter(r=>r.method==='eth_call' && same(r.params[0].to,call.to) && same(r.params[0].data??r.params[0].input,call.data));
    requireValue(rs,data=>{try {const bytes=call.type==='string'?data:'0x'+data.slice(2+call.index*64,2+(call.index+1)*64);return same(decodeAbiParameters([{type:call.type}],bytes)[0],call.expected);}catch{return false;}},call.data);
  }
  for(const [name,code] of Object.entries(p.invariant.code)) {
    if(code===null && name==='xPNTsImpl') continue;
    requireValue(raw('eth_getCode',[code.address]),bytes=>same(keccak256(bytes),code.codehash) && (bytes.length-2)/2===Number(code.size),'code.'+name);
  }
  const c=p.invariant.code;
  for(const [proxy,impl] of [['superPaymasterProxy','superPaymasterImpl'],['account','accountImpl']]) requireValue(raw('eth_getStorageAt',[c[proxy].address,IMPL_SLOT]),bytes=>/^0x[0-9a-f]{64}$/i.test(bytes) && same('0x'+bytes.slice(26),c[impl].address),'implementation.'+impl);
  requireValue(raw('eth_getCode',[c.xPNTsClone.address]),bytes=>{const clone=/^0x363d3d373d3d3d363d73[0-9a-f]{40}5af43d82803e903d91602b57fd5bf3$/i.test(bytes);return clone?same('0x'+bytes.slice(22,62),c.xPNTsImpl?.address):c.xPNTsImpl===null;},'clone implementation');
}
export function verifyPassportIdentity(p,config,deployment,baseline) {
  const i=p.invariant,c=i.code;
  for(const [value,expected] of [[p.chainId,config.chainId],[i.entryPoint.address,deployment.entryPoint],[c.entryPoint.address,deployment.entryPoint],[c.superPaymasterProxy.address,deployment.superPaymaster],[c.account.address,config.sender],[i.sender,config.sender],[i.bundler,config.accounts.bundler.address],[i.beneficiary,config.accounts.bundler.address],[i.superPaymaster.operator.address,config.operator],[i.verifyingSigner,config.accounts.verifyingSigner.address],[c.verifyingPaymaster.address,baseline.verifyingPaymaster.address],[c.tokenPaymaster.address,baseline.tokenPaymaster.address],[c.tokenPaymasterToken.address,baseline.tokenPaymaster.token],[c.tokenPaymasterOracle.address,baseline.tokenPaymaster.oracle],[c.xPNTsClone.address,i.superPaymaster.operator.xPNTsToken],[i.xPNTs.address,i.superPaymaster.operator.xPNTsToken]]) if(expected==null || !same(value,expected)) throw Error('Passport identity/config mismatch');
}
