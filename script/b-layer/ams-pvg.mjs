// R2-F2 item 3: preVerificationGas actually required on the Amsterdam B-layer stack. Local anvil only,
// anvil public dev keys only.
//
// mode "direct": handleOps txs sent straight to the EntryPoint (no bundler), beneficiary = the sender
//   EOA (already funded, so no EIP-8037 new-account charge). Per bundle: tx gasUsed vs the ops'
//   actualGasUsed. EntryPoint pays the beneficiary sum(actualGasUsed_i) * price; the bundler spends
//   gasUsed * price. Break-even PVG per op (equal split) = PVG_used - (sum(actualGasUsed) - gasUsed) / n.
//   actualGasUsed includes EntryPoint's 10 % penalty on unused callGasLimit + paymasterPostOpGasLimit,
//   so "break-even" counts that penalty as bundler revenue (it is: the beneficiary receives it).
//   Also reported: gap_noPVG = gasUsed - sum(actualGasUsed_i - PVG_i) (overhead not covered by the
//   ops' measured gas; the PVG must cover it).
// mode "bundler": per bundler, the smallest preVerificationGas eth_sendUserOperation accepts
//   (binary search; every accepted op is removed again with debug_bundler_clearState), the
//   bundler's own eth_estimateUserOperationGas PVG, the rejection message at threshold - 1, then the
//   op is submitted AT the threshold, bundled, and the bundle tx gap measured as in "direct".
//
// Usage: node ams-pvg.mjs <setupJson> direct <outJson>
//        node ams-pvg.mjs <setupJson> bundler <rundler|alto> <bundlerUrl> <outJson>
import { readFileSync, writeFileSync } from "node:fs";
import { createWalletClient, http, decodeEventLog, encodeFunctionData, toHex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { clients, rpc, send, EP, ANVIL_KEYS, eth } from "./lib.mjs";
import { ABI, GAS, buildG1Op } from "./g1-lib.mjs";

const args = process.argv.slice(2);
const [setupJson, mode] = args;
const s = JSON.parse(readFileSync(setupJson, "utf8"));
if (!/^http:\/\/(127\.0\.0\.1|localhost):/.test(s.rpcUrl)) throw new Error("local node only");
const d = s.deploy;
const ctx = clients(s.rpcUrl, ANVIL_KEYS[0]);
const ownerKey = ANVIL_KEYS[s.ownerKeyIndex];
const TOPIC_USEROP = "0x49628fd1471006c1482da88028e9ce4dbb080b815c9b0344d39e5a8e6ec1419f"; // UserOperationEvent v0.7
// anvil dev key #8 (public) as the direct-mode "bundler" EOA
const DIRECT_KEY = "0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97";

const sum = (xs) => xs.reduce((a, b) => a + b, 0n);
const zeroNonzero = (hex) => { const b = Buffer.from(hex.slice(2), "hex"); let z = 0; for (const x of b) if (x === 0) z++; return { bytes: b.length, zero: z, nonzero: b.length - z }; };

async function ensureSpStake() {
    const info = await ctx.pub.readContract({ address: EP, abi: ABI.ep, functionName: "getDepositInfo", args: [d.superPaymaster] });
    if (info.stake < eth("1")) await send(ctx, d.superPaymaster, ABI.sp, "addStake", [86_400], eth("1") - info.stake);
}

function opsFor(name) {
    const acct = (n) => s.accounts[n].address;
    if (name === "initCode") {
        const b4 = s.b4.ok;
        const factoryData = encodeFunctionData({ abi: ABI.factory, functionName: "createAccount", args: [s.owner, d.operatorToken, d.superPaymaster, BigInt(b4.salt)] });
        return [{ sender: b4.address, ownerKey, factory: b4.factory, factoryData }];
    }
    if (name === "bundle3") return ["b3a", "b3b", "b3c"].map((n) => ({ sender: acct(n), ownerKey }));
    return [{ sender: acct(name), ownerKey }];
}

async function analyzeTx(hash, ops) {
    const rc = await ctx.pub.getTransactionReceipt({ hash });
    const tx = await ctx.pub.getTransaction({ hash });
    const evs = rc.logs.filter((l) => l.address.toLowerCase() === EP.toLowerCase() && l.topics[0] === TOPIC_USEROP).map((l) => {
        // data: nonce, success, actualGasCost, actualGasUsed
        const w = (i) => BigInt("0x" + l.data.slice(2 + 64 * i, 2 + 64 * (i + 1)));
        return { userOpHash: l.topics[1], success: w(1) === 1n, actualGasCost: w(2), actualGasUsed: w(3) };
    });
    const pvgs = ops.map((o) => o.packed.preVerificationGas);
    const n = BigInt(evs.length);
    const used = rc.gasUsed;
    const sumUsed = sum(evs.map((e) => e.actualGasUsed));
    const sumPvg = sum(pvgs);
    const surplus = sumUsed - used; // > 0: the beneficiary received more than the tx cost (gas units)
    return {
        tx: hash, status: rc.status, txGasLimit: tx.gas.toString(), txGasUsed: used.toString(), effectiveGasPrice: rc.effectiveGasPrice.toString(),
        calldata: zeroNonzero(tx.input), nOps: evs.length, allSuccess: evs.every((e) => e.success),
        ops: evs.map((e, i) => ({ ...e, actualGasCost: e.actualGasCost.toString(), actualGasUsed: e.actualGasUsed.toString(), preVerificationGas: pvgs[i].toString() })),
        sumActualGasUsed: sumUsed.toString(), sumPVG: sumPvg.toString(),
        surplusGas_sumActualGasUsed_minus_txGasUsed: surplus.toString(),
        gapNoPVG_txGasUsed_minus_sum_actualGasUsed_minus_PVG: (used - (sumUsed - sumPvg)).toString(),
        // ceilDiv: (x+n-1)/n is a ceiling only for x >= 0; BigInt division truncates toward zero.
        breakEvenPVGperOp: n ? ceilDiv(sumPvg - surplus, n).toString() : null,
        gapNoPVGperOp: n ? ceilDiv(used - (sumUsed - sumPvg), n).toString() : null,
    };
}

const ceilDiv = (x, n) => (x >= 0n ? (x + n - 1n) / n : -((-x) / n));

async function direct(outJson) {
    await ensureSpStake();
    const pk = privateKeyToAccount(DIRECT_KEY);
    const w = createWalletClient({ account: pk, transport: http(s.rpcUrl, { timeout: 60_000 }) });
    const out = { mode: "direct", beneficiary: pk.address, gas: Object.fromEntries(Object.entries(GAS).map(([k, v]) => [k, v.toString()])), cases: {} };
    // order = a fresh SP's first op, then warm ops, then credit, then a 3-op bundle, then initCode
    for (const [label, name] of [["b1_first_op_fresh_SP", "b1"], ["b1_second_op_same_sender", "b1"], ["b8_first_op_of_sender_warm_SP", "b8"],
        ["b7_credit_first_op", "b7"], ["bundle3_b3abc_first_ops", "bundle3"], ["initCode_b4ok", "initCode"], ["b5_SP_RENEW", "b5"]]) {
        const ops = [];
        for (const p of opsFor(name)) {
            const extra = name === "b5" ? { flags: 1 } : {};
            ops.push(await buildG1Op(ctx, d, { ...p, ...extra }));
        }
        const hash = await w.writeContract({ address: EP, abi: ABI.ep, functionName: "handleOps", args: [ops.map((o) => o.packed), pk.address], chain: null, gas: 15_000_000n });
        await ctx.pub.waitForTransactionReceipt({ hash });
        out.cases[label] = await analyzeTx(hash, ops);
        const c = out.cases[label];
        console.log(`${label}: status ${c.status} n=${c.nOps} success=${c.allSuccess} gasUsed ${c.txGasUsed} sumActual ${c.sumActualGasUsed} sumPVG ${c.sumPVG} breakEvenPVG/op ${c.breakEvenPVGperOp} gapNoPVG/op ${c.gapNoPVGperOp}`);
    }
    writeFileSync(outJson, JSON.stringify(out, null, 1) + "\n");
}

async function bundler(kind, bundlerUrl, outJson) {
    await ensureSpStake();
    const B = (m, p = []) => rpc(bundlerUrl, m, p);
    const out = { mode: "bundler", kind, bundlerUrl, gas: Object.fromEntries(Object.entries(GAS).map(([k, v]) => [k, v.toString()])), cases: {} };
    out.bundlingMode = await B("debug_bundler_setBundlingMode", ["manual"]);
    for (const [label, name, extra] of [["b1_first_op_fresh_SP", "b1", {}], ["b1_second_op_same_sender", "b1", {}], ["b7_credit_first_op", "b7", {}],
        ["initCode_b4ok", "initCode", {}]]) {
        const [p] = opsFor(name);
        const mk = (pvg) => buildG1Op(ctx, d, { ...p, ...extra, gasOverride: { preVerificationGas: BigInt(pvg) } });
        const c = { probes: [] };
        const base = await mk(GAS.preVerificationGas);
        const est = await B("eth_estimateUserOperationGas", [base.rpcOp, EP]);
        c.estimate = est.result ?? est.error;
        const accepts = async (pvg) => {
            const op = await mk(pvg);
            const r = await B("eth_sendUserOperation", [op.rpcOp, EP]);
            const ok = !r.error;
            c.probes.push({ pvg, ok, error: r.error ? { code: r.error.code, message: String(r.error.message).slice(0, 300) } : null });
            if (ok) await B("debug_bundler_clearState", []);
            return ok;
        };
        let lo = 0, hi = 400_000;
        if (!(await accepts(hi))) { c.error = "not accepted even at PVG 400000"; out.cases[label] = c; console.log(label, c.error, JSON.stringify(c.probes.at(-1))); continue; }
        if (await accepts(lo)) hi = lo;
        while (hi - lo > 1) { const mid = Math.floor((lo + hi) / 2); if (await accepts(mid)) hi = mid; else lo = mid; }
        c.minAcceptedPVG = hi;
        c.rejectionAtMinMinus1 = c.probes.filter((x) => x.pvg === hi - 1 && !x.ok).map((x) => x.error)[0] ?? null;
        // submit at the threshold and bundle it, then measure the bundle tx
        const op = await mk(hi);
        const sub = await B("eth_sendUserOperation", [op.rpcOp, EP]);
        c.submitAtMin = sub.error ?? "ok";
        c.bundle = await B("debug_bundler_sendBundleNow", []);
        await new Promise((res) => setTimeout(res, 2000));
        let receipt = null;
        for (let i = 0; i < 20 && !receipt; i++) { const r = await B("eth_getUserOperationReceipt", [op.hash]); receipt = r.result; if (!receipt) await new Promise((res) => setTimeout(res, 500)); }
        if (receipt?.receipt?.transactionHash) c.onchain = await analyzeTx(receipt.receipt.transactionHash, [op]);
        else c.onchain = null;
        out.cases[label] = c;
        console.log(`${kind} ${label}: estimatePVG ${c.estimate?.preVerificationGas ? BigInt(c.estimate.preVerificationGas) : JSON.stringify(c.estimate).slice(0, 120)} minAccepted ${hi} included ${!!c.onchain} ${c.onchain ? `gasUsed ${c.onchain.txGasUsed} actual ${c.onchain.sumActualGasUsed} breakEvenPVG ${c.onchain.breakEvenPVGperOp} gapNoPVG ${c.onchain.gapNoPVGperOp}` : JSON.stringify(c.submitAtMin).slice(0, 200)}`);
    }
    writeFileSync(outJson, JSON.stringify(out, (k, v) => (typeof v === "bigint" ? v.toString() : v), 1) + "\n");
}

if (mode === "direct") await direct(args[2]);
else if (mode === "bundler") await bundler(args[2], args[3], args[4]);
else throw new Error("mode direct|bundler");
