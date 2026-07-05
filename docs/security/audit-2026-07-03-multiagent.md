# SuperPaymaster 安全审计报告（多 Agent 对抗式人工审计）

**日期**: 2026-07-03
**分支**: `fix/p0-cei-registry-callcheck`（HEAD `37121266`）
**版本**: SuperPaymaster-5.4.1-rc.1
**范围**: `contracts/src/**` 全部核心合约（约 9,200 行）
**方法**: 5 个并行审计 Agent 分域深挖 + 逐条源码对抗验证。所有 High/Medium 均由审计主控**亲自读源码复核**，非快照照搬。
**基线**: 已对照 `docs/security/slither-report-2026-06-28.md`（Slither 0.11.5），下文对其结论有修正与补充。

---

## 一、总体结论

代码库整体**加固程度很高**。SuperPaymaster v3 核心、Registry、GTokenStaking、MySBT、EIP-3009、BLS 配对等经过多轮审计，绝大多数经典攻击面（重入、replay、UUPS 初始化、ecrecover 零地址、rogue-key）都已闭合。本次审计**未发现 Critical**，但发现 **3 个 High、6 个 Medium** 以及若干 Low，集中在**跨合约信任边界**与**经济/配置**层面——这些是快照工具难以覆盖、需要人工构造场景才能暴露的问题。

| 严重级 | 数量 | 主题 |
|---|---|---|
| Critical | 0 | — |
| **High** | 1 | BLS slash 门槛不一致 / 通用调用爆炸半径（H-1） |
| **Medium** | 5 | slash 弱多数+无证据(M-5)、退出费 100% 没收(M-1)、SP 依赖锁死资金(M-2)、跨 operator 信用敞口(M-3)、退款缓冲被吞(M-4) |
| Low | 16 | 见第四节（含由 H-2/H-3/M-6 降级而来） |
| Info / 修正 | 多项 | 含对 Slither M-1 的修正 |

> **2026-07-04 动机复核修订**：经与团队对抗式复核，**H-2 降为 Medium、H-3 降为 Low、M-6 降为 Low**。理由：H-2 的资金全部进入 SuperPaymaster 黑洞（SP 无任何函数可记账/取回转入的 xPNTs），**无盈利动机、纯 griefing**，且需 facilitator 私钥先被攻破；H-3 的 V4 只收 owner 自定价的社区自有 token，攻击者需先持有有价值的社区币且 operator 需**误配** `maxGasCostCap` 低于真实 gas，本质是**补贴泄漏/配置隐患**而非外部抽干攻击。H-1 因"通用 `.call` 爆炸半径"保留 High，详见独立 issue `ISSUE-slash-mechanism-design.md`。

**对上一轮 P0 修复的验证**（本分支顶部 commit）：
- ✅ PaymasterFactory CEI（Slither M-2）——已正确前置状态写入，`deployPaymaster` / `deployPaymasterDeterministic` 均修复。
- ✅ Registry 低层 call 返回值（Slither M-7）——`_initRole` / `_syncExitFeeForRole` / `syncExitFees` / `burnSBT` 均已捕获 `ok` 并 emit 失败事件，无遗漏。
- ✅ Chainlink stale round（Slither M-12）——SuperPaymaster `updatePrice` 已校验 `answeredInRound >= roundId` + 上下界 + 未来时间戳。
- 🔄 **修正 Slither M-1**（xPNTs divide-before-multiply）：精度损失真实存在，但取整方向**始终偏向协议**（`_update` 用 floor 铸/ceil 还、`burnFromWithOpHash` 用 ceil、`repayDebt` 用 floor），单次误差 ≤ 1 wei-unit，**无法构造提取/抽干**。降级为 Info。

---

## 二、High 发现（3）

### H-1 — 通用 `executeProposal` 把 slash 法定人数从 7 降到 3（跨合约门槛降级）

**文件**: `modules/monitoring/BLSAggregator.sol:450-490`；`paymasters/superpaymaster/v3/SuperPaymaster.sol:842-846, 889-904`
**验证**: ✅ 已读源码确认

**根因**：SuperPaymaster 的 slash 入口只做身份校验、**不复验 BLS 证明门槛**：
- `queueSlash` (L843)：`if (msg.sender != owner() && msg.sender != BLS_AGGREGATOR) revert`
- `executeSlashWithBLS` (L890)：`if (msg.sender != BLS_AGGREGATOR) revert`；`proof` 仅在 L904 被 `keccak256` 记录做审计，**未做任何验证**——完全信任 aggregator。

而 aggregator 有两条路径调用这些特权函数：
- 专用路径 `verifyAndExecute` (L417) → `_checkSignatures(proof, hash, defaultThreshold)`，**门槛 = 7**。
- 通用路径 `executeProposal` (L477) → `_checkSignatures(proof, hash, requiredThreshold)`，门槛 = 调用方自选的 `requiredThreshold`，**只要 ≥ minThreshold（默认 3，可低至 2）**，随后对**任意 target/callData** 执行 `target.call`（L480，无 allowlist，仅 `target != 0`）。

因此，凡能调用 `executeProposal` 者，可用 3 个签名让 aggregator 以自己身份调用 `queueSlash` + `executeSlashWithBLS`，达成本应需要 7 签名的 slash。

**利用前置**：`executeProposal` 调用者须为 `owner()` 或 `DVT_VALIDATOR` 合约。经核对，DVTValidator **不转发**到 `executeProposal`，故实际调用者是 **BLSAggregator 的 owner**。即：**owner + 3 个共谋验证者**即可暂停任意 operator 并烧掉其最高 30% aPNTs 余额（`executeSlashWithBLS` 路径不受 owner 路径的 24h 冷却约束）；可每日重复。

**关键不对称**：Registry 的 `batchUpdateGlobalReputation` 会**独立复验** BLS 证明（`Registry.sol:414-417`），所以声誉路径安全；唯独 SuperPaymaster 的 slash 路径**不复验**，成为唯一可降级的特权入口。这也意味着同一 `target.call` 原语可在门槛 3 下打到所有 aggregator-gated 函数（`Registry.markProposalExecuted`、`DVTValidator.markProposalExecuted`）做 proposalId DoS。

**修复**（任选，推荐 a+b）：
- (a) 让 `executeSlashWithBLS` / `queueSlash` **自行复验** BLS 证明并强制 `defaultThreshold`，不再裸信 `msg.sender == BLS_AGGREGATOR`（对齐 Registry 的复验模式）。
- (b) 在 `executeProposal` 加 target/selector allowlist，排除 SuperPaymaster/Registry/DVTValidator 的共识函数；或当 target 为特权合约时要求 `requiredThreshold >= defaultThreshold`。

---

### H-2 — 紧急开关 + 日限额被 `transferFrom(受害者 → SuperPaymaster)` 绕过

**文件**: `tokens/xPNTsToken.sol:383-417`（守卫在 410-413）
**验证**: ✅ 已读源码确认

xPNTs 防火墙允许任意 `autoApprovedSpenders[msg.sender]` 把持有者代币转到 `to == msg.sender` **或** `to == SUPERPAYMASTER_ADDRESS`。两个安全阀（`emergencyDisabled` 紧急停机、`_checkAndConsumeRateLimit` 日限额）**只加在自拉分支**：

```solidity
if (to == msg.sender && to != SUPERPAYMASTER_ADDRESS) {  // L410
    if (emergencyDisabled) revert EmergencyStop();
    _checkAndConsumeRateLimit(msg.sender, value);
}
```

代码注释（L404-409）声称：目的地为 SP 的拉取是合法结算路径，"e.g. `msg.sender == to == SP`"。但守卫**只判断了 `to == SP`，没判断 `msg.sender == SP`**。任何**非 SP** 的 autoApproved spender（如通过 `addAutoApprovedSpender` 加入的 facilitator），当 `to == SUPERPAYMASTER_ADDRESS` 时同时命中：防火墙放行（L387）、`_spendAllowance` 对 autoApproved 是 no-op（无需 per-victim 授权）、且**跳过两个安全阀**。

**利用场景**：社区同时有 SP + 二级 facilitator `F`（均 autoApproved，属正常配置）→ `F` 被攻破 → owner 调 `emergencyRevokePaymaster()`（只解除 SP 授权 + 置 `emergencyDisabled=true`，`F` 仍在名单）→ 攻击者循环 `F.transferFrom(victim_i, SP, balance_i)` 把**每个持有者余额强制搬入 SP 合约**，紧急开关与日限额全程失效。至少构成事件期间**无上限的强制资金位移**；若 SP 记账把无主入账 xPNTs 归给某 operator，则升级为**直接盗窃**。此路径严格弱于 `burn(from,amount)`——而 burn 路径**是**有紧急门禁（L925）和限额（L946）的，正是 P0-7/H-2 声称已闭合的不一致。

**修复**：把两个安全阀改为按**调用者**判断，仅豁免真正的 SP 自调：
```solidity
if (msg.sender != SUPERPAYMASTER_ADDRESS) {
    if (emergencyDisabled) revert EmergencyStop();
    _checkAndConsumeRateLimit(msg.sender, value);
}
```

---

### H-3 — PaymasterV4 `maxGasCostCap` 静默少收 → 抽干 paymaster 的 EntryPoint ETH 押金

**文件**: `paymasters/v4/PaymasterBase.sol:262, 278, 341-350`
**验证**: ✅ 已读源码确认

- validate (L262)：`cappedMaxCost = maxCost > maxGasCostCap ? maxGasCostCap : maxCost;`，token 预扣按 `cappedMaxCost` 计（L278/286）。
- postOp (L348-350)：实际收费按真实 `actualGasCost` 重算，但**封顶在 `preChargedAmount`**。

而 EntryPoint 按真实 `actualGasCost`（≤ `maxCost`）从 paymaster 押金扣 **ETH**。当 `actualGasCost > maxGasCostCap` 时，paymaster 用 ETH 兜底全部 gas，却只收到 `maxGasCostCap` 对应的 token。`maxGasCostCap` 只被限制在 `(0, 100 ether]`（L211/650），任意低值都被接受；且 **V4 validate 无 SBT/资格门禁**（只查余额，L281），任何充过币的地址都被赞助。

**利用场景**：operator 把 `maxGasCostCap` 设成"保护性"低值（如 0.01 ETH）→ 攻击者 `depositFor` 一笔够单次封顶的廉价社区币 → 提交 `callGasLimit` 灌大、真实消耗高 gas 的 UserOp（`actualGasCost` 如 0.05 ETH）→ 只付 0.01 ETH 对应的 token，paymaster 净损 ~0.04 ETH 押金 → 循环直至押金耗尽。攻击者成本是低价社区币，损失方是 ETH。若攻击者兼任 builder，还能通过 priority fee 部分回收，形成套利。

**修复**：validate 中当 `maxCost > maxGasCostCap` 时**直接拒绝**该 op（返回校验失败），而非静默压低收费；或按真实 `maxCost` 计价预扣并要求余额覆盖。**不可同时**"付全额 gas" + "把 token 收费压到 gas 之下"。

---

## 三、Medium 发现（6）

### M-1 — Registry `minExitFee` 无上界，击穿 20% 退出费上限 → 100% 没收质押
**文件**: `GTokenStaking.sol:454-462, 364-374`；`Registry.sol` configureRole
**验证**: ✅ 已读源码确认
`setRoleExitFee` 只限制 `feePercent > 2000` revert（L457），但 `minFee` 完全无界（L460）。`_previewExitFee`：`if (fee < minFee) fee = minFee; if (fee > amount) fee = amount;`——把 `minExitFee` 设为极大值即令每次退出 `fee = amount`，operator `net = 0`，全部 GToken 质押转入 treasury。这绕过了明文注释"P1-41: prevent owner setting ruinous exit fees"的 20% 上限意图。owner 可信，但**用于约束 owner 的控制本身可被 owner 绕过**，且委托的角色 owner 是更弱的信任边界。
**修复**：`_previewExitFee` 中把有效 fee 封顶在 `amount*2000/10000`，使 20% 不变量与 `minFee` 无关；或给 `setRoleExitFee` 的 `minFee` 加上界。

### M-2 — 可 revert 的 SuperPaymaster 会锁死角色注册与质押提取
**文件**: `Registry.sol:303-306, 525-527`
`exitRole` 与 `_validateAndProcessRole` 以**高层（可 revert）调用** `ISuperPaymaster(SUPER_PAYMASTER).updateSBTStatus(...)`。若 SP 代理被暂停 / 升级后 buggy / 任意 revert，`exitRole` 在最终角色路径 revert——用户既不能退出也取不回锁定的 GToken，且所有新 `registerRole` 也 revert。这与同函数里已刻意改成**低层 call + `SBTBurnFailed` 事件**的 `burnSBT` 不一致，而 `updateSBTStatus`（把守资金释放）反而更关键。
**修复**：把 `updateSBTStatus` 也包成低层 `call` + 失败事件，SP 异常不得 brick 质押提取。

### M-3 — 信用额度按 xPNTs-token 而非全局聚合，单身份系统敞口 = N×L
**文件**: `SuperPaymaster.sol:805-827, 1162, 1399`
`_creditExceeded` 用 `IxPNTsToken(token).getDebt(user)`（**每 token**）+ pendingDebts + charge 与 `REGISTRY.getCreditLimit(user)`（**每用户全局**）比较。每个 operator 有独立 xPNTs，故额度按 operator 独立执行。一个身份在 N 个 operator 下各背 `L` 债务，每 token 检查都独立通过，系统级承担 **N×L** 未偿债务；集体违约时每 operator 各吃 `L`。单 operator 仍被 `L` 约束（"operator 不被抽干"成立），但与"全局信用分"的语义相悖。
**修复**：若 `getCreditLimit` 意为全局，则在 paymaster 内维护全局 `userDebtAPNTs[user]` 聚合校验；若意为 per-operator，则改名并明确文档。

### M-4 — owner 抢跑 `withdrawProtocolRevenue` 吞掉 operator 在途退款缓冲
**文件**: `SuperPaymaster.sol:788-803, 1172-1175, 1341-1356`
validate 阶段把含 10% VALIDATION_BUFFER 的**全额加价**记入 `protocolRevenue`（L1175）；postOp 通过 `protocolRevenue -= refund` 退还超收，但 `refund > protocolRevenue` 时被 clamp、operator 被静默少退（`ProtocolRevenueUnderflow`，L1344-1347）。owner 观察到大量在途 op 后 `withdrawProtocolRevenue` 抽到仅剩 `PROTOCOL_REVENUE_BUFFER`（0.1 ether，注释只够 ~10 并发），待 postOp 落地时各 operator 退款被 clamp 到近零、永久计入协议收入。owner 可信（中心化/griefing），但确为可由 owner 时序触发的真实 operator 资金损失，且缓冲对真实并发明显偏小。
**修复**：把 operator 可退缓冲与协议**真实费用**分池，`withdrawProtocolRevenue` 只能取真实 fee，不得触碰在途缓冲。

### M-5 — slash/blacklist 共识为弱多数（7/13），且签名消息不含证据哈希
**文件**: `BLSAggregator.sol:97-98, 404-431`；`DVTValidator.sol:175-193`
`defaultThreshold = 7 / 13` 是简单多数，非 BFT slashing 常见的 ≥2/3（9）。签名消息只承诺 `proposalId, operator, slashLevel, repUsers, newScores, epoch, chainid`——**无 evidence/fault-proof 哈希**，`reason` 字符串未经签名认证。共谋多数可对任意 operator 无链上依据地 slash。叠加 H-1，有效门槛进一步降到 3。
**修复**：`defaultThreshold` 提到 ≥ ceil(2/3·N)；把 `evidenceHash` 绑入签名消息并 emit；显式文档化诚实多数假设。

### M-6 — PaymasterV4 `depositFor` 记账按名义额，fee-on-transfer 代币破坏账目
**文件**: `paymasters/v4/PaymasterBase.sol:619-625`
`safeTransferFrom(msg.sender, this, amount)` 后 `balances[user][token] += amount`，记的是**名义额**而非实收。若支持的社区币有转账费/通缩，内部账本 > 实际持有，最后提取者 `withdraw` 因余额不足而 revert，资金被社会化；早存早取者可多提。
**修复**：measure `balanceOf(this)` 前后差额入账；或显式禁止 fee-on-transfer 代币。

---

## 四、Low 发现（14）

| # | 文件 | 摘要 | 修复方向 |
|---|---|---|---|
| L-1 | `PaymasterFactory.sol:197-251` | `deployPaymasterDeterministic` 的 salt 不含 operator，可被抢跑/占址（DoS+squat，非盗币） | salt 混入 `msg.sender`，同步 `predictPaymasterAddress` |
| L-2 | `xPNTsToken.sol:979-996` | `exchangeRate` 由 owner 每小时 ±20% 走高，债务按结算时汇率折算，可温水加价（仅本社区持有者，有界） | 债务按计提时汇率结算，或收紧 delta/延长冷却 |
| L-3 | `Registry.sol:330-348` | `safeMintForRole` 无被授对象同意，可强制给任意地址挂 soulbound SBT（griefing/声誉污染） | 要求目标签名同意或预授权 |
| L-4 | `Registry.sol:341-364` | 社区代付质押，退出时 `unlockAndTransfer` 退给 beneficiary 而非 payer（经济 footgun） | 记录 sponsor 并退给 sponsor，或明文"代付即赠与" |
| L-5 | `Registry.sol:567-569` | `blacklistNonce` 加在 `__gap[50]` 前未减 gap（升级布局卫生） | 减 `__gap[49]`，升级前 `forge inspect` 逐槽比对 |
| L-6 | `SuperPaymaster.sol:5,24` | UUPS 代理继承非升级版 `ReentrancyGuard`（`_status` 代理里初始 0）——**已核实不可利用**（自愈，仅首调无 gas 返还） | 改用 `ReentrancyGuardUpgradeable` |
| L-7 | `SuperPaymaster.sol:1583-1590` | `__gap` 注释与代码不一致（注释称 [31]，代码 `[30]`）；新变量分散声明 | 升级前逐槽比对部署布局，修正注释 |
| L-8 | `SuperPaymaster.sol:715-724` | fee-on-transfer/rebasing 的 `APNTS_TOKEN` 破坏 `totalTrackedBalance`（owner 配置边界） | 按实收 delta 入账，或断言标准代币 |
| L-9 | `SuperPaymaster.sol:633-699` | Chainlink 宕机时 `updatePriceDVT` 跳过 ±20% 偏离校验，owner/aggregator 可设极端价 | 宕机分支也用相对 `cachedPrice` 的窄带 |
| L-10 | `X402Facilitator.sol:246-257` | EIP-3009 结算 fee 可被另一 operator 抢跑窃取（仅 fee 归属，付款人无损） | 把目标结算方绑入授权/nonce |
| L-11 | `X402Facilitator.sol:292-326` | `settleX402PaymentDirect` 无实收 delta 检查（有 `isXPNTs` 门禁缓解） | 复用 EIP-3009 路径的 balBefore/After |
| L-12 | `MicroPaymentChannel.sol:184-226` | `authorizedSigner` 不可轮换/撤销，session key 泄露最多被抽干 deposit | 加 payer-only `setAuthorizedSigner` |
| L-13 | `BLSAggregator.sol:259-314` | 两个验证者地址可注册相同 G1 公钥，单密钥算 2 票（各槽仍需独立 minStake 缓解） | `usedKeyHash` 去重 |
| L-14 | `ReputationSystem.sol:94-108` | 社区可自设 `baseScore` 至 10000 并无限 push 规则 ID，自抬本社区分 + gas griefing（全局分另有 Registry 复验保护） | 规则数量封顶、去重、聚合分上界 |

---

## 五、Info / 已验证防护（无需动作）

**修正 Slither 报告**：M-1（xPNTs divide-before-multiply）取整偏向协议、不可利用，降为 Info。

**已确认稳固（读码验证，非发现）**：
- **访问控制**：三大核心合约每个 state-changing 外部函数都有正确 modifier；无匿名可调 mutator、无自助授角、无跨社区 slash。`syncStakeFromStaking` 为 `onlyGTOKEN_STAKING`，`getEffectiveStake` 以 Staking 为权威源，缓存无法虚增有效质押。
- **UUPS**：Registry/SuperPaymaster `_authorizeUpgrade` onlyOwner、`initializer`、构造器 `_disableInitializers()`；immutable 存于 impl 字节码。
- **重入**：SP validate/postOp/deposit/withdraw 均 `nonReentrant`；V4 `withdraw` 遵循 CEI；PaymasterFactory CEI 已修。
- **Oracle**：SP `updatePrice` 校验上下界/staleness/`answeredInRound>=roundId`；`updatePriceDVT` 有严格递增 replay、过去 2h、未来时间戳(P0-16)守卫。
- **Replay**：`_settledDebtOps[userOpHash]` postOp 幂等；EIP-3009 nonce 绑 `to+maxFee`；`receiveWithAuthorization` 挡 nonce-burn 抢跑；channel `closedChannels` 挡同盐 replay。
- **BLS**：配对方程 `e(G,sig)·e(-pkAgg,H(m))==1` 正确；G1 on-curve + 素数子群 + 非零点校验；`pkAgg`/`msgG2` 链上重构(P0-1) 挡伪造；PoP 挡 rogue-key。
- **MySBT**：`_update` override 在 `from!=0 && to!=0` 时 revert，真正 soulbound；铸/烧/停用均 Registry-gated。
- **EIP-3009 / ecrecover**：`GTokenAuthorization` 严格 CEI，`ECDSA.tryRecover` 校验 `err==NoError && recovered==from`，闭合零地址 bug。
- **GToken**：`ERC20Capped` 保证瞬时 ≤21M（注意：burn 后可再铸，**累计发行量无上限**，非 bug 但集成方勿把 21M 当终身上限）。

---

## 六、修复优先级建议

| 优先级 | 项 | 动作 | 预估 |
|---|---|---|---|
| **P0 — GA 前必修** | H-1 | slash 入口自行复验 BLS 门槛 + executeProposal 加 allowlist | 半天 |
| **P0 — GA 前必修** | H-2 | 紧急阀/限额守卫改为按 `msg.sender != SP` 判断 | 30 分钟 |
| **P0 — GA 前必修** | H-3 | validate 中 `maxCost > maxGasCostCap` 直接拒绝 op | 30 分钟 |
| **P1 — 主网前** | M-1 | `_previewExitFee` 有效 fee 封顶 20% | 30 分钟 |
| **P1 — 主网前** | M-2 | `updateSBTStatus` 改低层 call + 事件 | 30 分钟 |
| **P1 — 主网前** | M-4 | operator 退款缓冲与协议 fee 分池 | 半天 |
| **P2** | M-3, M-5, M-6 | 信用聚合/门槛提升+证据哈希/实收记账 | 各半天 |
| **P3** | L-1 ~ L-14 | 按表逐项，多为文档化或小改 | 1-2 天 |

**建议**：H-1/H-2/H-3 修复后，补对应 Foundry 回归用例（尤其 H-1 的"3 签名不能 slash"负向测试、H-2 的"emergencyDisabled 后 facilitator 拉款必 revert"、H-3 的"maxCost 超 cap 拒绝"），并复跑 5 条不变量与 E2E。所有改动须走 PR，`forge test` 全绿后再推。

---

*报告生成：2026-07-03。方法：5 Agent 并行审计 + 主控逐条源码对抗验证。下一步建议：修 P0 后可用 Codex/Copilot 做二次复核。*
