// R2-F4: which bytecode does the B-layer stack actually execute?
// Reads eth_getCode for every address of a (re-)deployed B-layer stack (deploy.json + setup.json) and
// matches it against the artifact variants recorded by docs/.../rams-f4/scripts/identity.mjs:
// for each candidate artifact, the on-chain code with that artifact's immutable ranges zeroed must equal
// the artifact's runtime with the same ranges zeroed (and have the same length). ERC1967 proxies are
// followed to their implementation slot; EIP-1167 clones are decoded to their implementation.
// Local node only. Usage: node f4-identity-onchain.mjs <rpc> <deploy.json> <setup.json> <identity.json> <out.json>
import { readFileSync, writeFileSync } from "node:fs";
import { keccak256 } from "viem";

const [rpc, deployPath, setupPath, identityPath, outPath] = process.argv.slice(2);
if (!/^http:\/\/(127\.0\.0\.1|localhost):/.test(rpc)) throw new Error("local node only");
const deploy = JSON.parse(readFileSync(deployPath, "utf8"));
const setup = JSON.parse(readFileSync(setupPath, "utf8"));
const identity = JSON.parse(readFileSync(identityPath, "utf8"));
const IMPL_SLOT = "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc";

let id = 0;
async function call(method, params) {
    const r = await fetch(rpc, { method: "POST", headers: { "content-type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", id: ++id, method, params }) });
    const j = await r.json();
    if (j.error) throw new Error(`${method}: ${JSON.stringify(j.error)}`);
    return j.result;
}

const variants = identity.contracts.flatMap((c) => (c.variants ?? []).map((v) => ({ target: c.target, ...v, runtime: null })));
// the artifact runtime itself is needed for masking; reload it from the out dir recorded in identity.json
for (const v of variants) {
    const a = JSON.parse(readFileSync(`${identity.outDir}/${v.artifact}`, "utf8"));
    v.runtime = a.deployedBytecode.object.toLowerCase();
}
function mask(hex, refs) {
    const b = Buffer.from(hex.slice(2), "hex");
    const vals = [];
    for (const ranges of Object.values(refs ?? {})) for (const { start, length } of ranges) {
        vals.push({ start, length, value: "0x" + b.subarray(start, start + length).toString("hex") });
        b.fill(0, start, start + length);
    }
    return { masked: "0x" + b.toString("hex"), vals };
}
function match(code) {
    const hits = [];
    for (const v of variants) {
        if (v.runtime.length !== code.length) continue;
        const a = mask(v.runtime, v.immutableReferences).masked;
        const { masked, vals } = mask(code, v.immutableReferences);
        if (a === masked) hits.push({ target: v.target, artifact: v.artifact, exactRuntimeEqual: v.runtime === code,
            immutables: vals.map((x) => ({ start: x.start, length: x.length, value: x.value })) });
    }
    return hits;
}

const addrs = [];
for (const [k, v] of Object.entries(deploy)) if (/^0x[0-9a-fA-F]{40}$/.test(v)) addrs.push([`deploy.${k}`, v]);
for (const [k, f] of Object.entries(setup.factories ?? {})) addrs.push([`factories.${k}`, f.address]);
for (const [k, a] of Object.entries(setup.accounts ?? {})) addrs.push([`accounts.${k}`, a.address]);

const rows = [];
for (const [label, addr] of addrs) {
    const code = (await call("eth_getCode", [addr, "latest"])).toLowerCase();
    const row = { label, address: addr, codeBytes: (code.length - 2) / 2, codeKeccak: code === "0x" ? null : keccak256(code) };
    if (code === "0x") { row.note = "no code (EOA or not deployed yet)"; rows.push(row); continue; }
    if (label === "deploy.entryPoint") row.canonicalEntryPointV07 =
        row.codeKeccak === "0x8db5ff695839d655407cc8490bb7a5d82337a86a6b39c3f0258aa6c3b582fc58";
    const m = /^0x363d3d373d3d3d363d73([0-9a-f]{40})5af43d82803e903d91602b57fd5bf3$/.exec(code);
    if (m) row.eip1167CloneOf = "0x" + m[1];
    row.matches = match(code);
    const slot = await call("eth_getStorageAt", [addr, IMPL_SLOT, "latest"]);
    if (BigInt(slot) !== 0n) {
        const impl = "0x" + slot.slice(-40);
        const icode = (await call("eth_getCode", [impl, "latest"])).toLowerCase();
        row.erc1967Implementation = { address: impl, codeBytes: (icode.length - 2) / 2, codeKeccak: keccak256(icode), matches: match(icode) };
    }
    rows.push(row);
}
writeFileSync(outPath, JSON.stringify({ rpc, deployPath, setupPath, identityPath, rows }, null, 1) + "\n");
for (const r of rows) {
    const m = (r.matches ?? []).map((h) => `${h.artifact}${h.exactRuntimeEqual ? "(=)" : "(masked=)"}`).join(",") || (r.eip1167CloneOf ? `clone→${r.eip1167CloneOf}` : "-");
    const i = r.erc1967Implementation ? ` impl ${r.erc1967Implementation.address} → ${r.erc1967Implementation.matches.map((h) => h.artifact).join(",") || "NO MATCH"}` : "";
    console.log(`${r.label.padEnd(28)} ${r.address} ${String(r.codeBytes).padStart(6)}B ${m}${i}${r.canonicalEntryPointV07 !== undefined ? " canonicalEP=" + r.canonicalEntryPointV07 : ""}`);
}
