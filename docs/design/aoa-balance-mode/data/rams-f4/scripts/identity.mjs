// R2-F4: artifact identity of the key contracts in a forge `out/` directory.
// For every artifact variant of each requested contract (forge 1.7.1 writes `<Name>.json` and, where
// compilation_restrictions produce a second compile job, `<Name>.<profile>.json`), record:
//   creation / runtime keccak, runtime keccak with immutable ranges zeroed, sizes, immutableReferences,
//   linkReferences (library links), the CBOR metadata tail of the runtime code (decoded), keccak of the
//   rawMetadata JSON, and the compiler settings taken from that metadata.
// Usage: node identity.mjs <outDir> <out.json> File.sol:Name [File.sol:Name ...]
import { readFileSync, readdirSync, existsSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { keccak256 } from "viem";

const [outDir, outJson, ...targets] = process.argv.slice(2);

function maskImmutables(hex, refs) {
    const b = Buffer.from(hex.slice(2), "hex");
    for (const ranges of Object.values(refs ?? {})) for (const { start, length } of ranges) b.fill(0, start, start + length);
    return "0x" + b.toString("hex");
}

// Minimal CBOR decoder for the solc metadata map (text keys, byte-string / text values).
function decodeCbor(buf) {
    let i = 0;
    const readLen = (ai) => {
        if (ai < 24) return ai;
        if (ai === 24) return buf[i++];
        if (ai === 25) { const v = buf.readUInt16BE(i); i += 2; return v; }
        throw new Error("cbor len");
    };
    const item = () => {
        const ib = buf[i++]; const mt = ib >> 5; const ai = ib & 31;
        if (mt === 2) { const n = readLen(ai); const v = "0x" + buf.subarray(i, i + n).toString("hex"); i += n; return v; }
        if (mt === 3) { const n = readLen(ai); const v = buf.subarray(i, i + n).toString("utf8"); i += n; return v; }
        if (mt === 5) { const n = readLen(ai); const o = {}; for (let k = 0; k < n; k++) { const key = item(); o[key] = item(); } return o; }
        if (mt === 7) return ai === 20 ? false : ai === 21 ? true : null;
        throw new Error("cbor type " + mt);
    };
    const v = item();
    if (i !== buf.length) throw new Error("cbor trailing");
    return v;
}

function cborTail(hex) {
    const b = Buffer.from(hex.slice(2), "hex");
    if (b.length < 2) return null;
    const n = b.readUInt16BE(b.length - 2);
    if (n + 2 > b.length) return null;
    const raw = b.subarray(b.length - 2 - n, b.length - 2);
    try {
        const m = decodeCbor(raw);
        if (m && m.solc && typeof m.solc === "string" && m.solc.startsWith("0x"))
            m.solcVersion = [...Buffer.from(m.solc.slice(2), "hex")].join(".");
        return { hex: "0x" + raw.toString("hex"), decoded: m };
    } catch { return { hex: "0x" + raw.toString("hex"), decoded: null }; }
}

function record(path) {
    const a = JSON.parse(readFileSync(path, "utf8"));
    const creation = a.bytecode.object, runtime = a.deployedBytecode.object;
    const imm = a.deployedBytecode.immutableReferences ?? {};
    const meta = a.rawMetadata ? JSON.parse(a.rawMetadata) : a.metadata;
    const s = meta?.settings ?? {};
    return {
        artifact: path.slice(outDir.length + 1),
        creationKeccak: keccak256(creation), creationBytes: (creation.length - 2) / 2,
        runtimeKeccak: keccak256(runtime), runtimeBytes: (runtime.length - 2) / 2,
        runtimeKeccakImmutablesZeroed: keccak256(maskImmutables(runtime, imm)),
        immutableReferences: imm,
        immutableRanges: Object.values(imm).reduce((n, r) => n + r.length, 0),
        linkReferences: { creation: a.bytecode.linkReferences ?? {}, runtime: a.deployedBytecode.linkReferences ?? {} },
        runtimeCborTail: cborTail(runtime),
        rawMetadataKeccak: a.rawMetadata ? keccak256(Buffer.from(a.rawMetadata, "utf8")) : null,
        compiler: meta?.compiler?.version,
        settings: {
            optimizer: s.optimizer, viaIR: s.viaIR, evmVersion: s.evmVersion,
            metadata: s.metadata, compilationTarget: s.compilationTarget, libraries: s.libraries,
        },
    };
}

const out = { outDir, generated: new Date().toISOString(), contracts: [] };
for (const t of targets) {
    const [file, name] = t.split(":");
    const dir = join(outDir, file);
    if (!existsSync(dir)) { out.contracts.push({ target: t, missing: true }); continue; }
    const variants = readdirSync(dir).filter((f) => f === `${name}.json` || (f.startsWith(`${name}.`) && f.endsWith(".json")))
        .filter((f) => f.split(".").length <= 3).sort();
    out.contracts.push({ target: t, variants: variants.map((f) => record(join(dir, f))) });
}
writeFileSync(outJson, JSON.stringify(out, null, 1) + "\n");
for (const c of out.contracts) {
    if (c.missing) { console.log(`${c.target} MISSING`); continue; }
    for (const v of c.variants)
        console.log(`${c.target} ${v.artifact} runs=${v.settings.optimizer?.runs} evm=${v.settings.evmVersion} rt=${v.runtimeBytes} ${v.runtimeKeccak} masked=${v.runtimeKeccakImmutablesZeroed.slice(0, 18)} cr=${v.creationKeccak.slice(0, 18)}`);
}
