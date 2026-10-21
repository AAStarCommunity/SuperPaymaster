// F1 — validation-time storage access pattern of the TokenPaymaster control (our tracer), decoded
// generically: slot = keccak(key ‖ base) + n resolved through the recorded KECCAK256 preimages;
// OZ v5.0.2 ERC20 (non-upgradeable) layout: _balances = slot 0, _allowances = slot 1.
// For every access: which validation phase, which contract, and which entity the slot is
// associated with (ERC-7562: slot == keccak(A ‖ x) + n  ⇒ associated with A).
// Usage: node script/b-layer/f1-analyze.mjs <f1SetupJson> <outJson> <label-regex> <traces.jsonl>...
import { readFileSync, writeFileSync } from "node:fs";
import { keccak256 } from "viem";

const [setupJson, outJson, labelRe, ...files] = process.argv.slice(2);
const S = JSON.parse(readFileSync(setupJson, "utf8"));
const low = (x) => x.toLowerCase();
const NAMES = { [low(S.f1.tokenPaymaster)]: "TokenPaymaster", [low(S.f1.tpmToken)]: "F1TestToken", [low(S.f1.tpmOracle)]: "F1Oracle",
    "0x0000000071727de22e5e9d8baf0edac6f37da032": "EntryPoint" };
for (const [n, a] of Object.entries(S.f1.tpmAccounts)) NAMES[low(a.address)] = `acct:${n}`;
const ERC20 = { 0n: "_balances", 1n: "_allowances", 2n: "_totalSupply" };
const out = {};
for (const f of files) {
    const lines = readFileSync(f, "utf8").trim().split("\n").map((l) => JSON.parse(l)).filter((l) => new RegExp(labelRe).test(l.label) && l.ourTrace);
    out[f.split("/").pop()] = lines.map((l) => {
        const t = l.ourTrace;
        const pre = new Map(t.kec.map((k) => [low(keccak256(k)), low(k)]));
        const frames = new Map(t.frames.map((x) => [x.id, x]));
        const acctPhases = t.phases.filter((p) => p.sel === "0x19822f7c");
        const sender = acctPhases.length ? acctPhases[acctPhases.length - 1].target : null;
        const start = t.phases.findLastIndex((p) => p.sel === "0x19822f7c");
        const kind = (p) => (p.sel === "0x19822f7c" ? "account" : p.sel === "0x52b7512c" ? "paymaster" : p.sel === "0x570e1a36" ? "factory" : "other");
        const name = (a) => NAMES[a] ?? (a === sender ? "sender" : a);
        const decode = (addr, slot, depth = 0) => {
            const s = BigInt(slot);
            if (s < 1n << 16n) return { v: (addr === low(S.f1.tpmToken) ? ERC20[s] : null) ?? `slot${s}`, keys: [] };
            if (depth > 3) return null;
            for (let n = 0n; n < 4n; n++) {
                const p = pre.get("0x" + (s - n).toString(16).padStart(64, "0"));
                if (!p || p.length !== 130) continue;
                const key = "0x" + p.slice(26, 66), base = "0x" + p.slice(66);
                const inner = decode(addr, base, depth + 1);
                if (!inner) continue;
                return { v: `${inner.v}[${name(key)}]${n ? `+${n}` : ""}`, keys: [...inner.keys, key] };
            }
            return null;
        };
        const rows = new Map();
        for (const a of t.acc) {
            const fr = frames.get(a.f);
            if (!fr || fr.phase < start || fr.phase < 0) continue;
            const ph = kind(t.phases[fr.phase]);
            if (a.a === "0x0000000071727de22e5e9d8baf0edac6f37da032") continue;
            const d = decode(a.a, a.s) ?? { v: `?${a.s}`, keys: [] };
            const assoc = d.keys.length ? name(d.keys[d.keys.length - 1]) /* ERC-7562: first word of the FINAL preimage = the last mapping key */ : (a.a === sender ? "sender (own storage)" : `${name(a.a)} (own storage)`);
            const k = `${ph}${name(a.a)}${a.op}${d.v}${assoc}`;
            rows.set(k, (rows.get(k) ?? 0) + 1);
        }
        return { label: l.label, sender: name(sender),
            accesses: [...rows.entries()].map(([k, n]) => { const [phase, contract, op, v, associatedWith] = k.split(""); return { phase, contract, op, var: v, associatedWith, n }; }),
            bannedOps: t.ops.filter((o) => (frames.get(o.f)?.phase ?? -1) >= start).map((o) => ({ op: o.op, ctx: name(frames.get(o.f).ctx) })) };
    });
}
writeFileSync(outJson, JSON.stringify(out, null, 2));
const first = Object.values(out)[0]?.[0];
if (first) for (const r of first.accesses) console.log(`${r.phase.padEnd(9)} ${r.contract.padEnd(15)} ${r.op.padEnd(6)} ${r.var.padEnd(44)} assoc=${r.associatedWith} x${r.n}`);
