# Echidna property suite — STATUS: superseded by forge invariants

> Audit 2026-06-11 §6 (T-H1). All five `contracts/echidna/*.sol` property
> contracts and the three `echidna*.yaml` configs are **non-functional** and are
> **not run in CI**.

## Why they don't run

Every property contract imports contract paths that were **deleted** in the
V3→V5 refactor:

| File | Dead import |
|---|---|
| `SuperPaymasterV2Invariants.sol` | `src/paymasters/superpaymaster/v2/SuperPaymasterV2_3.sol` |
| `GTokenStakingInvariants.sol` / `GTokenStakingProperties.sol` | `src/paymasters/v2/core/GTokenStaking.sol` |
| `MySBT_v2_4_0_Invariants.sol` | `src/paymasters/v2/tokens/MySBT_v2.4.0.sol` |
| `IntegrationInvariants.sol` | all of the above |

`contracts/src/paymasters/v2/` no longer exists, so `echidna . --config
echidna.yaml` (and the long-run / all-contracts variants) fail at compile time.

The properties themselves target a **V2 storage model that no longer exists**
(e.g. `lockedAmount`, `stakedAt`, `consecutiveDays`, per-operator
`exchangeRate`). They cannot be ported 1:1 — the data model changed.

## Decision: rewrite as forge invariants (NOT port to echidna)

The surviving, still-meaningful properties have been **re-expressed as native
`forge` invariant/fuzz tests** under [`contracts/test/invariant/`](../test/invariant/),
which run in the normal `forge test` CI with no extra toolchain:

| Old echidna property (intent) | New forge test |
|---|---|
| balances never go negative / accounting stays consistent | `SuperPaymasterFundConservation.invariant.t.sol` → `invariant_trackedBalanceEqualsSum`, `invariant_solvency` |
| exchange-rate / settlement math stays bounded | `XPNTsDebtRepay.invariant.t.sol` → `invariant_noOverBurnOnMint`, `testFuzz_repayNeverExceedsValue` |
| op/tx counters monotonic, no double-processing | `XPNTsOpHashReplay.invariant.t.sol` → `invariant_opHashSettledAtMostOnce` |

Forge invariants were chosen over repairing echidna because:
- they run in the existing `forge test` pipeline (no separate echidna binary,
  no `corpus/` management, no second compile profile);
- handler-based forge invariants drive the *real* V5.3 contracts directly,
  whereas the echidna files would need a full rewrite against the new model
  anyway — at which point forge is the lower-friction target.

## If you still want echidna later

Echidna can complement (not replace) the forge suite for deep, long-horizon
campaigns. To revive it you must:
1. Delete or rewrite the five `*.sol` files against current `contracts/src/`
   contracts (V5.3 storage layout).
2. Point the property contracts at `GTokenStaking`, `xPNTsToken`,
   `SuperPaymaster` (UUPS proxy), `Registry`, `MySBT` as they exist today.
3. Re-target the `corpusDir` paths and re-check `solcArgs` against
   `foundry.toml` (`via_ir`, `optimizer-runs 500`, Cancun).

Until then these files are kept (not deleted) only as a historical reference for
the property *intent*.
