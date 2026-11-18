// Reproduces each owner-table review-round-3 case against the code of a90fb624 and prints what that code did.
// Run from a tree extracted at a90fb624 (with node_modules linked), e.g.:
//   git archive a90fb624 scripts script/rehearsal script/evidence/rc8-owner-table docs/security/rc8-owner-table.json \
//     docs/security/rc8-owner-table.md contracts/src abis script/upgrade/manifest_exec.py script/upgrade/sp_upgrade_exec.py \
//     script/a3a/a3a_exec.py contracts/script/v3/DeployLive.s.sol | tar -x -C <dir>
//   cp script/evidence/owner-table-round3-old-behaviour.mjs <dir>/ && (cd <dir> && node owner-table-round3-old-behaviour.mjs)
// Offline; no network.
import * as lib from "./script/rehearsal/lib/two-endpoint.mjs";
import { inventoryErrors } from "./script/rehearsal/lib/inventory-accept.mjs";
import { load, status } from "./scripts/gen-rc8-owner-table.mjs";
import { readFileSync } from "node:fs";
const out = (k, v) => console.log(k.padEnd(58), JSON.stringify(v));
const SP = "0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9", REG = "0xf5Bf37ca83AfdAab73691bA7eCcDfA69b8708E71";
const inv = JSON.parse(readFileSync("script/evidence/rc8-owner-table/inventory-12158399.json"));
const want = { chainId: 11155111, sp: SP, registry: REG };
const { endpointsReturnIdenticalLogs, ...missing } = inv.positiveControl;
out("1 M4 delete endpointsReturnIdenticalLogs -> errors", inventoryErrors({ ...inv, positiveControl: missing }, want));
out("1 M4 controls {irrelevant:true} -> errors", inventoryErrors({ ...inv, positiveControl: { irrelevant: true } }, want));
const { t, ctx } = load();
const r = (id) => t.rows.find((x) => x.id === id);
t.legacyProbe.results.hits = t.legacyProbe.results.hits.filter((h) => h.subject !== t.identities.AGG_4_1_B);
t.legacyProbe.results.memberAbsent.push("STAKING.authorizedSlashers(x)");
r("staking.slashers").current = { error: "both endpoints timed out" };
out("2 M6 reviewer case agg_4_1_b.owner status", status(t, ctx, r("agg_4_1_b.owner")));
out("3 M5 both(Error('')) result", await lib.both([{}, {}], async () => { throw new Error(""); }));
const fk = { getCode: async () => { throw new Error(""); } };
out("3 M5 codeAt(Error('')) result", await lib.codeAt([fk, fk], "0x1", 1n));
const l = { address: "0xAb", blockNumber: 1n, blockHash: "0x1", logIndex: 0, transactionHash: "0x2", topics: [], data: "0x" };
out("4 H2 removed:true both sides identical?", lib.compareLogs([{ ...l, removed: true }], [{ ...l, removed: true }]).identical);
out("4 H2 duplicate identity identical?", lib.compareLogs([l, { ...l }], [l, { ...l }]).identical);
out("4 H2 transactionIndex differs identical?", lib.compareLogs([{ ...l, transactionIndex: 0 }], [{ ...l, transactionIndex: 1 }]).identical);
const tryInd = (a, b) => { try { return lib.assertIndependent(a, b); } catch (e) { return "rejected: " + e.message; } };
out("5 H1 host vs host.", tryInd("https://host/key1", "https://host./key2"));
out("5 H1 :8545 vs :443", tryInd("https://x.example:8545", "https://x.example:443"));
out("5 H1 a.example.org vs b.example.org", tryInd("https://a.example.org/k", "https://b.example.org/k"));
const invSrc = readFileSync("script/rehearsal/inventory.mjs", "utf8");
out("6 L6 inventory uses rename?", /renameSync|writeAtomic/.test(invSrc));
const red = lib.makeRedactor(["https://x.example.org/abc123key/proj987xyz?token=sek42val", "https://y.example.net/v3/zzKEY9"]);
out("7 L7 redacted split credential", red("auth failed for abc123key in project proj987xyz, token sek42val; key zzKEY9"));
out("9 dvt.validators status", status(load().t, load().ctx, load().t.rows.find((x) => x.id === "dvt.validators")));
out("10 apntsPmv4.owner notes", load().t.rows.find((x) => x.id === "apntsPmv4.owner").notes ?? null);
