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

Before TL CREATE: v5.4 CREATE/transfer/CREATE, five privilege transfers and one
unconditional GToken remainder transfer. The TL prediction is therefore +9 from
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
| Total tickets, paid back to then-treasury deployer | 74 |
| Deployer balance before remainder transfer | 2059 |
| Transfer to designated recipient | 2059 |
| Deployer final balance / staking allowance | 0 / 0 |

Ticket transfers return to the payer; they do not reduce supply. Conservation is
2199 = 140 locked + 2059 remainder. GToken owner is Safe; deployer mint is rejected.
Checker also reconstructs every mint from zero-source Transfer logs.

## Failed set: abandon and redeploy

Genesis COMMUNITY/PAYMASTER_SUPER and guardian DVT registrations, validator
admission, public keys/PoPs and threshold configuration stay before H because they
need the pre-handover owner. A reverted H CREATE leaves no H code and no external
party able to propose or execute via TL: predicted H alone retains P/E/C.
There is no recovery procedure. The failed set is **ABANDONED**, never published.

Run the normal checker and retain its FAIL with registration rows. Also run
`deploylive_failed_set_check.py <local-fork-rpc> <failed-config>`. It reads each
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

The complete valid-config checker count is **153 + 2N**: 157 for N=2, 159 for N=3.
This includes N guardian checks and N+3 stake checks; N/A and INFO rows do not count.
The two implementation-isolation assertions remain counted as INFO-PASS.
See DEPLOYLIVE_VALIDATION.md for exact test output and remaining evidence limits.
