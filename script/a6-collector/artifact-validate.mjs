import { bindArchivedDisposition, bindReceiptSummaries } from './derived-evidence.mjs';
import { verifyPassport, verifyPassportIdentity } from './passport-evidence.mjs';
import { stateCalls, supportsCall, archivedParamsAllowed } from './state-evidence.mjs';
import { readFileSync, realpathSync, readdirSync } from 'node:fs';
import { resolve, isAbsolute } from 'node:path';
import { evidenceIndex, sha256, stringify, loadRegistry, replacementReason, bindPreflight } from './evidence.mjs';
import { formalConfig, armOrder, DEFAULT_FACTORY, inclusionErrors } from './formal.mjs';
import { formatTransaction, decodeFunctionData, parseAbi, toFunctionSelector, encodeAbiParameters } from 'viem';
import { tpmAttemptRefreshed } from './trace-policy.mjs';

// Receipt/transaction polls of one endpoint, in archive order. Polls made before inclusion stay referenced (the index
// is complete) and return a null receipt or a pending transaction (blockHash null). They may only precede the first
// included observation; every included observation must match the recorded block; a sent attempt needs at least one.
export function inclusionSeriesError(observations, tx) {
  let seenIncluded=false, lastId=-Infinity;
  for (const { id, result } of observations) {
    if (!(id>lastId)) return 'endpoint raw references out of order';
    lastId=id;
    const pending=!result || result.blockHash==null;
    if (pending) { if (seenIncluded) return 'raw inclusion regressed after inclusion'; continue; }
    if (String(result.blockHash).toLowerCase()!==String(tx.blockHash).toLowerCase() || BigInt(result.blockNumber)!==BigInt(tx.blockNumber)) return 'raw inclusion mismatch';
    seenIncluded=true;
  }
  return seenIncluded ? null : 'raw inclusion missing';
}

const canonical=v=>Array.isArray(v)?v.map(canonical):v && typeof v==='object'?Object.fromEntries(Object.keys(v).sort().map(k=>[k,canonical(v[k])])):typeof v==='string' && v.startsWith('0x')?v.toLowerCase():typeof v==='bigint'?String(v):v;
const eq=(a,b)=>JSON.stringify(canonical(a))===JSON.stringify(canonical(b));
const READ_ONLY_METHODS = new Set(['eth_chainId','eth_blockNumber','eth_getBlockByNumber','eth_getBlockByHash','eth_getTransactionByHash','eth_getTransactionReceipt','eth_getTransactionCount','eth_getBalance','eth_getCode','eth_getStorageAt','eth_getProof','eth_call','eth_estimateGas','eth_getLogs','eth_gasPrice','eth_maxPriorityFeePerGas','eth_feeHistory','debug_traceTransaction','web3_clientVersion','net_version']);
function archivedMethodAllowed(raw,journal,trailer) {
  if (READ_ONLY_METHODS.has(raw.method) || raw.method==='eth_sendRawTransaction') return true;
  if (journal?.[0]?.rehearsal!==true || trailer.rehearsal!==true || !['anvil_setStorageAt','evm_mine'].includes(raw.method)) return false;
  // Control requests must be inside this endpoint's attempt archive interval and the
  // inclusive block interval [control.atBlock, readbacks.before.blockNumber].
  return journal.some(a=>{
    const c=a.rehearsalControl, endpoint=raw.endpoint==='A'?0:1;
    if (a.kind!=='attempt' || a.arm!=='TPM' || c?.kind!=='tpmCacheAged' || !raw.blockAnchor || !(raw.id>a.evidenceStart?.[endpoint] && raw.id<=a.evidenceEnd?.[endpoint])) return false;
    return BigInt(raw.blockAnchor.number)>=BigInt(c.atBlock) && BigInt(raw.blockAnchor.number)<=BigInt(a.readbacks.before[raw.endpoint].blockNumber);
  });
}
const lower=x=>String(x).toLowerCase();
export const bundleAbi=parseAbi(['function handleOps((address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData,bytes signature)[] ops,address beneficiary)']);
export function transactionErrors(row, config) {
  const errors=[];
  try {
    const frozen=formalConfig(config,1);
    if (lower(row.packedOp.callData)!==lower(frozen.callData)) errors.push('frozen task calldata mismatch');
    if (row.tx) {
      const decoded=decodeFunctionData({abi:bundleAbi,data:row.tx.input});
      if (decoded.functionName!=='handleOps' || !eq(JSON.parse(stringify(decoded.args[0])),row.bundledOps) || !eq(row.bundledOps[row.tx.handleOpsIndex],row.packedOp)) errors.push('transaction bundle/index mismatch');
      if (lower(decoded.args[1])!==lower(config.accounts.bundler.address)) errors.push('transaction beneficiary mismatch');
      for (const k of ['maxFeePerGas','maxPriorityFeePerGas']) if (BigInt(row.tx[k])>BigInt(config.fees[k]) || BigInt(row.tx[k])<0n) errors.push('outer transaction fee cap exceeded');
      if (BigInt(row.tx.gasLimit)>BigInt(config.bundlerGasLimit) || BigInt(row.tx.gasLimit)<=0n) errors.push('outer transaction gas limit exceeded');
    }
  } catch { errors.push('invalid transaction/config evidence'); }
  return errors;
}
export function artifactErrors(window,rows,trailer,journal) {
  const errors=[], cache=new Map(), archives=[{records:[]},{records:[]}];
  const fail=s=>errors.push(s);
  const local=path=>{
    const absolute=resolve(window,path);
    if (!absolute.startsWith(resolve(window)+'/') || realpathSync(absolute)!==absolute) throw new Error('artifact escapes window or symlink');
    return absolute;
  };
  const file=path=>readFileSync(local(path));
  const pin=p=>{
    if (!p?.path || !/^[a-f0-9]{64}$/.test(p.sha256)) throw new Error('missing pin');
    const bytes=isAbsolute(p.path)?readFileSync(p.path):file(p.path);
    if (sha256(bytes)!==p.sha256) throw new Error('artifact hash mismatch');
  };
  function reference(ref,endpoint) {
    if (!ref || !Number.isSafeInteger(ref.id)) throw new Error('invalid raw reference');
    if (!cache.has(ref.path)) {
      const records=file(ref.path).toString().trim().split('\n').filter(Boolean).map(JSON.parse);
      cache.set(ref.path,records);
      for (const r of records) {
        if (!archivedMethodAllowed(r,journal,trailer)) throw new Error(`archived RPC method forbidden or outside rehearsal control range: ${r.method}`);
        if (r.method==='debug_traceTransaction' && !['callTracer','prestateTracer'].some(tracer=>eq(r.params[1],{tracer,tracerConfig:tracer==='callTracer'?{withLog:true}:{diffMode:true}}))) throw new Error('TPM raw trace missing or inconsistent: exact tracer config required');
        if (r.credentialFlag) throw new Error('credential flagged archive');
        if (r.request!==r.requestBase64 || r.response!==r.responseBase64) throw new Error('archive byte aliases disagree');
        const request=JSON.parse(Buffer.from(r.request,'base64').toString());
        if (request.method!==r.method || !eq(request.params,r.params)) throw new Error('raw request metadata mismatch');
        if (!archivedParamsAllowed(r)) throw new Error(`archived RPC params invalid: ${r.method}`);
        if (r.blockAnchor && r.anchor && (BigInt(r.blockAnchor.number)!==BigInt(r.anchor.number) || r.blockAnchor.hash!==r.anchor.hash)) throw new Error('raw anchor metadata mismatch');
        const fixed={eth_call:1,eth_getCode:1,eth_getBalance:1,eth_getStorageAt:2,eth_getTransactionCount:1}[r.method];
        if (fixed!==undefined && (!r.blockAnchor || BigInt(r.params[fixed])!==BigInt(r.blockAnchor.number))) throw new Error('raw fixed block mismatch');
        if (r.response) {
          const response=JSON.parse(Buffer.from(r.response,'base64').toString());
          if (r.method==='eth_getBlockByNumber' && response.result && (!r.blockAnchor || response.result.hash!==r.blockAnchor.hash || BigInt(response.result.number)!==BigInt(r.blockAnchor.number) || (/^0x/.test(r.params[0]) && BigInt(r.params[0])!==BigInt(response.result.number)))) throw new Error('raw block response mismatch');
          if (response.id!==request.id) throw new Error('raw response identity mismatch');
        }
        if (!['A','B'].includes(r.endpoint)) throw new Error('invalid raw endpoint');
        archives[r.endpoint==='A'?0:1].records.push({...r,path:ref.path});
      }
    }
    const matches=cache.get(ref.path).filter(r=>r.id===ref.id);
    if (matches.length!==1 || matches[0].endpoint!==endpoint) throw new Error('raw reference does not resolve uniquely on endpoint');
    return matches[0];
  }
  function walk(value,endpoint) {
    if (!value || typeof value!=='object') return;
    if ('path' in value && 'id' in value) { reference(value,endpoint); return; }
    for (const [key,v] of Object.entries(value)) walk(v,['A','B'].includes(key)?key:endpoint);
  }
  try {
    for (const endpoint of ['A','B']) for (const name of readdirSync(local('raw/'+endpoint)).sort()) {
      if (!/^\d{8}\.ndjson$/.test(name)) throw new Error('invalid raw date file');
      const path=`raw/${endpoint}/${name}`,first=JSON.parse(file(path).toString().trim().split('\n')[0]);
      reference({path,id:first.id},endpoint);
    }
    for (const r of rows) { walk(r); for (const category of ['collector','validator','dependencies','contractSources','abi','config']) {
      if (!r.pins?.[category]?.length) throw new Error('required pins missing');
      r.pins[category].forEach(pin);
    } pin(r.rpcIdentity); loadRegistry(local(r.rpcIdentity.path));
      for (const p of Object.values(r.passports)) if (p) JSON.parse(file(p.path));
    }
    walk(trailer.finalBlockCheck);
    walk(trailer.endPassport); JSON.parse(file(trailer.endPassport.path));
    for (const arc of archives) {
      let previous=-1;
      for (const raw of [...arc.records].sort((a,b)=>a.path.localeCompare(b.path))) {
        if (!Number.isSafeInteger(raw.id) || raw.id<=previous) throw new Error('raw ids must be globally strictly increasing per endpoint (cannot resolve uniquely)');
        previous=raw.id;
      }
    }
  } catch(e) { fail(`artifact verification: ${e.message}`); }
  if (!journal) { fail('formal artifact verification requires journal'); return errors; }
  const attempts=journal.filter(r=>r.kind==='attempt'), start=journal[0];
  try {
    const chainId=BigInt(start.passport.chainId);
    if (!Number.isSafeInteger(start.frozenConfig?.chainId) || start.frozenConfig.chainId <= 0) throw new Error('target chainId required');
    if (start.rehearsal === true ? chainId !== 31337n : chainId === 31337n) throw new Error('formal/rehearsal chainId policy mismatch');
    if (start.rehearsal !== true && chainId !== BigInt(start.frozenConfig.chainId)) throw new Error('formal target chainId mismatch');
    const configPin=start.pins.config.find(p=>p.sha256===start.configSha256);
    if (!configPin) throw new Error('frozen config hash is not pinned');
    const frozen=JSON.parse(isAbsolute(configPin.path)?readFileSync(configPin.path):file(configPin.path));
    frozen.factory ??= DEFAULT_FACTORY;
    if (!eq(frozen,start.frozenConfig)) throw new Error('frozen config differs from pinned file');
    for (const key of ['deploymentConfigSha256','baselineConfigSha256']) if (!start.pins.config.some(p=>p.sha256===start[key])) throw new Error('deployment/baseline config hash is not pinned');
  } catch(e) { fail(e.message); }
  const pinnedConfig=hash=>{const pin=start.pins.config.find(p=>p.sha256===hash);return JSON.parse(isAbsolute(pin.path)?readFileSync(pin.path):file(pin.path));};
  const included=new Set(trailer.triples.filter(t=>t.included).flatMap(t=>t.attempts));
  errors.push(...inclusionErrors(attempts));
  for (const edge of trailer.replacements ?? []) {
    if (!attempts.filter(a=>a.tripletIndex===edge.abandoned.tripleIndex).some(a=>{
      try { return replacementReason(a,archives)===edge.reason; } catch { return false; }
    })) fail('unsupported replacement exclusion reason: raw-bound abandoned evidence required');
  }
  const windowTransactions=new Set(attempts.filter(a=>a.sent && a.tx).map(a=>lower(a.tx.hash)));
  for (const arc of archives) for (const raw of arc.records) if (['eth_getBlockByNumber','eth_getBlockByHash'].includes(raw.method) && raw.response) {
    const block=JSON.parse(Buffer.from(raw.response,'base64').toString()).result;
    if (block?.transactions?.filter(tx=>windowTransactions.has(lower(typeof tx==='string'?tx:tx.hash))).length>1) fail('more than one handleOps from window in archived block');
  }
  let previousIncluded=null;
  let lastTime=-Infinity, lastSendId=-1;
  const previousEnd=[0,0];
  for (let i=0;i<rows.length;i++) try {
    const r=rows[i], a=attempts[i];
    if (!a) throw new Error('missing journal attempt');
    for (const [endpoint,arc] of archives.entries()) {
      const startId=a.evidenceStart?.[endpoint], endId=a.evidenceEnd?.[endpoint];
      if (!Number.isSafeInteger(startId) || !Number.isSafeInteger(endId) || startId<previousEnd[endpoint] || endId<startId || endId>arc.records.reduce((max,r)=>Math.max(max,r.id),0)) throw Error('invalid attempt evidence id range');
      previousEnd[endpoint]=endId;
    }
    const preflightErrors=archives[0].records.filter(raw=>raw.id>a.evidenceStart?.[0] && raw.id<=a.evidenceEnd?.[0] && raw.method==='eth_call' && lower(raw.params[0]?.to)===lower(a.entryPoint) && raw.params[0]?.data?.startsWith('0x765e827f') && raw.response && JSON.parse(Buffer.from(raw.response,'base64')).error);
    if (preflightErrors.length && (a.sent!==false || a.verdict!=='NOT_SENT' || a.failingCheck!=='preflight_revert')) throw Error('derived evidence mismatch: preflight disposition');
    if (preflightErrors.length || a.preflight || a.failingCheck==='preflight_revert') bindPreflight(a,archives);
    bindArchivedDisposition(a,archives);
    bindReceiptSummaries(a, {formal:true});
    const time=Date.parse(a.collectedAtUtc);
    if (!Number.isFinite(time) || time<lastTime) throw new Error('journal chronology mismatch');
    lastTime=time;
    if (a.tx) {
      for (const arc of archives) if (!arc.records.some(raw=>{
        if (raw.method!=='eth_getBlockByNumber' || !raw.response) return false;
        const block=JSON.parse(Buffer.from(raw.response,'base64').toString()).result;
        return block?.hash===a.tx.blockHash && BigInt(block.number)===BigInt(a.tx.blockNumber) && BigInt(block.timestamp)===BigInt(a.tx.blockTimestamp) && block.transactions?.length===a.tx.blockTxCount && block.transactions?.some(tx=>lower(typeof tx==='string'?tx:tx.hash)===lower(a.tx.hash));
      })) throw new Error('inclusion block membership missing on A/B');
      const sends=archives[0].records.filter(raw=>raw.method==='eth_sendRawTransaction' && raw.response && lower(JSON.parse(Buffer.from(raw.response,'base64').toString()).result)===lower(a.tx.hash));
      if (sends.length!==1 || sends[0].id<=lastSendId || Date.parse(sends[0].requestedAtUtc)>time) throw new Error('archived send sequence mismatch');
      // headBefore must be a head actually read in this attempt before the send. The collector reads further heads
      // (pin refresh, wallet fee lookup) after it, and the chain may advance in between, so the claimed value is not
      // necessarily the last one. Isolation is therefore checked against the highest head read before the send: the
      // inclusion block must be newer than every block that already existed when the transaction was sent.
      const heads=archives[0].records.filter(raw=>raw.id>a.evidenceStart[0] && raw.id<sends[0].id && raw.method==='eth_blockNumber' && raw.response).map(raw=>BigInt(JSON.parse(Buffer.from(raw.response,'base64')).result));
      if (!heads.some(h=>h===BigInt(a.tx.headBefore))) throw Error('raw headBefore mismatch');
      if (BigInt(a.tx.blockNumber)<=heads.reduce((m,h)=>h>m?h:m)) throw Error('raw inclusion block not newer than every head read before send');
      if (previousIncluded) for (const archive of archives) {
        const result=raw=>raw.response && JSON.parse(Buffer.from(raw.response,'base64').toString()).result;
        const beforeSend=raw=>Date.parse(raw.receivedAtUtc)<=Date.parse(sends[0].requestedAtUtc);
        const receipts=archive.records.filter(raw=>raw.method==='eth_getTransactionReceipt' && lower(raw.params[0])===lower(previousIncluded.hash) && result(raw)?.blockHash===previousIncluded.blockHash && BigInt(result(raw).blockNumber)===BigInt(previousIncluded.blockNumber) && beforeSend(raw));
        if (!receipts.length) throw new Error('prior inclusion receipt missing before send');
        const heads=archive.records.filter(raw=>raw.method==='eth_blockNumber' && beforeSend(raw) && result(raw)!=null && BigInt(result(raw))>BigInt(previousIncluded.blockNumber) && receipts.some(rc=>raw.id>rc.id && Date.parse(raw.requestedAtUtc)>=Date.parse(rc.receivedAtUtc)));
        if (!heads.length) throw new Error('both heads must advance after prior inclusion receipt before send');
      }
      previousIncluded=a.tx;
      lastSendId=sends[0].id;
    }
    if (!eq(r.armOrder,a.armOrder)) throw new Error('index/journal armOrder mismatch');
    if (!eq(r.pins,start.pins) || !eq(r.rpcIdentity,start.rpcIdentity)) throw new Error('index/journal pins mismatch');
    for (const [key,value] of [['start',start.passport],['attempt',a.passport],['end',journal.at(-1)?.kind==='run_end'?journal.at(-1).passport:JSON.parse(file(trailer.endPassport.path))]]) {
      const passportRef=key==='end'?trailer.endPassport:r.passports[key];
      const artifact=JSON.parse(file(passportRef.path));
      if (!eq(artifact,value)) throw new Error('Passport/journal mismatch');
      verifyPassportIdentity(artifact,start.frozenConfig,pinnedConfig(start.deploymentConfigSha256),pinnedConfig(start.baselineConfigSha256));
      for (const e of ['A','B']) {
        if (!passportRef.raw[e].length) throw new Error('Passport raw references missing');
        for (const ref of passportRef.raw[e]) { const raw=reference(ref,e);
          if (raw.method!=='eth_chainId' && (!['eth_call','eth_getCode','eth_getStorageAt','eth_getBlockByNumber'].includes(raw.method) || raw.blockAnchor?.hash!==artifact.block.hash || BigInt(raw.blockAnchor.number)!==BigInt(artifact.block.number))) throw new Error('Passport raw anchor/method mismatch');
        }
        verifyPassport(artifact,passportRef.raw[e].map(ref=>reference(ref,e)));
      }
    }
    const inv=start.passport?.invariant;
    if (!eq(a.stateTargets,{superPaymaster:inv?.code.superPaymasterProxy.address,token:inv?.xPNTs.address,tpmToken:inv?.code.tokenPaymasterToken.address,operator:start.frozenConfig.operator})) throw new Error('state targets/config mismatch');
    const expected=evidenceIndex(a,{windowId:r.windowId,archives:archives.map((arc,i)=>({records:arc.records.filter(x=>x.id<=a.evidenceEnd?.[i])})),pins:r.pins,rpcIdentity:r.rpcIdentity,passports:r.passports,stopReason:a.stoppedBy?.reason??null,replaces:r.replaces});
    for (const k of ['chainId','entryPoint','sender','nonce','paymaster','bundler','callDataHash','failureReason','notSentReason','stopReason','verdict','exclusionReason','packedOp','bundle','tx','uoe','state','endpoints','gas','expectedUserOpHash','observedUserOpHash','trace']) if (!eq(r[k],expected[k])) throw new Error(`index/journal ${k} mismatch`);
    errors.push(...transactionErrors(a,start.frozenConfig).map(e=>`attempt ${i}: ${e}`));
    for (const endpoint of ['A','B']) {
      for (const kind of ['receipt','logs','transaction','stateReads']) {
        const observations=[];
        for (const ref of r.endpoints[endpoint][kind]) {
          const raw=reference(ref,endpoint), method={receipt:'eth_getTransactionReceipt',logs:'eth_getTransactionReceipt',transaction:'eth_getTransactionByHash'}[kind];
          if (method && (raw.method!==method || lower(raw.params[0])!==lower(r.tx?.txHash))) throw new Error('endpoint raw method/transaction mismatch');
          if (!method || !raw.response) continue;
          const result=JSON.parse(Buffer.from(raw.response,'base64').toString()).result;
          observations.push({id:raw.id,result});
          const pending=!result || result.blockHash==null;
          if (kind==='transaction' && !pending && !eq(a.tx.raw,JSON.parse(stringify(formatTransaction(result))))) throw new Error('raw transaction summary mismatch');
          if (kind==='transaction' && result && lower(result.from)!==lower(a.tx.from)) throw Error('raw transaction from mismatch');
          if (kind==='transaction' && result) for (const [rawKey,key] of [['input','input'],['gas','gasLimit'],['maxFeePerGas','maxFeePerGas'],['maxPriorityFeePerGas','maxPriorityFeePerGas']]) {
            if (rawKey==='input'?lower(result[rawKey])!==lower(r.tx[key]):BigInt(result[rawKey])!==BigInt(r.tx[key])) throw new Error('raw transaction field mismatch');
          }
          if ((kind==='receipt' || kind==='logs') && !pending) {
            for (const key of ['gasUsed','effectiveGasPrice']) if (a.tx[key] == null || result[key] == null || BigInt(a.tx[key]) !== BigInt(result[key])) throw new Error('raw receipt '+key+' mismatch');
            const logs=ls=>ls.map(l=>({address:lower(l.address),topics:l.topics.map(lower),data:lower(l.data),logIndex:String(BigInt(l.logIndex)),...(l.transactionHash?{transactionHash:lower(l.transactionHash)}:{})}));
            if ((result.status==='0x1'?'success':result.status==='0x0'?'reverted':null)!==a.tx.status || !eq(logs(result.logs),logs(a.logs))) throw new Error('raw complete receipt mismatch');
          }
          if (kind==='logs' && included.has(i) && !pending && !result.logs.some(l=>BigInt(l.logIndex)===BigInt(r.uoe.logIndex) && lower(l.address)===lower(r.uoe.address) && eq(l.topics,r.uoe.topics) && l.data===r.uoe.data)) throw new Error('raw UOE mismatch');
        }
        if (a.sent && kind!=='stateReads') { const e=inclusionSeriesError(observations,r.tx); if (e) throw new Error(e); }
      }
      for (const side of ['before','after']) for (const [key,state] of Object.entries(r.state[side])) if (state) {
        if (!state.raw[endpoint].length) throw new Error('state raw references missing');
        const calls=stateCalls(a,key,state.value);
        const records=state.raw[endpoint].map(ref=>reference(ref,endpoint));
        if (calls.some(call=>!records.some(raw=>supportsCall(raw,call,state.anchor)))) throw new Error('state call/return value mismatch');
        for (const ref of state.raw[endpoint]) {
          const raw=reference(ref,endpoint);
          if (raw.method!=='eth_call' || BigInt(raw.params[1])!==BigInt(state.anchor.number) || !eq(raw.blockAnchor,{number:String(state.anchor.number),hash:state.anchor.hash})) throw new Error('state raw method/anchor mismatch');
        }
      }
    }
    if (a.sent && a.verdict==='USEROP_SUCCESS' && r.arm==='TPM') {
      if (!a.tpmOracle || lower(a.tpmOracle)!==lower(inv.code.tokenPaymasterOracle.address)) throw new Error('TPM oracle/Passport mismatch');
      for (const [idx,endpoint] of ['A','B'].entries()) {
        const refs=r.trace?.raw?.[endpoint] ?? [];
        for (const [tracer,key] of [['callTracer','call'],['prestateTracer','state']]) {
          if (!refs.some(ref=>{const raw=reference(ref,endpoint),request=JSON.parse(Buffer.from(raw.request,'base64').toString());return request.params[1]?.tracerConfig?.[tracer==='callTracer'?'withLog':'diffMode']===true && raw.method==='debug_traceTransaction' && raw.params[0]===a.tx.hash && raw.params[1]?.tracer===tracer && raw.blockAnchor?.hash===a.tx.blockHash && eq(JSON.parse(Buffer.from(raw.response,'base64').toString()).result,a.traces?.[idx]?.[key]);})) throw new Error('TPM raw trace missing or inconsistent');
        }
      }
      if (tpmAttemptRefreshed(a) && included.has(i)) throw new Error('included TPM refresh or trace unavailable');
    }
  } catch(e) { fail(`attempt ${i}: ${e.message}`); }
  try {
    const check=trailer.finalBlockCheck;
    if (!check?.anchors?.length) throw new Error('final block revalidation missing');
    const observed=new Map();
    for (const arc of archives) for (const record of arc.records) if (record.blockAnchor) {
      const {number,hash}=record.blockAnchor;
      if (observed.has(String(number)) && observed.get(String(number))!==hash) throw new Error('archived reorg');
      observed.set(String(number),hash);
    }
    for (const [number,hash] of observed) for (const endpoint of ['A','B']) {
      if (!check.raw[endpoint].some(ref=>{
        const raw=reference(ref,endpoint), result=JSON.parse(Buffer.from(raw.response,'base64').toString()).result;
        return raw.method==='eth_getBlockByNumber' && BigInt(raw.params[0])===BigInt(number) && result?.hash===hash && BigInt(result.number)===BigInt(number) && Date.parse(raw.requestedAtUtc)>=lastTime;
      })) throw new Error('final historical anchor not verified on both endpoints');
    }
  } catch(e) { fail(e.message); }
  for (const t of trailer.triples) {
    const actual=attempts.filter(a=>a.tripletIndex===t.tripleIndex).map(a=>a.arm);
    if (!eq(actual,armOrder(t.tripleIndex).slice(0,actual.length))) fail('actual chronological arm order mismatch');
  }
  return errors;
}
