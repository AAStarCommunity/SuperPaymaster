// D5 gate G1 — cases B1–B10 against ONE bundler (manual bundling mode, so "one bundle" is exact).
// Every JSON-RPC response from the bundler is stored raw. The validation traces are captured by
// g1-proxy.mjs (the bundler talks to anvil through it); this runner labels them per case.
// Usage: node script/b-layer/g1-cases.mjs <setupJson> <rundler|alto> <bundlerUrl> <proxyUrl> <outJson>
import { readFileSync, writeFileSync } from "node:fs";
import { decodeEventLog, encodeFunctionData, toHex } from "viem";
import { clients, rpc, send, EP, ANVIL_KEYS, eth } from "./lib.mjs";
import { ABI, GAS, MIN_POST_OP_GAS, FLAG_SP_RENEW, FLAG_ACCOUNT_RENEW, buildG1Op, waitReceipt } from "./g1-lib.mjs";

const [setupJson, kind, bundlerUrl, proxyUrl, outJson] = process.argv.slice(2);
const s = JSON.parse(readFileSync(setupJson, "utf8"));
const d = s.deploy;
const ctx = clients(s.rpcUrl, ANVIL_KEYS[0]);
const read = (address, abi, functionName, args = []) => ctx.pub.readContract({ address, abi, functionName, args });
const B = (m, p = []) => rpc(bundlerUrl, m, p);
const statusMethod = kind === "rundler" ? "rundler_getUserOperationStatus" : "pimlico_getUserOperationStatus";

// Expected reason patterns (asserted, not just "failed"): D5-plan §6 item 2.
const REASON = {
    rundler: {
        spBelow: /paymaster.*(stake|unstake)|(stake|unstake).*too low|inaccessible storage/i,
        factoryUnstaked: /factory|stake|inaccessible storage/i,
        factoryLow: /factory|stake|inaccessible storage/i,
        factoryShortDelay: /factory|stake|inaccessible storage/i,
    },
    alto: {
        spBelow: /unstaked paymaster|stake/i,
        factoryUnstaked: /unstaked factory|factory|stake/i,
        factoryLow: /unstaked factory|factory|stake/i,
        factoryShortDelay: /unstaked factory|factory|stake/i,
    },
}[kind];

const results = { kind, bundlerUrl, entryPoint: EP, at: new Date().toISOString(), cases: {} };
const label = async (l) => { await fetch(`${proxyUrl}/__label`, { method: "POST", body: JSON.stringify({ label: l }) }); };

async function submit(op) {
    const res = await B("eth_sendUserOperation", [op.rpcOp, EP]);
    return { userOpHash: op.hash, response: res };
}
async function bundleNow() {
    const r = await B("debug_bundler_sendBundleNow", []);
    await new Promise((res) => setTimeout(res, 1500));
    return r;
}
async function outcome(sub) {
    if (sub.response.error) return { verdict: "reject", error: sub.response.error };
    const receipt = await waitReceipt(bundlerUrl, sub.userOpHash, 20);
    const status = await B(statusMethod, [sub.userOpHash]);
    return {
        verdict: receipt ? (receipt.success ? "included" : "included-reverted") : "accepted-not-included",
        receipt: receipt ? { success: receipt.success, tx: receipt.receipt?.transactionHash, actualGasCost: receipt.actualGasCost,
            logs: receipt.logs?.length } : null,
        status,
    };
}
async function snap(user) {
    const tok = d.operatorToken;
    const op = await read(d.superPaymaster, ABI.sp, "operators", [d.operator]);
    return {
        bal: (await read(tok, ABI.token, "balanceOf", [user])).toString(),
        locked: (await read(tok, ABI.token, "lockedOf", [user])).toString(),
        creditReserved: (await read(tok, ABI.token, "creditReservedOf", [user])).toString(),
        debts: (await read(tok, ABI.token, "debts", [user])).toString(),
        supply: (await read(tok, ABI.token, "totalSupply")).toString(),
        opBalance: BigInt(op[0]).toString(),
        revenue: (await read(d.superPaymaster, ABI.sp, "protocolRevenue")).toString(),
    };
}
const delta = (a, b, k) => BigInt(b[k]) - BigInt(a[k]);
async function tokenEvents(txHash) {
    if (!txHash) return [];
    const rc = await ctx.pub.getTransactionReceipt({ hash: txHash });
    const out = [];
    for (const lg of rc.logs) {
        try {
            const ev = decodeEventLog({ abi: ABI.token, data: lg.data, topics: lg.topics });
            out.push({ address: lg.address, event: ev.eventName, args: Object.fromEntries(Object.entries(ev.args).map(([k, v]) => [k, String(v)])) });
        } catch { /* not a token event */ }
    }
    return out;
}
const acct = (n) => s.accounts[n].address;
const opFor = (name, extra = {}) => buildG1Op(ctx, d, { sender: acct(name), ownerKey: ANVIL_KEYS[s.ownerKeyIndex], ...extra });
function record(name, c) { results.cases[name] = c; console.log(`${kind} ${name}: ${c.pass ? "PASS" : "FAIL"} — ${c.summary}`); }

await B("debug_bundler_setBundlingMode", ["manual"]).then((r) => (results.bundlingMode = r));

// ---------------- B9 below: SP stake 0.1 ETH / 86400 (the live Sepolia value) ----------------
{
    await label("B9-below");
    const stake = await read(EP, ABI.ep, "getDepositInfo", [d.superPaymaster]);
    const sub = await submit(await opFor("b9"));
    const bundle = sub.response.error ? null : await bundleNow(); // if (wrongly) accepted, see whether it lands
    const o = await outcome(sub);
    const msg = String(o.error?.message ?? "");
    record("B9-below", { expected: "reject (SP stake below threshold, specific reason)", spStake: { stake: stake.stake.toString(), delay: stake.unstakeDelaySec },
        ...o, sent: sub, bundle, pass: o.verdict === "reject" && REASON.spBelow.test(msg), summary: `${o.verdict}${o.error ? ` [${o.error.code}] ${msg.slice(0, 200)}` : ""}` });
}
// top up to exactly 1 ETH (the threshold), same delay
await send(ctx, d.superPaymaster, ABI.sp, "addStake", [86_400], eth("0.9"));
{
    await label("B9-above");
    const stake = await read(EP, ABI.ep, "getDepositInfo", [d.superPaymaster]);
    const sub = await submit(await opFor("b9"));
    const bundle = await bundleNow();
    const o = await outcome(sub);
    record("B9-above", { expected: "accept + include (SP stake 1 ETH / 86400)", spStake: { stake: stake.stake.toString(), delay: stake.unstakeDelaySec },
        ...o, sent: sub, bundle, pass: o.verdict === "included", summary: o.verdict });
}

// ---------------- B1 single BALANCE op ----------------
{
    await label("B1");
    const u = acct("b1");
    const before = await snap(u);
    const sub = await submit(await opFor("b1"));
    const bundle = await bundleNow();
    const o = await outcome(sub);
    const after = await snap(u);
    const burn = -delta(before, after, "bal");
    const opD = delta(before, after, "opBalance");
    const revD = delta(before, after, "revenue");
    const ev = await tokenEvents(o.receipt?.tx);
    const ok = o.verdict === "included" && burn > 0n && after.locked === "0" && -opD === revD && revD > 0n;
    record("B1", { expected: "accept + include; burn>0, lockedOf==0, operator Δ == −revenue Δ", ...o, sent: sub, bundle, before, after,
        post: { burn: burn.toString(), operatorDelta: opD.toString(), revenueDelta: revD.toString(), supplyDelta: delta(before, after, "supply").toString() },
        tokenEvents: ev, pass: ok, summary: `${o.verdict}; burn=${burn} lockedOf=${after.locked} opΔ=${opD} revΔ=${revD}` });
}

// ---------------- B2 same sender, three ops (nonce keys 0,1,2), one bundle ----------------
// Defined here, RUN LAST (see the end of the file): an in-bundle rejection feeds the bundler's
// paymaster reputation (Rundler applies ERC-7562 SREP-050: staked paymaster → BANNED), which would
// otherwise contaminate every later case.
/** EntryPoint.handleOps as an eth_call at the current state: the exact in-bundle verdict. */
async function handleOpsCall(packedOps) {
    try {
        await ctx.pub.simulateContract({ address: EP, abi: ABI.ep, functionName: "handleOps", args: [packedOps, ctx.account.address],
            account: ctx.account.address });
        return { reverted: false };
    } catch (e) {
        const err = e.walk?.((x) => x.data?.errorName) ?? null;
        return { reverted: true, error: err?.data ? { name: err.data.errorName, args: (err.data.args ?? []).map(String) } : String(e.shortMessage ?? e.message).slice(0, 300) };
    }
}

async function runB2(name, account, keys) {
    await label(name);
    const u = acct(account);
    const before = await snap(u);
    const ops = [];
    for (const key of keys) ops.push(await opFor(account, { nonceKey: BigInt(key) }));
    // the in-bundle verdict of all ops together, BEFORE anything is bundled (EntryPoint semantics)
    const handleOpsAll = await handleOpsCall(ops.map((o) => o.packed));
    const subs = [];
    for (const op of ops) subs.push(await submit(op));
    const mempool = await B("debug_bundler_dumpMempool", [EP]);
    const bundle = await bundleNow();
    const bundle2 = await bundleNow(); // second attempt: a builder may retry after dropping an op
    const outs = [];
    for (const sub of subs) outs.push(await outcome(sub));
    const after = await snap(u);
    const included = outs.filter((o) => o.verdict === "included").length;
    const txs = [...new Set(outs.filter((o) => o.receipt).map((o) => o.receipt.tx))];
    return { u, before, after, ops, handleOpsAll, subs, mempool, bundle, bundle2, outs, included, txs };
}

// ---------------- B3 three senders, one bundle ----------------
{
    await label("B3");
    const names = ["b3a", "b3b", "b3c"];
    const before = {}; for (const n of names) before[n] = await snap(acct(n));
    const subs = []; for (const n of names) subs.push(await submit(await opFor(n)));
    const bundle = await bundleNow();
    const outs = []; for (const sub of subs) outs.push(await outcome(sub));
    const after = {}; for (const n of names) after[n] = await snap(acct(n));
    const txs = [...new Set(outs.filter((o) => o.receipt).map((o) => o.receipt.tx))];
    const ev = await tokenEvents(txs[0]);
    const settled = ev.filter((e) => e.event === "LockSettled").map((e) => e.args.user.toLowerCase());
    const ok = outs.every((o) => o.verdict === "included") && txs.length === 1
        && names.every((n) => after[n].locked === "0" && BigInt(after[n].bal) < BigInt(before[n].bal))
        && new Set(settled).size === 3;
    record("B3", { expected: "3 senders, one bundle, all included; locks independent (3 distinct LockSettled, each lockedOf==0)",
        subs, outs, bundle, txs, before, after, tokenEvents: ev, pass: ok,
        summary: `${outs.map((o) => o.verdict).join(",")} in ${txs.length} tx; LockSettled users=${new Set(settled).size}` });
}

// ---------------- B5 SP_RENEW (flags = 1) ----------------
{
    await label("B5");
    const u = acct("b5");
    const sub = await submit(await opFor("b5", { flags: FLAG_SP_RENEW }));
    const bundle = await bundleNow();
    const o = await outcome(sub);
    const ev = await tokenEvents(o.receipt?.tx);
    const renewed = ev.find((e) => e.event === "AllowanceRenewed" && e.args.user?.toLowerCase() === u.toLowerCase());
    record("B5", { expected: "accept + include; AllowanceRenewed(user, SP, spRelayed=true)", ...o, sent: sub, bundle, tokenEvents: ev,
        pass: o.verdict === "included" && !!renewed, summary: `${o.verdict}; renewedEvent=${JSON.stringify(renewed?.args ?? null)}` });
}

// ---------------- B6 option A: account calls token.renewForSelf(sp) inside validateUserOp ----------------
{
    await label("B6");
    const u = acct("b6");
    const sub = await submit(await opFor("b6", { flags: FLAG_ACCOUNT_RENEW, accountRenew: true }));
    const bundle = await bundleNow();
    const o = await outcome(sub);
    const ev = await tokenEvents(o.receipt?.tx);
    const renewed = ev.find((e) => e.event === "AllowanceRenewed" && e.args.user?.toLowerCase() === u.toLowerCase());
    record("B6", { expected: "accept + include; AllowanceRenewed(user, SP, spRelayed=false) from the account frame", ...o, sent: sub, bundle,
        tokenEvents: ev, pass: o.verdict === "included" && !!renewed, summary: `${o.verdict}; renewedEvent=${JSON.stringify(renewed?.args ?? null)}` });
}

// ---------------- B7 CREDIT mode ----------------
{
    await label("B7");
    const u = acct("b7");
    const before = await snap(u);
    const sub = await submit(await opFor("b7"));
    const bundle = await bundleNow();
    const o = await outcome(sub);
    const after = await snap(u);
    const ev = await tokenEvents(o.receipt?.tx);
    const ok = o.verdict === "included" && BigInt(after.debts) > BigInt(before.debts) && after.creditReserved === "0"
        && ev.some((e) => e.event === "CreditSettled");
    record("B7", { expected: "accept + include; CREDIT path (CreditReserved → CreditSettled), debts>0, creditReservedOf==0", ...o, sent: sub, bundle,
        before, after, tokenEvents: ev, pass: ok, summary: `${o.verdict}; debts ${before.debts}→${after.debts}; reserved=${after.creditReserved}` });
}

// ---------------- B8 validation-time TSTORE (token live marker + SP in-flight marker) ----------------
{
    await label("B8");
    const sub = await submit(await opFor("b8"));
    const bundle = await bundleNow();
    const o = await outcome(sub);
    record("B8", { expected: "accept + include with SP staked (TSTORE of token live marker + SP in-flight marker in validation; OP-070 → storage rules)",
        ...o, sent: sub, bundle, pass: o.verdict === "included", summary: o.verdict });
}

// ---------------- B4 initCode via MockAirAccountFactory ----------------
for (const [fname, key, expectAccept] of [["unstaked", "factoryUnstaked", false], ["lowStake", "factoryLow", false],
    ["shortDelay", "factoryShortDelay", null], ["ok", null, true]]) {
    await label(`B4-${fname}`);
    const b4 = s.b4[fname];
    const factoryData = encodeFunctionData({ abi: ABI.factory, functionName: "createAccount", args: [s.owner, d.operatorToken, d.superPaymaster, BigInt(b4.salt)] });
    const op = await buildG1Op(ctx, d, { sender: b4.address, ownerKey: ANVIL_KEYS[s.ownerKeyIndex], factory: b4.factory, factoryData });
    const sub = await submit(op);
    const bundle = sub.response.error ? null : await bundleNow();
    const o = await outcome(sub);
    const msg = String(o.error?.message ?? "");
    const f = s.factories[fname];
    let pass;
    if (expectAccept === true) pass = o.verdict === "included";
    else if (expectAccept === false) pass = o.verdict === "reject" && REASON[key].test(msg);
    else pass = kind === "rundler" ? (o.verdict === "reject" && REASON[key].test(msg)) : true; // Alto: depends on its configured delay
    record(`B4-${fname}`, { expected: expectAccept === true ? "accept + include" : expectAccept === false ? "reject with factory stake reason"
        : "Rundler (min delay 86400): reject; Alto: per configured --min-entity-unstake-delay", factory: f, ...o, sent: sub, bundle, pass,
        summary: `${o.verdict}${o.error ? ` [${o.error.code}] ${msg.slice(0, 200)}` : ""}` });
}

// ---------------- B10 eth_estimateUserOperationGas with the new paymasterAndData ----------------
{
    await label("B10");
    const base = await opFor("b10");
    const est = {};
    const variants = {
        // v0.7 fields as both bundlers accept them; paymasterData = operator ‖ maxRate ‖ token ‖ flags
        suppliedPostOpMin: { ...base.rpcOp, paymasterVerificationGasLimit: toHex(GAS.pmVerificationGasLimit), paymasterPostOpGasLimit: toHex(MIN_POST_OP_GAS) },
        omittedPmGas: (() => { const o = { ...base.rpcOp }; delete o.paymasterVerificationGasLimit; delete o.paymasterPostOpGasLimit; return o; })(),
        omittedPostOpOnly: (() => { const o = { ...base.rpcOp }; delete o.paymasterPostOpGasLimit; return o; })(),
    };
    for (const [k, op] of Object.entries(variants)) {
        const q = { ...op };
        for (const f of ["callGasLimit", "verificationGasLimit", "preVerificationGas"]) delete q[f];
        const r = await B("eth_estimateUserOperationGas", [q, EP]);
        const pog = r.result?.paymasterPostOpGasLimit;
        est[k] = { request: q, response: r, paymasterPostOpGasLimit: pog ?? null,
            postOpGeMin: pog != null ? BigInt(pog) >= MIN_POST_OP_GAS : null };
    }
    const main = est.suppliedPostOpMin;
    const pass = !main.response.error && (main.paymasterPostOpGasLimit == null ? false : main.postOpGeMin);
    record("B10", { expected: "estimation succeeds and estimated paymasterPostOpGasLimit ≥ 200000", est, pass,
        summary: Object.entries(est).map(([k, v]) => `${k}: ${v.response.error ? `ERR [${v.response.error.code}] ${String(v.response.error.message).slice(0, 120)}` : `pmPostOp=${v.paymasterPostOpGasLimit} pmVerif=${v.response.result?.paymasterVerificationGasLimit}`}`).join(" | ") });
}

// ---------------- B2 (last) + aftermath: the paymaster's reputation in this bundler ----------------
results.reputationBeforeB2 = await B("debug_bundler_dumpReputation", [EP]);
{
    // B2a: two ops of one sender that both fit → one bundle, both included
    const r = await runB2("B2a", "b2", [0, 1]);
    const ok = r.included === 2 && r.txs.length === 1 && r.after.locked === "0";
    record("B2a", { expected: "same sender, 2 ops (nonce keys 0,1) that fit: accepted, ONE bundle, both included",
        userBalance: r.before.bal, a0: s.a0, ...r, ops: undefined, pass: ok, summary: `included=${r.included} in ${r.txs.length} tx; lockedOf=${r.after.locked}` });
}
{
    // B2b: three ops, balance = 2.5·x0 → the third lock cannot fit once the first two are locked (T-R14-02)
    const r = await runB2("B2b", "b2x", [0, 1, 2]);
    const third = r.outs[2];
    const firstTwo = r.outs[0].verdict === "included" && r.outs[1].verdict === "included";
    const ok = third.verdict !== "included" && r.after.locked === "0";
    record("B2b", { expected: "same sender, 3 ops, balance 2.5·x0: op 3 rejected (the EntryPoint says FailedOp(2, AA34)); ops 1–2 included",
        userBalance: r.before.bal, a0: s.a0, ...r, ops: undefined, firstTwoIncluded: firstTwo,
        pass: ok && firstTwo,
        summary: `handleOps(all)=${JSON.stringify(r.handleOpsAll.error ?? "ok")}; verdicts=${r.outs.map((o) => o.verdict + (o.error ? `[${o.error.code}] ${String(o.error.message).slice(0, 120)}` : "")).join(" | ")}` });
}
{
    await label("B2-aftermath");
    results.reputationAfterB2 = await B("debug_bundler_dumpReputation", [EP]);
    const sub = await submit(await opFor("b1"));
    const bundle = sub.response.error ? null : await bundleNow();
    const o = await outcome(sub);
    results.cases["B2-aftermath"] = { expected: "observation: can a normal op from the same SP still enter after B2?", ...o, sent: sub, bundle,
        pass: true, informational: true, summary: `${o.verdict}${o.error ? ` [${o.error.code}] ${String(o.error.message).slice(0, 200)}` : ""}` };
    console.log(`${kind} B2-aftermath: ${results.cases["B2-aftermath"].summary}`);
}

await label("done");
results.stakeStatus = {
    sp: await B("debug_bundler_getStakeStatus", [d.superPaymaster, EP]),
    factoryOk: await B("debug_bundler_getStakeStatus", [s.factories.ok.address, EP]),
};
results.allPass = Object.values(results.cases).every((c) => c.pass);
writeFileSync(outJson, JSON.stringify(results, (k, v) => (typeof v === "bigint" ? v.toString() : v), 2));
console.log(`${kind} all pass: ${results.allPass}`);
