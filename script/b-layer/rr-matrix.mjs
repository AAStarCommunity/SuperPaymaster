// CC-125 real mined EntryPoint v0.7 RR matrix. Invoked by rr-matrix-run.py.
// --self-test needs neither anvil nor viem nor Foundry artifacts.
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, appendFileSync, mkdirSync, existsSync } from "node:fs";
import { resolve } from "node:path";
import { gzipSync } from "node:zlib";
import { cells, regimes, MIN, SELECTOR, costs, freshCode, exhaustionCode, traceSummary, selfTest } from "./rr-matrix-lib.mjs";

const json = (v) => JSON.stringify(v, (_, x) => typeof x === "bigint" ? x.toString() : x);
if (process.argv.includes("--self-test")) {
    console.log(json(selfTest()));
} else {
    await run();
}
async function run() {
    const [setupFile, outArg, deltaArg = "100000", filter = ""] = process.argv.slice(2);
    assert(setupFile && outArg, "usage: rr-matrix.mjs <setup.json> <output-dir> [delta] [id-substring]");
    const out = resolve(outArg), s = JSON.parse(readFileSync(setupFile, "utf8"));
    const url = new URL(s.rpcUrl);
    assert(url.protocol === "http:" && ["127.0.0.1", "localhost"].includes(url.hostname) && url.port, "local node only");
    // Deliberately defer all B-layer/viem imports until after --self-test.
    const { encodeFunctionData, decodeEventLog, decodeAbiParameters, decodeErrorResult, parseAbiParameters, keccak256, toHex } = await import("viem");
    const { clients, rpc, send, EP, ANVIL_KEYS } = await import("./lib.mjs");
    const { ABI, buildG1Op } = await import("./g1-lib.mjs");
    const { epEvents } = await import("./ams-probe.mjs");
    const ctx = clients(s.rpcUrl, ANVIL_KEYS[0]), d = s.deploy;
    const request = async (method, params = []) => {
        const r = await rpc(s.rpcUrl, method, params); if (r.error) throw new Error(`${method}: ${json(r.error)}`); return r.result;
    };
    assert.equal(await request("eth_chainId"), "0x7a69");
    const version = await ctx.pub.readContract({ address: d.superPaymaster, abi: ABI.sp, functionName: "version" });
    assert.equal(version, "SuperPaymaster-5.5.0");
    const read = (address, abi, functionName, args = []) => ctx.pub.readContract({ address, abi, functionName, args });
    const gp = await read(d.superPaymaster, ABI.sp, "gasParams");
    assert.deepEqual([gp[0].minPostOpGas, gp[0].settleGasBound, gp[0].cWrap, gp[0].cPostop].map(Number), [440000, 420000, 5000, 340000]);
    mkdirSync(resolve(out, "traces"), { recursive: true });
    const header = JSON.parse(readFileSync(resolve(out, "header.json"), "utf8"));
    assert(!existsSync(resolve(out, "cells.jsonl")), "refuse to overwrite existing cells");
    writeFileSync(resolve(out, "cells.jsonl"), "");
    writeFileSync(resolve(out, "definitions.json"), json({ regimes: regimes(Number(deltaArg)), cells: cells() }) + "\n");
    writeFileSync(resolve(out, "runtime.json"), json({ version, gasParams: gp, deploy: d,
        codeHashes: Object.fromEntries(await Promise.all(["superPaymaster", "spImpl", "operatorToken", "xPNTsTokenV2Impl", "xPNTsTokenV2Ext"].map(async (k) => [k, keccak256(await ctx.pub.getCode({ address: d[k] }))]))) }) + "\n");
    const target = "0x00000000000000000000000000000000000cc126";
    const shadow = "0x00000000000000000000000000000000000cc127";
    const unused = "0x00000000000000000000000000000000000cc128";
    const signKey = ANVIL_KEYS[s.ownerKeyIndex];
    const gas = { verificationGasLimit: 1_500_000n, callGasLimit: 1_500_000n, pmVerificationGasLimit: 2_000_000n,
        preVerificationGas: 100_000n, maxFeePerGas: 100_000_000n, maxPriorityFeePerGas: 100_000_000n };
    const build = async (sender, postGas, sink = unused) => buildG1Op(ctx, d, { sender, ownerKey: signKey, flags: 0,
        callData: encodeFunctionData({ abi: ABI.account, functionName: "execute", args: [sink, 0n, "0x"] }),
        gasOverride: { ...gas, pmPostOpGasLimit: BigInt(postGas) } });
    const receipt = async (hash) => {
        for (let i = 0; i < 480; i++) {
            const r = await request("eth_getTransactionReceipt", [hash]); if (r) return r;
            await new Promise((r) => setTimeout(r, 250));
        }
        throw new Error(`receipt timeout ${hash}`);
    };
    // Explicit gas and fee fields. No eth_call/eth_estimateGas to determine RR behavior.
    const mine = async (ops, limit, warm) => {
        const tx = { from: ctx.account.address, to: EP, gas: toHex(limit), gasPrice: toHex(gas.maxFeePerGas),
            data: encodeFunctionData({ abi: ABI.ep, functionName: "handleOps", args: [ops.map((o) => o.packed), "0x000000000000000000000000000000000000bEEF"] }) };
        if (warm) { tx.type = "0x1"; tx.accessList = [d.superPaymaster, d.spImpl].map((address) => ({ address, storageKeys: [] })); }
        const latest = await request("eth_getBlockByNumber", ["latest", false]);
        await request("evm_setNextBlockTimestamp", [Number(BigInt(latest.timestamp)) + 1]);
        await request("anvil_setNextBlockBaseFeePerGas", ["0x0"]);
        const hash = await request("eth_sendTransaction", [tx]);
        const rc = await receipt(hash);
        const mined = await request("eth_getTransactionByHash", [hash]);
        assert.equal(BigInt(mined.gas), BigInt(limit)); assert.equal(mined.input, tx.data);
        assert.equal(Number(BigInt(rc.transactionIndex)), 0, "isolated automine transaction reordered");
        return { tx: mined, receipt: rc };
    };
    const state = async (ops) => {
        const opConfig = await read(d.superPaymaster, ABI.sp, "operators", [d.operator]);
        const users = {};
        for (const { packed: { sender }, hash } of ops) users[hash] = {
            balance: await read(d.operatorToken, ABI.token, "balanceOf", [sender]),
            locked: await read(d.operatorToken, ABI.token, "lockedOf", [sender]),
            creditReserved: await read(d.operatorToken, ABI.token, "creditReservedOf", [sender]),
            debt: await read(d.operatorToken, ABI.token, "debts", [sender]),
            used: await read(d.operatorToken, ABI.token, "usedOpHashes", [hash]),
            inflight: await read(d.superPaymaster, ABI.sp, "inflightOf", [hash]),
        };
        return { users, operatorBalance: opConfig[0], protocolRevenue: await read(d.superPaymaster, ABI.sp, "protocolRevenue"),
            epDeposit: await read(EP, ABI.ep, "balanceOf", [d.superPaymaster]),
            executionSlots: await Promise.all([0, 7, 23].map((slot) => request("eth_getStorageAt", [target, toHex(slot), "latest"]))) };
    };
    const snapshotPrice = async () => {
        const [price, , , decimals] = await read(d.superPaymaster, ABI.sp, "cachedPrice");
        return { price, decimals, aPriceUSD: await read(d.superPaymaster, ABI.sp, "aPNTsPriceUSD"),
            feeBps: await read(d.superPaymaster, ABI.sp, "protocolFeeBPS"), exchangeRate: await read(d.operatorToken, ABI.token, "exchangeRate") };
    };
    const events = (rc) => rc.logs.flatMap((lg) => {
        const abi = lg.address.toLowerCase() === d.operatorToken.toLowerCase() ? ABI.token
            : lg.address.toLowerCase() === d.superPaymaster.toLowerCase() ? ABI.sp : null;
        if (!abi) return [];
        try { const ev = decodeEventLog({ abi, data: lg.data, topics: lg.topics }); return [{ address: lg.address, event: ev.eventName, args: ev.args }]; }
        catch { return []; }
    });
    const capture = async (name, mined) => {
        const structLogger = await request("debug_traceTransaction", [mined.receipt.transactionHash,
            { disableMemory: true, enableMemory: false, disableStack: false, disableStorage: true }]);
        const callTracer = await request("debug_traceTransaction", [mined.receipt.transactionHash, { tracer: "callTracer", tracerConfig: { withLog: true } }]);
        writeFileSync(resolve(out, "traces", `${name}.jsonl.gz`), gzipSync(json({ header, name, ...mined, structLogger, callTracer }) + "\n"));
        return traceSummary(structLogger, callTracer, d.superPaymaster, d.spImpl, Number(BigInt(mined.tx.gas)), target);
    };
    const errors = [], comparisons = [], observed = { refund: 0, refill: 0, exhaustion: 0, guardChanges: 0 };
    const selected = cells().filter((c) => c.applicable && c.id.includes(filter));
    assert(selected.length, "no matching cells");
    for (const cell of selected) {
        const base = await request("evm_snapshot");
        try {
            const sender = s.accounts[cell.mode === "credit" ? "b7" : "b1"].address;
            if (cell.history === "subsequent") {
                const prime = await build(sender, MIN + 1);
                const mined = await mine([prime], 2 ** 24, false);
                const ev = epEvents(mined.receipt.logs).find((e) => e.event === "UserOperationEvent");
                assert.equal(ev?.args.success, "true", "history priming failed");
                await capture(`${cell.id}-prime`, mined);
            }
            const code = cell.scenario === "execution-revert" ? freshCode(1, true)
                : cell.scenario === "refill" ? freshCode(8, true)
                : cell.scenario === "refund" ? freshCode(8, false, true)
                : freshCode(cell.scenario === "state-demand" ? 24 : 1);
            const fixtureConfiguration = { target, code, shadow: null, tokenRuntime: null, originalTokenRuntime: null };
            await request("anvil_setCode", [target, code]);
            if (cell.scenario === "refund") for (let i = 0; i < 8; i++) await request("anvil_setStorageAt", [target, toHex(i, { size: 32 }), toHex(1n, { size: 32 })]);
            if (cell.scenario === "postOp-exhaustion") {
                const original = await ctx.pub.getCode({ address: d.operatorToken });
                await request("anvil_setCode", [shadow, original]);
                const wrapper = exhaustionCode(shadow, sender);
                fixtureConfiguration.shadow = shadow;
                fixtureConfiguration.originalTokenRuntime = original;
                fixtureConfiguration.tokenRuntime = wrapper;
                await request("anvil_setCode", [d.operatorToken, wrapper]);
            }
            const targetOp = await build(sender, cell.postGas, target);
            const companions = cell.position === "1of1" ? [] : await Promise.all(["b3a", "b3b"].map((k) => build(s.accounts[k].address, MIN + 1)));
            const ops = cell.position === "3of3" ? [...companions, targetOp] : [targetOp, ...companions];
            const targetIndex = ops.indexOf(targetOp);
            const price = await snapshotPrice();
            const rows = [];
            for (const regime of regimes(Number(deltaArg))) {
                const snap = await request("evm_snapshot");
                try {
                    const before = await state(ops), mined = await mine(ops, regime.gas, cell.warmth === "warm");
                    const trace = await capture(`${cell.id}-${regime.id}`, mined), after = await state(ops);
                    const evs = events(mined.receipt), ep = epEvents(mined.receipt.logs);
                    let failedOp = null;
                    if (mined.receipt.status === "0x0") {
                        try { const e = decodeErrorResult({ abi: ABI.ep, data: trace.topOutput }); failedOp = { name: e.errorName, args: e.args }; }
                        catch { failedOp = { name: "undecoded", output: trace.topOutput, error: trace.topError }; }
                    }
                    const cleanup = [];
                    for (const op of ops) {
                        const u = after.users[op.hash];
                        if (u.locked > 0n) cleanup.push((await send(ctx, d.operatorToken, ABI.token, "releaseStaleLock", [op.packed.sender, op.hash])).transactionHash);
                        if (u.creditReserved > 0n) cleanup.push((await send(ctx, d.operatorToken, ABI.token, "releaseStaleCredit", [op.packed.sender, op.hash])).transactionHash);
                        if (u.inflight[1] > 0n) cleanup.push((await send(ctx, d.superPaymaster, ABI.sp, "releaseStaleSponsorship", [op.hash])).transactionHash);
                    }
                    const released = await state(ops);
                    const perOp = ops.map((op, index) => {
                        const sameHash = (e) => (e.args.opHash ?? e.args.userOpHash)?.toLowerCase() === op.hash.toLowerCase();
                        const own = evs.filter(sameHash), ownEP = ep.filter(sameHash);
                        const uoe = ownEP.find((e) => e.event === "UserOperationEvent");
                        const settle = own.filter((e) => ["LockSettled", "CreditSettled"].includes(e.event));
                        const tokenCharge = settle.reduce((sum, e) => sum + (e.args.aCharged ?? e.args.debtAdded), 0n);
                        const sponsored = evs.filter((e) => e.event === "TransactionSponsored" && e.args.user?.toLowerCase() === op.packed.sender.toLowerCase());
                        const spCharge = sponsored.reduce((sum, e) => sum + e.args.debtAPNTs, 0n);
                        const kept = index === targetIndex ? BigInt(after.executionSlots[0]) !== BigInt(before.executionSlots[0]) : false;
                        const settled = settle.length === 1 && after.users[op.hash].used;
                        const reserved = own.some((e) => ["LockCreated", "CreditReserved"].includes(e.event));
                        const postReverted = ownEP.some((e) => e.event === "PostOpRevertReason");
                        const balanceBurn = before.users[op.hash].balance - after.users[op.hash].balance;
                        const debtAdded = after.users[op.hash].debt - before.users[op.hash].debt;
                        const burned = settle.reduce((sum, e) => sum + (e.args.xBurned ?? 0n), 0n);
                        const debtEvent = settle.reduce((sum, e) => sum + (e.args.debtAdded ?? 0n), 0n);
                        const unbacked = spCharge !== tokenCharge || ((kept || sponsored.length > 0) && !settled)
                            || sponsored.length > 1 || settle.length > 1 || balanceBurn !== burned || debtAdded !== debtEvent
                            || (settled && sponsored.length !== 1) || (!!uoe && !settled && !postReverted);
                        const outstanding = released.users[op.hash].inflight[1] !== 0n || released.users[op.hash].locked !== 0n
                            || released.users[op.hash].creditReserved !== 0n;
                        // Proxy frame order is the order EP calls postOp (one first attempt per op).
                        const postFrames = trace.frames.filter((f) => f.to.toLowerCase() === d.superPaymaster.toLowerCase() && f.selector === SELECTOR.postOp);
                        const pf = postFrames[index];
                        let contextBytes = null, contextSnapshot = null;
                        if (pf) {
                            const [, context] = decodeAbiParameters(parseAbiParameters("uint8, bytes, uint256, uint256"), "0x" + pf.input.slice(10));
                            contextBytes = (context.length - 2) / 2; assert.equal(contextBytes, 384);
                            const words = Array.from({ length: 12 }, (_, i) => BigInt("0x" + context.slice(2 + i * 64, 2 + (i + 1) * 64)));
                            const gs = words[11], mask = (1n << 32n) - 1n;
                            // Fee snapshot occupies all bits above the 128-bit GasParams slot.
                            contextSnapshot = { a0: words[2], mode: words[5], callGas: words[6], postGas: words[7],
                                price: words[8], decimals: words[9], aPriceUSD: words[10], minPost: gs & mask,
                                settle: (gs >> 32n) & mask, cWrap: (gs >> 64n) & mask, cPostop: (gs >> 96n) & mask,
                                feeBps: (gs >> 128n) - 1n };
                            assert.equal(contextSnapshot.price, BigInt(price.price));
                            assert.equal(contextSnapshot.decimals, BigInt(price.decimals));
                            assert.equal(contextSnapshot.aPriceUSD, price.aPriceUSD);
                            assert.equal(contextSnapshot.feeBps, price.feeBps);
                            assert.equal(contextSnapshot.settle, 420000n);
                            assert.equal(contextSnapshot.mode, cell.mode === "credit" && index === targetIndex ? 2n : 1n);
                        }
                        const implementationFrames = trace.frames.filter((f) => f.to.toLowerCase() === d.spImpl.toLowerCase() && f.selector === SELECTOR.postOp);
                        const implFrame = implementationFrames[index];
                        const guard = pf ? pf.output.startsWith(SELECTOR.guardError) ? "fail" : implFrame?.firstGasOpcode && implFrame.firstGasOpcode.gasleftReturned >= 420000 ? "pass" : "undetermined" : "not-reached";
                        const gasCost = uoe ? BigInt(uoe.args.actualGasCost) : null;
                        const netOfFeeChargeWei = (spCharge * 10000n / (10000n + price.feeBps))
                            * 10n ** BigInt(price.decimals) * price.aPriceUSD / (BigInt(price.price) * 10n ** 18n);
                        return { hash: op.hash, sender: op.packed.sender, index: index + 1, target: index === targetIndex,
                            actualGasCost: gasCost, actualGasUsed: uoe?.args.actualGasUsed ?? null, success: uoe?.args.success ?? null,
                            reserved, settled, postReverted, contextBytes, contextSnapshot, spCharge, tokenCharge,
                            tokenUnits: burned > 0n ? burned : debtEvent, balanceBurn, debtAdded,
                            ...costs(gasCost, price, spCharge), netOfFeeChargeWei, g2NoSubsidy: settled && gasCost !== null ? netOfFeeChargeWei >= gasCost : null,
                            I9: { unbackedCount: unbacked ? 1 : 0, pass: !unbacked && !outstanding, outstandingAfterRelease: outstanding, reservedWithoutSettlement: reserved && !settled, executionKept: kept },
                            postOpEntry: pf?.entry ?? null, postOpImplementationEntry: implFrame?.entry ?? null,
                            gasleftAtFirstGuardGAS: implFrame?.firstGasOpcode ?? null, guard,
                            validationEntry: trace.frames.filter((f) => f.to.toLowerCase() === d.superPaymaster.toLowerCase() && f.selector === SELECTOR.validate)[index]?.entry ?? null,
                            reservationAfter: after.users[op.hash], reservationAfterRelease: released.users[op.hash] };
                    });
                    const charges = perOp.reduce((sum, op) => sum + op.spCharge, 0n);
                    const epCost = perOp.reduce((sum, op) => sum + (op.actualGasCost ?? 0n), 0n);
                    const accounting = { operatorRestoredNetOfCharges: before.operatorBalance - released.operatorBalance === charges,
                        revenueEqualsCharges: released.protocolRevenue - before.protocolRevenue === charges,
                        epDepositPaysActualGasCost: before.epDeposit - after.epDeposit === epCost };
                    const focus = perOp[targetIndex];
                    const I10 = !focus.postReverted ? { applicable: false, reason: "target postOp did not revert" } : {
                        applicable: true, pass: focus.spCharge === 0n && focus.tokenCharge === 0n && !focus.I9.executionKept
                            && before.executionSlots.every((v, i) => BigInt(v) === BigInt(released.executionSlots[i]))
                            && before.users[targetOp.hash].balance === released.users[targetOp.hash].balance
                            && before.users[targetOp.hash].debt === released.users[targetOp.hash].debt
                            && released.users[targetOp.hash].inflight[1] === 0n && released.users[targetOp.hash].locked === 0n
                            && released.users[targetOp.hash].creditReserved === 0n && Object.values(accounting).every(Boolean),
                        accounting, definition: "03-final-spec.md §4 I10, R10-M1/R10-M1b; checked after stale release" };
                    const row = { cell, regime, fixtureConfiguration, txGas: regime.gas, receiptGasUsed: BigInt(mined.receipt.gasUsed),
                        failedOp, txHash: mined.receipt.transactionHash, txStatus: mined.receipt.status, priceSnapshot: price,
                        signedOperations: ops.map((op) => op.packed), trace, before, after, released, cleanup,
                        reservoirWitness: regime.id === "R0" ? "R0_ZERO" : trace.drawn ? "DRAWN" : "INITIAL_ONLY",
                        perOp, I9: perOp.every((op) => op.I9.pass), I10, accounting, epEvents: ep, tokenAndSPEvents: evs,
                        requestedOutcomeObserved: cell.postGas < MIN ? mined.receipt.status === "0x0" && failedOp?.name === "FailedOp" && String(failedOp.args[1]).includes("AA34") && !focus.reserved && focus.guard === "not-reached"
                            : cell.scenario === "postOp-exhaustion" ? focus.postReverted
                            : cell.scenario === "refill" ? focus.success === "false" && focus.settled && (regime.id !== "RR30M" || trace.refillObserved)
                            : cell.scenario === "refund" ? trace.refundIncreases.some((x) => x.previousOpcode === "SSTORE" && trace.executionFrames.some((f) => x.index > f.entry.index && x.index <= f.terminal.index))
                            : cell.scenario === "execution-revert" ? focus.success === "false" && focus.settled
                            : cell.scenario === "state-demand" ? mined.receipt.status === "0x1" && focus.actualGasCost !== null && focus.settled : focus.success === "true" && focus.settled };
                    if (trace.refillObserved) observed.refill++;
                    if (trace.terminal.refund > 0) observed.refund++;
                    if (focus.postReverted && cell.scenario === "postOp-exhaustion") observed.exhaustion++;
                    rows.push(row); appendFileSync(resolve(out, "cells.jsonl"), json(row) + "\n");
                    console.log(json({ cell: cell.id, regime: regime.id, status: row.txStatus, guard: focus.guard,
                        I9: row.I9, I10: I10.pass ?? "N/A", observed: row.requestedOutcomeObserved }));
                    if (!row.I9 || I10.pass === false || (row.txStatus === "0x1" && perOp.some((o) => o.actualGasCost === null)) || !Object.values(accounting).every(Boolean)
                        || !row.requestedOutcomeObserved) errors.push(`${cell.id}/${regime.id}: invariant/accounting/outcome failure`);
                } finally { assert(await request("evm_revert", [snap])); }
            }
            const baseline = rows[0].perOp[targetIndex];
            for (const rr of rows.slice(1)) {
                const focus = rr.perOp[targetIndex];
                const guardChanged = baseline.guard !== focus.guard;
                const guardPassFailChanged = guardChanged && [baseline.guard, focus.guard].every((v) => ["pass", "fail"].includes(v));
                const outcomeChanged = baseline.success !== focus.success || baseline.postReverted !== focus.postReverted || rows[0].txStatus !== rr.txStatus;
                if (guardChanged) observed.guardChanges++;
                comparisons.push({ cell: cell.id, regime: rr.regime.id, guardChanged, guardPassFailChanged, outcomeChanged,
                    R0: { guard: baseline.guard, entry: baseline.postOpEntry, success: baseline.success },
                    RR: { guard: focus.guard, entry: focus.postOpEntry, success: focus.success } });
            }
        } finally { assert(await request("evm_revert", [base])); }
    }
    writeFileSync(resolve(out, "comparisons.json"), json(comparisons) + "\n");
    writeFileSync(resolve(out, "summary.json"), json({ header, selectedCells: selected.length, transactions: selected.length * 3,
        skipped: cells().filter((c) => !c.applicable).length, observed, errors, result: errors.length ? "FAIL" : "CAPTURED; review coverage and guard changes" }) + "\n");
    const coverage = ["mode", "context", "warmth", "history", "position", "scenario", "postGas"].map((key) =>
        `| ${key} | ${[...new Set(selected.map((c) => c[key]))].join(", ")} |`).join("\n");
    const changes = comparisons.filter((c) => c.guardChanged || c.outcomeChanged);
    writeFileSync(resolve(out, "REPORT.md"), `# CC-125 Phase 2 capture\n\nEngine: ${header.engineCommit}; repository: ${header.repoCommit}.\n`
        + `Selected definitions: ${selected.length}; measured transactions: ${selected.length * 3}. Errors: ${errors.length}.\n\n`
        + `| DSR dimension | Captured cell values |\n|---|---|\n${coverage}\n\n`
        + `Each ID in definitions.json maps to cells.jsonl and traces/<ID>-<regime>.jsonl.gz. Legacy160 and cold 3of3 are inapplicable (definitions include reasons).\n\n`
        + `I9, I10, charge and bare/fee targets are per-op fields in cells.jsonl. I10 includes stale-release checks. PostOp exhaustion uses the labelled adversarial token fixture.\n\n`
        + `Refund observations: ${observed.refund}; refill observations: ${observed.refill}; exhaustion observations: ${observed.exhaustion}.\n\n`
        + `Guard or outcome changes: ${changes.length}; all comparisons are in comparisons.json.\n\n`
        + `| Cell | RR regime | Guard changed | Guard pass/fail changed | Outcome changed |\n|---|---|---|---|---|\n`
        + changes.map((c) => `| ${c.cell} | ${c.regime} | ${c.guardChanged} | ${c.guardPassFailChanged} | ${c.outcomeChanged} |`).join("\n") + "\n");
    if (errors.length) process.exitCode = 2;
}
