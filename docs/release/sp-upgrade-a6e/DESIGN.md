# CC-125 Safe A6e upgrade design

Status: implementation for offline review. The owner resolved the Phase 1 questions and authorized Phase 2. No fork was contacted during authoring. Runtime plan and simulation records must supply the dynamic evidence. All output remains unsigned; sign and send refuse with rc=3.

## Evidence and candidate identity

The owner supplies DSR ruling `d6d67a51` as selecting Safe A6e and retaining the earlier choices ("旧选择保留"). The ruling is attributed to the owner's task clarification; no network lookup was performed. The repository's [authorization record](../a3a-packets-RAMS-INVALIDATION.md#授权记录) independently records the author's 2026-10-22 answer `1=A，2=A，3=A` and CC-125 `cfa29193`.

The local annotated `v5.5.0-rc.4` tag peels to `fbd74fb1e2e9d948996e6d6c02c48dc1c1778107`. HEAD is `2536c1e1fb1131499fec43ceecaa0ac2f1d50505`. Local `git diff v5.5.0-rc.4 HEAD -- contracts/src contracts/script foundry.toml` is empty. This establishes equality for those paths, not a completed archive rebuild. No later 5.5 tag exists locally.

Sources:

- [Route rehearsal](../../../contracts/test/rams/RamsARouteRehearsal.t.sol). Its A6, A6b, A6c, A6d, A6e, and A7 tests define the governance model and read-back gate.
- `contracts/test/rams/RamsAHelpers.sol` defines the Registry and Safe interfaces and compiler-derived storage probe.
- [RAMS runbook](../../design/aoa-balance-mode/data/rams-a/README.md) records the assumptions and measured fork results at block 11,974,561.
- [rc.4 attestation](../v5.5.0-rc.4-attestation.md) records release identity and artifact scope.
- `contracts/script/v3/UpgradeToV5_5_0.s.sol`, `_step5_upgradeSP`, deploys the SP implementation by profile.default artifact with the old implementation's immutable bindings.
- `script/a3a/a3a_exec.py` supplies the reviewed execution infrastructure to import in Phase 2.

## Resolved choices and gated A3a prerequisite

Option A is selected. SP must use the same canonical shared TimelockController as A3a S2, `0xCCdF8e0D29Fb2c3061910D79484a2b653757C34B`. This follows the author's `1=A，2=A，3=A` in the [authorization record](../a3a-packets-RAMS-INVALIDATION.md#授权记录), CC-125 `cfa29193`, and the owner's supplied DSR `d6d67a51` statement retaining those choices. The older [choice sheet](../a3a-precheck-v4/AUTHOR-CHOICES.md) describes the options; the later answer selects A. The old go covered its old packet only and does not authorize this package's signing or transmission.

A3a has not executed. The selected address is therefore not claimed as deployed. Live `plan` fails unless code exists at the pin, its runtime matches the fresh candidate rebuild with value-checked immutables, and `getMinDelay()` is 172800. Role sets must be exactly PROPOSER, EXECUTOR, CANCELLER = {Safe}, DEFAULT_ADMIN = {timelock}. Creation input is checked against the fresh TimelockController initcode and exact constructor arguments to exclude silent constructor role writes. Reconcile the complete role history and check live membership and role admins.

Require A3a S6 and S7 at the pin: APNTsCapped owner equals the timelock, and SP pendingAPNTsToken equals A3a's APNTsCapped. Require the SP owner to remain the deployer EOA. A3a S7 must occur before step 4 because `setAPNTsToken` is owner-only. The upgrade package never deploys another timelock.

The operator selects the live pin with `plan --block`. Every dynamic field is read at that pin, including all sender nonces and balances, Safe nonce and owners, threshold, modules, guard, code, pending operations, holders, and historical configured addresses. Two read-only archive views must agree. Historical values below explain the source evidence and are not runtime defaults.

Before A3a executes live, `simulate --a3a-plan` imports and calls the frozen A3a rehearsal and uses its continuation to keep the same authenticated engine open. The upgrade plan is derived from the resulting fork state. This bootstrap run writes an unsigned plan; an independent `simulate --a3a-plan --plan` replays A3a and re-derives that plan before executing it. Both phases are recorded. A live `plan` never fabricates deployed A3a state to bypass its gate.

A bootstrap plan is bound to the A3a input hash and original pin, with a separate post-A3a state block, hash, and timestamp. A live plan has no bootstrap hash and binds directly to its operator-selected pin. These plans describe different nonce timelines and are not interchangeable. The combined simulation interface accepts the bootstrap plan. After A3a executes live, generate a new live plan from the actual chain state for review.

## Deployments and upgrade call

For the SP implementation swap alone, exactly one top-level CREATE deploys `SuperPaymaster(IEntryPoint,IRegistry,address)`. Its constructor creates exactly one `SuperPaymasterAdmin` extension with the same three arguments. Do not deploy another extension separately. `SuperPaymaster.EXTENSION` binds that address immutably.

The historical bindings, also present in `deployments/config.sepolia.json` and the RAMS fixture, are:

| Argument | Historical value | Required verification |
|---|---|---|
| entryPoint | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | Read `entryPoint()` on the pinned live SP and new implementation |
| registry | `0xf5Bf37ca83AfdAab73691bA7eCcDfA69b8708E71` | Read `REGISTRY()` on both |
| feed | `0x694AA1769357215DE4FAC081bf1f309aDC325306` | Read `ETH_USD_PRICE_FEED()` on both |

The SP proxy is `0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9`. The upgrade payload is `abi.encodeWithSignature("upgradeToAndCall(address,bytes)", newImpl, abi.encodeWithSignature("setGlobalPaused(bool)", true))`. Do not use the release script's empty upgrade payload. No reinitializer or new proxy is required.

The broader release script also provisions a V2 token stack. Those deployments are not prerequisites for this paused SP-only endpoint in A6e, and this package does not restore service or migrate operators. No additional governance deployment belongs to this package. A3a deploys the timelock using `TimelockController(172800, [Safe], [Safe], address(0))`.

## Live authorities and trust precondition

The historical RAMS setup asserts SP owner `0xb5600060e6de5E11D3636731964218E53caadf0E`. The run log `rehearsal-20261023T084836Z-51573.log` records that address as both Registry owner and PAYMASTER_SUPER configuration owner. These are historical observations, not fresh reads.

The Safe is `0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114`. RAMS asserts three owners and threshold two. A3a checks the exact owners against its archived snapshot and uses approver `0x8c3499252232105a1615767c459db9bbbf1273d6` and executor `0x871608cba092105b91e91295a1d79ffc539bfb48`. Re-read the complete owner set rather than inferring it from these two addresses. The deployer EOA is not assumed to be the third Safe owner. Check code for every current owner plus the deployer.

`configureRole` accepts either Registry owner or the role configuration owner. Both authorities must agree not to reopen registration. Before every step after the freeze, `pre_send` must re-read both owners and the complete role configuration, require the approved authority addresses, and require `isActive == false`. Reopening registration causes FAILURE and invalidates the holder enumeration and remaining plan.

## Ordered steps and nonce requirements

Let D, A, E be fresh pending transaction nonces for deployer, approver, and executor, and S be the Safe nonce. The runtime plan assigns numeric nonces from its pinned observations. Every mined transaction consumes its sender's nonce. Each successful Safe `execTransaction` consumes exactly one Safe nonce. `approveHash` consumes the approver EOA nonce without changing S. The executor binds all numeric nonces after verifying the prerequisites.

| Order | Signer or caller | Target and calldata | Nonce plan | Read-back |
|---|---|---|---|---|
| Prerequisite | Deployer | CREATE SP implementation with the three verified immutables | Fresh D; extension CREATE is internal | Both runtimes and immutables, EXTENSION, version, archive build identity |
| 1 | Registry-authorized EOA | Registry `configureRole(SUPER, originalConfig with isActive=false)` | Next D | Complete config preserved except isActive; both authorities |
| 2 | Read-only | Enumerate holders after the freeze | None | Unique live holders equal `getRoleUserCount(SUPER)` |
| 3 | SP owner EOA | SP `setOperatorPaused(address,true)` separately for every union member | Consecutive D, serial receipts | Each operator pause bit; freeze remains false |
| 4 | SP owner EOA | SP `transferOwnership(approvedTimelock)` | Next D | Owner equals timelock. Live 5.4.2 is one-step transfer per A6 |
| 5a | Safe approver, then executor | Safe approval and transaction calling timelock `scheduleBatch` for upgrade plus gas queue | Next A and E; Safe S | Safe hash, approval, nonce, operation id and ETA |
| Wait | None | External timelock delay at least 172800 seconds | None | Operation Ready at approved block time |
| 5b and 6a | Safe approver, then executor | Safe transaction calling timelock `executeBatch`; SP upgrade with atomic global pause, then `queueGasParams(440000,420000,5000,340000)` | Next A and E; Safe S+1 | Implementation and extension runtime; global pause; queued tuple and ETA; operation Done |
| 6b | None | Wait for internal gas ETA | None | At least 172800 seconds after queue |
| 6c | Safe approver, then executor | Safe transaction calling timelock `schedule(SP,0,executeGasParams(),upgradeOperationId,activationSalt,172800)` | Next A and E; Safe S+2 | Activation operation id, predecessor, salt, ETA |
| Wait | None | External activation delay at least 172800 seconds | None | Activation Ready, predecessor Done, internal ETA reached |
| 6d | Safe approver, then executor | Safe transaction calling timelock `execute` with the exact scheduled activation fields | Next A and E; Safe S+3 | Active tuple and cleared pending tuple; activation Done |
| 7 | Read-only | Pre-restore gate | None | All conditions below |

The sequential sequence retains both governance waits and never runs batches in parallel. The rehearsal's 96h and 144h values are model lower bounds to gas activation. Its 96h path overlaps the internal and external activation waits. This package's proposed serial path uses the 144h model lower bound, plus inclusion and verification time. Neither figure includes service restoration.

## Holder and historical operator enumeration

`script/evidence/rams-a-super-holders.py` scans Registry `RoleRegistered` events from its creation boundary, filters `hasRole`, and reconciles with `getRoleUserCount`. Its creation−1 and creation code checks are required. Repeat the scan after the freeze, not before it.

`script/evidence/rams-a-inventory.sh` scans SP `OperatorConfigured` events from creation block 11,151,016 with two-endpoint agreement. Its output `operators` filters current configured entries. The A6e pause set must instead retain every historical event address, including an address that later exits its Registry role. The executor consumes all raw event addresses and take their union with the post-freeze holders. Require complete chunk coverage, unique log identities, endpoint agreement, and creation boundary controls. The historical set contains five holders and two configured operators, but those counts are not constants for a new plan.

## safeMintForRole controls

The current Registry source checks active configuration before duplicate membership, sponsor COMMUNITY membership, recipient prerequisites, and stake processing. The live historical Registry version is 5.8.0; current source alone does not establish deployed bytecode identity.

On an authenticated isolated fork, choose an existing COMMUNITY sponsor and a recipient with the required COMMUNITY prerequisite who lacks SUPER. Fund and approve stake only as explicit fork fixtures. Before freezing, execute `safeMintForRole(SUPER,user,data)` and require success and membership. Roll back the control. Freeze, repeat the identical call, and require the complete `RoleNotConfigured(SUPER,false)` revert payload. Require no membership, stake, or nonce leakage after snapshot restoration. The RAMS README explicitly says this entry point was source-checked only. No positive or negative result is claimed here.

## Safe call chain and timelock operations

Import A3a's calldata, hashing, RPC, nonce, receipt, and negative-control helpers. Use one owner's `approveHash`, then a different owner's `execTransaction`, with the two approved-hash signature records sorted by numeric address as A3a does. Check each Safe transaction hash against on-chain `getTransactionHash` with all transaction fields and its exact Safe nonce. Require success events, approval state, EOA nonces, and Safe nonce after execution.

For both scheduling and execution, bind target arrays, values, payloads, salt, and predecessor into the plan. Independently compare local operation hashes with `hashOperationBatch` or `hashOperation`. The activation predecessor is the completed upgrade-and-queue batch. Salts are derived from the route, original pinned block hash, predicted implementation address, and operation purpose. Operation hashes and Safe hashes are independently recomputed and compared with on-chain getters before each Safe call.

## Modules, guard, delegation, and pending batches

Enumerate every `getModulesPaginated` page from sentinel address 1. Detect cursor cycles and duplicates. Read guard slot `0x4a204f620c8c5ccdca3fd54d003badd85ba500436a431f0cbda4f558c93c34c8`. Require the reviewed module list and guard; the historical RAMS values are empty and zero.

Read Safe runtime and `eth_getCode` for every owner EOA, including the deployer. Reject EIP-7702 delegation and unexpected code. Safe is a contract, so it must match its reviewed runtime rather than an empty-code rule.

Scan the selected timelock from its verified creation boundary through the pin for `CallScheduled`, `CallExecuted`, and `Cancelled`. Reconcile events in chain order, including cancellation and rescheduling of the same id. Query operation state and timestamp for surviving operations. Unknown or conflicting outstanding batches fail the gate. Recheck before each dependent step.

## Same-bundle risk

A4's hypothetical smart-account owner performs an upgrade inside an ERC-4337 bundle. The historical fixture strands 306 aPNTs of legacy validation debit and revenue despite execution rollback. Atomic global pause alone does not repair prior legacy reservations.

A6 restricts timelock execution to the Safe and rejects arbitrary account callers. This blocks the demonstrated direct smart-account executor. It does not prove that a Safe-authorized AA relay, a future module, delegation, or another authorized governance transaction cannot place Safe execution inside a bundle. Empty modules and a zero guard are snapshot observations. Execute each Safe governance transaction as a standalone top-level transaction outside `handleOps`, and exclude concurrent module, owner, delegation, or governance changes operationally. A fork trace must confirm the actual proposed call chain.

## Failure recovery

| Step | Required recovery behavior |
|---|---|
| Deployment prerequisite | Fail on artifact or immutable mismatch. Do not transfer ownership. Regenerate addresses and nonces if another deployment is required. |
| Freeze | Failed read-back stops all subsequent work. A changed authority or reopened config invalidates the enumeration and plan. |
| Enumeration | Missing chunks or a count mismatch stops the plan while the freeze remains in force. Obtain a new complete scan. |
| Operator pause | Failed pause read-back stops before ownership transfer. Re-read every pause and rebuild the remaining plan with current nonces. |
| Ownership transfer | Determine actual owner from chain. If transfer completed, the EOA cannot repair SP directly. Recovery must follow the timelock and Safe delay. |
| Upgrade schedule | Failed Safe execution does not imply scheduling succeeded. Read Safe nonce, operation state, and logs. Cancel an unwanted operation through the Safe, verify Unset, and reschedule with a new reviewed salt. |
| Upgrade execution | Failed batch must preserve the old implementation atomically. Verify implementation, queue, pause, and operation state before rebuilding. |
| Gas queue and activation | Keep global pause. An early execution must revert. A wrong tuple requires a separately authorized cancel/requeue and full waits. |
| Read-back gate | Preserve all pauses. Diagnose the failed field and require a new verified plan for corrective writes. |

The simulation executes both the failed-pause read-back control and Safe cancellation/rescheduling control on the fork, verifies the expected failures, and restores snapshots. Historical controls are not proof that this package passed.

## Pre-restore read-back gate

Require active gas tuple `(440000,420000,5000,340000)`, an empty pending queue, the approved owner and guardian, and `paused() == true`. Read ERC-1967 implementation slot `0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc`. Verify implementation and extension runtimes against fresh archive artifacts with immutable bindings. Require every union member paused, Registry freeze still active, unchanged Registry authorities, both operations Done, and no conflicting pending operations.

Unpause, Registry reactivation, guardian changes, and service restoration require a separate later package.

## Measured gas and CREATE reservoir policy

The first operator bootstrap passed A3a on 4e8874b, then failed the upgrade deploy's `pre_send_gas`: its estimate exceeded the old fixed 15,000,000 limit. That limit and the fixed limits for every other upgrade step are removed. Schema 2 starts with a transaction skeleton and freezes gas fields only after fork calibration. Old schema-1 upgrade plans must be regenerated.

For every step, record `estimateGas` from the archive RPC, `localEstimateGas` from the authenticated local engine, and `forkGasUsed` from a successful mined pilot. Archive estimation uses the original pin, cumulative state overrides from A3a and all completed upgrade transactions, and the planned execution timestamp. Thus the archive estimate observes the same prospective state as the local estimate. Snapshot trials do not enter that cumulative state.

The ordinary limit is `ceil(max(estimateGas, localEstimateGas, forkGasUsed) * 13 / 10)`. Every CREATE also records `minedGasMinimum`, and includes it in the same maximum. Other steps record a null minimum. Limits and sender budgets are recomputed from those measurements. No per-step fixed limit is a fallback.

### Mined minimum, not call success

The operator's RR matrix at branch `cc125/rr-matrix`, commit `00b9ee2968425cbad0efc09bd77e9ca9a777b38a`, contains `docs/design/aoa-balance-mode/data/rams-rr-matrix/REPORT.md` and `frame-calibration/nightly-4e8874b.json`. Those local git objects were read for this fix. The report states that `eth_call` and `eth_estimateGas` do not apply the EIP-8037 regular-gas cap. A successful call or estimate therefore cannot establish that an above-cap deploy succeeds when mined.

For every CREATE, execute snapshot trials on the authenticated fork. Each trial sends the exact planned transaction at gas g and the same timestamp, waits for its mined receipt, verifies the mined transaction identity, checks status, and reverts the snapshot. Nonces and Safe nonce must match their pre-trial values after restoration. Binary-search the success boundary to a one-gas interval. Start with a successful upper trial at 60,000,000; if that transaction fails, stop rather than claiming that a larger limit will help. The lower search bound respects intrinsic gas and the calldata floor to avoid treating an invalid RPC submission as a mined failure.

Record the minimum and the trial ledger of gas limits, transaction hashes, statuses, and gas used. The SP constructor also CREATEs the Admin extension, so this search applies even when estimates suggest a sub-cap deployment. A deterministic success boundary is assumed only for the fresh, fixed candidate creation code; a failed high trial never establishes a minimum.

At the proposed margin limit, mine another pilot and capture gas used. Recompute the margin if gas used raises the maximum. Require a stable limit within four pilots; otherwise fail. Revert every pilot before the actual package transaction. The final receipt must match the recorded gas used and timestamp.

### Narrow above-cap exception

A3a retains its default `GAS_CAP = 2^24`. The upgrade executor permits a final limit above that cap only when all these checks pass:

1. The transaction has no destination and is a top-level CREATE.
2. The measured mined minimum is strictly greater than `floor(2^24 * 10 / 13)`. This defines the requested `2^24 - margin` threshold using the same 30% headroom: `margin = 2^24 - floor(2^24 * 10 / 13)`.
3. A successful deploy's `debug_traceTransaction` first struct-log step has a nonzero `stateGasReservoir`. Record `rrRequired: true` and `rrWitness`, including engine commit, transaction hash, submitted limit, step index 0, PC, depth, regular gas, and reservoir. The witness must come from the top-level frame, match the planned limit and pinned engine, and fit within the excess over the regular cap.
4. The submitted limit is at most 100,000,000 and at most the block gas limit (checked on the fork at measurement time and again in `pre_send`), including the full 13/10 margin. Do not clamp a larger measured limit to the ceiling.
   The first ceiling, 60,000,000, had no basis and stopped the 2026-10-24 bootstrap: the SP implementation deploy needs 52,399,391 gas as a mined tx (estimate 52,811,426), i.e. 68,119,208 with the margin. Sepolia's block gas limit is about 200M, and txs above 100M are included (111,158,515 in the rams-rr scan).

Every other final transaction stays at or below 2^24, with `rrRequired: false` and a null witness. Exploratory high-gas CREATE trials are local snapshots only; they cannot become accepted package steps without the complete measured policy and witness. The shared A3a receipt/quantity helpers have explicit optional caps for those callers, while every existing A3a caller retains the original default. The 4e8874b pin and the operating-window teardown marker are unchanged.

This exception uses EIP-8037 as intended: the reservoir pays protocol state gas while regular execution gas remains capped. Real Sepolia transactions above 2^24 exist. The calibration file includes mined limits 27,071,391 and 49,977,564 with nonzero first-frame reservoirs, matched by 4e8874b. These are evidence of the protocol behavior, not measurements of this implementation's deployment need.

RR's ERC-4337 bundler-reimbursement concern applies to `handleOps`. A plain EOA-paid implementation CREATE has no `handleOps`, paymaster settlement, or bundler reimbursement. It still pays normal protocol transaction fees, including state gas. This policy does not authorize RR for Safe governance calls, operator pauses, or service restoration.

### Independent replay and pre-send checks

`pre_send` validates the measured limit, flag, CREATE restriction, witness, ceiling, and `planned gas >= recorded mined minimum` before checking the fresh estimate. A low estimate cannot override a higher mined requirement. Independent simulation binary-searches CREATE again before its actual send and requires the minimum and both estimates to equal the frozen measurements. It then checks final receipt gas used and the first-step witness against the frozen plan. A changed minimum fails even when the current estimate is below the planned limit.

Live `plan` remains read-only against both archive endpoints, but now starts an isolated fork to measure every proposed upgrade step. The bootstrap continuation receives A3a's cumulative archive overrides while staying on the same fork and relay. Plans and hashes are written only after all measurements, controls, budgets, and the final gate pass. No measurement, broadcast, or signing was performed against a public RPC while authoring this fix.

## Executor architecture

The new module must import helpers from `script/a3a/a3a_exec.py`, including `RPC`, `Gate`, `need`, `exact_keys`, `plan_json`, calldata/read helpers, archive rebuilding, `fork`, engine authentication, receipts, FAILURE recording, and negative controls where their interfaces apply. A3a's APNTs-specific plan and runtime assumptions require SP-specific validation around those helpers, not copied helper bodies.

`plan` reads pinned state and produces an unsigned record. Independent `simulate --plan` validates exact field sets and re-derives all transactions. Rebuild the selected committed candidate in a fresh git archive, including recorded submodules, without network. Bind artifacts and execution inputs to the reviewed plan hash. Use nightly `4e8874b2bdc840929585ca73e170993c50a4a531`, `--hardfork amsterdam --order fifo`, the loopback read-only relay, and A3a's `anvil_nodeInfo` and PID/port authentication. `pre_send` re-reads chain state for every step. `sign` and `send` refuse with rc=3. Every failed gate emits FAILURE.

Offline tests cover plan mutations, pinned scans, governance preconditions, Safe state, controls, and orchestration. CI runs them alongside the A3a suite using the same Python and Foundry pins. Offline test counts are reported in the executor README. Fork controls and successful archive simulation remain for the operator to run; no live result is asserted.
