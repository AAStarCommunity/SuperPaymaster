#!/usr/bin/env node
// READ-ONLY: fetch transaction + receipt + block header of already-mined PUBLIC transactions
// (eth_getTransactionByHash / eth_getTransactionReceipt / eth_getBlockByNumber). Signs nothing.
// Usage: node script/evidence/fetch-public-receipts.mjs <public rpc | env:<file with RPC_URL>> <out.json> <label=0xhash> [...]
//        env:<file> reads RPC_URL from that file (e.g. an archive endpoint with a key); the URL is never printed or written.
import { writeFileSync, readFileSync } from 'node:fs';

const [rpcArg, out, ...pairs] = process.argv.slice(2);
let rpc = rpcArg, rpcLabel = rpcArg;
if (rpcArg?.startsWith('env:')) {
  const line = readFileSync(rpcArg.slice(4), 'utf8').split('\n').find((l) => l.startsWith('RPC_URL='));
  rpc = line.slice('RPC_URL='.length).trim().replace(/^["']|["']$/g, '');
  rpcLabel = 'RPC_URL from ' + rpcArg.slice(4).split('/').pop() + ' (archive endpoint; URL not recorded)';
}
if (!rpcArg || !out || pairs.length === 0) { console.error('usage: fetch-public-receipts.mjs <rpc> <out.json> <label=0xhash> ...'); process.exit(2); }
let id = 0;
async function call(method, params) {
  const r = await fetch(rpc, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: ++id, method, params }) });
  const j = await r.json();
  if (j.error) throw new Error(`${method}: ${JSON.stringify(j.error)}`);
  return j.result;
}
const chainId = parseInt(await call('eth_chainId', []), 16);
const txs = [];
for (const p of pairs) {
  const [label, hash] = p.split('=');
  const transaction = await call('eth_getTransactionByHash', [hash]);
  const receipt = await call('eth_getTransactionReceipt', [hash]);
  const blk = await call('eth_getBlockByNumber', [receipt.blockNumber, false]);
  // What the chain says the tx IS (independent of the label the caller copied from a record).
  const observed = transaction.to
    ? `CALL ${transaction.input.slice(0, 10)} -> ${transaction.to}`
    : `CREATE -> ${receipt.contractAddress}`;
  txs.push({ recordLabel: label, observed, hash, blockNumber: parseInt(receipt.blockNumber, 16), blockHash: receipt.blockHash,
    blockTimestamp: parseInt(blk.timestamp, 16), txIndex: parseInt(receipt.transactionIndex, 16), nonce: parseInt(transaction.nonce, 16),
    from: transaction.from, status: receipt.status, gasUsed: parseInt(receipt.gasUsed, 16),
    contractAddress: receipt.contractAddress, transaction, receipt });
  console.log(`${label} ${hash} block ${parseInt(receipt.blockNumber, 16)} status ${receipt.status} observed: ${observed}`);
}
writeFileSync(out, JSON.stringify({ category: 'onchain-real', note: 'public chain, fetched read-only; verifiable on any explorer of this chain',
  rpc: rpcLabel, chainId, collectedAtUtc: new Date().toISOString(), transactions: txs }, null, 2) + '\n');
