Audit completed read-only at commit `053117cc8ca31eb69ae1f62755a1d7790e71190f`.

## New findings

No new security findings were identified in target (b).

## Confirmations of known/disclosed items

### K-1 — Medium — Role owners can rewrite admission and exit policy

- **Location:** [Registry.sol:497](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/core/Registry.sol:497), enforcement at [Registry.sol:333](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/core/Registry.sol:333) and [Registry.sol:424](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/core/Registry.sol:424).
- **Precondition:** Control of the Registry owner or the applicable `RoleConfig.owner`.
- **Call sequence:** Read the role row → call `configureRole(roleId, config)` with lowered `minStake`/`roleLockDuration`, or an extremely large lock duration → new users register under the weakened policy, or existing users call `exitRole`.
- **Impact:** A privileged caller can remove stake requirements, change fees and activity state, transfer role ownership, shorten locks, or extend existing members’ locks. A near-maximum duration can also make `lockedAt + lockDuration` overflow and prevent exit until governance corrects the configuration.
- **5.5.0 reachability:** **Yes**, through the known deployer-held Registry/role-owner privileges. This is the previously disclosed broad `configureRole` authority, not a new finding.
- **Minimal fix:** Give sensitive fields separate bounded setters; snapshot exit deadlines per lock instead of consulting mutable policy at exit; route admission/lock changes through the intended timelock.

### K-2 — Low — Pre-rotation reputation authorizations remain valid on the direct source route

- **Location:** [Registry.sol:574](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/core/Registry.sol:574), domain construction at [Registry.sol:547](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/core/Registry.sol:547).
- **Precondition:** A valid, unused reputation proof was signed before a DVT rotation; the caller can invoke an authorized source such as `ReputationSystem`.
- **Call sequence:** Rotate DVT without changing the retained aggregator/Registry domain → call `ReputationSystem.syncToRegistry(...)` with the old matching proof → it calls `batchUpdateGlobalReputation`.
- **Impact:** The old authorization can still apply a bounded ±100 reputation change and corresponding credit-tier movement despite the aggregator-routed proposal floor.
- **5.5.0 reachability:** **Yes**. Explicitly disclosed in `rc8-daybreak-fixes.md`; source gating, epoch progression, proposal replay protection, and credit caps still apply.
- **Minimal fix:** Add a Registry-side reputation generation/floor to the signed preimage and increment it on DVT rotation.

### K-3 — Low — Next-nonce blacklist proof survives DVT rotation

- **Location:** [Registry.sol:663](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/core/Registry.sol:663), nonce binding at [Registry.sol:676](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/core/Registry.sol:676).
- **Precondition:** An unused valid proof exists for `blacklistNonce + 1`, and the retained aggregator executes the call after rotation.
- **Call sequence:** Sign the next blacklist action → rotate DVT without changing the Registry BLS domain → aggregator invokes `updateOperatorBlacklist` → Registry increments the nonce, verifies the old proof, and forwards the statuses.
- **Impact:** Users can be blocked or unblocked using a pre-rotation authorization. No funds move.
- **5.5.0 reachability:** **Yes**. This is the explicitly disclosed blacklist residual.
- **Minimal fix:** Bind a rotation generation to blacklist proofs, or invalidate the blacklist nonce/domain during rotation.

### K-4 — Info — Credit exposure is exact only for the governance-declared population

- **Location:** [Registry.sol:832](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/core/Registry.sol:832), accounting at [Registry.sol:617](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/core/Registry.sol:617) and [Registry.sol:654](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/core/Registry.sol:654).
- **Precondition:** Governance invalidates/reseeds the population but omits an existing above-floor user and supplies an `expectedPopulationTotal` matching the incomplete list.
- **Call sequence:** Change an active credit tier or threshold → population becomes unseeded → call `seedCreditPopulation(incompleteUsers, incompleteCount, true)` → future reputation proposals resume.
- **Impact:** `totalCreditExposure` understates outstanding above-floor credit until an omitted user is touched by a later proposal and backfilled. This is documented directly in the contract and remains an operator-roster trust assumption.
- **5.5.0 reachability:** **Yes**, but only through owner-controlled seeding; the ordinary proposal delta arithmetic and backfill logic were internally consistent.
- **Minimal fix:** Maintain an enumerable reputation population from inception. For legacy migration, bind finalization to a reviewed manifest/Merkle commitment rather than a count supplied by the same caller.

## Controls verified

- Initialization atomically grants Registry ownership, all seven `RoleConfig.owner` values, and temporary reputation-source status to `_owner`. `DeployLive` subsequently authorizes exactly ReputationSystem and BLSAggregator and revokes the deployer source at [DeployLive.s.sol:430](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/script/v3/DeployLive.s.sol:430). The proxy is constructed with initialization calldata, so the deployment path exposes no separate initialization transaction.
- `markProposalExecuted` is aggregator-only at [Registry.sol:693](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/core/Registry.sol:693). Generic BLS execution denies that selector. Repeated marking is idempotent; arbitrary users cannot consume IDs.
- `Ownable2StepNamespaced` uses the correctly derived ERC-7201 slot, clears nominations on every ownership change, disables renunciation, and `_authorizeUpgrade` requires both current ownership and no pending nominee at [Registry.sol:1012](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/core/Registry.sol:1012).
- The current Prague artifact’s Registry source hash exactly matches the audited source. Its 34-entry layout equals the pinned 32-entry deployed snapshot plus only `pendingSBTBurn@31` and `pendingMembershipCleanup@32`; the gap moves to slot 33 with 41 slots, preserving end slot 74. The layout comparator returned no differences, and its read-only self-test rejected all nine mutations.
- No files were modified. Forge compilation/tests were not rerun because this environment’s filesystem policy prevented build/cache writes; existing source-matched artifacts were used for the storage verification.

**Counts — NEW: Critical 0, High 0, Medium 0, Low 0, Info 0; confirmed known/disclosed: Medium 1, Low 2, Info 1.**