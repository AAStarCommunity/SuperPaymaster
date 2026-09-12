# D5 计划：部署脚本迁移 + fork 演练 + B 层门槛 + I8/I9 fuzz 门槛

分支 `feat/aoa-balance-mode-5.5.0`，基线 `66d3e4c1`（Cancun 1564/0/49，Prague 1473/0/21）。
约束不变：只在本地、Anvil、Sepolia fork 上进行；**不广播、不升级共享的 Sepolia 代理**；走 PR 流程；DSR 逐项验收。

## 0. 现状（2026-09-13 从 Sepolia 读回）

| 项 | 值 | 对计划的影响 |
|---|---|---|
| SP 代理 `0x09DF…4DE9` | `SuperPaymaster-5.4.2`，impl `0xe25f…2C27` | runbook 第 5 步以它为升级前的基线 |
| SP owner | `0xb560…df0E`，**EOA**（代码长度 0） | fork 上可以直接 impersonate，不需要模拟 Safe 流程 |
| `pendingAPNTsToken` | `0xBb46…9883`（**非零**） | runbook 第 1 步要求"执行或取消，二选一"。这就是作者此前推迟的 aPNTs 切换。**演练两条分支都走；实际选哪一条由作者决定** |
| `cachedPrice.updatedAt` | 1788255708（已过期） | 7c 取消暂停之前必须 `updatePrice` 并读回（DSR D3 §8(a) 的条件） |
| 本机工具 | anvil 1.7.1、cargo、node；Docker 已安装但 daemon 未运行；没有 bun，pnpm 不在 PATH；`../super-relay` 是 Rundler 0.9.0 的 fork（已有 release 构建），`../UltraRelay-AAStar` 是 Alto 的 fork | 见 §3.1 的工具方案 |
| Anvil 对 JS tracer 的支持 | 已探测：`debug_traceCall` 接受自定义 JS tracer，`step` 回调逐条 opcode 执行（PUSH1…RETURN 全部记录到） | 这只是必要条件，**是否足以支撑 bundler 的完整 tracer 由门槛 B0 判定**（§3.2） |

## 1. 顺序

| 步 | 内容 | 产出 | 依赖 |
|---|---|---|---|
| D5.1 | **I8/I9 的 EntryPoint 级 fuzz**（门槛 G2）。只依赖合约，最早能做，最早能暴露问题 | `contracts/test/v2/SuperPaymasterV55Fuzz.t.sol` | 无 |
| D5.2 | **部署脚本迁移**：`DeployAnvil`、`DeployLive`、`TestAccountPrepare`、`InitializeAAStar`、`InitializeTestCommunities`、`DeployRepCreditSepolia`、`08b_WireUpToken`、`11_ConfigureOperator`、`11_1_ConfigureBreadOperator`、`L4GaslessTest`（D2-traceability §8.2 列出的全部）；新增 `UpgradeToV5_5_0.s.sol`，实现 runbook 第 4–7c 步，每一步带读回断言 | 脚本 + `./deploy-core anvil` 全新部署跑通 + 7 个 Check 脚本 | 无 |
| D5.3 | **fork 演练 runbook 0–7c**，在 `anvil --fork-url <sepolia 归档 RPC>` 上进行，impersonate owner 和各社区 owner，不广播 | 演练日志 + 每一步的读回表 `docs/design/aoa-balance-mode/D5-rehearsal.md` | D5.2 |
| D5.4 | **B 层**（门槛 G1）：先做 B0 tracer 兼容性判定，再跑用例 B1–B9 | trace 存档 `docs/design/aoa-balance-mode/b-layer/`，外加逐行对照表 | D5.2（部署脚本）；B0 不依赖 |
| D5.5 | D5 追溯文档 `D5-traceability.md`，然后交 DSR 验收 | — | 以上全部 |

D7（JS gasless E2E 迁移）在 D5 之后，依赖 D5.2 的部署脚本。

## 2. 门槛 G2：I8/I9 的 EntryPoint 级 fuzz（论文证据冻结之前）

**环境**：规范 EntryPoint v0.7 字节码（D3 G 层的 fixture，codehash `0x8db5ff69…`），真实的 SP 5.5.0 代理，工厂发行的 v2 代币。

**随机化维度**（每一轮都由 fuzz 种子决定）：
- bundle 大小 1–N（N = 6）；sender 在 1–3 个账户里随机选，允许同一 sender 在一个 bundle 里多笔（多个 nonce key）。
- 每笔的模式：让它走 BALANCE（余额充足）、走 CREDIT（余额不足，且 AUTO + requestCredit + 分档都有），或两者都不满足（验证失败，不进 bundle，用来覆盖"第 k 笔被拒"）。
- `paymasterPostOpGasLimit` ∈ {MIN − 1, MIN, MIN + δ（δ 随机 0–50k）, 大值}；`callGasLimit` 随机；用户的执行随机是成功、revert，或者 OOG。
- 结算失败注入：随机挑选若干笔，用 `vm.mockCallRevert` 让 `settleLocked` 或 `settleCredit` 对这笔 opHash revert。
- 随机夹入外部事件（在 bundle 之间）：黑名单、策略切换、分档变化、急停、汇率变动。

**每一笔都做的断言**：
- **I8**：用户执行的效果被保留（用计数器合约观察）⇔ 这一笔已经结算（`usedOpHashes[h]`，并且有 LockSettled 或 CreditSettled 事件）。
- **I9**：没有后盾的赞助 = 0。按每笔、每 bundle、每 operator 三个粒度累计"执行效果被保留，但用户没有烧币也没有记债"的笔数和金额，必须都是 0。
- **I10**：被注入结算失败的那一笔，用户净额 = 0；交易之后 `releaseStaleLock` / `releaseStaleCredit` / `releaseStaleSponsorship` 可以执行，之后 operator 的净额 = 0，lockedOf 和 creditReservedOf 回到 bundle 之前的值。
- 守恒：operator 余额的变化 = −Σ 已结算的 charge；`protocolRevenue` 的变化 = +Σ charge；用户 xPNTs 的烧毁量 = Σ xc。

**验收判据**：
1. Cancun 和 Prague 上 fuzz runs ≥ 1,000（inline config），全绿，并且在报告里写明 seed。
2. **覆盖计数**（由测试自己统计并断言下限，防止 fuzz 空转）：两种模式各至少 200 笔结算；注入的结算失败至少 50 笔；同一 bundle 里同一 sender 多笔的情况至少 50 次；postOpGasLimit = MIN 的至少 50 笔；opReverted 至少 50 笔。
3. **变异**，每个都要在指名断言上变红：settle 包 try/catch 吞掉失败（I8/I9 变红）；SETTLE_GAS_BOUND 改回 80k（I8 或 no-OOG 变红）；postOp 不退 a0 − c（守恒变红）；releaseStaleSponsorship 不退 a0（I10 变红）；CREDIT 分支跳过 settleCredit（I9 变红）。
4. 结果写进 `D5-traceability.md`，包括 runs、seed、覆盖计数、变异表。

## 3. 门槛 G1：B 层（任何 Sepolia 部署之前）

### 3.1 工具

- **参照 bundler 用上游版本，固定到具体版本**：Alto（pimlico/alto，固定一个 release tag，用 node 构建，pnpm 通过 corepack 启用）和 Rundler（alchemyplatform/rundler，固定一个 release tag，优先 `cargo build --release`；Docker daemon 起来之后也可以用官方镜像）。**不用 `super-relay` / `UltraRelay-AAStar` 这两个 fork 作为判定依据**，因为 fork 可能改过校验规则；可以作为第三个数据点另列。
- **链**：Anvil，fork Sepolia，或者本地全新部署（EntryPoint v0.7 用规范字节码 etch 到规范地址，同时部署 EntryPointSimulations）。两个 bundler 都开 safe mode，也就是 ERC-7562 全规则、打开 tracer。
- **需要作者操作的环境项**：启动 Docker Desktop（可选，只有用 Rundler 镜像时才需要）；安装 pnpm 或启用 corepack 需要网络。以上都在本机进行，不涉及任何链上广播。

### 3.2 B0：tracer 兼容性判定（先做；不通过就停下来换链）

Anvil 能执行 JS tracer，但 bundler 的 tracer 还会用到 `db.getState`、`log.contract.getAddress()`、`toHex` 等辅助函数和 keccak 预映像收集。**只看"合规的 op 能通过"证明不了规则真的在执行**，所以 B0 用反例：
- 部署 4 个**故意违规**的 paymaster 或账户：验证期读 TIMESTAMP（OP-011）；写一个与 sender 无关的槽（STO-021）；未质押的实体读自己的全局槽（STO-031/033）；未质押时在验证期用 TSTORE（OP-070）。
- **判据**：两个 bundler 在 safe mode 下都必须以对应的规则码拒绝这 4 个 op，同时接受一个合规的对照 op。有任何一个违规 op 被接受，说明 Anvil 上的 tracer 不可信，B 层改用 `geth --dev`（全新部署），并在报告里写明。

### 3.3 用例（每个都保存 bundler 的模拟 trace）

| # | 用例 | 预期 |
|---|---|---|
| B1 | 单笔 BALANCE op | 两个 bundler 都接受并上链；trace 逐行对照 §2.3 |
| B2 | 同一 sender 在一个 bundle 里多笔（多个 nonce key） | 接受；第 k 笔在余额不足时被拒（与 T-R14-02 一致） |
| B3 | 多个 sender 在同一个 bundle | 接受；各自的锁互不干扰 |
| B4 | 带 initCode 的首笔（模拟 AirAccount 的工厂），**工厂质押在门槛之上和之下两种情况** | 质押在门槛之上：接受；在门槛之下：按规则拒绝（对照 ERC-7562 的 factory 规则），两种都记录 |
| B5 | R1 的 SP_RENEW（flags = 1） | 接受；trace 显示续期只写与 sender 关联的槽 |
| B6 | 方案 A 的 `renewForSelf`：一个模拟 AirAccount 的账户在 `validateUserOp` 里调用 `token.renewForSelf(sp)` | 接受；trace 显示账户帧只访问 §2.3 第 55 行列出的 6 类槽，**不读任何全局槽** |
| B7 | CREDIT 模式 op（AUTO + requestCredit + 分档） | 接受；trace 显示读了分档源（STATICCALL），且只读 §2.3 第 52 行列出的全局槽 |
| B8 | 验证期 TSTORE（活标记） | 两个 bundler 都接受（SP 已质押）；记录 bundler 对 OP-070 的实际处理方式 |
| B9 | SP 质押在 bundler 门槛之上和之下 | 之上：接受；之下：SP 读全局槽被拒（STO-033 失效）。证明"SP 必须质押"这条前提 |

### 3.4 逐行对照

对每个用例，从 bundler 的 trace 里提取验证期 token 帧的全部 SLOAD / SSTORE / TLOAD / TSTORE 以及 opcode，逐项归入 §2.3 验证期访问清单的第 52–56 行。**判据：清单之外的访问数为 0**；第 56 行列出的禁止项（`_reentrancyStatus`、`usedOpHashes`、`spenderRateLimit`、`total*`、TIMESTAMP、NUMBER、ORIGIN）一次都不出现。对照表由脚本生成：trace 里的槽用 keccak 预映像还原成"变量名[key]"。

### 3.5 验收判据（G1）

1. B0 通过（4 个反例都被两个 bundler 拒绝，合规对照被接受），或者已经换到 geth 并通过。
2. B1–B9 在**两个** bundler 上的结果都与上表预期一致；两个 bundler 结论不一致的地方逐条写出原因。
3. 每个用例的 trace 原文存档；§3.4 的对照表里清单外访问 = 0，禁止项 = 0。
4. 使用的 bundler 版本（tag + commit）、safe mode 配置、链的类型写进报告。

## 4. fork 演练（D5.3）的读回判据

每一步都要有正对照读回（沿用 §6 的原则）：
- 第 0 步：盘点表。日志扫描按"归档 RPC + 完整性"的纪律做：数据源用 `~/Dev/.env` 里的归档 key，另找一个独立端点交叉验证；如果验证不了，写"未能验证"。
- 第 1 步：`pendingAPNTsToken` 的两条分支（execute 或 cancel）各演练一次，读回为 0。
- 第 2 步：`pendingDebts` 逐条，读回为 0 或者有核销记录（D-21 已定：旧债不处理）。
- 第 3 步：各 operator 的 `isPaused == true`。
- 第 4 步：`GlobalTierSource`、白名单（bootstrap 之后 seal）、扩展合约、模板、工厂；模板的 codehash 与 artifact 一致；工厂的 SUPERPAYMASTER 等于 SP。
- 第 5 步：`upgradeToAndCall`；读回 `version() == "SuperPaymaster-5.5.0"`；三个 immutable 与 5.4.2 一致；BLS 三腿不变；抽样 `sbtHolders` 和 `userOpState`；存储快照与升级前逐项比对（前 36 项）。
- 第 6 步：`setXPNTsFactory`，读回。
- 第 7a 步：各社区发行 v2 代币；codehash 等于模板；默认分档源读回；operator 仍处于暂停状态。
- 第 7b 步：D-21，只写迁移记录。
- 第 7c 步：`updatePrice`，并读回 `cachedPrice.updatedAt > 0` 且未过期 → `configureOperator` → 取消暂停；每个社区跑一笔余额模式 op（fork 上用 impersonate 的 bundler 调 `handleOps`），AUTO 社区另跑一笔信用 op；读回烧币量、revenue、operator 余额，三者满足守恒。

## 5. 风险

| 风险 | 缓解 |
|---|---|
| Anvil 的 tracer 与 bundler 不完全兼容 | B0 反例判定；不通过就换 geth `--dev` |
| 上游 bundler 对 EntryPoint v0.7 与 Anvil 的组合要求 EntryPointSimulations 或特定的 RPC | 按各自文档部署或配置；遇到的问题写进报告 |
| fork 演练依赖归档 RPC；Alchemy 的 key 此前失效过 | 已换成 `~/Dev/.env` 里的有效 key；再用 publicnode 交叉验证 |
| `pendingAPNTsToken` 的去留是作者的决定 | 两条分支都演练，报告里并列写出结果，请作者选择 |

## 6. DSR 批准时的补充（2026-09-13，已并入）

1. **G2 守恒项**：对每个 bundle，比较 EntryPoint 里 SP 押金的实际 ETH 变化与该 bundle 各笔 charge 按验证期快照折算的 ETH 等值，断言 **Σ charge_eth ≥ ΔEP 押金**，即"不补贴"。统计超额比例 `(charge_eth − actualGasCost) / actualGasCost` 的均值、P95、最大值，作为论文 R1-8"保守报价多付"的第一版数据。被注入结算失败的那几笔属于 I10 情形（G 由 SP 押金承担），单独断言，不计入不等式的 charge 一侧。
2. **G1 质押门槛**：读出所用 Alto、Rundler tag 的默认 `minStake` 和 `minUnstakeDelay`，写进 D5-traceability。B9 和 B4 的"门槛以下"那一格，要断言**被拒的具体原因码**，不能只断言失败。
3. **G1 新增 B10**：用新的 paymasterAndData 格式，分别调用 Alto 和 Rundler 的 `eth_estimateUserOperationGas`，确认估算能跑通，并且估出的 `paymasterPostOpGasLimit ≥ MIN_POST_OP_GAS`。SDK 和 D7 依赖这条路径。
4. **pendingAPNTsToken（`0xBb46…`）**：两条分支都演练，结果并列。每条分支都写明对 RepCredit 冻结证据的影响，以及 operator 余额迁移的读回。**作者决定之前，runbook 第 1 步保持"阻塞"。**
5. G2 做完先单独交 DSR 验收，不等 D5 全部完成。
