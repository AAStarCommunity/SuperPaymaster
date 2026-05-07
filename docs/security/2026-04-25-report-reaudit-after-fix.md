# SuperPaymaster Re-Audit Status — 2026-05-07

**Base audit**: `docs/security/2026-04-25-review.md` (branch `security/audit-2026-04-25`)
**Re-audit date**: 2026-05-07
**Scope**: All P0 (21 items) + P1 (42 items) findings cross-referenced against open PRs #122–131 and live contract code

---

## 评级标准

| 严重度 | 含义 | 上主网前 |
|--------|------|---------|
| Critical (P0) | 资金可盗 / 治理被夺 / 服务永久不可用 | 必修 |
| High (P1) | 资金/状态可被特定角色操纵 | 必修 |
| Medium (P2) | 经济偏离 / 边界处理不全 | 应修 |

---

## PR 覆盖速览

| PR | 分支 | 覆盖的 Finding | 状态 |
|----|------|---------------|------|
| #122 | fix/p1-sp-counter-move | P1-6 (totalTxSponsored++) | OPEN |
| #123 | fix/p2-mpc-defensive | P2-MPC self-channel/timer | OPEN |
| #124 | fix/p1-sp-guarded-functions | P1-4, P1-5, P1-39; delete dead agent-policy code | OPEN |
| #125 | fix/p2-registry-cleanup-deprecated | P2 Registry deprecated slot | OPEN |
| #126 | fix/p1p2-v4-paymasterbase | P1-34 (V4 answeredInRound), B5-N2 dead code | OPEN |
| #127 | fix/p2-xpnts-renounce-cleanup | B4-N2 renounceFactory, P1-34 updatedAt staleness | OPEN |
| #128 | fix/p1-registry-exit-cleanup | P1-32 exitRole DVT/ANODE/KMS cleanup | OPEN |
| #129 | fix/p2-bls-constructor-guards | P2-B6N3 BLSAggregator constructor + admin setters, ERC-7562 setAgentRegistries | OPEN |
| #130 | fix/p1-sp-chainlink-v3 | P1-34 SP answeredInRound | OPEN |
| #131 | fix/p0-14-slash-governance | P0-14 (slash cap+cooldown), P0-3 (BLSAgg timelock), setAgentRegistries code.length | OPEN |

---

## P0 完整状态表（21项）

| ID | 描述 | 状态 | 证据 |
|----|------|------|------|
| P0-1 | BLS PK cross-validation — pkG1Bytes 未与注册表比对，可伪造签名 | ❌ 未修 | 架构设计缺陷，需要引入 PK Registry |
| P0-2 | DVT validator stake-gate — addValidator 只检查注册时 role，不检查持续 stake | ⚠️ 部分 | `_requireActiveValidator` 已加到 createProposal/executeWithProof，但 addValidator 本身无 stake 门槛 |
| P0-3 | BLSAggregator 治理单点 — 即时更换无延迟 | ✅ 已修 | PR #131 `queueBLSAggregator` 24h timelock |
| P0-4 | Blacklist BLS check — 空 proof 绕过 BLS 验证 | ⚠️ 部分 | `p.exists` 检查已加；但 BLS 消息无 chainid 绑定（见 P0-21） |
| P0-5 | executeWithProof 无 caller 鉴权 | ✅ 已修 | `onlyAuthorizedExecutor` modifier 已加 |
| P0-6 | V4→V3 Registry 接口断裂 (deactivate 不存在) | ✅ 已修 | 重新设计为本地 `paused` flag，不调 Registry.deactivate |
| P0-7 | PaymasterBase emergency pause 死代码（paused 有变量无 setter） | ✅ 已修 | `pause()` / `unpause()` 函数存在，PaymasterBase.sol:667 |
| P0-8 | emergencyRevokePaymaster 未清除 SUPERPAYMASTER_ADDRESS | ✅ 已修 | `emergencyDisabled` flag 在 burn 路径最前面拦截；rotation + `unsetEmergencyDisabled` 要求新地址 |
| P0-9 | burn() 允许 auto-approved spender 任意销毁用户代币 | ✅ 已修 | destination 限制（self/SP）+ MAX_SINGLE_TX_LIMIT + `_checkAndConsumeRateLimit` 日限额 |
| P0-10 | setAPNTsToken 无 timelock / balance 前置检查 — 中途切换冻结资金 | ❌ 未修 | 代码中只有 `pendingAPNTsTokenEta` timelock 框架，但切换前无 `totalTrackedBalance == 0` 检查 |
| P0-11 | updatePriceDVT break-glass — Chainlink 宕机时跳过偏差检查 | ⚠️ 部分 | 偏差检查在 Chainlink 新鲜时有效；Chainlink 宕机 > 2h 则无偏差限制（设计决策，但 P1-42 有 div-by-zero 风险） |
| P0-12 | 三处 price setter 缺 bounds | ⚠️ 部分 | SP.setAPNTSPrice：MIN/MAX/DELTA ✅；**xPNTsFactory.updateAPNTsPrice：仅 !=0，无 MIN/MAX/DELTA** ❌ |
| P0-13 | settleX402PaymentDirect 无 payer 授权签名 | ✅ 已修 | xPNTs-only gate + community `approvedFacilitators` 白名单 + composite nonce |
| P0-14 | slashOperator 无 cap — owner 可单笔清空 operator 余额 | ✅ 已修 | PR #131：30% hardcap + 24h cooldown |
| P0-15 | _applyAgentSponsorship 死代码，agent 折扣从未生效 | ✅ 已修 | PR #124 删除整个 agent-policy 系统（产品决策） |
| P0-16 | x402SettlementNonces 全局命名空间冲突 | ✅ 已修 | `x402NonceKey(asset, from, nonce)` 三元组 key，兼容旧格式检查 |
| P0-17 | Registry.roleStakes 与 Staking slash 后不同步 | ✅ 已修 | `syncStakeFromStaking()` + `getEffectiveStake()` 双路，文档说明最多 1 块滞后 |
| P0-18 | 6 条 sigFailure 路径无法诊断 | ✅ 已修 | `dryRunValidation()` 加在 SP:1090，返回 8 个错误码 |
| P0-19 | 缓存未来时间戳 → staleness 检查下溢 | ✅ 已修 | PR #127：updatePrice 加 `updatedAt > block.timestamp` guard；setCachedPrice 已有 |
| P0-20 | createProposal 未重置 executed 标志 — 预投毒攻击 | ✅ 已修 | DVTValidator.sol:189 `p.executed = false` 显式重置 |
| P0-21 | BLS 消息无 chainid / nonce — 跨链 replay | ❌ 未修 | BLS 消息构造未绑定 chain.id，同 proof 可跨链重放 |

**P0 汇总：已修 15 / 部分 3 / 未修 3**

---

## P0 未修项详解

### P0-1 — BLS PK Cross-Validation（未修）

**问题**：BLSValidator.verifyProof 和 BLSAggregator._checkSignatures 接受调用方提供的 `pkG1Bytes`，仅验证消息绑定，不验证公钥是否来自 on-chain Registry。攻击者可提交合法消息 + 任意 BLS 公钥通过验证。

**风险**：Critical — 任意 slash / reputation 操作可被伪造

**修复成本**：Large（1-2天）— 需要在 Registry/DVTValidator 维护 BLS PK 注册映射，验证时 `pkG1Bytes` 必须匹配 `registeredPK[validator]`

**效果**：彻底关闭 BLS 签名伪造攻击面

**建议**：主网前必修；当前 DVT 功能未上线，可与 DVT launch 捆绑

---

### P0-10 — setAPNTsToken 无 balance 前置检查（未修）

**问题**：`pendingAPNTsToken` timelock 已存在，但切换执行前未检查 `config.aPNTsBalance == 0 && protocolRevenue == 0`。切换中途 operator 余额以旧 token 记账，换完后旧 token withdraw 用新 token 路径 → 资金冻结。

**风险**：High — owner 操作失误可冻结 operator 资金

**修复成本**：Small（< 30分钟）— 在 `applyAPNTsToken` 里加一行 require

**效果**：防止资金冻结；强迫先清账再换 token

**建议**：主网前必修，极低成本

```solidity
// In applyAPNTsToken():
uint256 totalTracked = _totalOperatorAPNTs();
if (totalTracked > 0 || protocolRevenue > 0) revert PendingBalanceExists();
```

---

### P0-12 (partial) — xPNTsFactory.updateAPNTsPrice 缺 bounds（未修）

**问题**：`updateAPNTsPrice(newPrice)` 只检查 `newPrice != 0`，无 MIN/MAX 绝对限制，无 ±% delta 限制。owner 可将价格设到任意值，破坏所有 xPNTs 计算。

**风险**：High — SP `setAPNTSPrice` 已有 bounds 但 Factory 侧无防护，两者不同步可导致套利

**修复成本**：Small（30分钟）— 对齐 SP 侧的 `APNTS_PRICE_MIN/MAX/DELTA_BPS` 模式

**效果**：防止价格操纵；工厂与 SP 价格一致性保障

---

### P0-21 — BLS 消息无 chainid / nonce（未修）

**问题**：BLSAggregator 构建的消息哈希未包含 `block.chainid`，同一组 DVT 签名可在不同链上重放执行。

**风险**：High — 测试网签名可攻击主网（若合约地址相同）；链分叉后 replay

**修复成本**：Medium（2-3小时）— 在消息构造里加入 `chainid + contractAddress` 绑定

**效果**：关闭跨链 replay；链分叉安全

---

## P1 完整状态表（关键项）

| ID | 描述 | 状态 | 备注 |
|----|------|------|------|
| P1-1 | Operator 无 per-user 黑名单（DoS 防护缺失） | ❌ 未修 | 设计层；`isBlocked` 仅全局 |
| P1-2 | withdrawProtocolRevenue 无 reservation — validate 和 withdraw 竞争 | ❌ 未修 | High |
| P1-4 | configureOperator xpntsFactory 前置检查 | ✅ PR #124 | |
| P1-5 | retryPendingDebt 无鉴权 | ✅ PR #124 | |
| P1-6 | totalTxSponsored++ 在 validate 被 simulation 膨胀 | ✅ PR #122 | |
| P1-8 | Agent NFT check 过宽（任意 ERC-721 通过） | ❌ 未修 | Medium |
| P1-9/10 | agent-policy 系统（agentPolicies 等） | ✅ PR #124 删除 | 整体删除 |
| P1-11 | setAgentRegistries 无 timelock | ⚠️ 部分 | PR #129/131 加了 code.length；无 24h delay |
| P1-12 | renounceFactory 未清 autoApprovedSpenders | ✅ PR #127 | |
| P1-13 | MPC authorizedSigner 不可轮换 | ❌ 未修 | Low |
| P1-14 | updateExchangeRate 无限制（xPNTs 率操纵） | ❌ 未修 | Medium |
| P1-17 | recordDebt 不幂等（opHash 无去重） | ❌ 未修 | Medium |
| P1-20 | priceStalenessThreshold 无 range [60,86400] | ✅ 已修 | PaymasterBase:652 已有检查 |
| P1-27 | syncToRegistry 无鉴权 + epoch 无单调性 | ❌ 未修 | Medium |
| P1-32 | exitRole 未清理 DVT/ANODE/KMS 状态 | ✅ PR #128 | |
| P1-34 | Chainlink answeredInRound 缺失 | ✅ PRs #126 #130 | |
| P1-36 | Oracle 过期导致 validUntil 在过去，难以诊断 | ❌ 未修 | Low |
| P1-39 | getEffectiveFacilitatorFee view 缺失 | ✅ PR #124 | |
| P1-41 | GTokenStaking.setRoleExitFee 绕过 Registry 20% cap | ❌ 未修 | Medium |
| P1-42 | updatePriceDVT：chainlinkPrice == 0 时 division by zero | ❌ 未修 | Small fix |

**P1 汇总：已修 10 / 部分 1 / 未修 9**

---

## P1 未修关键项详解

### P1-2 — withdrawProtocolRevenue 竞争（风险最高 P1）

**问题**：validate 阶段乐观累计 `protocolRevenue += aPNTsAmount`；owner 调 `withdrawProtocolRevenue` 后若 postOp refund 超过剩余 `protocolRevenue`，clamp 逻辑触发 `ProtocolRevenueUnderflow` event，operator 吸收损失。

**风险**：Medium — 不是盗窃，但破坏 operator 计账公平性

**修复成本**：Medium — 引入 `pendingRevenue` 分离已确认和待确认的 revenue

**建议**：上主网后第一版修复

---

### P1-8 — Agent NFT 检查过宽

**问题**：`isRegisteredAgent(account)` 调用 `agentIdentityRegistry.balanceOf(account) > 0`。任何 ERC-721 的持有者（包括普通 NFT）均可获得 agent 赞助。

**风险**：Medium — 赞助资格被滥用；operator 损失 aPNTs

**修复成本**：Medium — 改用特定 token ID 白名单，或引入 `isRegisteredAgent(address, uint256 tokenId)` schema

**建议**：上主网前若 agent 功能启用则必修

---

### P1-14 — updateExchangeRate 无限制

**问题**：xPNTs `updateExchangeRate(newRate)` 无 delta 限制，社区 owner 可将汇率设为任意值，影响 `postOp` 中 xPNTs debt 计算。

**风险**：Medium — 社区层 rugpull；用户被要求偿还不合理债务

**修复成本**：Small — 加 ±30% per-tx delta 限制（对齐 setCachedPrice 模式）

---

### P1-42 — updatePriceDVT div-by-zero（最易修）

**问题**：`updatePriceDVT` 在 Chainlink 数据新鲜时做偏差计算：`(price - chainlinkPrice) * 100 / chainlinkPrice`。若 `chainlinkPrice <= 0`，division by zero revert，DVT 价格更新永久失败。

**风险**：Low-Medium — Chainlink 返回 0（极端情况）会 brick DVT price update path

**修复成本**：Tiny（< 5行）— 加 `if (chainlinkPrice <= 0) { skip deviation check; }`

**建议**：顺手修，成本极低

---

### P1-41 — GTokenStaking.setRoleExitFee 绕过 Registry cap

**问题**：Registry 规定各角色 exit fee ≤ 20%，但 `GTokenStaking.setRoleExitFee` 由 staking owner 直接调用，不经过 Registry 限制检查。

**风险**：Medium — staking owner 设超高 exit fee → operator 无法退出

**修复成本**：Medium — 在 setRoleExitFee 加 `require(fee <= MAX_EXIT_FEE_BPS)` 与 Registry 对齐

---

## 总体评估

| 类别 | 总数 | 已修 | 部分 | 未修 |
|------|------|------|------|------|
| P0 (Critical) | 21 | 15 | 3 | **3** |
| P1 (High) | 42 | ~18 | 1 | **9** |

**P0 未修的 3 项** (P0-1 BLS PK, P0-10 APNTs token switch, P0-21 BLS chainid)：
- P0-1：DVT 功能上线前必修，架构级改造
- P0-10：极低成本 1 行 require，建议随 PR #131 一并修掉
- P0-21：DVT 功能上线前必修，chainid 绑定
- P0-12 partial (xPNTsFactory price bounds)：Small fix，应补上

**P1 未修的高优先级** (建议主网前处理)：
- P1-42：div-by-zero，tiny fix，立即修
- P1-14：updateExchangeRate delta 限制，Small
- P1-41：GTokenStaking exit fee cap bypass，Medium
- P1-2：protocolRevenue 竞争，Medium，可推迟到主网后第一版

**可推迟到主网后**：P1-1, P1-8, P1-11, P1-13, P1-27, P1-36

---

## 推荐修复顺序

```
立即（< 1天）:
  P1-42  updatePriceDVT chainlinkPrice <= 0 guard  [~5行]
  P0-10  applyAPNTsToken balance 前置 require       [~5行]
  P0-12p xPNTsFactory.updateAPNTsPrice MIN/MAX      [~10行]

短期（1-3天）:
  P0-21  BLS 消息加 chainid + nonce 绑定            [Medium]
  P1-14  updateExchangeRate ±delta 限制              [Small]
  P1-41  setRoleExitFee 对齐 Registry cap            [Small]

中期（DVT 上线前）:
  P0-1   BLS PK Registry 注册 + 验证时比对           [Large]
  P1-2   protocolRevenue reservation 机制            [Medium]
  P1-8   Agent NFT 检查收紧（tokenId schema）        [Medium]
```
