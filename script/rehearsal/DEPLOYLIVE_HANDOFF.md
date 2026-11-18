# DeployLive round-seven governance ceremony

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
literal `timelock`, the exact literal `safe`, or a contract passing the Safe checks below. The declared choice is resolved, applied, asserted and recorded.

| Input | DSR ceremony choice | Authority |
|---|---|---|
| SLASH_POLICY_ADMIN | timelock | BLSAggregator slashPolicyAdmin |
| X402_OWNER | safe | X402Facilitator owner |
| REPUTATION_OWNER | timelock | ReputationSystem owner |
| MPC_OWNER | timelock | MicroPaymentChannel owner |
| PAYMASTER_FACTORY_OWNER | timelock | PaymasterFactory and Paymaster implementation owners |

`GOVERNOR_ADDRESS` must be absent on production, including an empty declaration.
The rejection points to `X402_OWNER`. Legacy local behavior still resolves governor.
`DEPLOYER_GTOKEN_RECIPIENT` is required and accepts `safe`, `timelock`, or a
contract passing the same Safe checks. Empty input has a named error. Explicit rehearsal choices are in
[inputs/deploylive-rehearsal.inputs](inputs/deploylive-rehearsal.inputs); this file
is never loaded implicitly by the production script.

BLSAggregator, DVTValidator, xPNTsFactory v1, xPNTsFactoryV2 and
AOAProtocolRegistry owners are always the Safe. Every slot is checked using
GovernanceOwnerGate.readMofN, exact address equality, contract code and rejection
of the EIP-7702 prefix. This proves a Safe-compatible threshold >= 2 with enough
unique nonzero owners, excluding the deployer. The script additionally requires
no enabled modules (including the pagination sentinel) and a zero guard. Explicit
owner/recipient contracts pass these same checks. The independent checker also
requires slot 0 to match the singleton allowlist and the fallback-handler slot to
match the handler allowlist in `deployments/safe-official.json`. That JSON cites
each address's repository source; no package download or network lookup was used.
This checks the requested storage and interfaces; it is not proxy bytecode attestation.
The general gate's local-chain bypass is not used for the production rehearsal.
GToken owner, MySBT DAO, both treasuries, APNTsCapped minter and capGuardian are Safe.
Registry, SuperPaymaster and APNTsCapped ownership goes to TL through H.
AOA Paymaster and legacy uncapped aPNTs are not deployed; the checker requires zero config addresses and no deployer paymaster in the factory.

## Bytecode and execution environment

Production `CREATION_PINS` must be exactly `deployments/creation-pins.<chainId>.json`;
missing files and rehearsal paths fail before broadcast. Chain 31337 production rehearsal also requires its committed
`deployments/creation-pins.31337.json`; the legacy rehearsal file is rejected. Config records the exact file's SHA-256. The OP file is
`deployments/creation-pins.10.json`; CI independently rebuilds and compares it.
Regeneration belongs to reviewed release preparation, never automatic deployment.
Generate or check it with `python3 script/rehearsal/creation_pins.py <pin-file> [--check]`.
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

For a Prague fork, retain **Cancun release artifacts in `out`** and set
`DEFAULT_ARTIFACTS_OUT=out`, while the forge runner uses `--evm-version prague`
and a separate `FOUNDRY_OUT` and `FOUNDRY_CACHE_PATH`. The independent checker
reads the reviewed release artifacts from `out`, not the deployment config.
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

Retain the normal checker FAIL and the separate inventory tool's registration rows. Also run
`deploylive_failed_set_check.py <local-fork-rpc> <failed-config>`. The external list
is [inputs/external-tokens.json](inputs/external-tokens.json), selected by
`eth_chainId`; the rehearsal inputs explicitly set `EXTERNAL_TOKENS_FILE`. Labels
and decimals are explicit metadata, never inferred from `symbol()`. The OP group
contains native USDC, USDC.e, bridged USDT, USDT0, DAI, WETH and OP; Sepolia
contains Circle USDC and both specified WETH deployments. Unknown chains and
empty groups FAIL. Pass `--external-tokens <worktree-file>` to failure mode. It writes the supplied
groups into the abandoned config as `externalTokens`; supply a
`"31337"` group of deployed mock tokens (each entry: `label`, `address`, `decimals`).
Every listed address must have code before any balance call; missing code FAILs
and its balance is never read. Every listed token is read directly against every
contract in the failed set and must return an ABI uint256 equal to zero. Empty,
malformed or reverted reads FAIL. The Transfer scan remains a fallback for
unlisted tokens. It reads each
recorded contract's ETH balance, discovers incoming Transfer-emitting tokens from
the recorded `deploymentStartBlock`, reads balances for every discovered token/holder,
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
Invocation: `deploylive_rehearse.py MODE LOCAL_RPC CONFIG DEPLOYER SAFE [OPERATOR] [--external-tokens FILE]`.
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

## Reviewed external dependencies

`deployments/external-deps.10.json` records the owner-provided OP verification at
block 159689777. `external-deps.31337.json` is explicitly a fixture group. Other
chain IDs fail until their reviewed file exists. Production defaults identity and reputation to ZERO; explicit opt-in must match
the reviewed file. The validation address is recorded only, never wired to SP.
The checker obtains chainId itself and checks SP feed, EntryPoint, identity and
reputation getters, account-factory config and recorded validation address against
that file. It does not take expected dependency addresses from deployer inputs.

## Transaction counts and checker count

Transactions before H: **86 + 3N + c + a**, where c=1 if minimum threshold <3,
and a=1 when agent registries are wired. OP defaults to a=0. For N=3, c=1 this is **96**, plus H itself makes 97 broadcasts.
The explicit a=1 fixture has **97** before H, 98 including H. The agent
registry call is in Step 5, before Step 8/v5.4 and before CREATE TL. Thus the
v5.4-relative **+7** and TL-to-H **22** remain valid; default-off and explicit-on N=3 fixtures
independently count the transactions and both nonce distances. The opt-in local
forge regression uses the enabled 31337 fixture expectations.

The valid-config checker count is **172 + 2N**: **176 for N=2**, **178 for N=3**.
Relative to round 6c, there are 17 additional rows: two formerly N/A rows, pending
SBT burn, four Safe checks, six external-dependency rows, three runtime comparisons,
and the recipient authority row. N guardian rows and N+3 stake rows vary with N.
Implementation-isolation INFO-PASS rows count; ordinary INFO and fail-fast input
errors do not. Failed-set inventory has a separate result.

## Final handover assertions mapped to checker rows

This maps every assertion in `_assertHandover`, its Safe gate and
`TimelockHandover.assertFinal`. Rows are named rather than numbered so N does not
change the mapping. Existing negative probes are retained; mapping coverage does
not claim every require has an isolated mutation test.

| In-script assertion | Independent checker row(s) |
|---|---|
| SBT balance zero | deployer SBT balance == recorded (recorded must also be zero) |
| No pending SBT burn | deployer pending SBT burn == false |
| PolicyRegistry timelock / guardian | PolicyRegistry.timelock / PolicyRegistry.guardian == expected |
| TL delay 172800 | TL.minDelay == expected |
| Three two-step owners / pendingOwner zero | owner(registry/superPaymaster/aPNTs) == expected; pendingOwner(...) == 0 |
| TL self-admin; Safe P/E/C; no forbidden subject roles | TL role exact members, safe/H/deployer memberships, TL self-admin |
| Safe code, non-7702, threshold, owners excluding deployer | Safe code excludes delegation; Safe threshold/owners; Safe owners exclude deployer |
| Safe modules empty / guard zero | Safe modules empty; Safe guard zero |
| Deployer staking allowance zero | deployer GToken allowance == recorded |
| H constructor-only runtime | H runtime non-callable (prefix/length check); creation pins bind exact H |
| Facilitator and ten single-step owners | owner(each contract) == expected |
| Five gated owners equal Safe and pass threshold/code gate | owner(each contract) == expected; Safe code/threshold/owners rows |
| Minted supply | GToken mint ledger; GToken mint events == ledger; GToken totalSupply == mints |
| Each locked stake / ticket treasury | GToken stake[i]; GToken ticket ledger |
| Locked + tickets + remainder conservation | GToken conservation |
| Treasury ticket delta | GToken treasury tickets |
| Deployer GToken zero / recipient delta | deployer GToken balance == recorded; GToken recipient exact delta |
| Seven Registry role owners / deployer holds none | roleConfigs[role].owner == timelock; deployer.hasRole(role) == false |
| Empty deployer Registry role list | deployer Registry role list empty |
| No deployer DVT / reputation-source privilege | DVT.isValidator(deployer) == false; isReputationSource(deployer) == false |
| GToken owner / MySBT DAO | owner(gToken) == expected; MySBT.daoMultisig == expected |
| Both treasuries | SP.treasury / staking.treasury == expected |
| SP guardian / slash admin | SP.guardian / aggregator.slashPolicyAdmin == expected |
| Minimum/default/slash thresholds | agg.minThreshold / agg.defaultThreshold == expected; agg.slashThresholds[i] == input |
| Guardian slots | guardian[i] registered |
| Cap / minter / capGuardian | APNTsCapped.cap / minter / capGuardian == expected |
| Oracle staleness threshold | SP.priceStalenessThreshold == expected |
| Genesis registered, not configured | genesis operator has COMMUNITY/PAYMASTER_SUPER; genesis isConfigured == false |

## Remaining acceptance evidence and known gaps

The local Anvil regression is `DEPLOYLIVE_LOCAL_TEST=1 python3 -m unittest discover
-s script/rehearsal -p 'test_deploylive_local.py'`. It uses deterministic public test
BLS material, fixture infrastructure and a fixture Safe, then invokes the actual
DeployLive production/rehearsal path. The checker receives the untouched file
written by forge. **It could not run in this sandbox: loopback bind was denied.**
No real-forge-config SUMMARY or live failure-mode inventory is claimed. Execute
these acceptance steps in the authorized parent session; the current offline
results do not authorize deployment acceptance.

The checker runtime comparison intentionally covers only Registry implementation,
SuperPaymaster implementation and TimelockController, masking compiler immutable
references. The bytecode of every other contract must be evidenced by block-explorer
source verification in the deployment runbook, with compiler settings, constructor
arguments, address and verification result recorded. H's exact creation pin remains
part of preflight; its checker runtime row is a non-callability check.

Registry/SP implementation owners remain recorded and isolated as before; this
round does not transfer them. Existing artifact, wiring and v5.5 stack checks remain
in the deployment script; the table above is the final handover assertion mapping,
not a claim of checker parity for every historical deployment helper.

Listed external-token balances cover prefunding even though Transfer discovery
starts at deployment. Unlisted tokens received before that block, or tokens without
Transfer events, remain an inventory limitation. Never call the inventory exhaustive.

Fail-first evidence is specific to named regressions and the three run-level
mutations. The suite does not establish an exhaustive mutation proof of all
historical assertions. See DEPLOYLIVE_VALIDATION.md for exact results and logs.

## Round 7b — agent registries default OFF (DSR, 2026-11-18)

OP launch uses a=0: identity and reputation inputs default to ZERO and
DeployLive does not call setAgentRegistries. The three recorded OP registries are
130 B EIP-1967 proxies owned by the unattributed EOA
`0x547289319C3e6aedB179C0b8e8aF0B5ACd062603` (nonce 3).
One implementation upgrade by that key could make isRegisteredAgent return true
for anyone. SuperPaymaster calls it in validatePaymasterUserOp for eligibility
(SuperPaymaster.sol:525/533), giving any account operator-funded sponsorship.
setAgentRegistries is onlyOwner, so removing or changing SP's pointer takes the
48 h timelock. The addresses remain recorded, non-binding information in
external-deps.10.json; expected identity and reputation are ZERO.

Production opt-in requires ENABLE_AGENT_REGISTRIES=1 and both
AGENT_IDENTITY_REGISTRY and AGENT_REPUTATION_REGISTRY to be nonzero and equal the
reviewed external-deps.<chainId>.json expectations. Nonzero addresses without
the switch, a switch with either zero address, invalid switch values, and
mismatched enabled addresses revert during preflight. OP's reviewed zero
expectations therefore prevent opt-in without a reviewed dependency-file change.
The switch and both values are logged; config records enableAgentRegistries and
the actual agentIdentityRegistry / agentReputationRegistry pointers. The checker
compares both on-chain getters against the expected file, including ZERO on OP.

**Known testnet exposure:** Sepolia live SP
`0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9` has
agentIdentityRegistry = `0x8004A818BFB912233c491871b3d84c89A494BD9e` and
agentReputationRegistry = `0x8004B663056A597Dffe9eCcC1965A193B7388713`.
Both are 130 B proxies owned by the same EOA. The rc.8 Sepolia manifest does
not call setAgentRegistries; the in-place upgrade keeps storage, so both pointers
stay set after rc.8 on the testnet. These are owner-provided findings; this round
performed no network verification.
