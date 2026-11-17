# Daybreak-blue defensive audit

Scope: main commit `053117cc8ca31eb69ae1f62755a1d7790e71190f`, principally `BLSAggregator-4.14.1` and `DVTValidator-0.9.0`, including Registry, SuperPaymaster, GTokenStaking, and ReputationSystem call-outs.

Disclosure note: DVTValidator “rule A” was authored by Codex, the same model family as this reviewer. This review therefore independently re-traced the implementation but is not model-independent validation.

No files were modified, no network/RPC/secrets were accessed, and no Forge formatting or deployment command was run. `scripts/check_generic_selector_coverage.py` passed: 111 functions enumerated, 6 blocked, 20 allowed-with-reasons, 13 deployment grants mapped.

## NEW finding

### M-01 — A completed guardian exit does not retire its BLS seat or DVT admission

Severity: Medium

Locations:

- [BLSAggregator.sol:1861](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/modules/monitoring/BLSAggregator.sol:1861)
- [BLSAggregator.sol:1298](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/modules/monitoring/BLSAggregator.sol:1298)
- [DVTValidator.sol:296](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/modules/monitoring/DVTValidator.sol:296)
- [Registry.sol:359](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/core/Registry.sol:359)

Concrete precondition and call sequence:

1. A validator has `ROLE_DVT`, a live BLS slot, and `DVTValidator.isValidator[validator] == true`.
2. It calls `requestGuardianExit()`, waits through `readyAt + GUARDIAN_FRAUD_CHALLENGE`, then calls `Registry.exitRole(ROLE_DVT)`.
3. `consumeGuardianExit()` only deletes the exit notice. It neither revokes/suspends the BLS key nor clears DVT local admission.
4. Registry removes the role and unlocks the stake, temporarily making the slot ineligible.
5. The same address calls permissionless `Registry.registerRole(ROLE_DVT, ...)` again and supplies the required stake.
6. `_reconstructPkAgg()` now sees the old key as active, unsuspended, role-bearing, and adequately staked. `_requireActiveValidator()` also accepts the stale local admission.
7. The address can immediately propose and sign again without a fresh PoP, `addValidator`, owner approval, or enabling `permissionlessBLSRegistration`.

Impact:

A validator that has completed an exit can silently restore both proposer and signer powers. This bypasses the owner-curated key-registration switch and any intended post-exit re-admission process. It also leaves exited seats occupying scarce slots until governance explicitly revokes them.

This does not bypass an explicit `setSuspended`/`revokeAndSuspend`; a suspended validator remains excluded. The issue is that ordinary successful exit is not itself a signer-set removal.

Reachable in 5.5.0: Yes. Slash categories and `fraudProofVerifier` are irrelevant. It requires a previously admitted guardian, successful completion of the exit procedure, and enough GToken to register/stake for `ROLE_DVT` again.

Minimal fix:

On successful `consumeGuardianExit`, retire the active BLS registration while retaining the key-owner binding. To make re-admission explicitly owner-controlled, also suspend the guardian. If permissionless re-entry is desired instead, at minimum:

- revoke the active slot on consumed exit;
- require a fresh registration and PoP before the slot can vote again; and
- make `_requireActiveValidator` require an active BLS key or clear `DVTValidator.isValidator` through a coordinated callback.

Add a regression covering exit → role reacquisition and proving that neither proposal creation nor signature reconstruction succeeds before the chosen re-admission procedure.

## Generic `executeProposal` privilege inventory

The aggregator is not owner, role owner, operator, or DVT-role holder in the asserted 5.5.0 configuration. It is:

- SuperPaymaster’s configured BLS identity;
- Registry’s configured BLS identity and a reputation source;
- DVTValidator’s configured aggregator;
- indirectly accepted by ReputationSystem because Registry identifies it as a reputation source;
- not an authorized GTokenStaking slasher in 5.5.0.

| Contract / identity | Privileged function | Generic result |
|---|---|---|
| SuperPaymaster / `BLS_AGGREGATOR` | `queueSlash(address)` | Blocked by selector denylist |
| SuperPaymaster / `BLS_AGGREGATOR` | `executeSlashWithBLS(address,uint8,bytes)` | Blocked |
| SuperPaymaster / BLS or owner | `updatePriceDVT(int256,uint256,bytes,uint8)` | Allowed; freshness, monotonic timestamp, absolute bounds, and BLS ±20% cache band remain |
| Registry / reputation source | `batchUpdateGlobalReputation(...)` | Blocked |
| Registry / `blsAggregator` | `markProposalExecuted(uint256)` | Blocked |
| Registry / `blsAggregator` | `updateOperatorBlacklist(...)` | Allowed; performs its own default-threshold proof and nonce verification |
| GTokenStaking / authorized slasher | `slash(address,uint256,string)` | Blocked even if a future configuration grants the role |
| GTokenStaking / authorized slasher | `slashByDVT(address,bytes32,uint256,string)` | Blocked |
| DVTValidator / `BLS_AGGREGATOR` | `markProposalExecuted(uint256)` | Blocked |
| DVTValidator / authorized executor | `executeWithProof(...)` | Not denylisted, but re-entry into `verifyAndExecute` fails on `nonReentrant` |
| DVTValidator | `createProposal` / `queueSlashWithProof` | Aggregator lacks DVT role, stake, and local admission |
| DVTValidator | `registerBLSPublicKey` | Aggregator would have to register itself and satisfy permissionless role/stake/PoP checks; unreachable in asserted configuration |
| ReputationSystem / reputation source | `setCommunityReputation(...)` | Allowed; known unused-state residual |
| Arbitrary ERC-20 | `transfer` / `approve` | Allowed if the aggregator holds assets; known zero-balance deployment invariant |

Owner-only functions in these contracts remain unreachable because the aggregator is not their owner. Registry role-owner functions likewise remain unreachable because it owns no role. This matches the classification table.

The coverage script is appropriately treated as a source-text regression checker, not a complete authorization proof: aliases, inherited gates, new external targets, or fallback authorization could escape it.

## Reputation and queue ingress results

### DVT → `verifyAndExecute`

Confirmed controls:

- Current-DVT calls require `proposalId >= proposalFloor`.
- Reputation uses `defaultThreshold`.
- Slash uses the configured per-level threshold.
- Proposal shape comes from stored DVT fields.
- Pure reputation requires stored `(operator=0, level=0, evidenceHash=0)`, non-empty `repUsers`, and empty evidence.
- Slash requires a non-reputation stored shape, configured evidence category, accepted checker result, and exact stored evidence hash.
- Current signer role, stake, suspension, key activity, and matured exit status are rechecked at execution.

No rule-A bypass found on this ingress.

### `ReputationSystem.syncToRegistry` → Registry

Known/disclosed confirmation:

- [ReputationSystem.sol:194](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/modules/reputation/ReputationSystem.sol:194) derives a full-width hash proposal ID and calls Registry directly.
- Registry applies `defaultThreshold`, replay protection, per-user epoch progression, score clamping, and credit exposure caps.
- It has no `proposalFloor`; therefore unused pre-rotation proofs remain executable through this authorized source.

Reachable in 5.5.0: Yes.

Minimal containment if this residual is no longer accepted: add an aggregator-generation/floor component to the Registry proof domain or route all reputation updates through the current DVT executor.

### Owner-direct `verifyAndExecute`

Known/disclosed confirmation:

- Owner calls bypass `proposalFloor`.
- They still require the appropriate BLS threshold, current signer eligibility, and unused raw proposal ID.
- Slash shape and `evidenceHash` are caller-supplied rather than read from DVT storage; no DVT category checker runs.
- Reputation shape still enforces zero operator/level through the combined-shape guard.

Reachable in 5.5.0: Reputation is reachable; operator slash remains ineffective without a prior queue and, in disclosure-only configuration, the separate guardian-stake mechanism is disabled.

Minimal containment: if owner-mediated stale authorization or evidence bypass is no longer accepted, remove the owner entry or require owner calls to reference a stored DVT proposal at or above the floor.

### Queue paths

`DVTValidator.queueSlashWithProof`:

- Requires an active, eligible, unsuspended DVT validator.
- Requires a configured category and accepted evidence checker.
- Uses the per-severity slash threshold.
- Has no proposal ID/floor by design.
- The subsequent SuperPaymaster call enforces its BLS queue cooldown.

`BLSAggregator.queueSlashWithConsensus` owner path:

- Requires the same threshold and proof.
- Bypasses the DVT evidence-category check and proposal floor.
- Still encounters SuperPaymaster’s BLS cooldown because SuperPaymaster sees the aggregator as caller.

In 5.5.0, `categoryCount()==0` makes the DVT queue path unreachable. The owner path can consume an existing valid queue proof, but it moves no funds and is a disclosed reversible pre-flag. No new queue cooldown or threshold bypass was found.

## Signer-set integrity confirmations

- Registration is forwarded only by the current DVT, and both owner and permissionless paths require address/domain/key-bound PoP.
- Keys are validated for non-identity, curve membership, and subgroup membership.
- `blsKeyOwner` prevents the same public key from multiplying voting weight across addresses.
- Permissionless registration requires the caller to equal the validator plus live role/stake eligibility; suspension cannot be cleared through registration.
- Revocation clears the slot but retains the key-owner binding. `releaseKeyBinding` is owner-only and refuses a binding still used by an active registration.
- Verification rejects empty/out-of-range masks and rechecks active key, suspension, role, stake, and matured exit status for every selected slot.
- All signed paths bind chain ID, aggregator address, Registry address, and a distinct path tag. Slash/reputation IDs and generic/queue typed keys occupy separated replay namespaces.
- Signer commitments include the verified message, mask, sorted signer addresses, domain, typed key, and preceding block hash, so later slot reuse cannot rewrite attribution.
- Rotation does not cryptographically change the domain because the DVT address is not included. The documented `proposalFloor` invalidates current-DVT slash/reputation execution, while generic, direct Registry, owner-direct, and unused queue proofs retain their disclosed rotation behavior.

## Known items explicitly not re-reported

I did not count as new findings:

- disclosure-only guardian slashing (`categoryCount()==0`, `fraudProofVerifier==0`, aggregator not an authorized slasher);
- the residuals already listed in `docs/security/rc8-daybreak-fixes.md`;
- deployer-held owner, treasury, role-owner, `daoMultisig`, `slashPolicyAdmin`, zero guardian, and legacy uncapped aPNTs privileges being handled by the pending manifest/deploy work.

NEW findings — Critical: 0, High: 0, Medium: 1, Low: 0, Info: 0.