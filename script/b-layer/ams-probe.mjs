// R-AMS-2 (B layer on an Amsterdam-level chain) — per-case gas probe, called by g1-cases.mjs when
// G1_ESTIMATE=1, immediately BEFORE the op is submitted (same chain state the bundler validates).
//  1. eth_estimateUserOperationGas from the bundler under test, two request shapes:
//     "pmSupplied" (paymaster gas fields as the case sends them) and "pmOmitted" (both omitted);
//     callGasLimit / verificationGasLimit / preVerificationGas are always omitted.
//  2. "needs": the minimum of each executable gas field at which EntryPoint.handleOps([op]) fully
//     succeeds (no FailedOp, UserOperationEvent.success, no PostOpRevertReason), the other fields
//     held at generous values; binary search with debug_traceCall straight on anvil (not through
//     the bundler's proxy, so the bundler traces stay clean). Probe ops use maxFee = tip = 0.1 gwei
//     so that the generous limits do not exceed the case's token balance / credit cap (gas price
//     changes only the amounts SP locks, not which slots it touches).
//  3. "sufficiency": the op rebuilt with each estimate (missing paymaster fields → the case's
//     supplied value, or for pmOmitted the bundler's own default 0) at the case's real fees, run
//     through handleOps the same way — does the bundler's estimate actually execute?
//  4. "submitted": the op exactly as submitted, run through handleOps (predicts the on-chain fate).
// handleOps runs as account 0 with tx gas 16,000,000 (≤ the EIP-7825 cap, i.e. no EIP-8037 state-gas
// reservoir — a bundler's handleOps tx is below the cap too). Local anvil only.
import { encodeFunctionData, decodeEventLog, decodeErrorResult, parseAbi, toHex } from "viem";
import { rpc, EP } from "./lib.mjs";
import { ABI, GAS, buildG1Op } from "./g1-lib.mjs";

const EP_EVENTS = parseAbi([
    "event UserOperationEvent(bytes32 indexed userOpHash, address indexed sender, address indexed paymaster, uint256 nonce, bool success, uint256 actualGasCost, uint256 actualGasUsed)",
    "event PostOpRevertReason(bytes32 indexed userOpHash, address indexed sender, uint256 nonce, bytes revertReason)",
    "event UserOperationRevertReason(bytes32 indexed userOpHash, address indexed sender, uint256 nonce, bytes revertReason)",
    "event UserOperationPrefundTooLow(bytes32 indexed userOpHash, address indexed sender, uint256 nonce)",
    "event AccountDeployed(bytes32 indexed userOpHash, address indexed sender, address factory, address paymaster)",
]);
const SEL = { validateUserOp: "0x19822f7c", validatePaymasterUserOp: "0x52b7512c", postOp: "0x7c627b21", createSender: "0x570e1a36",
    innerHandleOp: "0x0042dc53" };
const BENEFICIARY = "0x000000000000000000000000000000000000bEEF";
const FROM = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
const TX_GAS = 16_000_000;
const LOW_FEE = 100_000_000n;

/** Decode EntryPoint events from a list of {address, topics, data}. */
export function epEvents(logs) {
    const out = [];
    for (const lg of logs) {
        if (lg.address?.toLowerCase() !== EP.toLowerCase()) continue;
        try {
            const ev = decodeEventLog({ abi: EP_EVENTS, data: lg.data, topics: lg.topics });
            out.push({ event: ev.eventName, args: Object.fromEntries(Object.entries(ev.args).map(([k, v]) => [k, String(v)])) });
        } catch { /* other EP event (Deposited, BeforeExecution, ...) */ }
    }
    return out;
}

function walk(frame, fn, depth = 0) { fn(frame, depth); for (const c of frame.calls ?? []) walk(c, fn, depth + 1); }

/** handleOps([packed]) via debug_traceCall + callTracer(withLog). */
export async function simulate(rpcUrl, packed, txGas = TX_GAS) {
    const data = encodeFunctionData({ abi: ABI.ep, functionName: "handleOps", args: [[packed], BENEFICIARY] });
    const r = await rpc(rpcUrl, "debug_traceCall", [{ from: FROM, to: EP, data, gas: toHex(txGas) }, "latest",
        { tracer: "callTracer", tracerConfig: { withLog: true } }]);
    if (r.error) return { ok: false, rpcError: r.error };
    const t = r.result;
    const res = { ok: false, txGasUsed: parseInt(t.gasUsed, 16) };
    if (t.error) {
        res.topError = t.error;
        try {
            const e = decodeErrorResult({ abi: ABI.ep, data: t.output });
            res.failedOp = { name: e.errorName, args: e.args.map((a) => String(a)) };
        } catch { res.revertData = t.output?.slice(0, 200); }
        return res;
    }
    const logs = []; const frames = {};
    walk(t, (f) => {
        for (const lg of f.logs ?? []) logs.push({ address: lg.address, topics: lg.topics, data: lg.data });
        const sel = f.input?.slice(0, 10);
        for (const [name, s] of Object.entries(SEL)) if (sel === s && !frames[name]) frames[name] = { gas: parseInt(f.gas, 16), gasUsed: parseInt(f.gasUsed, 16), error: f.error ?? null };
    });
    res.events = epEvents(logs);
    res.frames = frames;
    const uoe = res.events.find((e) => e.event === "UserOperationEvent");
    res.success = uoe ? uoe.args.success === "true" : null;
    res.actualGasUsed = uoe ? Number(uoe.args.actualGasUsed) : null;
    res.postOpReverted = res.events.some((e) => e.event === "PostOpRevertReason");
    res.execReverted = res.events.some((e) => e.event === "UserOperationRevertReason");
    res.ok = res.success === true && !res.postOpReverted;
    return res;
}

const brief = (r) => r.ok ? "ok" : r.failedOp ? `${r.failedOp.name}(${r.failedOp.args.join(",")})`
    : r.rpcError ? `rpc ${r.rpcError.message}` : r.topError ? `revert ${r.topError}` : `success=${r.success} postOpReverted=${r.postOpReverted} execReverted=${r.execReverted}`;

async function binsearch(pred, lo, hi) { // pred(lo) false assumed, pred(hi) true checked by caller
    while (hi - lo > 1) { const m = Math.floor((lo + hi) / 2); if (await pred(m)) hi = m; else lo = m; }
    return hi;
}

export async function probe({ ctx, d, rpcUrl, B, op }) {
    const out = { estimates: {}, sufficiency: {}, needs: null, submitted: null };
    const base = op.params;
    // 4. as submitted
    out.submitted = await simulate(rpcUrl, op.packed); out.submitted.brief = brief(out.submitted);
    // 1. bundler estimates
    const strip = (o, fields) => { const q = { ...o }; for (const f of fields) delete q[f]; return q; };
    const shapes = {
        pmSupplied: strip(op.rpcOp, ["callGasLimit", "verificationGasLimit", "preVerificationGas"]),
        pmOmitted: strip(op.rpcOp, ["callGasLimit", "verificationGasLimit", "preVerificationGas", "paymasterVerificationGasLimit", "paymasterPostOpGasLimit"]),
    };
    for (const [k, q] of Object.entries(shapes)) {
        const r = await B("eth_estimateUserOperationGas", [q, EP]);
        out.estimates[k] = { response: r };
        if (r.result) {
            const e = r.result; const n = (x) => (x == null ? null : BigInt(x));
            const g = {
                verificationGasLimit: n(e.verificationGasLimit), callGasLimit: n(e.callGasLimit),
                pmVerificationGasLimit: n(e.paymasterVerificationGasLimit) ?? (k === "pmSupplied" ? GAS.pmVerificationGasLimit : 0n),
                pmPostOpGasLimit: n(e.paymasterPostOpGasLimit) ?? (k === "pmSupplied" ? BigInt(op.rpcOp.paymasterPostOpGasLimit) : 0n),
            };
            const rebuilt = await buildG1Op(ctx, d, { ...base, gasOverride: g });
            const sim = await simulate(rpcUrl, rebuilt.packed);
            out.sufficiency[k] = { used: Object.fromEntries(Object.entries(g).map(([a, b]) => [a, b.toString()])),
                pmPostOpFilledByUs: e.paymasterPostOpGasLimit == null, ok: sim.ok, brief: brief(sim), sim };
        }
    }
    // 2. needs (generous baseline, low fee)
    out.needs = await needs({ ctx, d, rpcUrl, params: base });
    return out;
}

/** Minimum of each executable gas field (others generous, low fee) for handleOps([op]) with tx gas `txGas`. */
export async function needs({ ctx, d, rpcUrl, params, txGas = TX_GAS, fee = LOW_FEE }) {
    const generous = { verificationGasLimit: params.factory ? 4_000_000n : 1_500_000n, callGasLimit: 500_000n,
        pmVerificationGasLimit: 2_000_000n, pmPostOpGasLimit: 1_500_000n, maxFeePerGas: fee, maxPriorityFeePerGas: fee };
    const run = async (g) => simulate(rpcUrl, (await buildG1Op(ctx, d, { ...params, gasOverride: g })).packed, txGas);
    const gen = await run(generous);
    const out = { txGas, fee: fee.toString(), generousBaseline: { ok: gen.ok, brief: brief(gen), frames: gen.frames ?? null, actualGasUsed: gen.actualGasUsed ?? null, txGasUsed: gen.txGasUsed } };
    if (gen.ok) {
        for (const f of ["verificationGasLimit", "callGasLimit", "pmVerificationGasLimit", "pmPostOpGasLimit"]) {
            out[f] = await binsearch(async (m) => (await run({ ...generous, [f]: BigInt(m) })).ok, 0, Number(generous[f]));
        }
    }
    return out;
}

/** One line for the case log. */
export function probeSummary(p) {
    const e = (k) => { const r = p.estimates[k]?.response; if (!r) return "-"; if (r.error) return `ERR[${r.error.code}] ${String(r.error.message).slice(0, 80)}`;
        const x = r.result; return `v=${parseInt(x.verificationGasLimit)} c=${parseInt(x.callGasLimit)} pmV=${x.paymasterVerificationGasLimit != null ? parseInt(x.paymasterVerificationGasLimit) : "-"} pmP=${x.paymasterPostOpGasLimit != null ? parseInt(x.paymasterPostOpGasLimit) : "-"} pvg=${parseInt(x.preVerificationGas)} → ${p.sufficiency[k]?.brief}`; };
    const n = p.needs; const need = n?.verificationGasLimit ? `needs v=${n.verificationGasLimit} c=${n.callGasLimit} pmV=${n.pmVerificationGasLimit} pmP=${n.pmPostOpGasLimit}` : `needs: baseline ${n?.generousBaseline?.brief}`;
    return `submitted→${p.submitted.brief} | est[pmSupplied] ${e("pmSupplied")} | est[pmOmitted] ${e("pmOmitted")} | ${need}`;
}
