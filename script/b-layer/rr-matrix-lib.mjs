// CC-125: pure cell definitions and mined-trace analysis. No RPC, artifacts or npm imports.
import assert from "node:assert/strict";
export const CAP = 2 ** 24;
export const MIN = 440_000;
export const ENGINE_COMMIT = "4e8874b2bdc840929585ca73e170993c50a4a531";
export const SELECTOR = { validate: "0x52b7512c", postOp: "0x7c627b21", guardError: "0x8890295d" };
export const regimes = (delta = 100_000) => {
    assert(Number.isSafeInteger(delta) && delta > 0 && CAP + delta < 30_000_000);
    return [{ id: "R0", gas: CAP }, { id: "RR30M", gas: 30_000_000 }, { id: "RRdelta", gas: CAP + delta }];
};
export function cells() {
    const out = [];
    for (const mode of ["balance", "credit"])
        for (const context of ["legacy160", "V2"])
            for (const warmth of ["cold", "warm"])
                for (const history of ["first", "subsequent"])
                    for (const position of ["1of1", "1of3", "3of3"])
                        for (const scenario of ["success", "execution-revert", "postOp-exhaustion", "refund", "refill", "state-demand"])
                            for (const postGas of [MIN - 1, MIN, MIN + 1]) {
                                const reason = context === "legacy160" ? "rc.4 emits 384 B; decoder accepts only 352/384 B; 5.4.2 160 B unreachable"
                                    : warmth === "cold" && position === "3of3" ? "SP already touched by ops 1 and 2 validation; cold validation at op 3 impossible" : null;
                                out.push({ id: [mode, context, warmth, history, position, scenario, postGas].join("-"),
                                    mode, context, warmth, history, position, scenario, postGas, applicable: reason === null, reason,
                                    expectedValidation: postGas < MIN ? "reject-before-reservation" : "admit",
                                    fixture: scenario === "postOp-exhaustion" ? "token-settlement-gas-burner (adversarial token; SP bytes unchanged)" : "unaltered-token" });
                            }
    return out;
}
export const integer = (x) => typeof x === "number" ? x : Number(BigInt(x));
export const ceilDiv = (a, b) => (a + b - 1n) / b;
export function costs(actualGasCost, snapshot, charge) {
    if (actualGasCost === null) return { bareCost: null, feeTarget: null, chargeMinusBareCost: null, chargeMinusFeeTarget: null };
    const bareCost = ceilDiv(BigInt(actualGasCost) * BigInt(snapshot.price) * 10n ** 18n,
        10n ** BigInt(snapshot.decimals) * BigInt(snapshot.aPriceUSD));
    const feeTarget = ceilDiv(bareCost * (10_000n + BigInt(snapshot.feeBps)), 10_000n);
    return { bareCost, feeTarget, chargeMinusBareCost: BigInt(charge) - bareCost, chargeMinusFeeTarget: BigInt(charge) - feeTarget };
}
export function freshCode(n, revert = false, clear = false) {
    assert(Number.isInteger(n) && n >= 1 && n <= 65535);
    return "0x" + Array.from({ length: n }, (_, i) => `60${clear ? "00" : "01"}61${i.toString(16).padStart(4, "0")}55`).join("")
        + (revert ? "5f5ffd" : "00");
}
// Local fixture: forward every call via the original clone runtime in a shadow account,
// except settlement for one user, which loops until OOG. Storage and msg.sender are preserved.
export function exhaustionCode(shadow, user) {
    assert(/^0x[0-9a-fA-F]{40}$/.test(shadow) && /^0x[0-9a-fA-F]{40}$/.test(user));
    const bytes = [], labels = {}, patches = [];
    const emit = (s) => bytes.push(...Buffer.from(s, "hex"));
    const label = (s) => { labels[s] = bytes.length; emit("5b"); };
    const jump = (s, conditional = false) => { emit("61"); patches.push([bytes.length, s]); emit(conditional ? "000057" : "000056"); };
    emit("5f3560e01c80637e48bbce1490631baf44081417"); jump("checkUser", true); jump("forward");
    label("checkUser"); emit(`60043573${user.slice(2)}14`); jump("burn", true); jump("forward");
    label("burn"); jump("burn");
    label("forward"); emit(`365f5f375f5f365f73${shadow.slice(2)}5af43d5f5f3e`); jump("ok", true);
    emit("3d5ffd"); label("ok"); emit("3d5ff3");
    for (const [offset, name] of patches) { assert(name in labels); bytes[offset] = labels[name] >> 8; bytes[offset + 1] = labels[name] & 255; }
    return "0x" + Buffer.from(bytes).toString("hex");
}
const point = (s, index) => ({ index, depth: s.depth, pc: s.pc, op: s.op, gas: integer(s.gas),
    stateGasReservoir: integer(s.stateGasReservoir), refund: s.refund ?? null, error: s.error ?? null });
// Associate actual depth transitions with callTracer children using destination, type and
// entry gas. Precompiles/empty-code calls have no opcode frame and are skipped. Fail closed.
export function traceSummary(trace, call, sp, impl, txGas, fixture = null) {
    const steps = trace.structLogs;
    assert(steps?.length, "missing struct logs: start anvil with --steps-tracing");
    assert(steps.every((s) => s.stateGasReservoir !== undefined), "engine lacks stateGasReservoir");
    const frames = [], active = new Map();
    const root = { call, cursor: 0, start: 0, end: 0, depth: steps[0].depth };
    active.set(root.depth, root); frames.push(root);
    const same = (a, b) => a?.toLowerCase() === b?.toLowerCase();
    for (let i = 0; i < steps.length; i++) {
        const s = steps[i], prev = steps[i - 1];
        if (prev && s.depth > prev.depth) {
            assert.equal(s.depth, prev.depth + 1);
            const parent = active.get(prev.depth);
            assert(["CALL", "STATICCALL", "DELEGATECALL", "CALLCODE"].includes(prev.op), `unsupported frame creation ${prev.op}`);
            const to = "0x" + prev.stack.at(-2).replace(/^0x/, "").slice(-40).padStart(40, "0");
            const children = parent.call.calls ?? [];
            const ix = children.findIndex((c, j) => j >= parent.cursor && same(c.to, to)
                && c.type.toUpperCase() === prev.op && integer(c.gas) === integer(s.gas));
            assert(ix >= 0, `cannot map struct frame at step ${i} (${prev.op} ${to} gas ${s.gas})`);
            parent.cursor = ix + 1;
            const f = { call: children[ix], cursor: 0, start: i, end: i, depth: s.depth };
            frames.push(f); active.set(s.depth, f);
        }
        const f = active.get(s.depth); assert(f, `missing parent at ${i}`); f.end = i;
    }
    const identified = frames.filter((f) => (same(f.call.to, sp) || same(f.call.to, impl))
        && Object.values(SELECTOR).some((sel) => f.call.input?.startsWith(sel)));
    const summaries = identified.map((f) => {
        const own = steps.slice(f.start, f.end + 1).map((s, j) => [s, f.start + j]).filter(([s]) => s.depth === f.depth);
        const gasOp = own.find(([s]) => s.op === "GAS");
        return { type: f.call.type, to: f.call.to, selector: f.call.input.slice(0, 10), input: f.call.input,
            output: f.call.output ?? "0x", error: f.call.error ?? null,
            entry: point(steps[f.start], f.start), terminal: point(steps[f.end], f.end),
            firstGasOpcode: gasOp ? { ...point(...gasOp), gasleftReturned: integer(gasOp[0].gas) - integer(gasOp[0].gasCost) } : null };
    });
    const transitions = [];
    for (let i = 1; i < steps.length; i++) {
        const before = integer(steps[i - 1].stateGasReservoir), after = integer(steps[i].stateGasReservoir);
        if (before !== after) transitions.push({ afterStep: i - 1, before, after, delta: after - before,
            causeOpcode: steps[i - 1].op, causeError: steps[i - 1].error ?? null, fromDepth: steps[i - 1].depth, toDepth: steps[i].depth });
    }
    assert.equal(integer(steps[0].stateGasReservoir), Math.max(0, txGas - CAP), "wrong reservoir initialization");
    assert(integer(steps[0].gas) < CAP, "regular gas uncapped");
    const executionFrames = frames.filter((f) => same(f.call.to, fixture)).map((f) => ({
        to: f.call.to, entry: point(steps[f.start], f.start), terminal: point(steps[f.end], f.end),
        firstAfterReturn: steps[f.end + 1] ? point(steps[f.end + 1], f.end + 1) : null,
        error: f.call.error ?? null,
        sstores: steps.slice(f.start, f.end + 1).filter((s) => s.depth === f.depth && s.op === "SSTORE").length,
    }));
    const refundIncreases = steps.flatMap((s, i) => i > 0 && integer(s.refund ?? 0) > integer(steps[i - 1].refund ?? 0)
        ? [{ index: i, previousOpcode: steps[i - 1].op, depth: steps[i - 1].depth, pc: steps[i - 1].pc,
            before: steps[i - 1].refund ?? 0, after: s.refund }] : []);
    const terminal = point(steps.at(-1), steps.length - 1);
    return { topError: call.error ?? null, topOutput: call.output ?? "0x", handleOpsEntry: point(steps[0], 0), frames: summaries, terminal,
        end: ["RETURN", "STOP"].includes(terminal.op) && !terminal.error ? terminal : null,
        endNote: "structLogs are pre-opcode; end is exact only for successful RETURN/STOP, otherwise terminal is the last observation",
        transitions, executionFrames, refundIncreases, drawn: transitions.some((x) => x.delta < 0 && x.causeOpcode === "SSTORE"),
        refillObserved: transitions.some((x) => x.delta > 0 && (x.causeOpcode === "REVERT" || (x.causeError && x.toDepth < x.fromDepth))) };
}
export function selfTest() {
    const all = cells(), live = all.filter((c) => c.applicable);
    assert.equal(new Set(all.map((c) => c.id)).size, all.length);
    assert.equal(all.length, 864); assert.equal(live.length, 360);
    for (const key of ["mode", "context", "warmth", "history", "position", "scenario", "postGas"])
        assert(new Set(live.map((c) => c[key])).size >= (key === "context" ? 1 : 2));
    assert(all.filter((c) => c.context === "legacy160").every((c) => !c.applicable));
    assert(live.filter((c) => c.postGas < MIN).every((c) => c.expectedValidation === "reject-before-reservation"));
    for (const r of regimes()) assert.equal(r.gas > CAP, r.id !== "R0");
    assert.throws(() => regimes(0)); assert.throws(() => regimes(14_000_000));
    assert.equal(freshCode(1), "0x60016100005500"); assert.equal(freshCode(1, true, true), "0x6000610000555f5ffd");
    const code = exhaustionCode("0x" + "11".repeat(20), "0x" + "22".repeat(20));
    assert(code.includes("7e48bbce") && code.includes("1baf4408"));
    // Execute the dispatch branch offline: only the two settlement selectors for the
    // designated sender may reach the loop. Other calls must reach forwarding.
    const route = (selector, user) => {
        const bytes = Buffer.from(code.slice(2), "hex"), stack = [], seen = new Set(); let pc = 0;
        const calldata = Buffer.from(selector + user.padStart(64, "0"), "hex");
        for (let n = 0; n < 100; n++) {
            if (seen.has(pc)) return "burn"; seen.add(pc);
            const op = bytes[pc++];
            if (op >= 0x60 && op <= 0x7f) { const size = op - 0x5f; stack.push(BigInt("0x" + bytes.subarray(pc, pc + size).toString("hex"))); pc += size; }
            else if (op === 0x5f) stack.push(0n);
            else if (op === 0x35) { const offset = Number(stack.pop()); stack.push(BigInt("0x" + calldata.subarray(offset, offset + 32).toString("hex").padEnd(64, "0"))); }
            else if (op === 0x1c) { const shift = stack.pop(), value = stack.pop(); stack.push(value >> shift); }
            else if (op === 0x80) stack.push(stack.at(-1));
            else if (op === 0x90) [stack[stack.length - 1], stack[stack.length - 2]] = [stack.at(-2), stack.at(-1)];
            else if (op === 0x14) stack.push(stack.pop() === stack.pop() ? 1n : 0n);
            else if (op === 0x17) stack.push(stack.pop() | stack.pop());
            else if (op === 0x56) pc = Number(stack.pop());
            else if (op === 0x57) { const dest = Number(stack.pop()); if (stack.pop()) pc = dest; }
            else if (op === 0x36) stack.push(BigInt(calldata.length));
            else if (op === 0x37) return "forward";
            else assert.equal(op, 0x5b);
        }
        throw new Error("dispatcher did not terminate");
    };
    assert.equal(route("7e48bbce", "22".repeat(20)), "burn");
    assert.equal(route("1baf4408", "22".repeat(20)), "burn");
    assert.equal(route("7e48bbce", "33".repeat(20)), "forward");
    assert.equal(route("52b7512c", "22".repeat(20)), "forward");
    assert.deepEqual(costs(1n, { price: 1n, decimals: 18, aPriceUSD: 1n, feeBps: 1000n }, 2n),
        { bareCost: 1n, feeTarget: 2n, chargeMinusBareCost: 1n, chargeMinusFeeTarget: 0n });
    const sp = "0x" + "11".repeat(20), impl = "0x" + "22".repeat(20);
    const step = (op, depth, gas, reservoir, stack = []) => ({ op, depth, gas, gasCost: 2, pc: 0, stateGasReservoir: reservoir, stack });
    const trace = { structLogs: [step("CALL", 1, 1000, 100000, [sp.slice(2), "100"]),
        step("GAS", 2, 100, 100000), step("REVERT", 2, 98, 90000), step("STOP", 1, 900, 100000)] };
    const call = { calls: [{ type: "CALL", to: sp, gas: "0x64", input: SELECTOR.postOp }] };
    const summary = traceSummary(trace, call, sp, impl, CAP + 100000);
    assert.equal(summary.frames[0].firstGasOpcode.gasleftReturned, 98);
    assert.equal(summary.end.stateGasReservoir, 100000); assert(summary.refillObserved);
    assert.throws(() => traceSummary({ structLogs: [{ op: "STOP", gas: 1, depth: 1 }] }, {}, sp, impl, CAP));
    return { definitions: all.length, applicableCells: live.length, transactions: live.length * regimes().length,
        skippedDefinitions: all.length - live.length, status: "PASS" };
}
