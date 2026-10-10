# A2 rehearsal with fail-closed reads, fork block 11884320, script commit 045a8962

DSR CC-125 (466d42d1 ①) asked for two things in `script/evidence/a2-full-rehearsal.sh` (the whole script, not only stage D):
- **Every read must fail closed.** A failed, empty or ill-typed value must FAIL the run.
- **The fork-block hash check must reject empty values.** Endpoint A, endpoint B and the local fork must EACH be a non-empty 32-byte hash AND be equal. Before this change, two empty reads compared "equal".

This directory holds:
- the **old-vs-new negative-control readings** (`negctl-old-vs-new/`);
- **ONE fresh complete `all` run** of the final committed script.

## The run

**Run.** One uninterrupted `all` run of `script/evidence/a2-full-rehearsal.sh` at commit
`045a896299cdb0119d2f53f709409806ea366f7b`. The tree was clean: `rehearsal.log` L2 prints no "+ uncommitted changes".
- **Fork:** Sepolia block **11884320**, hash `0x00077efb242ec807041d51767ff3f2ef93cc83aaca8ebf8ddcc6111e31460478`. Each of endpoint A, endpoint B and the local fork read that same hash, and each value is checked to be a 32-byte hash (L47–L51).
- **Where:** LOCAL anvil, 127.0.0.1:28631.
- **When:** logged UTC 11:48Z → 11:54Z on 2026-10-10; exit code 0.

**Result: `RUN COMPLETED WITH 0 FAILURES (all)`** (L1107–L1108):
- **370 `CHECK … PASS`, 0 `CHECK … FAIL`, 0 failure (`!!!`) lines.** The only line containing "!!!" is the tally line L1107 itself, which reads "!!! lines: 0".
- **0 `READ FAILED` lines.**
- **65 negative controls, 65/65 PASS = 55 byte-exact revert-data matches + 10 offline regex refusals.** The 10 offline refusals are NEG-13, 21, 24 (`UpgradeViaTimelock` without a roles attestation), NEG-44/45 (stale dummy artifact), NEG-46/47 (slot-dump read failure), NEG-48/49 (getter-snapshot read failure) and NEG-50 (release tool refuses the test dummy). Each row's match kind is in `neg-controls.jsonl` (`mode`).

Nothing was broadcast to any public network. The public RPC was used only as `anvil --fork-url` and for read-only pre-state reads. RPC URLs and keys are not in any file here. A scan for the env file's 9 key/URL values found 0 hits in this directory; positive control: all 9/9 are found in the env file itself.

`contracts/src` is byte-identical to v5.5.0-rc.2 (peeled `1ac0e1c595dc84e684b540ca6a936168e922194f`, L3). The local `profile.default` build reproduces every attested artifact (L5–L17).

| what | log lines (`rehearsal.log`) | key result |
|---|---|---|
| pre-state on two endpoints, fail-closed | L18–L21 | A: 23 reads, 0 failed; B: 23 reads, 0 failed; IDENTICAL (23 values) |
| fork-block hash | L46–L51 | A, B and fork each a 32-byte hash; A == B; fork == A |
| GOV-1 Safe-only timelock (G0) + APNTsCapped accept | L68–L199 | Safe 2-of-3 `execTransaction` → TL schedule / 48h / execute |
| runbook 1–7c (EOA path), SP → 5.5.0, Registry → 5.9.0 | L141–L370 | |
| **UserOps, both communities** (7c) | L371–L399 | Mycelium: TxHash `0x5e14dc6b…2e10`, UserOpHash `0xa8b99bcb…f3f0`, block 11884382, success 1 (L379–L381). AAStar: TxHash `0xaf27186e…8918`, UserOpHash `0xeb3adaf3…6b7f`, block 11884388, success 1 (L393–L395) |
| M1 two-step transfer + scheduleBatch via Safe | L400–L522 | SP.owner == TL (L493); Registry.owner == TL (L497) |
| **Safe/timelock upgrade route** (C, same rc.2 bytecode) | L523–L657 | SP impl `0x3a69c08a…` (L576, version L579); Registry impl `0x6b1c9f85…` (L643, version L646) |
| M2 guardian pause / timelock unpause, M3 price via timelock | L658–L798 | |
| **dummy bump (upgrade) + rollback (downgrade)** via Safe → TL | L799–L1059 | D5: impl slot == dummy `0x90f740a9…` (L952), version `…-A2DRILL-DUMMY-NOT-A-RELEASE` (L955), impl codehash `0x855c0e80…` → `0xea5051d2…` (L956–L958). D6: impl slot == rc.2 `0x3a69c08a…` (L1038), version `SuperPaymaster-5.5.0` (L1040), codehash back to `0x855c0e80…` (L1041–L1042) |
| final runtime attestation + role sets | L1060–L1089 | |
| fork tx ledger | L1090–L1098 | 151 blocks, 120 txs; no tx from the Safe; Safe txs only from owners O1/O2; no mined revert; no direct tx to the TL |

Receipts of every tx sent are in `receipts.jsonl` (69). The complete fork ledger is in `fork-tx-ledger.jsonl` (120). Negative controls: `neg-controls.jsonl` (expected vs actual) and `neg.log` (full outputs).

## What changed in the script (commit 045a8962)

- **`rtype` / `rv`.** Every value is typed:
  - address = 20-byte hex;
  - bytes32 / word / hash = 32-byte hex;
  - uint / int must parse; bool must be true or false;
  - string must be quoted and non-empty;
  - address[] must be a well-formed list;
  - tuples and multi-returns must be non-empty and contain no "Error".

  `rv <type> <label> <filter> <cmd…>` checks the exit status (pipefail) and then the type. On failure it writes `!!! READ FAILED …` and returns the sentinel `READ-FAILED`.
- **Helpers routed through it.**
  - Basic reads: `bn`, `rbs`, `impl_of`, `codehash_at` / `codesize_at`.
  - Hash reads: `safe_hash`, `tl_id`.
  - Values read from receipts: contract addresses (TL, misconfigured TL, dummy).
  - Timestamps, operator balances and tokens, oracle reads.
  - M1 batch id, C-stage owner and BLS legs, M2 probe inputs, final read-backs.
- **`rb`.** Checks the exit status (cast's stderr is no longer mixed into the value) and requires the value to match the signature's return type.
- **`xread`.** All 23 pre-state reads on each endpoint are exit-checked and type-checked; a failure is written as `key=READ-FAILED`. Each endpoint must deliver 23 values with 0 failures before "identical" counts.
- **Fork-block hash.** A, B and the local fork are each typed as a hash, then A == B and fork == A are checked.
- **Verdict.** The final verdict also counts `!!!` lines. A `fail()` inside `$(…)` runs in a subshell, so its FAILURES increment is lost; its `!!!` line is not.
- **Unchanged on purpose.** `dump_slots` / `sp_state` keep their own block-number handling (`bn_raw`), because their negative controls inject exactly that failure.

## Old vs new: the same injected fault, both exit codes (real readings)

`script/evidence/a2-read-failclosed-negctl.sh` takes the script's preamble verbatim from each version with `git show`. The preamble is every line before `if stage_on 0; then`: provenance, build == attestation, the two-endpoint pre-state, the local anvil fork, and the fork-hash and Safe checks.
- **old** = merge `252ffe3879487158a148fa37183ba3e810fd26e4` (the script as merged by #462).
- **new** = `045a896299cdb0119d2f53f709409806ea366f7b`.

Each version runs under the same `cast` shim that injects the fault and otherwise forwards to the real binary. The harness then applies a neutral verdict: exit 0 iff FAILURES == 0 and there is no `!!!` line.

Both versions were run against fork block 11884270. The output is in `negctl-old-vs-new/` (`negctl-table.tsv`, `negctl-summary.log`, and `<injection>/<old|new>/` with each run's `rehearsal.log`, `console.log` and `injections.log`).

| injection | old exit | new exit | old: what decided | new: what decided |
|---|---|---|---|---|
| none (positive control) | 0 | 0 | all PASS | all PASS (A 23:0, B 23:0, 3 hashes well-formed and equal) |
| **both-empty**: block-hash read answers "" on A, B and the fork | **0 (fail-open)** | **1** | pre-state "IDENTICAL (23 values)" PASS; `fork block hash == endpoint A` **PASS: ''** (empty == empty) | A 23:1 and B 23:1 FAIL; `READ FAILED [fork block … hash]`; all 3 hashes ILL-TYPED; A==B and fork==A FAIL |
| both-empty-endpoints: "" on A and B, fork real | 1 | 1 | pre-state IDENTICAL **PASS** (empty == empty); only `fork == A` failed (real hash vs '') | A/B 23:1 FAIL; A and B hashes ILL-TYPED; A==B FAIL |
| both-fail: block-hash read exits 1 on A, B and the fork | 1 | 1 | `fork block hash == endpoint A` **PASS: ''**. The run failed only because the injected stderr text landed in the endpoint-A file and the "error" grep caught it | A/B 23:1 FAIL; `READ FAILED … exit 1`; 3 hashes ILL-TYPED |
| single-endpoint-fail: every read on B exits 1 | 1 | 1 | pre-state diff differs → FAIL | B 23:23 FAIL; B hash ILL-TYPED; A==B FAIL (A and fork stay healthy) |
| **ill-typed**: SP.owner() = `0x1234` on A and B | **0 (fail-open)** | **1** | pre-state IDENTICAL PASS (equal garbage) | A 23:1 and B 23:1 FAIL (`SP.owner` expected address) |

Where the old script was fail-open (both-empty, ill-typed), old exits 0 and new exits 1. Where the old script already exited 1, it did so for an incidental or partial reason:
- **both-empty-endpoints:** the old pre-state comparison still passed on two empty hashes.
- **both-fail:** the old fork-hash comparison still passed on '' == ''.

In those cases the new script fails at the read itself.

## Not in this directory

- The `.rv.err` / `.rb.err` / `.xr.err` scratch files the new helpers leave in the run directory were not archived. They hold the stderr of the last read; every failure's text is already in its `!!!` line. A cleanup tweak would change the script after this run, so it is left for a later commit.
- Earlier A2 archives (`fork-rehearsal-a2-full-11877936-0c21a8fe`, `a2-item4-dummy-bump-*`) are unchanged.

## Reproduce

```
forge build                      # profile.default
pnpm install
script/evidence/a2-full-rehearsal.sh <env file with RPC_URL> 11884320 <out dir> all
script/evidence/a2-read-failclosed-negctl.sh <env file with RPC_URL> 11884270 <out dir> 252ffe38
cd docs/design/aoa-balance-mode/data/d5b/a2-failclosed-reads-11884320-045a8962 && shasum -a 256 -c EVIDENCE.sha256
```
