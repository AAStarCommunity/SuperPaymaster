// R2-F4: match runtime code dumped by the instrumented G fixture (f4dump/<name>.hex) against every artifact
// variant in an identity.json (immutable ranges of the candidate zeroed on both sides, equal length).
// Usage: node match_dump.mjs <dumpDir> <identity.json> <out.json>
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { keccak256 } from "viem";

const [dumpDir, identityPath, outPath] = process.argv.slice(2);
const identity = JSON.parse(readFileSync(identityPath, "utf8"));
const variants = identity.contracts.flatMap((c) => (c.variants ?? []).map((v) => ({ target: c.target, ...v,
    runtime: JSON.parse(readFileSync(`${identity.outDir}/${v.artifact}`, "utf8")).deployedBytecode.object.toLowerCase() })));
const mask = (hex, refs) => { const b = Buffer.from(hex.slice(2), "hex");
    for (const r of Object.values(refs ?? {})) for (const { start, length } of r) b.fill(0, start, start + length); return "0x" + b.toString("hex"); };
const addrs = Object.fromEntries(readFileSync(`${dumpDir}/addresses.txt`, "utf8").trim().split("\n").map((l) => l.split(" ")));
const rows = [];
for (const f of readdirSync(dumpDir).filter((f) => f.endsWith(".hex")).sort()) {
    const name = f.slice(0, -4);
    const code = readFileSync(`${dumpDir}/${f}`, "utf8").trim().toLowerCase();
    const m = /^0x363d3d373d3d3d363d73([0-9a-f]{40})5af43d82803e903d91602b57fd5bf3$/.exec(code);
    const hits = variants.filter((v) => v.runtime.length === code.length && mask(v.runtime, v.immutableReferences) === mask(code, v.immutableReferences))
        .map((v) => v.artifact);
    rows.push({ name, address: addrs[name], codeBytes: (code.length - 2) / 2, codeKeccak: keccak256(code), eip1167CloneOf: m ? "0x" + m[1] : undefined, matches: hits });
    console.log(`${name.padEnd(26)} ${String((code.length - 2) / 2).padStart(6)}B ${hits.join(", ") || (m ? "EIP-1167 clone of 0x" + m[1] : "NO MATCH")}`);
}
writeFileSync(outPath, JSON.stringify({ dumpDir, identityPath, rows }, null, 1) + "\n");
