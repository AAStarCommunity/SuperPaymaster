import { stateCalls, supportsCall } from './state-evidence.mjs';
import { readFileSync, realpathSync } from 'node:fs';
import { resolve, isAbsolute } from 'node:path';
import { evidenceIndex, sha256, stringify, loadRegistry } from './evidence.mjs';
import { formalConfig, armOrder, DEFAULT_FACTORY } from './formal.mjs';
import { decodeFunctionData, parseAbi, toFunctionSelector, encodeAbiParameters } from 'viem';
import { postOpRefreshed } from './trace-policy.mjs';
const canonical=v=>Array.isArray(v)?v.map(canonical):v && typeof v==='object'?Object.fromEntries(Object.keys(v).sort().map(k=>[k,canonical(v[k])])):typeof v==='string' && v.startsWith('0x')?v.toLowerCase():typeof v==='bigint'?String(v):v;
const eq=(a,b)=>JSON.stringify(canonical(a))===JSON.stringify(canonical(b));
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
        if (r.credentialFlag) throw new Error('credential flagged archive');
        if (r.request!==r.requestBase64 || r.response!==r.responseBase64) throw new Error('archive byte aliases disagree');
        const request=JSON.parse(Buffer.from(r.request,'base64').toString());
        if (request.method!==r.method || !eq(request.params,r.params)) throw new Error('raw request metadata mismatch');
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
    for (const r of rows) { walk(r); for (const category of ['collector','validator','dependencies','contractSources','abi','config']) {
      if (!r.pins?.[category]?.length) throw new Error('required pins missing');
      r.pins[category].forEach(pin);
    } pin(r.rpcIdentity); loadRegistry(local(r.rpcIdentity.path));
      for (const p of Object.values(r.passports)) if (p) JSON.parse(file(p.path));
    }
    walk(trailer.finalBlockCheck);
    walk(trailer.endPassport); JSON.parse(file(trailer.endPassport.path));
  } catch(e) { fail(`artifact verification: ${e.message}`); }
  if (!journal) { fail('formal artifact verification requires journal'); return errors; }
  const attempts=journal.filter(r=>r.kind==='attempt'), start=journal[0];
  try {
    const configPin=start.pins.config.find(p=>p.sha256===start.configSha256);
    if (!configPin) throw new Error('frozen config hash is not pinned');
    const frozen=JSON.parse(isAbsolute(configPin.path)?readFileSync(configPin.path):file(configPin.path));
    frozen.factory ??= DEFAULT_FACTORY;
    if (!eq(frozen,start.frozenConfig)) throw new Error('frozen config differs from pinned file');
    for (const key of ['deploymentConfigSha256','baselineConfigSha256']) if (!start.pins.config.some(p=>p.sha256===start[key])) throw new Error('deployment/baseline config hash is not pinned');
  } catch(e) { fail(e.message); }
  const included=new Set(trailer.triples.filter(t=>t.included).flatMap(t=>t.attempts));
  let lastTime=-Infinity, lastSendId=-1;
  for (let i=0;i<rows.length;i++) try {
    const r=rows[i], a=attempts[i];
    if (!a) throw new Error('missing journal attempt');
    const time=Date.parse(a.collectedAtUtc);
    if (!Number.isFinite(time) || time<lastTime) throw new Error('journal chronology mismatch');
    lastTime=time;
    if (a.tx) {
      const sends=archives[0].records.filter(raw=>raw.method==='eth_sendRawTransaction' && raw.response && lower(JSON.parse(Buffer.from(raw.response,'base64').toString()).result)===lower(a.tx.hash));
      if (sends.length!==1 || sends[0].id<=lastSendId || Date.parse(sends[0].requestedAtUtc)>time) throw new Error('archived send sequence mismatch');
      lastSendId=sends[0].id;
    }
    if (!eq(r.armOrder,a.armOrder)) throw new Error('index/journal armOrder mismatch');
    if (!eq(r.pins,start.pins) || !eq(r.rpcIdentity,start.rpcIdentity)) throw new Error('index/journal pins mismatch');
    for (const [key,value] of [['start',start.passport],['attempt',a.passport]]) {
      const artifact=JSON.parse(file(r.passports[key].path));
      if (!eq(artifact,value)) throw new Error('Passport/journal mismatch');
      for (const e of ['A','B']) {
        if (!r.passports[key].raw[e].length) throw new Error('Passport raw references missing');
        for (const ref of r.passports[key].raw[e]) { const raw=reference(ref,e);
          if (!['eth_call','eth_getCode','eth_getStorageAt','eth_getBlockByNumber'].includes(raw.method) || raw.blockAnchor?.hash!==artifact.block.hash || BigInt(raw.blockAnchor.number)!==BigInt(artifact.block.number)) throw new Error('Passport raw anchor/method mismatch');
        }
      }
    }
    const inv=start.passport?.invariant;
    if (!eq(a.stateTargets,{superPaymaster:inv?.code.superPaymasterProxy.address,token:inv?.xPNTs.address,tpmToken:inv?.code.tokenPaymasterToken.address,operator:start.frozenConfig.operator})) throw new Error('state targets/config mismatch');
    const expected=evidenceIndex(a,{windowId:r.windowId,archives:archives.map((arc,i)=>({records:arc.records.filter(x=>x.id<=a.evidenceEnd?.[i])})),pins:r.pins,rpcIdentity:r.rpcIdentity,passports:r.passports,stopReason:a.stoppedBy?.reason??null,replaces:r.replaces});
    for (const k of ['packedOp','bundle','tx','uoe','state','endpoints','gas','expectedUserOpHash','observedUserOpHash','trace']) if (!eq(r[k],expected[k])) throw new Error(`index/journal ${k} mismatch`);
    errors.push(...transactionErrors(a,start.frozenConfig).map(e=>`attempt ${i}: ${e}`));
    for (const endpoint of ['A','B']) {
      for (const kind of ['receipt','logs','transaction','stateReads']) for (const ref of r.endpoints[endpoint][kind]) {
        const raw=reference(ref,endpoint), method={receipt:'eth_getTransactionReceipt',logs:'eth_getTransactionReceipt',transaction:'eth_getTransactionByHash'}[kind];
        if (method && (raw.method!==method || lower(raw.params[0])!==lower(r.tx?.txHash))) throw new Error('endpoint raw method/transaction mismatch');
        if (method && raw.response) {
          const result=JSON.parse(Buffer.from(raw.response,'base64').toString()).result;
          if (included.has(i) && (!result || lower(result.blockHash)!==lower(r.tx.blockHash) || BigInt(result.blockNumber)!==BigInt(r.tx.blockNumber))) throw new Error('raw inclusion mismatch');
          if (kind==='transaction' && result) for (const [rawKey,key] of [['input','input'],['gas','gasLimit'],['maxFeePerGas','maxFeePerGas'],['maxPriorityFeePerGas','maxPriorityFeePerGas']]) {
            if (rawKey==='input'?lower(result[rawKey])!==lower(r.tx[key]):BigInt(result[rawKey])!==BigInt(r.tx[key])) throw new Error('raw transaction field mismatch');
          }
          if (kind==='logs' && included.has(i) && !result.logs.some(l=>BigInt(l.logIndex)===BigInt(r.uoe.logIndex) && lower(l.address)===lower(r.uoe.address) && eq(l.topics,r.uoe.topics) && l.data===r.uoe.data)) throw new Error('raw UOE mismatch');
        }
      }
      for (const side of ['before','after']) for (const [key,state] of Object.entries(r.state[side])) if (state) {
        if (!state.raw[endpoint].length) throw new Error('state raw references missing');
        const calls=stateCalls(a,key,state.value);
        const records=state.raw[endpoint].map(ref=>reference(ref,endpoint));
        if (calls.some(call=>!records.some(raw=>supportsCall(raw,call,state.anchor))) || records.some(raw=>!calls.some(call=>supportsCall(raw,call,state.anchor)))) throw new Error('state call/return value mismatch');
        for (const ref of state.raw[endpoint]) {
          const raw=reference(ref,endpoint);
          if (raw.method!=='eth_call' || BigInt(raw.params[1])!==BigInt(state.anchor.number) || !eq(raw.blockAnchor,{number:String(state.anchor.number),hash:state.anchor.hash})) throw new Error('state raw method/anchor mismatch');
        }
      }
    }
    if (included.has(i) && r.arm==='TPM') {
      if (!a.tpmOracle || lower(a.tpmOracle)!==lower(inv.code.tokenPaymasterOracle.address)) throw new Error('TPM oracle/Passport mismatch');
      for (const [idx,endpoint] of ['A','B'].entries()) {
        const refs=r.trace?.raw?.[endpoint] ?? [];
        for (const [tracer,key] of [['callTracer','call'],['prestateTracer','state']]) {
          if (!refs.some(ref=>{const raw=reference(ref,endpoint);return raw.method==='debug_traceTransaction' && raw.params[0]===a.tx.hash && raw.params[1]?.tracer===tracer && raw.blockAnchor?.hash===a.tx.blockHash && eq(JSON.parse(Buffer.from(raw.response,'base64').toString()).result,a.traces?.[idx]?.[key]);})) throw new Error('TPM raw trace missing or inconsistent');
        }
      }
      if (a.traces?.length!==2 || a.postOpRefreshed!==false || a.traces.some(t=>postOpRefreshed(t.call,t.state,a.paymaster,a.tpmOracle))) throw new Error('included TPM refresh or trace unavailable');
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
