Audited commit `053117cc8ca31eb69ae1f62755a1d7790e71190f` read-only. I found 4 new Medium and 2 new Low issues. No Critical or High findings. No builds or tests were necessary; the findings follow directly from deployment/executor call paths.

## NEW findings

### M-01 — Manifest enables the fraud verifier without granting staking slasher authority

- Severity: Medium
- Location: [manifest_exec.py:2282](/Users/jason/Dev/aastar/sp-wt/rc8-bls/script/upgrade/manifest_exec.py:2282), [manifest_exec.py:2348](/Users/jason/Dev/aastar/sp-wt/rc8-bls/script/upgrade/manifest_exec.py:2348), [GTokenStaking.sol:474](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/core/GTokenStaking.sol:474)
- Precondition and sequence:
  1. Execute manifest step `A12b`, proposing the new verifier.
  2. Wait four days and execute `B4`, activating it.
  3. Submit a valid `queueGuardianSlash`.
  4. Call `executeGuardianSlash`.
  5. `BLSAggregator` calls `GTokenStaking.slashByDVT`, which rejects the aggregator because `authorizedSlashers[newAggregator]` was never granted.
- Impact: valid fraud cases cannot slash. The caught revert emits `GuardianSlashFailed`, while the affected guardian remains unresolved and exit-frozen until expiry. More importantly, the manifest appears to enable a security control that remains non-functional.
- Reachable in 5.5.0: No in the untouched disclosure-only configuration. Yes after this manifest performs `A12b` and `B4`. This is not a re-report of the known 5.5.0 no-slasher posture; it is a defect in the later enablement path.
- Minimal fix: include `staking.setAuthorizedSlasher(newAggregator, true)` in the same governance/timelock operation that begins verifier enablement, with a readback before activation. Revoke the predecessor only after the new path is proven live.

### M-02 — Explicit zero governor produces a permanently unusable timelock

- Severity: Medium
- Location: [V54Bootstrap.sol:74](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/script/v3/V54Bootstrap.sol:74), [V54Bootstrap.sol:115](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/script/v3/V54Bootstrap.sol:115)
- Precondition and sequence:
  1. Set `GOVERNOR_ADDRESS=0x0`, while providing a valid `GOVERNANCE_OWNER` so the unrelated final governance gates pass.
  2. `_resolveGovernance` accepts zero.
  3. The fresh `TimelockController` assigns proposer, executor and external admin roles to zero.
  4. `PolicyRegistry` permanently records this timelock as its immutable loosening/admin authority.
- Impact: nobody can schedule the operations needed to administer or loosen `PolicyRegistry`. Recovery requires replacing the V5.4 stack; the X402 facilitator simultaneously remains deployer-owned because its transfer helper treats zero as a no-op.
- Reachable in 5.5.0: Yes during a fresh production deployment with an explicitly zero governor.
- Minimal fix: reject zero governor on every non-local chain. Require and read back the expected proposer, executor, canceller and admin memberships, ideally binding the governor to a separately declared governance address.

### M-03 — Paymaster CREATE2 addresses can be front-run and pre-funded deposits stolen

- Severity: Medium
- Location: [PaymasterFactory.sol:197](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/paymasters/v4/core/PaymasterFactory.sol:197), [PaymasterFactory.sol:220](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/paymasters/v4/core/PaymasterFactory.sol:220), [PaymasterFactory.sol:240](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/paymasters/v4/core/PaymasterFactory.sol:240)
- Precondition and sequence:
  1. A victim calls `predictPaymasterAddress(version, salt)` and publishes or pre-funds the result through `EntryPoint.depositTo`.
  2. An attacker copies the salt and calls `deployPaymasterDeterministic` first, supplying initialization data that makes the attacker the clone owner.
  3. The CREATE2 address is identical because the effective salt does not include the operator.
  4. The attacker calls the owner-only `withdrawTo` to withdraw the prefunded EntryPoint balance.
- Impact: theft of funds sent to a counterfactual paymaster address, or permanent address squatting/denial for the intended operator.
- Reachable in 5.5.0: Yes. The fresh deployment also leaves the factory Registry unset, allowing any EOA to attempt the attack rather than only another registered operator.
- Minimal fix: derive `effectiveSalt = keccak256(abi.encode(msg.sender, salt))`, and make prediction accept the operator address. Operationally, never pre-fund the address before successful deployment and owner verification.

### M-04 — “Default artifact” verification trusts forge JSON bytecode not bound to its metadata

- Severity: Medium
- Location: [DefaultArtifacts.sol:150](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/script/v3/DefaultArtifacts.sol:150), [DefaultArtifacts.sol:221](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/script/v3/DefaultArtifacts.sol:221), [DefaultArtifacts.sol:290](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/script/v3/DefaultArtifacts.sol:290), [DefaultArtifacts.sol:332](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/script/v3/DefaultArtifacts.sol:332)
- Precondition and sequence:
  1. A compromised cache, ignored `out/` directory, or alternate `DEFAULT_ARTIFACTS_OUT` contains a forged artifact JSON.
  2. The attacker preserves valid copied metadata—source hashes, compiler version, optimizer settings and Cancun target—but replaces `bytecode.object` and `deployedBytecode.object`.
  3. `_isDefaultBuild` accepts the metadata.
  4. `vm.deployCode` deploys the substituted creation bytecode.
  5. Runtime verification succeeds because it compares the deployment against the substituted runtime in the same JSON.
- Impact: backdoored bytecode can be labelled and accepted as the audited `profile.default` build. Existing semantic readbacks constrain simple substitutions but do not prove complete bytecode provenance.
- Reachable in 5.5.0: Deployment-time only; yes if build outputs are not freshly and independently authenticated. I found no evidence that the current artifacts are poisoned.
- Minimal fix: rebuild from the pinned clean commit in an isolated directory and bind creation/runtime hashes to compiler build-info or reviewed release hashes. Production scripts should refuse `DEFAULT_ARTIFACTS_OUT` overrides.

### L-01 — Fresh deployment never enables PaymasterFactory role gating

- Severity: Low
- Location: [DeployLive.s.sol:192](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/script/v3/DeployLive.s.sol:192), [DeployLive.s.sol:457](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/script/v3/DeployLive.s.sol:457), [PaymasterFactory.sol:129](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/src/paymasters/v4/core/PaymasterFactory.sol:129)
- Precondition and sequence:
  1. Complete `DeployLive`.
  2. `pmFactory.registry()` remains zero because `_executeWiring` only adds the implementation.
  3. Any address calls `deployPaymaster` or `deployPaymasterDeterministic`.
  4. Both COMMUNITY and PAYMASTER_AOA checks are skipped.
- Impact: the canonical factory can be polluted with unregistered, inactive paymasters; it also broadens M-03 from registered operators to every EOA.
- Reachable in 5.5.0: Yes.
- Minimal fix: call `pmFactory.setRegistry(address(registry))` before adding/deploying an implementation, and assert it during `_assertWiring`.

### L-02 — Any existing community can invalidate the manifest’s predicted clone address

- Severity: Low
- Location: [manifest_exec.py:2370](/Users/jason/Dev/aastar/sp-wt/rc8-bls/script/upgrade/manifest_exec.py:2370), [manifest_exec.py:2414](/Users/jason/Dev/aastar/sp-wt/rc8-bls/script/upgrade/manifest_exec.py:2414), [manifest_exec.py:2990](/Users/jason/Dev/aastar/sp-wt/rc8-bls/script/upgrade/manifest_exec.py:2990)
- Precondition and sequence:
  1. Manifest step `A4.factory` deploys the new public factory.
  2. Before `C3.deploy`, any existing `ROLE_COMMUNITY` holder calls `deployxPNTsToken`.
  3. That call consumes the factory’s first CREATE nonce and increments `getDeployedCount`.
  4. `C3_factory_fresh` stops because the manifest hardcodes `X = create_address(factory, 1)` and count zero.
- Impact: an external community can repeatedly grief a staged upgrade after earlier irreversible deployment, upgrade, pause and ownership steps have occurred. The gate correctly detects the change, but recovery requires regenerating/reconciling the remaining plan.
- Reachable in 5.5.0: Not through the ordinary fresh `DeployLive` token path, but reachable during this manifest upgrade while the new factory is publicly callable.
- Minimal fix: deploy community clones deterministically with a salt namespaced to the community, or derive the token from the factory mapping/receipt rather than requiring the global factory nonce and count to remain zero.

## Confirmations of known/disclosed items

These are not counted as new findings.

### Fresh DeployLive authority end state

Assuming `GOVERNANCE_OWNER = G`, `GOVERNOR_ADDRESS = V` and `GUARDIAN_ADDRESS = H`:

| Component/authority | Holder after successful completion |
|---|---|
| Registry owner; all seven role-config owners | deployer |
| GToken owner/minter | deployer |
| GTokenStaking owner and treasury | deployer |
| Staking slashers | Registry remains implicit; aggregator authorization is false |
| MySBT `daoMultisig` | deployer |
| SuperPaymaster owner and treasury | deployer |
| SuperPaymaster guardian | zero |
| ReputationSystem owner | deployer |
| Registry reputation sources | ReputationSystem and BLSAggregator; deployer revoked |
| BLSAggregator owner; DVTValidator owner | `G` |
| BLSAggregator `slashPolicyAdmin` | deployer |
| Legacy aPNTs community owner; legacy factory owner | `G` |
| aPNTs mint authority | uncapped factory/community-owner path |
| AOAProtocolRegistry owner; xPNTsFactoryV2 owner | `G` |
| X402Facilitator owner | `V`, defaulting to deployer when unset |
| Timelock proposer/executor/canceller/external admin | `V`; timelock also retains its standard self-admin |
| PolicyRegistry guardian | `H`, defaulting to deployer |
| PolicyRegistry authorized consumer | SuperPaymaster |
| PaymasterFactory owner | deployer |
| PaymasterFactory Registry | zero, per L-01 |
| Deployer V4 clone owner and treasury | deployer |
| MicroPaymentChannel owner | deployer |
| Optional Mycelium v2 token owner/minter and SP operator treasury | Anni |

This confirms the deployer-held privilege cluster the prompt identified; it is not re-reported.

### 5.5.0 disclosure-only slashing

[DeployLive.s.sol:403](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/script/v3/DeployLive.s.sol:403) correctly asserts `categoryCount() == 0`, and [DeployLive.s.sol:413](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/script/v3/DeployLive.s.sol:413) asserts the aggregator is not a staking slasher. With `fraudProofVerifier == 0`, guardian slashing is intentionally unreachable. This is confirmed, not a new finding.

### Manifest final authority state

After a full A/B/C/D rehearsal:

- SP, Registry, AOAProtocolRegistry and xPNTsFactoryV2 are owned by the fixed timelock.
- New and old aggregators, DVT and committee are owned by the fixed Safe.
- Both aggregator `slashPolicyAdmin` values are the Safe.
- APNTsCapped minter is the Safe.
- New aggregator is the Registry reputation source; the old source is revoked.
- SP treasury and guardian remain unchanged; Registry role owners other than the explicitly frozen PAYMASTER_SUPER configuration remain unchanged.
- GToken, staking, MySBT, legacy factories/tokens and PaymasterFactory are not handed over by this manifest.
- The new aggregator is still not an authorized staking slasher, as described in M-01.

## Ordering, rerun and default-input conclusions

- `DeployLive` is not resumable: rerunning starts a new stack because `v55` begins empty and V5.4 always receives `existingTimelock = 0`.
- Its transactions are individually broadcast. A later failure does not roll back already mined deployments; governance handoffs are deliberately last, so partial runs retain deployer authority.
- Step 7 is intentionally skippable when `PRIVATE_KEY_ANNI` is absent.
- V5.4 facilitator wiring intentionally skips tokens not owned by the deployer and may complete partially.
- `GOVERNANCE_OWNER=0` cannot silently complete on production: the final gate refuses it. `GOVERNOR_ADDRESS` and `GUARDIAN_ADDRESS` silently default to the deployer, which is the known privilege issue.
- `SIMPLE_ACCOUNT_FACTORY` can be explicitly zero and is merely written to configuration; it is not validated or used by this path.
- The manifest’s frozen plan rejects skipped or reordered steps during simulation. Stage `a7`, `b4`, and `c` artifacts are marked non-final.
- `manifest_exec.py sign` and `send` deliberately stop as unimplemented at [manifest_exec.py:3667](/Users/jason/Dev/aastar/sp-wt/rc8-bls/script/upgrade/manifest_exec.py:3667). Therefore its pre-send checks currently protect local rehearsals, not an implemented live broadcaster.
- Ordinary deployer CREATE predictions are safe from unrelated accounts because only the deployer can consume its nonce. The material prediction risks are the operator-independent CREATE2 salt in M-03 and the public factory CREATE nonce in L-02.

Critical: 0; High: 0; Medium: 4; Low: 2; Info: 0.