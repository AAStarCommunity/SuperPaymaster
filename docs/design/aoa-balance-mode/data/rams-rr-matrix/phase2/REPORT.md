# CC-125 Phase 2 capture

Engine: 4e8874b2bdc840929585ca73e170993c50a4a531; repository: 1ef7bede045831a7d94cebffa88ba08d6d23d23e.
Selected definitions: 360; measured transactions: 1080. Errors: 0.

| DSR dimension | Captured cell values |
|---|---|
| mode | balance, credit |
| context | V2 |
| warmth | cold, warm |
| history | first, subsequent |
| position | 1of1, 1of3, 3of3 |
| scenario | success, execution-revert, postOp-exhaustion, refund, refill, state-demand |
| postGas | 439999, 440000, 440001 |

Each ID in definitions.json maps to cells.jsonl and traces/<ID>-<regime>.jsonl.gz. Legacy160 and cold 3of3 are inapplicable (definitions include reasons).

I9, I10, charge and bare/fee targets are per-op fields in cells.jsonl. I10 includes stale-release checks. PostOp exhaustion uses the labelled adversarial token fixture.

Refund observations: 1080; refill observations: 120; exhaustion observations: 120.

Guard or outcome changes: 40; all comparisons are in comparisons.json.

| Cell | RR regime | Guard changed | Guard pass/fail changed | Outcome changed |
|---|---|---|---|---|
| balance-V2-cold-first-1of1-state-demand-440000 | RR30M | false | false | true |
| balance-V2-cold-first-1of1-state-demand-440001 | RR30M | false | false | true |
| balance-V2-cold-first-1of3-state-demand-440000 | RR30M | false | false | true |
| balance-V2-cold-first-1of3-state-demand-440001 | RR30M | false | false | true |
| balance-V2-cold-subsequent-1of1-state-demand-440000 | RR30M | false | false | true |
| balance-V2-cold-subsequent-1of1-state-demand-440001 | RR30M | false | false | true |
| balance-V2-cold-subsequent-1of3-state-demand-440000 | RR30M | false | false | true |
| balance-V2-cold-subsequent-1of3-state-demand-440001 | RR30M | false | false | true |
| balance-V2-warm-first-1of1-state-demand-440000 | RR30M | false | false | true |
| balance-V2-warm-first-1of1-state-demand-440001 | RR30M | false | false | true |
| balance-V2-warm-first-1of3-state-demand-440000 | RR30M | false | false | true |
| balance-V2-warm-first-1of3-state-demand-440001 | RR30M | false | false | true |
| balance-V2-warm-first-3of3-state-demand-440000 | RR30M | false | false | true |
| balance-V2-warm-first-3of3-state-demand-440001 | RR30M | false | false | true |
| balance-V2-warm-subsequent-1of1-state-demand-440000 | RR30M | false | false | true |
| balance-V2-warm-subsequent-1of1-state-demand-440001 | RR30M | false | false | true |
| balance-V2-warm-subsequent-1of3-state-demand-440000 | RR30M | false | false | true |
| balance-V2-warm-subsequent-1of3-state-demand-440001 | RR30M | false | false | true |
| balance-V2-warm-subsequent-3of3-state-demand-440000 | RR30M | false | false | true |
| balance-V2-warm-subsequent-3of3-state-demand-440001 | RR30M | false | false | true |
| credit-V2-cold-first-1of1-state-demand-440000 | RR30M | false | false | true |
| credit-V2-cold-first-1of1-state-demand-440001 | RR30M | false | false | true |
| credit-V2-cold-first-1of3-state-demand-440000 | RR30M | false | false | true |
| credit-V2-cold-first-1of3-state-demand-440001 | RR30M | false | false | true |
| credit-V2-cold-subsequent-1of1-state-demand-440000 | RR30M | false | false | true |
| credit-V2-cold-subsequent-1of1-state-demand-440001 | RR30M | false | false | true |
| credit-V2-cold-subsequent-1of3-state-demand-440000 | RR30M | false | false | true |
| credit-V2-cold-subsequent-1of3-state-demand-440001 | RR30M | false | false | true |
| credit-V2-warm-first-1of1-state-demand-440000 | RR30M | false | false | true |
| credit-V2-warm-first-1of1-state-demand-440001 | RR30M | false | false | true |
| credit-V2-warm-first-1of3-state-demand-440000 | RR30M | false | false | true |
| credit-V2-warm-first-1of3-state-demand-440001 | RR30M | false | false | true |
| credit-V2-warm-first-3of3-state-demand-440000 | RR30M | false | false | true |
| credit-V2-warm-first-3of3-state-demand-440001 | RR30M | false | false | true |
| credit-V2-warm-subsequent-1of1-state-demand-440000 | RR30M | false | false | true |
| credit-V2-warm-subsequent-1of1-state-demand-440001 | RR30M | false | false | true |
| credit-V2-warm-subsequent-1of3-state-demand-440000 | RR30M | false | false | true |
| credit-V2-warm-subsequent-1of3-state-demand-440001 | RR30M | false | false | true |
| credit-V2-warm-subsequent-3of3-state-demand-440000 | RR30M | false | false | true |
| credit-V2-warm-subsequent-3of3-state-demand-440001 | RR30M | false | false | true |

## Analysis (Claude, from `analysis.json` = `script/evidence/rr-matrix-analyze.py phase2 analysis.json`, and `comparisons.json`)

Run: engine nightly **4e8874b** (keeps the EIP-8037 reservoir; frame-level 10/10 vs chain, `../frame-calibration/`), repo `1ef7bede`, `dirtyCount 0`, 360 cells × {R0 = 2^24, RR30M, RRdelta = 2^24 + 100,000} = **1080 mined handleOps**, 0 errors.

**SP safety under RR — no change found**
- **I9 holds in all 1080 rows** (no validation-reserved sponsorship left unsettled).
- **postOp guard `gasleft() < snapSettle`: 0 pass/fail changes in 720 R0↔RR comparisons** (pass 480, not-reached 240 in both regimes; not-reached = MIN−1 rows rejected at validation).
  **Coverage limit:** no admitted op ever *trips* the guard in either regime — by design MIN (440k) > SETTLE (420k) — so the guard-*fail* path is not exercised; the matrix shows RR does not turn pass into fail, not how a failing guard behaves under RR.
- **G2 (no subsidy) 200/200 in every regime.** `charge − bareCost < 0` in 40/240 target ops in every regime — all 40 are `postOp-exhaustion` with the labelled adversarial token fixture (`token-settlement-gas-burner`, SP bytes unchanged), identical across regimes.
- **Outcome changes: 40, all `state-demand` cells in RR30M** — state-heavy ops that only fit with a reservoir (expected).

**EntryPoint-level finding — RR under-reimburses the bundler**
- EntryPoint v0.7 measures each op with `gasleft()` deltas, and `gasleft()` excludes the reservoir. Per-op `actualGasUsed` vs R0 (same cell, both successful, excluding `state-demand`):
  - RR30M: **median 0.492× (min 0.416×)**, delta median −1,762,560 gas;
  - RRdelta (reservoir 100,000): delta ≥ −100,000 (= the reservoir), median 0.986×.
- Hence `tx gasUsed − Σ op actualGasUsed`: R0 median −341,815 (PVG over-covers), **RR30M median +321,355, max +3,480,684** — gas the bundler pays but EntryPoint does not reimburse; the user / SP pay correspondingly less. SP's own books stay consistent because SP charges on EntryPoint's `actualGasCost`.
- Consequence: a bundle above 2^24 is a loss for the bundler. This is outside SP, but it must be a stated requirement for SDK/bundler configuration (handleOps gas ≤ 2^24), not an assumption.

**Not covered:** legacy 160 B context (not reachable with rc.4 bytes) and cold validation at op 3/3 (definitions record the reasons); real public-bundler behaviour above 2^24.

## Evidence layout (size)

The full trace set (1260 `traces/*.jsonl.gz`, 380 MB) is too large for the repository. It is kept outside git as
`phase2-traces.tar` (sha256 in `TRACES-ARCHIVE.sha256`), and **every individual trace's sha256 is committed** in
`TRACES-SHA256.txt`, so any copy of the archive can be verified file by file. `traces-sample/` holds 12 traces
(4 cells × R0/RR30M/RRdelta: the smoke success cell, a state-demand cell, a postOp-exhaustion cell and a MIN−1 cell).
`cells.jsonl` is committed as `cells.jsonl.gz` (sha256 of the uncompressed file in `CELLS-SHA256.txt`);
`rr-matrix-analyze.py` reads either form and reproduces `analysis.json` exactly.
