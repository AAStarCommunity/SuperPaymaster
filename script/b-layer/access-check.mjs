// D5 gate G1 §3.4 — line-by-line check of every validation-time storage access against the
// 03-final-spec §2.3 "验证期访问清单" table, from the traces captured by g1-proxy.mjs (our tracer).
//
// Slot → name: storage layouts from `forge inspect <C> storageLayout --json` (saved under
// cases/layouts/) + the KECCAK256 preimages the tracer recorded: slot = keccak(key ‖ base) + n
// is resolved recursively (nested mappings), keccak(p) + i as dynamic-array element, and the
// transient live markers keccak(user ‖ keccak(opHash ‖ SEED)) via the known SEED constants.
//
// Rows (spec §2.3):
//   R1  SP frame, token global READ (STO-033):  SUPERPAYMASTER_ADDRESS, historicalSP[SP], emergencyDisabled,
//       exchangeRate, maxSingleTxLimit, creditPolicy, policyEpoch, creditTierSource, community;
//       Registry creditTierConfig
//   R2  SP frame, token user-keyed READ/WRITE (STO-021): lockedOf[u], _auto[SP][u], _budget[u], autoRenewUsed[u],
//       _locks[h][u], creditReservedOf[u], _creditRes[h][u]; READ-ONLY renewalMode[u], spenderDisabled[SP][u],
//       creditReq[u], _balances[u], debts[u]; Registry globalReputation[u]
//   R3  SP frame TSTORE/TLOAD: live marker (token keccak(u‖keccak(h‖SEED)); SP in-flight keccak(h‖SEED))
//   R4  account frame (unstaked) via renewForSelf: ONLY lockedOf[me], creditReservedOf[me], _auto[sp][me],
//       _budget[me], autoRenewUsed[me], renewalMode[me]; NO global slot
//   R5  forbidden in every frame: _reentrancyStatus, usedOpHashes, spenderRateLimit, any total* counter;
//       TIMESTAMP, NUMBER, ORIGIN
// Acceptance: token accesses outside R1–R4 = 0, R5 hits = 0.
//
// Usage: node script/b-layer/access-check.mjs <setupJson> <outJson> <traces.jsonl>... [--control]
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { keccak256, toHex, pad, encodeAbiParameters } from "viem";
import { ROOT, EP, SENDER_CREATOR } from "./lib.mjs";

const args = process.argv.slice(2);
const control = args.includes("--control");
const [setupJson, outJson, ...traceFiles] = args.filter((a) => a !== "--control");
const S = JSON.parse(readFileSync(setupJson, "utf8"));
const D = S.deploy;
const LAYOUT_DIR = resolve(ROOT, "docs/design/aoa-balance-mode/b-layer/cases/layouts");
const low = (a) => a.toLowerCase();
const TOKEN = low(D.operatorToken), SP = low(D.superPaymaster), REG = low(D.registry), EPL = low(EP);

// ---------------------------------------------------------------- layouts
function layout(name) {
    const j = JSON.parse(readFileSync(resolve(LAYOUT_DIR, `${name}.json`), "utf8"));
    const bySlot = new Map();
    for (const s of j.storage) {
        const k = BigInt(s.slot);
        if (!bySlot.has(k)) bySlot.set(k, []);
        bySlot.get(k).push(s.label);
    }
    return bySlot;
}
const LAYOUTS = { [TOKEN]: layout("xPNTsTokenV2"), [SP]: layout("SuperPaymaster"), [REG]: layout("Registry") };
const NAMED = {
    "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc": "ERC1967.implementation",
    "0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00": "OZ.Initializable",
    "0x9016d09d72d40fdae2fd8ceac6b6234c7706214fd39c1cd1e609a0528c199300": "OZ.Ownable",
    "0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00": "OZ.ReentrancyGuard",
};
const SEEDS = {
    [keccak256(toHex("xPNTs.v2.lock.live"))]: "LOCK_SEED",
    [keccak256(toHex("xPNTs.v2.credit.live"))]: "CREDIT_SEED",
    [keccak256(toHex("SP.v5.5.inflight.live"))]: "INFLIGHT_SEED",
};

// ---------------------------------------------------------------- names for keys
const ADDR_NAMES = { [SP]: "SP", [TOKEN]: "token", [REG]: "Registry", [EPL]: "EntryPoint", [low(D.operator)]: "operator" };
for (const [n, a] of Object.entries(S.accounts)) ADDR_NAMES[low(a.address)] = `acct:${n}`;
for (const [n, a] of Object.entries(S.b4)) ADDR_NAMES[low(a.address)] = `acct:b4-${n}`;
const FACTORIES = new Set(Object.values(S.factories).map((f) => low(f.address)));
for (const [n, f] of Object.entries(S.factories)) ADDR_NAMES[low(f.address)] = `factory:${n}`;

function keyName(word, ctx) {
    const w = low(word);
    if (BigInt(w) < 1n << 16n) return BigInt(w).toString();
    if (/^0x0{24}[0-9a-f]{40}$/.test(w)) {
        const a = "0x" + w.slice(26);
        if (ctx.sender && a === ctx.sender) return "u";
        return ADDR_NAMES[a] ?? a;
    }
    if (ctx.opHashes?.has(w)) return "h";
    return w.slice(0, 10) + "…";
}

// ---------------------------------------------------------------- slot decoding
function makeDecoder(kecInputs) {
    const pre = new Map();
    for (const inp of kecInputs) pre.set(low(keccak256(inp)), low(inp));
    function decode(addr, slotHex, ctx, depth = 0) {
        const slot = BigInt(slotHex);
        const L = LAYOUTS[addr];
        if (slot < 1n << 16n) return { name: L?.get(slot)?.join("/") ?? `slot${slot}`, base: L?.get(slot) ?? [], keys: [], off: 0n };
        const hx = pad(toHex(slot), { size: 32 });
        if (NAMED[hx]) return { name: NAMED[hx], base: [NAMED[hx]], keys: [], off: 0n };
        if (SEEDS[hx]) return { name: SEEDS[hx], base: [SEEDS[hx]], keys: [], off: 0n };
        if (depth > 4) return null;
        for (let n = 0n; n < 64n; n++) {
            const h = pad(toHex(slot - n), { size: 32 });
            const p = pre.get(low(h));
            if (!p) continue;
            if (p.length === 2 + 64) { // keccak(p) — dynamic array data
                const b = BigInt(p);
                const nm = L?.get(b)?.join("/") ?? `slot${b}`;
                return { name: `${nm}[${n}]`, base: L?.get(b) ?? [], keys: [n.toString()], off: 0n, array: true };
            }
            if (p.length === 2 + 128) {
                const key = "0x" + p.slice(2, 66), baseWord = "0x" + p.slice(66);
                const inner = decode(addr, baseWord, ctx, depth + 1);
                if (!inner) continue;
                return { name: `${inner.name}[${keyName(key, ctx)}]${n ? `+${n}` : ""}`, base: inner.base,
                    keys: [...inner.keys, key], off: n };
            }
        }
        return null;
    }
    return decode;
}

// ---------------------------------------------------------------- classification
const TOKEN_R1 = new Set(["SUPERPAYMASTER_ADDRESS", "historicalSP", "emergencyDisabled", "exchangeRate", "maxSingleTxLimit",
    "creditPolicy", "policyEpoch", "creditTierSource", "community"]);
const TOKEN_R2_RW = new Set(["lockedOf", "_auto", "_budget", "autoRenewUsed", "_locks", "creditReservedOf", "_creditRes"]);
const TOKEN_R2_RO = new Set(["renewalMode", "spenderDisabled", "creditReq", "_balances", "debts"]);
const TOKEN_R4 = new Set(["lockedOf", "creditReservedOf", "_auto", "_budget", "autoRenewUsed", "renewalMode"]);
const FORBIDDEN_VARS = (b) => b.some((x) => x === "_reentrancyStatus" || x === "usedOpHashes" || x === "spenderRateLimit" || /^_?total/i.test(x));
const FORBIDDEN_OPS = new Set(["TIMESTAMP", "NUMBER", "ORIGIN"]);
const OTHER_BANNED = new Set(["GASPRICE", "BLOCKHASH", "COINBASE", "DIFFICULTY", "PREVRANDAO", "BASEFEE", "GASLIMIT",
    "SELFBALANCE", "BALANCE", "BLOBHASH", "BLOBBASEFEE", "SELFDESTRUCT", "INVALID", "CREATE", "CREATE2", "GAS"]);

function senderKeyOk(d, ctx, spAsFirst) {
    // the innermost (last) mapping key must be the sender; for _auto/spenderDisabled the outer key is the SP
    if (!d.keys.length) return false;
    const last = low(d.keys[d.keys.length - 1]);
    if (last !== low(pad(ctx.sender, { size: 32 }))) return false;
    if (spAsFirst) return low(d.keys[0]) === low(pad(SP, { size: 32 }));
    return true;
}

function classify(entry, { sender, opHashes, phaseFilter }) {
    const t = entry.ourTrace;
    const decode = makeDecoder(t.kec);
    const frames = new Map(t.frames.map((f) => [f.id, f]));
    const phases = t.phases.map((p) => ({ ...p,
        kind: (p.sel === "0x570e1a36" || p.target === low(SENDER_CREATOR)) ? "factory" : p.sel === "0x19822f7c" ? "account" : p.sel === "0x52b7512c" ? "paymaster" : "other" }));
    // the op under test = the LAST account phase and everything after it (Alto queues earlier ops in front)
    let startPhase = 0;
    phases.forEach((p, i) => { if (p.kind === "account" && p.target === sender) startPhase = i; });
    // a factory phase for this op precedes its account phase
    if (startPhase > 0 && phases[startPhase - 1].kind === "factory") startPhase -= 1;
    const ctx = { sender, opHashes };
    const rows = { R1: 0, R2: 0, R3: 0, R4: 0, spOwn: 0, accountOwn: 0, registryListed: 0, registryUnlisted: 0 };
    const outside = [], forbidden = [], table = [], otherBanned = [];
    let allowedCreate2 = 0;
    for (const a of t.acc) {
        const f = frames.get(a.f);
        if (!f || f.phase < startPhase || f.phase === -1) continue;
        const ph = phases[f.phase];
        if (phaseFilter && !phaseFilter.includes(ph.kind)) continue;
        const d = decode(a.a, a.s, ctx) ?? { name: `?${a.s}`, base: [], keys: [], off: 0n };
        const isT = a.op === "TSTORE" || a.op === "TLOAD";
        const write = a.op === "SSTORE" || a.op === "TSTORE";
        let row = null;
        if (FORBIDDEN_VARS(d.base)) { forbidden.push({ phase: ph.kind, addr: ADDR_NAMES[a.a] ?? a.a, op: a.op, var: d.name }); row = "R5!"; }
        else if (a.a === TOKEN) {
            const v = d.base[0];
            if (ph.kind === "paymaster") {
                if (isT) row = (d.base.includes("LOCK_SEED") || d.base.includes("CREDIT_SEED")) && senderKeyOk(d, ctx) ? "R3" : null;
                else if (d.base.some((x) => TOKEN_R1.has(x)) && !d.keys.length && !write) row = "R1";
                else if (v === "historicalSP" && !write && low(d.keys[0] ?? "") === low(pad(SP, { size: 32 }))) row = "R1";
                else if (TOKEN_R2_RW.has(v) && senderKeyOk(d, ctx, v === "_auto")) row = "R2";
                else if (TOKEN_R2_RO.has(v) && !write && senderKeyOk(d, ctx, v === "spenderDisabled")) row = "R2";
            } else if (ph.kind === "account") {
                if (!isT && TOKEN_R4.has(v) && senderKeyOk(d, ctx, false)) row = "R4"; // _auto[sp][me]: outer = the named spender
            }
            if (!row) outside.push({ phase: ph.kind, op: a.op, var: d.name, slot: a.s });
        } else if (a.a === REG) {
            const v = d.base[0];
            if (ph.kind === "paymaster" && !write && (v === "creditTierConfig" || (v === "globalReputation" && senderKeyOk(d, ctx)))) { row = "R1/R2(Registry)"; rows.registryListed++; }
            else { row = "Registry-unlisted"; rows.registryUnlisted++; }
        } else if (a.a === SP) {
            row = isT ? (d.base.includes("INFLIGHT_SEED") ? "R3" : "SP-own(T)") : "SP-own";
            if (row === "R3") rows.R3++; else rows.spOwn++;
            row = row === "R3" ? "R3(SP)" : row;
        } else if (a.a === low(sender)) { row = "account-own"; rows.accountOwn++; }
        else if (a.a === EPL) { row = "EntryPoint"; }
        else if (FACTORIES.has(a.a) && ph.kind === "factory") { row = "factory-own"; rows.factoryOwn = (rows.factoryOwn ?? 0) + 1; }
        else { row = "other-address"; outside.push({ phase: ph.kind, addr: a.a, op: a.op, var: d.name, slot: a.s }); }
        if (row && /^R[1-4]$/.test(row)) rows[row]++;
        table.push({ phase: ph.kind, addr: ADDR_NAMES[a.a] ?? a.a, op: a.op, var: d.name, row: row ?? "OUTSIDE" });
    }
    for (const o of t.ops) {
        const f = frames.get(o.f);
        if (!f || f.phase < startPhase || f.phase === -1) continue;
        const ph = phases[f.phase];
        const who = ADDR_NAMES[f.ctx] ?? f.ctx;
        if (FORBIDDEN_OPS.has(o.op)) forbidden.push({ phase: ph.kind, addr: who, op: o.op });
        else if (o.op === "CREATE2" && ph.kind === "factory" && FACTORIES.has(f.ctx)) allowedCreate2++; // OP-031: the factory deploys the sender once
        else if (OTHER_BANNED.has(o.op)) otherBanned.push({ phase: ph.kind, addr: who, op: o.op });
    }
    const tokenFrames = [...frames.values()].filter((f) => f.ctx === TOKEN && f.phase >= startPhase)
        .map((f) => ({ phase: phases[f.phase]?.kind, type: f.type, sel: f.sel, from: ADDR_NAMES[f.from] ?? f.from }));
    // unique rows for the report
    const uniq = new Map();
    const SEP = "\u0001";
    for (const r of table) { const k = [r.phase, r.addr, r.op, r.var, r.row].join(SEP); uniq.set(k, (uniq.get(k) ?? 0) + 1); }
    return { rows, allowedCreate2, outsideCount: outside.length, forbiddenCount: forbidden.length, outside, forbidden, otherBanned,
        tokenFrames, phases: phases.slice(startPhase).map((p) => ({ kind: p.kind, target: ADDR_NAMES[p.target] ?? p.target })),
        table: [...uniq.entries()].map(([k, n]) => { const [phase, addr, op, v, row] = k.split(SEP); return { phase, addr, op, var: v, row, n }; }) };
}

// ---------------------------------------------------------------- per case sender
function senderOf(label, entry) {
    // the sender of the LAST op in the simulation = the last account-phase target
    const acc = entry.ourTrace.phases.filter((p) => p.sel === "0x19822f7c");
    return acc.length ? acc[acc.length - 1].target : null;
}

function checkFile(file) {
    const out = [];
    const seen = new Set();
    const lines = readFileSync(file, "utf8").trim().split("\n").filter(Boolean).map((l) => JSON.parse(l));
    for (const [i, e] of lines.entries()) {
        if (!e.ourTrace) { out.push({ i, label: e.label, error: e.ourTraceError }); continue; }
        const sender = senderOf(e.label, e);
        if (!sender) continue;
        const res = classify(e, { sender, opHashes: new Set() });
        // keep the full per-slot table once per (file, case, sender); later simulations keep counts only
        const key = `${e.label}|${sender}`;
        if (seen.has(key)) delete res.table; else seen.add(key);
        out.push({ i, label: e.label, sender: ADDR_NAMES[sender] ?? sender, ...res });
    }
    return out;
}

// ---------------------------------------------------------------- positive control
function positiveControl(file) {
    const lines = readFileSync(file, "utf8").trim().split("\n").map((l) => JSON.parse(l));
    const b1 = lines.find((l) => l.label === "B1" && l.ourTrace);
    const b6 = lines.find((l) => l.label === "B6" && l.ourTrace);
    const results = {};
    const clone = (x) => JSON.parse(JSON.stringify(x));
    const run = (e) => classify(e, { sender: senderOf(e.label, e), opHashes: new Set() });
    results.baseline_B1 = { outside: run(b1).outsideCount, forbidden: run(b1).forbiddenCount };
    const tokenFramePm = (e) => e.ourTrace.frames.find((f) => f.ctx === TOKEN && e.ourTrace.phases[f.phase]?.sel === "0x52b7512c");
    const user = senderOf("B1", b1);
    const h = "0x" + "ab".repeat(32);
    const inject = (e, acc, kec = [], ops = []) => { const c = clone(e); c.ourTrace.acc.push(...acc); c.ourTrace.kec.push(...kec); c.ourTrace.ops.push(...ops); return c; };
    const mapSlot = (key, p) => { const inp = encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }], [key, p]); return { inp, slot: keccak256(inp) }; };
    const f = tokenFramePm(b1).id;
    // (a) SLOAD usedOpHashes[h] (slot 45) in the SP frame
    { const m = mapSlot(h, 45n); const r = run(inject(b1, [{ f, op: "SLOAD", a: TOKEN, s: m.slot }], [m.inp])); results.usedOpHashes = { forbidden: r.forbiddenCount, flagged: r.forbidden }; }
    // (b) SLOAD _reentrancyStatus (slot 47)
    { const r = run(inject(b1, [{ f, op: "SLOAD", a: TOKEN, s: pad(toHex(47n), { size: 32 }) }])); results.reentrancyStatus = { forbidden: r.forbiddenCount }; }
    // (c) SLOAD _totalSupply (slot 2)
    { const r = run(inject(b1, [{ f, op: "SLOAD", a: TOKEN, s: pad(toHex(2n), { size: 32 }) }])); results.totalSupply = { forbidden: r.forbiddenCount }; }
    // (d) SSTORE renewalMode[u] (read-only row) in the SP frame
    { const m = mapSlot(pad(user, { size: 32 }), 34n); const r = run(inject(b1, [{ f, op: "SSTORE", a: TOKEN, s: m.slot }], [m.inp])); results.writeReadOnly = { outside: r.outsideCount, flagged: r.outside }; }
    // (e) lockedOf[otherUser] (not sender-associated)
    { const m = mapSlot(pad("0x000000000000000000000000000000000000beef", { size: 32 }), 36n); const r = run(inject(b1, [{ f, op: "SSTORE", a: TOKEN, s: m.slot }], [m.inp])); results.otherUserSlot = { outside: r.outsideCount, flagged: r.outside }; }
    // (f) TIMESTAMP in the token frame
    { const r = run(inject(b1, [], [], [{ f, op: "TIMESTAMP" }])); results.timestamp = { forbidden: r.forbiddenCount }; }
    // (g) a GLOBAL token read (exchangeRate, slot 15) inside the ACCOUNT frame of B6 (row R4 forbids it)
    if (b6) {
        const fa = b6.ourTrace.frames.find((x) => x.ctx === TOKEN && b6.ourTrace.phases[x.phase]?.sel === "0x19822f7c");
        results.baseline_B6 = { outside: run(b6).outsideCount, forbidden: run(b6).forbiddenCount };
        const r = run(inject(b6, [{ f: fa.id, op: "SLOAD", a: TOKEN, s: pad(toHex(15n), { size: 32 }) }]));
        results.globalReadInAccountFrame = { outside: r.outsideCount, flagged: r.outside };
    }
    results.allFlagged = results.usedOpHashes.forbidden === 1 && results.reentrancyStatus.forbidden === 1 && results.totalSupply.forbidden === 1
        && results.writeReadOnly.outside === 1 && results.otherUserSlot.outside === 1 && results.timestamp.forbidden === 1
        && (!b6 || results.globalReadInAccountFrame.outside === 1) && results.baseline_B1.outside === 0 && results.baseline_B1.forbidden === 0;
    return results;
}

const report = { at: new Date().toISOString(), files: {} };
for (const f of traceFiles) report.files[f.split("/").pop()] = checkFile(f);
if (control) report.positiveControl = positiveControl(traceFiles[0]);
const summary = {};
for (const [f, entries] of Object.entries(report.files)) {
    summary[f] = entries.filter((e) => !e.error).map((e) => ({ label: e.label, sender: e.sender, rows: e.rows, outside: e.outsideCount,
        forbidden: e.forbiddenCount, otherBanned: e.otherBanned.length, tokenFrames: e.tokenFrames.map((t) => `${t.phase}:${t.type}`).join(",") }));
}
report.summary = summary;
writeFileSync(outJson, JSON.stringify(report, null, 2));
for (const [f, rows] of Object.entries(summary)) {
    console.log(`== ${f}`);
    for (const r of rows) console.log(`${r.label.padEnd(14)} ${String(r.sender).padEnd(16)} R1=${r.rows.R1} R2=${r.rows.R2} R3=${r.rows.R3} R4=${r.rows.R4} reg=${r.rows.registryListed}/${r.rows.registryUnlisted} spOwn=${r.rows.spOwn} acctOwn=${r.rows.accountOwn} factoryOwn=${r.rows.factoryOwn ?? 0} OUTSIDE=${r.outside} FORBIDDEN=${r.forbidden} otherBanned=${r.otherBanned}`);
}
if (control) console.log("positive control:", JSON.stringify(report.positiveControl, (k, v) => (k === "flagged" ? undefined : v)));
