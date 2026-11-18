# DeployLive governance ceremony

The deployer is trusted during deployment; the guarantee is the END state.
Any independent party can re-run the read-only checker against the recorded config.
Offline fixture tests are not chain evidence. No contracts/src files were changed.

Only chain ID 31337 is local. Every other chain uses production validation.
DEPLOYLIVE_REHEARSAL=1 selects the same production path on 31337.
Required inputs are GOVERNANCE_OWNER, GOVERNOR_ADDRESS, GUARDIAN_ADDRESS,
SP_GUARDIAN, GENESIS_AASTAR_OPERATOR, APNTS_CAP, GUARDIAN_N,
GUARDIAN_MIN_THRESHOLD, GUARDIAN_DEFAULT_THRESHOLD,
GUARDIAN_SLASH_THRESHOLD_0/1/2, and GUARDIANS (ABI-encoded GuardianInput[], with
address, BLS key and proof of possession). Thresholds satisfy
2 <= min <= default <= N <= 64, with each slash threshold in [2,N].

Safe, SP guardian, PolicyRegistry guardian, genesis operator, each DVT guardian
and deployer must be pairwise distinct. GOVERNOR_ADDRESS may equal Safe.
There is no keeper input. Production uses the validated governor/guardian inputs,
without re-reading them from the environment. Deployer resolution uses one read.

GOVERNANCE_OWNER must have code, exclude any 0xef0100 delegation prefix, and
answer getThreshold/getOwners with threshold >= 2 and enough distinct nonzero
owners. The gate validates canonical ABI encoding. This proves Safe-compatible
M-of-N configuration, not a canonical Safe codehash/factory attestation. The
checker repeats code and threshold/owners readback; no production EOA bypass exists.

ENTRY_POINT, ETH_USD_FEED and SIMPLE_ACCOUNT_FACTORY must have code. EntryPoint
must be v0.7 at 0x0000000071727De22E5E9d8BAf0edAc6f37da032. Feed decimals must
be 8 and answer positive, with nonzero updatedAt no later than now and at most
4200 seconds old (the configured staleness). The factory's accountImplementation
must have code and return that EntryPoint. Initial production updatePrice failure
aborts deployment instead of being swallowed.

## Bootstrap sequence and final state

The v5.4 facilitator CREATE, its transfer to the predicted timelock, and
PolicyRegistry CREATE consume three transactions. Five privilege transfers follow.
Timelock is predicted at the starting nonce + 8. H is predicted at timelock nonce
+ 22: CREATE timelock, seven role-owner configs, slash-policy-admin transfer,
ten single-step ownership transfers, three nominations, then CREATE H.
Nonce/address boundaries are asserted before timelock and again before H.

Timelock starts at delay 0, proposers=[H], executors=[H], admin=address(0).
Timelock itself holds DEFAULT_ADMIN; H gets CANCELLER via construction.
Safe holds NO timelock role before H. H accepts the validated Safe constructor
argument and schedules/executes this exact ten-call batch:

1. acceptOwnership on Registry, SuperPaymaster, APNTsCapped, in that order.
2. grant PROPOSER, EXECUTOR, CANCELLER to Safe, in that order.
3. revoke PROPOSER, EXECUTOR, CANCELLER from H, in that order.
4. updateDelay(172800).

H has no runtime entry points; missing P/E raises BootstrapRolesMissing.
Final assertions check all four roles for deployer, H, governorInput,
guardianInput, spGuardianInput, genesisInput, every guardian and address(0).
A governor equal to Safe is checked as Safe, as explicitly allowed. Safe holds
exactly P/E/C; timelock holds exactly DEFAULT_ADMIN.

Deploy-day: no deployer transaction between nominations and H; no additional
funding or operational operator registration until H is deployed and checker PASS.
The required scripted genesis/DVT Registry setup remains within the trusted
ceremony. Genesis SP isConfigured must be false: Registry role registration does
not configure an SP operator. Its token issuance, configuration and funding are
post-PASS operator actions. minTxInterval==0 is not evidence of configuration.
Production no longer deposits/stakes ETH into EntryPoint during wiring.

H failure => abandon the whole set after confirming it holds no funds and no
registrations, redeploy. Both recovery runners and their Python implementations
are removed; there is no Safe fallback. Scripted registrations can already exist
in a failed set: inventory and resolve them before claiming the abandonment
precondition. Do not fund or operate the failed set.

Before handover the deployer's GToken allowance to staking is set to zero.
Remaining GToken balance stays in place; its destination awaits a separate
governance decision. Config records deployerGTokenBalance, deployerGTokenAllowance
and deployerSBTBalance, and checker prints/asserts each. Other slot recipients
remain unchanged.

## Checker and rehearsal

`python3 script/rehearsal/deploylive_postdeploy_check.py RPC CONFIG DEPLOYER SAFE`

CLI deployer/Safe must match config.deployer/governanceOwner. Integer fields accept
JSON numbers, decimal strings and hex strings. All timelock logs start at recorded
deploymentStartBlock, never block 0. Each of four role sets is reconstructed from
RoleGranted/RoleRevoked, confirmed with hasRole, and compared to the exact expected
set. CallScheduled/CallExecuted must contain only H's executed batch, including
all ten indices, exact payloads and hashOperationBatch ID. RPC errors fail closed.

Registry and SP implementation isolation reports INFO-PASS, counted in status.
The checker reads implementation owners and ERC-1967 bindings; direct initialize
must return InvalidInitialization, direct upgrade UUPSUnauthorizedCallContext,
and proxy upgrade from the implementation owner OwnableUnauthorizedAccount.
These are eth_call simulations, not transactions.

DEPLOYLIVE_STOP_BEFORE_BOOTSTRAP=1 is honored only in production rehearsal on
chain 31337; it is refused before broadcast elsewhere. The stopped config must
FAIL the checker. For a separately authorized disposable Anvil-fork session,
deploylive_fork_deploy.py RPC DEPLOYER [--stop] checks loopback, Anvil metadata,
fork presence and chain 31337. Reset/discard a stopped rehearsal; never recover H.
The retained hook runner and prepare helper are disposable post-PASS fixture tools.
No RPC/deployment/impersonation was performed in this implementation session.

Validation commands: forge build --offline; forge test --offline --match-path
'contracts/test/scripts/DeployLive*.t.sol'; python3 -m unittest discover -s
script/rehearsal -p 'test_deploylive*.py'; bash -n on shell scripts.
Use /Users/jason/.foundry/bin/forge. No formatter or git write was run.

## Check catalogue

**139 + N checks**, including two INFO-PASS assertions: **141 for N=2**, 142 for N=3.
Guardian rows below show N=2.

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
| `guardian[1] registered` | Input guardian at slot i; DVT validator true |
| `guardian[2] registered` | Input guardian at slot i; DVT validator true |
| `genesis operator has COMMUNITY` | true |
| `genesis operator has PAYMASTER_SUPER` | true |
| `genesis isConfigured == false` | false: operator configuration deferred |
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
| `config deployer == CLI` | Required end-state assertion; see ceremony above |
| `config governanceOwner == CLI` | Required end-state assertion; see ceremony above |
| `Safe code excludes delegation` | Required end-state assertion; see ceremony above |
| `Safe threshold/owners` | Required end-state assertion; see ceremony above |
| `required principals pairwise distinct` | Required end-state assertion; see ceremony above |
| `deployer GToken balance == recorded` | Recorded config value; allowance must additionally be zero |
| `deployer GToken allowance == recorded` | Recorded config value; allowance must additionally be zero |
| `deployer SBT balance == recorded` | Recorded config value; allowance must additionally be zero |
| `TL history exactly H batch executed` | Required end-state assertion; see ceremony above |
| `registryImpl isolated` | INFO-PASS: bound implementation, disabled initializer, direct and implementation-owner proxy upgrades rejected |
| `spImpl isolated` | INFO-PASS: bound implementation, disabled initializer, direct and implementation-owner proxy upgrades rejected |

## Original 53 checks → current names

All original checks remain; exact-target companion checks strengthen negative ownership checks.

| Original # | Original check | Current name |
|---|---|---|
| 1 | `owner(superPaymaster) != deployer` | `owner(superPaymaster) != deployer` |
| 2 | `owner(registry) != deployer` | `owner(registry) != deployer` |
| 3 | `owner(staking) != deployer` | `owner(staking) != deployer` |
| 4 | `owner(gToken) != deployer` | `owner(gToken) != deployer` |
| 5 | `owner(xPNTsFactoryV2) != deployer` | `owner(xPNTsFactoryV2) != deployer` |
| 6 | `owner(aoaProtocolRegistry) != deployer` | `owner(aoaProtocolRegistry) != deployer` |
| 7 | `owner(reputationSystem) != deployer` | `owner(reputationSystem) != deployer` |
| 8 | `owner(blsAggregator) != deployer` | `owner(blsAggregator) != deployer` |
| 9 | `owner(dvtValidator) != deployer` | `owner(dvtValidator) != deployer` |
| 10 | `roleConfigs[COMMUNITY].owner != deployer` | `roleConfigs[COMMUNITY].owner != deployer` |
| 11 | `roleConfigs[ENDUSER].owner != deployer` | `roleConfigs[ENDUSER].owner != deployer` |
| 12 | `roleConfigs[PAYMASTER_AOA].owner != deployer` | `roleConfigs[PAYMASTER_AOA].owner != deployer` |
| 13 | `roleConfigs[PAYMASTER_SUPER].owner != deployer` | `roleConfigs[PAYMASTER_SUPER].owner != deployer` |
| 14 | `roleConfigs[DVT].owner != deployer` | `roleConfigs[DVT].owner != deployer` |
| 15 | `roleConfigs[ANODE].owner != deployer` | `roleConfigs[ANODE].owner != deployer` |
| 16 | `roleConfigs[KMS].owner != deployer` | `roleConfigs[KMS].owner != deployer` |
| 17 | `isReputationSource(repSystem)` | `isReputationSource(repSystem)` |
| 18 | `isReputationSource(aggregator)` | `isReputationSource(aggregator)` |
| 19 | `isReputationSource(deployer) == false` | `isReputationSource(deployer) == false` |
| 20 | `SP.treasury != deployer` | `SP.treasury != deployer` |
| 21 | `staking.treasury != deployer` | `staking.treasury != deployer` |
| 22 | `MySBT.daoMultisig != deployer` | `MySBT.daoMultisig != deployer` |
| 23 | `aggregator.slashPolicyAdmin != deployer` | `aggregator.slashPolicyAdmin != deployer` |
| 24 | `SP.guardian != deployer` | `SP.guardian != deployer` |
| 25 | `PolicyRegistry.guardian != deployer` | `PolicyRegistry.guardian != deployer` |
| 26 | `DVT.isValidator(deployer) == false` | `DVT.isValidator(deployer) == false` |
| 27 | `TL.PROPOSER_ROLE(deployer) == false` | `TL.PROPOSER_ROLE(deployer) == false` |
| 28 | `TL.EXECUTOR_ROLE(deployer) == false` | `TL.EXECUTOR_ROLE(deployer) == false` |
| 29 | `TL.CANCELLER_ROLE(deployer) == false` | `TL.CANCELLER_ROLE(deployer) == false` |
| 30 | `TL.DEFAULT_ADMIN_ROLE(deployer) == false` | `TL.DEFAULT_ADMIN_ROLE(deployer) == false` |
| 31 | `authorizedSlashers(aggregator) == false` | `authorizedSlashers(aggregator) == false` |
| 32 | `fraudProofVerifier == 0` | `fraudProofVerifier == 0` |
| 33 | `owner(superPaymaster) != aggregator` | `owner(superPaymaster) != aggregator` |
| 34 | `owner(registry) != aggregator` | `owner(registry) != aggregator` |
| 35 | `owner(staking) != aggregator` | `owner(staking) != aggregator` |
| 36 | `owner(gToken) != aggregator` | `owner(gToken) != aggregator` |
| 37 | `owner(xPNTsFactoryV2) != aggregator` | `owner(xPNTsFactoryV2) != aggregator` |
| 38 | `owner(aoaProtocolRegistry) != aggregator` | `owner(aoaProtocolRegistry) != aggregator` |
| 39 | `owner(reputationSystem) != aggregator` | `owner(reputationSystem) != aggregator` |
| 40 | `owner(blsAggregator) != aggregator` | `owner(blsAggregator) != aggregator` |
| 41 | `owner(dvtValidator) != aggregator` | `owner(dvtValidator) != aggregator` |
| 42 | `owner(xPNTsFactory) != aggregator` | `owner(xPNTsFactory) != aggregator` |
| 43 | `owner(paymasterFactory) != aggregator` | `owner(paymasterFactory) != aggregator` |
| 44 | `owner(paymasterV4Impl) != aggregator` | `owner(paymasterV4Impl) != aggregator` |
| 45 | `owner(microPaymentChannel) != aggregator` | `owner(microPaymentChannel) != aggregator` |
| 46 | `owner(x402Facilitator) != aggregator` | `owner(x402Facilitator) != aggregator` |
| 47 | `aggregator ETH balance == 0` | `aggregator ETH balance == 0` |
| 48 | `aggregator gToken balance == 0` | `aggregator gToken balance == 0` |
| 49 | `aggregator aPNTs balance == 0` | `aggregator aPNTs balance == 0` |
| 50 | `aggregator pnts balance == 0` | `aggregator pnts balance == 0` |
| 51 | `generic executeProposal(batchUpdateGlobalReputation) rejected with ForbiddenGenericSelector` | `generic executeProposal(batchUpdateGlobalReputation) rejected with ForbiddenGenericSelector` |
| 52 | `generic executeProposal(slash) rejected with ForbiddenGenericSelector` | `generic executeProposal(slash) rejected with ForbiddenGenericSelector` |
| 53 | `generic executeProposal(slashByDVT) rejected with ForbiddenGenericSelector` | `generic executeProposal(slashByDVT) rejected with ForbiddenGenericSelector` |

## Review split

1. DeployLiveInputs.sol and DeployLiveInfrastructure.t.sol, plus DeployLive input/oracle hunks.
2. TimelockHandoverBootstrap.sol, remaining DeployLive handover/config hunks and DeployLiveHandover.t.sol.
3. Checker, Python tests, rehearsal helpers, recovery deletions and docs.

No commits were made. Worktree validation logs: deploylive-build.log, deploylive-forge.log, deploylive-python.log.
