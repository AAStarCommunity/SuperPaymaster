#!/usr/bin/env node
// A3a precheck: read-only snapshot of live Sepolia state relevant to runbook step 1 ①–③.
// Usage: RPC_A=<url> RPC_B=<url> [BLOCK=<n>] node scripts/a3a-snapshot.mjs > snapshot.json
// Only eth_call / getCode / getStorageAt / getBalance / getTransactionCount at ONE pinned block.
// RPC URLs are read from the environment and never written to the output.
import { createPublicClient, http, parseAbi, keccak256, toHex } from 'viem';

const A = process.env.RPC_A, B = process.env.RPC_B;
if (!A) { console.error('RPC_A required'); process.exit(2); }
const SP = '0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9';
const REG = '0xf5Bf37ca83AfdAab73691bA7eCcDfA69b8708E71';
const TL = '0x86C86c789EDc099801cc6a5F48334F1D67dC9564';
const SAFE = '0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114';
const EOA = '0xb5600060e6de5E11D3636731964218E53caadf0E';
const ANNI = '0xEcAACb915f7D92e9916f449F7ad42BD0408733c9';
const EP = '0x0000000071727De22E5E9d8BAf0edAc6f37da032';
const IMPL_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc';

const spAbi = parseAbi([
  'function version() view returns (string)',
  'function owner() view returns (address)',
  'function APNTS_TOKEN() view returns (address)',
  'function pendingAPNTsToken() view returns (address)',
  'function pendingAPNTsTokenEta() view returns (uint256)',
  'function APNTS_TOKEN_TIMELOCK() view returns (uint256)',
  'function totalTrackedBalance() view returns (uint256)',
  'function protocolRevenue() view returns (uint256)',
  'function protocolFeeBPS() view returns (uint256)',
  'function priceStalenessThreshold() view returns (uint256)',
  'function cachedPrice() view returns (int256,uint256,uint80,uint8)',
  'function operators(address) view returns (uint128,bool,bool,address,uint32,uint48,address,uint256,uint256)',
]);
const tlAbi = parseAbi([
  'function getMinDelay() view returns (uint256)',
  'function hasRole(bytes32,address) view returns (bool)',
]);
const safeAbi = parseAbi(['function getThreshold() view returns (uint256)', 'function getOwners() view returns (address[])', 'function VERSION() view returns (string)']);
const epAbi = parseAbi(['function getDepositInfo(address) view returns ((uint256 deposit,bool staked,uint112 stake,uint32 unstakeDelaySec,uint48 withdrawTime))']);
const tokAbi = parseAbi(['function version() view returns (string)', 'function symbol() view returns (string)']);
const ROLES = {
  PROPOSER: keccak256(toHex('PROPOSER_ROLE')), CANCELLER: keccak256(toHex('CANCELLER_ROLE')),
  EXECUTOR: keccak256(toHex('EXECUTOR_ROLE')), ADMIN: '0x0000000000000000000000000000000000000000000000000000000000000000',
};

const j = (v) => JSON.parse(JSON.stringify(v, (_, x) => (typeof x === 'bigint' ? x.toString() : x)));

async function read(url, blockNumber) {
  const c = createPublicClient({ transport: http(url, { retryCount: 3, timeout: 30000 }) });
  const bn = blockNumber ?? (await c.getBlockNumber());
  const blk = await c.getBlock({ blockNumber: bn });
  const call = (address, abi, functionName, args = []) =>
    c.readContract({ address, abi, functionName, args, blockNumber: bn }).catch((e) => ({ error: (e.shortMessage || e.message).slice(0, 120) }));
  const slot = async (a) => '0x' + (await c.getStorageAt({ address: a, slot: IMPL_SLOT, blockNumber: bn })).slice(26);
  const out = { blockNumber: bn, blockTimestamp: blk.timestamp, chainId: await c.getChainId() };
  out.sp = {
    address: SP, impl: await slot(SP), version: await call(SP, spAbi, 'version'), owner: await call(SP, spAbi, 'owner'),
    APNTS_TOKEN: await call(SP, spAbi, 'APNTS_TOKEN'), pendingAPNTsToken: await call(SP, spAbi, 'pendingAPNTsToken'),
    pendingAPNTsTokenEta: await call(SP, spAbi, 'pendingAPNTsTokenEta'), APNTS_TOKEN_TIMELOCK: await call(SP, spAbi, 'APNTS_TOKEN_TIMELOCK'),
    totalTrackedBalance: await call(SP, spAbi, 'totalTrackedBalance'), protocolRevenue: await call(SP, spAbi, 'protocolRevenue'),
    protocolFeeBPS: await call(SP, spAbi, 'protocolFeeBPS'), priceStalenessThreshold: await call(SP, spAbi, 'priceStalenessThreshold'),
    cachedPrice: await call(SP, spAbi, 'cachedPrice'),
    entryPointDeposit: await call(EP, epAbi, 'getDepositInfo', [SP]),
    creditPolicy: 'N/A on SuperPaymaster-5.4.2 (creditPolicy is an xPNTs v2 concept introduced by 5.5.0)',
  };
  out.operators = {};
  for (const [name, op] of [['OWNER', EOA], ['ANNI', ANNI]]) {
    const r = await call(SP, spAbi, 'operators', [op]);
    out.operators[name] = Array.isArray(r) ? { address: op, aPNTsBalance: r[0], isConfigured: r[1], isPaused: r[2], xPNTsToken: r[3] } : r;
  }
  const pend = out.sp.pendingAPNTsToken;
  if (typeof pend === 'string' && pend !== '0x0000000000000000000000000000000000000000') {
    const code = await c.getCode({ address: pend, blockNumber: bn });
    out.pendingToken = { address: pend, codeSize: code ? (code.length - 2) / 2 : 0, version: await call(pend, tokAbi, 'version'), symbol: await call(pend, tokAbi, 'symbol') };
  }
  out.registry = { address: REG, impl: await slot(REG), version: await call(REG, spAbi, 'version'), owner: await call(REG, spAbi, 'owner') };
  out.timelock = { address: TL, minDelay: await call(TL, tlAbi, 'getMinDelay'), roles: {} };
  for (const [who, a] of [['deployerEOA', EOA], ['multisig', SAFE]]) {
    out.timelock.roles[who] = {};
    for (const [rn, rh] of Object.entries(ROLES)) out.timelock.roles[who][rn] = await call(TL, tlAbi, 'hasRole', [rh, a]);
  }
  const safeCode = await c.getCode({ address: SAFE, blockNumber: bn });
  out.multisig = { address: SAFE, codeSize: safeCode ? (safeCode.length - 2) / 2 : 0, threshold: await call(SAFE, safeAbi, 'getThreshold'), owners: await call(SAFE, safeAbi, 'getOwners'), version: await call(SAFE, safeAbi, 'VERSION') };
  out.deployerEOA = { address: EOA, nonce: await c.getTransactionCount({ address: EOA, blockNumber: bn }), balanceWei: await c.getBalance({ address: EOA, blockNumber: bn }) };
  out.multisigBalanceWei = await c.getBalance({ address: SAFE, blockNumber: bn });
  return out;
}

const a = await read(A, process.env.BLOCK ? BigInt(process.env.BLOCK) : undefined);
let b = null, diffs = [];
if (B) {
  b = await read(B, a.blockNumber);
  const fa = JSON.stringify(j(a)), fb = JSON.stringify(j(b));
  if (fa !== fb) {
    const walk = (x, y, p) => {
      if (typeof x === 'object' && x && typeof y === 'object' && y) { for (const k of new Set([...Object.keys(x), ...Object.keys(y)])) walk(x[k], y[k], p + '.' + k); }
      else if (JSON.stringify(x) !== JSON.stringify(y)) diffs.push({ path: p, A: x, B: y });
    };
    walk(j(a), j(b), '');
  }
}
console.log(JSON.stringify(j({ generatedAt: new Date().toISOString(), note: 'read-only; RPC URLs omitted', endpointA: 'RPC_A', endpointB: B ? 'RPC_B' : null, crossCheckIdentical: B ? diffs.length === 0 : null, crossCheckDiffs: diffs, snapshot: a }), null, 1));
