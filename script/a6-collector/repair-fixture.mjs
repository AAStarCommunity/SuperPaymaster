// Offline fixture with real, resolvable archives. No transport or signer is used.
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { formatTransaction, encodeFunctionData, toHex, toFunctionSelector } from 'viem';
import { rawArchive,evidenceIndex,sha256,stringify,writeArtifact,armCounts } from './evidence.mjs';
import { formalConfig,armOrder } from './formal.mjs';
import { bundleAbi } from './artifact-validate.mjs';
import { passportCalls, IMPL_SLOT } from './passport-evidence.mjs';
import { encodeAbiParameters, keccak256 } from 'viem';
import { stateCalls } from './state-evidence.mjs';
export function repairFixture(dir,count=3,{advanceHeadBeforeSend=false}={}) {
  const source=readFileSync(new URL('../../docs/design/aoa-balance-mode/data/a6-gauge-local/positive.jsonl',import.meta.url),'utf8').trim().split('\n').map(JSON.parse);
  const template=source[1], inv=source[0].passport.invariant;
  const config={frozen:true,chainId:31337,operator:inv.superPaymaster.operator.address,factory:template.sender,sender:template.sender,salt:'0',bundlerGasLimit:'3000000',accounts:{owner:{name:'owner',address:template.sender},bundler:{name:'bundler',address:template.bundler},verifyingSigner:{name:'verifier',address:inv.verifyingSigner}},fees:{maxFeePerGas:'5000000000',maxPriorityFeePerGas:'1000000000'},task:{token:inv.xPNTs.address,recipient:template.paymaster},gas:Object.fromEntries(['SP','VPM','TPM'].map(arm=>[arm,{callGasLimit:'100000',verificationGasLimit:'300000',preVerificationGas:'60000',paymasterVerificationGasLimit:'450000',paymasterPostOpGasLimit:'480000'}]))};
  const frozen=formalConfig(config,1);
  writeFileSync(join(dir,'pin'),'fixture pin');
  const pin={path:join(dir,'pin'),sha256:sha256('fixture pin')};
  const pins=Object.fromEntries(['collector','validator','dependencies','contractSources','abi','config'].map(k=>[k,[pin]]));
  writeArtifact(dir,'frozen-config.json',config);
  const configPin={path:join(dir,'frozen-config.json'),sha256:sha256(readFileSync(join(dir,'frozen-config.json')))};
  pins.config.push(configPin);
  const configs=[{entryPoint:inv.entryPoint.address,superPaymaster:inv.code.superPaymasterProxy.address},{verifyingPaymaster:{address:inv.code.verifyingPaymaster.address},tokenPaymaster:{address:inv.code.tokenPaymaster.address,token:inv.xPNTs.address,oracle:inv.xPNTs.address}}];
  const configPins=configs.map((x,i)=>{const path=join(dir,`config-${i}.json`);writeFileSync(path,stringify(x));const pin={path,sha256:sha256(readFileSync(path))};pins.config.push(pin);return pin;});
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
  passport.volatile.depositInfo=Object.fromEntries(['SP','VPM','TPM'].map(arm=>[arm,{deposit:'1000000000000000000',...passport.invariant.stakes[arm]}]));
  passport.invariant.credit={policy:0,hasPendingPolicy:false,pendingPolicy:0,pendingPolicyEta:0,policyEpoch:0};
  const codes=new Map();
  for(const code of Object.values(passport.invariant.code)) if(code) codes.set(code.address.toLowerCase(),'0x6000');
  const clone=passport.invariant.code.xPNTsClone.address.toLowerCase();
  codes.set(clone,'0x363d3d373d3d3d363d73'+passport.invariant.code.xPNTsImpl.address.slice(2).toLowerCase()+'5af43d82803e903d91602b57fd5bf3');
  for(const code of Object.values(passport.invariant.code)) if(code) {const bytes=codes.get(code.address.toLowerCase());code.codehash=keccak256(bytes);code.size=(bytes.length-2)/2;}
  writeArtifact(dir,'passports/start.json',passport);
  const p={path:'passports/start.json',raw:{A:[],B:[]}};
  for(const [idx,arc] of archives.entries()) {
    const anchor={number:toHex(BigInt(passport.block.number)),hash:passport.block.hash};
    append(arc,'eth_chainId',[],toHex(passport.chainId),null);
    append(arc,'eth_getBlockByNumber',[anchor.number,false],{number:anchor.number,hash:anchor.hash,timestamp:toHex(BigInt(passport.block.timestamp))},anchor);
    for(const [address,bytes] of codes) append(arc,'eth_getCode',[address,anchor.number],bytes,anchor);
    for(const [proxy,impl] of [['superPaymasterProxy','superPaymasterImpl'],['account','accountImpl']]) append(arc,'eth_getStorageAt',[passport.invariant.code[proxy].address,IMPL_SLOT,anchor.number],'0x'+passport.invariant.code[impl].address.slice(2).padStart(64,'0'),anchor);
    const grouped=new Map();
    for(const c of passportCalls(passport)) {
      const key=c.to.toLowerCase()+c.data;
      if(!grouped.has(key)) grouped.set(key,{...c,words:[]});
      grouped.get(key).words[c.index]=encodeAbiParameters([{type:c.type}],[c.type==='bool'?c.expected:c.type==='string'||c.type==='address'?c.expected:BigInt(c.expected)]).slice(2);
    }
    for(const c of grouped.values()) append(arc,'eth_call',[{to:c.to,data:c.data},anchor.number],'0x'+Array.from({length:c.words.length},(_,j)=>c.words[j]??'0'.repeat(64)).join(''),anchor);
    p.raw[idx?'B':'A']=arc.records.map(r=>({path:r.path,id:r.id}));
  }
  for(let i=0;i<count;i++) {
    clock=new Date(Date.UTC(2026,10,1,0,0,i)).toISOString();
    const a=structuredClone(template), triple=Math.floor(i/3), arm=armOrder(triple)[i%3];
    Object.assign(a,{passport,attemptIndex:i,tripletIndex:triple,arm,armOrder:armOrder(triple),collectedAtUtc:new Date(Date.UTC(2026,10,1,0,0,i,500)).toISOString(),evidenceStart:archives.map(x=>x.ids.length),stateTargets:{superPaymaster:inv.code.superPaymasterProxy.address,token:inv.xPNTs.address,tpmToken:inv.xPNTs.address,operator:config.operator}});
    a.tx.hash='0x'+(i+1).toString(16).padStart(64,'0');
    a.tx.blockNumber=String(100+i*2); a.tx.headBefore=String((advanceHeadBeforeSend?98:99)+i*2); a.tx.blockTxCount=1; a.tx.blockHash='0x'+(100+i*2).toString(16).padStart(64,'0');
    for(const side of ['before','after']) for(const endpoint of ['A','B']) { const n=100+i*2-(side==='before'?1:0); Object.assign(a.readbacks[side][endpoint],{blockNumber:String(n),blockHash:'0x'+n.toString(16).padStart(64,'0')}); }
    a.packedOp.callData=frozen.callData;a.bundledOps=[a.packedOp];
    Object.assign(a.tx,{input:encodeFunctionData({abi:bundleAbi,functionName:'handleOps',args:[[a.packedOp],config.accounts.bundler.address]}),handleOpsIndex:0,gasLimit:'3000000',maxFeePerGas:'5000000000',maxPriorityFeePerGas:'1000000000'});
    a.tx.raw={type:'0x2',chainId:'0x7a69',nonce:'0x0',value:'0x0',transactionIndex:'0x0',v:'0x1',r:'0x'+'11'.repeat(32),s:'0x'+'22'.repeat(32),accessList:[],gasPrice:'0x3b9aca00',to:a.entryPoint,from:a.tx.from,hash:a.tx.hash,input:a.tx.input,gas:toHex(BigInt(a.tx.gasLimit)),maxFeePerGas:toHex(BigInt(a.tx.maxFeePerGas)),maxPriorityFeePerGas:toHex(BigInt(a.tx.maxPriorityFeePerGas)),blockNumber:toHex(BigInt(a.tx.blockNumber)),blockHash:a.tx.blockHash};
    const archivedTx=structuredClone(a.tx.raw);a.tx.raw=JSON.parse(stringify(formatTransaction(archivedTx)));
    const uoe=a.logs.find(l=>l.topics[1]===a.expectedUserOpHash);a.userOpEvent.logIndex=uoe.logIndex;a.observedUserOpEvent={...a.userOpEvent};
    for(const side of ['before','after']) for(const e of ['A','B']) Object.assign(a.readbacks[side][e],{tpmTokenBalances:{sender:'5',paymaster:'7'},tpmCachedPriceTimestamp:'10'});
    if (arm==='TPM') {a.tpmOracle=inv.xPNTs.address;a.postOpRefreshed=false;a.traces=[0,1].map(()=>({call:{type:'CALL',to:a.entryPoint,calls:[{type:'CALL',to:a.paymaster,input:toFunctionSelector('postOp(uint8,bytes,uint256,uint256)'),calls:[]}]},state:{pre:{[a.entryPoint.toLowerCase()]:{storage:{'0x0':'0x1'}}},post:{[a.entryPoint.toLowerCase()]:{storage:{'0x0':'0x2'}}}},postOpRefreshed:false}));}
    for(const [endpointIndex,arc] of archives.entries()) {
      const anchor={number:toHex(BigInt(a.tx.blockNumber)),hash:a.tx.blockHash};
      if (i>0) { const prev=attempts[i-1].tx; append(arc,'eth_getTransactionReceipt',[prev.hash],{blockNumber:toHex(BigInt(prev.blockNumber)),blockHash:prev.blockHash,status:'0x1',logs:attempts[i-1].logs},null); append(arc,'eth_blockNumber',[],toHex(BigInt(prev.blockNumber)+1n),null); }
      append(arc,'eth_blockNumber',[],toHex(BigInt(a.tx.headBefore)),null);
      if (advanceHeadBeforeSend) append(arc,'eth_blockNumber',[],toHex(BigInt(a.tx.headBefore)+1n),null);
      if (arc===archives[0]) append(arc,'eth_sendRawTransaction',['0x01'],a.tx.hash,null);
      if (a.traces) for (const [tracer,key] of [['callTracer','call'],['prestateTracer','state']]) append(arc,'debug_traceTransaction',[a.tx.hash,{tracer,tracerConfig:tracer==='callTracer'?{withLog:true}:{diffMode:true}}],a.traces[endpointIndex][key],anchor);
      append(arc,'eth_getBlockByNumber',[anchor.number,false],{number:anchor.number,hash:anchor.hash,timestamp:toHex(BigInt(a.tx.blockTimestamp)),transactions:[a.tx.hash]},anchor);
      append(arc,'eth_getTransactionByHash',[a.tx.hash],archivedTx,anchor);
      append(arc,'eth_getTransactionReceipt',[a.tx.hash],{blockNumber:anchor.number,blockHash:anchor.hash,status:'0x1',gasUsed:toHex(BigInt(a.tx.gasUsed)),effectiveGasPrice:toHex(BigInt(a.tx.effectiveGasPrice)),logs:a.logs.map(l=>({...l,logIndex:toHex(BigInt(l.logIndex))}))},anchor);
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
  return {finalBlockCheck,rows,attempts,archives,passport:p,start:{kind:'run_start',formal:true,rehearsal:true,configSha256:configPin.sha256,deploymentConfigSha256:configPins[0].sha256,baselineConfigSha256:configPins[1].sha256,pins,rpcIdentity,frozenConfig:config,passport},config};
}
