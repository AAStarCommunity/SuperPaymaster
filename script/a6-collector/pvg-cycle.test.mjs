// Real 2-cycles of the signed PVG fixed point observed on the attempt1 Sepolia fork (REHEARSAL,
// fork-verify run, TPM arm). The account signature is deterministic (RFC 6979) and changes with the PVG
// word; one signature byte toggles between 0x00 and non-zero, so the rule value alternates by 12 gas
// (27196 <-> 27208) and no exact fixed point exists. Fixture: pvg-cycle-fixture.json, built by
// script/rq3op/pvg_cycle_fixture.mjs from the fork evidence; the owner key is a public fork-only scalar.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { encodeFunctionData, keccak256, parseAbi, toHex } from 'viem';
import { privateKeyToAccount } from 'viem/accounts';
import { localUserOpHash } from './gauge-lib.mjs';
import { finalizePVG, measurePVG, recordPVG } from './pvg.mjs';

const cases = JSON.parse(readFileSync(new URL('./pvg-cycle-fixture.json', import.meta.url)));
const abi = parseAbi(['function handleOps((address sender,uint256 nonce,bytes initCode,bytes callData,bytes32 accountGasLimits,uint256 preVerificationGas,bytes32 gasFees,bytes paymasterAndData,bytes signature)[] ops,address beneficiary)']);
const signer = c => {
  // Public fork-only test scalar: keccak256 of a label, never a real key.
  const owner = privateKeyToAccount(keccak256(toHex(c.forkOnlyOwnerKeyLabel)));
  const base = { ...c.op, nonce: BigInt(c.op.nonce) };
  return async value => {
    const packed = { ...base, preVerificationGas: value, signature: '0x' };
    const hash = localUserOpHash(packed, c.entryPoint, BigInt(c.chainId));
    packed.signature = await owner.signMessage({ message: { raw: hash } });
    return { packed, hash };
  };
};

for (const c of cases) {
  test(`fixture reproduces the recorded op and has no exact fixed point: ${c.source}`, async () => {
    const sign = signer(c);
    const top = c.recordedSequence.map(BigInt).reduce((x, y) => (x > y ? x : y));
    assert.equal((await sign(top)).hash, c.recordedUserOpHash);
    const cycle = [...new Set(c.recordedSequence.slice(1))].map(BigInt);
    for (const v of cycle) assert.notEqual(measurePVG((await sign(v)).packed, c.beneficiary).value, v);
  });

  test(`signed PVG 2-cycle resolves at the cycle maximum with a declared surplus: ${c.source}`, async () => {
    const sign = signer(c);
    const result = await finalizePVG(sign, c.beneficiary, { lengths: c.lengths, reserve: c.reserve });
    const top = c.recordedSequence.map(BigInt).reduce((x, y) => (x > y ? x : y));
    assert.equal(result.packed.preVerificationGas, top);
    assert.equal(result.pvg.value, top);
    const rule = measurePVG(result.packed, c.beneficiary).value;
    assert.equal(result.pvg.ruleValue, rule);
    assert.equal(result.pvg.surplus, top - rule);
    assert.ok(result.pvg.surplus > 0n && result.pvg.surplus % 12n === 0n);
    assert.equal(result.pvg.resolution, 'cycle-max');
    assert.ok(top <= BigInt(c.reserve));
    // The data row stays consistent with the actual transaction input: consistency equals the declared surplus.
    const input = encodeFunctionData({ abi, functionName: 'handleOps', args: [[result.packed], c.beneficiary] });
    const row = {};
    recordPVG(row, result.pvg, input);
    assert.equal(row.pvgConsistency, result.pvg.surplus);
  });
}

test('an undeclared surplus is still refused (PVG_CONSISTENCY)', async () => {
  const c = cases[0], sign = signer(c);
  const result = await finalizePVG(sign, c.beneficiary, { lengths: c.lengths, reserve: c.reserve });
  const input = encodeFunctionData({ abi, functionName: 'handleOps', args: [[result.packed], c.beneficiary] });
  assert.throws(() => recordPVG({}, { ...result.pvg, surplus: 0n }, input), /PVG_CONSISTENCY/);
});

test('a cycle whose maximum exceeds the reserve is refused (PVG_RESERVE)', async () => {
  const c = cases[0], sign = signer(c);
  const top = c.recordedSequence.map(BigInt).reduce((x, y) => (x > y ? x : y));
  await assert.rejects(finalizePVG(sign, c.beneficiary, { lengths: c.lengths, reserve: String(top - 1n) }), /PVG_RESERVE/);
});
