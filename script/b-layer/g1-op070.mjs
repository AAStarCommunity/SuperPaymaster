// D5 gate G1 / B8 — how each bundler's OWN tracer records the validation-time TSTOREs (OP-070).
// For every B8 simulation: take the TSTORE slots our tracer saw (token live marker, SP in-flight
// marker) and look them up in the bundler tracer's per-entity `access[address].writes` map.
// Usage: node script/b-layer/g1-op070.mjs <setupJson> <outJson> <label=traces.jsonl>...
import { readFileSync, writeFileSync } from "node:fs";

const [setupJson, outJson, ...pairs] = process.argv.slice(2);
const S = JSON.parse(readFileSync(setupJson, "utf8"));
const TOKEN = S.deploy.operatorToken.toLowerCase(), SP = S.deploy.superPaymaster.toLowerCase();
const out = {};
for (const pair of pairs) {
    const [label, file] = pair.split("=");
    const lines = readFileSync(file, "utf8").trim().split("\n").map((l) => JSON.parse(l)).filter((l) => l.label === "B8");
    out[label] = lines.map((l) => {
        const ts = l.ourTrace.acc.filter((a) => a.op === "TSTORE" && (a.a === TOKEN || a.a === SP));
        const levels = l.bundlerTrace?.callsFromEntryPoint ?? [];
        const pm = levels.filter((c) => c.topLevelMethodSig === "0x52b7512c").pop();
        return ts.map((a) => {
            const acc = pm?.access?.[a.a] ?? {};
            return { address: a.a === TOKEN ? "token" : "SP", slot: a.s,
                inBundlerWrites: Object.prototype.hasOwnProperty.call(acc.writes ?? {}, a.s),
                bundlerWriteCount: acc.writes?.[a.s] ?? null, inBundlerReads: Object.prototype.hasOwnProperty.call(acc.reads ?? {}, a.s) };
        });
    });
}
writeFileSync(outJson, JSON.stringify(out, null, 2));
console.log(JSON.stringify(out));
