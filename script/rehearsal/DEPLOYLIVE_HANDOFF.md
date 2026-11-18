# DeployLive round-six governance ceremony

The deployer is trusted during deployment. Acceptance is the verified final state,
not a successful simulation or a partially written config. `contracts/src` is unchanged.
Only chain 31337 without `DEPLOYLIVE_REHEARSAL=1` uses the legacy local behavior.

## Inputs and authority

Production requires `GOVERNANCE_OWNER`, `GUARDIAN_ADDRESS`, `SP_GUARDIAN`,
`GENESIS_AASTAR_OPERATOR`, `APNTS_CAP`, `GUARDIAN_N`, `GUARDIAN_MIN_THRESHOLD`,
`GUARDIAN_DEFAULT_THRESHOLD`, `GUARDIAN_SLASH_THRESHOLD_0/1/2`, and public
`GUARDIANS` (ABI-encoded account, public key, PoP tuples).
Safe, policy guardian, SP guardian, genesis operator, deployer and each DVT guardian
must differ. Thresholds satisfy 2 <= min <= default <= N <= 64; slash thresholds
are in [2,N]. EntryPoint v0.7, the fresh 8-decimal oracle and the account factory
are checked before broadcast.

The following five inputs have **no production defaults**. Each accepts the exact
literal `timelock`, the exact literal `safe`, or a nonzero contract address other
than the deployer. The declared choice is resolved, applied, asserted and recorded.

| Input | DSR ceremony choice | Authority |
|---|---|---|
| SLASH_POLICY_ADMIN | timelock | BLSAggregator slashPolicyAdmin |
| X402_OWNER | safe | X402Facilitator owner |
| REPUTATION_OWNER | timelock | ReputationSystem owner |
| MPC_OWNER | timelock | MicroPaymentChannel owner |
| PAYMASTER_FACTORY_OWNER | timelock | PaymasterFactory and Paymaster implementation owners |

`GOVERNOR_ADDRESS` must be absent on production, including an empty declaration.
The rejection points to `X402_OWNER`. Legacy local behavior still resolves governor.
`DEPLOYER_GTOKEN_RECIPIENT` is also required: a nonzero address other than the
deployer (`safe` explicitly resolves the Safe). Explicit rehearsal choices are in
[inputs/deploylive-rehearsal.inputs](inputs/deploylive-rehearsal.inputs); this file
is never loaded implicitly by the production script.

BLSAggregator, DVTValidator, xPNTsFactory v1, xPNTsFactoryV2 and
AOAProtocolRegistry owners are always the Safe. Every slot is checked using
GovernanceOwnerGate.readMofN, exact address equality, contract code and rejection
of the EIP-7702 prefix. This proves a Safe-compatible threshold >= 2 with enough
unique nonzero owners, not a canonical Safe implementation/factory attestation.
The general gate's local-chain bypass is not used for the production rehearsal.
GToken owner, MySBT DAO, both treasuries, APNTsCapped minter and capGuardian are Safe.
Registry, SuperPaymaster and APNTsCapped ownership goes to TL through H.
AOA Paymaster and legacy uncapped aPNTs are not deployed; their checker rows are N/A.

## Bytecode and execution environment

Before any broadcast, `CREATION_PINS` must name the release pin JSON. Generate or
check it with `python3 script/rehearsal/creation_pins.py <pin-file> [--check]`.
The tool copies source/dependencies/config to a fresh worktree-local temporary
directory, excludes existing outputs, caches and environment files, creates an
empty `out-clean`, sets `DEFAULT_ARTIFACTS_OUT=out-clean`, and builds offline.
It never selects a pre-existing artifact. Registry and the importing deployment
script use runs=200; other release artifacts use runs=500. Pins cover the exact
artifact creation bytes selected by DefaultArtifacts plus compiled H creationCode.
SuperPaymaster's pin also binds its embedded SuperPaymasterAdmin creation code.

The 25 pins are Registry, SuperPaymaster, APNTsCapped, TimelockController, H,
ERC1967Proxy, xPNTsFactory, GTokenAuthorization, GTokenStaking, MySBT,
ReputationSystem, DVTValidator, BLSAggregator, MicroPaymentChannel,
PaymasterFactory, Paymaster, X402Facilitator, PolicyRegistry, GlobalTierSource,
AOAProtocolRegistry, xPNTsTokenV2Ext, xPNTsTokenV2, xPNTsFactoryV2,
SuperPaymasterLens and xPNTsToken.

For a Prague fork, retain **Cancun release artifacts in `out-cancun`** and set
`DEFAULT_ARTIFACTS_OUT=out-cancun`, while the forge runner uses `--evm-version prague`.
Cancun bytes are the deployed release; Prague supplies EIP-2537 for BLS verification.
Do not let the simulation overwrite or silently replace the release artifact set.
`compare_artifacts.py <dirA> <dirB>` lists creation/runtime differences and missing
artifacts and exits nonzero for any non-test difference. Config records the artifact
directory and `DEPLOYLIVE_EVM_VERSION`; the provided fork wrapper sets the latter
and the actual forge flag together. For direct CLI use, the operator must keep them
consistent: Solidity cannot read forge's selected hardfork name.

## Fixed handover and accounting

A remaining GToken balance leaves the deployer a path back into a protocol role.
It could re-approve staking and pay the 30 GToken ticket through the permissionless
`registerRole` to register itself as COMMUNITY again. The handover therefore
transfers the entire remainder to DEPLOYER_GTOKEN_RECIPIENT.

Before TL CREATE: v5.4 CREATE/transfer/CREATE, three privilege transfers and one
unconditional GToken remainder transfer. The TL prediction is therefore +7 from
the start of v5.4. Staking allowance is already zero. Recipient pre-balance and
transferred amount are recorded, and the final exact balance delta is asserted.

The actual encoded handover list has seven role configs, one slash-admin change,
ten single-step owner transfers and three nominations: 21 calls. H's nonce is
`TL nonce + 1 + call-list.length`, currently **+22**. The observed nonce is recorded
immediately before CREATE and must match. No conditional transaction belongs here.

TL initially has delay zero, self-admin and P/E/C only for predicted H. Safe has
no TL authority. H's constructor atomically accepts three ownerships, grants Safe
P/E/C, revokes H P/E/C and sets delay 172800. Its runtime has no callable surface.
No additional funding or operational registration is permitted until checker PASS.
Genesis remains registered but not configured as a SuperPaymaster operator.

The mint ledger records count, recipients and amounts; supply must equal their sum.
The registration ledger records stakes, tickets and the treasury at payment time.
For the N=3 local production-path fixture (base units are 1e18):

| Item | GToken |
|---|---:|
| Mint 1 to deployer | 2000 |
| Mint 2 to deployer | 199 |
| Genesis PAYMASTER_SUPER stake | 50 |
| Each of three guardian DVT stakes | 30 |
| Bootstrap COMMUNITY ticket | 30 |
| Genesis COMMUNITY / PAYMASTER_SUPER tickets | 30 / 5 |
| Each guardian ticket | 3 |
| ticketsToTreasury (measured Safe receipts) | 74 |
| Deployer balance before remainder transfer | 1985 |
| deployerRemainderToRecipient | 1985 |
| Deployer final balance / staking allowance | 0 / 0 |

On production, staking treasury is set immediately after staking deployment, before
any registration; SP treasury is set immediately after its proxy deployment. Neither
is set again in handover. Tickets do not reduce supply. Conservation is
2199 = 140 locked + 74 ticketsToTreasury + 1985 deployerRemainderToRecipient
= GToken.totalSupply(). A distinct recipient receives only 1985; when recipient is
Safe its final balance is 2059, of which 74 arrived during registrations. GToken owner is Safe; deployer mint is rejected.
Checker also reconstructs every mint from zero-source Transfer logs.

## Failed set: abandon and redeploy

Genesis COMMUNITY/PAYMASTER_SUPER and guardian DVT registrations, validator
admission, public keys/PoPs and threshold configuration stay before H because they
need the pre-handover owner. A reverted H CREATE leaves no H code and no external
party able to propose or execute via TL: predicted H alone retains P/E/C.
There is no recovery procedure. The failed set is **ABANDONED**, never published.

Run the normal checker and retain its FAIL with registration rows. Also run
`deploylive_failed_set_check.py <local-fork-rpc> <failed-config>`. The external list
is [inputs/external-tokens.json](inputs/external-tokens.json), selected by
`eth_chainId`; the rehearsal inputs explicitly set `EXTERNAL_TOKENS_FILE`. Labels
and decimals are explicit metadata, never inferred from `symbol()`. The OP group
contains native USDC, USDC.e, bridged USDT, USDT0, DAI, WETH and OP; Sepolia
contains Circle USDC and both specified WETH deployments. Unknown chains and
empty groups FAIL. Local rehearsal configs must supply `externalTokens` with a
`"31337"` group of deployed mock tokens (each entry: `label`, `address`, `decimals`).
Every listed address must have code before any balance call; missing code FAILs
and its balance is never read. Every listed token is read directly against every
contract in the failed set and must return an ABI uint256 equal to zero. Empty,
malformed or reverted reads FAIL. The Transfer scan remains a fallback for
unlisted tokens. It reads each
recorded contract's ETH balance, discovers incoming Transfer-emitting tokens from
genesis (including pre-funding), reads balances for every discovered token/holder,
and permits positive balances only for this set's GToken/APNTsCapped. It prints
historical and current registrations and the abandoned addresses. Any incomplete
RPC read fails the inventory; an inventory PASS never accepts the deployment.
Nonstandard tokens that change balances without Transfer events are outside this
log-discovery method; an independently complete external-token inventory remains
necessary to make an unrestricted "every token" claim.

The deployment coordinator records every address as ABANDONED and notifies the DVT
node operators and Safe signers. A replacement set has a **new aggregator address**.
Send DVT operators the new release pin file/hash, chain/domain, predicted aggregator
and DVT addresses, and each guardian account/slot. Each node regenerates its PoP in
predicted-address mode, verifies the new popContext, and returns only public key and
PoP to SP's coordinator. The coordinator invalidates all old PoPs and redistributes
the replacement public input bundle to the Safe signers. Old PoPs are void for the
new aggregator. Failed-set public keys and registrations remain on chain: public
keys are public and harmless; abandoned registrations have authority only in that set.

## Rehearsal driver and evidence

Modes: `happy`, `failure`, `governance`, plus existing `prepare`, `hook`, `guard`.
Invocation: `deploylive_rehearse.py MODE LOCAL_RPC CONFIG DEPLOYER SAFE [OPERATOR]`.
The mutating driver requires an Anvil fork. These modes were unit-tested only here;
no fork was available or accessed. The Solidity production fixture runs locally
with mock infrastructure/BLS boundaries, not a fork or genuine PoP validation.

Failure mode deploys with STOP_BEFORE_BOOTSTRAP=1, overwrites pendingOwner with
anvil_setStorageAt (no nonce), submits H creation at the recorded nonce, requires a
reverted receipt and absent code, inventories the failed set, and requires checker
exit 1. Governance mode impersonates Safe, schedules TL.updateDelay(172801), requires
the exact not-ready revert before 172800 seconds, advances time, executes and reads
back 172801. Run this only after the initial checker: it deliberately changes history.

No BLS secret/PoP step may run at forge verbosity >=3. The repository default is 3;
set FOUNDRY_VERBOSITY=2 explicitly. Both entry points refuse unsafe verbosity before
RPC/deployment. A key-generating rehearsal script must begin with
`REHEARSAL ONLY - never use for deploy day`. This driver does not generate keys.
On deploy day, DVT nodes generate PoPs in predicted-address mode; SP receives only
PoPs and public keys, never scalars.

Provide DEPLOYLIVE_EVIDENCE_DIR, REHEARSAL_SOURCE_RPC and REHEARSAL_BLS_SCALARS
(JSON array, explicitly [] when no secrets were used). The fixed final step runs
even on failure: recursively scan every evidence file for source RPC URL, host,
path/query fragments and scalar decimal/hex forms. Any hit fails without echoing it.
Include all forge/broadcast outputs in that evidence directory before invoking the
driver; files outside it cannot be certified by the scan.

The complete valid-config checker count is **155 + 2N**: 159 for N=2, 161 for N=3.
Round six was 153 + 2N; 6b adds Safe owners exclude deployer, and 6c adds
GToken treasury tickets. External-token inventory is a separate failed-set audit
and is not included in this post-deployment SUMMARY.
This includes N guardian checks and N+3 stake checks; N/A and INFO rows do not count.
The two implementation-isolation assertions remain counted as INFO-PASS.
See DEPLOYLIVE_VALIDATION.md for exact test output and remaining evidence limits.

## Row-by-row checker mapping to the original 53

O01–O53 identify the original assertions in their execution order. Each row below
is one counted output for N=2, including both INFO-PASS rows. “New” means there
is no equivalent original assertion; related authority rows cite the original ID.
For N=3, insert guardian[3] after guardian[2] and stake[5] after stake[4]; subsequent
row numbers shift accordingly. INFO and N/A output and fail-fast input parsing are
not counted. This supersedes the old 157-row snapshot without dropping any check.

| Current row (N=2) | Assertion | Original 53 / extension |
|---:|---|---|
| 1 | `owner(superPaymaster) != deployer` | O01 unchanged |
| 2 | `owner(registry) != deployer` | O02 unchanged |
| 3 | `owner(staking) != deployer` | O03 unchanged |
| 4 | `owner(gToken) != deployer` | O04 unchanged |
| 5 | `owner(xPNTsFactoryV2) != deployer` | O05 unchanged |
| 6 | `owner(aoaProtocolRegistry) != deployer` | O06 unchanged |
| 7 | `owner(reputationSystem) != deployer` | O07 unchanged |
| 8 | `owner(blsAggregator) != deployer` | O08 unchanged |
| 9 | `owner(dvtValidator) != deployer` | O09 unchanged |
| 10 | `roleConfigs[COMMUNITY].owner != deployer` | O10 unchanged |
| 11 | `roleConfigs[ENDUSER].owner != deployer` | O11 unchanged |
| 12 | `roleConfigs[PAYMASTER_AOA].owner != deployer` | O12 unchanged |
| 13 | `roleConfigs[PAYMASTER_SUPER].owner != deployer` | O13 unchanged |
| 14 | `roleConfigs[DVT].owner != deployer` | O14 unchanged |
| 15 | `roleConfigs[ANODE].owner != deployer` | O15 unchanged |
| 16 | `roleConfigs[KMS].owner != deployer` | O16 unchanged |
| 17 | `isReputationSource(repSystem)` | O17 unchanged |
| 18 | `isReputationSource(aggregator)` | O18 unchanged |
| 19 | `isReputationSource(deployer) == false` | O19 unchanged |
| 20 | `SP.treasury != deployer` | O20 unchanged |
| 21 | `staking.treasury != deployer` | O21 unchanged |
| 22 | `MySBT.daoMultisig != deployer` | O22 unchanged |
| 23 | `aggregator.slashPolicyAdmin != deployer` | O23 unchanged |
| 24 | `SP.guardian != deployer` | O24 unchanged |
| 25 | `PolicyRegistry.guardian != deployer` | O25 unchanged |
| 26 | `DVT.isValidator(deployer) == false` | O26 unchanged |
| 27 | `TL.PROPOSER_ROLE(deployer) == false` | O27 unchanged |
| 28 | `TL.EXECUTOR_ROLE(deployer) == false` | O28 unchanged |
| 29 | `TL.CANCELLER_ROLE(deployer) == false` | O29 unchanged |
| 30 | `TL.DEFAULT_ADMIN_ROLE(deployer) == false` | O30 unchanged |
| 31 | `authorizedSlashers(aggregator) == false` | O31 unchanged |
| 32 | `fraudProofVerifier == 0` | O32 unchanged |
| 33 | `owner(superPaymaster) != aggregator` | O33 unchanged |
| 34 | `owner(registry) != aggregator` | O34 unchanged |
| 35 | `owner(staking) != aggregator` | O35 unchanged |
| 36 | `owner(gToken) != aggregator` | O36 unchanged |
| 37 | `owner(xPNTsFactoryV2) != aggregator` | O37 unchanged |
| 38 | `owner(aoaProtocolRegistry) != aggregator` | O38 unchanged |
| 39 | `owner(reputationSystem) != aggregator` | O39 unchanged |
| 40 | `owner(blsAggregator) != aggregator` | O40 unchanged |
| 41 | `owner(dvtValidator) != aggregator` | O41 unchanged |
| 42 | `owner(xPNTsFactory) != aggregator` | O42 unchanged |
| 43 | `owner(paymasterFactory) != aggregator` | O43 unchanged |
| 44 | `owner(paymasterV4Impl) != aggregator` | O44 unchanged |
| 45 | `owner(microPaymentChannel) != aggregator` | O45 unchanged |
| 46 | `owner(x402Facilitator) != aggregator` | O46 unchanged |
| 47 | `aggregator ETH balance == 0` | O47 unchanged |
| 48 | `aggregator gToken balance == 0` | O48 unchanged |
| 49 | `aggregator aPNTs balance == 0` | O49 unchanged |
| 50 | `aggregator pnts balance == 0` | O50 unchanged |
| 51 | `generic executeProposal(batchUpdateGlobalReputation) rejected with ForbiddenGenericSelector` | O51 unchanged |
| 52 | `generic executeProposal(slash) rejected with ForbiddenGenericSelector` | O52 unchanged |
| 53 | `generic executeProposal(slashByDVT) rejected with ForbiddenGenericSelector` | O53 unchanged |
| 54 | `owner(superPaymaster) == expected` | O01, O33 — exact owner |
| 55 | `owner(registry) == expected` | O02, O34 — exact owner |
| 56 | `owner(staking) == expected` | O03, O35 — exact owner |
| 57 | `owner(gToken) == expected` | O04, O36 — exact owner |
| 58 | `owner(xPNTsFactoryV2) == expected` | O05, O37 — exact owner |
| 59 | `owner(aoaProtocolRegistry) == expected` | O06, O38 — exact owner |
| 60 | `owner(reputationSystem) == expected` | O07, O39 — exact owner |
| 61 | `owner(blsAggregator) == expected` | O08, O40 — exact owner |
| 62 | `owner(dvtValidator) == expected` | O09, O41 — exact owner |
| 63 | `owner(xPNTsFactory) == expected` | O42 — exact owner |
| 64 | `owner(paymasterFactory) == expected` | O43 — exact owner |
| 65 | `owner(paymasterV4Impl) == expected` | O44 — exact owner |
| 66 | `owner(microPaymentChannel) == expected` | O45 — exact owner |
| 67 | `owner(x402Facilitator) == expected` | O46 — exact owner |
| 68 | `owner(aPNTs) == expected` | New — aPNTs ownership |
| 69 | `pendingOwner(registry) == 0` | New — completed two-step ownership |
| 70 | `pendingOwner(superPaymaster) == 0` | New — completed two-step ownership |
| 71 | `pendingOwner(aPNTs) == 0` | New — completed two-step ownership |
| 72 | `roleConfigs[COMMUNITY].owner == timelock` | O10 — exact role owner |
| 73 | `deployer.hasRole(COMMUNITY) == false` | New — all deployer registrations removed |
| 74 | `roleConfigs[ENDUSER].owner == timelock` | O11 — exact role owner |
| 75 | `deployer.hasRole(ENDUSER) == false` | New — all deployer registrations removed |
| 76 | `roleConfigs[PAYMASTER_AOA].owner == timelock` | O12 — exact role owner |
| 77 | `deployer.hasRole(PAYMASTER_AOA) == false` | New — all deployer registrations removed |
| 78 | `roleConfigs[PAYMASTER_SUPER].owner == timelock` | O13 — exact role owner |
| 79 | `deployer.hasRole(PAYMASTER_SUPER) == false` | New — all deployer registrations removed |
| 80 | `roleConfigs[DVT].owner == timelock` | O14 — exact role owner |
| 81 | `deployer.hasRole(DVT) == false` | New — all deployer registrations removed |
| 82 | `roleConfigs[ANODE].owner == timelock` | O15 — exact role owner |
| 83 | `deployer.hasRole(ANODE) == false` | New — all deployer registrations removed |
| 84 | `roleConfigs[KMS].owner == timelock` | O16 — exact role owner |
| 85 | `deployer.hasRole(KMS) == false` | New — all deployer registrations removed |
| 86 | `deployer Registry role list empty` | New — all deployer registrations removed |
| 87 | `SP.treasury == expected` | O20 — exact authority |
| 88 | `staking.treasury == expected` | O21 — exact authority |
| 89 | `MySBT.daoMultisig == expected` | O22 — exact authority |
| 90 | `aggregator.slashPolicyAdmin == expected` | O23 — exact authority |
| 91 | `SP.guardian == expected` | O24 — exact authority |
| 92 | `PolicyRegistry.guardian == expected` | O25 — exact authority |
| 93 | `PolicyRegistry.timelock == expected` | New — explicit ceremony input / state invariant |
| 94 | `SP.APNTS_TOKEN == expected` | New — explicit ceremony input / state invariant |
| 95 | `APNTsCapped.minter == expected` | New — explicit ceremony input / state invariant |
| 96 | `APNTsCapped.capGuardian == expected` | New — explicit ceremony input / state invariant |
| 97 | `pmFactory.registry == expected` | New — explicit ceremony input / state invariant |
| 98 | `TL.minDelay == expected` | O27–O30 — ceremony delay / exact operation history |
| 99 | `APNTsCapped.cap == expected` | New — explicit ceremony input / state invariant |
| 100 | `SP.priceStalenessThreshold == expected` | New — explicit ceremony input / state invariant |
| 101 | `agg.minThreshold == expected` | New — explicit ceremony input / state invariant |
| 102 | `agg.defaultThreshold == expected` | New — explicit ceremony input / state invariant |
| 103 | `agg.slashThresholds[0] == input` | New — explicit ceremony input / state invariant |
| 104 | `agg.slashThresholds[1] == input` | New — explicit ceremony input / state invariant |
| 105 | `agg.slashThresholds[2] == input` | New — explicit ceremony input / state invariant |
| 106 | `expectedGuardian nonzero and not deployer` | New — explicit ceremony input / state invariant |
| 107 | `expectedSPGuardian nonzero and not deployer` | New — explicit ceremony input / state invariant |
| 108 | `genesisOperator nonzero and not deployer` | New — explicit ceremony input / state invariant |
| 109 | `Safe nonzero and not deployer` | New — explicit ceremony input / state invariant |
| 110 | `guardian N == inputs` | New — explicit ceremony input / state invariant |
| 111 | `guardian[1] registered` | O26 — configured guardian admission |
| 112 | `guardian[2] registered` | O26 — configured guardian admission |
| 113 | `genesis operator has COMMUNITY` | New — explicit ceremony input / state invariant |
| 114 | `genesis operator has PAYMASTER_SUPER` | New — explicit ceremony input / state invariant |
| 115 | `genesis isConfigured == false` | New — explicit ceremony input / state invariant |
| 116 | `H runtime non-callable` | New — explicit ceremony input / state invariant |
| 117 | `TL.DEFAULT_ADMIN_ROLE exact members` | O30 — exact membership / excluded H |
| 118 | `TL.DEFAULT_ADMIN_ROLE(H) == false` | O30 — exact membership / excluded H |
| 119 | `TL.DEFAULT_ADMIN_ROLE(safe) == expected` | O30 — exact membership / excluded H |
| 120 | `TL.PROPOSER_ROLE exact members` | O27 — exact membership / excluded H |
| 121 | `TL.PROPOSER_ROLE(H) == false` | O27 — exact membership / excluded H |
| 122 | `TL.PROPOSER_ROLE(safe) == expected` | O27 — exact membership / excluded H |
| 123 | `TL.EXECUTOR_ROLE exact members` | O28 — exact membership / excluded H |
| 124 | `TL.EXECUTOR_ROLE(H) == false` | O28 — exact membership / excluded H |
| 125 | `TL.EXECUTOR_ROLE(safe) == expected` | O28 — exact membership / excluded H |
| 126 | `TL.CANCELLER_ROLE exact members` | O29 — exact membership / excluded H |
| 127 | `TL.CANCELLER_ROLE(H) == false` | O29 — exact membership / excluded H |
| 128 | `TL.CANCELLER_ROLE(safe) == expected` | O29 — exact membership / excluded H |
| 129 | `TL.DEFAULT_ADMIN_ROLE(timelock) == true` | O30 — exact membership / excluded H |
| 130 | `config deployer == CLI` | New — explicit ceremony input / state invariant |
| 131 | `config governanceOwner == CLI` | New — explicit ceremony input / state invariant |
| 132 | `Safe code excludes delegation` | New — explicit ceremony input / state invariant |
| 133 | `Safe threshold/owners` | New — explicit ceremony input / state invariant |
| 134 | `Safe owners exclude deployer` | New 6b — Safe signer exclusion |
| 135 | `required principals pairwise distinct` | New — explicit ceremony input / state invariant |
| 136 | `deployer GToken balance == recorded` | New — funding ledger / readback |
| 137 | `deployer GToken allowance == recorded` | New — funding ledger / readback |
| 138 | `deployer SBT balance == recorded` | New — explicit ceremony input / state invariant |
| 139 | `SLASH_POLICY_ADMIN resolved contract` | New — explicit ceremony input / state invariant |
| 140 | `X402_OWNER resolved contract` | New — explicit ceremony input / state invariant |
| 141 | `REPUTATION_OWNER resolved contract` | New — explicit ceremony input / state invariant |
| 142 | `MPC_OWNER resolved contract` | New — explicit ceremony input / state invariant |
| 143 | `PAYMASTER_FACTORY_OWNER resolved contract` | New — explicit ceremony input / state invariant |
| 144 | `GToken recipient exact delta` | New — funding ledger / readback |
| 145 | `GToken mint ledger` | New — funding ledger / readback |
| 146 | `GToken mint events == ledger` | New — funding ledger / readback |
| 147 | `GToken totalSupply == mints` | New — funding ledger / readback |
| 148 | `GToken ticket ledger` | New — funding ledger / readback |
| 149 | `GToken stake[0]` | New — funding ledger / readback |
| 150 | `GToken stake[1]` | New — funding ledger / readback |
| 151 | `GToken stake[2]` | New — funding ledger / readback |
| 152 | `GToken stake[3]` | New — funding ledger / readback |
| 153 | `GToken stake[4]` | New — funding ledger / readback |
| 154 | `GToken conservation` | New — funding conservation / deployer residue (6c three-way accounting) |
| 155 | `GToken treasury tickets` | O21 — new 6c measured ticket receipts |
| 156 | `deployer GToken mint rejected` | New — funding ledger / readback |
| 157 | `TL history exactly H batch executed` | New — explicit ceremony input / state invariant |
| 158 | `registryImpl isolated` | New — implementation isolation (counted INFO-PASS) |
| 159 | `spImpl isolated` | New — implementation isolation (counted INFO-PASS) |
