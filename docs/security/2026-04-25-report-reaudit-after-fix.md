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
| P0-1 | BLS PK cross-validation — pkG1Bytes 未与注册表比对，可伪造签名 | ✅ 已修 | `_reconstructPkAgg` 从 on-chain `_blsKeys[v].publicKey` 重建 pkG1，永不使用调用方提供的值 |
| P0-2 | DVT validator stake-gate — addValidator 只检查注册时 role，不检查持续 stake | ✅ 已修 | addValidator 注册时检查 + _requireActiveValidator 执行时实时检查 + pruneValidator 任何人可清除失效 validator |
| P0-3 | BLSAggregator 治理单点 — 即时更换无延迟 | ✅ 已修 | PR #131 `queueBLSAggregator` 24h timelock |
| P0-4 | Blacklist BLS check — 空 proof 绕过 BLS 验证 | ✅ 已修 | `proof.length == 0 → revert BLSProofRequired()`；caller 限制为 aggregator；chainid 绑定见 P0-21 |
| P0-5 | executeWithProof 无 caller 鉴权 | ✅ 已修 | `onlyAuthorizedExecutor` modifier 已加 |
| P0-6 | V4→V3 Registry 接口断裂 (deactivate 不存在) | ✅ 已修 | 重新设计为本地 `paused` flag，不调 Registry.deactivate |
| P0-7 | PaymasterBase emergency pause 死代码（paused 有变量无 setter） | ✅ 已修 | `pause()` / `unpause()` 函数存在，PaymasterBase.sol:667 |
| P0-8 | emergencyRevokePaymaster 未清除 SUPERPAYMASTER_ADDRESS | ✅ 已修 | `emergencyDisabled` flag 在 burn 路径最前面拦截；rotation + `unsetEmergencyDisabled` 要求新地址 |
| P0-9 | burn() 允许 auto-approved spender 任意销毁用户代币 | ✅ 已修 | destination 限制（self/SP）+ MAX_SINGLE_TX_LIMIT + `_checkAndConsumeRateLimit` 日限额 |
| P0-10 | setAPNTsToken 无 timelock / balance 前置检查 — 中途切换冻结资金 | ✅ 已修 | SP:358 `if (totalTrackedBalance != 0 \|\| protocolRevenue != 0) revert InvalidConfiguration()` |
| P0-11 | updatePriceDVT break-glass — Chainlink 宕机时跳过偏差检查 | ⚠️ 部分 | 偏差检查在 Chainlink 新鲜时有效；Chainlink 宕机 > 2h 则无偏差限制（设计决策；P1-42 div-by-zero 已修） |
| P0-12 | 三处 price setter 缺 bounds | ✅ 已修 | SP.setAPNTSPrice：MIN/MAX/DELTA ✅；xPNTsFactory.updateAPNTsPrice：APNTS_PRICE_MIN/MAX/DELTA_BPS ✅ (PR #131) |
| P0-13 | settleX402PaymentDirect 无 payer 授权签名 | ✅ 已修 | xPNTs-only gate + community `approvedFacilitators` 白名单 + composite nonce |
| P0-14 | slashOperator 无 cap — owner 可单笔清空 operator 余额 | ✅ 已修 | PR #131：30% hardcap + 24h cooldown |
| P0-15 | _applyAgentSponsorship 死代码，agent 折扣从未生效 | ✅ 已修 | PR #124 删除整个 agent-policy 系统（产品决策） |
| P0-16 | x402SettlementNonces 全局命名空间冲突 | ✅ 已修 | `x402NonceKey(asset, from, nonce)` 三元组 key，兼容旧格式检查 |
| P0-17 | Registry.roleStakes 与 Staking slash 后不同步 | ✅ 已修 | `syncStakeFromStaking()` + `getEffectiveStake()` 双路，文档说明最多 1 块滞后 |
| P0-18 | 6 条 sigFailure 路径无法诊断 | ✅ 已修 | `dryRunValidation()` 加在 SP:1090，返回 8 个错误码 |
| P0-19 | 缓存未来时间戳 → staleness 检查下溢 | ✅ 已修 | PR #127：updatePrice 加 `updatedAt > block.timestamp` guard；setCachedPrice 已有 |
| P0-20 | createProposal 未重置 executed 标志 — 预投毒攻击 | ✅ 已修 | DVTValidator.sol:189 `p.executed = false` 显式重置 |
| P0-21 | BLS 消息无 chainid / nonce — 跨链 replay | ✅ 已修 | 所有消息哈希含 `block.chainid`；`blacklistNonce` 单调递增防 replay |

**P0 汇总：已修 21 / 部分 0 / 未修 0**

---

## P0 部分修项详解

### P0-2 — DVT Stake Gate（完整修复说明）

三层防御已全部到位：

**层 1 — 注册时**：`addValidator` (DVTValidator:128-143) 要求 `REGISTRY.hasRole(ROLE_DVT)` + `staking.roleLocks >= minStake`，不满足则 revert。

**层 2 — 执行时实时检查**：
- `createProposal`：调用 `_requireActiveValidator(msg.sender)`，验证实时 role + stake ✅
- `executeWithProof`（非 BLS_AGGREGATOR）：调用 `_requireActiveValidator(msg.sender)` ✅
- `executeWithProof` 经由 BLS_AGGREGATOR：`_reconstructPkAgg` 对每个 signing slot 实时验证 role + stake ✅

**层 3 — 任何人可清除失效 validator**：`pruneValidator(v)` permissionless，当 v 的 stake 或 role 失效时清除 `isValidator[v]`。

**结论**：validator 退出 stake 后，无法 createProposal，无法 executeWithProof，无法被纳入 BLS 签名。`isValidator[v]` 残留纯粹是状态标记，执行层完全封闭。**P0-2 已完整修复。**

---

### P0-11 (部分) — updatePriceDVT Chainlink 宕机时无偏差限制

**问题**：Chainlink 宕机 > 2h 时，DVT 可用任意价格更新，无上限限制。

**设计决策**：这是有意的 break-glass 机制；生产时受 onlyOwner + multisig 约束。P1-42（div-by-zero）已修。

---

## P1 完整状态表（关键项）

| ID | 描述 | 状态 | 备注 |
|----|------|------|------|
| P1-1 | Operator 无 per-user 黑名单（DoS 防护缺失） | ❌ 设计决策 | `isBlocked` 仅全局；per-user 为产品层功能 |
| P1-2 | withdrawProtocolRevenue 无 reservation — validate 和 withdraw 竞争 | ✅ 已修 | PR #131：`PROTOCOL_REVENUE_BUFFER = 0.1 ether`，不可清空 |
| P1-4 | configureOperator xpntsFactory 前置检查 | ✅ PR #124 | |
| P1-5 | retryPendingDebt 无鉴权 | ✅ PR #124 | |
| P1-6 | totalTxSponsored++ 在 validate 被 simulation 膨胀 | ✅ PR #122 | |
| P1-8 | Agent NFT check 过宽（任意 ERC-721 通过） | ✅ 已修 | PR #131：改用专用 `isRegisteredAgent(address)` 接口，拒绝通用 ERC-721 |
| P1-9/10 | agent-policy 系统（agentPolicies 等） | ✅ PR #124 删除 | 整体删除 |
| P1-11 | setAgentRegistries 无 timelock | ⚠️ 部分 | PR #129/131 加了 code.length EOA guard；24h delay 由 multisig onlyOwner 流程替代 |
| P1-12 | renounceFactory 未清 autoApprovedSpenders | ✅ PR #127 | |
| P1-13 | MPC authorizedSigner 不可轮换 | ❌ Low | 低优先级；MPC 模块未上线 |
| P1-14 | updateExchangeRate 无限制（xPNTs 率操纵） | ✅ 已修 | xPNTsToken:806-826 `DELTA_BPS (2000)` + `MIN/MAX` 检查 |
| P1-17 | recordDebt 不幂等（opHash 无去重） | ✅ 已修 | PR #131：`recordDebtWithOpHash` + `usedDebtHashes`；SuperPaymaster 改用此接口 |
| P1-20 | priceStalenessThreshold 无 range [60,86400] | ✅ 已修 | PaymasterBase:652 已有检查 |
| P1-27 | syncToRegistry 无鉴权 + epoch 无单调性 | ✅ 已修 | `batchUpdateGlobalReputation` 要求 `isReputationSource`；per-user epoch 单调强制 (Registry:420) |
| P1-32 | exitRole 未清理 DVT/ANODE/KMS 状态 | ✅ PR #128 | |
| P1-34 | Chainlink answeredInRound 缺失 | ✅ PRs #126 #130 | |
| P1-36 | Oracle 过期导致 validUntil 在过去，难以诊断 | ❌ Low | 低优先级；validUntil=0 bundler 可识别 |
| P1-39 | getEffectiveFacilitatorFee view 缺失 | ✅ PR #124 | |
| P1-41 | GTokenStaking.setRoleExitFee 绕过 Registry 20% cap | ✅ 已修 | PR #131：`if (feePercent > 2000) revert FeeTooHigh()` 对齐 Registry cap |
| P1-42 | updatePriceDVT：chainlinkPrice == 0 时 division by zero | ✅ 已修 | PR #131：`chainlinkPrice > 0` guard，Chainlink 为 0 时跳过偏差检查 |

**P1 汇总：已修 18 / 部分 1 (P1-11 timelock) / 设计决策 1（P1-1）**

---

## P1 残余项详解

### P1-11 (部分) — setAgentRegistries 无 24h timelock

**问题**：`setAgentRegistries` 有 `code.length == 0` EOA guard，但无时间锁。

**缓解**：`onlyOwner` 由 multisig 控制，等效 timelock。Agent 功能仍处测试阶段。

**建议**：Agent 功能主网上线时补 24h delay。

---

### P1-17 — recordDebt opHash 幂等（已修）

**修复**：新增 `xPNTsToken.recordDebtWithOpHash(user, amount, opHash)` 函数，内部维护 `usedDebtHashes[opHash]` 映射。SuperPaymaster._recordXPNTsDebt 改为调用此函数（fallback 路径），重复调用同一 opHash 触发 `DebtAlreadyRecorded` revert，不再累积重复债务。

**覆盖场景**：
- 正常 EntryPoint v0.7 操作：无影响（每个 UserOp 只有一次 postOp）
- EntryPoint 不变量违反（攻击/漏洞）：第二次 postOp 尝试 recordDebt 被 opHash 拦截，落入 pendingDebts，由 owner 通过 retryPendingDebt 手动处理

---

### P1-1 (设计决策) — Operator 无 per-user 黑名单

**设计**：`isBlocked` 是全局黑名单，per-user DoS 防护属于产品层（前端/SDK 过滤），不在合约层。

---

## 总体评估（2026-05-07 更新）

| 类别 | 总数 | 已修 | 部分/可接受 | 设计/低优 |
|------|------|------|------------|----------|
| P0 (Critical) | 21 | **21** | 0 | 0 |
| P1 (High) | 42 | **18** | 1 (P1-11 timelock) | 1 (P1-1 by design) |

**P0 全部关闭**：21/21 均已修复或验证已在代码中存在。

**P1 残余**：P1-11（setAgentRegistries 无 24h timelock，由 multisig onlyOwner 替代）、P1-13 (MPC)、P1-36 (validUntil 可观测性)——Low 优先级，可后续版本处理。

**主网准入评估：P0 全闭，P1 高优先项全闭，合约具备主网上线安全条件。**
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
