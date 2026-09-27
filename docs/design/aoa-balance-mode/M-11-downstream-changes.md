# M-11 · SP 5.5.0 下游变更清单（给 repo:sdk、repo:dvt）

> CC-122 M-11。日期 2026-09-27。本文件列出从**今天 Sepolia 上下游实际在用的合约（OLD）**到 **5.5.0 候选（NEW）** 的全部 ABI、版本号、存储布局与行为变化，以及每个下游仓库要做的事。
> 机器生成的原始数据在 [`m11/`](m11/)：`onchain-sepolia.json`（链上读回）、`abi-diff.json`（逐合约完整形状 diff）。复现命令见 §7。

## 0. 两个基线

| 基线 | 定义 | 坐标 |
|---|---|---|
| **OLD** | 今天 Sepolia 上的部署 | 链上读回于 **Sepolia 块 11,791,473**（chainId 11155111）。ABI 取自**源码编译**（`origin/main` @ `a839347e`，`git archive` + `forge build --skip test`），**不取 `abis/*.json`**（该目录曾长期陈旧）。BLSAggregator 例外，见 §0.1 |
| **NEW** | 5.5.0 候选 | `feat/aoa-balance-mode-5.5.0` @ **`898748c5`**（含 PR #440、#442），`forge build --skip test`，profile.default |

### 0.1 OLD 源码是不是链上那份（屏蔽 immutable 后逐字节比对 runtime）

| 合约 | 链上 `version()` | OLD 源码产物 = 链上？ |
|---|---|---|
| SuperPaymaster（实现 `0xe25f88db…`） | `SuperPaymaster-5.4.2` | ✅ 一致 |
| Registry（实现 `0x9bed0f58…`） | `Registry-5.8.0` | ✅ 一致 |
| DVTValidator / GTokenStaking / MySBT / ReputationSystem / Paymaster V4 实现 / X402Facilitator / LivenessRegistry / PolicyRegistry | `DVTValidator-0.6.0` / `Staking-4.2.0` / `MySBT-3.2.0` / `Reputation-0.3.2` / `PMV4-Deposit-4.5.1` / `X402Facilitator-1.0.0` / `LivenessRegistry-1.0.0` / `PolicyRegistry-1.0.0` | ✅ 全部一致 |
| BLSAggregator `0xEaeC2F51…` | `BLSAggregator-4.11.0` | ❌ `main` 源码是 4.12.0（未部署）。**OLD ABI 改用已钉住的 `abis/BLSAggregator-4.11.0.deployed.json`**（#423，已做链上 provenance） |
| xPNTsFactory `0x67422d2e…` | `xPNTsFactory-2.3.0-clone-optimized` | ❌ 链上 5,221 B，`main` 源码 6,802 B（链上是更早的一版，同版本号）。**旧工厂 ABI 为近似值** |
| 官方 aPNTs `0x696A…`、PNTs `0xE657…`（EIP-1167 克隆） | `XPNTs-3.4.0` | ⚠️ `main` 源码是 `XPNTs-3.5.0`。**v1 代币的 OLD ABI 对这两个克隆是近似值**，未逐字节核对 |
| GToken `0x4c09…` | `GToken-2.2.0` | ❌ 源码（OLD 与 NEW 都是）写 `GToken-2.1.2`，链上 6,113 B vs 源码 2,583 B。**这是早已存在的部署漂移，与 5.5.0 无关**；GToken 在 5.5.0 中不变 |
| PaymasterFactory `0xA936…` | `PaymasterFactory-1.0.2` | ❌ 大小不同（6,093 vs 6,158），同上，与 5.5.0 无关，ABI 在 OLD/NEW 源码间不变 |

### 0.2 NEW 产物 runtime keccak（产物里 immutable 区间为 0，**不等于**链上 codehash；上链后的核对须屏蔽 immutable）

| 合约 | runtime 字节 | immutable 引用数 | keccak(deployedBytecode) |
|---|---|---|---|
| SuperPaymaster | 13744 | 5 | `0xc9fe37f57b2bf4de56d8c87270660ce4a098692280ed642855c0a603d6b9d222` |
| SuperPaymasterAdmin | 19214 | 4 | `0xefc71c67b20fd21111e50808ee8d60bec6f1f47ec30aaa1729dcf293e7e178d2` |
| Registry | 23306 | 1 | `0xde3d06d860890b9e95a1e80202833efea49175a417958d3362d32e0231406e8b` |
| SuperPaymasterLens | 5413 | 0 | `0x4435e4a51e3293245ec1856bc9aa8d5606b9dc45b9a3dbd9742cf625e3cad3c1` |
| xPNTsTokenV2 | 20008 | 9 | `0xb15c14c49929505baa68328af7638d60f87ebbfc0b6c80ee412ebbfc86850474` |
| xPNTsTokenV2Ext | 22005 | 8 | `0x449f651a10251b654334a475b20f4220e784dc98c6867a8a48c07803b10d2604` |
| xPNTsFactoryV2 | 8537 | 4 | `0xc5c8222627d1d42f755459671acb338e2c47fee775128a07e8d3552789d91776` |
| AOAProtocolRegistry | 2746 | 0 | `0x14b95e6c2b6630b835f4253ac5d667980288de98461dcda9580e25df78fb5551` |
| GlobalTierSource | 542 | 1 | `0x73c8f2f26dcf342874cc68b8e8b766d18269b302ae04334a166f8ae1b58e84f7` |
| APNTsCapped | 5346 | 7 | `0x16a1a114c5c16b566e056ef5d9701652cb647926a7cde85432ff6b79692c1304` |

这些是**候选**坐标。正式 RC 坐标（commit + runtime codehash）由 A2 的 release attestation 给出，以那份为准。

## 1. 5.5.0 上线时，链上到底变什么

按 runbook（`03-final-spec.md` §6）：

| 动作 | 合约 | 地址 |
|---|---|---|
| UUPS 原地升级 5.4.2 → 5.5.0（第 5 步） | SuperPaymaster（同时由构造函数新建 SuperPaymasterAdmin 扩展） | 代理地址**不变** `0x09DF…4DE9` |
| UUPS 原地升级 5.8.0 → 5.9.0（第 5c 步） | Registry | 代理地址**不变** `0xf5Bf…8E71` |
| 新部署（第 1、4 步） | APNTsCapped、GlobalTierSource、AOAProtocolRegistry、xPNTsTokenV2Ext、xPNTsTokenV2（模板）、xPNTsFactoryV2、SuperPaymasterLens、TimelockController（OZ v5.0.2 标准合约） | **新地址**，部署后公布 |
| SP 改指向（第 1、6 步） | `SP.APNTS_TOKEN` → APNTsCapped；`SP.xpntsFactory()` → xPNTsFactoryV2 | — |
| 各社区发 v2 代币（第 7a 步） | xPNTsTokenV2 克隆 | **新地址**；旧 v1 代币仍在，但 SP 不再为它们结算 |
| 所有权移交（M1，A5s） | SP、Registry、AOAProtocolRegistry、xPNTsFactoryV2 的 owner → 48h timelock | — |

**不变**（链上字节码 5.5.0 不动；本表 OLD→NEW 源码 ABI 也无任何差异）：DVTValidator、GTokenStaking、GToken、MySBT、ReputationSystem、PaymasterFactory、Paymaster V4、X402Facilitator、LivenessRegistry、PolicyRegistry、**BLSAggregator（仍为 4.11.0）**。

## 2. ABI 变化（完整形状：函数按 selector、事件按 topic0、错误按 selector；输出类型与 stateMutability、事件 indexed 位一并比较）

### 2.1 SuperPaymaster 代理（OLD 5.4.2 → NEW = 核心 ∪ SuperPaymasterAdmin）
函数 90 → 99：**+13 / −4 / 同 selector 形状变化 0**。

- **删除（下游调用会 revert）**：
  - `dryRunValidation(PackedUserOperation,uint256)` → **挪到 `SuperPaymasterLens.dryRunValidation(address sp, PackedUserOperation, uint256)`**（多一个 `sp` 参数，`SuperPaymasterLens.sol:107`）
  - `pendingDebts(address,address)`、`retryPendingDebt(address,address,uint256)`、`clearPendingDebt(address,address)`：旧的 pending-debt 路径已退役（存储槽保留，`SuperPaymasterStorage.sol:92-95`）
- **新增**：`EXTENSION()`、`acceptOwnership()`、`pendingOwner()`（两步所有权）、`guardian()`、`setGuardian(address)`、`paused()`、`setGlobalPaused(bool)`（全局暂停）、`gasParams()`、`queueGasParams(uint32,uint32,uint32,uint32)`、`executeGasParams()`、`cancelGasParams()`（GOV-5 gas 参数治理）、`inflightOf(bytes32)`、`releaseStaleSponsorship(bytes32)`
- **事件新增**：`GasParamsQueued/Executed/Cancelled`、`GlobalPauseSet(address,bool)`、`GuardianSet(address,address)`、`OwnershipTransferStarted(address,address)`、`SponsorshipReleased(bytes32,address,uint256)`
- **错误新增**：`GasParamsTimelock()`、`InvalidContextLength()`、`OwnershipRenounceDisabled()`、`PendingOwnershipTransfer(address)`、`PostOpGasTooLow()`、`SponsorshipInFlight()`
- 新增 `fallback()`：不在核心里的 selector 会转发给 `EXTENSION`（SuperPaymasterAdmin）。**对调用方透明**，但 ABI 必须用「核心 ∪ Admin」的合并版本，只用核心 ABI 会缺函数。

### 2.2 Registry 代理（5.8.0 → 5.9.0）
函数 50 → 52：**+2 / −0 / 形状变化 0**。新增 `acceptOwnership()`、`pendingOwner()`；事件 `OwnershipTransferStarted(address,address)`；错误 `OwnershipRenounceDisabled()`、`PendingOwnershipTransfer(address)`。**其余全部不变**，包括 DVT 读的角色、质押、声誉、BLS 相关接口。

### 2.3 xPNTs 代币：v1（`XPNTs-3.5.0` 源码；链上官方克隆为 3.4.0）→ v2（xPNTsTokenV2 ∪ xPNTsTokenV2Ext）
这是**新模板**，不是升级。函数 70 → 148：**+88 / −10**；事件 +24 / −2；错误 +16 / −4。

- **删除**：`recordDebt(address,uint256)`、`recordDebtWithOpHash(address,uint256,bytes32)`、`usedDebtHashes(bytes32)`、`getDebt(address)`（v2 里叫 **`debts(address)`**，`IxPNTsTokenV2.sol:14`）、`burnFromWithOpHash(address,uint256,bytes32)`、`needsApproval(address,address,uint256)`、`addAutoApprovedSpender(address)`、`setSuperPaymasterAddress(address)`、**`credibilityScore()`**（v2 没有；可由 `backingValueUSD()`、`issuedValueUSD()` 算出）、`initialize(string,string,address,string,string,uint256)`（v2 用结构体参数的 `initialize`）
- **新增**（要点）：余额锁定 `tryLockForGas` / `settleLocked` / `releaseStaleLock` / `lockOf` / `lockedOf`；信用 `tryReserveCredit` / `settleCredit` / `releaseStaleCredit` / `creditReservedOf` / `effectiveCreditCap` / `requestCredit` / `approveCredit` / `revokeCredit`；策略 `creditPolicy` / `queueCreditPolicy` / `executeCreditPolicy`；有界自动额度 `setAutoAllowance` / `autoAllowance` / `renewForSelf` / `setRenewalMode`；SP 状态机 `proposeSP` / `activateSP` / `historicalSP` / `standbySP`；spender 管理 `proposeSpender` / `activateSpender` / `disableSpenderForSelf`；签名动作 `executeBySig` / `actionDigest` / `actionNonce`。完整列表见 `m11/abi-diff.json`。
- ⚠️ **同名、不同签名的事件**：删除 `SuperPaymasterAddressUpdated(address)`，新增 `SuperPaymasterAddressUpdated(address,address)`。**topic0 不同**。按事件名订阅、却用旧 ABI 解码的消费方会**静默地收不到**。另删除 `DebtRecorded(address,uint256)`。

### 2.4 xPNTsFactory → xPNTsFactoryV2（新合约）
相对 `main` 源码的 2.3.0：+4 函数（`defaultTierSource()`、`setDefaultTierSource(address)`、`implementationCodehash()`、`extensionCodehash()`），+3 错误。注意 §0.1：链上旧工厂是更早的构建，这个 diff 对链上旧工厂只是近似。

### 2.5 全新合约
APNTsCapped（32 函数）、SuperPaymasterLens（18）、AOAProtocolRegistry（20）、GlobalTierSource（3）。完整 ABI 在 `abis/` 与 `m11/abi-diff.json`。TimelockController 为 OZ v5.0.2 标准合约（`abis/TimelockController.json`，外部来源）。

### 2.6 同 selector、返回形状改变（**最危险的一类**）
**5.5.0 上线范围内：0 处。**

范围外、但要记住的一处：`BLSAggregator.guardianSlashCases(uint256)`（`0xee02231c`），4.11.0 返回 7 个字 → 4.12.0 返回 8 个字（`uint16 slashBps` 插在 `verifier` 之前）。**4.12.0 不在 5.5.0 上线范围内，链上仍是 4.11.0**。SDK 当前代码在 11 处引用它（见 §5）；只要 4.12.0 不部署，就继续按 7 字解码。

## 3. 存储布局

- **Registry**：OLD（5.8.0）产物、仓库快照、NEW 三者顺序布局**完全一致**（32 项）。`pendingOwner` 放在 ERC-7201 命名空间槽，不占顺序布局。`scripts/check_storage_layout.py`：OK。
- **SuperPaymaster**：`scripts/check_storage_layout.py` 报 OK（快照 + 2 个允许的追加项）。⚠️ **但这个快照不是链上 5.4.2 的布局**：快照 40 项，是 Part B 之后的 5.5.0 早期基线；5.4.2 源码产物是 37 项。所以另外直接比较了 **5.4.2 产物 ↔ NEW**：
  - 槽 0–36：标签、槽位、偏移完全一致。`userOpState`（槽 6）、`cachedPrice`（槽 10）的类型名从 `SuperPaymaster.*` 变成 `SuperPaymasterStorage.*`，只是声明位置变了；结构体成员逐项比较（`OperatorConfig`、`PriceCache`、`SlashRecord`、`UserOperatorState`），**完全一致**。
  - 5.4.2 的 `__gap uint256[28]` 占槽 37–64；5.5.0 从中取出 4 个槽：`_inflight`（37）、`_gasParams`（38）、`_pendingGasParams`（39）、`guardian`+`paused`（40），剩下的 `__gap uint256[24]` 占槽 41–64。**结束槽都是 64，不变**。
  - 升级瞬间新变量均为 0：没有在途记录、gas 参数取默认值（`_gpRaw()` 在槽为 0 时替换成常量，`SuperPaymasterStorage.sol:317-322`）、没有 guardian、未暂停。
  - 结论：**5.4.2 → 5.5.0 原地升级存储兼容。**

## 4. ABI 不变、但下游必须知道的行为变化

1. **`paymasterAndData` 新格式**（`03-final-spec.md` §3.2；`SuperPaymasterStorage.sol:176-182`）：`[paymaster 20][verifGas 16][postOpGas 16][operator 20][maxRate 32][token 20][flags 1]`，共 125 字节。OLD 到 `maxRate` 为止（104 字节）。NEW 中长度不足 124，或 `token` 不等于该 operator 配置的 `xPNTsToken`，都会 **sigFail**（`SuperPaymaster.sol:292-294`）。`flags` bit0 = `SP_RENEW`，bit1 = `ACCOUNT_RENEW`，两位同时为 1 也是 sigFail。**旧 SDK 构造的 `paymasterAndData` 在 5.5.0 上一律被拒**。
2. **验证失败返回 sigFail，而不是 revert**：暂停、operator 未配置或已暂停、token 不匹配、汇率超出 `maxRate`、余额不足、锁定或信用被拒等，全都返回 `_packValidationData(true, 0, 0)`（`SuperPaymaster.sol:233-319`），bundler 看到的是 **AA34**，而不是带 revert 数据的 **AA33**。SDK 如果依赖 revert 原因来区分失败，需要改用 **Lens `dryRunValidation` 的原因码**（`DRYRUN_*` 常量）。
3. **`paymasterPostOpGasLimit` 下限**：低于当前 `GasParams.minPostOpGas`（默认 `MIN_POST_OP_GAS = 200_000`，`SuperPaymasterStorage.sol:193`）就 sigFail（`SuperPaymaster.sol:266-269`）。§3.2 规定 SDK **写死 ≥ 200,000**，不能使用 bundler 的估算值；`paymasterVerificationGasLimit` 也要设下限（实测 198k–238k）。gas 参数以后可以由治理修改（`queueGasParams` → `executeGasParams`，要求 ≥ 48h；M1 之后再加上 timelock 的 48h）。**SDK 应该读取 `gasParams()`，不要写死**。
4. **结算模型**：验证期「锁定余额 / 预留信用」，postOp 按实际用量结算，多出来的退回。用户的 xPNTs 在验证期被锁定（`lockedOf`），在途期间**不能转走**。交易失败后，由 `releaseStaleSponsorship(opHash)`（SP，`SuperPaymaster.sol:457`）或代币侧的 `releaseStaleLock` / `releaseStaleCredit` 释放。
5. **postOp context**：384 字节（11 个 OpCtx 字 + 第 12 个字：低 128 位是 gas 参数快照，高位是「验证时费率 + 1」，PR #442）。对下游透明，但**不要自己解码 context**。
6. **同一 sender 同时只能有 1 笔在途 op**（§3.2，F1）：SDK 和 AirAccount 侧强制执行，这是上线前置条件。
7. **免授权额度有上限**：SP 不再是无限额度的 spender（`xPNTsTokenV2.sol` A-3：`transferFrom` / `burn(from)` 对当前 SP 和历史 SP 一律 revert）。钱包里「无限授权 / needsApproval」的逻辑要换成 `autoAllowance`、`setAutoAllowance`、`renewForSelf`。
8. **信用默认关闭**：每个社区的 `creditPolicy` 初始为 OFF，开启要走 48h 队列；额度 = `effectiveCreditCap(user)`。全局声誉当前从未被写入过（CC-121），所以 AUTO 模式的分档对所有人都是 level-1 常数（Sepolia 为 300 aPNTs）。
9. **所有权与治理**：M1 之后，SP、Registry、AOAProtocolRegistry、xPNTsFactoryV2 的 owner 是 48h timelock（两步转移）。所有 `onlyOwner` 调用都要走 schedule → 48h → execute。guardian 可以随时暂停，但不能恢复、升级或动资金。
10. **aPNTs 换成 APNTsCapped**：`SP.APNTS_TOKEN()` 在第 1 步会变成新地址。operator 的存款是在新代币里重新存入的。凡是写死旧 aPNTs `0x696A…` 的地方都要更新。
11. **Lens 的版本钉**：`SuperPaymasterLens.EXPECTED_SP_VERSION = keccak256("SuperPaymaster-5.5.0")`（`SuperPaymasterLens.sol:43`），版本不一致时返回 `DRYRUN_VERSION_MISMATCH`。

## 5. 下游动作

### repo:sdk
扫描依据：`aastar-sdk/packages`，扫描时检出的是 `fix/cc103-slotcleared` 分支，排除测试、dist 和 abis 目录。当前仍在使用、到 5.5.0 会失效的引用：`dryRunValidation` 6 处、`pendingDebts` / `retryPendingDebt` / `clearPendingDebt` 各 4 处（`core/src/actions/superPaymaster.ts`）；`recordDebt` 6、`recordDebtWithOpHash` 5、`getDebt` 5、`usedDebtHashes` 3、`burnFromWithOpHash` 7、`needsApproval` 3、`addAutoApprovedSpender` 4、`setSuperPaymasterAddress` 9、`credibilityScore` 8（`core/src/actions/tokens.ts` 等）；`DebtRecorded` 3（analytics 脚本）。

最重要的五件事：
1. **`paymasterAndData` 编码**改成 125 字节的新格式（加 `token`、`flags`），`paymasterPostOpGasLimit ≥ gasParams().minPostOpGas`（默认 200k），并给 `paymasterVerificationGasLimit` 设下限。
2. **dryRun 改走 Lens**：`SuperPaymasterLens.dryRunValidation(sp, userOp, maxCost)`，按 `DRYRUN_*` 原因码给出提示；删掉对 SP 上 `dryRunValidation` 的调用。
3. **代币 API 迁移到 v2**：删掉 debt、approval 相关调用，改成 `lockedOf` / `debts` / `effectiveCreditCap` / `autoAllowance` / `setAutoAllowance` / `renewForSelf` / `executeBySig`；`credibilityScore` 改为用 `backingValueUSD`、`issuedValueUSD` 自己计算；事件订阅按新签名重生（注意 `SuperPaymasterAddressUpdated` 的 topic 变了）。
4. **ABI 重生成**：SP 要用「核心 ∪ Admin」的合并 ABI；新增 Lens、xPNTsTokenV2 ∪ Ext、xPNTsFactoryV2、AOAProtocolRegistry、GlobalTierSource、APNTsCapped。**ABI 比对要比较完整形状（含 outputs）**，SDK 的 #366 已补。
5. **同一 sender 同时只允许 1 笔在途 op**；新地址（APNTsCapped、工厂、Lens、各社区 v2 代币）上线后更新配置；`guardianSlashCases` 继续按 4.11.0 的 7 字解码，直到 4.12.0 真正部署。

### repo:dvt
扫描依据：`YetAnotherAA-Validator/src`，`master`。在已删除或已改变的接口里，只命中 `getDebt`（8 处，都在 `modules/blockchain/blockchain.service.ts`）。按 DVT 自己的说明，它**调用者为 0**；但如果以后要接上，v2 代币上它会 revert，应改用 `debts(address)`。

1. **BLSAggregator、DVTValidator、GTokenStaking：5.5.0 不改变**。DVT 读的 BLS、slash、guardian 相关 ABI 和事件**无需改动**。
2. **Registry**：只新增两步所有权，**DVT 读的角色、质押、`globalReputation`、`batchUpdateGlobalReputation`、BLS 相关接口不变**。M1 之后 owner 变成 timelock：DVT 如果有任何「由 owner 执行」的运维脚本，都要改成 schedule → 48h → execute。
3. **SuperPaymaster**：DVT 用到的 slash 相关接口（`executeSlashWithBLS`、`isSlashPending`、`BLS_AGGREGATOR()`）**不在删除列表里，没有变化**。新增的事件（`GlobalPauseSet`、`GuardianSet`、`GasParams*`、`SponsorshipReleased`）DVT 可以选择订阅用于监控，不是必须。
4. **xPNTs**：`isOverIssued()` 在 v2 里仍然存在；`credibilityScore()` 在 v2 里**没有**。DVT 目前两者的调用者都是 0，今天不需要动。以后如果要实现 rule ③ 或 30% 及格线，要用 v2 的 getter 自己计算。
5. **复核 B3′ 和 B6′ 时**，以 A2 重新冻结的 RC 坐标为准，不要用 `v5.5.0-rc.1`（已作废），也不要用 DSR 失效的 provisional pin。

## 6. 未核实 / 局限
- 链上旧工厂（5,221 B）、官方 aPNTs/PNTs 克隆（XPNTs-3.4.0）、GToken、PaymasterFactory 的**确切源码 commit 没有找到**。这几项的 OLD ABI 取自 `main` 源码，是近似值。GToken 和 PaymasterFactory 在 5.5.0 中不变，所以不影响结论；v1 代币和旧工厂都会被新合约取代。
- SDK / DVT 的使用扫描是按函数名做**文本搜索**（排除测试和生成物），不是调用图分析；SDK 的结果只针对扫描时检出的那个分支。
- 表 0.2 的哈希是产物字节码（immutable 为 0），**不是**链上 codehash。
- `TimelockController` 没有从本仓库源码编译，它的 ABI 取自 `abis/TimelockController.json`（外部来源）。

## 7. 复现

```bash
# OLD 链上读回（只读；RPC 取自环境变量，不写入输出）
node --env-file=.env.sepolia scripts/m11-onchain-versions.mjs deployments/config.sepolia.json \
  > docs/design/aoa-balance-mode/m11/onchain-sepolia.json

# OLD 源码树（与链上 SP 5.4.2 / Registry 5.8.0 逐字节一致，见 §0.1）
git archive -o /tmp/m11-old.tar a839347e04b40da287522c3641e12121ef2e8e9e
mkdir -p /tmp/m11-old && tar -xf /tmp/m11-old.tar -C /tmp/m11-old
cp -R contracts/lib/chainlink-brownie-contracts contracts/lib/solady /tmp/m11-old/contracts/lib/   # 子模块，commit 与 NEW 相同
(cd /tmp/m11-old && forge build --skip test)

# NEW
git checkout 898748c54d52403618bca98d1e566729cb934550 && forge build --skip test

# diff（会再次用 RPC 按 onchain-sepolia.json 记录的块读 getCode 做字节码比对）
node --env-file=.env.sepolia scripts/m11-abi-diff.mjs /tmp/m11-old/out out \
  docs/design/aoa-balance-mode/m11/onchain-sepolia.json > docs/design/aoa-balance-mode/m11/abi-diff.json

# 存储布局
python3 scripts/check_storage_layout.py
```
