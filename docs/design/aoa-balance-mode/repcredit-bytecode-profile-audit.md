# RepCredit 证据的字节码 profile 核查（registry-size vs default）

> 性质：**只读核查**（DSR 对 D5 进度第 3 问：“registry-size 字节码问题可能影响 RepCredit 的证据（BLSAggregator 等）：要求 SP 只核查、列清单”）。
> 没有修改 `contracts/src`、测试、脚本、`foundry.toml`，也没有部署或广播。结论交作者，作为 RepCredit TODO。
> 核查基准：本仓库 `2283d4a2`；链上读取块高约 11,692,362（2026-09-13），公共 RPC `ethereum-sepolia-rpc.publicnode.com`，
> 其中一笔回执 publicnode 返回 null，改用 `.env.sepolia` 里的归档端点读取（URL 未打印、未落盘）。

## 0. 结论先行

1. **RepCredit 在 Sepolia 上依赖的 SP 合约，链上字节码全部是 default（runs=500）产物，没有一个是 registry-size（runs=200）。**
   B3 冻结清单里的 5 个 SP 合约（Registry 5.8.0 impl、SuperPaymaster 5.4.2 impl、BLSAggregator 4.11.0、DVTValidator 0.6.0、GTokenStaking）
   以及历史证据用到的 3 个（BLSAggregator 4.3.0 ×2、Registry 5.4.2 impl），屏蔽 immutable 之后与部署 commit 的 default artifact **逐字节相同**。
   原因很简单：
   - 其中 7 个部署于 `bb2610e8`（2026-08-26，registry-size profile 引入的那个 commit）**之前**，当时只有一个 profile（runs=500），不存在二选一的问题；
   - 唯一在之后部署的是 B3 那两份（`d23ab088`）：BLSAggregator 用 `DeployBLSAggregatorSepolia.s.sol` 部署，这个脚本**没有 import Registry.sol**，所以走 default；
     Registry 自己的 default artifact 本来就是 runs=200，两种 profile 下都是同一份。
   - 所以 D5 §7–§8 发现的问题（`deploy-core` / `DeployAnvil` / `DeployLive` 部署出 registry-size 字节码）**没有落到 RepCredit 的 Sepolia 栈上**。
2. **不一致在“测试”这一侧**：RepCredit 的大部分行为测试（CC48 系列、RepCredit* 系列、`RegistryUpgradeTo580`、`PoC_C01`、`SuperPaymaster_APNTs_Integration`，
   以及 Prague 真实预编译的 `RepCreditPragueE2E`）都 import 了 Registry.sol，所以在 runs=200 下编译，它们 `new` 出来的 BLSAggregator / SP / DVTValidator / GTokenStaking
   是 registry-size 版本，而链上跑的是 default 版本。
   这些测试只断言行为、不断言 gas；两份字节码源码相同，而且这 5 个合约里没有依赖 gas 的分支（没有 `gasleft`，没有定额 `{gas: N}` 调用，只有 BLS.sol 里 `staticcall(gas(), …)` 把全部 gas 转给预编译）。
   **所以这层不一致不改变任何行为主张**；剩下的风险只是理论上的编译器 bug。
3. **论文里的 gas 数字都不是在 registry-size 下测的**：
   - 链上数字（OP 主网 Experiment 1、C.7 的 331,215、B4/B5/B6 的 SDK 回执）测的就是链上部署的字节码，按定义一致。
   - forge 数字（111,977 / 144,907 / 244,232，来自 `DVT_BLS.t.sol`）：这个测试文件不 import Registry.sol，编译用的是 default（runs=500），**和部署一致**。
   - **但这组数字另有问题，和 profile 无关**：它们 2026-02-06 首次写进 DSR，当时 SP 的 `foundry.toml` 是 runs=10000，BLSAggregator 也是更早的版本。
     在已部署的源码 `d23ab088`（BLSAggregator 4.11.0，default profile，与链上逐字节一致）上重跑同一个测试，得到 `verifyAndExecute` **278,837**、`test_BLS_ManualVerify` **416,140**、`test_DVT_ProposalFlow` **438,270**。
     论文里的数字在当前部署的字节码上**复现不出来**。这是版本 / harness 漂移，不是 registry-size 造成的，但作者需要知道（见 §5 T-3）。
4. **需要提前防的风险**：runbook 第 10 步的 RepCredit 重新采集，如果用 `DeployRepCreditSepolia`（或 `DeployLive`）部署一个**全新**的栈，
   那么除了 SP impl 和 v2 栈（已改走 `_deployDefault`）以外，BLSAggregator、DVTValidator、GTokenStaking、MySBT、ReputationSystem、xPNTsFactory 都会以 registry-size 部署（D5 §8 已经在 DeployAnvil/DeployLive 上实测过同样的机制）。
   到那时，“链上 = registry-size”对“forge 测 gas 用的 = default（DVT_BLS）”的不一致就会真的出现。现在还没有发生。

## 1. 方法

1. **确定证据用了哪些合约**：本仓库 `deployments/deploy-record-cc115-b3-sepolia.md`、`deployments/config.sepolia.json`；DSR 仓库 `writing/paper7-RepCredit/`
   （`REPCREDIT_SECURITY_CLAIM_LEDGER_2026-08-29.md`、`paper_draft_v15_iet.md` 附录 C.4–C.7、§5.4）以及分支 `codex/cc115-v16-route-b-20260829` 上**冻结**的
   `evidence/route-b-cc115-20260829/b3-successor-manifest-20260904.json`（DSR commit `5bc6579`，SHA-256 `db7cdf91…f405c`）；
   SDK `scripts/upstream-abi-pin.json` 的 `deployedStack.sepolia`（B4 证据运行器钉住的地址）。
2. **确定部署 commit**：扫描本仓库 `broadcast/**/11155111/run-*.json` 的 CREATE 交易（Foundry 在其中记录 `commit`）。
   B3 的两笔部署没有 broadcast 文件，改用部署记录里的交易哈希读回执，再用部署记录写明的“measured on `d23ab088`”以及 B3 清单的 `deployedRuntimeSourceAnchor = d23ab088` 定位 commit。
3. **重建 artifact**：在本 worktree 里依次 checkout `d23ab088`、`78364b12`、`2283d4a2`，每个都执行 `forge build --out out-<c> --cache-path cache-<c>`（default profile；在有 restriction 的 commit 上，会同时产出 `<C>.json` 和 `<C>.registry-size.json`）。
   `contracts/lib/{solady,chainlink-brownie-contracts}` 的内容从主 checkout 拷过来，两者都与这些 commit 钉住的 submodule 版本相同（`90db92ce` / `6e324d8a`）。
4. **比对**：`cast code` 取链上 runtime，用每个 artifact 自己的 `deployedBytecode.immutableReferences` 把链上字节和 artifact 字节中的对应区间同时清零，再逐字节比较；长度不同直接判不等。
   每个 artifact 的 profile 读自其 `metadata.settings.optimizer.runs`，不按文件名猜。
   正对照：同一合约的另一个 profile artifact 必须判“不等”（下表每行都满足），说明比对不是恒真的；另外取到的 5 份 B3 runtime，keccak 与 B3 冻结清单的 `runtimeCodehash` 逐一相同，说明比对的就是冻结的那份代码。
5. **测试 profile**：看测试合约 artifact 的 `metadata.settings.optimizer.runs`。一个测试文件只要（传递地）import 了 Registry.sol，就只能用 registry-size 编译（runs=200），它 `new` 出来的合约字节码也嵌在同一个编译单元里，所以同样是 runs=200。

## 2. 证据用到的合约与链上字节码 profile

registry-size profile 引入于 `bb2610e8`（2026-08-26 12:03 +0700）。在这之前，`[profile.default]` 是 runs=500、via_ir、cancun、`bytecode_hash=none`，而且只有这一个 profile（v3-only 是 via_ir=false，GTokenStaking 在它下面编译不过，所以不可能用它）。

### 2.1 B3 冻结清单（route-B 的 successor 栈；B4/B5/B6 都跑在它上面）

| 合约 | 地址 | 链上 version / runtime | 部署交易 / 块 / 部署 commit | 部署路径 | default artifact | registry-size artifact | 结论 |
|---|---|---|---|---|---|---|---|
| Registry impl（代理 `0xf5Bf…8E71`，ERC-1967 槽读回 = 此 impl） | `0x9beD0F58d6001B0006923eb8c4b1Cc548D42ccEe` | Registry-5.8.0 / 23,038 B | `0x2792ea49…12b5` / 11,599,359 / `d23ab088` | `UpgradeRegistryTo580.s.sol`（`new Registry()`） | `out-d23ab088/Registry.sol/Registry.json`，runs=200，23,038 B → **MATCH**（屏蔽 2 处） | 不存在（Registry 只有一份，default 本身就受限为 runs=200） | **default（= runs=200）**；两种 profile 没有区别 |
| BLSAggregator | `0xEaeC2F512eA50708211fa95533e4dBb60e3d2E5D` | BLSAggregator-4.11.0 / 23,667 B | `0x6a5a6ddf…3881` / 11,599,366 / `d23ab088` | `DeployBLSAggregatorSepolia.s.sol`（只 import BLSAggregator.sol 和 GovernanceOwnerGate，**不 import Registry**） | `BLSAggregator.json`，runs=500，23,667 B → **MATCH**（屏蔽 10 处） | `BLSAggregator.registry-size.json`，runs=200，23,300 B → 长度不等 | **default** |
| SuperPaymaster impl（代理 `0x09DF…4DE9`，槽读回 = 此 impl） | `0xe25f88dbeaFc64200270A948Df8e9dd2F9b22C27` | SuperPaymaster-5.4.2 / 23,569 B | `0xc73a1f1b…3fcf`（CREATE，receipt `contractAddress` = 此 impl）/ 11,228,202 / `6a6d2d17`（`UpgradeToV5_4_2.s.sol`）。**更正（2026-09-13）**：此前误写为 `0xae0399f8…3ec6`，那一笔是同块的 `upgradeToAndCall`（`to` = 代理），证据见 `data/onchain-real/sepolia-5.4.x-upgrade-txs.json` | 早于 restriction | `@78364b12` `SuperPaymaster.json` runs=500 23,569 B → **MATCH**（屏蔽 24 处）；`@d23ab088` default 同样 MATCH | `@d23ab088` registry-size 23,356 B → 长度不等 | **default（部署时只有一个 profile）** |
| DVTValidator | `0x568b1486BFE036e603eA11f0D03Dc47fa62c9E0e` | DVTValidator-0.6.0 / 6,326 B | `0x7ce79682…8b49` / 11,209,693 / `ba14f520`（`DeployNewBLSModules.s.sol`） | 早于 restriction | `@78364b12` runs=500 6,326 B → **MATCH**（屏蔽 4 处）；`@d23ab088` default MATCH | `@d23ab088` registry-size 6,170 B → 长度不等 | **default（同上）** |
| GTokenStaking | `0x472297B557c1d0F030f281a5Bb8A535f6c5AB65e` | Staking-4.2.0 / 9,061 B | `0x2d64cee1…5786` / 11,151,005 / `cf26915e`（`DeployLive.s.sol`） | 早于 restriction | `@78364b12` runs=500 9,061 B → **MATCH**（屏蔽 16 处）；`@d23ab088` default MATCH | `@d23ab088` registry-size 9,086 B → 长度不等 | **default（同上）** |
| FraudProofVerifier | `0xa1346F1668cBf8D031Cc5D72eDA45F5788CA1cd3` | 2,981 B | — | 在 YetAnotherAA-Validator 仓库编译 | — | — | **不在本仓库的 profile 问题范围内**，未核对 |

补充：`SuperPaymaster.sol`、`DVTValidator.sol`、`GTokenStaking.sol` 从各自部署 commit 到 `d23ab088`，`git diff` 为空，所以它们在两个 commit 上都能 MATCH。
`Registry.sol` 从 `3bfaf062` 到 `78364b12` 也没有变化。`14d2653f` 与 `78364b12` 的 `contracts/src` 完全相同。

### 2.2 历史证据（v15 已写入的 Sepolia 数据）

| 合约 | 地址 | 用在哪里 | 链上 | 部署 | 比对 | 结论 |
|---|---|---|---|---|---|---|
| BLSAggregator（独立 A′） | `0xf44E7E51EFFa867114BE48fA92411fE216b1A285` | v15 附录 C.7：guardian 共谋惩罚链上 trace（`executeGuardianSlash` 331,215 gas） | 4.3.0 / 15,857 B | `0x9d7efbde…3ca2` / 11,491,591 / `14d2653f` | `@78364b12`（src 与 `14d2653f` 相同）runs=500 15,857 B → **MATCH**（屏蔽 6 处） | **default（部署时只有一个 profile）** |
| BLSAggregator（前任 canonical） | `0x174b60bB462b00550F0EC7Bc35Fe39dDB6310158` | “Sepolia 5.4/4.3 负面部署证据”；B3 的 predecessor | 4.3.0 / 15,857 B | `0x6474f16c…d01a` / 11,492,045 / `78364b12` | 同上 → **MATCH** | **default（同上）** |
| Registry impl 5.4.2 | `0x9e5da7B4461Ff92F9Ea2Ae57bcf749afC812CC00` | “Sepolia Registry-5.4.2” 负面证据（`GlobalReputationUpdated=0` 等） | 5.4.2 / 23,663 B | `0x8d4e543a…56c5` / 11,228,783 / `3bfaf062` | `@78364b12` runs=500 23,663 B → **MATCH**（屏蔽 2 处） | **default，而且是 runs=500**（见 §4 注） |
| “不超发”的争议代币 | `0x8dE1b6585Bdf5a3e6F13B3125B2d40CC34fc005b` | C.7 | 374 B，`name()`/`symbol()`/`version()` 全部 revert | 找不到 broadcast | — | **未能验证**：不是本仓库的产品合约（很可能是测试 mock），找不到部署来源 |
| OverIssueFraudProofVerifier（C.7） | `0xd7111fcC31B52dC451f2B7400Cd75B434E2b1abd` | C.7 | — | DVT 仓库 | — | 不在本仓库的范围内 |

### 2.3 不在 Sepolia 上的证据

| 证据 | 部署 | profile 判断 |
|---|---|---|
| OP 主网 Experiment 1（Registry 3.0.2 / SP 3.2.2 等，2026-01/02） | 早于 restriction 半年多；当时 `[profile.default]` 是 runs=10000、via_ir（`0382b840` 起，到 `38319255` 2026-03-20 为止） | 不可能是 registry-size。**未逐字节验证**（没有重建 2026-02 的树）；这组 gas 本来就是链上回执，测的就是部署的字节码 |
| Anvil Experiment 6（2026-02-15，`paper7-exclusive-data.ts`） | 本地 anvil，链已不存在 | 不可能是 registry-size；具体字节码**未能验证** |
| 旧 91 笔回执那一代（2026-08-24，本地 Prague + Sepolia，已标 DO-NOT-REFERENCE） | 由 `repcredit-e2e-worktrees/20260823/SuperPaymaster` 在 `cf9b7f46` 自行部署 | `cf9b7f46` 的 `foundry.toml` 里没有 registry-size（单一 profile，runs=500），不存在二选一。字节码未逐一比对 |

## 3. gas 数据与测试用的是哪个 profile

### 3.1 gas 数字

| 数字（论文位置） | 来源 | 测的是哪份字节码 | profile |
|---|---|---|---|
| T1/T2/T2.1/T5 152k–169k（§5.4.2、C.5，OP 主网） | 链上回执 | 部署的那份（按定义） | 部署时只有一个 profile，runs=10000 |
| 331,215（C.7 `executeGuardianSlash`，Sepolia 块 11,491,914） | 链上回执 | `0xf44E…A285`（§2.2） | default runs=500，与部署一致 |
| B4/B5/B6 回执（SDK orchestrator；`RepCreditPragueE2E` 的注释写明 “Foundry gasleft values are not used as manuscript evidence”） | Sepolia 回执 | B3 栈（§2.1） | default，与部署一致（**B6 尚未冻结**，届时仍按回执计，结论不变） |
| 111,977 / 144,907 / 244,232（§5.4.3，“forge test, precompile-stubbed harness”） | `contracts/test/modules/DVT_BLS.t.sol --gas-report` | 测试里 `new` 出来的 BLSAggregator | 测试不 import Registry.sol → **default**（`@d23ab088` 与 `@2283d4a2` 下 `DVTBLSTest` 都是 runs=500），与部署的 profile 一致。**但数字写于 2026-02-06（DSR `550ceda`），当时是 runs=10000、旧版源码**；见 §5 T-3 |
| Anvil 闭环 approve/recordDebt/syncToRegistry 等（C.6） | anvil 回执 | 当时 DeployAnvil 部署的那份 | 2026-02，只有一个 profile |

`DVT_BLS.t.sol` 在当前与已部署的源码上的实测（本次重跑，Cancun，桩化的预编译）：

| 测试 / 函数 | 论文 | `d23ab088`（= 链上 4.11.0 源码，default） | `2283d4a2`（HEAD，4.12.0，default） |
|---|---|---|---|
| `verifyAndExecute`（gas report） | 111,977 | 278,837 | 278,949 |
| `test_BLS_ManualVerify` | 144,907 | 416,140 | 416,274 |
| `test_DVT_ProposalFlow` | 244,232 | 438,270 | 438,382 |

### 3.2 行为测试（claim ledger 列出的，以及 RepCredit 相关的套件）

在 `d23ab088` 与 `2283d4a2` 两个 commit 上都读了 artifact 的 `optimizer.runs`，结果一致：

| 测试文件 | 是否（传递地）import Registry.sol | 编译 profile | 测试里的 BLSAggregator / SP / DVT / Staking | 与链上一致吗 |
|---|---|---|---|---|
| `security/RepCreditIssuanceAndExitControls.t.sol` | 是 | runs=200 | registry-size | 否 |
| `security/CC48CoreFixes.t.sol` | 是 | runs=200 | registry-size | 否 |
| `security/CC48DomainSeparation.t.sol` | 是 | runs=200 | registry-size | 否 |
| `security/CC48CreditScheduleControls.t.sol` | 是 | runs=200 | registry-size | 否 |
| `security/CC48RegistryTimelockGovernance.t.sol` | 是 | runs=200 | registry-size | 否 |
| `security/PoC_C01_CreditCeiling.t.sol` | 是 | runs=200 | registry-size | 否 |
| `v3/RegistryUpgradeTo580.t.sol` | 是 | runs=200 | registry-size（Registry 本身两边都是 runs=200） | Registry 一致；其余不一致 |
| `v3/SuperPaymaster_APNTs_Integration.t.sol` | 是 | runs=200 | registry-size | 否 |
| `paper7/CC48PragueStateMachine.t.sol`（Prague） | 是 | runs=200 | registry-size | 否 |
| `paper7/CC48KeyScanPreflight.t.sol` | 是 | runs=200 | registry-size | 否 |
| `paper7/RepCreditDomainReplay.t.sol` | 是 | runs=200 | registry-size | 否 |
| `paper7/BLSGasMeasurement.t.sol`（合约 `RepCreditPragueE2E`，Prague） | 是 | runs=200 | registry-size | 否（它不产出论文用的 gas） |
| `modules/DVT_BLS.t.sol` | 否 | runs=500 | default | 是 |
| `security/CC48VerifierConformance.t.sol` | 否 | runs=500 | default | 是 |
| `crossrepo/CC115GenuinePragueCrossRepo.t.sol` | 否 | runs=500 | default | 是 |
| `security/CC48GovernanceOwnerGate.t.sol` | 否 | runs=500 | default | 是 |
| `invariant/XPNTsOpHashReplay.invariant.t.sol` | 否 | runs=500 | default | 是 |
| `modules/BLSAggregatorUnit` / `BLSAggregatorLiveness` / `BLSPermissionlessRegistration` / `GenericDVTProposal`、`v3/BLSAggregator_PkAggReconstruct` | 否 | runs=500 | default | 是 |

claim ledger 里那几组测试是在 `a439044` 上跑的，它的 `foundry.toml` 已经带 registry-size；我没有在 `a439044` 上构建，所以对它的归类是按上表的 import 结构**推断**的，没有逐一验证。

**另一个比 profile 更大的轴**：HEAD 的源码是 BLSAggregator 4.12.0 / SuperPaymaster 5.5.0，链上是 4.11.0 / 5.4.2。所以在 HEAD 上跑的任何测试，不管哪个 profile，测的都不是链上那份源码。只有在 `d23ab088` 上跑 default profile 的测试，才等于链上的 BLSAggregator/SP/DVT/Staking。

## 4. 不一致清单

| 合约 | 链上 profile | 测试 / 测量用的 profile | 影响哪条 RepCredit 主张 |
|---|---|---|---|
| BLSAggregator 4.11.0 `0xEaeC…` | default（runs=500，23,667 B） | gas：`DVT_BLS` default ✓；链上回执 ✓。行为：CC48/RepCredit* 套件用 registry-size（23,300 B） ✗ | **gas**：没有 profile 不一致，但论文里的 forge 数字在部署源码上复现不出来（§3.1，T-3）。**体积**：B3 清单、部署记录的 23,667 B（余量 909）都是 default = 链上 ✓。**行为**：不受影响（源码相同，没有依赖 gas 的分支） |
| Registry 5.8.0 impl `0x9beD…` | runs=200（default 与 registry-size 是同一份） | 所有测试都是 runs=200 ✓ | 无 |
| SuperPaymaster 5.4.2 impl `0xe25f…` | default（23,569 B） | 链上回执 ✓；import Registry 的集成测试用 registry-size ✗（而且 HEAD 已是 5.5.0） | gas 来自回执，无影响；行为无影响 |
| DVTValidator 0.6.0 `0x568b…` | default（6,326 B） | `DVT_BLS` default ✓；CC48 系列 registry-size（6,170 B）✗ | 无（`test_DVT_ProposalFlow` 的 gas 走 default） |
| GTokenStaking `0x472297…` | default（9,061 B） | CC48 / Prague 套件 registry-size（9,086 B）✗ | C.7 的 331,215 是回执 ✓；行为无影响 |
| BLSAggregator 4.3.0 ×2、Registry 5.4.2 impl | default（部署时只有一个 profile） | 当时的测试也是同一个 profile | 无 |
| OP 主网 / Anvil / DO-NOT-REFERENCE 那一代 | 部署时只有一个 profile | 同 | 无（未逐字节验证） |

注：**Registry 自己换过优化档**。5.4.2 impl 是 runs=500（23,663 B），5.8.0 impl 是 runs=200（23,038 B）。这不是 registry-size 的“部署 ≠ 测试”问题，
但如果论文把某个 Registry 路径（例如 `batchUpdateGlobalReputation`、`syncToRegistry` 那一段）在 5.4.2 上测到的 gas 拿来代表 5.8.0，就把一次优化档变化算进去了。

## 5. 给作者的 TODO（RepCredit）

- **T-1（不用改，写一句）**：B3 冻结栈的 5 个 SP 合约、C.7 和“5.4/4.3 负面证据”用到的 3 个合约，链上都是 default profile，与部署 commit 的 default artifact 逐字节一致（§2）。
  registry-size 问题**没有**污染已冻结或历史的 Sepolia 证据。论文的可复现说明里可以写“部署字节码 = `forge build` default artifact @ `d23ab088`（B3）/ 部署当时的唯一 profile（其余）”。
- **T-2（按需说明）**：RepCredit 的行为测试大多在 runs=200 下编译（§3.2），测的是 registry-size 字节码。论文如果写“测试覆盖的就是部署的字节码”，要改成“同一源码，优化档不同（runs 200 vs 500）”；
  或者引用那几个 default 下编译的套件（`DVT_BLS`、`CC48VerifierConformance`、`CC115GenuinePragueCrossRepo`）。行为结论本身不受影响。
- **T-3（与 profile 无关；影响范围已由 DSR 更正，2026-09-13）**：111,977 / 144,907 / 244,232 在已部署的 4.11.0 源码上复现不出来（重跑结果为 278,837 / 416,140 / 438,270，§3.1）。
  **更正影响范围**：DSR 用 grep 核实过，RepCredit 的权威稿 `paper_draft_v16_iet.md` 和投稿包 `submission_IET_v16/` **都没有引用**这三个数。它们只出现在旧章节文件 `05_evaluation.md`（L146–149）和 review_rounds 的历史审稿意见里。**所以 T-3 不阻塞 RepCredit v16。** 给作者的记录：旧章节文件不能再作为数据来源；以后如果要引用 forge 的 BLS gas 数据，用在 `d23ab088` 上重跑的结果，并注明优化器配置（runs=500，via_ir）。下面几条原来的建议只适用于将来要引用这组数据的情况。
  这些数字是 2026-02 的树（runs=10000、旧版 BLSAggregator）上测的。可选：(a) 标注测量时的 commit/版本；(b) 在 `d23ab088` 上重测后替换；(c) B6 有了真实 Prague 回执以后，只保留回执。
  补充：常数项（配对）/线性项（重建）的划分不受这点影响，只是绝对值变了。
- **T-4（事前防范）**：第 10 步重新采集时，如果部署**新栈**，不要用 `DeployRepCreditSepolia` / `DeployLive` 现在的 `new` 路径部署 BLSAggregator、DVTValidator、GTokenStaking 等：它们 import 了 Registry.sol，按 D5 §8 的机制会部署出 registry-size 版本（HEAD 下 BLSAggregator 是 23,940 B，不是 24,345 B）。
  要么把这些也改成 `_deployDefault`（D5 §8 的做法），要么在证据清单里明确记录 profile。原地升级（B3 的路线）不受影响。
- **T-5（范围外，已记录）**：`0x8dE1…005b`（C.7 的争议代币）的来源和字节码未能验证；OP 主网与 Anvil 那两批的字节码没有逐字节重建。

## 6. 复现要点

```
# 在本仓库 worktree 中（submodule 为空时从主 checkout 拷贝 solady / chainlink-brownie-contracts）
git checkout d23ab088 && forge build --out out-d23ab088 --cache-path cache-d23ab088
git checkout 78364b12 && forge build --out out-78364b12 --cache-path cache-78364b12
cast code <addr> --rpc-url https://ethereum-sepolia-rpc.publicnode.com
# 比对：按 artifact 的 deployedBytecode.immutableReferences 把两边的对应区间清零后逐字节比较；
# profile 读自 artifact metadata.settings.optimizer.runs
forge test --match-path contracts/test/modules/DVT_BLS.t.sol --gas-report   # 在 d23ab088 上
```

链上 runtime 的 keccak 与 B3 清单一致：BLSAggregator `0xa47bcf01…de4c`、Registry impl `0xa43e76a7…d5a8`、SP impl `0x63a66dc0…5135`、DVTValidator `0x945bf1df…863c`、GTokenStaking `0xc1e3c59b…e0ae`。
