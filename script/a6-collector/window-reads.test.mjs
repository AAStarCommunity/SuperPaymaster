import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, realpathSync, rmSync, readFileSync } from 'node:fs';
import { join } from 'node:path';
import { getAddress, keccak256, createPublicClient, custom, decodeFunctionData, encodeFunctionResult } from 'viem';
import { CANONICAL_EP_V07 } from './gauge-lib.mjs';
import { READ_CAP, readPool, readRound, readPassport, readReadbacks, EIP1967_IMPL, EP_DEPOSIT_ABI, SP_ABI, TOKEN_ABI } from './window-reads.mjs';
import { archivedRpc } from './formal.mjs';
import { rawArchive } from './evidence.mjs';
import { verifyPassport } from './passport-evidence.mjs';

// Reference: the sequential Passport and read-back bodies of collector.mjs at cd810a8a, with the
// module globals passed in `e`. The concurrent reads must return exactly what these return.
async function sequentialPassport(p, blockNumber, e) {
  const at = { blockNumber };
  const codehash = async (a) => { const c = await p.getCode({ address: a, ...at }); return { address: getAddress(a), codehash: c ? keccak256(c) : null, size: c ? (c.length - 2) / 2 : 0 }; };
  const implOf = async (a) => { const s = await p.getStorageAt({ address: a, slot: EIP1967_IMPL, ...at }); return getAddress('0x' + s.slice(26)); };
  const tokenCode = await p.getCode({ address: e.spToken, ...at });
  const tokenImpl = /^0x363d3d373d3d3d363d73[0-9a-f]{40}5af43d82803e903d91602b57fd5bf3$/i.test(tokenCode) ? getAddress('0x' + tokenCode.slice(22, 62)) : null;
  const block = await p.getBlock({ blockNumber });
  const spR = (functionName, args = []) => p.readContract({ address: e.SPA, abi: SP_ABI, functionName, args, ...at });
  const tR = (functionName, args = []) => p.readContract({ address: e.spToken, abi: TOKEN_ABI, functionName, args, ...at });
  const op = await spR('operators', [e.operator]);
  const price = await spR('cachedPrice');
  const depInfo = async (a) => p.readContract({ address: e.EP, abi: EP_DEPOSIT_ABI, functionName: 'getDepositInfo', args: [a], ...at });
  const depositInfo = { SP: await depInfo(e.SPA), VPM: await depInfo(e.baselines.verifyingPaymaster.address), TPM: await depInfo(e.baselines.tokenPaymaster.address) };
  const stakeOf = (arm) => { const d = depositInfo[arm]; return { staked: d.staked, stake: d.stake, unstakeDelaySec: d.unstakeDelaySec, withdrawTime: d.withdrawTime }; };
  return {
    allowSameEndpointLocal: e.allowSameEndpointLocal,
    chainId: await p.getChainId(),
    block: { number: blockNumber, hash: block.hash, timestamp: block.timestamp },
    // Everything under `invariant` must be identical at the start and the end of the run.
    invariant: {
      entryPoint: { address: e.EP, isCanonicalV07Address: e.EP.toLowerCase() === CANONICAL_EP_V07.toLowerCase() },
      code: {
        entryPoint: await codehash(e.EP),
        superPaymasterProxy: await codehash(e.SPA), superPaymasterImpl: await codehash(await implOf(e.SPA)),
        xPNTsClone: await codehash(e.spToken), xPNTsImpl: tokenImpl ? await codehash(tokenImpl) : null,
        // Hash what the token and SP actually bind to, not what the deployment config says.
        xPNTsExt: await codehash(await tR('EXTENSION')),
        account: await codehash(e.sender), accountImpl: await codehash(await implOf(e.sender)),
        verifyingPaymaster: await codehash(e.baselines.verifyingPaymaster.address),
        tokenPaymaster: await codehash(e.baselines.tokenPaymaster.address),
        tokenPaymasterToken: await codehash(e.baselines.tokenPaymaster.token),
        ...(e.formal ? {tokenPaymasterOracle:await codehash(e.baselines.tokenPaymaster.oracle)} : {}),
        priceFeed: await codehash(await spR('ETH_USD_PRICE_FEED')),
      },
      superPaymaster: {
        version: await spR('version'), entryPoint: await spR('entryPoint'), registry: await spR('REGISTRY'),
        aPNTs: await spR('APNTS_TOKEN'), protocolFeeBPS: await spR('protocolFeeBPS'), aPNTsPriceUSD: await spR('aPNTsPriceUSD'),
        priceStalenessThreshold: await spR('priceStalenessThreshold'), paused: await spR('paused'),
        cachedPrice: { price: price[0], decimals: price[3] },
        operator: { address: e.operator, isConfigured: op[1], isPaused: op[2], xPNTsToken: op[3], minTxInterval: op[5] },
        senderEligible: await spR('isEligibleForSponsorship', [e.sender]),
        minPostOpGas: (await spR('gasParams'))[0].minPostOpGas,
      },
      xPNTs: { address: e.spToken, version: await tR('version'), exchangeRate: await tR('exchangeRate'),
        superPaymaster: await tR('SUPERPAYMASTER_ADDRESS'), maxSingleTxLimit: await tR('maxSingleTxLimit'), emergencyDisabled: await tR('emergencyDisabled') },
      // Credit OFF for the operator's token (A4 Passport C2/C3). Any change between run_start and
      // run_end is drift; the validator also requires policy OFF and nothing queued.
      credit: { policy: await tR('creditPolicy'), hasPendingPolicy: await tR('hasPendingPolicy'),
        pendingPolicy: await tR('pendingPolicy'), pendingPolicyEta: await tR('pendingPolicyEta'), policyEpoch: await tR('policyEpoch') },
      stakes: { SP: stakeOf('SP'), VPM: stakeOf('VPM'), TPM: stakeOf('TPM') },
      verifyingSigner: await p.readContract({ address: e.baselines.verifyingPaymaster.address, abi: e.baselines.verifyingPaymaster.abi, functionName: 'verifyingSigner', ...at }),
      // Identical-EntryPoint condition across arms: every paymaster must be bound to e.EP.
      armEntryPoints: {
        SP: await spR('entryPoint'),
        VPM: await p.readContract({ address: e.baselines.verifyingPaymaster.address, abi: e.baselines.verifyingPaymaster.abi, functionName: 'entryPoint', ...at }),
        TPM: await p.readContract({ address: e.baselines.tokenPaymaster.address, abi: e.baselines.tokenPaymaster.abi, functionName: 'entryPoint', ...at }),
        account: await p.readContract({ address: e.sender, abi: [{ type: 'function', name: 'entryPoint', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] }], functionName: 'entryPoint', ...at }),
      },
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

async function sequentialReadbacks(p, arm, blockNumber, expectedHash, sender, e) {
  const pm = e.pmAddrOf(arm);
    const at = { blockNumber };
    const block = await p.getBlock({ blockNumber });
    const out = { blockNumber, blockHash: block.hash,
      epDeposit: await p.readContract({ address: e.EP, abi: EP_DEPOSIT_ABI, functionName: 'balanceOf', args: [pm], ...at }) };
    const op = await p.readContract({ address: e.SPA, abi: SP_ABI, functionName: 'operators', args: [e.operator], ...at });
    out.operatorBalance = op[0]; // Passport anchor at this exact block, including baseline arms.
    if (arm === 'SP') {
      const inf = await p.readContract({ address: e.SPA, abi: SP_ABI, functionName: 'inflightOf', args: [expectedHash], ...at });
      const t = (functionName, args = []) => p.readContract({ address: e.spToken, abi: TOKEN_ABI, functionName, args, ...at });
      Object.assign(out, {
        operatorBalance: op[0], totalSpent: op[7], totalTxSponsored: op[8],
        protocolRevenue: await p.readContract({ address: e.SPA, abi: SP_ABI, functionName: 'protocolRevenue', ...at }),
        inflightOperator: inf[0], inflightA0: inf[1],
        userXPNTs: await t('balanceOf', [sender]), totalSupply: await t('totalSupply'),
        lockedOf: await t('lockedOf', [sender]), debts: await t('debts', [sender]),
        creditReservedOf: await t('creditReservedOf', [sender]),
        lockXLocked: (await t('lockOf', [expectedHash, sender])).xLocked,
      });
    }
    if (e.formal && arm === 'TPM') {
      const tpm = e.baselines.tokenPaymaster;
      out.tpmTokenBalances = {
        sender:await p.readContract({address:tpm.token, abi:TOKEN_ABI, functionName:'balanceOf', args:[sender], ...at}),
        paymaster:await p.readContract({address:tpm.token, abi:TOKEN_ABI, functionName:'balanceOf', args:[tpm.address], ...at}),
      };
      out.tpmCachedPriceTimestamp = await p.readContract({address:tpm.address, abi:[{type:'function',name:'cachedPriceTimestamp',stateMutability:'view',inputs:[],outputs:[{type:'uint48'}]}],functionName:'cachedPriceTimestamp',...at});
    }
    return out;
}

const A = n => getAddress('0x' + n.toString(16).padStart(40, '0'));
const hex40 = a => a.slice(2).toLowerCase();
const EP = CANONICAL_EP_V07, SPA = A(0x5a), TOKEN = A(0x70c), SENDER = A(0x5e), OPERATOR = A(0x0b);
const IMPL = { [SPA]: A(0x51), [SENDER]: A(0x5f) }, CLONE_IMPL = A(0xc1), EXT = A(0xe7), FEED = A(0xfe);
const baselines = { verifyingPaymaster: { address: A(0x71), abi: [{ type: 'function', name: 'verifyingSigner', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] },
  { type: 'function', name: 'entryPoint', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] }] },
  tokenPaymaster: { address: A(0x72), token: A(0x73), oracle: A(0x74), abi: [{ type: 'function', name: 'entryPoint', stateMutability: 'view', inputs: [], outputs: [{ type: 'address' }] }] } };
const env = (over = {}) => ({ EP, SPA, spToken: TOKEN, sender: SENDER, operator: OPERATOR, baselines, formal: true, allowSameEndpointLocal: false,
  bundler: A(0xb0), gas: { SP: { callGasLimit: 1n } }, pmGas: { SP: { ver: 1n, post: 2n } }, callDataHash: '0x' + '11'.repeat(32),
  pmAddrOf: arm => ({ SP: SPA, VPM: baselines.verifyingPaymaster.address, TPM: baselines.tokenPaymaster.address })[arm], ...over });
const ROUND2 = new Set([IMPL[SPA], IMPL[SENDER], CLONE_IMPL, EXT, FEED].map(a => 'getCode:' + a));

/** Fake endpoint: deterministic answers per call, random latency, records start/end ticks. */
function fakeClient({ clone = true, fail = null, seed = 1 } = {}) {
  let tick = 0, inFlight = 0, rnd = seed;
  const calls = [];
  const c = { calls, maxInFlight: 0 };
  const sleep = () => { rnd = (rnd * 1103515245 + 12345) % 2147483648; return new Promise(r => setTimeout(r, rnd % 7)); };
  const answer = (key, value) => async () => {
    const call = { key, start: ++tick }; calls.push(call);
    inFlight++; c.maxInFlight = Math.max(c.maxInFlight, inFlight);
    try { await sleep(); if (fail && fail === key) throw new Error('boom ' + key); return value(); }
    finally { inFlight--; call.end = ++tick; }
  };
  const read = ({ address, functionName, args = [] }) => {
    const tag = `${functionName}@${address}:${args.join(',')}`;
    const v = { operators: () => [10n, true, false, TOKEN, 3, 5n, A(0x7e), 7n, 8n], cachedPrice: () => [1000n, 99n, 1n, 8],
      getDepositInfo: () => ({ deposit: BigInt(args[0]) % 997n, staked: true, stake: 2n, unstakeDelaySec: 86400, withdrawTime: 0 }),
      gasParams: () => [{ minPostOpGas: 500 }, { eta: 0n }], inflightOf: () => [A(0), 0n], lockOf: () => ({ xLocked: 0n, aReserved: 0n, locker: A(0) }),
      EXTENSION: () => EXT, ETH_USD_PRICE_FEED: () => FEED, entryPoint: () => EP }[functionName];
    return answer('readContract:' + tag, v ?? (() => tag))();
  };
  return Object.assign(c, {
    getCode: ({ address }) => answer('getCode:' + address, () => address === TOKEN && clone ? '0x363d3d373d3d3d363d73' + hex40(CLONE_IMPL) + '5af43d82803e903d91602b57fd5bf3' : '0x60' + hex40(address))(),
    getStorageAt: ({ address, slot }) => answer('getStorageAt:' + address, () => { assert.equal(slot, EIP1967_IMPL); return '0x' + '0'.repeat(24) + hex40(IMPL[address]); })(),
    getBlock: ({ blockNumber }) => answer('getBlock:' + blockNumber, () => ({ number: blockNumber, hash: '0x' + 'ab'.repeat(32), timestamp: 1234n }))(),
    getChainId: () => answer('getChainId', () => 11155420)(),
    readContract: read,
  });
}
const keys = c => c.calls.map(x => x.key).sort();

for (const [label, over, clone] of [['formal clone', {}, true], ['formal no clone', {}, false], ['local', { formal: false, allowSameEndpointLocal: true }, true]]) {
  test(`passport equals the sequential reference (${label}) with the same calls`, async () => {
    const s = fakeClient({ clone }), c = fakeClient({ clone, seed: 7 });
    assert.deepStrictEqual(await readPassport(c, 42n, env(over), readPool(8)), await sequentialPassport(s, 42n, env(over)));
    assert.deepStrictEqual(keys(c), keys(s));
  });
}
for (const arm of ['SP', 'VPM', 'TPM']) for (const formal of [true, false]) {
  test(`readbacks equal the sequential reference (${arm}, formal ${formal}) with the same calls`, async () => {
    const s = fakeClient(), c = fakeClient({ seed: 9 }), h = '0x' + '22'.repeat(32);
    assert.deepStrictEqual(await readReadbacks(c, arm, 42n, h, SENDER, env({ formal }), readPool(8)), await sequentialReadbacks(s, arm, 42n, h, SENDER, env({ formal })));
    assert.deepStrictEqual(keys(c), keys(s));
  });
}
test('cap bounds reads in flight per endpoint and is reached', async () => {
  for (const cap of [1, 3, 8]) {
    const c = fakeClient({ seed: cap });
    await readPassport(c, 42n, env(), readPool(cap));
    assert.equal(c.maxInFlight, cap);
  }
  assert.deepStrictEqual(READ_CAP, { A: 8, B: 8 });
  assert.throws(() => readPool(0), /positive integer/);
});
test('dependent code reads run only in the second round, after every first-round read', async () => {
  const c = fakeClient();
  await readPassport(c, 42n, env(), readPool(8));
  const split = c.calls.findIndex(x => ROUND2.has(x.key)), first = c.calls.slice(0, split), second = c.calls.slice(split);
  assert.ok(!first.some(x => ROUND2.has(x.key)));
  assert.ok(second.every(x => x.start > Math.max(...first.map(y => y.end))));
  assert.equal(first.length, 43); // 41 state reads, the block header and eth_chainId
  assert.deepStrictEqual(second.map(x => x.key).sort(), [...ROUND2, 'getCode:' + TOKEN, 'readContract:entryPoint@' + SPA + ':'].sort());
});
test('a failing read stops the round: no read starts after it, and its cause surfaces', async () => {
  const fail = 'readContract:paused@' + SPA + ':';
  const c = fakeClient({ fail });
  await assert.rejects(readPassport(c, 42n, env(), readPool(4)), /boom readContract:paused/);
  const failed = c.calls.find(x => x.key === fail);
  assert.ok(c.calls.every(x => x.start < failed.end));
  assert.ok(!c.calls.some(x => ROUND2.has(x.key)));
  assert.ok(c.calls.length < 49);
  const r = fakeClient({ fail: 'getBlock:42' });
  await assert.rejects(readReadbacks(r, 'SP', 42n, '0x' + '22'.repeat(32), SENDER, env(), readPool(2)), /boom getBlock:42/);
  assert.ok(r.calls.every(x => x.start < r.calls[0].end || x.key === 'getBlock:42'));
});
test('readRound keeps keys and refuses later reads once one has failed', async () => {
  const pool = readPool(1), started = [];
  const out = readRound(pool, { a: async () => { started.push('a'); throw new Error('first'); }, b: async () => { started.push('b'); return 1; } });
  await assert.rejects(out, /first/);
  assert.deepStrictEqual(started, ['a']);
  assert.deepStrictEqual(await readRound(readPool(2), { x: async () => 1, y: async () => 2 }), { x: 1, y: 2 });
});
test('concurrent Passport through the archived transport: archive in completion order, every read bracketed, verifyPassport accepts', async () => {
  const d = realpathSync(mkdtempSync('/tmp/a6-reads-'));
  try {
    const arc = rawArchive(d, 'A'), abis = [SP_ABI, TOKEN_ABI, EP_DEPOSIT_ABI, baselines.verifyingPaymaster.abi, baselines.tokenPaymaster.abi];
    const gen = o => o.type === 'tuple' ? Object.fromEntries(o.components.map(c => [c.name, gen(c)])) : o.type === 'address' ? A(0x99) : o.type === 'bool' ? false : o.type === 'string' ? 'v1' : 7n;
    const special = { EXTENSION: EXT, ETH_USD_PRICE_FEED: FEED, entryPoint: EP };
    const result = (to, data) => {
      for (const abi of abis) { try {
        const { functionName } = decodeFunctionData({ abi, data }), item = abi.find(x => x.name === functionName);
        let v = functionName in special ? special[functionName] : functionName === 'operators' ? [10n, true, false, TOKEN, 3, 5n, A(0x7e), 7n, 8n]
          : item.outputs.length === 1 ? gen(item.outputs[0]) : item.outputs.map(gen);
        return encodeFunctionResult({ abi, functionName, result: v });
      } catch {} }
      throw new Error('unknown call ' + data.slice(0, 10));
    };
    const serve = (method, params) => ({
      eth_chainId: () => '0xaa37dc',
      eth_getBlockByNumber: () => ({ number: params[0], hash: '0x' + BigInt(params[0]).toString(16).padStart(64, '0'), parentHash: '0x' + '00'.repeat(32), timestamp: '0x4d2', baseFeePerGas: '0x1', gasLimit: '0x1', gasUsed: '0x0', transactions: [] }),
      eth_getCode: () => params[0].toLowerCase() === TOKEN.toLowerCase() ? '0x363d3d373d3d3d363d73' + hex40(CLONE_IMPL) + '5af43d82803e903d91602b57fd5bf3' : '0x60' + hex40(params[0]),
      eth_getStorageAt: () => '0x' + '0'.repeat(24) + hex40(IMPL[getAddress(params[0])]),
      eth_call: () => result(params[0].to, params[0].data ?? params[0].input),
    })[method]();
    let rnd = 3;
    const fetchImpl = async (_url, { body }) => {
      const { id, method, params } = JSON.parse(body);
      rnd = (rnd * 1103515245 + 12345) % 2147483648; await new Promise(r => setTimeout(r, rnd % 9));
      const bytes = Buffer.from(JSON.stringify({ jsonrpc: '2.0', id, result: serve(method, params) }));
      return { ok: true, status: 200, arrayBuffer: async () => bytes };
    };
    const client = createPublicClient({ transport: custom(archivedRpc({ url: 'https://fake.invalid/QzSecretPathQz', endpoint: 'A', append: arc.append, fetchImpl }), { retryCount: 0 }) });
    const p = await readPassport(client, 102n, env(), readPool(8));
    verifyPassport(p, arc.records);
    const lines = readFileSync(join(d, arc.records[0].path), 'utf8').trim().split('\n').map(JSON.parse);
    assert.deepStrictEqual(lines.reduce((m, r) => (m[r.method] = (m[r.method] ?? 0) + 1, m), {}),
      { eth_getBlockByNumber: 97, eth_chainId: 1, eth_call: 32, eth_getCode: 14, eth_getStorageAt: 2 }); // as the sequential reads // 48 fixed-block reads x (header, read, header) + block + chainId
    assert.deepStrictEqual(lines.map(r => r.id), lines.map((_, i) => i + 1)); // archive ids follow completion order
    const rpcIds = lines.map(r => Number(JSON.parse(Buffer.from(r.request, 'base64').toString()).id.split('-')[1]));
    assert.ok(rpcIds.some((id, i) => i && id < rpcIds[i - 1])); // requests completed out of issue order
    for (const r of lines.filter(r => ['eth_call', 'eth_getCode', 'eth_getStorageAt'].includes(r.method))) {
      const fixed = r.method === 'eth_getStorageAt' ? 2 : 1;
      assert.equal(BigInt(r.params[fixed]), BigInt(r.blockAnchor.number));
      assert.equal(BigInt(r.anchor.number), BigInt(r.blockAnchor.number)); assert.equal(r.anchor.hash, r.blockAnchor.hash);
    }
  } finally { rmSync(d, { recursive: true, force: true }); }
});
