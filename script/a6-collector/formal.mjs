import { request as httpRequest } from 'node:http';
import { request as httpsRequest } from 'node:https';
import { lookup } from 'node:dns/promises';
import { isIP } from 'node:net';
import { rawArchive } from './evidence.mjs';
import { dirname } from 'node:path';
// Formal-A6 slice 1. TODO(A6-SOP §2, §4, §5): identity registry, per-op
// evidence index, exclusion validation and freeze/sampling manifest are later slices.
import { readFileSync, openSync, writeSync, fsyncSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createPublicClient, createWalletClient, custom, encodeFunctionData, getAddress,
  hashMessage, keccak256, parseAbi, recoverAddress, serializeTransaction } from 'viem';
import { toAccount } from 'viem/accounts';

export const DEFAULT_FACTORY = '0x91E60e0613810449d098b0b5Ec8b51A0FE8c8985';
export const EP_ABI = parseAbi([
  'function getNonce(address sender, uint192 key) view returns (uint256)',
  'function getUserOpHash((address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData,bytes signature) op) view returns (bytes32)',
]);
const TASK_ABI = parseAbi(['function execute(address dest,uint256 value,bytes func)', 'function transfer(address to,uint256 amount) returns (bool)']);
export const armOrder = i => ['SP', 'VPM', 'TPM'].map((_, j, a) => a[(i + j) % 3]);
export function endpointPair(a, b) {
  const parse = value => {
    let u;
    try { u = new URL(value); } catch { throw new Error('invalid formal RPC URL (redacted)'); }
    const h = u.hostname.toLowerCase().replace(/\.$/, '');
    if (!['http:', 'https:'].includes(u.protocol) || h === 'localhost' || h.endsWith('.localhost') ||
        /^127\./.test(h) || h === '[::]' || h === '[::1]' || h === '0.0.0.0' || h.startsWith('[::ffff:7f')) throw new Error('formal RPC must be remote');
    return `${h}:${u.port || (u.protocol === 'https:' ? '443' : '80')}`;
  };
  if (parse(a) === parse(b)) throw new Error('formal RPC A/B have the same host/port');
}
export function publicAddress(address) {
  const h = address.toLowerCase().replace(/^\[|\]$/g, '');
  if (isIP(h) === 4) {
    const [a,b] = h.split('.').map(Number);
    return !(a === 0 || a === 10 || a === 127 || a >= 224 || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) || (a === 100 && b >= 64 && b <= 127));
  }
  // Accept only global-unicast IPv6; mapped IPv4 and local/reserved ranges fail closed.
  if (isIP(h) !== 6 || !/^[23][0-9a-f]{3}:/.test(h)) return false;
  const [first, second = '0'] = h.split(':').map(x => x || '0');
  return !(parseInt(first,16) === 0x2002 || (parseInt(first,16) === 0x2001 && [0,0xdb8].includes(parseInt(second,16))));
}
export async function resolveEndpoints(a,b,resolver = lookup) {
  endpointPair(a,b);
  const sets = await Promise.all([a,b].map(async url => {
    const host = new URL(url).hostname.replace(/^\[|\]$/g,'');
    const addresses = isIP(host) ? [host] : (await resolver(host,{all:true})).map(r=>r.address);
    if (!addresses.length || addresses.some(a=>!publicAddress(a))) throw new Error('formal RPC resolved to forbidden address');
    return [...new Set(addresses.map(a=>a.toLowerCase()))].sort();
  }));
  if (sets[0].some(a=>sets[1].includes(a))) throw new Error('formal RPC A/B share resolved address');
  return sets;
}
export function pinnedFetch(url, options, addresses) {
  return new Promise((resolve,reject)=>{
    const request = (new URL(url).protocol==='https:'?httpsRequest:httpRequest)(url,{
      method:options.method,headers:options.headers,signal:options.signal,
      lookup:(_host,opts,cb)=>{ const records=addresses.map(address=>({address,family:isIP(address)})); if(opts.all) cb(null,records); else cb(null,records[0].address,records[0].family); }
    },response=>{
      const chunks=[];response.on('data',chunk=>chunks.push(chunk));response.on('error',reject);
      response.on('end',()=>resolve({status:response.statusCode,ok:response.statusCode>=200 && response.statusCode<300,arrayBuffer:async()=>Buffer.concat(chunks)}));
    });
    request.on('error',()=>reject(new Error('RPC transport failed (redacted)')));request.end(options.body);
  });
}
export function credentialFragments(urls) {
  return [...new Set(urls.flatMap(value=>{
    const u=new URL(value);
    return [u.username,u.password,...u.pathname.split('/'),...u.searchParams.values()].filter(Boolean).flatMap(x=>[x,decodeURIComponent(x)]);
  }))];
}
export async function revalidateAnchors(archives) {
  const anchors = new Map();
  for (const archive of archives) for (const r of archive.records) for (const a of [r.blockAnchor,...(r.blockRange ?? [])]) if (a) {
    const n=BigInt(a.number).toString();
    if (anchors.has(n) && anchors.get(n)!==a.hash) throw new Error('final anchor disagreement');
    anchors.set(n,a.hash);
  }
  const raw={A:[],B:[]};
  for (const [number,hash] of anchors) for (const [idx,archive] of archives.entries()) {
    const b=await archive.request({method:'eth_getBlockByNumber',params:['0x'+BigInt(number).toString(16),false]});
    if (!b || BigInt(b.number)!==BigInt(number) || b.hash!==hash) throw new Error('final historical block changed or unavailable');
    const record=archive.records.at(-1);
    raw[idx?'B':'A'].push({path:record.path,id:record.id});
  }
  return {anchors:[...anchors].map(([number,hash])=>({number,hash})),raw};
}
export function taskCallData(task, candidate) {
  const T = getAddress(task.token), R = getAddress(task.recipient);
  if ([T, R].some(a => /^0x0{40}$/i.test(a))) throw new Error('task addresses must be nonzero');
  const inner = encodeFunctionData({ abi: TASK_ABI, functionName: 'transfer', args: [R, 1n] });
  const data = encodeFunctionData({ abi: TASK_ABI, functionName: 'execute', args: [T, 0n, inner] });
  if (candidate !== undefined && candidate.toLowerCase() !== data.toLowerCase()) throw new Error('formal calldata must be execute(T,0,transfer(R,1))');
  return data;
}
export function formalConfig(c, bMax) {
  if (!Number.isSafeInteger(c.chainId) || c.chainId <= 0) throw new Error('target chainId required');
  if (BigInt(bMax) !== 1n) throw new Error('formal B_max must be 1');
  if (c.frozen !== true) throw new Error('formal gas config must be frozen');
  const fees = Object.fromEntries(['maxFeePerGas', 'maxPriorityFeePerGas'].map(k => [k, BigInt(c.fees[k])]));
  if (fees.maxFeePerGas !== 5_000_000_000n || fees.maxPriorityFeePerGas !== 1_000_000_000n) throw new Error('formal fees must be 5/1 gwei');
  const gas = {}, pmGas = {};
  for (const arm of armOrder(0)) {
    const g = Object.fromEntries(['callGasLimit', 'verificationGasLimit', 'preVerificationGas', 'paymasterVerificationGasLimit', 'paymasterPostOpGasLimit'].map(k => {
      if (!/^[1-9]\d*$/.test(String(c.gas[arm][k]))) throw new Error(`invalid frozen gas ${arm}.${k}`);
      const v = BigInt(c.gas[arm][k]);
      if (v >= 1n << 128n) throw new Error('gas exceeds uint128');
      return [k, v];
    }));
    gas[arm] = { callGasLimit: g.callGasLimit, verificationGasLimit: g.verificationGasLimit, preVerificationGas: g.preVerificationGas, ...fees };
    pmGas[arm] = { ver: g.paymasterVerificationGasLimit, post: g.paymasterPostOpGasLimit };
  }
  if (pmGas.SP.post < 480000n) throw new Error('SP post gas below matrix floor');
  if (!/^[1-9]\d*$/.test(String(c.bundlerGasLimit))) throw new Error('bundlerGasLimit required');
  for (const role of ['owner', 'bundler', 'verifyingSigner']) {
    if (!/^[\w.-]+$/.test(c.accounts[role].name)) throw new Error('keystore account name required');
    getAddress(c.accounts[role].address);
  }
  if (c.accounts.owner.name === c.accounts.bundler.name || c.accounts.owner.address.toLowerCase() === c.accounts.bundler.address.toLowerCase()) throw new Error('owner and bundler must be separate keystore accounts');
  getAddress(c.operator); getAddress(c.factory); getAddress(c.sender);
  if (c.operator.toLowerCase() === c.accounts.bundler.address.toLowerCase()) throw new Error('bundler must differ from operator');
  if (!/^\d+$/.test(String(c.salt))) throw new Error('factory salt required');
  return { gas, pmGas, fees, callData: taskCallData(c.task, c.task.callData) };
}
export function requirePostGas(post, minimum) {
  if (BigInt(post) < BigInt(minimum)) throw new Error('SP paymasterPostOpGasLimit below pinned minPostOpGas');
}
export function feePause(block, cap) {
  if (block.baseFeePerGas == null) throw new Error('base fee unavailable');
  return BigInt(block.baseFeePerGas) > BigInt(cap) ? { sent: false, tx: null, logs: [], verdict: 'NOT_SENT',
    reason: 'basefee_above_cap', failingCheck: 'basefee_above_cap', exclusion: 'NOT_SENT:basefee_above_cap',
    baseFeePerGas: block.baseFeePerGas, feeBlock: { number: block.number, hash: block.hash } } : null;
}

const STATE_TAG = { eth_call: 1, eth_getCode: 1, eth_getBalance: 1, eth_getStorageAt: 2, eth_getTransactionCount: 1, eth_getProof: 2, eth_estimateGas: 1 };
export function guardRequest(method, params) {
  if (/^(anvil_|hardhat_|evm_)/.test(method)) throw new Error('development RPC forbidden in formal mode');
  if (method in STATE_TAG && !/^0x[0-9a-f]+$/i.test(params[STATE_TAG[method]] ?? '')) throw new Error(`${method} requires a fixed block number`);
  if (method === 'eth_getLogs' && (!/^0x[0-9a-f]+$/i.test(params[0]?.fromBlock ?? '') || !/^0x[0-9a-f]+$/i.test(params[0]?.toBlock ?? ''))) throw new Error('eth_getLogs requires fixed blocks');
  if (['eth_sendTransaction', 'eth_sign', 'personal_sign'].includes(method)) throw new Error('formal signing must use a keystore signer');
}

/** Transport owns serialization: base64 preserves exact request and response bytes,
 * including whitespace, invalid JSON and error responses. No endpoint URL is stored. */
export function archivedRpc({ url, endpoint, append, fetchImpl = fetch, secrets = [], secretPatterns = [], rehearsal = false }) {
  const credentials = [...credentialFragments([url]), ...secrets];
  const sensitive = bytes => credentials.some(s=>s && bytes.includes(s)) || secretPatterns.some(p=>new RegExp(p).test(bytes));
  let sequence = 0;
  const ids = [], anchors = new Map();
  let fatalError;
  async function request(args) {
    if (fatalError) throw fatalError;
    try { return await perform(args); } catch (e) {
      if (!e.data) fatalError = e;
      throw e;
    }
  }
  async function perform({ method, params = [] }) {
    if (!(rehearsal && ['anvil_setStorageAt','evm_mine'].includes(method))) guardRequest(method, params);
    let anchor = null;
    if (rehearsal && ['anvil_setStorageAt','evm_mine'].includes(method)) {
      const block = await request({method:'eth_getBlockByNumber',params:['latest',false]});
      anchor = {number:block.number,hash:block.hash};
    }
    const tag = method in STATE_TAG ? params[STATE_TAG[method]] : method === 'eth_getBlockByNumber' ? params[0] : null;
    if (tag && /^0x[0-9a-f]+$/i.test(tag) && method !== 'eth_getBlockByNumber') {
      const b = await request({ method: 'eth_getBlockByNumber', params: [tag, false] });
      if (!b?.hash || b.number !== tag) throw new Error('fixed block unavailable');
      anchor = { number: b.number, hash: b.hash };
    }
    if (['debug_traceTransaction', 'eth_getTransactionByHash'].includes(method)) {
      const receipt = await request({ method: 'eth_getTransactionReceipt', params: [params[0]] });
      if (receipt) anchor = { number: receipt.blockNumber, hash: receipt.blockHash };
    }
    let blockRange = null;
    if (method === 'eth_getLogs') {
      blockRange = await Promise.all([params[0].fromBlock, params[0].toBlock].map(async number => {
        const block = await request({ method: 'eth_getBlockByNumber', params: [number, false] });
        if (!block?.hash) throw new Error('log range block unavailable');
        return { number: block.number, hash: block.hash };
      }));
    }
    const id = `${endpoint}-${++sequence}`, at = new Date().toISOString();
    const body = JSON.stringify({ jsonrpc: '2.0', id, method, params });
    let bytes, response;
    try {
      response = await fetchImpl(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body, redirect: 'error', signal: AbortSignal.timeout(60000) });
      bytes = Buffer.from(await response.arrayBuffer());
    } catch {
      const credentialFlag = sensitive(body) || sensitive(bytes?.toString('utf8') ?? '');
    append({ credentialFlag, id, endpoint, requestedAtUtc: at, receivedAtUtc: new Date().toISOString(), method, params, anchor, blockRange,
        requestBase64: Buffer.from(body).toString('base64'), responseBase64: null, transportError: 'RPC transport failed (redacted)' });
      ids.push(id);
      throw new Error(`RPC ${endpoint} transport failed (redacted)`);
    }
    let data;
    try { data = JSON.parse(bytes.toString('utf8')); } catch { /* Archive before refusing malformed JSON. */ }
    if (data?.result?.blockHash && data.result.blockNumber) anchor = { number: data.result.blockNumber, hash: data.result.blockHash };
    if (['eth_getBlockByNumber', 'eth_getBlockByHash'].includes(method) && data?.result?.hash) anchor = { number: data.result.number, hash: data.result.hash };
    const credentialFlag = sensitive(body) || sensitive(bytes?.toString('utf8') ?? '');
    append({ credentialFlag, id, endpoint, requestedAtUtc: at, receivedAtUtc: new Date().toISOString(), method, params, anchor, blockRange,
      requestBase64: Buffer.from(body).toString('base64'), responseBase64: bytes.toString('base64'), httpStatus: response.status });
    ids.push(id);
    if (credentialFlag) throw new Error('RPC archive credential exposure; window stopped (redacted)');
    if (anchor) {
      if (anchors.has(anchor.number) && anchors.get(anchor.number) !== anchor.hash) throw new Error('recorded block hash changed');
      anchors.set(anchor.number, anchor.hash);
    }
    if (!response.ok || !data || data.id !== id || data.jsonrpc !== '2.0') throw new Error(`RPC ${endpoint} invalid response (redacted)`);
    if (data.error) { const e = new Error(`RPC ${endpoint} error ${Number(data.error.code)} (redacted)`); e.code = data.error.code; e.data = /^0x[0-9a-f]*$/i.test(data.error.data ?? '') ? data.error.data : undefined; throw e; }
    if (!('result' in data)) throw new Error(`RPC ${endpoint} missing result`);
    if (method in STATE_TAG) {
      // Re-read after the state response too: a reorg during the call invalidates the pin.
      const after = await request({ method: 'eth_getBlockByNumber', params: [tag, false] });
      if (!after?.hash || after.number !== tag || after.hash !== anchor.hash) throw new Error('fixed block unavailable or changed after state read');
    }
    return data.result;
  }
  return { request, ids };
}

// Inject createSigner({name,address}, role) in offline tests. Production default delegates
// only digest signing to Foundry; the collector never opens a keystore/password file.
export function castSigner(config, _role, run = execFileSync) {
  const address = getAddress(config.address);
  async function sign(hash) {
    let signature;
    try { signature = run('cast', ['wallet', 'sign', '--account', config.name, '--no-hash', hash], { encoding: 'utf8', stdio: ['inherit', 'pipe', 'pipe'] }).trim(); }
    catch { throw new Error('keystore signing failed (redacted)'); }
    if ((await recoverAddress({ hash, signature })).toLowerCase() !== address.toLowerCase()) throw new Error('keystore signer address mismatch');
    return signature;
  }
  return toAccount({ address, signMessage: ({ message }) => sign(hashMessage(message)),
    signTransaction: async (tx, options = {}) => {
      const serialize = options.serializer ?? serializeTransaction;
      const sig = await sign(keccak256(serialize(tx)));
      return serialize(tx, { r: sig.slice(0, 66), s: `0x${sig.slice(66, 130)}`, v: BigInt(`0x${sig.slice(130, 132)}`) });
    }, signTypedData: async () => { throw new Error('typed data signing is not used by A6'); } });
}

export async function formalRuntime({ config, rpcAFile, rpcBFile, outPath, rehearsal = false, createSigner = castSigner, fetchImpl, resolver = lookup }) {
  const a = readFileSync(rpcAFile, 'utf8').trim(), b = readFileSync(rpcBFile, 'utf8').trim();
  let resolved;
  if (rehearsal) {
    for (const url of [a,b]) if (!/^http:\/\/127\.0\.0\.1:\d+$/.test(url)) throw new Error('rehearsal requires literal loopback RPC');
    if (config.chainId !== 31337) throw new Error('rehearsal requires chain 31337');
    resolved = [['127.0.0.1'], ['127.0.0.1']];
    const { rehearsalSigner } = await import('./rehearsal-signer.mjs');
    createSigner = rehearsalSigner;
  } else resolved = await resolveEndpoints(a, b, resolver);
  const archives = ['A', 'B'].map((endpoint, i) => {
    const archive = rawArchive(dirname(outPath), endpoint);
    const rpc = archivedRpc({ rehearsal, url: i ? b : a, endpoint, fetchImpl: fetchImpl ?? ((url,options)=>pinnedFetch(url,options,resolved[i])), append: archive.append, secrets: credentialFragments([a,b]), secretPatterns: config.secretPatterns ?? [] });
    return { ...rpc, ...archive };
  });
  let pin;
  const publicClients = archives.map(rpc => createPublicClient({ transport: custom(rpc, { retryCount: 0 }) }));
  const pinned = p => new Proxy(p, { get(target, key) {
    if (['readContract', 'simulateContract', 'getCode', 'getStorageAt', 'getBalance', 'getTransactionCount'].includes(key)) return (args = {}) => {
      if (args.blockTag || (args.blockNumber === undefined && pin === undefined)) throw new Error('state read requires a fixed pin');
      return target[key]({ ...args, blockNumber: args.blockNumber ?? pin });
    };
    return target[key];
  } });
  const accounts = {};
  for (const role of ['owner', 'bundler', 'verifyingSigner']) {
    accounts[role] = await createSigner(config.accounts[role], role);
    if (accounts[role].type !== 'local' || getAddress(accounts[role].address) !== getAddress(config.accounts[role].address)) throw new Error('injected signer identity mismatch');
  }
  const pubA = pinned(publicClients[0]), pubB = pinned(publicClients[1]);
  const wallet = createWalletClient({ account: accounts.bundler, transport: custom(archives[0], { retryCount: 0 }) });
  async function refreshPin() {
    const number = await pubA.getBlockNumber({ cacheTime: 0 });
    const [A, B] = await Promise.all([pubA.getBlock({ blockNumber: number }), pubB.getBlock({ blockNumber: number })]);
    if (!A.hash || A.hash !== B.hash || A.number !== B.number || A.baseFeePerGas !== B.baseFeePerGas) throw new Error('RPC fixed block disagreement');
    pin = number;
    return A;
  }
  return { pubA, pubB, accounts, archives, refreshPin,
    async writeContract(args) {
      const block = await refreshPin();
      const pause = feePause(block, config.fees.maxFeePerGas);
      if (pause) { const error = new Error('basefee_above_cap'); error.pause = pause; throw error; }
      return wallet.writeContract({ ...args, chain: null, chainId:config.chainId, type: 'eip1559', gas: BigInt(config.bundlerGasLimit),
        nonce: await pubA.getTransactionCount({ address: accounts.bundler.address }),
        maxFeePerGas: BigInt(config.fees.maxFeePerGas), maxPriorityFeePerGas: BigInt(config.fees.maxPriorityFeePerGas) });
    } };
}

/** Prepare only the configured SimpleAccount. Funding/eligibility belongs to Phase C;
 * no impersonation, token minting, approval changes or mid-window top-ups here. */
export async function prepareSimpleAccount({ config, runtime, readAB }) {
  const abi = parseAbi(['function getAddress(address owner,uint256 salt) view returns (address)',
    'function createAccount(address owner,uint256 salt) returns (address)', 'function owner() view returns (address)']);
  const factory = getAddress(config.factory), owner = runtime.accounts.owner.address, salt = BigInt(config.salt);
  await runtime.refreshPin();
  const predicted = () => readAB('factory counterfactual address', p => p.readContract({ address: factory, abi, functionName: 'getAddress', args: [owner, salt] }));
  const sender = getAddress((await predicted()).value);
  if (sender !== getAddress(config.sender)) throw new Error('counterfactual sender mismatch');
  const code = () => readAB('account code', p => p.getCode({ address: sender }));
  const existing = (await code()).value;
  let created = false;
  if (!existing || existing === '0x') {
    const hash = await runtime.writeContract({ address: factory, abi, functionName: 'createAccount', args: [owner, salt] });
    const [A, B] = await Promise.all([runtime.pubA.waitForTransactionReceipt({ hash }), runtime.pubB.waitForTransactionReceipt({ hash })]);
    if (A.status !== 'success' || B.status !== A.status || B.blockHash !== A.blockHash) throw new Error('factory receipt failed or disagreed');
    await runtime.refreshPin();
    if (getAddress((await predicted()).value) !== sender) throw new Error('counterfactual sender changed');
    const deployed = (await code()).value;
    if (!deployed || deployed === '0x') throw new Error('factory did not deploy counterfactual account');
    created = true;
  }
  const actualOwner = await readAB('account owner', p => p.readContract({ address: sender, abi, functionName: 'owner' }));
  if (getAddress(actualOwner.value) !== getAddress(owner)) throw new Error('SimpleAccount owner mismatch');
  return { sender, created };
}

export function requireDecodedPreflight(error, decoded) { if (!decoded) throw error; }

/** Receipt inclusion is required before polling; both heads must advance before another send. */
export async function waitAfterInclusion(clients, receipt, {timeoutMs=60000, pollMs=250}={}) {
  if (receipt?.blockNumber == null || !receipt.blockHash) throw new Error('inclusion receipt required');
  const deadline=Date.now()+timeoutMs;
  while (true) {
    const heads=await Promise.all(clients.map(c=>c.getBlockNumber({cacheTime:0})));
    if (heads.every(n=>n>BigInt(receipt.blockNumber))) return heads;
    if (Date.now()>=deadline) throw new Error('both heads must advance past inclusion');
    await new Promise(r=>setTimeout(r,pollMs));
  }
}
export function inclusionErrors(attempts) {
  const errors=[]; let previous=-1n; const blocks=new Set();
  for (const a of attempts) if (a.sent && a.tx?.blockNumber != null) {
    const n=BigInt(a.tx.blockNumber);
    if (n<=previous) errors.push('inclusion blocks must be strictly increasing across all attempts');
    if (blocks.has(n.toString())) errors.push('more than one handleOps from window in a block');
    blocks.add(n.toString()); previous=n;
  }
  return errors;
}
