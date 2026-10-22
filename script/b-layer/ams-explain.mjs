// R-AMS-2 follow-up (REPORT §6.1): two read-only investigations on a fresh variant-a stack.
//  (1) pmV trace: handleOps([op]) via debug_traceCall at given paymasterVerificationGasLimit values
//      (others generous, low fee). For each: the SP validatePaymasterUserOp frame (gas, gasUsed,
//      error, decoded validationData → sigFail bit) and SP's child calls into the token
//      (tryLockForGas / tryReserveCredit: gas, gasUsed, error), and the EntryPoint verdict.
//      Plus an "Alto-style" search: the smallest pmV at which the paymaster frame does NOT revert
//      (EntryPoint verdict is not AA33/AA36 — a sigFail AA34 counts as "did not revert", which is
//      the predicate Alto's estimator applies), next to the smallest pmV at which the op succeeds.
//  (2) B7 at 3 gwei: maxCost / a0 of the generous probe op vs the account's effective credit cap,
//      and the minimum-need search at 3 gwei with a smaller "generous" baseline.
// Usage: node script/b-layer/ams-explain.mjs <setupJson> <outJson> [pmV...]
import { readFileSync, writeFileSync } from "node:fs";
import { encodeFunctionData, decodeFunctionResult, toHex, toFunctionSelector } from "viem";
import { clients, rpc, EP, ANVIL_KEYS } from "./lib.mjs";
import { ABI, GAS, buildG1Op, a0Of, FLAG_SP_RENEW } from "./g1-lib.mjs";
import { needs, simulate } from "./ams-probe.mjs";

const [setupJson, outJson, ...pmvArgs] = process.argv.slice(2);
const s = JSON.parse(readFileSync(setupJson, "utf8"));
if (!/^http:\/\/(127\.0\.0\.1|localhost):/.test(s.rpcUrl)) throw new Error("local node only");
const d = s.deploy; const ctx = clients(s.rpcUrl, ANVIL_KEYS[0]);
const FROM = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
const LOW = 100_000_000n;
const GEN = { verificationGasLimit: 1_500_000n, callGasLimit: 500_000n, pmPostOpGasLimit: 1_500_000n, maxFeePerGas: LOW, maxPriorityFeePerGas: LOW };
const SEL = { tryLockForGas: toFunctionSelector("tryLockForGas(address,bytes32,uint256,bool)"), tryReserveCredit: toFunctionSelector("tryReserveCredit(address,bytes32,uint256)") };
const vpmAbi = [{ type: "function", name: "validatePaymasterUserOp", stateMutability: "nonpayable", inputs: [], outputs: [{ name: "context", type: "bytes" }, { name: "validationData", type: "uint256" }] }];
const params = (n) => ({ sender: s.accounts[n].address, ownerKey: ANVIL_KEYS[s.ownerKeyIndex], ...(n === "b5" ? { flags: FLAG_SP_RENEW } : {}) });

function walk(f, fn, depth = 0) { fn(f, depth); for (const c of f.calls ?? []) walk(c, fn, depth + 1); }
async function trace(name, pmV) {
    const op = await buildG1Op(ctx, d, { ...params(name), gasOverride: { ...GEN, pmVerificationGasLimit: BigInt(pmV) } });
    const data = encodeFunctionData({ abi: ABI.ep, functionName: "handleOps", args: [[op.packed], "0x000000000000000000000000000000000000bEEF"] });
    const r = (await rpc(s.rpcUrl, "debug_traceCall", [{ from: FROM, to: EP, data, gas: toHex(16_000_000) }, "latest", { tracer: "callTracer" }])).result;
    const sim = await simulate(s.rpcUrl, op.packed);
    let pm = null; const tokenCalls = [];
    walk(r, (f) => {
        if (!pm && f.input?.startsWith("0x52b7512c") && f.to?.toLowerCase() === d.superPaymaster.toLowerCase()) {
            pm = { gas: parseInt(f.gas, 16), gasUsed: parseInt(f.gasUsed, 16), error: f.error ?? null };
            try { const [, vd] = decodeFunctionResult({ abi: vpmAbi, functionName: "validatePaymasterUserOp", data: f.output });
                pm.validationData = toHex(vd); pm.sigFail = (vd & ((1n << 160n) - 1n)) === 1n; } catch { pm.output = f.output?.slice(0, 80); }
            walk(f, (c) => { const sel = c.input?.slice(0, 10);
                for (const [k, v] of Object.entries(SEL)) if (sel === v) tokenCalls.push({ fn: k, gas: parseInt(c.gas, 16), gasUsed: parseInt(c.gasUsed, 16), error: c.error ?? null, output: c.output ?? null }); });
        }
    });
    return { case: name, pmV: Number(pmV), entryPoint: sim.ok ? "ok" : sim.failedOp ? `${sim.failedOp.name}(${sim.failedOp.args.join(",")})` : `success=${sim.success}`, pmFrame: pm, tokenCalls };
}
const reverted = (t) => /AA33|AA36|AA13|AA23/.test(t.entryPoint);
async function search(name, pred) { let lo = 0, hi = 2_000_000; while (hi - lo > 1) { const m = Math.floor((lo + hi) / 2); if (pred(await trace(name, m))) hi = m; else lo = m; } return hi; }

const out = { rpcUrl: s.rpcUrl, pmvTrace: [], altoStyle: [], b7Fee: {} };
for (const name of ["b1", "b5", "b6", "b7"]) {
    const noRevert = await search(name, (t) => !reverted(t));
    const succeeds = await search(name, (t) => t.entryPoint === "ok");
    const row = { case: name, minPmvPaymasterDoesNotRevert: noRevert, minPmvOpSucceeds: succeeds,
        atNoRevert: await trace(name, noRevert), belowNoRevert: await trace(name, noRevert - 1), atSucceeds: await trace(name, succeeds), belowSucceeds: await trace(name, succeeds - 1) };
    out.altoStyle.push(row);
    console.log(`${name}: smallest pmV where SP does not revert = ${noRevert} (${row.atNoRevert.entryPoint}; token ${JSON.stringify(row.atNoRevert.tokenCalls.map((c) => [c.fn, c.error]))}); smallest pmV where the op succeeds = ${succeeds}`);
}
for (const v of pmvArgs) for (const name of ["b1", "b6"]) { const t = await trace(name, Number(v)); out.pmvTrace.push(t); console.log(JSON.stringify(t)); }

// (2) B7 at 3 gwei
{
    const fee = 3_000_000_000n;
    const gen = { verificationGasLimit: 1_500_000n, callGasLimit: 500_000n, pmVerificationGasLimit: 2_000_000n, pmPostOpGasLimit: 1_500_000n };
    const maxCost = (g) => (g.verificationGasLimit + g.callGasLimit + g.pmVerificationGasLimit + g.pmPostOpGasLimit + GAS.preVerificationGas) * fee;
    const cap = await ctx.pub.readContract({ address: d.operatorToken, abi: ABI.token, functionName: "effectiveCreditCap", args: [s.accounts.b7.address] });
    const debt = await ctx.pub.readContract({ address: d.operatorToken, abi: ABI.token, functionName: "debts", args: [s.accounts.b7.address] });
    const small = { verificationGasLimit: 300_000n, callGasLimit: 100_000n, pmVerificationGasLimit: 1_000_000n, pmPostOpGasLimit: 500_000n };
    const a0Gen = await a0Of(ctx, d, maxCost(gen)), a0Small = await a0Of(ctx, d, maxCost(small));
    out.b7Fee = { fee: fee.toString(), effectiveCreditCap: cap.toString(), debt: debt.toString(),
        generous: { gas: Object.fromEntries(Object.entries(gen).map(([k, v]) => [k, v.toString()])), maxCost: maxCost(gen).toString(), a0: a0Gen.toString(), a0ExceedsCap: a0Gen > cap },
        smaller: { gas: Object.fromEntries(Object.entries(small).map(([k, v]) => [k, v.toString()])), maxCost: maxCost(small).toString(), a0: a0Small.toString(), a0ExceedsCap: a0Small > cap },
        needsAtGenerous: await needs({ ctx, d, rpcUrl: s.rpcUrl, params: params("b7"), fee }),
        needsAtSmaller: await needs({ ctx, d, rpcUrl: s.rpcUrl, params: params("b7"), fee, generousOverride: small }) };
    const x = out.b7Fee;
    console.log(`B7 3 gwei: cap ${x.effectiveCreditCap}; generous a0 ${x.generous.a0} (> cap: ${x.generous.a0ExceedsCap}) → ${x.needsAtGenerous.generousBaseline.brief}; smaller a0 ${x.smaller.a0} (> cap: ${x.smaller.a0ExceedsCap}) → ${x.needsAtSmaller.generousBaseline.brief} needs v=${x.needsAtSmaller.verificationGasLimit} c=${x.needsAtSmaller.callGasLimit} pmV=${x.needsAtSmaller.pmVerificationGasLimit} pmP=${x.needsAtSmaller.pmPostOpGasLimit}`);
}
writeFileSync(outJson, JSON.stringify(out, (k, v) => (typeof v === "bigint" ? v.toString() : v), 2));
