#!/usr/bin/env node
// A3a precheck: read-only. Compute the Safe transaction hashes for the two multisig steps
// (timelock schedule / execute of APNTsCapped.acceptOwnership), plus Safe owner balances and
// fee data, at the pinned block. Usage: RPC_A=<url> BLOCK=<n> SIM=<fork-sim dir> node scripts/a3a-safe-payloads.mjs
import { createPublicClient, http, parseAbi, keccak256 } from 'viem';
import { readFileSync } from 'node:fs';

const c = createPublicClient({ transport: http(process.env.RPC_A, { retryCount: 3, timeout: 30000 }) });
const bn = BigInt(process.env.BLOCK);
const sim = process.env.SIM;
const SAFE = '0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114';
const Z = '0x0000000000000000000000000000000000000000';
const abi = parseAbi([
  'function nonce() view returns (uint256)',
  'function getOwners() view returns (address[])',
  'function getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256) view returns (bytes32)',
]);
const addrs = JSON.parse(readFileSync(`${sim}/addresses.json`, 'utf8'));
const sched = readFileSync(`${sim}/S5-schedule.calldata`, 'utf8').trim();
const exec = readFileSync(`${sim}/S6-execute.calldata`, 'utf8').trim();
const nonce = await c.readContract({ address: SAFE, abi, functionName: 'nonce', blockNumber: bn });
const owners = await c.readContract({ address: SAFE, abi, functionName: 'getOwners', blockNumber: bn });
const hash = (data, n) => c.readContract({ address: SAFE, abi, functionName: 'getTransactionHash', args: [addrs.newTimelock, 0n, data, 0, 0n, 0n, 0n, Z, Z, n], blockNumber: bn });
const blk = await c.getBlock({ blockNumber: bn });
const out = {
  pinnedBlock: bn.toString(), safe: SAFE, safeNonceAtPin: nonce.toString(),
  steps: [
    { step: 'S5', to: addrs.newTimelock, value: '0', operation: 0, data: sched, dataKeccak: keccak256(sched), safeNonce: nonce.toString(), safeTxHash: await hash(sched, nonce) },
    { step: 'S6', to: addrs.newTimelock, value: '0', operation: 0, data: exec, dataKeccak: keccak256(exec), safeNonce: (nonce + 1n).toString(), safeTxHash: await hash(exec, nonce + 1n) },
  ],
  safeTxParams: { safeTxGas: 0, baseGas: 0, gasPrice: 0, gasToken: Z, refundReceiver: Z },
  owners: await Promise.all(owners.map(async (o) => ({ owner: o, balanceWei: (await c.getBalance({ address: o, blockNumber: bn })).toString() }))),
  baseFeePerGasAtPin: blk.baseFeePerGas?.toString(), gasPriceNow: (await c.getGasPrice()).toString(),
  note: 'safeTxHash depends on the Safe nonce and on the timelock/APNTsCapped addresses, which depend on the deployer nonce at real execution; recompute both before signing.',
};
console.log(JSON.stringify(out, null, 1));
