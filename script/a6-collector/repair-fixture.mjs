// Offline fixture with real, resolvable archives. No transport or signer is used.
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { encodeFunctionData, toHex, toFunctionSelector } from 'viem';
import { rawArchive,evidenceIndex,sha256,stringify,writeArtifact,armCounts } from './evidence.mjs';
import { formalConfig,armOrder } from './formal.mjs';
import { bundleAbi } from './artifact-validate.mjs';
import { stateCalls } from './state-evidence.mjs';
export function repairFixture(dir,count=3) {
  const source=readFileSync(new URL('../../docs/design/aoa-balance-mode/data/a6-gauge-local/positive.jsonl',import.meta.url),'utf8').trim().split('\n').map(JSON.parse);
  const template=source[1], inv=source[0].passport.invariant;
  const config={frozen:true,chainId:31337,operator:inv.superPaymaster.operator.address,factory:template.sender,sender:template.sender,salt:'0',bundlerGasLimit:'3000000',accounts:{owner:{name:'owner',address:template.sender},bundler:{name:'bundler',address:template.bundler},verifyingSigner:{name:'verifier',address:template.paymaster}},fees:{maxFeePerGas:'5000000000',maxPriorityFeePerGas:'1000000000'},task:{token:inv.xPNTs.address,recipient:template.paymaster},gas:Object.fromEntries(['SP','VPM','TPM'].map(arm=>[arm,{callGasLimit:'100000',verificationGasLimit:'300000',preVerificationGas:'60000',paymasterVerificationGasLimit:'450000',paymasterPostOpGasLimit:'480000'}]))};
  const frozen=formalConfig(config,1);
  writeFileSync(join(dir,'pin'),'fixture pin');
  const pin={path:join(dir,'pin'),sha256:sha256('fixture pin')};
  const pins=Object.fromEntries(['collector','validator','dependencies','contractSources','abi','config'].map(k=>[k,[pin]]));
  writeArtifact(dir,'frozen-config.json',config);
  const configPin={path:join(dir,'frozen-config.json'),sha256:sha256(readFileSync(join(dir,'frozen-config.json')))};
  pins.config.push(configPin);
  const registry={schemaVersion:'a6-rpc-identity/1',...Object.fromEntries(['A','B'].map(e=>[e,{operatorName:e,backendIdentity:e,upstream:e,endpointLabel:e,registeredAt:'2026-11-01T00:00:00.000Z',evidence:[pin]}]))};
  writeArtifact(dir,'rpc-identity.json',registry);
  const rpcIdentity={path:'rpc-identity.json',sha256:sha256(readFileSync(join(dir,'rpc-identity.json')))};
  const archives=['A','B'].map(e=>rawArchive(dir,e)), rows=[],attempts=[];
  let clock='2026-11-01T00:00:00.000Z';
  const append=(arc,method,params,result,anchor)=>{
    const id=arc.records.length+1, time=clock;
    arc.append({endpoint:arc===archives[0]?'A':'B',requestedAtUtc:time,receivedAtUtc:time,method,params,anchor,requestBase64:Buffer.from(JSON.stringify({jsonrpc:'2.0',id,method,params})).toString('base64'),responseBase64:Buffer.from(JSON.stringify({jsonrpc:'2.0',id,result})).toString('base64')});
  };
  const passport={...source[0].passport,invariant:{...inv,code:{...inv.code,tokenPaymasterToken:{address:inv.xPNTs.address},tokenPaymasterOracle:{address:inv.xPNTs.address}}}};
  writeArtifact(dir,'passports/start.json',passport);
  const p={path:'passports/start.json',raw:{A:[],B:[]}};
  for(const [idx,arc] of archives.entries()) { const anchor={number:toHex(BigInt(passport.block.number)),hash:passport.block.hash}; append(arc,'eth_getBlockByNumber',[anchor.number,false],{number:anchor.number,hash:anchor.hash},anchor);p.raw[idx?'B':'A']=[{path:arc.records[0].path,id:arc.records[0].id}]; }
  for(let i=0;i<count;i++) {
    clock=new Date(Date.UTC(2026,10,1,0,0,i)).toISOString();
    const a=structuredClone(template), triple=Math.floor(i/3), arm=armOrder(triple)[i%3];
    Object.assign(a,{passport,attemptIndex:i,tripletIndex:triple,arm,armOrder:armOrder(triple),collectedAtUtc:new Date(Date.UTC(2026,10,1,0,0,i,500)).toISOString(),evidenceStart:archives.map(x=>x.ids.length),stateTargets:{superPaymaster:inv.code.superPaymasterProxy.address,token:inv.xPNTs.address,tpmToken:inv.xPNTs.address,operator:config.operator}});
    a.tx.hash='0x'+(i+1).toString(16).padStart(64,'0');
    a.tx.blockNumber=String(100+i*2); a.tx.blockHash='0x'+(100+i*2).toString(16).padStart(64,'0');
    for(const side of ['before','after']) for(const endpoint of ['A','B']) { const n=100+i*2-(side==='before'?1:0); Object.assign(a.readbacks[side][endpoint],{blockNumber:String(n),blockHash:'0x'+n.toString(16).padStart(64,'0')}); }
    a.packedOp.callData=frozen.callData;a.bundledOps=[a.packedOp];
    Object.assign(a.tx,{input:encodeFunctionData({abi:bundleAbi,functionName:'handleOps',args:[[a.packedOp],config.accounts.bundler.address]}),handleOpsIndex:0,gasLimit:'3000000',maxFeePerGas:'5000000000',maxPriorityFeePerGas:'1000000000'});
    a.tx.raw={hash:a.tx.hash,input:a.tx.input,gas:toHex(BigInt(a.tx.gasLimit)),maxFeePerGas:toHex(BigInt(a.tx.maxFeePerGas)),maxPriorityFeePerGas:toHex(BigInt(a.tx.maxPriorityFeePerGas)),blockNumber:toHex(BigInt(a.tx.blockNumber)),blockHash:a.tx.blockHash};
    const uoe=a.logs.find(l=>l.topics[1]===a.expectedUserOpHash);a.userOpEvent.logIndex=uoe.logIndex;
    for(const side of ['before','after']) for(const e of ['A','B']) Object.assign(a.readbacks[side][e],{tpmTokenBalances:{sender:'5',paymaster:'7'},tpmCachedPriceTimestamp:'10'});
    if (arm==='TPM') {a.tpmOracle=inv.xPNTs.address;a.postOpRefreshed=false;a.traces=[0,1].map(()=>({call:{type:'CALL',to:a.paymaster,input:toFunctionSelector('postOp(uint8,bytes,uint256,uint256)'),calls:[]},state:{pre:{},post:{}},postOpRefreshed:false}));}
    for(const [endpointIndex,arc] of archives.entries()) {
      const anchor={number:toHex(BigInt(a.tx.blockNumber)),hash:a.tx.blockHash};
      if (i>0) { const prev=attempts[i-1].tx; append(arc,'eth_getTransactionReceipt',[prev.hash],{blockNumber:toHex(BigInt(prev.blockNumber)),blockHash:prev.blockHash},null); append(arc,'eth_blockNumber',[],toHex(BigInt(prev.blockNumber)+1n),null); }
      if (arc===archives[0]) append(arc,'eth_sendRawTransaction',['0x01'],a.tx.hash,null);
      if (a.traces) for (const [tracer,key] of [['callTracer','call'],['prestateTracer','state']]) append(arc,'debug_traceTransaction',[a.tx.hash,{tracer}],a.traces[endpointIndex][key],anchor);
      append(arc,'eth_getBlockByNumber',[anchor.number,false],{number:anchor.number,hash:anchor.hash,transactions:[a.tx.hash]},anchor);
      append(arc,'eth_getTransactionByHash',[a.tx.hash],a.tx.raw,anchor);
      append(arc,'eth_getTransactionReceipt',[a.tx.hash],{blockNumber:anchor.number,blockHash:anchor.hash,logs:a.logs.map(l=>({...l,logIndex:toHex(BigInt(l.logIndex))}))},anchor);
      for(const side of ['before','after']) {
        const s=a.readbacks[side].A, fields={entryPointDeposit:s.epDeposit,operatorBalance:s.operatorBalance,...(arm==='SP'?{protocolRevenue:s.protocolRevenue,inflightOf:{operator:s.inflightOperator,a0:s.inflightA0},userXPNTs:s.userXPNTs,totalSupply:s.totalSupply,lockedOf:s.lockedOf,debts:s.debts,creditReservedOf:s.creditReservedOf,operatorTotalSpent:s.totalSpent,operatorTotalTxSponsored:s.totalTxSponsored}:arm==='TPM'?{tpmTokenBalances:s.tpmTokenBalances,tpmCachedPriceTimestamp:s.tpmCachedPriceTimestamp}:{vpmDeposit:s.epDeposit})};
        const calls=Object.entries(fields).flatMap(([key,v])=>stateCalls(a,key,v)), grouped=new Map();
        for(const c of calls) { const id=c.to+c.data; if(!grouped.has(id))grouped.set(id,{...c,words:[]});grouped.get(id).words[c.index]=BigInt(c.expected).toString(16).padStart(64,'0'); }
        for(const c of grouped.values()) append(arc,'eth_call',[{to:c.to,data:c.data},toHex(BigInt(s.blockNumber))],'0x'+Array.from({length:c.words.length},(_,i)=>c.words[i]??'0'.repeat(64)).join(''),{number:toHex(BigInt(s.blockNumber)),hash:s.blockHash});
      }
    }
    a.evidenceEnd=archives.map(x=>x.ids.length);
    const row=evidenceIndex(a,{windowId:'w',archives,pins,rpcIdentity,passports:{start:p,attempt:p},stopReason:null,replaces:triple===1?{windowId:'w',tripleIndex:0}:null});
    rows.push(row);attempts.push(a);
  }
  const anchors=[...new Map(archives.flatMap(a=>a.records.filter(r=>r.blockAnchor).map(r=>[r.blockAnchor.number,r.blockAnchor.hash])))].map(([number,hash])=>({number,hash}));
  clock='2026-11-02T00:00:00.000Z';
  const finalBlockCheck={anchors,raw:{A:[],B:[]}};
  for (const [idx,arc] of archives.entries()) for (const anchor of anchors) { append(arc,'eth_getBlockByNumber',[toHex(BigInt(anchor.number)),false],{number:toHex(BigInt(anchor.number)),hash:anchor.hash},anchor); const record=arc.records.at(-1);finalBlockCheck.raw[idx?'B':'A'].push({path:record.path,id:record.id}); }
  return {finalBlockCheck,rows,attempts,archives,passport:p,start:{kind:'run_start',configSha256:configPin.sha256,deploymentConfigSha256:pin.sha256,baselineConfigSha256:pin.sha256,pins,rpcIdentity,frozenConfig:config,passport},config};
}
