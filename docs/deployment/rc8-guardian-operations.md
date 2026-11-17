# rc.8 guardian operations (BLSAggregator-4.14.2 / DVTValidator-0.9.0)

The deploy-day runbooks for the Sepolia manifest and the OP DeployLive both reference this page for guardian procedures.

## Thresholds are deploy inputs
Defaults: N = 3, `minThreshold` 2, `defaultThreshold` 2, slash thresholds WARNING 2 / MINOR 3 / MAJOR 3. Read them back after setting them.

## Voluntary exit
1. The guardian calls `BLSAggregator.requestGuardianExit()`.
2. After `GUARDIAN_EXIT_DELAY + GUARDIAN_FRAUD_CHALLENGE`, the guardian calls `Registry.exitRole(ROLE_DVT)` within the exit window. The stake is returned.
3. **A completed exit suspends the guardian and revokes its BLS key (4.14.2).** Re-staking ROLE_DVT does not bring it back.

**Precondition.** The request is refused with `GuardianExitWouldBreakQuorum(remaining, before)` when the live guardian count *before* the exit equals any configured threshold, slash thresholds included, even though slashing is unused in 5.5.0.

- With the defaults and 3 guardians, **no voluntary exit is possible**.
- Before an exit, either:
  - the governance multisig adds a guardian (stake, `addValidator`, `registerBLSPublicKey` with PoP); or
  - `slashPolicyAdmin` lowers the MINOR/MAJOR thresholds to 2 (`setSlashThreshold`).

## Re-admission after an exit
1. The governance owner calls `BLSAggregator.setSuspended(guardian, false)`.
2. The guardian holds ROLE_DVT with at least `minStake`.
3. Between steps 1 and 3, the address has **proposer power only**: its key is revoked, so it cannot contribute to any quorum. The owner then calls `DVTValidator.registerBLSPublicKey(guardian, key, slot, pop)` with a valid PoP. The PoP digest has no admission epoch, so the original PoP is accepted again. If `permissionlessBLSRegistration` is on, the guardian can make this call itself, but only after step 1.
4. `DVTValidator.addValidator` is needed only if the address was removed or pruned.

The DVT node re-registration script must perform step 1 first.

## Emergency removal
`revokeAndSuspend(guardian)` and `revokeBLSPublicKey(guardian)` (owner) are **not** subject to the exit precondition. They can take the live set below a threshold. Every proof then fails with `InvalidSignatureCount` until guardians are re-admitted.
