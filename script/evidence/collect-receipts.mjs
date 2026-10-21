#!/usr/bin/env node
// Collect raw transaction + receipt + block-header JSON for a set of tx hashes from a LOCAL node
// (anvil / anvil --fork-url). Read-only JSON-RPC; sends nothing.
//
// Usage: node script/evidence/collect-receipts.mjs <rpc> <out.json> <category> <label=0xhash> [...]
//        node script/evidence/collect-receipts.mjs <rpc> <out.json> <category> --broadcast <forge broadcast run-*.json>
// <category>: local-anvil | fork-simulation  (written into the file; these hashes exist ONLY on the
//             local node that produced them and on no public explorer).
import { readFileSync, writeFileSync } from 'node:fs';

const [rpc, out, category, ...rest] = process.argv.slice(2);
if (!rpc || !out || !category || rest.length === 0) {
  console.error('usage: collect-receipts.mjs <rpc> <out.json> <category> (<label=0xhash> ... | --broadcast <file>)');
  process.exit(2);
}
if (!/^http:\/\/(127\.0\.0\.1|localhost):\d+$/.test(rpc)) {
  console.error('refusing: this collector only talks to a local node (http://127.0.0.1:<port>)');
  process.exit(2);
}

let id = 0;
async function call(method, params = []) {
  const res = await fetch(rpc, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params }),
  });
  const j = await res.json();
  if (j.error) throw new Error(`${method}: ${JSON.stringify(j.error)}`);
  return j.result;
}

let items = [];
let bc = null;
if (rest[0] === '--broadcast') {
  // The hash list comes from forge's broadcast file; the LABEL of each tx is NOT taken from the
  // broadcast's array position (observed: forge 1.7.1 can pair a hash with the wrong entry) but is
  // re-derived below from the fetched transaction itself (creation address / exact calldata match).
  bc = JSON.parse(readFileSync(rest[1], 'utf8'));
  items = bc.receipts.map((r) => ({ label: null, hash: r.transactionHash }));
} else {
  items = rest.map((a) => {
    const [label, hash] = a.split('=');
    return { label, hash };
  });
}

const chainId = parseInt(await call('eth_chainId'), 16);
const clientVersion = await call('web3_clientVersion').catch(() => null);
let forkInfo = null;
try {
  const meta = await call('anvil_metadata');
  forkInfo = meta.forkedNetwork || null;
} catch { /* not anvil */ }

const txs = [];
for (const { label, hash } of items) {
  const tx = await call('eth_getTransactionByHash', [hash]);
  const receipt = await call('eth_getTransactionReceipt', [hash]);
  const blk = await call('eth_getBlockByNumber', [receipt.blockNumber, false]);
  let lbl = label;
  if (bc) {
    const lc = (s) => (s || '').toLowerCase();
    let m;
    if (!tx.to) {
      m = bc.transactions.find((t) => t.transactionType === 'CREATE' && lc(t.contractAddress) === lc(receipt.contractAddress));
      lbl = `CREATE ${m?.contractName || '?'} -> ${receipt.contractAddress}`;
    } else {
      m = bc.transactions.find((t) => lc(t.transaction?.input || t.transaction?.data) === lc(tx.input) && lc(t.transaction?.to) === lc(tx.to));
      lbl = `CALL ${m?.function || tx.input.slice(0, 10)} -> ${tx.to}`;
    }
  }
  txs.push({
    label: lbl,
    hash,
    blockNumber: parseInt(receipt.blockNumber, 16),
    blockHash: receipt.blockHash,
    blockTimestamp: parseInt(blk.timestamp, 16),
    baseFeePerGas: blk.baseFeePerGas ? BigInt(blk.baseFeePerGas).toString() : null,
    status: receipt.status,
    gasUsed: parseInt(receipt.gasUsed, 16),
    effectiveGasPrice: receipt.effectiveGasPrice ? BigInt(receipt.effectiveGasPrice).toString() : null,
    transaction: tx,
    receipt,
  });
}

txs.sort((a, b) => a.blockNumber - b.blockNumber ||
  parseInt(a.receipt.transactionIndex, 16) - parseInt(b.receipt.transactionIndex, 16));

const doc = {
  category,
  notice: 'LOCAL NODE ONLY: these transaction hashes were produced on a local anvil node (or a local anvil fork) ' +
    'and do not exist on any public chain or explorer. They are reproduction records, not on-chain evidence.',
  rpc: rpc.replace(/:\d+$/, ':<local port>'),
  chainId,
  clientVersion,
  forkedNetwork: forkInfo,
  collectedAtUtc: new Date().toISOString(),
  transactions: txs,
};
writeFileSync(out, JSON.stringify(doc, null, 2) + '\n');
console.log(`wrote ${out}: ${txs.length} tx, chainId ${chainId}${forkInfo ? `, fork of chain ${forkInfo.chainId} @ ${forkInfo.forkBlockNumber}` : ''}`);
for (const t of txs) console.log(`  ${t.label}  ${t.hash}  block ${t.blockNumber}  status ${t.status}  gasUsed ${t.gasUsed}`);
