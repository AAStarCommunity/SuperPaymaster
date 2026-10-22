// R-AMS-2: does the transaction gas limit change what an op "needs" on an Amsterdam chain?
// EIP-8037: gas above the EIP-7825 per-tx cap (16,777,216) goes into a state-gas reservoir that pays
// state gas (new slots, new accounts, code bytes) before the frame's regular gas. A simulation run with
// a large eth_call gas (Alto's estimator sends none, so the node uses the block gas limit) can then
// succeed with per-frame limits that fail inside a real bundle (tx gas below the cap → no reservoir).
// For the given cases this runs the same minimum-need search (ams-probe.mjs needs()) at several tx
// gas values (and at several gas prices, see the second sweep) and writes the table. Local anvil only; read-only (debug_traceCall).
// Usage: node script/b-layer/ams-reservoir.mjs <setupJson> <outJson> [case...]
import { readFileSync, writeFileSync } from "node:fs";
import { clients, ANVIL_KEYS } from "./lib.mjs";
import { needs } from "./ams-probe.mjs";
import { FLAG_SP_RENEW } from "./g1-lib.mjs";

const [setupJson, outJson, ...names] = process.argv.slice(2);
const s = JSON.parse(readFileSync(setupJson, "utf8"));
if (!/^http:\/\/(127\.0\.0\.1|localhost):/.test(s.rpcUrl)) throw new Error("local node only");
const ctx = clients(s.rpcUrl, ANVIL_KEYS[0]);
const CASES = { b1: {}, b5: { flags: FLAG_SP_RENEW }, b7: {} };
const out = { rpcUrl: s.rpcUrl, rows: [] };
for (const n of names.length ? names : Object.keys(CASES)) {
    for (const txGas of [8_000_000, 16_000_000, 16_777_216, 17_000_000, 20_000_000, 30_000_000, 60_000_000]) {
        const r = await needs({ ctx, d: s.deploy, rpcUrl: s.rpcUrl, txGas,
            params: { sender: s.accounts[n].address, ownerKey: ANVIL_KEYS[s.ownerKeyIndex], ...CASES[n] } });
        out.rows.push({ case: n, sweep: "txGas", ...r });
        console.log(`${n} txGas=${txGas}: baseline ${r.generousBaseline.brief} | needs v=${r.verificationGasLimit} c=${r.callGasLimit} pmV=${r.pmVerificationGasLimit} pmP=${r.pmPostOpGasLimit} | baseline txGasUsed=${r.generousBaseline.txGasUsed}`);
    }
}
// Second sweep: the op's maxFeePerGas = maxPriorityFeePerGas (tx gas 16M). Alto's estimator simulates
// with 1 wei (eth_estimateUserOperationGas.ts: simulationUserOp.maxFeePerGas = 1n); SP's validation
// writes depend on the amounts it locks, so the price can change which slots go zero→nonzero.
for (const n of names.length ? names : Object.keys(CASES)) {
    for (const fee of [1n, 1_000n, 1_000_000n, 100_000_000n, 1_000_000_000n, 3_000_000_000n]) {
        const r = await needs({ ctx, d: s.deploy, rpcUrl: s.rpcUrl, fee,
            params: { sender: s.accounts[n].address, ownerKey: ANVIL_KEYS[s.ownerKeyIndex], ...CASES[n] } });
        out.rows.push({ case: n, sweep: "fee", ...r });
        console.log(`${n} fee=${fee}: baseline ${r.generousBaseline.brief} | needs v=${r.verificationGasLimit} c=${r.callGasLimit} pmV=${r.pmVerificationGasLimit} pmP=${r.pmPostOpGasLimit} | pm frame gasUsed=${r.generousBaseline.frames?.validatePaymasterUserOp?.gasUsed}`);
    }
}
writeFileSync(outJson, JSON.stringify(out, null, 2));
