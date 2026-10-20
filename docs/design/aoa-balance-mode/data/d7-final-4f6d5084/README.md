# D7 JS E2E — rerun on the final head `4f6d5084` (DSR CC-125 9479dbd8 package ①)

Supersedes `../d7-rc2/` for the harness question: that archive ran harness `68dfdccb`; #484's final
head `853278d0` changed `setup-gasless.js` once more. This run uses the **final feat head for both the
deployed contracts and the harness**.

**Local anvil only. Not public-chain evidence, not A6 data.**

## Coordinates (`env.txt`)

| item | value |
|---|---|
| commit (contracts + harness, same worktree) | `4f6d50842c51678f79c1246dde86282f3b37b74f` (feat head after #480–#485) |
| worktree clean for contracts/ script/ deploy-core prepare-test | yes |
| contracts/src vs `v5.5.0-rc.2` `1ac0e1c5` | IDENTICAL |
| tools | anvil 1.7.1, forge 1.7.1, node v24.21.0 |
| chain | fresh `anvil --chain-id 31337 --hardfork prague`, control block 0 / deployer nonce 0 |
| runner | `script/evidence/d7-anvil-rerun.sh <worktree> <out> 8640` (committed with this archive; identical sha to the copy that ran) |

## Impact of `68dfdccb → 853278d0` (the 16 lines DSR asked about)

`git diff 68dfdccb 853278d0` touches only `script/gasless-tests/setup-gasless.js`, hunk `@@ -246,12 +246,18 @@`
(Step 4.5 "Ensure Base Credit Tier"): the tier-raise scan now collects contiguous levels below the
**write target** (300) instead of the trigger (200), raising highest-first. `853278d0..4f6d5084` does not
change `script/gasless-tests/` at all.

`setup-gasless.js` runs once, at `run-all-e2e-tests.sh:319` (Phase 9), and again after the warp. So the
change can only affect what runs **after** it and depends on Registry credit tiers:

| script | depends on the change? | result here |
|---|---|---|
| Phases 1–8 (A1…I2 groups, before L319) | no — run before setup-gasless | see summary |
| Gasless: PaymasterV4 (test-case-1) | runs after; uses V4 deposit, not credit tiers | PASS |
| Gasless: SuperPaymaster xPNTs1 (test-case-2) | runs after; balance mode | SKIP — AA account has 0 aPNTs (funding), not exercised |
| Gasless: SuperPaymaster xPNTs2 (test-case-3) | runs after; balance mode | PASS |
| Gasless: SP Credit/Debt (test-case-4) | **yes** — credit cap comes from tier 1 | in-suite SKIP (48h timelock, by design); **after warp PASS** — credit 300 aPNTs available, debt +132.96426, credit −132.96426, xPNTs unchanged |

The changed code path executed in this run: `03-e2e.clean.log` L1591–1597 — "creditTierConfig[2] below
threshold — raising to 300" then tier 1, i.e. highest-first, both `setCreditTier` txs confirmed.
On a fresh deploy the tier table is `[100, 100, 300, 600, 1000, 2000]` (`03-e2e.clean.log` L202–209),
so the old scan (stop at ≥ 200) and the new scan (stop at ≥ 300) both pick levels {1, 2} and stop at 3;
the fix matters for schedules with a neighbour in [200, 300). That case is covered by the simulation in
the `853278d0` commit message, not by this run.

## Result

Suite (`03-e2e.clean.log`): **37 scripts — 31 PASS / 4 FAIL / 2 SKIP**. Post-warp (`steps.txt`):
`updatePrice` rc 0, `setup-gasless` rc 1 (its pre-existing "Deployer xPNTsToken = aPNTs" prerequisite,
a stale legacy check), **test-case-4 rc 0 (PASS)**, test-case-2 rc 2 (SKIP, zero balance).

D7-migrated scripts (scope of DSR's #438 acceptance): B4, B5, C1, E3, E4, G1, G3, I1 **PASS**;
test-case-1/3 PASS; test-case-4 PASS after warp; **test-case-2 not exercised**.

## Exclusion boundary — this is NOT 37/37

| excluded | reason |
|---|---|
| test-case-2 (xPNTs1) | SKIP: AA account holds 0 aPNTs when it runs (harness funding); the balance-mode path is exercised by test-case-3 instead, but test-case-2 itself never ran |
| B3 | stale script: passes v1 `aPNTs` to `configureOperator`; 5.5.0 requires a factory-bound v2 token |
| D2 | stale script: `setCreditTier(7,0)` → `CreditTiersNotMonotonic()` (Registry rule; G3 handles it) |
| E1 | calls `description()` (`0x7284e416`), not implemented by `AnvilMockPriceFeed` |
| x402 EIP-3009 | `decimals()` on a token not deployed on anvil |

None of the four failures is in the D7 migration scope, and none is a contract defect.

## Files

`env.txt`, `steps.txt`, `config.anvil.json`, `e2e.env.redacted`, `01-deploy-core.log.gz`,
`02-prepare-test.log.gz`, `03-e2e.clean.log`, `04-setup-after-warp.log`, `05-tc4-after-warp.log`,
`06-tc2-after-warp.log`, `anvil.log.redacted.gz` (only the anvil default key block and mnemonic
redacted; 190 tx hashes kept). Exit codes are in `steps.txt`. Covered by `../../EVIDENCE.sha256`.
