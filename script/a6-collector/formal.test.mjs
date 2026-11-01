import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, writeFileSync, readFileSync, rmSync, closeSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { decodeFunctionData, encodeFunctionData, keccak256, parseAbi, parseTransaction, serializeTransaction, recoverTransactionAddress } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { endpointPair, guardRequest, formalConfig, taskCallData, armOrder, feePause, requirePostGas, archivedRpc, formalRuntime, castSigner, prepareSimpleAccount } from './formal.mjs';
const address = n => `0x${n.toString(16).padStart(40, '0')}`;
const hash = `0x${'ab'.repeat(32)}`;
function config() {
  return { frozen: true, chainId: 31337, operator: address(9), factory: address(8), sender: address(7), salt: '0', bundlerGasLimit: '3000000',
    accounts: Object.fromEntries(['owner', 'bundler', 'verifyingSigner'].map((r, i) => [r, { name: r, address: address(i + 1) }])),
    fees: { maxFeePerGas: '5000000000', maxPriorityFeePerGas: '1000000000' }, task: { token: address(4), recipient: address(5) },
    gas: Object.fromEntries(armOrder(0).map(arm => [arm, { callGasLimit: '100000', verificationGasLimit: '300000', preVerificationGas: '60000', paymasterVerificationGasLimit: '450000', paymasterPostOpGasLimit: '480000' }])) };
}
test('formal endpoint guards normalize host/port without leaking URLs', () => {
  for (const a of ['http://localhost:8545', 'http://127.0.0.1:8545', 'http://127.1:1', 'http://[::1]:1', 'http://LOCALHOST.:1']) assert.throws(() => endpointPair(a, 'https://other.invalid'), /remote/);
  assert.throws(() => endpointPair('https://a.invalid/secret1', 'https://A.invalid:443/secret2'), /same host/);
  assert.doesNotThrow(() => endpointPair('https://a.invalid/secret', 'https://b.invalid/secret'));
});
test('formal RPC guards refuse development methods and unpinned state', () => {
  for (const method of ['anvil_setBalance', 'anvil_impersonateAccount', 'hardhat_setCode', 'evm_mine']) assert.throws(() => guardRequest(method, []), /forbidden/);
  for (const method of ['eth_call', 'eth_getCode', 'eth_getBalance', 'eth_getTransactionCount']) {
    for (const tag of [undefined, 'latest', 'pending', 'safe']) assert.throws(() => guardRequest(method, [address(1), tag]), /fixed/);
    assert.doesNotThrow(() => guardRequest(method, [address(1), '0x1']));
  }
});
test('matrix transfer and callDataHash; legacy empty call refused', () => {
  const c = config(), data = taskCallData(c.task);
  const abi = parseAbi(['function execute(address dest,uint256 value,bytes func)', 'function transfer(address to,uint256 amount) returns (bool)']);
  const outer = decodeFunctionData({ abi, data });
  assert.deepEqual(outer.args.slice(0, 2), [c.task.token, 0n]);
  assert.deepEqual(decodeFunctionData({ abi, data: outer.args[2] }).args, [c.task.recipient, 1n]);
  assert.equal(keccak256(data), keccak256(formalConfig(c, 1).callData));
  assert.throws(() => taskCallData(c.task, encodeFunctionData({ abi, functionName: 'execute', args: ['0x000000000000000000000000000000000000dEaD', 0n, '0x'] })), /calldata/);
});
test('rotation uses triple index and repeats every three triples', () => {
  assert.deepEqual([0, 1, 2, 3].map(armOrder), [['SP','VPM','TPM'], ['VPM','TPM','SP'], ['TPM','SP','VPM'], ['SP','VPM','TPM']]);
});
test('frozen fees, B_max, separate accounts and pinned gas minimum enforced', () => {
  const c = config();
  assert.equal(formalConfig(c, 1).gas.TPM.maxFeePerGas, 5000000000n);
  assert.throws(() => formalConfig(c, 2), /B_max/);
  requirePostGas(480000n, 480000n);
  assert.throws(() => requirePostGas(480000n, 480001n), /pinned/);
  for (const mutate of [c => c.frozen = false, c => c.fees.maxFeePerGas = '20000000000', c => c.gas.SP.paymasterPostOpGasLimit = '200000', c => c.accounts.bundler = c.accounts.owner]) {
    const bad = config(); mutate(bad); assert.throws(() => formalConfig(bad, 1));
  }
});
test('fee cap retains a NOT_SENT row with the observed block; equality is allowed', () => {
  const block = { number: 42n, hash, baseFeePerGas: 5000000001n };
  const r = feePause(block, 5000000000n);
  assert.equal(r.verdict, 'NOT_SENT'); assert.equal(r.reason, 'basefee_above_cap'); assert.equal(r.tx, null);
  assert.deepEqual(r.feeBlock, { number: 42n, hash }); assert.equal(r.baseFeePerGas, block.baseFeePerGas);
  assert.equal(feePause({ ...block, baseFeePerGas: 5000000000n }, 5000000000n), null);
});
test('dual raw archive preserves every exact request/response including RPC errors and malformed JSON', async () => {
  for (const endpoint of ['A', 'B']) {
    const records = [], sent = [], received = [];
    const rpc = archivedRpc({ endpoint, url: 'https://secret.invalid/token', append: r => records.push(r), fetchImpl: async (_, { body }) => {
      sent.push(body); const r = JSON.parse(body);
      const result = r.method === 'eth_getBlockByNumber' ? { number: '0x2a', hash } : '0x01';
      const text = r.method === 'bad' ? '{broken' : JSON.stringify({ jsonrpc: '2.0', id: r.id, ...(r.method === 'error' ? { error: { code: -32000, message: 'secret.invalid' } } : { result }) }, null, 2) + '\n';
      received.push(text); return new Response(text);
    } });
    assert.equal(await rpc.request({ method: 'eth_call', params: [{ to: address(1), data: '0x' }, '0x2a'] }), '0x01');
    await assert.rejects(rpc.request({ method: 'error' }), e => !e.message.includes('secret.invalid'));
    await assert.rejects(rpc.request({ method: 'bad' }), /error -32000/);
    assert.equal(records.length, 4); assert.equal(rpc.ids.length, 4);
    records.forEach((r, i) => {
      assert.equal(Buffer.from(r.requestBase64, 'base64').toString(), sent[i]);
      assert.equal(Buffer.from(r.responseBase64, 'base64').toString(), received[i]);
      assert.ok(r.requestedAtUtc && r.receivedAtUtc); assert.equal(r.id, rpc.ids[i]);
    });
    assert.deepEqual(records[1].anchor, { number: '0x2a', hash });
  }
});
test('transport failure archived; reorg refused without overwriting the first anchor', async () => {
  const rows = []; let n = 0;
  const rpc = archivedRpc({ endpoint: 'A', url: 'https://hidden.invalid', append: r => rows.push(r), fetchImpl: async (_, { body }) => {
    const r = JSON.parse(body); n++;
    if (n === 3) throw new Error('hidden.invalid credential');
    return new Response(JSON.stringify({ jsonrpc: '2.0', id: r.id, result: { number: '0x1', hash: n === 1 ? hash : `0x${'cd'.repeat(32)}` } }));
  } });
  await rpc.request({ method: 'eth_getBlockByNumber', params: ['0x1', false] });
  await assert.rejects(rpc.request({ method: 'eth_getBlockByNumber', params: ['0x1', false] }), /hash changed/);
  await assert.rejects(rpc.request({ method: 'eth_chainId' }), /hash changed/);
  assert.equal(rows.length, 2);
  assert.ok(!JSON.stringify(rows).includes('hidden.invalid'));
});
test('formal runtime uses injected separate signers, archives signed transactions, never loads development keys', async () => {
  const dir = mkdtempSync(join(tmpdir(), 'a6-formal-'));
  const c = config(), signers = {};
  // Synthetic test-only keys, unrelated to any keystore or Anvil account.
  for (const [i, role] of ['owner', 'bundler', 'verifyingSigner'].entries()) {
    signers[role] = privateKeyToAccount(`0x${String(i + 1).repeat(64)}`);
    c.accounts[role].address = signers[role].address;
  }
  let runtime;
  try {
    for (const e of ['a', 'b']) writeFileSync(join(dir, e), `https://${e}.invalid/secret`);
    const calls = [];
    let baseFeePerGas = '0x1';
    runtime = await formalRuntime({ resolver: async h => [{address:h.startsWith('a')?'8.8.8.8':'1.1.1.1'}], config: c, rpcAFile: join(dir, 'a'), rpcBFile: join(dir, 'b'), outPath: join(dir, 'run'),
      createSigner: (account, role) => { assert.equal(account.name, role); return signers[role]; },
      fetchImpl: async (_, { body }) => {
        const r = JSON.parse(body); calls.push(r);
        const results = { eth_blockNumber: '0x2a', eth_chainId: '0x7a69', eth_getTransactionCount: '0x0', eth_sendRawTransaction: hash,
          eth_getBlockByNumber: { number: '0x2a', hash, baseFeePerGas, timestamp: '0x1', transactions: [] }, eth_call: '0x' };
        assert.ok(r.method in results, `unexpected RPC ${r.method}`);
        return new Response(JSON.stringify({ jsonrpc: '2.0', id: r.id, result: results[r.method] }));
      } });
    assert.throws(() => runtime.pubA.readContract({ address: address(1), abi: parseAbi(['function x() view returns (uint256)']), functionName: 'x', blockTag: 'latest' }), /fixed pin/);
    await runtime.refreshPin();
    const txHash = await runtime.writeContract({ address: address(1), abi: parseAbi(['function go()']), functionName: 'go' });
    assert.equal(txHash, hash);
    const tx = parseTransaction(calls.find(r => r.method === 'eth_sendRawTransaction').params[0]);
    assert.equal(tx.maxFeePerGas, 5000000000n); assert.equal(tx.maxPriorityFeePerGas, 1000000000n);
    baseFeePerGas = '0x12a05f201'; // 5 gwei + 1 wei
    await assert.rejects(runtime.writeContract({ address: address(1), abi: parseAbi(['function go()']), functionName: 'go' }), e => e.pause?.reason === 'basefee_above_cap' && e.pause.baseFeePerGas === 5000000001n);
    assert.equal(calls.filter(r => r.method === 'eth_sendRawTransaction').length, 1, 'pause must not submit a second transaction');
    for (const a of runtime.archives) assert.equal(readFileSync(join(dir,a.records[0].path), 'utf8').trim().split('\n').length, a.ids.length);
    assert.ok(!calls.some(r => /^(anvil|hardhat)_/.test(r.method)));
    assert.ok(!readFileSync(new URL('./formal.mjs', import.meta.url), 'utf8').includes('ANVIL_KEYS'));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
test('Foundry digest adapter checks the actual recovered signer', async () => {
  const account = privateKeyToAccount(`0x${'4'.repeat(64)}`), message = { raw: hash };
  const signature = await account.signMessage({ message });
  const signer = castSigner({ name: 'test-owner', address: account.address }, 'owner', (cmd, args) => {
    assert.equal(cmd, 'cast'); assert.deepEqual(args.slice(0, 6), ['wallet', 'sign', '--account', 'test-owner', '--no-hash', args[5]]);
    return signature;
  });
  assert.equal(await signer.signMessage({ message }), signature);
  await assert.rejects(castSigner({ name: 'wrong', address: address(1) }, '', () => signature).signMessage({ message }), /mismatch/);
});

test('factory account creation verifies counterfactual address, deployment and owner', async () => {
  for (const mode of ['create', 'existing', 'wrong-counterfactual', 'no-code', 'wrong-owner']) {
    const c = config(); let deployed = mode === 'existing', sends = 0;
    const pub = { readContract: async ({ functionName }) => functionName === 'getAddress'
      ? (mode === 'wrong-counterfactual' ? address(99) : c.sender)
      : (mode === 'wrong-owner' ? address(99) : c.accounts.owner.address),
    getCode: async () => deployed ? '0x6000' : '0x',
    waitForTransactionReceipt: async () => ({ status: 'success', blockHash: hash }) };
    const runtime = { pubA: pub, pubB: pub, accounts: { owner: c.accounts.owner }, refreshPin: async () => {},
      writeContract: async args => { assert.equal(args.address, c.factory); assert.equal(args.functionName, 'createAccount'); sends++; deployed = mode !== 'no-code'; return hash; } };
    const run = () => prepareSimpleAccount({ config: c, runtime, readAB: async (_, fn) => ({ value: await fn(pub) }) });
    if (mode.startsWith('wrong') || mode === 'no-code') await assert.rejects(run());
    else { const result = await run(); assert.equal(result.sender, c.sender); assert.equal(result.created, mode === 'create'); }
    assert.equal(sends, ['existing', 'wrong-counterfactual'].includes(mode) ? 0 : 1);
  }
});

test('Foundry adapter serializes a verifiable EIP-1559 transaction offline', async () => {
  const account = privateKeyToAccount(`0x${'5'.repeat(64)}`);
  const tx = { type: 'eip1559', chainId: 31337, nonce: 0, to: address(1), gas: 21000n, maxFeePerGas: 5000000000n, maxPriorityFeePerGas: 1000000000n, value: 0n };
  const { r, s, v } = parseTransaction(await account.signTransaction(tx));
  const signature = `${r}${s.slice(2)}${v.toString(16).padStart(2, '0')}`;
  const signer = castSigner({ name: 'offline-test', address: account.address }, 'bundler', (_, args) => {
    assert.equal(args.at(-1), keccak256(serializeTransaction(tx)));
    return signature;
  });
  const serialized = await signer.signTransaction(tx);
  assert.equal(await recoverTransactionAddress({ serializedTransaction: serialized }), account.address);
});
