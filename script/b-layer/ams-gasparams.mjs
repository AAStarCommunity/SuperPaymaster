// R-AMS-2 variant (b): set SuperPaymaster's GasParams the way governance does on a deployment —
// owner queueGasParams → wait GP_TIMELOCK (48 h; warped on anvil) → owner executeGasParams — and
// read them back. Local anvil only; owner = anvil dev key #0 (DeployBLayerAnvil's deployer).
// Usage: node script/b-layer/ams-gasparams.mjs <rpcUrl> <deployJson> <minPostOp> <settle> <cWrap> <cPostop> <outJson>
import { readFileSync, writeFileSync } from "node:fs";
import { clients, send, rpc, ANVIL_KEYS } from "./lib.mjs";
import { ABI } from "./g1-lib.mjs";

const [rpcUrl, deployJson, minPost, settle, cWrap, cPostop, outJson] = process.argv.slice(2);
if (!/^http:\/\/(127\.0\.0\.1|localhost):/.test(rpcUrl)) throw new Error("local node only");
const d = JSON.parse(readFileSync(deployJson, "utf8"));
const ctx = clients(rpcUrl, ANVIL_KEYS[0]);
const read = (fn) => ctx.pub.readContract({ address: d.superPaymaster, abi: ABI.sp, functionName: fn });
const fmt = (gp) => JSON.parse(JSON.stringify(gp, (k, v) => (typeof v === "bigint" ? v.toString() : v)));
const before = fmt(await read("gasParams"));
const q = await send(ctx, d.superPaymaster, ABI.sp, "queueGasParams", [Number(minPost), Number(settle), Number(cWrap), Number(cPostop)]);
const queued = fmt(await read("gasParams"));
await rpc(rpcUrl, "evm_increaseTime", [48 * 3600 + 60]);
await rpc(rpcUrl, "evm_mine", []);
const x = await send(ctx, d.superPaymaster, ABI.sp, "executeGasParams", []);
const after = fmt(await read("gasParams"));
const out = { before, queued, after, queueTx: q.transactionHash, executeTx: x.transactionHash };
writeFileSync(outJson, JSON.stringify(out, null, 2));
console.log(JSON.stringify(out));
