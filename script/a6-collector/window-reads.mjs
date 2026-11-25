import { getAddress, keccak256 } from 'viem';
import { CANONICAL_EP_V07 } from './gauge-lib.mjs';
// Fixed-block reads for the Passport and the per-attempt read-backs, issued concurrently per
// endpoint. Every read still goes through the archived transport one call at a time (formal.mjs
// brackets each fixed-block read with its own header before and after); only independent reads
// overlap. The returned objects are the same as the former sequential reads in collector.mjs.

/** Maximum fixed-block reads in flight per endpoint (A, B). One read = header, state, header.
 *  The timing probe (window-timing.mjs) measures a slot at these caps on the real pair. */
export const READ_CAP = { A: 8, B: 8 };

// The raw archive files a record under the UTC date its request started and numbers it when it
// completes (evidence.mjs); the artifact validator requires ids to increase across date files. A
// request started before 00:00 UTC must therefore complete before any later one starts: around
// midnight the pool runs one read at a time. 240 s covers a read's three 60 s requests on each side.
export const MIDNIGHT_GUARD_MS = 240_000;
const DAY_MS = 86_400_000;
export const nearUtcMidnight = t => { const m = ((t % DAY_MS) + DAY_MS) % DAY_MS; return m < MIDNIGHT_GUARD_MS || m > DAY_MS - MIDNIGHT_GUARD_MS; };

/** Semaphore for one endpoint. Permits are taken synchronously in `pump`, so a new caller cannot
 *  take a permit a waiter was promised. `maxInFlight` is the high-water mark. */
export function readPool(cap, { clock = Date.now } = {}) {
  if (!Number.isSafeInteger(cap) || cap < 1) throw new Error('read cap must be a positive integer');
  let inFlight = 0;
  const waiting = [];
  const pool = { cap, maxInFlight: 0, started: 0,
    run(fn) {
      return new Promise((resolve, reject) => {
        waiting.push(() => Promise.resolve().then(fn).then(resolve, reject).finally(() => { inFlight--; pump(); }));
        pump();
      });
    } };
  function pump() {
    while (waiting.length && inFlight < (nearUtcMidnight(clock()) ? 1 : cap)) {
      inFlight++; pool.started++; pool.maxInFlight = Math.max(pool.maxInFlight, inFlight);
      waiting.shift()();
    }
  }
  return pool;
}

/** Run independent reads `{key: () => promise}` under `pool`. After the first failure no further
 *  read starts; reads already in flight settle, then the first failure is thrown. A thunk with a
 *  `request` tag equal to an earlier one in the round runs after the round: viem merges identical
 *  requests in flight, and the archive must keep every request the sequential reads made. */
export async function readRound(pool, thunks) {
  let failure = null;
  const seen = new Set(), now = [], later = {};
  for (const [key, fn] of Object.entries(thunks)) {
    if (fn.request !== undefined && seen.has(fn.request)) later[key] = fn;
    else { if (fn.request !== undefined) seen.add(fn.request); now.push([key, fn]); }
  }
  const settled = await Promise.allSettled(now.map(([, fn]) => pool.run(() => {
    if (failure) return Promise.reject(failure.error);
    return Promise.resolve().then(fn).catch(error => { failure ??= { error }; throw error; });
  })));
  if (failure) throw failure.error;
  const out = Object.fromEntries(now.map(([key], i) => [key, settled[i].value]));
  return Object.keys(later).length ? { ...out, ...await readRound(pool, later) } : out;
}

export const EIP1967_IMPL = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';

export const EP_DEPOSIT_ABI = [{ type: 'function', name: 'balanceOf', stateMutability: 'view', inputs: [{ name: 'a', type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'getDepositInfo', stateMutability: 'view', inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ type: 'tuple', components: [{ name: 'deposit', type: 'uint256' }, { name: 'staked', type: 'bool' },
      { name: 'stake', type: 'uint112' }, { name: 'unstakeDelaySec', type: 'uint32' }, { name: 'withdrawTime', type: 'uint48' }] }] }];
export const SP_ABI = [
  { type: 'function', name: 'gasParams', stateMutability: 'view', inputs: [], outputs: [
    { name: 'current', type: 'tuple', components: ['minPostOpGas', 'settleGasBound', 'cWrap', 'cPostop'].map(name => ({ name, type: 'uint32' })) },
    { name: 'pending', type: 'tuple', components: [...['minPostOpGas', 'settleGasBound', 'cWrap', 'cPostop'].map(name => ({ name, type: 'uint32' })), { name: 'eta', type: 'uint64' }] },
  ] },
  { type: 'function', name: 'updateSBTStatus', stateMutability: 'nonpayable', inputs: [{ name: 'user', type: 'address' }, { name: 'status', type: 'bool' }], outputs: [] },
  { type: 'function', name: 'operators', stateMutability: 'view', inputs: [{ name: '', type: 'address' }],
    outputs: [{ name: 'aPNTsBalance', type: 'uint128' }, { name: 'isConfigured', type: 'bool' }, { name: 'isPaused', type: 'bool' },
      { name: 'xPNTsToken', type: 'address' }, { name: 'reputation', type: 'uint32' }, { name: 'minTxInterval', type: 'uint48' },
      { name: 'treasury', type: 'address' }, { name: 'totalSpent', type: 'uint256' }, { name: 'totalTxSponsored', type: 'uint256' }] },
  { type: 'function', name: 'deposit', stateMutability: 'nonpayable', inputs: [{ name: 'amount', type: 'uint256' }], outputs: [] },
  { type: 'function', name: 'updatePrice', stateMutability: 'nonpayable', inputs: [], outputs: [] },
  { type: 'function', name: 'protocolRevenue', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'inflightOf', stateMutability: 'view', inputs: [{ name: 'opHash', type: 'bytes32' }], outputs: [{ name: 'operator', type: 'address' }, { name: 'a0', type: 'uint256' }] },
  { type: 'function', name: 'version', stateMutability: 'view', inputs: [], outputs: [{ type: 'string' }] },
  { type: 'function', name: 'entryPoint', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'REGISTRY', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'APNTS_TOKEN', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'protocolFeeBPS', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'aPNTsPriceUSD', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'priceStalenessThreshold', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'paused', stateMutability: 'view', inputs: [], outputs: [{ type: 'bool' }] },
  { type: 'function', name: 'cachedPrice', stateMutability: 'view', inputs: [], outputs: [{ name: 'price', type: 'int256' }, { name: 'updatedAt', type: 'uint256' }, { name: 'roundId', type: 'uint80' }, { name: 'decimals', type: 'uint8' }] },
  { type: 'function', name: 'ETH_USD_PRICE_FEED', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'isEligibleForSponsorship', stateMutability: 'view', inputs: [{ name: 'u', type: 'address' }], outputs: [{ type: 'bool' }] },
];
export const TOKEN_ABI = [
  { type: 'function', name: 'mint', stateMutability: 'nonpayable', inputs: [{ name: 'to', type: 'address' }, { name: 'amount', type: 'uint256' }], outputs: [] },
  { type: 'function', name: 'approve', stateMutability: 'nonpayable', inputs: [{ name: 'spender', type: 'address' }, { name: 'amount', type: 'uint256' }], outputs: [{ type: 'bool' }] },
  { type: 'function', name: 'transfer', stateMutability: 'nonpayable', inputs: [{ name: 'to', type: 'address' }, { name: 'amount', type: 'uint256' }], outputs: [{ type: 'bool' }] },
  { type: 'function', name: 'balanceOf', stateMutability: 'view', inputs: [{ name: 'a', type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'totalSupply', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'lockedOf', stateMutability: 'view', inputs: [{ name: 'a', type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'debts', stateMutability: 'view', inputs: [{ name: 'a', type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'creditReservedOf', stateMutability: 'view', inputs: [{ name: 'a', type: 'address' }], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'lockOf', stateMutability: 'view', inputs: [{ name: 'h', type: 'bytes32' }, { name: 'u', type: 'address' }],
    outputs: [{ type: 'tuple', components: [{ name: 'xLocked', type: 'uint128' }, { name: 'aReserved', type: 'uint128' }, { name: 'locker', type: 'address' }] }] },
  { type: 'function', name: 'version', stateMutability: 'view', inputs: [], outputs: [{ type: 'string' }] },
  { type: 'function', name: 'exchangeRate', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'SUPERPAYMASTER_ADDRESS', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'maxSingleTxLimit', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint256' }] },
  { type: 'function', name: 'emergencyDisabled', stateMutability: 'view', inputs: [], outputs: [{ type: 'bool' }] },
  { type: 'function', name: 'EXTENSION', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'creditPolicy', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint8' }] },
  { type: 'function', name: 'hasPendingPolicy', stateMutability: 'view', inputs: [], outputs: [{ type: 'bool' }] },
  { type: 'function', name: 'pendingPolicy', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint8' }] },
  { type: 'function', name: 'pendingPolicyEta', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint64' }] },
  { type: 'function', name: 'policyEpoch', stateMutability: 'view', inputs: [], outputs: [{ type: 'uint32' }] },
  { type: 'function', name: 'setAutoAllowance', stateMutability: 'nonpayable', inputs: [{ name: 'spender', type: 'address' }, { name: 'cap', type: 'uint256' }], outputs: [] },
  { type: 'function', name: 'setUserTotalCap', stateMutability: 'nonpayable', inputs: [{ name: 'cap', type: 'uint256' }], outputs: [] },
];
/** Tag a read with the request it makes (method, lower-cased target, function, arguments). */
const tag = (fn, method, address, functionName = '', args = []) => Object.assign(fn, { request: [method, address.toLowerCase(), functionName, ...args.map(String)].join(':').toLowerCase() });
const codeInfo = (a, c) => ({ address: getAddress(a), codehash: c ? keccak256(c) : null, size: c ? (c.length - 2) / 2 : 0 });
const implAddress = s => getAddress('0x' + s.slice(26));

/** Passport at `blockNumber` on client `p`. Round 1 holds every read that needs no other read;
 *  round 2 the five code reads whose address comes from round 1 (SP impl, account impl, xPNTs
 *  clone impl, xPNTs EXTENSION, ETH/USD feed) and the two reads that repeat a round-1 read
 *  (xPNTs clone code, SP entryPoint): viem dedupes identical requests in flight, and the archive
 *  must keep both requests as the sequential reads made them. `e`: addresses and constants of the run. */
export async function readPassport(p, blockNumber, e, pool) {
  const at = { blockNumber };
  const code = a => tag(() => p.getCode({ address: a, ...at }), 'code', a);
  const implSlot = a => tag(() => p.getStorageAt({ address: a, slot: EIP1967_IMPL, ...at }), 'slot', a);
  const spR = (functionName, args = []) => tag(() => p.readContract({ address: e.SPA, abi: SP_ABI, functionName, args, ...at }), 'call', e.SPA, functionName, args);
  const tR = functionName => tag(() => p.readContract({ address: e.spToken, abi: TOKEN_ABI, functionName, ...at }), 'call', e.spToken, functionName);
  const depInfo = a => tag(() => p.readContract({ address: e.EP, abi: EP_DEPOSIT_ABI, functionName: 'getDepositInfo', args: [a], ...at }), 'call', e.EP, 'getDepositInfo', [a]);
  const call = (address, abi, functionName) => tag(() => p.readContract({ address, abi, functionName, ...at }), 'call', address, functionName);
  const vpm = e.baselines.verifyingPaymaster, tpm = e.baselines.tokenPaymaster;
  const ACCOUNT_EP_ABI = [{ type: 'function', name: 'entryPoint', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] }];
  const r = await readRound(pool, {
    tokenCode: code(e.spToken), block: () => p.getBlock({ blockNumber }), op: spR('operators', [e.operator]), price: spR('cachedPrice'),
    depSP: depInfo(e.SPA), depVPM: depInfo(vpm.address), depTPM: depInfo(tpm.address), chainId: () => p.getChainId(),
    epCode: code(e.EP), spCode: code(e.SPA), spImpl: implSlot(e.SPA), extension: tR('EXTENSION'),
    accountCode: code(e.sender), accountImpl: implSlot(e.sender), vpmCode: code(vpm.address), tpmCode: code(tpm.address),
    tpmTokenCode: code(tpm.token), ...(e.formal ? { oracleCode: code(tpm.oracle) } : {}), feed: spR('ETH_USD_PRICE_FEED'),
    version: spR('version'), entryPoint: spR('entryPoint'), registry: spR('REGISTRY'), aPNTs: spR('APNTS_TOKEN'),
    protocolFeeBPS: spR('protocolFeeBPS'), aPNTsPriceUSD: spR('aPNTsPriceUSD'), priceStalenessThreshold: spR('priceStalenessThreshold'),
    paused: spR('paused'), senderEligible: spR('isEligibleForSponsorship', [e.sender]), gasParams: spR('gasParams'),
    tVersion: tR('version'), exchangeRate: tR('exchangeRate'), tSuperPaymaster: tR('SUPERPAYMASTER_ADDRESS'),
    maxSingleTxLimit: tR('maxSingleTxLimit'), emergencyDisabled: tR('emergencyDisabled'),
    policy: tR('creditPolicy'), hasPendingPolicy: tR('hasPendingPolicy'), pendingPolicy: tR('pendingPolicy'),
    pendingPolicyEta: tR('pendingPolicyEta'), policyEpoch: tR('policyEpoch'),
    verifyingSigner: call(vpm.address, vpm.abi, 'verifyingSigner'),
    armEpVPM: call(vpm.address, vpm.abi, 'entryPoint'), armEpTPM: call(tpm.address, tpm.abi, 'entryPoint'),
    armEpAccount: call(e.sender, ACCOUNT_EP_ABI, 'entryPoint'),
  });
  const tokenImpl = /^0x363d3d373d3d3d363d73[0-9a-f]{40}5af43d82803e903d91602b57fd5bf3$/i.test(r.tokenCode) ? getAddress('0x' + r.tokenCode.slice(22, 62)) : null;
  const spImpl = implAddress(r.spImpl), accountImpl = implAddress(r.accountImpl);
  const r2 = await readRound(pool, {
    spImplCode: code(spImpl), ...(tokenImpl ? { tokenImplCode: code(tokenImpl) } : {}), extCode: code(r.extension),
    accountImplCode: code(accountImpl), feedCode: code(r.feed), cloneCode: code(e.spToken), armEpSP: spR('entryPoint'),
  });
  const { op, price } = r;
  const stakeOf = d => ({ staked: d.staked, stake: d.stake, unstakeDelaySec: d.unstakeDelaySec, withdrawTime: d.withdrawTime });
  const depositInfo = { SP: r.depSP, VPM: r.depVPM, TPM: r.depTPM };
  return {
    allowSameEndpointLocal: e.allowSameEndpointLocal,
    chainId: r.chainId,
    block: { number: blockNumber, hash: r.block.hash, timestamp: r.block.timestamp },
    // Everything under `invariant` must be identical at the start and the end of the run.
    invariant: {
      entryPoint: { address: e.EP, isCanonicalV07Address: e.EP.toLowerCase() === CANONICAL_EP_V07.toLowerCase() },
      code: {
        entryPoint: codeInfo(e.EP, r.epCode),
        superPaymasterProxy: codeInfo(e.SPA, r.spCode), superPaymasterImpl: codeInfo(spImpl, r2.spImplCode),
        xPNTsClone: codeInfo(e.spToken, r2.cloneCode), xPNTsImpl: tokenImpl ? codeInfo(tokenImpl, r2.tokenImplCode) : null,
        // Hash what the token and SP actually bind to, not what the deployment config says.
        xPNTsExt: codeInfo(r.extension, r2.extCode),
        account: codeInfo(e.sender, r.accountCode), accountImpl: codeInfo(accountImpl, r2.accountImplCode),
        verifyingPaymaster: codeInfo(vpm.address, r.vpmCode),
        tokenPaymaster: codeInfo(tpm.address, r.tpmCode),
        tokenPaymasterToken: codeInfo(tpm.token, r.tpmTokenCode),
        ...(e.formal ? { tokenPaymasterOracle: codeInfo(tpm.oracle, r.oracleCode) } : {}),
        priceFeed: codeInfo(r.feed, r2.feedCode),
      },
      superPaymaster: {
        version: r.version, entryPoint: r.entryPoint, registry: r.registry,
        aPNTs: r.aPNTs, protocolFeeBPS: r.protocolFeeBPS, aPNTsPriceUSD: r.aPNTsPriceUSD,
        priceStalenessThreshold: r.priceStalenessThreshold, paused: r.paused,
        cachedPrice: { price: price[0], decimals: price[3] },
        operator: { address: e.operator, isConfigured: op[1], isPaused: op[2], xPNTsToken: op[3], minTxInterval: op[5] },
        senderEligible: r.senderEligible,
        minPostOpGas: r.gasParams[0].minPostOpGas,
      },
      xPNTs: { address: e.spToken, version: r.tVersion, exchangeRate: r.exchangeRate,
        superPaymaster: r.tSuperPaymaster, maxSingleTxLimit: r.maxSingleTxLimit, emergencyDisabled: r.emergencyDisabled },
      // Credit OFF for the operator's token (A4 Passport C2/C3). Any change between run_start and
      // run_end is drift; the validator also requires policy OFF and nothing queued.
      credit: { policy: r.policy, hasPendingPolicy: r.hasPendingPolicy,
        pendingPolicy: r.pendingPolicy, pendingPolicyEta: r.pendingPolicyEta, policyEpoch: r.policyEpoch },
      stakes: { SP: stakeOf(r.depSP), VPM: stakeOf(r.depVPM), TPM: stakeOf(r.depTPM) },
      verifyingSigner: r.verifyingSigner,
      // Identical-EntryPoint condition across arms: every paymaster must be bound to EP.
      armEntryPoints: { SP: r2.armEpSP, VPM: r.armEpVPM, TPM: r.armEpTPM, account: r.armEpAccount },
      sender: e.sender, bundler: e.bundler, beneficiary: e.bundler,
      gas: e.gas, pmGas: e.pmGas, callDataHash: e.callDataHash,
    },
    // Recorded, not drift-checked (moves with every op / with time).
    volatile: { cachedPriceUpdatedAt: price[1], operatorBalance: op[0],
      depositInfo: Object.fromEntries(Object.entries(depositInfo).map(([arm, d]) => [arm, {
        deposit: String(d.deposit), staked: d.staked, stake: String(d.stake),
        unstakeDelaySec: String(d.unstakeDelaySec), withdrawTime: String(d.withdrawTime),
      }])) },
  };
}

/** Read-backs of `arm` at `blockNumber` on client `p`, all in one round. */
export async function readReadbacks(p, arm, blockNumber, expectedHash, sender, e, pool) {
  const at = { blockNumber };
  const pm = e.pmAddrOf(arm), tpm = e.baselines.tokenPaymaster;
  const c = (address, abi, functionName, args = []) => tag(() => p.readContract({ address, abi, functionName, args, ...at }), 'call', address, functionName, args);
  const t = (functionName, args = []) => c(e.spToken, TOKEN_ABI, functionName, args);
  const r = await readRound(pool, {
    block: () => p.getBlock({ blockNumber }), epDeposit: c(e.EP, EP_DEPOSIT_ABI, 'balanceOf', [pm]), op: c(e.SPA, SP_ABI, 'operators', [e.operator]),
    ...(arm === 'SP' ? {
      inf: c(e.SPA, SP_ABI, 'inflightOf', [expectedHash]), protocolRevenue: c(e.SPA, SP_ABI, 'protocolRevenue'),
      userXPNTs: t('balanceOf', [sender]), totalSupply: t('totalSupply'), lockedOf: t('lockedOf', [sender]), debts: t('debts', [sender]),
      creditReservedOf: t('creditReservedOf', [sender]), lock: t('lockOf', [expectedHash, sender]),
    } : {}),
    ...(e.formal && arm === 'TPM' ? {
      tpmSender: c(tpm.token, TOKEN_ABI, 'balanceOf', [sender]), tpmPaymaster: c(tpm.token, TOKEN_ABI, 'balanceOf', [tpm.address]),
      tpmCachedPriceTimestamp: c(tpm.address, [{type:'function',name:'cachedPriceTimestamp',stateMutability:'view',inputs:[],outputs:[{type:'uint48'}]}], 'cachedPriceTimestamp'),
    } : {}),
  });
  const out = { blockNumber, blockHash: r.block.hash, epDeposit: r.epDeposit };
  out.operatorBalance = r.op[0]; // Passport anchor at this exact block, including baseline arms.
  if (arm === 'SP') Object.assign(out, {
    operatorBalance: r.op[0], totalSpent: r.op[7], totalTxSponsored: r.op[8],
    protocolRevenue: r.protocolRevenue, inflightOperator: r.inf[0], inflightA0: r.inf[1],
    userXPNTs: r.userXPNTs, totalSupply: r.totalSupply, lockedOf: r.lockedOf, debts: r.debts,
    creditReservedOf: r.creditReservedOf, lockXLocked: r.lock.xLocked,
  });
  if (e.formal && arm === 'TPM') {
    out.tpmTokenBalances = { sender: r.tpmSender, paymaster: r.tpmPaymaster };
    out.tpmCachedPriceTimestamp = r.tpmCachedPriceTimestamp;
  }
  return out;
}
