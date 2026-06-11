# SuperPaymaster 全仓综合审计报告

| | |
|---|---|
| **审计日期** | 2026-06-11 |
| **审计基线** | `main` @ `145b3e0a`（v5.3.3-beta.2，已部署 Sepolia） |
| **合约规模** | SuperPaymaster 24,159B / Registry 24,352B（EIP-170 上限 24,576B） |
| **测试基线** | 979 forge 单测全绿 / 36 E2E / 0 失败 |
| **审计方法** | 7 个独立审计线程并行（6 个专项 Agent + Codex 独立对抗复核），关键 High 由主审逐行亲验代码闭合 |
| **审计范围** | 全部生产合约、架构一致性、Gas、测试体系、部署脚本、Open PR、v5.4 全部 issue 方案 |

---

## 0. 执行摘要（Executive Summary）

**总体结论：beta 可维持，无致命问题。** 不存在"必须撤回已发布 beta"级别的可被立即利用盗取真实资金的漏洞（且当前部署在 Sepolia 测试网，无真实资金）。合约整体设计成熟度高于同类项目，可见多轮安全加固（P0/H 编号体系、CEI、幂等、break-glass 时间锁、纵深防御、双记账不变量）。

但本次审计发现 **2 个合约层 High（建议 beta 期 hotfix）**、若干结构性/测试/运维 High，以及多个 Medium/Low。最重要的两个合约问题：

1. **信用上限可在 UserOp 执行期被绕过**（C-01 修复的余额短路给了绕过口）—— 经 Codex 与核心安全线程**独立命中**、主审**逐行亲验闭合**。
2. **xPNTs `transferFrom` 绕过紧急开关与每日限速**（P0-7/P0-8 只挂在 burn 路径）—— 主审亲验闭合。

二者均**真实可利用但非致命**：受 eligible 准入、`maxSingleTxLimit`、`minTxInterval`、operator pause 等多重缓解约束，是"慢性损耗 / 纵深防御缺口"而非"一击盗空"。建议在 beta 期开分支修复 + 测试 + 走 PR，**不影响已发布 beta**。

此外有一个**最紧急的跨仓协调项（非合约漏洞）**：issue **#229** 已被链上实现推翻（链上 EIP-712 domain 是 `"SuperPaymaster"`，#229 写的是 `"aastar.io"`），KMS/SDK 若按 #229 开发将**全部验签失败**——需立即裁决，否则产生跨仓返工。

### 严重度统计

| 严重度 | 数量 | 其中合约层 |
|---|---|---|
| **High** | 2（合约可利用）+ 11（结构/测试/运维/一致性/Gas） | 2 |
| **Medium** | 9 | 6 |
| **Low** | 14 | — |
| **Info** | 9 | — |

---

## 1. 合约安全发现（按严重度）

### 🔴 High

#### H-1｜信用上限可在 UserOp 执行期被绕过（C-01 缺口）
- **位置**：`SuperPaymaster.sol:819-826`（`_creditExceeded`）+ `xPNTsToken.sol:483-496`（`recordDebtWithOpHash`）+ `SuperPaymaster.sol:1343-1350`（`_recordDebt`）
- **交叉验证**：Codex 独立线程 + 核心安全线程**各自独立命中**；主审逐行亲验三环全部闭合。
- **攻击路径**（已亲验）：
  1. `_creditExceeded:822` 在 `balanceOf(user) >= xPNTsCharge` 时直接 `return false`（放行，**不查信用上限**）。
  2. ERC-4337 在 `validatePaymasterUserOp` 与 `postOp` **之间**执行账户自己的 calldata。eligible 用户充值刚好够 charge 的 xPNTs 通过余额检查，然后在自己的 UserOp 里 `xPNTs.transfer(otherAccount, balance)` 把余额搬空（普通 `transfer` 不受 `autoApprovedSpenders` firewall 限制，那个 firewall 只管 `transferFrom`）。
  3. `postOp → _recordDebt:1344` 先 try `burnFromWithOpHash`（余额 0 → revert/catch）→ 再 try `recordDebtWithOpHash`。
  4. `recordDebtWithOpHash:487` **只检查 `maxSingleTxLimit`（5000 ether）**，`debts[user] += amountAPNTs`（:494）直接累加，**完全没有 `getCreditLimit` 校验**。
  5. 结果：operator 验证时预扣的 aPNTs 已花在 gas 上，xPNTs 债务记在一个永不偿还的账户上 → operator 被慢性抽血。**这正是 C-01 设计要堵的场景**。
- **现实放大器**（H-1 与下文 M-2 叠加）：`Registry.sol:486-497` 的 ENDUSER 注册无需社区同意，且末尾无条件 `updateSBTStatus(user,true)` → 任意地址付 ticket 即可获得 eligible 身份。攻击门槛仅剩"持有目标社区 xPNTs"。
- **缓解因素**（故定 High 而非 Critical）：单次债务 ≤ `maxSingleTxLimit`；受 `minTxInterval` 频率限制；operator 可 pause；Sepolia 无真实资金。
- **建议修复**（团队需在 UX 与安全间权衡，本报告附 PR 实现保守方案）：
  - 方案 A（最稳，改 UX）：`_creditExceeded` 取消余额短路，**始终**强制 `getDebt + pendingDebts + charge <= getCreditLimit`。代价：零信用用户即便有余额也无法发起赞助交易。
  - 方案 B（影响最小，本报告采用）：保留余额短路，但在 `recordDebtWithOpHash` 落账前强制信用上限校验，超限则拒绝记账并自动 block 该 user（阻止重复），把"无限抽血"降级为"单次小额 + 自动封禁"。

#### H-2｜xPNTs `transferFrom` 绕过紧急开关与每日限速（P0-7/P0-8 缺口）
- **位置**：`xPNTsToken.sol:372-387`（`transferFrom`）vs `:741-762`/`:864-892`（限速/紧急开关只挂 burn）
- **交叉验证**：代币模块线程发现；主审亲验 `transferFrom` 代码闭合。
- **问题**（已亲验）：P0-7（`emergencyDisabled`）与 P0-8（`_checkAndConsumeRateLimit` 每日上限）的设计意图（注释 `:51-65`）是"halt **every** path that can affect another holder's balance"，但二者**只挂在 `burn`/`burnFromWithOpHash`/`recordDebt*` 上**。`transferFrom` 的 autoApproved 分支（:374-384）只做两项检查：目的地必须是自身或 SP、单笔 ≤ `maxSingleTxLimit` —— **无 `emergencyDisabled`、无每日限速**。
- **攻击路径**：被攻破/有 bug 的 autoApproved spender（如某社区的 AOA PaymasterV4，或 owner/factory 手动加的地址）可循环 `transferFrom(victim_i, self, ≤maxSingleTxLimit)` 抽干每个持有人；单笔限 5000 xPNTs 但**无每日累计上限、无持有人数量上限**。`emergencyRevokePaymaster()`（:642）只能撤销 SP 自己，对其他 autoApproved spender 无效 → 设计承诺的"一笔交易关停所有危险路径"失效。
- **缓解因素**：需 autoApproved spender 先被攻破（纵深防御失效，非直接利用）。
- **建议修复**（本报告附 PR 实现）：`transferFrom` 的 autoApproved 分支中，对 `to == msg.sender`（抽到自己）补 `if (emergencyDisabled) revert EmergencyStop();` 与 `_checkAndConsumeRateLimit(msg.sender, value)`；`to == SUPERPAYMASTER_ADDRESS`（正常 settle，SP 受紧急开关单独 de-authorize）保留豁免。

### 🟠 Medium

#### M-1｜x402 EIP-3009 路径缺 payer 签名的 maxFee + fee-on-transfer 超付
- **位置**：`SuperPaymaster.sol:1605-1615`、`:1556-1559`
- **交叉验证**：Codex + 核心安全线程一致。
- **问题**：`settleX402PaymentDirect`（C-02 路径）要求 payer 签名的 EIP-712 含显式 `maxFee` 且 `if (fee > maxFee) revert`（:1653）；但 EIP-3009 路径**无此约束**。payer 的 EIP-3009 签名只授权转 `amount` 给 SP，不约束 fee 分配 → 任意 `ROLE_PAYMASTER_SUPER` operator 可抽取至多 `MAX_FACILITATOR_FEE`（5%），payer 从未同意该费率。**第二**：该路径假设合约恰好收到 `amount`，对 fee-on-transfer/rebasing 资产会按名义 `amount` 超付，耗尽其他结算的储备（USDC 安全，但函数不限制资产类型，不同于 direct 路径的 `isXPNTs` gate）。
- **建议**：把 payer 签名的 `maxFee` 绑进 EIP-3009 流程；按 `balanceOf` 实收差额结算或白名单非通缩资产。

#### M-2｜无许可 ENDUSER 社区成员注入（社区无法门禁成员）
- **位置**：`Registry.sol:486-490`（ENDUSER 分支）+ `:227`（registerRole）+ `:495-497`（无条件 updateSBTStatus）
- **亲验**：✅ 确认。ENDUSER 注册只校验目标社区有 `ROLE_COMMUNITY`，**从不校验社区是否同意**；末尾对任意角色无条件 `updateSBTStatus(user,true)`。
- **影响**：任意地址付 ticket（0.3 GT）即可挂靠任意社区、获得 SBT 赞助资格、污染该社区成员/声誉基数；并直接放大 H-1 的可达性。
- **建议**：ENDUSER 路径强制 `data.community == msg.sender` 或携带社区授权签名/allowlist。

#### M-3｜safeMintForRole 允许跨社区代注册
- **位置**：`Registry.sol:311-329`
- **问题**：`safeMintForRole` 只要求调用者有 `ROLE_COMMUNITY`，对 ENDUSER 不校验 `data.community == msg.sender` → 社区 X 可替任意 victim 注册成社区 Y 的 ENDUSER，强制授予角色 + SBT 资格。与 M-2 构成跨社区成员污染通道。
- **建议**：ENDUSER 路径强制社区一致性或 victim 授权。

#### M-4｜UUPS 存储布局需用 forge inspect 跨版本核对
- **位置**：`Registry.sol:536-539`（`blacklistNonce` 在 `__gap` 前）；`ISuperPaymaster.sol:13-37`（OperatorConfig packed struct）
- **交叉验证**：角色质押线程 + 架构线程一致。
- **问题**：Registry 4.1.0→5.3.3 期间新增 `blacklistNonce`；SuperPaymaster v5.3.2→v5.3.3 因 OperatorConfig 字段位移**实际导致 in-place UUPS 升级不安全、被迫重部署**（PR #196）。packed struct + UUPS 组合埋下隐性 layout 雷，工具不强制。
- **建议**：CI 加 `forge inspect <C> storage-layout` 快照 diff gate（Registry + SuperPaymaster），任何改动 layout 的 PR 必须显式确认；新增变量一律"减 gap"而非追加。

#### M-5｜operator 可抢跑 withdraw 规避 Tier-1 slash
- **位置**：`SuperPaymaster.sol:771-782`（`withdraw`）
- **亲验**：✅ 确认。`withdraw` 无延迟、无 pending-slash 检查、无 paused 检查即可提走全部 `aPNTsBalance`。
- **缓解**：只逃得掉 Tier-1（aPNTs）罚没，逃不掉 Tier-2（GToken stake 在 GTokenStaking 合约不受影响）；slash 可走 private mempool 规避抢跑。故定 Medium 偏 Low。
- **建议**：引入延迟提款队列（队列资金仍可被 slash）+ paused/pending-slash 时阻断提款。

#### M-6｜exitRole 用 best-effort 缓存 gate 真实资金释放
- **位置**：`Registry.sol:261`（`roleStakes` 缓存）vs `GTokenStaking.sol:357-362`（`_syncRegistry` try/catch 可失步）
- **问题**：用可能失步的缓存决定是否 `unlockAndTransfer`；缓存被错置 0 而 lock 实存 → GToken 永久锁死。
- **建议**：`hasStake` 改用权威源 `getLockedStake(user, roleId) > 0`，缓存仅供 UI/索引。

### 🟡 Low（合约层，纵深防御与卫生）

- **L-1**｜遗留 `recordDebt`（无 opHash 去重）仍 external 可达，SP 误调会重复记债 — `xPNTsToken.sol:453-471`。建议移除或加 hash。
- **L-2**｜BLS owner 注册路径跳过 PoP，rogue-key 防护完全依赖链下 — `BLSAggregator.sol:261-264`。建议 owner 路径也强制 `_verifyPoP`。
- **L-3**｜`BLSAggregator.verify` 不绑 chainid，跨链重放下放给调用方 — `BLSAggregator.sol:323-353`。建议接口注释固化前置条件或自掺 chainid。
- **L-4**｜`GTokenStaking.slash()` 授权 slasher 可无上限/无范围/无冷却清零全部质押 — `GTokenStaking.sol:268-345`（仓库内无内部调用方，仅对 authorizedSlashers 开放）。建议加单次上限+冷却或删除。
- **L-5**｜slash / slashByDVT 均无合约层冷却 — `GTokenStaking.sol:268,498`。建议补兜底冷却或显式注释信任边界。
- **L-6**｜exitRole 对 paymaster 角色清理不对称，残留 roleMetadata/roleSBTTokenIds — `Registry.sol:270-282`。建议统一清理。
- **L-7**｜`markProposalExecuted` 允许 blsAggregator 预封锁合法提案号（DoS）— `Registry.sol:437-441`。建议绑定语义/事件审计。
- **L-8**｜`PROTOCOL_REVENUE_BUFFER` 固定 0.1 ether 不随流量/价格伸缩，高并发时可能 `ProtocolRevenueUnderflow` 静默少退 operator — `SuperPaymaster.sol:98`。建议改 owner 可配或按吞吐推导。
- **L-9**｜MicroPaymentChannel / settleX402 对 fee-on-transfer 资产记账不兼容（与 M-1 同源）— `MicroPaymentChannel.sol:200-211`。建议文档限定资产或按差额记账。

### ⓘ Info（合约层）

- **I-1**｜验证阶段读非关联外部 storage（balanceOf/getDebt/exchangeRate/getCreditLimit），ERC-7562 下虽有质押宽限但扩大验证期信任面并可能触发 bundler 限流 — `SuperPaymaster.sol:821-825,1104,1109`。建议与目标 bundler 确认质押 paymaster 规则，考虑快照入关联存储。
- **I-2**｜`dryRunValidation` 检查顺序（solvency 先于 credit）与真实路径相反，`ok` 一致但 reasonCode 可能误导链下消费方 — `SuperPaymaster.sol:1221-1232` vs `:1116-1124`。
- **I-3**｜`updateSBTStatus(true)` 对所有角色（含 COMMUNITY/DVT 运营角色）生效，赞助资格授予过宽 — `Registry.sol:495-497`。
- **I-4**｜BLSAggregator 死存储/死代码（`aggregatedSignatures`、`proposalNonces`、`_countSetBits`）— `BLSAggregator.sol:93,95,719`。建议删除减小 bytecode。
- **I-5**｜xPNTs clone 的 EIP-2612 permit 域名为空串（OZ v5 在实现合约缓存 `name=""`，clone 共享 bytecode）— `xPNTsToken.sol:256`。SDK 若用真实 `name()` 构造 permit 域会签出无法验证的签名。建议文档明确或 clone 上不暴露 permit。
- **I-6**｜ReputationSystem 评分全来自调用方输入，安全性下放给 Registry BLS proof — `ReputationSystem.sol:178-201`。建议确认 Registry 端 proof 覆盖 score 字段（评分本身无下溢，✅）。

---

## 2. 架构合理性（A）

### 🔴 High（结构债，非可利用漏洞，但阻碍 v5.4 演进）

- **A-H1｜SuperPaymaster god-contract**：1692 行 / 43 个外部函数 / 承载 6+ 职责（paymaster + 价格预言机 break-glass + operator 管理 + 双路 slash + 信用闸 + x402 双结算 + agent 赞助 + facilitator 费 + pending debt 恢复 + APNTS 时间锁换币），**仅余 417B**，v5.4 加任何 feature 必爆 EIP-170。**这是当前最高优先级结构债，不拆分则无法演进。** 建议优先把 x402 结算外移到独立 Facilitator 合约（项目已有 MicroPaymentChannel 先例），价格预言机抽成 SP/V4 共享模块。
- **A-H2｜Registry 双向调用环**：Registry ↔ Staking / MySBT / SuperPaymaster 全双向回调，靠 try/catch 缓解而非边界隔离。建议确立"Staking 是 stake 唯一真相"（INV-12），Registry 的 `roleStakes` 降级为纯展示缓存，删 slash/unlock 路径的逐 role 回调写。
- **A-H3｜SP 与 V4 PaymasterBase 预言机/计价逻辑大面积重复**：两份各自维护 PriceCache/价格边界/staleness/updatePrice/计价，逻辑同源实现分叉。建议抽 `PriceOracleLib` 共用。

### 🟠 Medium

- **A-M1**｜OperatorConfig packed struct + UUPS 已实际逼停一次升级（见 M-4）。
- **A-M2**｜immutable REGISTRY 与 mutable setter 非对称：可换 Staking 但永不可换 Registry，且换 Staking 时旧合约仍持全部质押无迁移路径 — `GTokenStaking.sol:48/95`,`MySBT.sol:123`,`Registry.sol:168`。建议补迁移 runbook + 部署断言。
- **A-M3**｜Scheme B 部署：`initialize(_owner,_staking,_mysbt)` 实际传 address(0) 再用 setter 接线，两参数沦为误导性死参；且 `setMySBT` 校验 code.length、`setStaking` 不校验（不对称）— `Registry.sol:78-105/168-198`。
- **A-M4**｜MySBT 不继承 IMySBT，Registry 强转调用仅靠约定对齐，无编译期保证 — `MySBT.sol:29-33` vs `Registry.sol:253/289/325`。

---

## 3. 代码一致性（B）

- **B-H1｜version() 三套命名标准**：`"Registry-5.3.3"` / `"Staking-4.2.0"`（前缀≠合约名）/ `"MySBT-3.2.0"` / `"SuperPaymaster-5.3.3"` / `"PMV4-Deposit-4.5.0"`（完全另一套），版本号 3.2.0~5.3.3 各飞各的，无法从单一版本号推断系统兼容性。建议统一 `合约名-X.Y.Z` + monorepo release 版本。
- **B-M1**｜custom error 与 require-string 混用，集中在 `BasePaymasterUpgradeable.sol:24,90`（全仓其余统一 custom error）。建议改 custom error，顺带省字节码。
- **B-M2**｜mutable storage 用 SCREAMING_SNAKE_CASE 暗示 immutable（`GTOKEN_STAKING`/`MYSBT`/`SUPER_PAYMASTER`/`APNTS_TOKEN`/`BLS_AGGREGATOR`）— 与真 immutable 撞命名风格，误导。建议 mutable 改 mixedCase。
- **B-L1**｜version() 的 virtual/override 修饰不一致（UUPS 用 virtual，pointer-replacement 不用，有理由但缺注释）。
- **B-L2**｜事件冗余携带 `block.timestamp`（MySBT/Registry 多个事件）— 纯浪费 LOG data word，indexer 可直接取。
- **B-L3**｜indexed 不统一（`OperatorConfigured` 的 xPNTsToken/treasury、`X402PaymentSettled` 的 asset 未 indexed）。
- **B-L4**｜MySBT 单字母命名（`_m`、参数 u/c/d/g/s/r/a/f）拉低可读性，与全仓不一致。

---

## 4. Gas / 性能（C）

> ⚠️ 所有 packing 类优化都改 UUPS layout。v5.3.3 既已声明 in-place 升级不安全/必须重部署，**这批 packing 应搭同一班车一次做完**，避免再背一次迁移。

### 🔴 High（热路径）

- **C-H1**｜每 op 两处 0→1 永久 SSTORE 做同一 opHash 三层防重放（~44k 且永不清理）— `SuperPaymaster.sol:1280-1281` + `xPNTsToken.sol:422-427/492-493`。建议（需安全签字）保留 token 级、删 SP 级 `_settledDebtOps` 或改 EIP-1153 transient。
- **C-H2**｜SP PriceCache 占 3 slot（decimals 恒 8、roundId 从不读），V4 已打包单 slot SP 没跟上 — `SuperPaymaster.sol:29-34`。打包省 ~4.2k/op。
- **C-H3**｜`getCreditLimit` 在验证热路径循环读 storage 数组（~19-21k/债务 op）— `Registry.sol:462-472`。建议 levelThresholds 打包单 slot 或 SP 本地镜像。

### 🟠 Medium / 🟡 Low（节选）

- **C-M1**｜totalSpent/totalTxSponsored 各占整 slot（合并省 ~5k/op）。
- **C-M2**｜aPNTsPriceUSD/protocolFeeBPS/priceStalenessThreshold 三热读变量各独立 slot（打包省 ~4.2k/op）。
- **C-M3**｜storage 版 ReentrancyGuard，Cancun 已启用未用 transient（换 transient 降到 ~400 gas；注意 SP UUPS slot1 占位）。
- **C-M4**｜`_creditExceeded` 重复调 `exchangeRate()`（`:1104` 已调一次，`:821` 再调）— 传参复用。
- **C-M5**｜slashUser 循环内逐 role 外部回调 `_syncRegistry`（≥2.6k/role）— Registry 加批量 sync。
- **C-M6**｜V4 entryPoint/ethUsdPriceFeed 用 storage 而非 immutable + oracleDecimals 恒 8 仍 SLOAD（省 ~8-12k/op）。
- **C-L**｜validUntil 在拒绝检查前算（~4.2k 白付）；V4 postOp 价格过期同 tx 调 2 次 latestRoundData；slashUser 主循环重读 roles。
- **C-Info**｜V4 双重 `_transferOwnership`；`registerRole` 应改 external；`_slash` 已 paused 仍重复 emit。

---

## 5. 部署 / 运维脚本（D）

- **D-H1**｜`srcHash` 跳过机制覆盖不足：`compute_src_hash()` 只 hash `contracts/src/*.sol`，不含 lib 子模块/singleton-paymaster/foundry.toml/部署脚本 — `deploy-core:103-110`。升级 OZ、改 optimizer runs、改 wiring 后会被误判"无变化"跳过。建议纳入 hash。
- **D-H2**｜check 失败不阻塞 + config 先写后验：`save_config`（:317-341）在 `run_checks`（:343-378）之前，且 checks 每个 `|| true` 仅计数 → 部署后 Check01-08 全挂仍写入新地址+srcHash，下次直接 skip — `deploy-core`。建议改 deploy→wire→断言→全通过才写 config，任一 check 失败 exit 1。
- **D-H3**｜DeployAnvil 与 DeployLive 各自手写 initialize 参数，易漂移（OperatorConfig 重排已踩同类坑 PR #196）— 建议抽共享 `_deployCore()`。
- **D-H4**｜wiring 步骤无完整性断言（setStaking/setMySBT/... 逐条执行，结尾无 `require(registry.GTOKEN_STAKING()==staking)`）— `DeployLive.s.sol:200-260`。建议末尾加 assert 块。
- **D-H5**｜srcHash 多人/多分支误判 + config 与链上无自动对账 — 建议 config 增 gitCommit/deployer，skip 前做链上 version() 抽查，CI 加每日 config↔链上 diff 报警。
- **D-M**｜签名者回退链非 anvil 也可能落到 anvil 默认 key；env `source` 无校验；硬编码 EntryPoint/Chainlink 散布多脚本；TestAccountPrepare try/catch 吞注册失败。
- **D-Low**｜PRIVATE_KEY 走命令行 ps 可见（优先 keystore）；init-submoduel.sh 拼写错误；**未发现明文私钥 echo（良好）**。

---

## 6. 测试体系（成熟度评分 6.5 / 10）

### 🔴 High

- **T-H1｜echidna 不变量套件整体失效**：`contracts/echidna/*.sol` import 已删除的 v2 合约路径（`v2/SuperPaymasterV2_3.sol` 等），**3 个 yaml 一个都跑不起来**，所表达的资金守恒/shares 1:1/no-inflation/one-sbt-per-user 等好不变量名存实亡。
- **T-H2｜forge 无 invariant、仅 1 个 fuzz 测试**：全仓唯一 fuzz 是 `PaymasterFactory_Coverage.t.sol:559`，0 个 `invariant_`，CI 的 `--fuzz-runs 10000` 实际只对这 1 个函数生效（空转）。资金守恒等系统级不变量**目前完全靠单测枚举分支近似**。
- **T-H3｜BLS.sol 零专属单测 + H-02 未闭环**：`contracts/src/utils/BLS.sol` 无专属测试（~2.86% 覆盖）；PoP 仅 permissionless 路径验证且无真实配对正向测试，rogue-key（H-02）在 forge 层仍是"⏳ needs deeper verification"。
- **附**：`.github/workflows/deep-scan.yml`（security.yml 注释引用的 Stage4 echidna/mythril）**不存在**。

### 🟠 Medium / 🟡 Low

- **T-M1**｜C-04/C-01 缺负向 E2E（低 postOpGasLimit 被拒、零额度用户被拒，链上无验证）。
- **T-M2**｜UUPS 无 storage-layout 快照比对（仅值级状态保持，__gap 收缩靠人工纪律）。
- **T-M3**｜exitRole cleanup 无逐步断言、M-02（operator isConfigured 残留）无测试。
- **T-M4**｜17 个文件 0 expectRevert（含名为 Security 的 `SuperPaymasterV3_Security.t.sol`、`APNTs_Integration.t.sol` 等只测 happy path）。
- **T-L**｜15 文件用 stdstore 直写状态（sbtHolders/APNTS_TOKEN，绕过 Registry 联动，mock 漂移风险）；杂物进主套件（Debug.t.sol/TestEncoding.t.sol/BadContract.sol/paper7 论文实验代码）；硬编码 Sepolia 地址；CI Stage2 套件重复跑两遍；workflows 残留 `.backup.*` 文件。

### 覆盖矩阵缺口

| 生产合约 | 状态 |
|---|---|
| `utils/BLS.sol` | **零专属单测** |
| `GToken.sol` | 薄弱（无专属文件） |
| `BasePaymasterUpgradeable` | 薄弱（仅 UUPS 间接） |

六项安全修复 E2E 对照：C-02 ✅、C-03 ✅、H-01 ✅、H-02 ✅、**C-01 ⚠️ 仅正向无负向**、**C-04 ❌ 无负向 E2E**。

---

## 7. Open PR 审查

> 当前实际 open：**#233 / #239 / #241 / #242**（#234 已被 #242 取代）。

| PR | 评价 | 建议动作 |
|---|---|---|
| **#233** actions bump（checkout v4→v6、slither 0.4.0→0.4.2） | diff 安全，CI 全绿。actions 用 tag 非 SHA pin（既有风格） | 可 merge（但受 #239 缺陷影响，见下） |
| **#239** Dependabot auto-merge | 安全性三项验证通过（SHA pin `d7267f6` 实测正确、triple guard 齐、无 checkout）。**但有功能缺陷** | **改后 merge** |
| **#241** hono 4.12.18→4.12.21 | 纯 patch，被 #242 覆盖 | **关闭**（#242 取代） |
| **#242** facilitator-node 5 包分组 bump | minor/patch，diff 干净 | 可 merge（建议先本地 `pnpm typecheck`） |

### #239 功能缺陷（重要，需修）
required status checks（`test`/Stage1/Stage2/secret-scan）带 `paths: contracts/**` 过滤，**npm-only Dependabot PR（#241/#242）根本不触发这 3 个 check** → GitHub 对"required 但从未 report"的 check 永久显示 Expected 并阻塞 merge，`gh pr merge --auto` 永久挂起；且 npm PR 上实质 CI gate 只剩 secret-scan（≈无测试合并）。**修复**：① 加镜像 workflow（同 job 名 + 反向 paths）对被跳过的 PR report success（GitHub 官方 "skipped-but-required" 模式）；② 给 `packages/x402-facilitator-node` 加路径触发的 `pnpm install --frozen-lockfile && typecheck && build` job 并设 required。

---

## 8. v5.4 Issue 方案审查（准确性 / 最优性 / 优先级）

> 注：v5.4 milestone（#1）已创建，#201–#218 + #237/#238 共 20 个 issue 已挂入（审计期间确认）。

**描述需更正的 issue**：
- **#201**（retryPendingDebt replay）：威胁描述**夸大** —— 债务总量严格受 pendingDebts 余额约束（先减 pending 再 recordDebt、`pending==0` revert、金额钳制、无 try/catch），非真实可利用 replay。**建议 Critical→Medium**，不必进 beta hotfix；且提议的 hash 含 `block.number` 会与 H-01 分块重试碰撞，需加 nonce。
- **#204**（xPNTs 授权绕过）：**部分过时** —— 已有 transferFrom firewall + maxSingleTxLimit；**仍成立的缺口正是本报告 H-2**（emergency/日限额）。`emergencyDisabled` 一行修复成本极低，**建议提前到 beta**。
- **#208**（postOp 汇率快照）：定位错误（实际读 `IxPNTsToken.exchangeRate()` 非 `operators[].exchangeRate`），且修复比描述复杂（换算在 token 内部）。建议改用"postOp 重读 rate 与 context 中 snapshot maxRate 比较"的轻方案。
- **#211**（UUPS batch）：L-F 描述有误（depositFor 实有角色检查），且其修复 `withdraw` 加 `require(isConfigured)` 会**锁死已退出 operator 余额** → 建议从 batch 剔除 L-F。缺标注 blocked by #210。
- **#215**（recordDebt 累计上限）：SP 侧已有 `_creditExceeded` 信用闸，真正缺的是 token 侧 `maxDebtPerUser` 自防御 —— 但**注意本报告 H-1 表明该信用闸可被绕过**，两者需合并考虑。

**依赖标注缺口**：#206/#213 的 `#(L-A issue)` 占位符未回填为 **#210**；#211 应加 blocked-by #210；#237/#238 缺 label。

**优先级调整建议**：
- **#202**（BLSAggregator target 白名单）：实际严重度接近 High（可操纵价格缓存 + 任意 slash，虽 onlyOwner 函数挡掉一部分），白名单 setter 的 timelock 应从 optional 改 **mandatory**。

**建议关闭**：
- **#92**（syncExitFees 自动化）：**已修复**（`Registry.configureRole:358` 已自动调 `setRoleExitFee`）。
- **#241**：被 #242 取代。
- **#229**：⚠️ **已被链上实现推翻**（链上 domain `"SuperPaymaster"/"1"` + `X402PaymentAuthorization` typehash，#229 写的 `PaymentPayload` + `"aastar.io"`）。**KMS/SDK 若按 #229 实现将全部验签失败** —— 需立即与 AirAccount#21 同步裁决（应对齐 `"SuperPaymaster"`），关闭或彻底重写。**本项是当前最紧急跨仓协调项。**

**长期 issue**：
- **#91**（updatePriceDVT owner 偏差约束）：大部分已被 `emergencySetPrice` 取代，剩余仅一行（从 `updatePriceDVT` 移除 owner 直通），可并入 #211。
- **#90**（accountToUser 下游）：6 周无更新，建议指派+设截止或关闭。
- **#95**（ENDUSER 测试覆盖）：保留，并入 #216。
- **#223**（KMS Q1–Q4）：已回应（审计期间确认），保留待转 docs。

### Issue 体系缺口（该提未提）
1. **#239 required-checks 路径过滤缺口**（见 §7）—— 应开 CI 修复 issue。
2. **#210 压缩预算不足**：150B 只够 H-4/M-2，未算 #211 的 timelock；需"Registry v5.4 字节预算总表"或评估外置 OZ TimelockController。
3. **v5.4 统一重部署窗口协调 issue**：#202/#203/#204/#205/#207/#209/#212/#215 都要重部署，应有统一"redeploy window + 状态迁移演练"协调项（复用 MigrateToUUPS Phase 0 模式，先 fork 全流程演练）。

---

## 9. 已检查无虞清单（通过项）

以下经三个安全线程交叉确认**未发现问题**，作为正向记录：

**资金会计与不变量**
- postOp 双记账不变量 `totalTrackedBalance = Σ(operator balances) + protocolRevenue` 在 validate/postOp 退款/slash/withdrawProtocolRevenue 全路径保持（含 underflow clamp）。
- Registry/Staking 资金守恒：lock/unlock/slash/topUp/exitFee 三方账目一致，**无重复注册/退出套利路径**（每周期净成本 = ticket + exitFee）。
- slash 按比例扣减 + dust 回填数学正确，`postSlashAmounts` 按 roleId 同步不受 `_cleanupZeroLocks` swap-pop 影响。
- mulDiv 取整方向全部对协议有利（计价/buffer/charge Ceil，repay Floor）。
- xPNTs 自动还债 `_update` 不变量 `ceil(floor(value/rate)·rate) ≤ value` 成立，永不多烧。

**重放 / 幂等 / 时间锁**
- C-02 direct settle：签名先于 nonce 写、maxFee 强制、isXPNTs + facilitator gate、任意 from 被签名阻断。
- C-03 recipient 绑定：`nonce=keccak256(abi.encode(to,salt))`，改 to 即签名失效，**机理正确**。
- P0-13 x402 nonce 三键隔离 + legacy guard；burnFromWithOpHash 跨路径双 hash 查重。
- GTokenAuthorization EIP-3009：typehash 区分 transfer/receive/cancel、ECDSA.tryRecover 拒 high-s/零地址、nonce 三态 + 严格 CEI、5 分钟窗口。
- APNTS_TOKEN 7 天时间锁 + drain 不变量；MicroPaymentChannel 累积 voucher 防重放 + channelId 绑 chainid/合约 + closedChannels 防重开重放 + 全函数 nonReentrant CEI。

**访问控制 / 升级 / 密码学**
- UUPS `_authorizeUpgrade` onlyOwner；`initialize` initializer 保护 + 构造器 `_disableInitializers()` + 部署脚本 ERC1967Proxy 原子初始化（**无抢跑**）。
- Slash caps：slashOperator/executeSlashWithBLS 均 30% cap，owner slash 24h cooldown，uncapped 分支不可达。
- Oracle break-glass：emergencySetPrice 要求 Chainlink stale + ±20% band + 7 天过期；updatePriceDVT 拒非递增/>2h/未来时间戳。
- BLSAggregator pkAgg 链上重建（caller 无法注入）、逐 slot 实时校验 isActive+ROLE_DVT+锁仓、G1 on-curve + prime-order subgroup（全标量乘 r 不被约简）+ 拒 identity；permissionless PoP 用域标签隔离防 rogue-key。
- SBT 不可转移（`_update` 拦 from≠0&&to≠0）、onlyRegistry mint/burn、MAX_MEMBERSHIPS 限 gas。
- xPNTsFactory Clones 非确定性地址 + 同 tx initialize（无抢跑）+ communityToToken 防重复 + COMMUNITY gate。
- 重入面：核心写函数 nonReentrant + 外部对象受信 + GToken 标准无回调 ERC20。

---

## 10. 修复路线图与优先级

### P0 — beta 期 hotfix（开分支修复 + 测试 + PR，不影响已发布 beta）
1. **H-1 信用上限绕过** — 本报告附保守修复 PR（fallback 落账前强制信用上限 + 自动 block）。
2. **H-2 transferFrom 绕过应急开关** — 本报告附修复 PR（两行 emergencyDisabled + 限速）。亦覆盖 issue #204 的核心缺口。
3. **#229 裁决**（非合约改动，跨仓最紧急）— 立即与 AirAccount#21/SDK 同步对齐 `"SuperPaymaster"` domain。

### P1 — v5.4（重部署/UUPS 升级窗口，需审计 + fork 演练）
- M-2/M-3 ENDUSER 许可模型、M-4 storage-layout CI gate、M-5 提款延迟队列、M-6 缓存权威源。
- 既有 issue：#202（升 High + mandatory timelock）、#203、#207、#208（修正方案）、#209、#212。
- **架构拆分（A-H1/A-H2/A-H3）+ Gas packing（C-H1/C-H2/C-H3）打成同一"必然重部署"版本一次做完**，CI 加 storage-layout 快照 gate。

### P2 — 测试 / CI / 运维基建
- 修活 echidna（移植到 V5.3 合约或转 forge `invariant_`）+ 补 INV-03 资金守恒不变量（T-H1/T-H2）。
- BLS.sol 专属测试 + H-02 真实配对验证（T-H3）。
- 部署链路重构 deploy→wire→断言→写 config（D-H1~H5）。
- 修 #239 CI 路径过滤缺陷。
- 补 C-01/C-04 负向 E2E。

### P3 — 一致性 / 卫生（搭便车）
- version() 统一命名（B-H1）、custom error 统一、mutable 命名、事件冗余 timestamp、死代码清理。

---

## 附录：审计方法论

本次采用 **7 线程并行 + 独立对抗复核 + 主审亲验** 方法：

| 线程 | 范围 | 引擎 |
|---|---|---|
| 核心 Paymaster 安全 | SuperPaymaster/Base/V4/Factory | 专项 Agent |
| 角色/质押安全 | Registry/Staking/MySBT/GToken | 专项 Agent |
| 代币/模块安全 | xPNTs/GTokenAuth/BLS/DVT/Reputation/MPC | 专项 Agent |
| 架构 + 一致性 + Gas | 全仓 | 专项 Agent |
| 测试覆盖 | test/ + echidna + E2E | 专项 Agent |
| PR/Issue 方案 | Open PR + 26 个 issue | 专项 Agent |
| **独立安全复核** | SuperPaymaster.sol 对抗性 | **Codex（Tier-1）** |

**交叉验证亮点**：H-1（信用绕过）由 Codex 与核心安全线程**各自独立命中**，主审逐行亲验闭合；H-2、M-2、M-5 均由主审独立读代码确认。报告中标注"亲验✅"的发现均经主审打开源码核对，非单纯采信 Agent 输出。

**局限**：本次为静态/只读审计 + 测试基线确认，未做链上 fork 攻击复现 PoC；BLS 密码学层（H-02 rogue-key）的真实配对验证仍是已知未闭环项；UUPS 跨版本 storage layout 一致性需用 `forge inspect` 对已部署 4.1.0/5.3.2 字节码实测确认（建议作为 hotfix 前置）。

*报告生成：2026-06-11 · 基线 commit `145b3e0a` · 979 测试全绿*
