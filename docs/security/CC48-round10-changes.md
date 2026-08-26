# CC-48 round 10 — CI gate integrity (no contract change)

**Scope of this round is CI and generated documentation only.**
No Solidity source, no ABI, no storage layout, and no `version()` string changes here.
`docs/security/CC48-round9-changes.md` remains the authoritative record for the
Registry 5.8.0 ABI/storage surface; nothing in this round supersedes it.

Trigger: PR #375 at `34c7a742` was **approved by pr-daemon** (third review, 17:47Z,
0 blocker / 0 high / 0 medium — two Lows recorded as residuals below) but could not be
merged because two CI gates were red. Both were real defects in our own CI plumbing, not
flakes, and neither is fixed by deleting a check.

---

## 1. `abi-docs` — the generator invented 45 phantom contracts

### Symptom
`pnpm gen:abi-docs:check` failed with `STALE: docs/abi/reference.md` /
`STALE: docs/abi/selectors.md`.

### Why the naive fix was wrong
Simply committing the generator's output made the check pass, but the output was garbage:
**94 contract sections instead of 49**, +18,313 lines. The extra sections were named
`BLSAggregator.registry-size`, `GToken.registry-size`, `MySBT.registry-size`, … — 45
phantom "contracts" that do not exist, each a byte-for-byte duplicate of a real one's
entire documented surface. Committing that would have turned the reference doc into a
duplicated mess in order to make a gate green.

### Root cause
CC-48 round-3 added an `additional_compiler_profiles` entry named `registry-size` to
`foundry.toml` (Registry.sol is pinned to `max_optimizer_runs = 200` for EIP-170). Every
contract in Registry's import closure is therefore compiled **twice** and forge emits two
artifacts:

```
out/BLSAggregator.sol/BLSAggregator.json                 # default profile
out/BLSAggregator.sol/BLSAggregator.registry-size.json   # restricted profile
```

`scripts/gen-abi-docs.mjs` accepted any `*.json` in the directory and derived the contract
name with `file.replace(/\.json$/, "")`, so the second artifact became a contract literally
named `BLSAggregator.registry-size`. 132 such artifacts exist in a current build.

This is the **same failure mode already fixed in `scripts/extract_v3_abis.sh` during
round 9** — that script's `find out -name "<C>.json"` likewise stopped finding what it
expected once the second profile appeared. The generator was missed at the time.

### Fix
`scripts/gen-abi-docs.mjs` is now profile-aware: when a directory contains both
`<Contract>.json` and `<Contract>.<profile>.json`, the default-profile artifact wins and the
variant is skipped. If only a variant exists it is still documented, but under the real
contract name (never the suffixed one). Solidity identifiers cannot contain `.`, so a
multi-segment artifact stem is unambiguously a profile variant.

### Result
`docs/abi/` now regenerates to **55 contracts / 934 functions / 272 errors / 198 events**,
with zero `registry-size` strings and no duplicate section names. All 49 previously
documented contracts are preserved unchanged in identity; the diff is +2,034 / −73.

The 6 newly documented contracts (`IFraudProofVerifier`, `IGTokenStakingSlash`,
`ILivenessRegistry`, `ISPStakeView`, `IxPNTsFactoryCap`, `LivenessRegistry`) **already exist
on `main`** — the committed docs were stale before this PR and this round incidentally
corrects that, because the gate is all-or-nothing. Only `IGuardianExitGate` is introduced by
this branch. This is disclosed rather than presented as PR content.

Verified: generator is idempotent (two consecutive runs byte-identical), `--check` passes,
and the new Registry credit surface (`seedCreditPopulation`, `creditPopulationTotal`,
`creditPopulationSeededAt`, `CreditExposureResynced`, `CreditPopulationNotSeeded`,
`CreditTiersNotMonotonic`, 2-arg `setCreditPolicy`) is present with real NatSpec.

---

## 2. `CI Required Shim` — `paths-ignore` is not the complement of `paths`

### Symptom
Every required check appeared **twice** on PR #375, once green and once red:

| check | real workflow | shim |
|---|---|---|
| `test` | ✅ pass (6m55s) | ❌ fail (7s) |
| `Stage 1 — solhint + build (EIP-170)` | ✅ pass (1m10s) | ❌ fail (6s) |
| `Stage 2 — forge test + fuzz` | ✅ pass (13m38s) | ❌ fail (5s) |

### Root cause
`ci-required-shim.yml` existed to unblock docs-only PRs: path-filtered required checks never
run on them, so branch protection hangs on "Expected — waiting for status" forever. The shim
reported the same check names on `paths-ignore:` — assuming that is the complement of the
real workflows' `paths:`.

**It is not.** Both `paths:` and `paths-ignore:` are *"does **any** changed file match?"*
predicates. They partition PRs only when a PR is homogeneous. PR #375 changes 68 files:
**51 contract-path files** (which satisfy `paths:` and fire the real workflows) and
**17 docs/ABI files** (which satisfy `paths-ignore:` and fire the shim). Both ran. The shim's
300-file bypass guard then did its job correctly — it detected contract changes and exited 1,
exactly as designed — producing a permanently red check run sharing a required name with the
green one. Unmergeable, with no way to fix it from inside the shim's own design.

### Fix — strengthen the gate rather than remove it
The shim is deleted, and `test.yml` / `security.yml` now run on **every** PR (their `paths:`
filters are gone). Consequences:

- **Exactly one check run per required name, always.** The collision is structurally
  impossible, not merely unlikely. No reliance on GitHub's ambiguous "which duplicate wins"
  behaviour, and no reliance on "a skipped job counts as success".
- **The gate decides its own applicability, from the complete diff.** Each job's first step
  runs `git diff --name-only base...head` over the full changed-file set and sets
  `contract=true|false`. Heavy steps are guarded on that output; the job itself always
  reports success or failure on its own merits and is never "skipped".
- **This closes the 300-file hole rather than guarding it.** Previously the *real* workflows'
  `paths:` filter decided whether the security suite ran at all — and GitHub only evaluates
  path filters against the first 300 changed files. A large PR with contract changes buried
  past file #300 would have skipped the real suite entirely, leaving only the shim's guard to
  catch it. Now the real workflow always starts and makes the decision itself from a full
  `git diff`, which has no such limit.
- **Nothing is weakened.** Whenever any contract path changes, solhint + build + EIP-170 +
  storage-layout + full `forge test` + 10k fuzz + the Prague real-precompile gate all run
  exactly as before. `Scan for Private Keys and Secrets` was never path-filtered and is
  untouched.

Cost: a docs-only PR now pays one checkout per job (~1 min) instead of zero, and correctly
reports green without a shim. That is the price of removing an unsound predicate.

Verified by simulating the detection regex against this PR's real diff: both workflows
resolve to `contract=true` (full gate runs), while a docs-only file list resolves to
`contract=false` (honest success). YAML parses and job names match the protected check names
byte-for-byte.

---

## 3. Preserved

All round-9 pr-daemon fixes and every protocol test are intact and still enforced:
B1 (`_invalidateCreditPopulation` on both schedule setters), B3 (`seedCreditPopulation`
replacing the operator-supplied baseline), B4 (honest `totalCreditExposure` NatSpec),
B5 (`CC48CreditScheduleControls.t.sol`, 21 tests on `initialize` defaults), B6 (two-sided
monotonicity validation). No test was deleted, skipped, or weakened.

## 4. Open residuals (pr-daemon Lows, not addressed this round — deliberately)

Both were filed as non-blocking in the approving review and are left for a follow-up so this
round stays confined to CI:

- **L1** `Registry.sol:646-655` — pricing an unreachable level invalidates the whole
  population even though it moves nobody's limit. Suggested guard:
  `if (level <= maxLevel) _invalidateCreditPopulation();`
- **L2** `Registry.sol:711-713` — the ceiling guard reads `totalCreditExposure`, which
  `_invalidateCreditPopulation()` has zeroed, so it is vacuous inside the invalidation
  window. Either refuse *lowering* `maxTotalCreditExposure` while `creditPopulationSeededAt
  == 0`, or correct the NatSpec to name `seedCreditPopulation`'s per-batch check as the real
  protection.

## 5. Verification (all run locally on this branch)

| gate | result |
|---|---|
| `pnpm gen:abi-docs:check` | up to date (55 contracts / 934 fn / 272 err / 198 ev) |
| generator idempotency | two runs byte-identical |
| `forge build --sizes --skip test --skip script` | exit 0 |
| Registry EIP-170 | 23,029 B / 1,547 B headroom |
| `python3 scripts/check_storage_layout.py` | OK SuperPaymaster (37) / OK Registry (32) |
| `forge test` (Cancun) | 1339 passed / 0 failed / 38 skipped |
| `forge test --evm-version prague` | see PR comment |
| focused `contracts/test/security/*` | see PR comment |
| focused `contracts/test/paper7/*` (prague) | see PR comment |
| `git diff --check` | clean |
