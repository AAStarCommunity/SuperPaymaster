# RR-5 / G-1 — exact `PostOpGasTooLow()` guard-fail

The test file is `contracts/test/v2/SuperPaymasterRR5GuardFail.t.sol`. It contains two suites, BALANCE and CREDIT,
with 5 tests each. Both use the deployment tuple `440000 / 420000 / 5000 / 340000` via `DeploymentGasFixtures`.
Evidence comes from `script/evidence/rr5-guard-fail-run.sh run/`, executed at the commit in `run/head.txt`. Logs and
the verdict are in `run/`; hashes are in `run/SHA256SUMS`.

## What each test asserts

| test | asserts |
|---|---|
| `test_RR5_exactSelector_adjacentBoundary` | Binary search over postOp call gas. Every failure must be **exactly** `abi.encodeWithSelector(PostOpGasTooLow.selector)` (not a bare OOG), with state still pending. Every success must fully settle. The adjacent pair `lo`/`lo+1` is asserted on both sides. |
| `test_RR5_snapshot_not_live_bound` | The live settle bound is raised to 1,000,000 after validation. A 600k call must still settle, because the guard reads the validation snapshot, not the live bound. |
| `test_RR5_guardFail_staleRecovery` | After a guard-fail, the lock (BALANCE) or credit reservation (CREDIT) is still held and nothing is settled: `usedOpHashes` false, revenue, supply and debt unchanged. Then `releaseStaleLock`/`releaseStaleCredit` and `releaseStaleSponsorship` restore user balance and operator a0 and clear every record. Calling both release paths a second time changes nothing. |
| `test_RR5_realEntryPoint_minimum_negativeControl` | Through the real EntryPoint v0.7 runtime, postOp limit = MIN_POST: the op settles, no `PostOpRevertReason` is emitted, the target executes, and the deposit drops by exactly `actualGasCost`. In the CREDIT suite the account has **no balance**, so the op settles through credit (a debt is recorded and the reservation is cleared). In the BALANCE suite tokens are burned and no debt is recorded. |
| `test_RR5_diag_scan_band` | Diagnostic, no assertion. It classifies every call gas from SETTLE to 900k in 2k steps as guard-fail, non-guard failure, or settled. |

**Real EntryPoint boundary.** With deployment params MIN_POST ≥ SETTLE + 20k, the guard cannot be reached through
the real EntryPoint. A previous-release 352-byte context uses LEGACY_SETTLE = 160k, which is also below that minimum.
For that reason, the guard-fail and recovery assertions here are **direct calls** (pranked EntryPoint), and the real
EntryPoint test is a negative control. Neither guard-induced user rollback nor failure-path ETH charging is established by these tests. EntryPoint-level
rollback after a postOp revert in general is covered by `test_I8_settle_failure_rolls_back_user_execution_e2e` in
`SuperPaymasterV55.t.sol`.

## Results (`run/verdict.txt`)

| engine | result | guard boundary (call gas) | scan |
|---|---|---|---|
| forge 1.7.1 Cancun | 10/0/0 | last guard-fail 431,513 / first settle 431,514 (both modes) | guard ≤ 430k, settle from 432k, **no** non-guard failure |
| forge 1.7.1 Prague | 10/0/0 | same | same |
| nightly 4e8874b Amsterdam | **7 passed / 3 failed** | — | guard ≤ 438k. **Non-guard failure (OOG past the guard) 440k–632k CREDIT, 440k–568k BALANCE**. Settles from 634k / 570k. |

Mutations (stable Cancun):
- Deleting the guard turns 3 tests red in each suite: `exactSelector_adjacentBoundary`, `guardFail_staleRecovery`,
  `snapshot_not_live_bound`.
- Making the guard read `_gasParams.settleGasBound` instead of the snapshot turns `snapshot_not_live_bound` red.
- The source is restored afterwards (`restored; tree clean`).

## Open finding (Amsterdam) — not resolved here

On Amsterdam the guard admits the call, but the call then fails without the guard selector (empty revert data). The
scan shows this as a non-guard failure band. The B-1 property "a
postOp that passed the entry check completes" does **not** hold in this direct-call setup under the deployment
tuple. For one point, the CREDIT 600k call in `test_RR5_snapshot_not_live_bound`, the failure is located by a trace:
`run/amsterdam-credit-600k-trace.log`, summarised in `run/amsterdam-credit-600k-location.txt`. It shows
`[OutOfGas]` *after* `settleCredit` has returned (`CreditSettled` emitted), inside SP's own writes. The other band
points are classified only by their revert data and are **not** individually traced.

This conflicts with `nosubsidy-attribution/` (PR on `cc127/nosubsidy-attribution`): there, a postOp limit of
MIN_POST settles through the real EntryPoint with a net frame ≤ 389,218. Candidate causes, **not yet
distinguished**:
1. Amsterdam state-gas accounting depends on what the same transaction already did. In handleOps, validation and
   postOp share one transaction. Here the record is created, released and re-created around `vm.snapshot` /
   `vm.revertTo`, so the reservoir regime can differ.
2. A peak-versus-net effect. The −97,820 in-flight clear credit lands late in the frame, so the gas needed *during*
   the frame exceeds the net total.
3. A genuine B-1 violation for fresh SP state on Amsterdam.

Until this is attributed, no claim is made either way. Sepolia is on Amsterdam, so this matters for the final
gas tuple, which must be bound to the peak need, not the net frame.
