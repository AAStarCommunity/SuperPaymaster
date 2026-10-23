# Route A rehearsal evidence

This directory preserves the Sepolia block 11,974,561 fork runs and their mutation logs. Review 2 changes are authored offline and have **not been rerun on a fork**. See [REVIEW-2.md](REVIEW-2.md) for the finding map. No production sources or deployment settings change.

The historical clean-tree run at e704f1f5 used Foundry nightly 926eb1d, Amsterdam, `--no-isolate`, and `FOUNDRY_ISOLATE=false`. `rehearsal-20261023T064207Z-94221.log` records 10 passing route tests. `mutations-run3/summary.tsv` records 13 historical kills. Those results do not validate the revised tests or the 16 current definitions in `mutations-def4/`. `mutations-run2/` keeps the previous 13 definitions with their logs; their headers and bytes remain historical evidence. `mutations-run1-INVALID/` remains invalid infrastructure evidence.

## Upgrade orderings and downtime

| Ordering | Before upgrade | After upgrade through gas activation | Total from first pause |
| --- | --- | --- | --- |
| A6 Safe timelock owns 5.4.2 before scheduling upgrade and queue | 48h | 48h parallel or 96h sequential | 96h or 144h |
| A6d EOA pauses all, directly upgrades with atomic global pause, queues parameters, then nominates timelock | 0h modeled | 48h parallel or 96h sequential | 48h or 96h |

Both orderings are documented without selecting one. Operational transaction inclusion and gate work add time. These totals end at gas activation; the tests leave global pause enabled. A subsequent unpause needs an authorized timelock transaction, so these are minimum service downtime figures, not measured times to restored service. An unpause batch can be scheduled in advance, but execution must follow the read-back gate. If scheduling waits for that gate, add another 48h.

In the Safe ordering, the EOA loses its ability to pause operators immediately after ownership transfer. A6b registers a new operator one hour into the modeled 48h wait, proves a valid sponsorship, then proves its timelocked pause is still unavailable at the earliest upgrade time. Re-enumerating additions cannot close this gap: each new pause also needs 48h. The sponsorship-stop guarantee begins at the atomic `upgradeToAndCall(newImpl, setGlobalPaused(true))`.

In the EOA-first ordering, the exposure window is the elapsed time between pause-all and inclusion of the direct EOA upgrade. A6d models these calls at one timestamp, logs zero pre-upgrade seconds, and executes a real Safe-scheduled batch accepting ownership and activating gas parameters after the wait. The EOA queues gas parameters immediately after upgrading while it is still owner. Separate real transactions can have a nonzero inclusion gap.

## Registry registration switch

The setup reads the Registry address from `sp.REGISTRY()` and checks `0xf5Bf37ca83AfdAab73691bA7eCcDfA69b8708E71`. Inspected source: `git show v5.4.2:contracts/src/core/Registry.sol`, version `Registry-5.4.2`, `configureRole` lines 377–388 and `registerRole` lines 245–251. Setup now logs and checks the live version; a mismatch requires source review before accepting this result. No RPC was used to confirm the version in Review 2.

`configureRole(bytes32,RoleConfig)` accepts either `Registry.owner()` or `getRoleConfig(roleId).owner`. Setting `isActive=false` for `keccak256("PAYMASTER_SUPER")` makes `registerRole` revert with `RoleNotConfigured(roleId,false)`. The earlier fork log records OWNER `0xb5600060e6de5E11D3636731964218E53caadf0E` as both authorities. A6c logs them again, deactivates the role as Registry owner, verifies the grant fails, and verifies the unregistered address cannot call `configureOperator`.

This switch blocks new role grants, **not existing ROLE_PAYMASTER_SUPER holders**. Existing holders can still configure a new operator. Full coverage requires independently enumerating those holders and confirming they are already configured and paused, or another reviewed control. Increasing minStake is not a demonstrated stop and no Registry-wide pause is claimed. The switch's availability and authority must be confirmed on the pinned fork.

## Gas measurement scope

The historical A5b values 438,786 and 174,659 are synthetic callback success thresholds dominated by the `gasleft() < snapSettle` guard. They are not settlement exhaustion measurements. Inputs were `actualGasCost=100000`, `actualUserOpFeePerGas=1`, with `--no-isolate` and real reserved contexts.

Their difference is 264,127. The excess over the 260,000 SETTLE change is exactly the rounded EIP-150 scaling term: `ceil(260000 * 64 / 63) - 260000 = 4127`. Thus forwarding a 260k larger guard budget accounts numerically for the delta; a trace attribution of all per-call overhead remains unmeasured. A5b logs each guard-crossing threshold and its overhead rather than claiming a universal settlement bound. The **1,214 gas settlement-margin claim is withdrawn**. A5c adds real EntryPoint `handleOps` at postOp MIN−1 (439999, exact AA34 rejection), MIN (440000, execution and settlement), and MIN+1 (440001, execution and settlement). Those fork checks await the owner's rerun.

M5 still discriminates the wrong SETTLE tuple only at its read-back. The separate R-AMS-2a report records 365,325 balance and 369,624 credit gas for its own fixtures (`../rams-2a/REPORT.md`); those values are not this fixture's settlement bound.

## Inventory and assumptions

`isConfigured=true` has a single write site (v5.4.2:298). The archive scan covers the proxy's `OperatorConfigured(address,address,address)` events from block 11,151,016 through 11,974,561 and filters configured operators at the endpoint block.

The historical JSON labels are **A** and **C**, with four logs and two operators each. The earlier narrative named Alchemy and Tenderly, but the preserved JSON does not establish which label maps to which provider. Provider identity is therefore unverified. `rams-a-inventory.sh` accepts `RAMS_RPC_A` and `RAMS_RPC_C`, never prints endpoints, checks code absence at creation−1 **and nonempty code at creation**, scans in chunks, and writes fresh JSON even if the output is missing. It was not run in Review 2. The old JSON's `codeAtFromMinus1: "0x"` has no preserved creation positive control; it cannot independently establish the deployment boundary until rerun.

A7 compares the submitted inventory hash against a separately captured setup commitment, and M16 omits one operator. This catches changes to the gate input, but the archive inventory's completeness remains an external attestation. It does not discover unknown operators independently.

A3 counts only validation calls that actually return SIG_FAILURE with empty context. M14 disables upgrade read-backs while omitting atomic pause; M15 disables pause read-backs while skipping one pause. Their remaining validation probes must discriminate. See [MUTATIONS.md](MUTATIONS.md).

A6 reads all live Safe module pages and the standard guard storage slot on the fork. Threshold and owners are also checked. This is a snapshot inspection, not proof that a Safe transaction cannot be relayed through a UserOp or that future modules cannot change. Safe-authorized AA relay, modules, delegation, and concurrent governance remain operational assumptions. The timelock is locally deployed and Safe calls are impersonated; no real Safe signatures or executor operations are exercised.

R0 remains a runner assumption. Setup logs `block.gaslimit` and `2^24`; a contract cannot read the transaction gas limit, cap-enable flag, or starting reservoir. Block gas limit is not transaction gas limit. These logs alone do not prove R0 or RR behavior.

Fresh accounts, ETH and token balances, a $2000 oracle response, and synthetic-account credit mocks remain controlled fixtures. Live role checks, factory binding, pauses, validation, settlement, and upgrades are not mocked. A4's hypothetical smart-account owner upgrade strands the legacy validation debit and revenue increment (306 aPNTs in the historical fixture) despite execution rollback. The live EOA owner prevents that specific path; Safe relay exclusion remains an assumption.

## Evidence tooling

Both runners redact HTTP, HTTPS, WS, WSS and bare host:port forms. Headers print the effective isolation value and exclude their own output paths from dirty-file reporting while retaining all other dirty paths. The mutation runner refuses a rehearsal target that differs from HEAD, obtains its baseline with `git show HEAD:<target>`, and restores it on exit. Review 2 is intentionally uncommitted, so the mutation runner must refuse this tree until the owner establishes a committed baseline.
