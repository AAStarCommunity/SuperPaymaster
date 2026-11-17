# OP mainnet release parameters — SP inventory for §6 (DeployLive @ main cdb59d06)

> **Author tool:** Codex (read-only, inside the sp-wt/rc8-bls worktree; no network, chain, .env or keystore).
> **SP spot-check:** I checked key claims against source myself: legacy aPNTs DL:160-162, no APNTsCapped in DeployLive, SP.initialize staleness 4200 DL:173, EntryPoint funding DL:518-519.
> **Gas figures:** taken from the 1845b124 OP-fork rehearsal receipts. Fork gas prices are not mainnet prices.

The main discrepancy is that **DeployLive does not produce the governance configuration described in the release table**. It also deploys an **uncapped legacy xPNTs aPNTs token**, sets price staleness to **4,200 seconds**, and leaves operator transaction intervals at **0**, not 60 seconds.

Source findings below describe the current worktree. Receipt and post-deployment findings describe the supplied **1845b124 fork rehearsal**, not a rehearsal of cdb59d06. I did not access the network, chain, environment files, or keystores.

For compact source references:

- **DL** = [contracts/script/v3/DeployLive.s.sol](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/script/v3/DeployLive.s.sol)
- **V54** = [contracts/script/v3/V54Bootstrap.sol](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/script/v3/V54Bootstrap.sol)
- **V55** = [contracts/script/v3/V55Bootstrap.sol](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/script/v3/V55Bootstrap.sol)
- **DA** = [contracts/script/v3/DefaultArtifacts.sol](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/script/v3/DefaultArtifacts.sol)
- **Gate** = [contracts/script/checks/GovernanceOwnerGate.sol](/Users/jason/Dev/aastar/sp-wt/rc8-bls/contracts/script/checks/GovernanceOwnerGate.sol)
- Other Solidity filenames refer to their paths under `contracts/src/`, unless explicitly identified as scripts.

**A. Environment variables and external inputs**

“Required” means omission causes failure on the relevant production execution path, rather than merely leaving an undesirable default. Conditional branches are identified explicitly.

| Name | Read via | Default when unset | Falls back to | File:line | Required on production | Note |
|---|---|---|---|---|---|---|
| `ENTRY_POINT` | `vm.envAddress` | None | Nothing | DL:90 | Yes | External EntryPoint address; no network-address lookup. |
| `ETH_USD_FEED` | `vm.envAddress` | None | Nothing | DL:91 | Yes | External Chainlink feed. |
| `SIMPLE_ACCOUNT_FACTORY` | `vm.envAddress` | None | Nothing | DL:92 | Yes | Recorded in config; DeployLive does not deploy it. |
| `DEPLOYER_ADDRESS` | `vm.envOr(address(0))`, then `envAddress` | Zero | `msg.sender` | DL:97–100 | No | This selects deployment principals; it does not select the broadcast signing key. Wrapper can derive it from the keystore. |
| `PRIVATE_KEY_ANNI` | `vm.envOr(uint256(0))`; conditional `envUint` | Zero | Skip Mycelium entirely | DL:199,247,556 | No | Nonzero enables Mycelium registration, token creation, funding and explicit Anni broadcast. No production-chain guard disables this branch. |
| `GOVERNANCE_OWNER` | `vm.envOr(address(0))` through Gate | Zero | Ownership transfers skipped; original owners remain | Gate:298,358,527; DL:313–353 | **Yes** | Optional read, but final production gate fails without a declared matching Safe-compatible owner. Must satisfy threshold ≥2 and valid distinct owners. |
| `GOVERNOR_ADDRESS` | `vm.envOr(address)` | `deployer` | Deployer EOA | V54:79 | **No** | Controls X402Facilitator ownership and timelock proposer/executor/additional-admin roles. Does not default to `GOVERNANCE_OWNER`. |
| `GUARDIAN_ADDRESS` | `vm.envOr(address)` | `deployer` | Deployer EOA | V54:80,130–132 | **No** | Used for **PolicyRegistry.guardian only**. Does not set SP.guardian. |
| `LOCAL_DEV_GOVERNANCE_ACK` | `vm.envOr(bool)` | `false` | No local bypass | Gate:312–350 | No on production | Read only on chain ID 31337; there it must be true and block number <1,000,000. |
| `TESTNET_EOA_OWNER_ACK` | `vm.envOr(bool)` | `false` | Reject testnet EOA ownership | Gate:407–432 | No on production | Production EOA owners fail before this acknowledgment can help. |
| `AGENT_IDENTITY_REGISTRY` | `vm.envOr(address)` | Chain-dependent address | Built-in mainnet/testnet identity registry; zero on unsupported chains | DL:478–493 | No | OP default listed below. |
| `AGENT_REPUTATION_REGISTRY` | `vm.envOr(address)` | Chain-dependent address | Built-in mainnet/testnet reputation registry; zero otherwise | DL:478–494 | No | Identity and reputation are wired only when both resolve nonzero. |
| `AGENT_VALIDATION_REGISTRY` | `vm.envOr(address)` | Chain-dependent address | Built-in mainnet/testnet validation registry; zero otherwise | DL:478–495 | No | Recorded in config, not wired into SP. |
| `ENV` | `vm.envString` | None in DeployLive | Nothing | DL:627–628 | Yes for direct DeployLive | Determines output `deployments/config.<ENV>.json`. Wrapper supplies it. |
| `DEPLOY_TIME` | `vm.envOr(string)` | `"N/A"` | Metadata placeholder | DL:678 | No | Wrapper supplies local `date` output. |
| `DEFAULT_ARTIFACTS_OUT` | `vm.envOr(string)` through parameterized helper | `"out"` | Worktree build-artifact directory | DA:189–196 | No | Must be a valid relative directory. Missing/stale/nonmatching artifacts still fail. |

Chain-dependent defaults in DL:483–490:

| Input | OP/mainnet-family default | Testnet-family default |
|---|---|---|
| Identity | `0x8004A169FB4a3325136EB29fA0ceB6D2e539a432` | `0x8004A818BFB912233c491871b3d84c89A494BD9e` |
| Reputation | `0x8004BAa17C55a88189AE136b182e5fdA19dE9b63` | `0x8004B663056A597Dffe9eCcC1965A193B7388713` |
| Validation | `0x8004Cc8439f36fd5F9F049D9fF86523Df6dAAB58` | `0x8004Cb1BF31DAf7788923b405b754f57acEB4272` |

The mainnet-family chain IDs are `1,10,137,8453,42161,43114,56,534352`; testnet-family IDs are `11155111,11155420,84532,421614,80002`.

I searched `vm.env` in DL, both bootstraps, DefaultArtifacts, GovernanceOwnerGate, first-party contracts, and the relevant dependency trees. **V55Bootstrap and SPReleaseVersion add no environment reads.** Inherited Forge `StdChains` contains dynamic RPC environment reads at `contracts/lib/forge-std/src/StdChains.sol:162,164`, but DeployLive never calls that chain-resolution path. Those are not additional executed deployment inputs.

The non-anvil wrapper adds these inputs:

| Name | Read via | Default when unset | Falls back to | File:line | Required on production | Note |
|---|---|---|---|---|---|---|
| Environment argument `$1` | Shell | `anvil` | Local deployment route | `deploy-core:8` | Yes to select a non-anvil route | E.g. `optimism`; used in filenames and RPC variable name. |
| `.env.<ENV>` | Shell `source` | File may be absent | Existing process environment | `deploy-core:9–13` | No for core wrapper | Contents were not read. It is executable shell input, not a fixed-schema data file. |
| `<UPPERCASE_ENV_WITH_UNDERSCORES>_RPC_URL` | Shell indirect expansion | `$RPC_URL` | Generic endpoint | `deploy-core:20–29` | One of the pair required | `optimism` → `OPTIMISM_RPC_URL`; `op-mainnet` → `OP_MAINNET_RPC_URL`. |
| `RPC_URL` | Shell | Empty | Nothing | `deploy-core:23–29` | Yes if specific URL absent | Empty final URL exits. |
| `--force` | Shell substring match on `$*` | `false` | Hash-based skip decision | `deploy-core:47–50,65` | No | Does **not** force fresh proxies; existing config can still select UpgradeLive. |
| `--fresh-deploy` | Shell substring match | `false` | Existing-config routing | `deploy-core:50,132–139` | No | Forces DeployLive and prompts on live networks. |
| Confirmation stdin | Shell `read` | No affirmative answer | Abort | `deploy-core:57–60` | Conditional | Must equal `yes` when `--fresh-deploy` is used. |
| `DEPLOYER_ACCOUNT` | Shell → `cast`/Forge `--account` | Empty | `PRIVATE_KEY` | `deploy-core:156–173` | One signer required | Keystore takes priority. |
| Keystore/password | `cast wallet address` / Forge signer | No wrapper default | Nothing | `deploy-core:164,170,195` | Conditional | External signer material; not inspected. |
| `DEPLOYER_ADDRESS` | Shell | Derive via `cast wallet address --account` | Keystore address | `deploy-core:160–166` | No | Already-configured value bypasses address-resolution prompt. |
| `PRIVATE_KEY` | Shell → Forge `--private-key` | Empty | Nothing on non-anvil | `deploy-core:171–178` | Yes if no account | Unlike anvil, no built-in key fallback. |
| `CONFIG_FILE` | Wrapper-generated export | `config.<ENV>.json` | Not caller-selectable here | `deploy-core:79` | No user input required | Used by checks, **not** by DeployLive’s config writer. |
| `ENV`, `DEPLOY_TIME` | Wrapper-generated exports | Selected environment; current local date/time | Shell values | `deploy-core:86–87` | No user input required beyond environment selection | Overrides inherited values at this point. |
| Existing deployment config | Shell `jq` | Missing file means fresh deployment | DeployLive | `deploy-core:45,65–76,132` | No for fresh deployment | `.srcHash` controls skip; nonzero `.registry` controls upgrade routing. |
| Source/build/tooling files | `find`, `shasum`, Forge | No substitute | Current worktree | `deploy-core:39–44,194–195` | Yes operationally | Hash includes sources, scripts, Foundry/remappings and listed tooling. |
| ABI artifacts under `out` | Shell `find`/`jq` | Missing individual ABI skipped | None | `deploy-core:199–203` | No for ABI copy | Separate from mandatory deployment artifact validation. |

`SRC_HASH` is **not an executed DeployLive environment read**. The wrapper comments at lines 80–84 are stale for this script: DL:676–677 writes an empty string directly; the wrapper writes the real hash after audit.

Because `deploy-core` invokes additional programs, these conditional inputs also matter:

| Name | Read via | Default when unset | Falls back to | File:line | Required on production | Note |
|---|---|---|---|---|---|---|
| `CONFIG_FILE` in audit checks | `vm.envOr(string)` | Most older checks: `anvil.json`; Check11/default-artifact check: `config.anvil.json` | Default deployment config | `checks/Check01_GToken.s.sol:11`; Check02:11; Check03:11; Check04:11; Check07:11; Check08:41; Check10:22; Check11:69; VerifyV3_1_1:22; CheckDefaultArtifacts:56 | No | `audit-core:155` explicitly passes the selected filename. Paths are under `contracts/script/checks/`. |
| `PRIVATE_KEY` / `DEPLOYER_ADDRESS` in verification | `envOr(uint256(0))` / `envAddress` | Zero key → require address | Key-derived address, otherwise declared address | `checks/VerifyV3_1_1.s.sol:28–32` | One required | Here the private key takes priority, unlike wrapper account selection. |
| `CONFIG_PATH` | `vm.envOr(string)` | `""` | `projectRoot/deployments/CONFIG_FILE` | `checks/CheckDefaultArtifacts.s.sol:54–56` | No | Overrides config path for this checker only. |
| `EXPECT_AGGREGATOR_ROTATION_TO` | `vm.envOr(address)` | Zero | No explicit expected rotation target | `checks/Check11_AggregatorPointers.s.sol:128` | No | Audit expectation, not deployment setter. |
| `APNTS_EXPECTED_CAP` | `vm.envOr(uint256)` | 300,000e18 on chains 1/10; 10,000,000e18 elsewhere | Checker’s expected cap | `checks/CheckDefaultArtifacts.s.sol:325–326` | No | Read only for direct APNTsCapped, not DeployLive’s legacy clone. |
| `APNTS_EXPECTED_MINTER` | `vm.envOr(address)` | OP Safe `0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114` | Fixed checker expectation | `checks/CheckDefaultArtifacts.s.sol:340` | No | Same capped-token branch. |
| `APNTS_EXPECTED_CAP_GUARDIAN` | `vm.envOr(address)` | Same OP Safe | Fixed checker expectation | `checks/CheckDefaultArtifacts.s.sol:341` | No | Same capped-token branch. |
| Audit config, stamps, ABI files and live code/state | Shell/`vm.readFile`, JSON parsing, RPC | Missing stamps → rerun | Current config/state | `audit-core:45–60,77–105,145–157,168 onward` | Config/state required | Audit is invoked even on deployment-skip route. |
| Upgrade config | `vm.readFile` / JSON parsing | None for required keys; zero for optional addresses | Existing proxies and module addresses | `v3/UpgradeLive.s.sol:69–92` | Yes on upgrade branch | Requires registry, SP, EntryPoint, priceFeed, legacy factory. Optional microPaymentChannel/X402/timelock/policy addresses. |
| `ENV`, `DEPLOY_TIME` on upgrade branch | `vm.envOr(string)` | `sepolia`, `N/A` | Upgrade defaults | `v3/UpgradeLive.s.sol:69,232` | No | Shares V54 and DefaultArtifacts inputs already listed. |
| Testnet preparation keys | `vm.envOr(uint256)` plus explicit requires | Built-in anvil keys only on anvil | No usable non-anvil fallback | `v3/TestAccountPrepare.s.sol:61–79` | Not invoked on production names | For `sepolia`/`op-sepolia`, **both** `PRIVATE_KEY` and `PRIVATE_KEY_ANNI` are required; keystore alone is insufficient. |
| `PRIVATE_KEY_ANNI` in test-account checker | `vm.envOr(uint256)` | Built-in anvil account 1 key | Anvil account 1 | `checks/Check09_TestAccounts.s.sol:32` | No | Wrapper only reaches this through testnet preparation; preparation already requires keys. |
| `ETHERSCAN_API_KEY` | Shell | Empty | Nothing | `scripts/verify-all.sh:85–88` | No for overall deploy-core; yes for verification substep | Wrapper treats verification failure as nonfatal. |
| Verification `.env.<ENV>` | Shell `source` | Missing file → verifier exits | None | `scripts/verify-all.sh:52–61` | Same conditional status | Unlike deploy-core itself, this helper requires the file. |
| Verification RPC/signer inputs | Shell | Specific RPC → generic RPC; address → account → key | Listed alternatives | `scripts/verify-all.sh:66–79,123–137` | Conditional | Same variable names as above. |
| Verification config | Shell `jq` | `deployments/config.<ENV>.json` → `contracts/deployments/config.<ENV>.json` | Alternate config location | `scripts/verify-all.sh:91–119` | Conditional | Reads deployment addresses, including legacy `blsValidator`. |
| Report environment/config/date | `process.argv[2]`, file read, system clock | Missing network/config fails helper | No data fallback | `scripts/generate-verification-report.ts:30–46,58–60` | No | Nonfatal report step; no `process.env` reads. |

Additional non-environment inputs on the DeployLive call path:

| Name | Read via | Default when unset | Falls back to | File:line | Required on production | Note |
|---|---|---|---|---|---|---|
| Broadcast signer / `msg.sender` | Forge CLI, `vm.startBroadcast()` | Host-tool selection | Script caller if no deployer override | DL:97–106,593,623 | Valid signer required | Anni branch uses its own explicit key. |
| Chain ID, block number, timestamp | EVM context | No script default | Selected RPC chain | DL:478,510; Gate:312–334 | Yes operationally | Affects registry defaults, governance gate and price initialization. |
| Chainlink `latestRoundData()` | External contract call | No constant price fallback | DVT initialization attempt, then `updatePrice()` | DL:507–515 | Stateful dependency | Outer feed-read failure is swallowed; a valid cache is not guaranteed merely by setting the address. |
| Governance account code, threshold, owners | Code inspection and static calls | None | Reject invalid governance | Gate:155–205,360–395 | Yes | Requires a matching declared Safe-compatible owner. |
| Artifact JSON and current source files | `vm.readFile`, JSON parsing, `vm.getCode` | Candidate artifact layouts | Another matching layout of the same build | DA:63–65,150–182,221–255 | Yes | Checks solc 0.8.33, Cancun, viaIR, runs 500 except Registry 200, and source hashes. |
| Deployed code, clone implementations, proxy slots and wiring | Contract calls, `.code`, `vm.load` | None | Assertions fail on mismatches | DL:257–290,384–420; V55:187 onward; V54:270–271 | Yes | These are external-state inputs, not independently configurable environment knobs. |
| Factory token list and token ownership/capabilities | External calls/static calls | Unsupported or non-owned token skipped | Manual follow-up | V54:169–234 | No | Controls facilitator wiring. Fresh aPNTs is expected to support it. |
| Project root/output directory access | `vm.projectRoot`, file operations | Foundry project root | None | DL:628,681; DA:64 | Yes operationally | DeployLive writes config only at the end. |

The precise values or additional behavior introduced by sourced `.env` shell code, installed tools, ambient Foundry configuration, or keystore contents are **undetermined** under the permitted reads. They are not assumed to be empty.

**B. Values to fill or correct in the table**

**3.2 — Deployment gas and ETH**

Calculated directly from **all 78 receipts** in the supplied `broadcast.json`; all receipt statuses are successful:

| Scope | Receipts | Sum `gasUsed` | Sum `gasUsed × effectiveGasPrice` |
|---|---:|---:|---:|
| Deployer `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` | 73 | 66,595,254 | 467,254,865,162 wei |
| Anni `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` | 5 | 988,303 | 136,818,003 wei |
| **Total** | **78** | **67,583,557** | **467,391,683,165 wei = 0.000000467391683165 ETH** |

Recorded effective gas prices range from **131 to 24,505 wei/gas**. **These fork prices are not OP mainnet prices.** The receipts contain no OP L1-fee field, so this multiplication does not establish a complete mainnet transaction-fee budget.

The script also transfers **0.35 ETH**, separately from fees:

- SP EntryPoint deposit: **0.1 ETH**, DL:518.
- SP EntryPoint stake: **0.1 ETH**, unstake delay **86,400 seconds**, DL:519.
- AOA paymaster stake: **0.1 ETH**, delay **86,400 seconds**, DL:540.
- AOA EntryPoint deposit: **0.05 ETH**, DL:549.

The broadcast transactions’ value fields independently sum to **350,000,000,000,000,000 wei**.

Recommended budgeting expression:

`ETH budget = 0.35 ETH + (G × P_L2 × safety_factor + separately estimated OP L1/operator fees) / 1e18`

Here `G` is gas for the **actual release transaction set**, and `P_L2` is a contemporaneous mainnet fee assumption in wei/gas. The supplied rehearsal gives `G = 67,583,557` including optional Mycelium work. A final mainnet ETH amount is **undetermined**: the selected deployment branch, release-code gas, mainnet prices and additional OP fees are not supplied.

**3.4 — Genesis communities and operators**

| Community/operator | Address derivation | Roles actually registered | Effective GToken stake / entry ticket | Source |
|---|---|---|---|---|
| AAStar, ENS `aastar.eth` | `DEPLOYER_ADDRESS`, otherwise `msg.sender` | `COMMUNITY`, `PAYMASTER_AOA` | COMMUNITY: **0 / 30**; AOA: **30 / 3** | DL:154–158,545–546; `core/Registry.sol:104–117,301–304` |
| Mycelium Community, ENS `mushroom.box` | `vm.addr(PRIVATE_KEY_ANNI)` | Conditional `COMMUNITY`, `PAYMASTER_SUPER` | COMMUNITY: **0 / 30**; SUPER: **50 / 5** | DL:555–577; `core/Registry.sol:104–117,301–304` |

The community data structs contain `stakeAmount: 30 ether`, but Registry’s `_enforceMinStake` returns **zero when role minStake is zero**. The community payment is the **30 GToken entry ticket**, not a 30 GToken locked stake. Ticket payments go to staking treasury; comments describing them as “burn” are stale (`core/GTokenStaking.sol:144–156`).

For the supplied rehearsal:

- AAStar/deployer: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`.
- Mycelium/Anni: `0x70997970C51812dc3A010C7d01b50e0d17dc79C8`.
- Broadcast transaction 60, using zero-based indexing, creates Mycelium PNTs from the Anni address; the config contains nonzero `pnts`.
- Thus **the optional Anni path did run in this rehearsal**.

AAStar receives a legacy aPNTs token and an AOA paymaster. DeployLive does **not** register AAStar as `PAYMASTER_SUPER`. Mycelium receives a V2 PNTs token, operator treasury equal to Anni, 1,000 aPNTs funding/deposit and 500 PNTs minting (DL:583–615).

**No DVT validators/BLS public keys are registered by DeployLive.** The `1` passed to DVTValidator is the first proposal ID, not validator count or quorum (`DL:181`; `modules/monitoring/DVTValidator.sol:142–148`).

**All 4.x rows**

| Row | Actual fresh DeployLive value | Evidence and correction |
|---|---|---|
| **4.1 Community fee / minimum stake** | **30 GToken / 0** | `core/Registry.sol:104–110`; initialized through DL:119–120. |
| **4.2 End-user fee / minimum stake** | **0.3 GToken / 0** | Same initializer matrix. |
| **4.3 Super operator minimum stake** | **50 GToken**, plus **5 GToken entry ticket** | `core/Registry.sol:108–110`. SP checks live effective stake against this Registry role configuration; it has no separate fixed GToken minimum (`paymasters/superpaymaster/v3/SuperPaymasterStorage.sol:387–395`). The 1,000 aPNTs Mycelium deposit is bootstrap funding, not the role minimum. |
| **4.4 Protocol fee** | **1,000 bps = 10%** | `SuperPaymaster.sol:132–133`. Setter permits **0–2,000 bps inclusive** (`SuperPaymasterAdmin.sol:270–275`; `SuperPaymasterStorage.sol:253`). |
| **4.5 Price-cache validity** | **4,200 seconds** | Explicit argument DL:173. The initializer’s 3,600-second fallback is not used (`SuperPaymaster.sol:125–130`). |
| **4.6 Settlement gas triple** | **500,000 / 450,000 / 450,000** | Effective defaults for `minPostOpGas / settleGasBound / cPostop`; no deployment override. `SuperPaymasterStorage.sol:235–238,444–447`. Additional `cWrap = 5,000`. |
| **4.7 Credit tiers** | **100 / 100 / 300 / 600 / 1,000 / 2,000**, each ×1e18 | `core/Registry.sol:150–155`. V2 token credit policy remains its zero/default OFF state; DeployLive does not enable it. V2 tier source is wired at creation (`V55:167`; `tokens/v2/xPNTsTokenV2.sol:102–107`). |
| **4.8 Operator minimum interval** | **0 seconds**, including newly configured Mycelium | `configureOperator` does not write `minTxInterval` (`SuperPaymasterAdmin.sol:145–172`); only `setOperatorLimits` changes it at :175–178, and DeployLive never calls it. **60 seconds is not a DeployLive setting.** |
| **4.9 aPNTs cap / price** | Legacy xPNTs clone; **no enforced mint cap**; `issuanceCap = 0`; **$0.02** price | DL:161–163 deploys through legacy factory; no `setIssuanceCap`. `tokens/xPNTsToken.sol:190,1051–1056`: mint has no cap check. SP price is `0.02e18` (`SuperPaymaster.sol:132`); legacy and V2 factories independently initialize the same price (`xPNTsFactory.sol:188`; `tokens/v2/xPNTsFactoryV2.sol:248`). |

For 4.6, “治理只能调高” needs clarification: the code enforces **absolute floors and bounds**, not monotonic increases relative to the currently configured values. Previously raised settings can be lowered within those constraints (`SuperPaymasterAdmin.sol:314–351`).

For 4.9, distinguish three separate concepts:

1. **DeployLive issuance:** mint **20,000 aPNTs** to deployer, exchange rate **1e18**, no hard cap (DL:162,551–552).
2. **Legacy over-issuance monitoring:** default category baseline **$10,000**, cap ratio **10,000 bps**, plus qualifying SP backing. With this fresh aPNTs token’s 1:1 rate, $0.02 price and no linked SUPER operator backing, that baseline corresponds to **500,000 aPNTs**. It is an `isOverIssued()` reporting threshold, **not a mint limit** (`xPNTsFactory.sol:199–205`; `xPNTsToken.sol:810–867`).
3. **Separate APNTsCapped flow:** `DeployAPNTsCapped.s.sol` documents **300,000 aPNTs** as the decided mainnet cap, but on chains 1/10 still requires explicit nonzero `APNTS_CAP`; Sepolia/anvil use **10,000,000 aPNTs** as a test value (`contracts/script/v3/DeployAPNTsCapped.s.sol:84–87,179–191`). **DeployLive does not call that flow**, and the supplied config is not evidence that APNTsCapped was deployed.

SP aPNTs price changes have absolute bounds **$0.001–$1,000** and a **±10% per-update** restriction (`SuperPaymasterAdmin.sol:40–41,250–266`).

**5 — SimpleAccountFactory**

The supplied `config.json` contains:

`0x91E60e0613810449d098b0b5Ec8b51A0FE8c8985`

DeployLive reads it from **`SIMPLE_ACCOUNT_FACTORY`**, not from a built-in OP constant (`DL:92`), and writes it to config at `DL:642`. Its chain code and provenance were not independently verified.

**Existing governance rows also need corrections**

| Table row | What DeployLive actually does |
|---|---|
| 1.1 | `GOVERNANCE_OWNER` receives BLSAggregator, DVTValidator, legacy aPNTs community ownership, legacy factory, V2 factory and AOAProtocolRegistry. `GOVERNOR_ADDRESS` separately controls X402Facilitator and timelock roles. DL:313–353; V54:108–132. |
| 1.2 | Timelock delay is **172,800 seconds**, but **SP, Registry and staking remain deployer-owned**; DeployLive does not deploy APNTsCapped or transfer those contracts to the timelock. DL:119,132,173; V54:61,121. |
| 1.3 | The timelock receives **governor as additional admin**, alongside its own administration. No admin renunciation occurs. V54:119–122. |
| 1.4 | `GUARDIAN_ADDRESS` sets PolicyRegistry guardian. **SP.guardian remains zero.** V54:130–132; `SuperPaymasterStorage.sol:179`. |
| 1.5 | GToken owner remains deployment broadcaster; no Safe handover in DeployLive. DL:125–128 and supplied postdeploy evidence. |
| 1.6–1.8 | SP treasury, staking treasury and MySBT DAO multisig are all initialized to **deployer**. DL:132–134,173. |
| 1.9 | All seven role owners remain **deployer**. `core/Registry.sol:119–121`. |
| 2.1–2.4 | No validators enrolled; aggregator defaults **minThreshold 3 / defaultThreshold 7**, unchanged by DeployLive. `BLSAggregator.sol:222–223`; DL:179–194. |
| 2.5–2.7 | Slash thresholds **2 / 3 / 3**; permissionless registration **false**; fraud verifier remains zero; aggregator not authorized as staking slasher. `BLSAggregator.sol:380,704–709`; DL:406–411. |
| 3.3, 3.5 | DeployLive reads **no keeper signing-address or alert-channel input**. Deployment-specific values are **undetermined** from these inputs. |

The supplied `postdeploy.txt` confirms the retained deployer ownership, treasuries, DAO multisig, seven role owners and slash-policy administrator; it reports **37 passed / 16 failed**. It also reports SP version **`SuperPaymaster-5.5.2`**, despite the table’s 5.5.0 title.

**C. Missing rows to add**

These are deployment settings or constructor/initializer defaults inherited by this fresh deployment. Existing table rows corrected above are not repeated.

| Suggested new row | Value produced by DeployLive | Source |
|---|---|---|
| BLS slash-policy administrator | **Deployment broadcaster**, independently of aggregator owner; not transferred to Safe | `modules/monitoring/BLSAggregator.sol:709`; DL:313–318 |
| X402Facilitator owner | `GOVERNOR_ADDRESS`, otherwise deployer | V54:79,108,149–155 |
| ReputationSystem owner | Deployment broadcaster; no transfer | DL:180; supplied `postdeploy.txt` |
| MicroPaymentChannel owner | Deployer; no transfer | DL:185 |
| PaymasterFactory / V4 implementation ownership | Deployment broadcaster; no transfer | DL:187–188; supplied `postdeploy.txt` |
| AOA paymaster owner / treasury | Both deployer | DL:529–539 |
| AOA paymaster fee / ETH-to-aPNTs threshold / cache validity | Initializer arguments **100 / 1 ether / 4,200 seconds** | DL:529–537 |
| AOA aPNTs price | **2,000,000**, i.e. $0.02 in its 8-decimal price representation | DL:542–543 |
| EntryPoint bootstrap funding | SP deposit/stake **0.1 / 0.1 ETH**; AOA deposit/stake **0.05 / 0.1 ETH** | DL:518–519,540,549 |
| EntryPoint unstake delays | **86,400 seconds** for both paymasters | DL:519,540 |
| GToken genesis mint and supply ceiling | **2,000 GToken** minted to deployer; constructor amount **21,000,000e18** | DL:125–128,154 |
| aPNTs genesis mint / metadata / exchange rate | **20,000**; `AAStar PNTs`, `aPNTs`, `AAStar`, `aastar.eth`; **1e18** | DL:162,552 |
| Optional Mycelium funding | **1,000 aPNTs** transferred; **1,000 aPNTs** deposited when balance <100; **500 PNTs** minted when balance <500 | DL:583–615 |
| Optional Mycelium operator treasury | Anni address derived from `PRIVATE_KEY_ANNI` | DL:556–557,600 |
| Optional Mycelium token exchange rate | **1e18**, token issued by V2 factory | DL:597 |
| Gas wrapper allowance `cWrap` | **5,000 gas** | `SuperPaymasterStorage.sol:237,447` |
| Aggregate credit uplift per proposal | **2,000e18** | `core/Registry.sol:160` |
| Protocol-wide maximum credit exposure | **200,000e18** | `core/Registry.sol:164` |
| Reputation level thresholds | **13 / 34 / 89 / 233 / 610** | `core/Registry.sol:166–170` |
| Reputation-source allowlist | ReputationSystem and BLSAggregator enabled; deployer revoked | DL:427–430 |
| DVT first proposal ID | **1** | DL:181; `DVTValidator.sol:142–148` |
| ERC-8004 identity/reputation/validation addresses | OP defaults in A; validation recorded only | DL:483–501 |
| V2 protocol allowlist bootstrap | Approve deployed SP and GlobalTierSource code hash, then **seal** | V55:122–129 |
| SP token-factory binding | **V2 factory**; legacy factory still points at SP and creates protocol aPNTs | DL:457–462; V55:167 |
| Legacy aPNTs automatic spenders | Factory, SP and X402Facilitator enabled | `xPNTsToken.sol:379–380`; DL:460–462; V54:195–200 |
| X402Facilitator aPNTs daily spender cap | **10,000e18 tokens**; facilitator also approved | V54:62,212,223 |
| Default token daily spender cap | **50,000e18 tokens** | `xPNTsToken.sol:382–384`; `tokens/v2/xPNTsTokenV2.sol:84–85` |
| Token single-transaction limit | **5,000e18** | `xPNTsToken.sol:386–387`; `tokens/v2/xPNTsTokenV2.sol:84` |
| Factory industry multipliers | DeFi **2.0**, Gaming **1.5**, Social **1.0**, DAO **1.2**, NFT **1.3**, all ×1e18 | `xPNTsFactory.sol:191–195`; `tokens/v2/xPNTsFactoryV2.sol:251–255` |
| Factory issuance-monitoring baseline | Default **$10k**, DeFi **$50k**, Gaming **$20k**, Social **$10k**, DAO/NFT **$15k**; ratio **10,000 bps** | `xPNTsFactory.sol:199–205`; `tokens/v2/xPNTsFactoryV2.sol:259–265` |
| Factory suggested-funding safety factor | **1.5e18** default; distinct from the deployment gas-budget safety factor | `xPNTsFactory.sol:113`; `tokens/v2/xPNTsFactoryV2.sol:133` |
| Release artifact/build policy | Solidity **0.8.33**, Cancun, viaIR, optimizer **500**, Registry **200**; source-hash validation | DA:43–44,135–136,221–255 |

The missing role-economics rows can be recorded as one matrix. All quantities below are GToken unless stated otherwise:

| Role | Minimum stake | Entry ticket | Exit fee bps | Minimum exit fee | Lock duration |
|---|---:|---:|---:|---:|---:|
| PAYMASTER_AOA | 30 | 3 | 1,000 | 1 | 30 days |
| PAYMASTER_SUPER | 50 | 5 | 1,000 | 2 | 30 days |
| DVT | 30 | 3 | 1,000 | 1 | 30 days |
| ANODE | 20 | 2 | 1,000 | 1 | 30 days |
| KMS | 100 | 10 | 1,000 | 5 | 30 days |
| COMMUNITY | 0 | 30 | 0 | 0 | 0 |
| ENDUSER | 0 | 0.3 | 0 | 0 | 0 |

Source: `core/Registry.sol:104–121`; DeployLive synchronizes the five operator-role exit fees to staking at DL:143–149.

Also add the role reputation-parameter tuple **threshold / base / increment / maximum**: AOA, SUPER and DVT **10/2/1/10**; ANODE **15/1/1/5**; KMS **5/5/2/20**; COMMUNITY and ENDUSER **0/0/0/0**. All seven roles initialize active. Sources: `core/Registry.sol:111–114,214`.