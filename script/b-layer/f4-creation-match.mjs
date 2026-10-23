// R2-F4: match the init code of every CREATE in a forge broadcast file against the creation bytecode of the
// artifact variants in an identity.json (input = creation code ‖ ABI-encoded constructor args).
// Usage: node f4-creation-match.mjs <broadcast run-latest.json> <identity.json> <out.json>
import { readFileSync, writeFileSync } from "node:fs";
import { keccak256 } from "viem";
const [bPath, idPath, outPath] = process.argv.slice(2);
const b = JSON.parse(readFileSync(bPath, "utf8"));
const id = JSON.parse(readFileSync(idPath, "utf8"));
const vs = id.contracts.flatMap((c) => (c.variants ?? []).map((v) => ({ artifact: v.artifact,
    creation: JSON.parse(readFileSync(`${id.outDir}/${v.artifact}`, "utf8")).bytecode.object.toLowerCase() })));
const rows = [];
b.transactions.forEach((t, i) => {
    if (t.transactionType !== "CREATE") return;
    const input = (t.transaction.input ?? t.transaction.data).toLowerCase();
    const hits = vs.filter((v) => input.startsWith(v.creation)).sort((x, y) => y.creation.length - x.creation.length);
    const h = hits[0];
    rows.push({ i, hash: t.hash, forgeName: t.contractName, address: t.contractAddress, inputBytes: (input.length - 2) / 2, inputKeccak: keccak256(input),
        creationArtifact: h?.artifact ?? null, constructorArgs: h ? "0x" + input.slice(h.creation.length) : null });
});
writeFileSync(outPath, JSON.stringify({ broadcast: bPath, identity: idPath, rows }, null, 1) + "\n");
for (const r of rows) console.log(`#${String(r.i).padStart(2)} ${String(r.forgeName).padEnd(28)} ${r.address} ${String(r.inputBytes).padStart(6)}B ${r.creationArtifact ?? "NO MATCH (not in identity list)"}`);
