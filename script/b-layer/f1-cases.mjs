// F1 investigation — scenarios against ONE bundler (manual bundling), raw responses recorded.
// Scenarios (argument list, run in the given order):
//   tpm1      TokenPaymaster sanity: one op → must be included (proves the control works at all)
//   tpm3      TokenPaymaster control: same sender, 3 ops (nonce keys 0,1,2), token balance for 2
//   gSig      SP + guarded account (mode 1, sigFail → AA24): same sender, 3 ops, balance 2.5·a0
//   gRev      SP + guarded account (mode 2, revert  → AA23): same sender, 3 ops, balance 2.5·a0
//   sp3       SP + plain MockAirAccount: the B2b reproduction (3 ops, balance 2.5·a0)
// After each multi-op scenario: reputation dump of the paymaster and of the sender, then one normal
// op from a FRESH sender through the same paymaster ("after" probe: -32504 = paymaster banned).
// Usage: node script/b-layer/f1-cases.mjs <f1SetupJson> <rundler|alto> <bundlerUrl> <proxyUrl> <outJson> <scenario...>
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { decodeErrorResult, encodeFunctionData } from "viem";
import { clients, rpc, EP, ANVIL_KEYS, ROOT, buildOp } from "./lib.mjs";
import { ABI, GAS, buildG1Op, waitReceipt } from "./g1-lib.mjs";

const [setupJson, kind, bundlerUrl, proxyUrl, outJson, ...scenarios] = process.argv.slice(2);
const S = JSON.parse(readFileSync(setupJson, "utf8"));
const d = S.deploy, F = S.f1;
const ctx = clients(S.rpcUrl, ANVIL_KEYS[0]);
const ownerKey = ANVIL_KEYS[S.ownerKeyIndex];
const TPM = JSON.parse(readFileSync(resolve(ROOT, "docs/design/aoa-balance-mode/b-layer/cases/f1/TokenPaymaster.json"), "utf8"));
const read = (address, abi, functionName, args = []) => ctx.pub.readContract({ address, abi, functionName, args });
const B = (m, p = []) => rpc(bundlerUrl, m, p);
const statusMethod = kind === "rundler" ? "rundler_getUserOperationStatus" : "pimlico_getUserOperationStatus";
const label = async (l) => { await fetch(`${proxyUrl}/__label`, { method: "POST", body: JSON.stringify({ label: l }) }); };
const results = { kind, bundlerUrl, at: new Date().toISOString(), scenarios: {} };
const ERR_ABI = [...ABI.ep.filter((x) => x.type === "error"),
    { type: "error", name: "EscrowPending", inputs: [{ name: "locked", type: "uint256" }, { name: "reserved", type: "uint256" }] },
    { type: "error", name: "ERC20InsufficientBalance", inputs: [{ name: "sender", type: "address" }, { name: "balance", type: "uint256" }, { name: "needed", type: "uint256" }] }];

const execCall = (to) => encodeFunctionData({ abi: ABI.account, functionName: "execute", args: [to, 0n, "0x"] });
async function tpmOp(sender, nonceKey) {
    const nonce = await read(EP, ABI.ep, "getNonce", [sender, BigInt(nonceKey)]);
    return buildOp(ctx, { sender, nonce, ownerKey, callData: execCall("0x000000000000000000000000000000000000dEaD"),
        callGasLimit: GAS.callGasLimit, verificationGasLimit: GAS.verificationGasLimit, preVerificationGas: GAS.preVerificationGas,
        maxFeePerGas: GAS.maxFeePerGas, maxPriorityFeePerGas: GAS.maxPriorityFeePerGas,
        pm: { address: F.tokenPaymaster, verificationGasLimit: GAS.pmVerificationGasLimit, postOpGasLimit: GAS.pmPostOpGasLimit, data: "0x" } });
}
const spOp = (sender, nonceKey) => buildG1Op(ctx, d, { sender, nonceKey: BigInt(nonceKey), ownerKey });

async function handleOpsCall(packed) {
    try {
        await ctx.pub.simulateContract({ address: EP, abi: ABI.ep, functionName: "handleOps", args: [packed, ctx.account.address], account: ctx.account.address });
        return { reverted: false };
    } catch (e) {
        const raw = e.walk?.((x) => typeof x.data === "string" && x.data.startsWith("0x"))?.data ?? e.walk?.((x) => x.raw)?.raw;
        const named = e.walk?.((x) => x.data?.errorName)?.data;
        const out = { reverted: true };
        if (named) out.error = { name: named.errorName, args: (named.args ?? []).map(String) };
        if (named?.errorName === "FailedOpWithRevert") {
            try { const inner = decodeErrorResult({ abi: ERR_ABI, data: named.args[2] }); out.inner = { name: inner.errorName, args: inner.args.map(String) }; } catch { out.innerRaw = named.args[2]; }
        }
        if (!named) out.raw = raw ?? String(e.shortMessage ?? e.message).slice(0, 300);
        return out;
    }
}
async function outcome(sub) {
    if (sub.response.error) return { verdict: "reject", error: sub.response.error };
    const receipt = await waitReceipt(bundlerUrl, sub.userOpHash, 16);
    return { verdict: receipt ? (receipt.success ? "included" : "included-reverted") : "accepted-not-included",
        receipt: receipt ? { success: receipt.success, tx: receipt.receipt?.transactionHash } : null, status: await B(statusMethod, [sub.userOpHash]) };
}
async function bundleNow() { const r = await B("debug_bundler_sendBundleNow", []); await new Promise((x) => setTimeout(x, 1500)); return r; }
async function reputationOf(addrs) {
    const r = await B("debug_bundler_dumpReputation", [EP]);
    const want = addrs.map((a) => a.toLowerCase());
    return { raw: r.error ?? null, entries: (r.result ?? []).filter((e) => want.includes(e.address.toLowerCase())) };
}

async function multi(name, { sender, paymaster, makeOp, afterSender }) {
    await label(name);
    const repBefore = await reputationOf([paymaster, sender]);
    const ops = [];
    for (const k of [0, 1, 2]) ops.push(await makeOp(sender, k));
    const joint = await handleOpsCall(ops.map((o) => o.packed)); // EntryPoint verdict of the three together
    const subs = [];
    for (const op of ops) subs.push({ userOpHash: op.hash, response: await B("eth_sendUserOperation", [op.rpcOp, EP]) });
    const bundle1 = await bundleNow();
    const bundle2 = await bundleNow();
    const bundle3 = await bundleNow();
    const outs = [];
    for (const s of subs) outs.push(await outcome(s));
    const repAfter = await reputationOf([paymaster, sender]);
    // after-probe: a normal op from a fresh sender through the same paymaster
    await label(`${name}-after`);
    const probe = await makeOp(afterSender, 0);
    const probeSub = { userOpHash: probe.hash, response: await B("eth_sendUserOperation", [probe.rpcOp, EP]) };
    const probeBundle = probeSub.response.error ? null : await bundleNow();
    const probeOut = await outcome(probeSub);
    const r = { sender, paymaster, jointHandleOps: joint, subs, bundles: [bundle1, bundle2, bundle3], outs, repBefore, repAfter,
        after: { sender: afterSender, sub: probeSub, bundle: probeBundle, ...probeOut } };
    results.scenarios[name] = r;
    const fmt = (o) => o.verdict + (o.error ? `[${o.error.code}] ${String(o.error.message).slice(0, 110)}` : "");
    console.log(`${kind} ${name}: joint=${JSON.stringify(joint.error ?? "ok")}${joint.inner ? ` inner=${JSON.stringify(joint.inner)}` : ""} | ops: ${outs.map(fmt).join(" | ")} | pmRep ${JSON.stringify(repAfter.entries.find((e) => e.address.toLowerCase() === paymaster.toLowerCase()) ?? null)} | senderRep ${JSON.stringify(repAfter.entries.find((e) => e.address.toLowerCase() === sender.toLowerCase()) ?? null)} | after: ${fmt(probeOut)}`);
}

await B("debug_bundler_setBundlingMode", ["manual"]).then((r) => (results.bundlingMode = r));
const acct = (n) => S.accounts[n].address;
for (const sc of scenarios) {
    if (sc === "tpm1") {
        await label("tpm1");
        const op = await tpmOp(F.tpmAccounts.t1.address, 0);
        const sub = { userOpHash: op.hash, response: await B("eth_sendUserOperation", [op.rpcOp, EP]) };
        const bundle = sub.response.error ? null : await bundleNow();
        const o = await outcome(sub);
        results.scenarios.tpm1 = { sub, bundle, ...o };
        console.log(`${kind} tpm1: ${o.verdict}${o.error ? ` [${o.error.code}] ${o.error.message}` : ""}`);
    } else if (sc === "tpm3") {
        await multi("tpm3", { sender: F.tpmAccounts.tpm3.address, paymaster: F.tokenPaymaster, makeOp: tpmOp, afterSender: F.tpmAccounts.tAfter.address });
    } else if (sc === "gSig") {
        await multi("gSig", { sender: F.guarded.gSig.address, paymaster: d.superPaymaster, makeOp: spOp, afterSender: F.spAfter.spAfter1.address });
    } else if (sc === "gRev") {
        await multi("gRev", { sender: F.guarded.gRev.address, paymaster: d.superPaymaster, makeOp: spOp, afterSender: F.spAfter.spAfter2.address });
    } else if (sc === "sp3") {
        await multi("sp3", { sender: acct("b2x"), paymaster: d.superPaymaster, makeOp: spOp, afterSender: F.spAfter.spAfter3.address });
    } else throw new Error(`unknown scenario ${sc}`);
}
await label("done");
writeFileSync(outJson, JSON.stringify(results, (k, v) => (typeof v === "bigint" ? v.toString() : v), 2));
