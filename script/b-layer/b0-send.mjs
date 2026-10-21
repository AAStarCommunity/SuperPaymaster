// B0 send: one UserOperation per case to a bundler; records the bundler's verdict.
// Usage: node script/b-layer/b0-send.mjs <setupJson> <bundlerUrl> <label> <outJson>
import { readFileSync, writeFileSync } from "node:fs";
import { clients, buildOp, rpc, EP, EP_ABI } from "./lib.mjs";

const [setupJson, bundlerUrl, label, outJson] = process.argv.slice(2);
const s = JSON.parse(readFileSync(setupJson, "utf8"));
const ctx = clients(s.rpcUrl);

const EXPECT = {
    control: "accept",
    op011_timestamp: "reject",
    sto031_unstakedOwnStorage: "reject",
    op070_unstakedTstore: "reject",
    sto021_stakedExternalWrite: "reject",
};

const results = { label, bundlerUrl, entryPoint: EP, at: new Date().toISOString(), cases: {} };
for (const [name, c] of Object.entries(s.cases)) {
    const nonce = await ctx.pub.readContract({ address: EP, abi: EP_ABI, functionName: "getNonce", args: [c.account, 0n] });
    const { rpcOp, hash } = await buildOp(ctx, {
        sender: c.account, nonce, ownerKey: s.ownerKey,
        pm: { address: c.paymaster, verificationGasLimit: 100_000n, postOpGasLimit: 50_000n },
    });
    const res = await rpc(bundlerUrl, "eth_sendUserOperation", [rpcOp, EP]);
    let receipt = null;
    if (res.result) {
        for (let i = 0; i < 40 && !receipt; i++) {
            await new Promise((r) => setTimeout(r, 500));
            const rr = await rpc(bundlerUrl, "eth_getUserOperationReceipt", [res.result]);
            receipt = rr.result ?? null;
        }
    }
    const verdict = res.error ? "reject" : "accept";
    results.cases[name] = {
        expected: EXPECT[name], verdict, pass: verdict === EXPECT[name],
        userOpHash: hash, error: res.error ?? null,
        included: receipt ? { success: receipt.success, tx: receipt.receipt?.transactionHash } : null,
    };
    console.log(`${label} ${name}: expected ${EXPECT[name]}, got ${verdict}` +
        (res.error ? ` [${res.error.code}] ${String(res.error.message).slice(0, 160)}` : receipt ? ` (included, success=${receipt.success})` : " (not yet included)"));
}
results.allPass = Object.values(results.cases).every((c) => c.pass);
writeFileSync(outJson, JSON.stringify(results, null, 2));
console.log(`${label} B0 all pass: ${results.allPass}`);
