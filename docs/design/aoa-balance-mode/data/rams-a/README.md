# Route A rehearsal evidence

This directory preserves the Sepolia block 11,974,561 fork runs and their mutation logs. See [REVIEW-2.md](REVIEW-2.md) for the Review 2 and Review 3 finding maps. Review 3 revises the controls and mutation definitions; fork and mutation results below are historical Review 2 results, pending the owner’s Review 3 rerun. No production sources or deployment settings change.

## Current results (Review 3, clean tree, 2026-10-23)

| Item | Result | File |
|---|---|---|
| Fork rehearsal (nightly 926eb1d, `--hardfork amsterdam`, block 11,974,561) | **15/15 PASS** at 1ef98867, `Dirty paths: 0` | `rehearsal-20261023T075352Z-20644.log` |
| Mutations, 18 definitions `mutations-def4/` | **CONTROL 15/15 GREEN; M1–M18 all KILLED by their expected assertion** at fd2b5b5a | `mutations-run7/summary.tsv` |
| Preceding mutation attempt | M1–M15 KILLED; **M16–M18 PATCH-FAILED**. The generator reads the base from `git show HEAD:`, and the Review 3 definitions were generated before the edits were committed, so they targeted the old test. Regenerated at the committed HEAD (M1–M15 differ only in hunk line numbers) | `mutations-run6/summary.tsv` |
| Review 2 runs (superseded) | fork 15/15 at a65d8167; mutations M1–M16 KILLED at 3d41bd98 (`mutations-run5/`); M15 WRONG-ASSERTION in `mutations-run4/` (unconsumed prank, fixed); first Review 2 attempt failed at the Registry version guard (live is `Registry-5.8.0`) | `rehearsal-20261023T072628Z-81942.log`, `rehearsal-20261023T071827Z-7710.log` |
| Operator inventory rescan | endpoints labelled (by the operator, not verified) Alchemy and Tenderly public gateway agree: 4 `OperatorConfigured` logs, 2 operators. Code at creation−1 is `0x` on both; code at the creation block is non-empty on both (positive control) | `operator-inventory-11974561-review2.json` |
| Offline gates | results in that file | [review-3-offline-gates.log](review-3-offline-gates.log) |

Fork observations (from `rehearsal-20261023T075352Z-20644.log`):
- **Registry stop switch (H1b).** The live Registry owner and the `PAYMASTER_SUPER` role config owner are both OWNER EOA `0xb5600060…df0e`. A6c, same user: before the freeze, `registerRole(PAYMASTER_SUPER)` reverts with `RoleNotGranted(ROLE_COMMUNITY, user)`, because the prerequisite role is missing. After `configureRole(isActive=false)` by the live owner, it reverts with exactly `RoleNotConfigured(PAYMASTER_SUPER, false)`. The `isActive` gate runs before the prerequisite check, so it rejects every caller. This is shown by the change of revert. It is **not** shown with a fully qualified operator that succeeds before the freeze (no such fixture). M17 (freeze removed) fails at the post-freeze assertion. `safeMintForRole` is **source-checked (same `isActive` gate), not executed on the fork**. Holders who already have the role are **not** revoked.
- **Residual holders (H1b).** 3 existing `PAYMASTER_SUPER` holders are not configured SP operators, and the freeze does not stop them (see Registry section). This is an input to the ordering choice.
- **Safe-route gap (H1a).** A6b: under the Safe-owned timelock, an operator registered during the wait before the upgrade gets a real sponsorship. A timelock pause scheduled in the gap is rejected at the upgrade ETA with the exact `TimelockUnexpectedOperationState` payload. Pre-upgrade hours, computed from elapsed block time: 48. M18 (the upgrade batch also pauses the new operator) fails at "new operator sponsored in gap".
- **EOA-first ordering (H1c).** A6d: 0 pre-upgrade seconds, a structural consequence of the modeled ordering, not a measurement; 48h / 96h through gas activation. Safe route: 96h / 144h.
- **Settlement at MIN (M1).** A5c, real `handleOps`, logged: 439,999 is rejected with `AA34 signature error`; 440,000 and 440,001 are executed and settled. A5b's 438,786 / 174,659 are synthetic guard crossings, not settlement exhaustion. Of the 4,127 gap, the part equal to `ceil(260000·64/63)−260000` is consistent with EIP-150 forwarding, but this was not traced.
- **Inventory commitment (M4).** The A7 gate checks length and commitment separately. M16 keeps the length, swaps one member, and fails at "RAMS gate: inventory commitment".
- **Live Safe:** 0 modules, guard slot zero.

The historical clean-tree run at e704f1f5 used Foundry nightly 926eb1d, Amsterdam, `--no-isolate`, and `FOUNDRY_ISOLATE=false`. `rehearsal-20261023T064207Z-94221.log` records 10 passing route tests. `mutations-run3/summary.tsv` records 13 historical kills. Those results do not validate the revised tests or the historical 16 definitions in `mutations-def4/`. `mutations-run2/` keeps the previous 13 definitions with their logs; their headers and bytes remain historical evidence. `mutations-run1-INVALID/` remains invalid infrastructure evidence.

## Upgrade orderings and downtime

| Ordering | Before upgrade | After upgrade through gas activation | Total from first pause |
| --- | --- | --- | --- |
| A6 Safe timelock owns 5.4.2 before scheduling upgrade and queue | 48h | 48h parallel or 96h sequential | 96h or 144h |
| A6d EOA pauses all, directly upgrades with atomic global pause, queues parameters, then nominates timelock | 0h modeled | 48h parallel or 96h sequential | 48h or 96h |

Both orderings are documented without selecting one. Operational transaction inclusion and gate work add time. These totals end at gas activation; the tests leave global pause enabled. A subsequent unpause needs an authorized timelock transaction, so these are minimum service downtime figures, not measured times to restored service. An unpause batch can be scheduled in advance, but execution must follow the read-back gate. If scheduling waits for that gate, add another 48h.

In the Safe ordering, the EOA loses its ability to pause operators immediately after ownership transfer. A6b registers a new operator one hour into the modeled 48h wait, proves a valid sponsorship, then proves its timelocked pause is still unavailable at the earliest upgrade time. Re-enumerating additions cannot close this gap: each new pause also needs 48h. The sponsorship-stop guarantee begins at the atomic `upgradeToAndCall(newImpl, setGlobalPaused(true))`.

In the EOA-first ordering, the exposure window is the elapsed time between pause-all and inclusion of the direct EOA upgrade. A6d models these calls at one timestamp, logs zero pre-upgrade seconds, and executes a real Safe-scheduled batch accepting ownership and activating gas parameters after the wait. The EOA queues gas parameters immediately after upgrading while it is still owner. Separate real transactions can have a nonzero inclusion gap.

## Registry registration switch

The setup reads the Registry address from `sp.REGISTRY()` and checks `0xf5Bf37ca83AfdAab73691bA7eCcDfA69b8708E71`. **Correction (fork rerun):** the live Registry reports `Registry-5.8.0`, not 5.4.2; the first rerun failed at the setup version guard (`rehearsal-20261023T071827Z-7710.log`). 5.8.0 was introduced at `bb2610e8` and replaced at `dfdbf742`; at both ends `configureRole` (Registry owner or the role's config owner may write `RoleConfig`, including `isActive`), the `registerRole` `if (!config.isActive) revert RoleNotConfigured(...)` gate and the `RoleConfig` struct are identical to the v5.4.2 source Review 2 inspected. The guard now expects 5.8.0. Deployed-bytecode identity against a specific commit in that range is not checked.

`configureRole(bytes32,RoleConfig)` accepts either `Registry.owner()` or `getRoleConfig(roleId).owner`. Setting `isActive=false` for `keccak256("PAYMASTER_SUPER")` makes `registerRole` revert with `RoleNotConfigured(roleId,false)`. The earlier fork log records OWNER `0xb5600060e6de5E11D3636731964218E53caadf0E` as both authorities. The revised A6c logs both authorities and calls `registerRole` for the same user before freezing: a revert must have a selector other than `RoleNotConfigured`; a successful call must grant the role. It logs the outcome and rolls back that control before deactivating the role as Registry owner and checking the exact `RoleNotConfigured(roleId,false)` payload. The unrelated `configureOperator` assertion has been removed.

This switch blocks new role grants, **not existing ROLE_PAYMASTER_SUPER holders**. **Measured at block 11,974,561** (`super-holders-11974561.json`, script `script/evidence/rams-a-super-holders.py`): 5 `RoleRegistered(PAYMASTER_SUPER)` logs, 5 distinct users, `getRoleUserCount` = 5, all 5 hold the role. The enumeration is complete: in Registry-5.8.0, `roleMembers` is written only alongside `hasRole` and `RoleRegistered`. The two known operators are present (positive control). **3 holders are not configured SP operators**: `0x2e72a258…7b00`, `0x368f8cb8…5c94`, `0xf92dc383…9516`. After a Registry freeze, each of them can still call `configureOperator` during the pre-upgrade gap. A newly configured operator is unpaused, so it can be sponsored. On the Safe route that gap is ≥48h and the freeze does not close it. On the EOA-first route the gap is the interval between the pause-all transactions and the upgrade transaction. No Registry function that removes another address's role was found in the 5.8.0 source; `exitRole` is self-only. Increasing minStake is not a demonstrated stop, and no Registry-wide pause is claimed.

## Gas measurement scope

The historical A5b values 438,786 and 174,659 are synthetic callback success thresholds dominated by the `gasleft() < snapSettle` guard. They are not settlement exhaustion measurements. Inputs were `actualGasCost=100000`, `actualUserOpFeePerGas=1`, with `--no-isolate` and real reserved contexts.

Their difference is 264,127. The excess over the 260,000 SETTLE change is exactly the rounded EIP-150 scaling term: `ceil(260000 * 64 / 63) - 260000 = 4127`. Thus forwarding a 260k larger guard budget accounts numerically for the delta; a trace attribution of all per-call overhead remains unmeasured. A5b logs each guard-crossing threshold and its overhead rather than claiming a universal settlement bound. The **1,214 gas settlement-margin claim is withdrawn**. A5c adds real EntryPoint `handleOps` at postOp MIN−1 (439999, exact AA34 rejection), MIN (440000, execution and settlement), and MIN+1 (440001, execution and settlement). The historical Review 2 fork passed these boundaries (see Current results); Review 3 adds an outcome log for each boundary.

M5 still discriminates the wrong SETTLE tuple only at its read-back. The separate R-AMS-2a report records 365,325 balance and 369,624 credit gas for its own fixtures (`../rams-2a/REPORT.md`); those values are not this fixture's settlement bound.

## Inventory and assumptions

`isConfigured=true` has a single write site (v5.4.2:298). The archive scan covers the proxy's `OperatorConfigured(address,address,address)` events from block 11,151,016 through 11,974,561 and filters configured operators at the endpoint block.

The initial inventory JSON used **A** and **C** without a preserved provider mapping or creation positive control; those limitations apply to that historical file. The Review 2 rescan (`operator-inventory-11974561-review2.json`, Current results) preserves four logs, two operators, and creation−1/creation controls for both endpoints. Its provider identities are operator-supplied labels, not verified identities. Its `endpointLabels` and `generatedUTC` were added by hand after generation; the JSON now explicitly annotates that provenance.

`rams-a-inventory.sh` accepts `RAMS_RPC_A` and `RAMS_RPC_C`, never prints endpoints, checks code absence at creation−1 and nonempty code at creation, scans in chunks, and writes fresh JSON. It now emits `generatedUTC` and `endpointLabels`, using optional `RAMS_LABEL_A` / `RAMS_LABEL_C` names (default A/C), rejecting labels containing `://`. Labels do not verify provider identity. The scanner was not executed during the offline Review 3 edit.

A7 compares the submitted inventory hash against a separately captured setup commitment, and M16 replaces one member without changing either array’s length. Distinct length and commitment assertions ensure that only the inventory commitment kills M16. This catches changes to the gate input, but the archive inventory's completeness remains an external attestation. It does not discover unknown operators independently.

A3 counts only validation calls that actually return SIG_FAILURE with empty context. M14 disables upgrade read-backs while omitting atomic pause; M15 disables pause read-backs while skipping one pause. Their remaining validation probes must discriminate. See [MUTATIONS.md](MUTATIONS.md).

A6 reads all live Safe module pages and the standard guard storage slot on the fork. Threshold and owners are also checked. This is a snapshot inspection, not proof that a Safe transaction cannot be relayed through a UserOp or that future modules cannot change. Safe-authorized AA relay, modules, delegation, and concurrent governance remain operational assumptions. The timelock is locally deployed and Safe calls are impersonated; no real Safe signatures or executor operations are exercised.

R0 remains a runner assumption. Setup logs `block.gaslimit` and `2^24`; a contract cannot read the transaction gas limit, cap-enable flag, or starting reservoir. Block gas limit is not transaction gas limit. These logs alone do not prove R0 or RR behavior.

Fresh accounts, ETH and token balances, a $2000 oracle response, and synthetic-account credit mocks remain controlled fixtures. Live role checks, factory binding, pauses, validation, settlement, and upgrades are not mocked. A4's hypothetical smart-account owner upgrade strands the legacy validation debit and revenue increment (306 aPNTs in the historical fixture) despite execution rollback. The live EOA owner prevents that specific path; Safe relay exclusion remains an assumption.

## Evidence tooling

Both runners redact HTTP, HTTPS, WS, WSS, bare IP:port, and host:port or scheme-less `/v2/<key>` and `/v3/<key>` paths for common TLDs. Solidity locations such as `Registry.sol:526` remain visible. Headers print the effective isolation value and exclude their own output paths from dirty-file reporting while retaining all other dirty paths. The mutation runner refuses changes reported by `git status --porcelain -- contracts/src contracts/test foundry.toml`, obtains its baseline with `git show HEAD:<target>`, and restores it on exit.

The generator also reads its base from `git show HEAD:<target>`. For this edit-only Review 3 delivery, M1–M15 retain their HEAD definitions byte for byte; M16–M18 carry the revised assertion bodies they need, with diffs still applicable against HEAD. After the owner commits the reviewed tests, regenerate definitions against that baseline before executing the mutation runner. M17 removes the freeze and its early read-back so the exact post-freeze registration assertion must discriminate. M18 executes a mature upgrade-and-new-operator-pause batch before the gap probe so the distinct sponsorship-in-gap assertion must discriminate. No Review 3 fork or mutation kill result is claimed.
