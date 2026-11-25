// Offline frozen window with resolvable A/B evidence and an explicit test protocol.
import { execFileSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { encodeAbiParameters, encodeFunctionData, formatTransaction, getAddress, keccak256, toFunctionSelector, toHex } from 'viem';
import { bundleAbi } from './artifact-validate.mjs';
import { armCounts, evidenceIndex, sha256, stringify, writeArtifact, writeTrailer } from './evidence.mjs';
import { localUserOpHash } from './gauge-lib.mjs';
import { IMPL_SLOT, passportCalls } from './passport-evidence.mjs';
import { finalizePVG, recordPVG } from './pvg.mjs';
import { stateCalls } from './state-evidence.mjs';
import { createWindow, REGISTERED_WINDOW, windowRecord } from './window-schedule.mjs';

const legacy=readFileSync(new URL('../../docs/design/aoa-balance-mode/data/a6-gauge-local/positive.jsonl',import.meta.url),'utf8').trim().split('\n').map(JSON.parse);
const names={SP:'SP',VerifyingPaymaster:'VPM',TokenPaymaster:'TPM'}, arms=Object.values(names);
const accounts=[200,201,202].map(n=>getAddress(toHex(n,{size:20})));
const json=v=>JSON.parse(stringify(v));
const word=v=>toHex(BigInt(v),{size:32});
const hex=v=>toHex(BigInt(v));
const hash=n=>word(n);
const refs=records=>records.map(({path,id})=>({path,id}));
const pairs=fn=>Object.fromEntries(['A','B'].map((e,i)=>[e,fn(i)]));
const addressTopic=a=>'0x'+a.slice(2).padStart(64,'0');
const words=(...values)=>'0x'+values.map(v=>word(v).slice(2)).join('');
const ceil=(n,d)=>(n+d-1n)/d;
const senderFields=['userXPNTs','lockedOf','debts','creditReservedOf'];
const scheduleFields=['block_slot','pair_id','seed','schedule_sha256','warmup','spWait','slotChecks','scheduleDisposition'];
let fixtureBundle;
export async function sentWindowFixture(dir,{
  windowIndex=1, runId=`frozen-sent-${windowIndex}`, blockStart=100+(windowIndex-1)*1000,
  priceDelta=0n, version, priceDecimals, protocol=REGISTERED_WINDOW, nonceOffset=0,
  nonceGap=false, balanceGap=false, senderBalanceGap=false, outerGasDelta=0n,
  priceStalenessThreshold=3000, finalVpmVerdict='USEROP_SUCCESS'
}={}) {
  const bytes=fixtureBundle??=execFileSync('python3.11',['-B','script/a6-collector/frozen-fixture.py']);
  const bundleSha256=sha256(bytes), chainId=10, seed='public';
  const {adapters,manifest}=createWindow({readBundle:()=>bytes,bundleSha256,seed,chainId,accounts,windowIndex});
  const {schedule,slice}=manifest, head={schema:'a6-gauge/2',runId};
  const registered={...protocol,seed,scheduleSha256:schedule.sha256};
  const epoch=BigInt(legacy[0].passport.block.timestamp)+BigInt(windowIndex-1)*3000n;
  const {targetTriplets,slotCap,stoppingRule,warmupAttempts,warmup}=protocol;
  Object.assign(manifest,{targetTriplets,slotCap,stoppingRule,warmupAttempts,warmup,windowId:head.runId,startTimestamp:String(epoch)});
  const usedSlots=schedule.payload.slots.slice(slice.firstSlot,slice.lastSlot+1);
  const [missedSlot, firstIncluded]=usedSlots;
  const firstSent=firstIncluded.block_slot;
  writeFileSync(join(dir,'bundle.json'),bytes);
  writeArtifact(dir,'manifest.json',manifest);

  const {plan}=adapters.get(accounts[0]), pc=plan.phaseC, addresses=pc.addresses;
  const entryPoint=plan.addresses.entryPoint, operator=plan.deploymentContext.operator, token=addresses.X;
  const input=plan.externalInputs.data.phaseC, bundler=input.bundler, verifyingSigner=input.verifyingSigner;
  const deployment={entryPoint,superPaymaster:addresses.SP};
  const baseline={verifyingPaymaster:{address:addresses.VPM},tokenPaymaster:{address:addresses.TPM,token:addresses.Q,oracle:addresses.oracle}};
  const config={chainId,operator,factory:plan.deploymentContext.accountFactory,
    accounts:{bundler:{name:'bundler',address:bundler},verifyingSigner:{name:'verifier',address:verifyingSigner}},
    task:{token:addresses.T,recipient:pc.recipient},senders:accounts.map(sender=>{
      const {accountOwner,salt}=adapters.get(sender).plan.externalInputs.data.phaseC;
      return {sender,salt,owner:{name:'owner-'+salt,address:accountOwner}};
    })};
  const [first]=config.senders;
  const frozenConfig={...config,sender:first.sender,salt:first.salt,accounts:{...config.accounts,owner:first.owner}};
  adapters.get(first.sender).bind(frozenConfig,deployment,baseline,1,20);
  const pin=(path,object)=>{
    writeArtifact(dir,path,object);
    const absolute=join(dir,path);
    return {path:absolute,sha256:sha256(readFileSync(absolute))};
  };
  const fixturePin=pin('fixture.json',{fixture:'offline'});
  const [configPin,deploymentPin,baselinePin]=[['formal.json',config],['deployment.json',deployment],['baseline.json',baseline]].map(([path,data])=>pin(path,data));
  const pins=Object.fromEntries(['collector','validator','dependencies','contractSources','abi','config'].map(k=>[k,[fixturePin]]));
  pins.config.push(configPin,deploymentPin,baselinePin);
  const registry={schemaVersion:'a6-rpc-identity/1',...pairs(i=>({operatorName:'operator-'+i,backendIdentity:'backend-'+i,
    upstream:'upstream-'+i,endpointLabel:'endpoint-'+i,registeredAt:'2026-11-01T00:00:00.000Z',evidence:[fixturePin]}))};
  const rpcIdentity={...pin('rpc-identity.json',registry),path:'rpc-identity.json'};

  const archives=['A','B'].map(endpoint=>({endpoint,path:`raw/${endpoint}/20261125.ndjson`,records:[]})), index=[], rows=[], triplets=[];
  let clock=Date.UTC(2026,10,25), lastTx=null, pending=(windowIndex-1)*(slice.slots-1)*3, blockNumber=blockStart;
  const now=()=>new Date(clock).toISOString();
  function append(i,method,params,result,anchor=null) {
    const arc=archives[i], id=arc.records.length+1;
    const encoded=v=>Buffer.from(JSON.stringify({jsonrpc:'2.0',id,...v})).toString('base64');
    const ts=now(), request=encoded({method,params}), response=encoded({result});
    const blockAnchor=anchor && {number:String(BigInt(anchor.number)),hash:anchor.hash};
    arc.records.push({path:arc.path,endpoint:arc.endpoint,id,ts,requestedAtUtc:ts,receivedAtUtc:ts,method,params,
      anchor,blockAnchor,request,response,requestBase64:request,responseBase64:response});
  }
  const blocks=new Map();
  function block(number,timestamp,transactions=[]) {
    const anchor={number:hex(number),hash:hash(number)};
    const result={...anchor,timestamp:hex(timestamp),transactions,baseFeePerGas:hex(pc.feeRule.baseFee)};
    blocks.set(String(number),result);
    return {anchor,result,passport:{number:String(number),hash:anchor.hash,timestamp:String(timestamp)}};
  }
  const readBlock=(i,b)=>append(i,'eth_getBlockByNumber',[b.anchor.number,false],b.result,b.anchor);
  function archiveCalls(i,anchor,calls) {
    const groups=new Map();
    for(const c of calls) {
      const key=c.to.toLowerCase()+c.data;
      if(!groups.has(key)) groups.set(key,{...c,words:[]});
      const type=c.type??'uint256', value=type==='uint256'||type==='int256'?BigInt(c.expected):c.expected;
      groups.get(key).words[c.index]=encodeAbiParameters([{type}],[value]).slice(2);
    }
    for(const {to,data,words} of groups.values()) {
      append(i,'eth_call',[{to,data},anchor.number],'0x'+Array.from(words,w=>w??'0'.repeat(64)).join(''),anchor);
    }
  }

  const deposit=Object.fromEntries(arms.map(arm=>[arm,10n**19n]));
  const operatorStart=BigInt(legacy[0].passport.volatile.operatorBalance);
  let operatorBalance=operatorStart;
  const invariants=new Map(accounts.map(sender=>{
    const {frozen,plan}=adapters.get(sender);
    const i=structuredClone(legacy[0].passport.invariant);
    Object.assign(i,{entryPoint:{address:entryPoint,isCanonicalV07Address:false},sender,bundler,beneficiary:bundler,verifyingSigner,
      armEntryPoints:Object.fromEntries([...arms,'account'].map(k=>[k,entryPoint])),gas:frozen.gas,pmGas:frozen.pmGas,callDataHash:keccak256(frozen.callData),
      credit:{policy:0,hasPendingPolicy:false,pendingPolicy:0,pendingPolicyEta:0,policyEpoch:0}});
    Object.assign(i.superPaymaster,{entryPoint,registry:plan.addresses.registry,aPNTs:plan.addresses.aPNTs,minPostOpGas:pc.gasTuple[0]});
    i.superPaymaster.priceStalenessThreshold=priceStalenessThreshold;
    i.superPaymaster.cachedPrice.price=String(BigInt(i.superPaymaster.cachedPrice.price)+priceDelta);
    if(version!==undefined) i.superPaymaster.version=version;
    if(priceDecimals!==undefined) i.superPaymaster.cachedPrice.decimals=priceDecimals;
    Object.assign(i.superPaymaster.operator,{address:operator,xPNTsToken:token,minTxInterval:pc.minTxInterval});
    Object.assign(i.xPNTs,{address:token,superPaymaster:addresses.SP});
    const codeAddresses={entryPoint,account:sender,superPaymasterProxy:addresses.SP,xPNTsClone:token,accountImpl:input.accountImplementation,
      verifyingPaymaster:addresses.VPM,tokenPaymaster:addresses.TPM,tokenPaymasterToken:addresses.Q,tokenPaymasterOracle:addresses.oracle};
    for(const [name,address] of Object.entries(codeAddresses)) i.code[name]={address};
    for(const stake of Object.values(i.stakes)) Object.assign(stake,{staked:true,stake:'1000000000000000000',unstakeDelaySec:86400});
    return [sender,i];
  }));
  const codeBytes=(name,i)=>name==='xPNTsClone'
    ? '0x363d3d373d3d3d363d73'+i.code.xPNTsImpl.address.slice(2).toLowerCase()+'5af43d82803e903d91602b57fd5bf3' : '0x6000';
  for(const i of invariants.values()) for(const [name,code] of Object.entries(i.code)) {
    const bytes=codeBytes(name,i);Object.assign(code,{codehash:keccak256(bytes),size:(bytes.length-2)/2});
  }
  function passport(sender,b) {
    const invariant=invariants.get(sender);
    return json({allowSameEndpointLocal:false,chainId,block:b.passport,invariant,
      volatile:{cachedPriceUpdatedAt:epoch,operatorBalance,
        depositInfo:Object.fromEntries(arms.map(arm=>[arm,{deposit:deposit[arm],...invariant.stakes[arm]}]))}});
  }
  function savePassport(name,p,b,{read=true}={}) {
    const path='passports/'+name+'.json', inv=p.invariant;
    writeArtifact(dir,path,p);
    if(read) for(const i of [0,1]) {
      append(i,'eth_chainId',[],hex(chainId));
      readBlock(i,b);
      for(const [name,code] of Object.entries(inv.code)) append(i,'eth_getCode',[code.address,b.anchor.number],codeBytes(name,inv),b.anchor);
      for(const [proxy,impl] of [['superPaymasterProxy','superPaymasterImpl'],['account','accountImpl']]) {
        append(i,'eth_getStorageAt',[inv.code[proxy].address,IMPL_SLOT,b.anchor.number],addressTopic(inv.code[impl].address),b.anchor);
      }
      archiveCalls(i,b.anchor,passportCalls(p));
    }
    return {path,raw:pairs(i=>refs(archives[i].records.filter(r=>r.method==='eth_chainId' ||
      r.blockAnchor?.number===p.block.number && r.blockAnchor.hash===p.block.hash &&
      ['eth_call','eth_getCode','eth_getStorageAt','eth_getBlockByNumber'].includes(r.method))))};
  }
  for(const i of [0,1]) append(i,'eth_getTransactionCount',[bundler,'pending'],hex(pending));
  const starts=new Map(accounts.map(sender=>{
    const b=block(blockNumber++,epoch), p=passport(sender,b);
    return [sender,{p,ref:savePassport('start-'+sender,p,b)}];
  }));
  const start={...head,kind:'run_start',formal:true,rehearsal:false,protocolConformant:true,fixture:null,rpcA:'https://a.invalid',rpcB:'https://b.invalid',
    allowSameEndpointLocal:false,count:manifest.targetTriplets,maxAttempts:slice.slots,bMax:1,arms,passport:starts.get(first.sender).p,
    frozenConfig:json(frozenConfig),configSha256:configPin.sha256,deploymentConfigSha256:deploymentPin.sha256,baselineConfigSha256:baselinePin.sha256,pins,rpcIdentity};
  savePassport('start',start.passport,null,{read:false});

  const nonces=new Map(accounts.map((sender,i)=>[sender,BigInt(13+i*7+(windowIndex-1)*(slice.slots-1)+nonceOffset)])), allocations=new Map(), lastSP=new Map();
  const spData=legacy[1].readbacks.before.A;
  const spShared=Object.fromEntries(Object.entries(spData).filter(([key])=>!senderFields.includes(key)));
  const spUsers=new Map(accounts.map((sender,i)=>[sender,{...Object.fromEntries(senderFields.map(k=>[k,spData[k]])),
    userXPNTs:String(BigInt(spData.userXPNTs)+BigInt(i)*10n**18n)}]));
  const tpmUsers=new Map(accounts.map((sender,i)=>[sender,1000+i])), tpmHoldings={paymaster:500};
  spShared.totalSupply=String([...spUsers.values()].reduce((sum,user)=>sum+BigInt(user.userXPNTs),0n));
  for(const slot of schedule.payload.slots.slice(0,slice.firstSlot)) for(const name of slot.order) {
    const key=slot.senders[name]+':'+names[name];
    allocations.set(key,(allocations.get(key)??0)+1);
  }
  const submitPin=block(blockNumber++,epoch);
  const expired=block(blockNumber++,epoch+BigInt(missedSlot.deadline_seconds-missedSlot.start_seconds)+1n);
  const expiredReads=new Set(), tally=Object.fromEntries(arms.map(arm=>[arm,{attempts:0,verdicts:{}}]));
  const seenTpmSenders=new Set();
  let brokenBalance=false;
  for(const slot of usedSlots) {
    const sent=slot.block_slot>=firstSent, armOrder=slot.order.map(name=>names[name]), attempts=[];
    const vpmVerdict=slot.block_slot===slice.lastSlot?finalVpmVerdict:'USEROP_SUCCESS';
    const startTime=epoch+BigInt(slot.start_seconds-missedSlot.start_seconds), deadline=epoch+BigInt(slot.deadline_seconds-missedSlot.start_seconds);
    for(const [position,name] of slot.order.entries()) {
      const sender=slot.senders[name], arm=names[name], adapter=adapters.get(sender), attemptIndex=rows.length, key=sender+':'+arm;
      const submitGate=attemptIndex===0;
      const allocation=allocations.get(key)??0;
      allocations.set(key,allocation+1);
      clock+=1000;
      const a={...head,...adapter.row(arm,allocation),kind:'attempt',attemptIndex,tripletIndex:slot.block_slot,block_slot:slot.block_slot,pair_id:slot.pair_id,
        seed:schedule.payload.seed,schedule_sha256:schedule.sha256,arm,armOrder,sender,warmup:false,fixture:null,
        spBranch:arm==='SP'?{planned:'balance',observed:null,event:null}:null,
        stateTargets:{superPaymaster:addresses.SP,token,tpmToken:addresses.Q,operator},
        evidenceStart:archives.map(arc=>arc.records.length)};
      const time=sent?startTime+BigInt(position*5):BigInt(expired.passport.timestamp);
      const pinBlock=sent?block(blockNumber++,time):submitGate?submitPin:expired;
      a.passport=passport(sender,pinBlock);
      if(lastTx) a.priorInclusionHeads=[pinBlock.passport.number,pinBlock.passport.number];
      const attemptRef=savePassport('attempt-'+attemptIndex,a.passport,pinBlock,{read:sent||submitGate||!expiredReads.has(sender)});
      if(pinBlock===expired) expiredReads.add(sender);
      const minTxInterval=arm==='SP'?BigInt(pc.minTxInterval):0n, lastTimestamp=arm==='SP'?lastSP.get(sender)??0n:0n;
      const beforeBlock=sent?block(blockNumber++,time+1n):null;
      const waitAt=(b,elapsed=0n)=>({seconds:elapsed,blocks:elapsed,minTxInterval,lastTimestamp,validAfter:lastTimestamp+minTxInterval,
        timestamp:BigInt(b.passport.timestamp),pin:{number:b.passport.number,hash:b.anchor.hash},start:startTime,deadline});
      const gate=sent?{allowed:true,wait:waitAt(beforeBlock)}:{allowed:false,reason:'slot_deadline_exceeded',wait:waitAt(expired)};
      a.slotChecks=sent||submitGate?[{allowed:true,wait:waitAt(pinBlock,sent&&arm==='SP'?1n:0n)},gate]:[gate];
      if(arm==='SP') a.spWait=a.slotChecks.reduce((prev,{wait})=>({...wait,
        seconds:(prev?.seconds??0n)+wait.seconds,blocks:(prev?.blocks??0n)+wait.blocks}),null);
      if(!sent) Object.assign(a,{sent:false,tx:null,verdict:'NOT_SENT',failingCheck:gate.reason,scheduleDisposition:gate.reason});
      if(sent || submitGate) {
        const paymaster=addresses[arm], {frozen}=adapter, gas={...frozen.gas[arm]}, pmGas=frozen.pmGas[arm];
        let nonce=nonces.get(sender);
        if(nonceGap && sender===accounts[1] && slot.block_slot===firstSent+1) nonce++;
        if(sent) nonces.set(sender,nonce+1n);
        const lengths=adapter.plan.phaseC.pvgLengths[arm], u128=v=>toHex(v,{size:16}).slice(2);
        const paymasterTail=arm==='SP'?operator.slice(2)+'ff'.repeat(32)+token.slice(2)+'00':'00'.repeat(lengths.paymasterAndData-52);
        const {packed,pvg}=await finalizePVG(async preVerificationGas=>({packed:{
          sender,nonce,initCode:'0x',callData:frozen.callData,accountGasLimits:'0x'+u128(gas.verificationGasLimit)+u128(gas.callGasLimit),
          preVerificationGas,gasFees:'0x'+u128(gas.maxPriorityFeePerGas)+u128(gas.maxFeePerGas),signature:'0x'+'11'.repeat(65),
          paymasterAndData:paymaster+u128(pmGas.ver)+u128(pmGas.post)+paymasterTail
        }}),bundler,{lengths,reserve:adapter.plan.phaseC.pvgReserve[arm]});
        gas.preVerificationGas=pvg.value;
        const opHash=localUserOpHash(packed,entryPoint,chainId);
        Object.assign(a,{chainId,entryPoint,bundler,nonce,paymaster,callDataHash:keccak256(packed.callData),packedOp:packed,bundledOps:[packed],gas,pmGas,
          expectedUserOpHash:opHash,epUserOpHash:opHash,localUserOpHash:opHash,bundledUserOpHashes:[opHash],guard:{allowed:true}});
        recordPVG(a,pvg);
      }
      if(sent) {
        const {nonce,packedOp:packed,gas,pmGas,paymaster,expectedUserOpHash:opHash}=a;
        const pvg=a.gasSources.preVerification;
        const txId=hash(10000+blockStart+attemptIndex), txBlock=block(blockNumber++,time+2n,[txId]);
        const template=legacy.find(row=>row.arm===arm), gasUsed=BigInt(template.userOpEvent.actualGasUsed);
        const gasPrice=BigInt(pc.feeRule.baseFee)+gas.maxPriorityFeePerGas, gasCost=gasUsed*gasPrice;
        const verdict=arm==='VPM'?vpmVerdict:'USEROP_SUCCESS';
        const txReverted=verdict==='TX_FAILED';
        const event=txReverted || verdict==='NO_EVENT'?null:{
          userOpHash:opHash,sender,paymaster,nonce,success:verdict==='USEROP_SUCCESS',actualGasUsed:gasUsed,actualGasCost:gasCost};
        const spState=()=>({...spShared,...spUsers.get(sender)}), tpmState=()=>({tpmTokenBalances:{sender:String(tpmUsers.get(sender)),paymaster:String(tpmHoldings.paymaster)},tpmCachedPriceTimestamp:String(epoch)});
        const readback=b=>({...arm==='SP'?spState():arm==='TPM'?tpmState():{},blockNumber:b.passport.number,blockHash:b.anchor.hash,
          epDeposit:String(deposit[arm]),operatorBalance:String(operatorBalance)});
        if(arm==='TPM') {
          if(senderBalanceGap && seenTpmSenders.has(sender)) tpmUsers.set(sender,tpmUsers.get(sender)+1);
          seenTpmSenders.add(sender);
        }
        const before=readback(beforeBlock);
        const logs=event?template.logs.map(l=>({...l,transactionHash:txId})):[];
        const uoe=logs.at(-1);
        if(event) Object.assign(uoe,{address:entryPoint,topics:[uoe.topics[0],opHash,addressTopic(sender),addressTopic(paymaster)],
          data:words(nonce,event.success?1n:0n,gasCost,gasUsed)});
        for(const log of logs.slice(0,-1)) if(log.address===template.entryPoint) log.address=entryPoint;
        if(arm==='SP') {
          const required=gas.callGasLimit+gas.verificationGasLimit+pvg.value+pmGas.ver+pmGas.post;
          const sp=a.passport.invariant.superPaymaster, fee=BigInt(sp.protocolFeeBPS);
          const convert=v=>ceil(v*BigInt(sp.cachedPrice.price)*10n**18n,10n**BigInt(sp.cachedPrice.decimals)*BigInt(sp.aPNTsPriceUSD));
          const a0=ceil(convert(required*gas.maxFeePerGas)*(11000n+fee),10000n);
          const aGas=convert(400000n*gasPrice), charge=ceil(aGas*(10000n+fee),10000n);
          const [,,burn,settle,sponsor]=logs;
          Object.assign(logs[0],{address:token,topics:[logs[0].topics[0],addressTopic(sender),opHash,addressTopic(paymaster)],data:words(a0,a0)});
          Object.assign(burn,{address:token,topics:[burn.topics[0],addressTopic(sender),burn.topics[2]],data:words(charge)});
          Object.assign(settle,{address:token,topics:[settle.topics[0],addressTopic(sender),opHash],data:words(charge,charge)});
          Object.assign(sponsor,{address:paymaster,topics:[sponsor.topics[0],addressTopic(operator),addressTopic(sender)],data:words(aGas,charge)});
          operatorBalance-=charge;
          for(const [field,delta] of Object.entries({totalSpent:a0,totalTxSponsored:1n,protocolRevenue:charge,totalSupply:-charge})) {
            spShared[field]=String(BigInt(spShared[field])+delta);
          }
          const user=spUsers.get(sender);
          user.userXPNTs=String(BigInt(user.userXPNTs)-charge);
          lastSP.set(sender,time+2n);
        } else if(arm==='TPM') {
          for(const log of logs.slice(0,-1)) {
            if(log.address===template.paymaster) log.address=paymaster;
            else if(log.address!==entryPoint) {log.address=addresses.Q;log.topics=[log.topics[0],addressTopic(sender),addressTopic(paymaster)];}
          }
          tpmUsers.set(sender,tpmUsers.get(sender)-1);
          tpmHoldings.paymaster++;
        }
        if(event) deposit[arm]-=gasCost;
        const after=readback(txBlock);
        if(balanceGap && !brokenBalance && lastTx && lastTx.sender!==sender && arm!=='SP') {
          before.operatorBalance=after.operatorBalance=String(BigInt(before.operatorBalance)+1n);
          brokenBalance=true;
        }
        const input=encodeFunctionData({abi:bundleAbi,functionName:'handleOps',args:[[packed],bundler]});
        const tx={hash:txId,input,from:bundler,status:txReverted?'reverted':'success',blockNumber:txBlock.passport.number,blockHash:txBlock.anchor.hash,blockTimestamp:txBlock.passport.timestamp,
          gasLimit:BigInt(adapter.plan.phaseC.bounds[arm].outer)+(slot.block_slot===firstSent && sender===accounts[1]?outerGasDelta:0n),
          ...adapter.frozen.fees,handleOpsIndex:0,blockTxCount:1,headBefore:beforeBlock.passport.number,
          gasUsed:template.tx.gasUsed,effectiveGasPrice:gasPrice};
        const archivedTx={...template.tx.raw,type:'0x2',chainId:hex(chainId),nonce:hex(pending),value:'0x0',transactionIndex:'0x0',v:'0x1',
          r:hash(1),s:hash(2),accessList:[],gasPrice:hex(gasPrice),to:entryPoint,from:bundler,hash:txId,input,gas:hex(tx.gasLimit),
          maxFeePerGas:hex(tx.maxFeePerGas),maxPriorityFeePerGas:hex(tx.maxPriorityFeePerGas),blockNumber:txBlock.anchor.number,blockHash:tx.blockHash};
        tx.raw=formatTransaction(archivedTx);
        const receipt={transactionHash:txId,blockNumber:txBlock.anchor.number,blockHash:tx.blockHash,status:txReverted?'0x0':'0x1',gasUsed:hex(tx.gasUsed),
          effectiveGasPrice:hex(gasPrice),logs:logs.map(l=>({...l,logIndex:hex(l.logIndex)}))};
        const failingCheck={TX_FAILED:'receipt_status',NO_EVENT:'user_operation_event_present',USEROP_REVERTED:'user_operation_success'}[verdict]??null;
        Object.assign(a,{sent:true,tx,logs,receipt,userOpEvent:event?{...event,logIndex:uoe.logIndex}:null,
          observedUserOpEvent:event?{...event,logIndex:uoe.logIndex,txHash:txId}:null,verdict,failingCheck,
          revertKind:event?.success===false?'executionReverted':null,execRevert:[],postOpRevert:[],prefundTooLow:[],
          readbacks:{before:pairs(()=>before),after:pairs(()=>after)},conservation:{evaluated:!!event,ok:event?true:null,checks:[]},exclusion:failingCheck});
        if(arm==='SP') a.spBranch={planned:'balance',observed:'balance',event:'LockSettled'};
        if(arm==='TPM') Object.assign(a,{tpmOracle:addresses.oracle,postOpRefreshed:false,traces:[0,1].map(()=>({
          call:{type:'CALL',to:entryPoint,calls:[{type:'CALL',to:paymaster,input:toFunctionSelector('postOp(uint8,bytes,uint256,uint256)'),calls:[]}]},
          state:{pre:{[entryPoint]:{storage:{'0x0':'0x1'}}},post:{[entryPoint]:{storage:{'0x0':'0x2'}}}},postOpRefreshed:false
        }))});
        recordPVG(a,pvg,input,{gasUsed:tx.gasUsed,effectiveGasPrice:gasPrice},event);
        for(const i of [0,1]) {
          if(lastTx) append(i,'eth_blockNumber',[],hex(pinBlock.passport.number));
          append(i,'eth_blockNumber',[],hex(tx.headBefore));
          append(i,'eth_getTransactionCount',[bundler,'pending'],hex(pending));
          if(i===0) append(i,'eth_sendRawTransaction',['0x01'],txId);
          append(i,'eth_getTransactionReceipt',[txId],receipt,txBlock.anchor);
          readBlock(i,txBlock);
          append(i,'eth_getTransactionByHash',[txId],archivedTx,txBlock.anchor);
          if(a.traces) for(const [tracer,key] of [['callTracer','call'],['prestateTracer','state']]) {
            append(i,'debug_traceTransaction',[txId,{tracer,tracerConfig:tracer==='callTracer'?{withLog:true}:{diffMode:true}}],a.traces[i][key],txBlock.anchor);
          }
          for(const [b,s] of [[beforeBlock,before],[txBlock,after]]) {
            readBlock(i,b);
            const fields={entryPointDeposit:s.epDeposit,operatorBalance:s.operatorBalance,...(arm==='SP'?{
              protocolRevenue:s.protocolRevenue,inflightOf:{operator:s.inflightOperator,a0:s.inflightA0},userXPNTs:s.userXPNTs,totalSupply:s.totalSupply,
              lockedOf:s.lockedOf,debts:s.debts,creditReservedOf:s.creditReservedOf,operatorTotalSpent:s.totalSpent,operatorTotalTxSponsored:s.totalTxSponsored
            }:arm==='TPM'?{tpmTokenBalances:s.tpmTokenBalances,tpmCachedPriceTimestamp:s.tpmCachedPriceTimestamp}:{vpmDeposit:s.epDeposit})};
            archiveCalls(i,b.anchor,Object.entries(fields).flatMap(([key,v])=>stateCalls(a,key,v)));
          }
        }
        lastTx={sender,time:time+2n};pending++;
      }
      a.collectedAtUtc=now();
      a.evidenceEnd=archives.map(arc=>arc.records.length);
      const r=evidenceIndex(a,{schedule:true,windowId:head.runId,archives,pins,rpcIdentity,passports:{start:starts.get(sender).ref,attempt:attemptRef},stopReason:null});
      Object.assign(r,Object.fromEntries(scheduleFields.map(key=>[key,a[key]])));
      index.push(r);rows.push(json(a));attempts.push(attemptIndex);
      tally[arm].attempts++;
      tally[arm].verdicts[a.verdict]=(tally[arm].verdicts[a.verdict]??0)+1;
    }
    triplets.push({block_slot:slot.block_slot,pair_id:slot.pair_id,matched:sent&&vpmVerdict==='USEROP_SUCCESS',attempts,tripletIndex:slot.block_slot});
  }
  const endChecks=['endBlock',...accounts.map(sender=>'senderPassport:'+sender),'finalPassport','anchors'].map(check=>({check,status:'PASS'}));
  let endTime=lastTx.time;
  for(const sender of accounts) {
    const b=block(blockNumber++,++endTime);
    savePassport('end-'+sender,passport(sender,b),b);
  }
  const finalBlock=block(blockNumber++,++endTime), final=passport(first.sender,finalBlock);
  const endPassport=savePassport('end',final,finalBlock);
  clock+=1000;
  const anchors=[...blocks.values()].map(({number,hash})=>({number:String(BigInt(number)),hash}));
  const finalBlockCheck={anchors,raw:pairs(i=>anchors.map(anchor=>{
    const b=blocks.get(anchor.number);
    append(i,'eth_getBlockByNumber',[b.number,false],b,anchor);
    return refs(archives[i].records.slice(-1))[0];
  }))};
  const matchedTriplets=triplets.filter(t=>t.matched).length;
  const window={...windowRecord(manifest,{status:'EXHAUSTED',slots:triplets,complete:matchedTriplets,unusedSlots:[]}),
    targetTriplets:manifest.targetTriplets};
  const end={...head,kind:'run_end',rehearsal:false,stop:{reason:'EXHAUSTED',code:0},exitCode:0,endChecks,endCheckScope:'on every in-process exit (not on SIGINT/SIGTERM/SIGKILL)',
    matchedTriplets,targetTriplets:manifest.targetTriplets,scheduledSlots:slice.slots,attemptedSlots:triplets.length,
    warmupAttempts:0,tally,triplets,window,passport:final,finalBlockCheck};
  const triples=triplets.map(t=>({tripleIndex:t.tripletIndex,attempts:t.attempts,included:t.matched}));
  const trailer={schemaVersion:'a6-evidence-trailer/1',rehearsal:false,windowId:head.runId,void:false,stopReason:'EXHAUSTED',
    stopAttempt:rows.length-1,endPassport,finalBlockCheck,endChecks,endCheckScope:end.endCheckScope,triples,replacements:[],
    counts:armCounts(index,triples,[]),window};
  // Buffer synthetic RPC evidence to avoid a disk sync for every fake response.
  for(const {endpoint,path,records} of archives) {
    mkdirSync(join(dir,'raw',endpoint),{recursive:true});
    writeFileSync(join(dir,path),records.map(({path,...record})=>stringify(record)).join('\n')+'\n');
  }
  writeFileSync(join(dir,'index.ndjson'),index.map(stringify).join('\n')+'\n');
  writeTrailer(dir,trailer);
  const runPath=join(dir,'run.jsonl');
  writeFileSync(runPath,[start,...rows,end].map(stringify).join('\n')+'\n');
  return {runPath,accounts,rows,end,trailer,registered};
}
