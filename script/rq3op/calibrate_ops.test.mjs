import { redact, requireFork } from './calibration_safety.mjs';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import test from 'node:test';
import assert from 'node:assert/strict';
import { concat, encodeAbiParameters, encodeFunctionData, getAddress, keccak256, pad, toHex, parseAbi } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';

// Execute the CLI through its guards with an in-memory RPC stub; no sockets or writes.
const source = readFileSync(new URL('./calibrate_ops.mjs', import.meta.url), 'utf8');
const start = source.indexOf('const [requestPath]');
const end = source.indexOf('const bytes = readFileSync(req.bundlePath)');
const guard = source.slice(start, end).replace(/const EP_ABI = parseAbi\([\s\S]*?const lower = v => String\(v\).toLowerCase\(\);/, '');
async function run(url, chain) {
  let calls = 0;
  const context = vm.createContext({
    redact, requireFork: (req, rpc) => requireFork(req, rpc, () => {}),
    process: { argv: ['node', 'helper', 'request'] },
    readFileSync: () => JSON.stringify({ forkUrl: url, forkPid: 123, forkPin: 456 }),
    getAddress: x => x,
    fetch: async (_, options) => { calls++; const { method } = JSON.parse(options.body); return { json: async () => ({ result: method === 'web3_clientVersion' ? 'anvil/v1' : method === 'anvil_nodeInfo' ? { forkConfig: { forkBlockNumber: 456 } } : `0x${chain.toString(16)}` }) }; },
  });
  await vm.runInContext(`(async () => { ${guard} })()`, context);
  return calls;
}
for (const chain of [11155111, 11155420]) {
  test(`accept local chain ${chain}`, async () => assert.equal(await run('http://127.0.0.1:18555', chain), 3));
}
test('reject other chain', async () => assert.rejects(run('http://127.0.0.1:18555', 31337), /chainId/));
for (const url of ['https://example.com', 'http://localhost:18555', 'http://127.0.0.1:18555@evil.test']) {
  test(`reject URL ${url}`, async () => assert.rejects(run(url, 11155420), /fork URL/));
}

test('RPC errors never print upstream URL or data', async () => {
  const context = vm.createContext({
    redact, requireFork: (req, rpc) => requireFork(req, rpc, () => {}),
    process: { argv: ['node', 'helper', 'request'] },
    readFileSync: () => JSON.stringify({ forkUrl: 'http://127.0.0.1:18555' }),
    getAddress: x => x,
    fetch: async () => ({ json: async () => ({ error: {
      message: 'https://host/v2/SECRET wss://host/SECRET', data: 'SECRET',
    }, result: '0xaa37dc' }) }),
  });
  await assert.rejects(vm.runInContext(`(async () => { ${guard} })()`, context), error => {
    assert.doesNotMatch(String(error) + JSON.stringify(error), /SECRET/);
    return true;
  });
});

for (const [client, pin, dead] of [['geth/v1', 456, false], ['anvil/v1', 457, false], ['anvil/v1', 456, true]]) {
  test(`refuse foreign/stale fork ${client} ${pin} ${dead}`, async () => {
    const rpc = async method => method === 'web3_clientVersion' ? client : { forkConfig: { forkBlockNumber: pin } };
    await assert.rejects(requireFork({ forkPid: 123, forkPin: 456 }, rpc, () => { if (dead) throw Error(); }), /live child anvil/);
  });
}
test('metadata fallback and child exit during verification', async () => {
  const rpc = async method => {
    if (method === 'web3_clientVersion') return 'anvil/v1';
    if (method === 'anvil_nodeInfo') throw Error();
    return { forkedNetwork: { forkBlockNumber: '0x1c8' } };
  };
  await requireFork({ forkPid: 123, forkPin: 456 }, rpc, () => {});
  let calls = 0;
  await assert.rejects(requireFork({ forkPid: 123, forkPin: 456 }, rpc, () => { if (++calls === 2) throw Error(); }));
});
test('shared redaction covers every URL scheme and opaque file contents', () => {
  assert.doesNotMatch(redact('HTTP://host/SECRET https://host/v2/SECRET ws://host/SECRET WSS://host/SECRET'), /SECRET/);
  assert.doesNotMatch(redact('BARE_FILE_SECRET', true), /SECRET/);
});
test('direct helper invocation requires a child PID and pin', async () => {
  await assert.rejects(requireFork({}, async () => { throw Error('must not call'); }), /PID and fork pin required/);
});

// K1b warm-up: run the senders/rounds loop of calibrate_ops.mjs against an in-memory RPC stub and
// check that one warm-up pass per sender (SP, then VPM, then TPM, at the frozen bounds) precedes
// every measurement round, so the first recorded measurement of each arm happens at nonce >= 1.
test('calibration warm-up sends SP,VPM,TPM once per sender before any measurement (nonce >= 1)', async () => {
  const start = source.indexOf('const senders = Object.keys(bundle.plans);');
  const end = source.indexOf('writeFileSync(req.out,');
  assert.ok(start !== -1 && end > start);
  const loop = source.slice(start, end);
  const EP = getAddress('0x0000000071727De22E5E9d8BAf0edAc6f37da032');
  const PM = getAddress('0x' + '77'.repeat(20));
  const BUNDLER = getAddress('0x' + '88'.repeat(20));
  const OPERATOR = getAddress('0x' + '99'.repeat(20));
  const OWNER = '0x' + 'aa'.repeat(20);
  const CALLDATA = '0xdeadbeef';
  const EP_ABI = parseAbi([
    'function getNonce(address sender, uint192 key) view returns (uint256)',
    'function getUserOpHash((address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData,bytes signature) op) view returns (bytes32)',
    'function handleOps((address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData,bytes signature)[] ops,address beneficiary)',
  ]);
  const SEL = { validateUserOp: '0x19822f7c', validatePaymasterUserOp: '0x52b7512c', postOp: '0x7c627b21', innerHandleOp: '0x0042dc53', execute: '0xb61d27f6' };
  const lower = v => String(v).toLowerCase();
  const frames = root => { const list = []; const walk = (f, parent) => { list.push({ ...f, parent }); for (const c of f.calls || []) walk(c, f); }; walk(root, null); return list; };
  const forkKey = label => keccak256(toHex(`rq3-calib/fork-only/${label}`));
  const gasFields = () => ({ verificationGasLimit: 300000n, callGasLimit: 100000n, preVerificationGas: 60000n, maxFeePerGas: 1000000000n, maxPriorityFeePerGas: 1000000000n });
  const senders = ['0x' + '11'.repeat(20), '0x' + '22'.repeat(20)].map(getAddress);
  const ownersByS = new Map(senders.map((s, si) => [s, privateKeyToAccount(forkKey(`owner-${si}`))]));
  const nonces = new Map();
  const out = { forkSubstitutions: [], ops: [] };
  let lastS = null, planSeq = 0;
  const rpc = async (method, params = []) => {
    switch (method) {
      case 'eth_getStorageAt': return '0x' + '00'.repeat(24) + OWNER.slice(2);
      case 'anvil_setStorageAt': case 'evm_mine': case 'evm_setNextBlockTimestamp': return true;
      case 'eth_getBlockByNumber': return { timestamp: '0x64', number: '0xf' };
      case 'eth_sendTransaction': nonces.set(lastS, (nonces.get(lastS) ?? 0n) + 1n); return '0x' + 'ab'.repeat(32);
      case 'eth_getTransactionReceipt': return { status: '0x1', blockNumber: '0x10', blockHash: '0x' + '66'.repeat(32), gasUsed: '0x5208', logs: [] };
      case 'debug_traceTransaction': return { from: BUNDLER, to: EP, input: '0x', gas: '0xffff', gasUsed: '0xffff', calls: [
        { from: EP, to: lastS, input: SEL.validateUserOp + '00', gas: '0x1000', gasUsed: '0x100', calls: [] },
        { from: EP, to: PM, input: SEL.validatePaymasterUserOp + '00', gas: '0x1000', gasUsed: '0x200', calls: [] },
        { from: EP, to: EP, input: SEL.innerHandleOp + '00', gas: '0x1000', gasUsed: '0x10', calls: [
          { from: EP, to: lastS, input: CALLDATA, gas: '0x1000', gasUsed: '0x300', calls: [] }] },
        { from: EP, to: PM, input: SEL.postOp + '00', gas: '0x1000', gasUsed: '0x400', calls: [] },
      ] };
      default: throw Error('unexpected rpc ' + method);
    }
  };
  const call = async (to, abi, functionName, args = []) => {
    if (functionName === 'getNonce') { lastS = getAddress(args[0]); return nonces.get(lastS) ?? 0n; }
    if (functionName === 'getUserOpHash') return '0x' + '11'.repeat(32);
    if (functionName === 'getHash') return '0x' + '22'.repeat(32);
    if (functionName === 'owner') return ownersByS.get(getAddress(to)).address;
    throw Error('unexpected call ' + functionName);
  };
  const createFrozenPlan = ({ account }) => ({
    plan: {
      planIndex: planSeq++, chainId: 11155111,
      phaseC: {
        addresses: { S: getAddress(account), SP: PM, VPM: PM, TPM: PM, X: PM },
        bounds: { SP: { outer: '1000000' }, VPM: { outer: '1000000' }, TPM: { outer: '1000000' } },
        pvgLengths: { SP: {}, VPM: {}, TPM: {} },
        pvgReserve: { SP: 1000n, VPM: 1000n, TPM: 1000n },
        minTxInterval: 0, spBranch: 'balance',
      },
      externalInputs: { data: { phaseC: { accountOwner: OWNER } } },
      deploymentContext: { operator: OPERATOR },
    },
    frozen: {
      gas: { SP: gasFields(), VPM: gasFields(), TPM: gasFields() },
      pmGas: { SP: { ver: 100000n, post: 50000n }, VPM: { ver: 100000n, post: 50000n }, TPM: { ver: 150000n, post: 120000n } },
      callData: CALLDATA,
      fees: { maxFeePerGas: 1000000000n, maxPriorityFeePerGas: 1000000000n },
    },
  });
  const sandbox = {
    req: { rounds: 1, search: false, out: '/dev/null' },
    bundle: { plans: Object.fromEntries(senders.map(s => [s, {}])) },
    bytes: 'bundle', bundleSha256: 'sha',
    createFrozenPlan, rpc, call, pinNextTimestamp: async () => {},
    EP, EP_ABI, VPM_ABI: [], OWNER_ABI: [], SP: PM, VPM: PM, TPM: PM, X: PM,
    bundler: BUNDLER, operator: OPERATOR, chain: 11155111n,
    vSigner: privateKeyToAccount(forkKey('verifying-signer')),
    u128: v => pad(toHex(v), { size: 16 }), forkKey, out, frames, SEL, lower, redact,
    getAddress, concat, encodeAbiParameters, encodeFunctionData, keccak256, pad, toHex, privateKeyToAccount,
    finalizePVG: async sign => { const r = await sign(60000n); return { ...r, pvg: { value: 60000n } }; },
    measurePVG: () => ({ value: 60000n }), checkPVGLengths: () => {},
    localUserOpHash: () => '0x' + '11'.repeat(32),
    classifyAttempt: () => ({ verdict: 'USEROP_SUCCESS', event: { success: true, actualGasUsed: 100n, actualGasCost: 50n } }),
    VERDICTS: { USEROP_SUCCESS: 'USEROP_SUCCESS' },
    settlementBranch: () => ({}), settlementSignatures: {},
  };
  await vm.runInContext('(async () => { ' + loop + ' })()', vm.createContext(sandbox));
  const ops = out.ops;
  assert.equal(ops.length, 12); // 2 senders x (3 warm-up ops + 3 measurement ops at rounds=1)
  for (const S of senders) {
    const mine = ops.filter(o => o.sender === S);
    assert.deepEqual(mine.map(o => [o.arm, o.round, o.warmup]), [
      ['SP', -1, true], ['VPM', -1, true], ['TPM', -1, true],
      ['SP', 0, false], ['VPM', 0, false], ['TPM', 0, false]]);
    assert.deepEqual(mine.map(o => o.nonce), ['0', '1', '2', '3', '4', '5']);
    for (const op of mine.slice(0, 3)) { assert.equal(op.minima, null); assert.equal(op.measurement, null); }
    for (const arm of ['SP', 'VPM', 'TPM']) {
      const measured = mine.filter(o => o.arm === arm && o.measurement);
      assert.equal(measured.length, 1);
      assert.ok(BigInt(measured[0].nonce) >= 1n, arm + ' first measurement at nonce ' + measured[0].nonce);
    }
  }
});
