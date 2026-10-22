// R-AMS-2: deployment receipts for every transaction forge broadcast while deploying the B-layer stack
// (tx hash, contract, gas limit, gasUsed, status), read back from the local node, plus how many exceed
// the EIP-7825 per-tx cap 2^24 = 16,777,216. Local anvil only.
// Usage: node script/b-layer/ams-receipts.mjs <rpcUrl> <forge broadcast run-latest.json> <outJson>
import { readFileSync, writeFileSync } from "node:fs";
import { rpc } from "./lib.mjs";

const [rpcUrl, runJson, outJson] = process.argv.slice(2);
if (!/^http:\/\/(127\.0\.0\.1|localhost):/.test(rpcUrl)) throw new Error("local node only");
const CAP = 2 ** 24;
const run = JSON.parse(readFileSync(runJson, "utf8"));
const rows = [];
for (const [i, t] of run.transactions.entries()) {
    const rc = (await rpc(rpcUrl, "eth_getTransactionReceipt", [t.hash])).result;
    const tx = (await rpc(rpcUrl, "eth_getTransactionByHash", [t.hash])).result;
    rows.push({ i, hash: t.hash, type: t.transactionType, contractName: t.contractName ?? null, function: t.function ?? null,
        contractAddress: rc?.contractAddress ?? t.contractAddress ?? null, block: rc ? parseInt(rc.blockNumber, 16) : null,
        gasLimit: tx ? parseInt(tx.gas, 16) : null, gasUsed: rc ? parseInt(rc.gasUsed, 16) : null,
        status: rc ? parseInt(rc.status, 16) : null, overCap: rc ? parseInt(rc.gasUsed, 16) > CAP : null });
}
const out = { rpcUrl, source: runJson, cap: CAP, count: rows.length, allStatus1: rows.every((r) => r.status === 1),
    overCap: rows.filter((r) => r.overCap).map((r) => ({ i: r.i, contractName: r.contractName, type: r.type, gasUsed: r.gasUsed, hash: r.hash })),
    totalGasUsed: rows.reduce((a, r) => a + (r.gasUsed ?? 0), 0), rows };
writeFileSync(outJson, JSON.stringify(out, null, 2));
console.log(`${rows.length} deploy txs, all status 1: ${out.allStatus1}, over 2^24: ${out.overCap.length} ${JSON.stringify(out.overCap.map((r) => [r.contractName, r.gasUsed]))}`);
