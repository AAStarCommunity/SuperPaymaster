# DeployLive rc.8 handoff (partial: size-limit stop)

No deployment or RPC was executed. The checker test fixture is not chain evidence.

## Scope and remaining work

Implemented production input validation, guardian registration then threshold setting,
owner/privilege handover, and the constructor-only timelock bootstrap. Integrated
APNTsCapped because it is one of the three mandatory two-step handover subjects.
Factory Registry binding, price staleness and end-state assertions are included.
The original local deployment branch remains in place; production skips the legacy
Anni/mint bootstrap because capped minting belongs to the Safe.

Stopped at the requested approximately 500-line logic budget. Still required:

- The two anvil-only recovery runners: unchanged-nonce H redeployment and Safe-proposed fallback batch.
- The anvil-only Registry.exitRole / SP pause-hook runner with a same-transaction assertion.
- Orchestrator-run OP fork rehearsal, real guardian PoP registration and complete end-to-end DeployLive verification.

The genesis input receives COMMUNITY and PAYMASTER_SUPER roles. It is not impersonated:
its v2 token issuance, operator configuration and funding remain operator actions.
The checker accepts its default minTxInterval of zero and does not assert isConfigured.
Recovery runners and the exit-hook check have not been substituted with weaker checks.

## Required production inputs

Production means chain ID 10 or 11155111. Chain 31337 retains the original default branch.

- `GOVERNANCE_OWNER`: Safe; proposer, executor and canceller of the timelock, but never admin.
- `GOVERNOR_ADDRESS`, `GUARDIAN_ADDRESS`, `SP_GUARDIAN`, `GENESIS_AASTAR_OPERATOR`: required nonzero addresses distinct from deployer.
- `APNTS_CAP`: required positive integer in token base units; no production cap default.
- `GUARDIAN_N`, `GUARDIAN_MIN_THRESHOLD`, `GUARDIAN_DEFAULT_THRESHOLD`.
- `GUARDIAN_SLASH_THRESHOLD_0`, `_1`, `_2` (slash levels 0, 1, 2).
- `GUARDIANS`: hex ABI encoding of `GuardianInput[]`, each entry
  `(address,(bytes32,bytes32,bytes32,bytes32),(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32))`.
  G1/G2 field order follows `contracts/src/utils/BLS.sol`. Entries occupy slots 1..N.
  PoPs must bind the guardian address and the new aggregator's domain; they cannot be
  copied from another deployment. No private keys are consumed by the new input path.

Threshold constraints: `2 <= min <= default <= N <= 64`; each slash threshold is 2..N.
`GOVERNOR_ADDRESS` is validated and recorded; final contract ownership and timelock
roles follow the decided Timelock/Safe targets, not this separate governor address.

## Bootstrap sequence

At nonce n the script creates a zero-delay self-administered timelock with Safe and
predicted H as proposer/executor (both also receive canceller). It then emits exactly
21 transactions: seven role configurations, slash-policy-admin transfer, ten one-step
ownership transfers, and three two-step nominations. H is CREATE at nonce n+22.
The script checks the starting nonce, timelock address, H nonce and H address.
H accepts Registry, SuperPaymaster and APNTsCapped, removes its three roles and
sets the delay to 172800 in one batch. The script then verifies the final state.

H compiled runtime: **16 bytes**, `0x5f80fdfea164736f6c6343000821000a`.
The executed runtime begins PUSH0/DUP1/REVERT; the remainder is compiler metadata.
Creation bytecode in the isolated default-profile test build: **2045 bytes**, excluding arguments.

## Checker

`python3 script/rehearsal/deploylive_postdeploy_check.py <rpc> <config.json> <deployer> <safe>`

Uses only read operations: eth_call plus balance/code/log readback required by the
checks. It does not send transactions. RPC errors are redacted; no URL is printed.
Log reconstruction starts at block zero, filtered to the timelock, and fails closed
if the RPC rejects the history request. Reconstructed members are confirmed with
hasRole. Zero delay, retained bootstrap roles and pending owners all produce FAIL.
Expected inputs and bootstrap address/nonce are included in the deployment config.

There are **128 + N checks**: the original 53 plus 75 fixed checks and one per guardian.
For N=2 the offline fixture gives 130 checks; for N=3 the orchestrator should see 131.
The full expected-owner list is printed by the `owner(...) == expected` checks below.

## Complete check catalog

| Check name | Expected value |
|---|---|
| `owner(superPaymaster) != deployer` | Not deployer (original check; exact-target check also retained below) |
| `owner(registry) != deployer` | Not deployer (original check; exact-target check also retained below) |
| `owner(staking) != deployer` | Not deployer (original check; exact-target check also retained below) |
| `owner(gToken) != deployer` | Not deployer (original check; exact-target check also retained below) |
| `owner(xPNTsFactoryV2) != deployer` | Not deployer (original check; exact-target check also retained below) |
| `owner(aoaProtocolRegistry) != deployer` | Not deployer (original check; exact-target check also retained below) |
| `owner(reputationSystem) != deployer` | Not deployer (original check; exact-target check also retained below) |
| `owner(blsAggregator) != deployer` | Not deployer (original check; exact-target check also retained below) |
| `owner(dvtValidator) != deployer` | Not deployer (original check; exact-target check also retained below) |
| `roleConfigs[COMMUNITY].owner != deployer` | Not deployer (original check; exact-target check also retained below) |
| `roleConfigs[ENDUSER].owner != deployer` | Not deployer (original check; exact-target check also retained below) |
| `roleConfigs[PAYMASTER_AOA].owner != deployer` | Not deployer (original check; exact-target check also retained below) |
| `roleConfigs[PAYMASTER_SUPER].owner != deployer` | Not deployer (original check; exact-target check also retained below) |
| `roleConfigs[DVT].owner != deployer` | Not deployer (original check; exact-target check also retained below) |
| `roleConfigs[ANODE].owner != deployer` | Not deployer (original check; exact-target check also retained below) |
| `roleConfigs[KMS].owner != deployer` | Not deployer (original check; exact-target check also retained below) |
| `isReputationSource(repSystem)` | true |
| `isReputationSource(aggregator)` | true |
| `isReputationSource(deployer) == false` | false |
| `SP.treasury != deployer` | Not deployer (original check; exact-target check also retained below) |
| `staking.treasury != deployer` | Not deployer (original check; exact-target check also retained below) |
| `MySBT.daoMultisig != deployer` | Not deployer (original check; exact-target check also retained below) |
| `aggregator.slashPolicyAdmin != deployer` | Not deployer (original check; exact-target check also retained below) |
| `SP.guardian != deployer` | Not deployer (original check; exact-target check also retained below) |
| `PolicyRegistry.guardian != deployer` | Not deployer (original check; exact-target check also retained below) |
| `DVT.isValidator(deployer) == false` | false |
| `TL.PROPOSER_ROLE(deployer) == false` | false |
| `TL.EXECUTOR_ROLE(deployer) == false` | false |
| `TL.CANCELLER_ROLE(deployer) == false` | false |
| `TL.DEFAULT_ADMIN_ROLE(deployer) == false` | false |
| `authorizedSlashers(aggregator) == false` | false |
| `fraudProofVerifier == 0` | 0 |
| `owner(superPaymaster) != aggregator` | Not aggregator |
| `owner(registry) != aggregator` | Not aggregator |
| `owner(staking) != aggregator` | Not aggregator |
| `owner(gToken) != aggregator` | Not aggregator |
| `owner(xPNTsFactoryV2) != aggregator` | Not aggregator |
| `owner(aoaProtocolRegistry) != aggregator` | Not aggregator |
| `owner(reputationSystem) != aggregator` | Not aggregator |
| `owner(blsAggregator) != aggregator` | Not aggregator |
| `owner(dvtValidator) != aggregator` | Not aggregator |
| `owner(xPNTsFactory) != aggregator` | Not aggregator |
| `owner(paymasterFactory) != aggregator` | Not aggregator |
| `owner(paymasterV4Impl) != aggregator` | Not aggregator |
| `owner(microPaymentChannel) != aggregator` | Not aggregator |
| `owner(x402Facilitator) != aggregator` | Not aggregator |
| `aggregator ETH balance == 0` | 0 |
| `aggregator gToken balance == 0` | 0 |
| `aggregator aPNTs balance == 0` | 0 |
| `aggregator pnts balance == 0` | 0 |
| `generic executeProposal(batchUpdateGlobalReputation) rejected with ForbiddenGenericSelector` | Revert with ForbiddenGenericSelector for the blocked selector |
| `generic executeProposal(slash) rejected with ForbiddenGenericSelector` | Revert with ForbiddenGenericSelector for the blocked selector |
| `generic executeProposal(slashByDVT) rejected with ForbiddenGenericSelector` | Revert with ForbiddenGenericSelector for the blocked selector |
| `owner(superPaymaster) == expected` | Timelock |
| `owner(registry) == expected` | Timelock |
| `owner(staking) == expected` | Timelock |
| `owner(gToken) == expected` | Safe |
| `owner(xPNTsFactoryV2) == expected` | Timelock |
| `owner(aoaProtocolRegistry) == expected` | Timelock |
| `owner(reputationSystem) == expected` | Timelock |
| `owner(blsAggregator) == expected` | Timelock |
| `owner(dvtValidator) == expected` | Timelock |
| `owner(xPNTsFactory) == expected` | Timelock |
| `owner(paymasterFactory) == expected` | Timelock |
| `owner(paymasterV4Impl) == expected` | Timelock |
| `owner(microPaymentChannel) == expected` | Timelock |
| `owner(x402Facilitator) == expected` | Timelock |
| `owner(aPNTs) == expected` | Timelock |
| `pendingOwner(registry) == 0` | 0 |
| `pendingOwner(superPaymaster) == 0` | 0 |
| `pendingOwner(aPNTs) == 0` | 0 |
| `roleConfigs[COMMUNITY].owner == timelock` | Timelock |
| `deployer.hasRole(COMMUNITY) == false` | false |
| `roleConfigs[ENDUSER].owner == timelock` | Timelock |
| `deployer.hasRole(ENDUSER) == false` | false |
| `roleConfigs[PAYMASTER_AOA].owner == timelock` | Timelock |
| `deployer.hasRole(PAYMASTER_AOA) == false` | false |
| `roleConfigs[PAYMASTER_SUPER].owner == timelock` | Timelock |
| `deployer.hasRole(PAYMASTER_SUPER) == false` | false |
| `roleConfigs[DVT].owner == timelock` | Timelock |
| `deployer.hasRole(DVT) == false` | false |
| `roleConfigs[ANODE].owner == timelock` | Timelock |
| `deployer.hasRole(ANODE) == false` | false |
| `roleConfigs[KMS].owner == timelock` | Timelock |
| `deployer.hasRole(KMS) == false` | false |
| `deployer Registry role list empty` | [] |
| `SP.treasury == expected` | Safe |
| `staking.treasury == expected` | Safe |
| `MySBT.daoMultisig == expected` | Safe |
| `aggregator.slashPolicyAdmin == expected` | Timelock |
| `SP.guardian == expected` | SP_GUARDIAN |
| `PolicyRegistry.guardian == expected` | GUARDIAN_ADDRESS |
| `PolicyRegistry.timelock == expected` | Timelock |
| `SP.APNTS_TOKEN == expected` | Deployed APNTsCapped address |
| `APNTsCapped.minter == expected` | Safe |
| `APNTsCapped.capGuardian == expected` | Safe |
| `pmFactory.registry == expected` | Registry proxy address |
| `TL.minDelay == expected` | 172800 seconds |
| `APNTsCapped.cap == expected` | APNTS_CAP (> 0) |
| `SP.priceStalenessThreshold == expected` | 4200 seconds |
| `agg.minThreshold == expected` | GUARDIAN_MIN_THRESHOLD |
| `agg.defaultThreshold == expected` | GUARDIAN_DEFAULT_THRESHOLD |
| `agg.slashThresholds[0] == input` | GUARDIAN_SLASH_THRESHOLD_0 |
| `agg.slashThresholds[1] == input` | GUARDIAN_SLASH_THRESHOLD_1 |
| `agg.slashThresholds[2] == input` | GUARDIAN_SLASH_THRESHOLD_2 |
| `expectedGovernor nonzero and not deployer` | Nonzero and not deployer |
| `expectedGuardian nonzero and not deployer` | Nonzero and not deployer |
| `expectedSPGuardian nonzero and not deployer` | Nonzero and not deployer |
| `genesisOperator nonzero and not deployer` | Nonzero and not deployer |
| `Safe nonzero and not deployer` | Nonzero and not deployer |
| `guardian N == inputs` | GUARDIAN_N, 2..64, matching distinct guardian input count |
| `guardian[i] registered (i = 1..N)` | Input guardian at slot i; DVT validator true; not zero/deployer |
| `genesis operator has COMMUNITY` | true |
| `genesis operator has PAYMASTER_SUPER` | true |
| `genesis minTxInterval == 0` | 0 |
| `H runtime non-callable` | At most 64 bytes, unconditional revert prefix (built H: 16 bytes) |
| `TL.DEFAULT_ADMIN_ROLE exact members` | {timelock} |
| `TL.DEFAULT_ADMIN_ROLE(H) == false` | false |
| `TL.DEFAULT_ADMIN_ROLE(safe) == expected` | false |
| `TL.PROPOSER_ROLE exact members` | {Safe} |
| `TL.PROPOSER_ROLE(H) == false` | false |
| `TL.PROPOSER_ROLE(safe) == expected` | true |
| `TL.EXECUTOR_ROLE exact members` | {Safe} |
| `TL.EXECUTOR_ROLE(H) == false` | false |
| `TL.EXECUTOR_ROLE(safe) == expected` | true |
| `TL.CANCELLER_ROLE exact members` | {Safe} |
| `TL.CANCELLER_ROLE(H) == false` | false |
| `TL.CANCELLER_ROLE(safe) == expected` | true |
| `TL.DEFAULT_ADMIN_ROLE(timelock) == true` | true |

## Validation results (verbatim)

Commands used the specified Forge binary with `--offline`, invoked through `nice -n 10`.
The sandbox reported `nice: setpriority: Operation not permitted`; Forge continued
and exited successfully. No formatter, network/RPC call, git mutation or source-contract edit was performed.

Final `forge build --offline` (exit 0):

```text
Solc 0.8.33 finished in 5.13s
Solc 0.8.33 finished in 26.47s
Compiler run successful with warnings:
```

Final `forge test --offline --match-path 'contracts/test/scripts/DeployLive*.t.sol'` (exit 0):

```text
Suite result: ok. 15 passed; 0 failed; 0 skipped; finished in 8.36ms (27.65ms CPU time)
Suite result: ok. 5 passed; 0 failed; 0 skipped; finished in 15.05ms (16.56ms CPU time)
Ran 2 test suites in 18.15ms (23.41ms CPU time): 20 tests passed, 0 failed, 0 skipped (20 total tests)
```

Offline Python checker tests (exit 0; mocked read operations, not a fork):

```text
Ran 2 tests in 0.058s

OK
SUMMARY 130 passed, 0 failed, 130 total
```

The checker suite includes zero delay, pending ownership, retained H roles,
unexpected admin membership, grant/revoke log replay, and RPC-error redaction.
The Solidity suite covers every required address/numeric input, local-default input
loading, threshold bounds, guardian shape/count, successful constructor handover,
missing constructor roles, and each omitted revoke/delay operation.
It does not execute the entire production DeployLive flow or validate real BLS PoPs.
When `pnts` is the zero address, the retained aggregator-pnts-balance check reports zero
because no such asset is configured; it does not prove a genesis v2 token exists.

## Changed files and line counts

Counts are relative to Git HEAD and include the supplied partial attempt. The existing
20-line governance test addition was preserved. Source/checker logic totals **494
added/deleted lines**, counting even comments/blank lines and the promoted checker.
Generated ignored Forge artifacts/caches are excluded. Isolated test artifacts were removed.

| File | Added | Deleted |
|---|---:|---:|
| `contracts/script/v3/DefaultArtifacts.sol` | 1 | 0 |
| `contracts/script/v3/DeployLive.s.sol` | 157 | 12 |
| `contracts/script/v3/DeployLiveInputs.sol` | 56 | 0 |
| `contracts/script/v3/TimelockHandoverBootstrap.sol` | 64 | 0 |
| `contracts/test/scripts/DeployLiveGovernance.t.sol` (supplied addition) | 20 | 0 |
| `contracts/test/scripts/DeployLiveHandover.t.sol` | 143 | 0 |
| `script/rehearsal/deploylive_postdeploy_check.py` | 204 | 0 |
| `script/rehearsal/test_deploylive_postdeploy_check.py` | 108 | 0 |
| `script/rehearsal/DEPLOYLIVE_HANDOFF.md` | 268 | 0 |

Ignored validation logs retained in the worktree: `deploylive-build.log`,
`deploylive-build-final.log`, `deploylive-handover-tests.log`,
`deploylive-tests-final.log`, and `deploylive-checker-tests.log`.
