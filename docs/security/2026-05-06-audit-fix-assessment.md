# SuperPaymaster 审计修复全面评估报告

**日期**: 2026-05-06  
**审计基线**: [`docs/security/2026-04-25-review.md`](./2026-04-25-review.md)（security/audit-2026-04-25 分支）  
**评估范围**: P0（18+3 项）、P1（32 项）、P2（~70 项）审计发现，对应 PR #99–#130  
**评估人**: Claude Code (Tier 3 本地) + Codex CLI review (PR #122/123/124)

---

## 1. Codex Review 状态汇总

| PR | 分支 | Codex 审核 | 发现问题 | 处理结果 |
|---|---|---|---|---|
| **#122** | fix/p1-sp-counter-move | ✅ 已 review | 无重大问题 | 直接通过 |
| **#123** | fix/p2-mpc-defensive | ✅ 已 review | ⚠️ Medium: `catch (bytes memory reason)` 在 postOp 中内存开销大 | ✅ 已修 → `event PriceUpdateFailed()` 无参 + `catch {}` |
| **#124** | fix/p1-sp-guarded-functions | ✅ 已 review | ⚠️ Critical(误): UUPS 中间存储槽被删→slot 下移 | ✅ 已决策 → 全新部署场景，直接删除（无升级兼容需求） |
| **#125** | fix/p2-registry-cleanup-deprecated | ❌ 未 Codex review | — | Codex stop gate 曾触发警告（Registry 中间槽）；用户确认新部署场景后继续 |
| **#126** | fix/p1p2-v4-paymasterbase | ❌ 未 Codex review | — | — |
| **#127** | fix/p2-xpnts-renounce-cleanup | ❌ 未 Codex review | — | — |
| **#128** | fix/p1-registry-exit-cleanup | ❌ 未 Codex review | — | — |
| **#129** | fix/p2-bls-constructor-guards | ❌ 未 Codex review | — | — |
| **#130** | fix/p1-sp-chainlink-v3 | ❌ 未 Codex review | — | — |

> **建议**: PR #125–130 在合并前应补跑 Codex review。可用 `/codex:rescue` 批量送审。

---

## 2. P0 — 主网前必修（18 原始 + 3 Codex 新增 = 19–21 项）

### 2.1 已完全修复（通过已合并 PR）

| P0# | 审计 ID | 问题简述 | 修复 PR | 状态 |
|---|---|---|---|---|
| P0-1 | B6-C1a | BLS PK 未从链上重建，可伪造 DVT 共识 | #112 | ✅ merged |
| P0-2 | B6-C1b | DVT validator 集合无 stake-gate | #105 | ✅ merged |
| P0-4 | B6-C2 | updateOperatorBlacklist 空 proof 跳过 BLS 校验 | #113 | ✅ merged |
| P0-5 | B6-H1 | executeWithProof 无鉴权 | #104 | ✅ merged |
| P0-6 | B5-H1 | V4 deactivate/activate 调用 V3 Registry 接口失败 | #100 | ✅ merged |
| P0-7 | B5-H2 | V4 pause 是死码 | #99 | ✅ merged |
| P0-8 | B4-H1 | emergencyRevokePaymaster 未清 SUPERPAYMASTER_ADDRESS | #101 | ✅ merged |
| P0-9 | B4-H2 | `burn(address,uint256)` 绕过 firewall；autoApproved spender 可随意销毁用户余额 | main 直推 (commit 4236935) | ✅ merged |
| P0-10 | B2-N1 | setAPNTsToken 可任意切换，freezing 全合约 | #108 | ✅ merged |
| P0-11 | B2-N2+P3-H2 | updatePriceDVT break-glass 无偏离限制 | #115 | ✅ merged |
| P0-12a | B2-N3(部分) | x402 Direct settle 接受任意 ERC20 | #109 | ✅ merged |
| P0-12b | B2-N3(部分) | Facilitator 无白名单 | #110 | ✅ merged |
| P0-12c | B2-N3+P3-H1 | aPNTsPriceUSD/setCachedPrice/V4 price setter 无上下限 | #114 | ✅ merged |
| P0-13 | B2-N4+B3-N2 | x402 nonce 全局 namespace → DoS / 跨合约重放 | #106 | ✅ merged |
| P0-16 | B3-N3+B2-N8 | updatePriceDVT future-timestamp 可操控价格 | #107 | ✅ merged |
| P0-17 | H-01 | slash 后 Registry.roleStakes 与 Staking 锁仓量发散 | #111 | ✅ merged |
| P0-18 | J2-BLOCKER | 6 处 silent sigFailure，bundler/前端无法诊断 | #102 | ✅ merged |
| P0-15 | B3-N1 | _applyAgentSponsorship 死代码（Codex 降为 P1 产品决策） | #124 | 🔴 open (待合并) |

### 2.2 Codex 新增 P0（19–21）

| P0# | 审计 ID | 问题简述 | 修复 PR | 状态 |
|---|---|---|---|---|
| P0-19 | B-N1 future-ts | future-timestamp 已并入 P0-16 | #107 | ✅ merged |
| P0-20 | B-N5 proposalId pre-poison | DVT proposal pre-poison；并入 P0-4 | #104 | ✅ merged |
| P0-21 | — | （见 §6.C，与 D1/D5-bis 决策绑定） | — | — |

### 2.3 ⚠️ 尚未修复的 P0

| P0# | 审计 ID | 问题简述 | 原因 / 当前决策 |
|---|---|---|---|
| **P0-3** | B6-C1c | Slash 路径单点依赖 BLS，治理无法自救 | Codex 将其**降级为 P1**，pending D5-bis 决策（owner 多签 + timelock vs Optimistic Governance Slash）。当前有 `slashOperator` onlyOwner 路径可作替代，但无 timelock。 |
| **P0-14** | B2-N6 | `slashOperator(onlyOwner)` 无 30% cap 也无 timelock，owner 可全额 slash 任意 operator | Codex 修订为"加 timelock/challenge window"，但**至今无 PR**。当前代码注释为"Owner slash: no 30% hardcap"。 |

**结论**: 18 原始 P0 中，**16 已通过 PR 合并修复**，1 项在 open PR 中（#124），**2 项（P0-3 + P0-14）无 PR，为当前最大残余风险**。

---

## 3. P1 — 主网前应修（32 项）

### 3.1 已通过 open PR 修复（待合并）

| P1# | 审计 ID | 问题简述 | PR | 状态 |
|---|---|---|---|---|
| P1-4 | B2-N10 | configureOperator 在 xpntsFactory=0 时跳过校验 | #124 | 🔴 open |
| P1-5 | B2-N12 | retryPendingDebt 无 auth | #124 | 🔴 open |
| P1-6 | B2-N15 | totalTxSponsored++ 在 validate simulation 中也计 | #122 | 🔴 open |
| P1-18 | B5-M1 | setCachedPrice 无 bounds（并入 P0-12） | #114 | ✅ merged |
| P1-29 | B1-N2 | blacklist 条件性 BLS（并入 P0-4） | #113 | ✅ merged |
| P1-32 | M-01 | exitRole 仅清理 COMMUNITY/ENDUSER，DVT/ANODE/KMS 状态残留 | #128 | 🔴 open |
| P1-34 | P3-H3 | Chainlink answeredInRound >= roundId 校验缺失 | #126 (V4) + #130 (SP) | 🔴 open |
| P1-39 | J4-MAJOR-6 | 无 getEffectiveFacilitatorFee(operator) view | #124 | 🔴 open |

### 3.2 因删除死代码而关闭（P1-9/10 merged into PR #124）

- **P1-9** (B3-N6: setAgentPolicies 无 cap)：整个 F1 agent policy 代码在 PR #124 中删除
- **P1-10** (B3-N9: _resolveAgentPolicy 昂贵外部调用)：同上，代码已删

### 3.3 ⚠️ 未覆盖的 P1 项（~22 项）

| P1# | 审计 ID | 问题简述 | 备注 |
|---|---|---|---|
| P1-1 | B2-N5 | Operator 无 per-user 拦截能力，恶意 eligible user 可 DoS | 无 PR |
| P1-2 | B2-N7 | withdrawProtocolRevenue 无 reservation，可在 validate/postOp 间清空 | 无 PR |
| P1-3 | B2-N9 | 5 处 silent reject，监控/UX 受影响（P0-18 dryRun 部分缓解） | 无 PR（部分 P0-18 缓解） |
| P1-7 | B3-N4 | _submitSponsorshipFeedback 反映 gas 而非 agent task | 无 PR |
| P1-8 | B3-N5 | Agent NFT 只验证 balanceOf>0，任意 ERC721 通过 | 无 PR |
| P1-11 | B3-N11 | setAgentRegistries 无 timelock | 无 PR |
| P1-12 | B4-M1 | Factory setSuperPaymasterAddress 不传播到已部署 token | 无 PR |
| P1-13 | B4-M3 | MPC authorizedSigner 不可中途轮换 | 无 PR |
| P1-14 | B4-M4 | updateExchangeRate 无限速，飞行中改影响用户 | 无 PR |
| P1-15 | B4-M5+M-03 | CLOSE_TIMEOUT=900s 硬编码（L2 建议 ≥1d） | 无 PR |
| P1-16 | B4-M6+M-04 | MAX_SINGLE_TX_LIMIT 硬编码 5000 ether | 无 PR |
| P1-17 | B4-M7 | recordDebt 无幂等（同一 opHash 可重复记债） | 无 PR |
| P1-19 | B5-M2 | V4 治理关键参数无 timelock | 无 PR（#126 部分清理） |
| P1-20 | B5-M3 | priceStalenessThreshold 无 [60,86400] 范围校验 | 无 PR |
| P1-21 | B5-M4 | operator→paymaster 单向永久绑定，无 releaseSlot | 无 PR |
| P1-22 | B5-M5 | PaymasterFactory arbitrary calldata 后置验证脆弱 | 无 PR |
| P1-23 | B6-M1 | slash 与 reputation 使用同一 proof namespace | 无 PR |
| P1-24 | B6-M2 | BLS 阈值 setter 无 timelock，无下限 | 无 PR |
| P1-25 | B6-M3 | 无 removeValidator 路径 | 无 PR |
| P1-26 | B6-M4 | reputation threshold 静默 fallback=3 | 无 PR |
| P1-27 | B6-M5 | syncToRegistry 任意 EOA 可调 | 无 PR |
| P1-28 | B1-N1 | setStaking 不自动 syncExitFees（注：MEMORY.md 记录已内嵌，需再验） | 无 PR |
| P1-30 | B1-N3 | setStaking 不迁移旧锁仓，旧 Staking 可遗孤 | 无 PR |
| P1-31 | B1-N5 | MySBT.recordActivity 仅 _isValid(msg.sender)，未限 onlyRegistry | 无 PR |
| P1-33 | M-02 | sbtHolders 命名错位（实为所有角色 holder 都获 sponsorship） | 无 PR（产品决策） |
| P1-35 | P3-H4 | recordDebt 累积无 TTL/per-user cap | 无 PR |
| P1-37 | J2-MAJOR-4 | sbtHolders 与 MySBT 状态可能解耦（INV-09） | 无 PR |

---

## 4. P2 — 上主网后 1-2 迭代修复

### 4.1 已通过 open PR 修复

| 问题 | PR | 状态 |
|---|---|---|
| MPC self-channel 防御 + requestClose timer reset | #123 | 🔴 open |
| renounceFactory 未撤销旧 factory autoApprovedSpender | #127 | 🔴 open |
| Registry deprecated __blsValidator slot 清理 | #125 | 🔴 open |
| PaymasterBase dead code 删除 (getRealtimeTokenCost) | #126 | 🔴 open |
| BLSAggregator constructor 零地址校验 | #129 | 🔴 open |

### 4.2 未覆盖 P2 项（~65 项）

大量 P2 项涉及：event 完善、bounds 校验、注释清理、工具函数（treasury 迁移工具、removeValidator 等）、ReputationSystem 优化、PaymasterFactory 改进等。这些不是主网阻塞项，但应在 1-2 个版本内处理。

---

## 5. PR 依赖关系图

```
main
├── #99  fix/p0-6-v4-pause            ✅ merged     [独立]
├── #100 fix/p0-5-v4-deactivate       ✅ merged     [独立]
├── #101 fix/p0-7-xpnts-emergency     ✅ merged     [独立]
├── #102 fix/p0-15-dryrun-validation  ✅ merged     [独立]
├── #104 fix/p0-4-and-17-dvt-defense  ✅ merged     [独立]
├── #105 fix/p0-2-validator-stake-gate ✅ merged    [独立]
├── #106 fix/p0-13-x402-nonce-triple  ✅ merged     [独立]
├── #107 fix/p0-16-future-timestamp   ✅ merged     [独立]
├── #108 fix/p0-9-apnts-token-timelock ✅ merged   [独立]
├── #109 fix/p0-12a-x402-asset-whitelist ✅ merged [独立]
├── #110 fix/p0-12b-facilitator-whitelist ✅ merged [独立]
├── #111 fix/p0-14-slash-sync         ✅ merged     [独立]
├── #112 fix/p0-1-bls-rewrite         ✅ merged     [独立]
├── #113 fix/p0-3-blacklist-hardening ✅ merged     [独立]
├── #114 fix/p0-11-price-setter-bounds ✅ merged    [独立]
├── #115 fix/p0-10-breakglass         ✅ merged     [独立]
├── #118 fix/eip170-hotfix            ✅ merged     [独立]
│
├── #122 fix/p1-sp-counter-move       🔴 open      [独立, base: main]
├── #123 fix/p2-mpc-defensive         🔴 open      [独立, base: main]
│
├── #124 fix/p1-sp-guarded-functions  🔴 open      [独立, base: main] ← 关键
│   └── #130 fix/p1-sp-chainlink-v3  🔴 open      [⚠️ 依赖 #124, base: fix/p1-sp-guarded-functions]
│
├── #125 fix/p2-registry-cleanup-deprecated 🔴 open [独立, base: main]
├── #126 fix/p1p2-v4-paymasterbase    🔴 open      [独立, base: main]
├── #127 fix/p2-xpnts-renounce-cleanup 🔴 open    [独立, base: main]
├── #128 fix/p1-registry-exit-cleanup 🔴 open     [独立, base: main]
└── #129 fix/p2-bls-constructor-guards 🔴 open    [独立, base: main]
```

**唯一依赖关系**: PR #130 必须在 PR #124 合并后才能合并（base 是 fix/p1-sp-guarded-functions 而非 main）。建议合并 #124 后立即 rebase #130 到 main。

**推荐合并顺序**:
1. #122, #123, #125, #126, #127, #128, #129（全部独立，可并行）
2. #124（合并后 #130 的 base 自动变为 main，可直接合并）
3. #130

---

## 6. 残余风险评估

### 6.1 主网阻塞残余风险（P0 级）

| 风险 | 严重度 | 当前缓解 | 推荐行动 |
|---|---|---|---|
| **P0-14**: `slashOperator(onlyOwner)` 无 timelock，owner 可不经挑战期全额 slash operator | High | owner 为 multisig（降低单点风险）；社区可 exit 减少损失 | 在 main 上加 48h timelock + 最大 30% per-tx cap；或决策采用 multisig ≡ 终极治理（见 D5-bis） |
| **P0-3**: slash 路径与 BLS 共 single-point，治理自救能力弱 | Medium（post C1a 修复后降级） | P0-1 已重建 PK 路径；P0-5 加了 executeWithProof 鉴权；owner 路径补位 | D5-bis 决策后处理：选 multisig + timelock 即可降为 P1 |

### 6.2 主网前应修残余风险（P1 级，已有 open PR）

PRs #122/124/126/128/130 合并后，将关闭 P1-4/5/6/32/34/39 共 7 项。

### 6.3 主网前应修残余风险（P1 级，无 PR）

以下是**影响最大**且尚无 PR 的 P1 项：

| 优先级 | P1# | 问题 | 推荐 |
|---|---|---|---|
| 🔴 高 | P1-8 | Agent NFT 仅 balanceOf>0，任意 ERC721 骗过资格验证 | 加 Registry 侧 whitelist 或 tokenId schema |
| 🔴 高 | P1-2 | withdrawProtocolRevenue 无 reservation buffer，可竞态清空 | 引入 10% 缓冲区或 24h delay |
| 🟡 中 | P1-17 | recordDebt 无幂等，同 opHash 可重复记债 | 加 `mapping(bytes32 => bool) debtNonces` |
| 🟡 中 | P1-35 | recordDebt 累积无上限/TTL | per-user 债务上限 + TTL 清理 |
| 🟡 中 | P1-27 | syncToRegistry 任意 EOA 可调 | 限定 onlyBLSAggregator 或 onlyOwner |
| 🟡 中 | P1-14 | updateExchangeRate 无限速 | ±20%/24h rolling cap |

### 6.4 整体风险评分

| 维度 | 修复前 | 当前（PRs 合并后） |
|---|---|---|
| CRITICAL 项 | 4 | 0（P0-1 BLS PK 重建已彻底修复） |
| P0 未修复 | 18 | 2（P0-3 降级中, P0-14 无 PR） |
| P1 未修复 | 32 | ~22（10 项已有 PR 或合并） |
| EIP-170 违规 | 是（1,590B 超限） | 否（PR #118 修复） |

---

## 7. 行动清单

### 立即（主网部署前）

- [ ] **提 PR for P0-14**: `slashOperator` 加 48h timelock + max 30% per-call cap（或 D5-bis 决策 multisig 替代）
- [ ] **Codex review PR #125–#130**（6 个新 PR 未经 Codex 审核）
- [ ] **合并 PR #124 后**: 将 PR #130 rebase 到 main
- [ ] **决策 D5-bis**: owner multisig = 终极治理 vs Optimistic Governance Slash（影响 P0-3 是否关闭）

### 短期（主网后 1–2 周）

- [ ] P1-8: Agent NFT whitelist/schema 验证
- [ ] P1-2: withdrawProtocolRevenue reservation buffer
- [ ] P1-17: recordDebt 幂等
- [ ] P1-35: recordDebt per-user TTL/cap
- [ ] P1-27: syncToRegistry 权限锁定

### 中期（1–2 迭代）

- [ ] P1-13: MPC authorizedSigner 轮换
- [ ] P1-14: updateExchangeRate 限速
- [ ] P1-24: BLS 阈值 timelock
- [ ] P1-25: removeValidator 路径
- [ ] P2 项全量清理（~65 项）

---

## 8. 附录：审计发现编号→PR 映射表（完整）

| 审计 ID | 问题 | 修复 PR | 合并状态 |
|---|---|---|---|
| B6-C1a | BLS PK 未重建 | #112 | ✅ merged |
| B6-C1b | DVT stake-gate | #105 | ✅ merged |
| B6-C1c | 治理 slash 单点 | 无 PR（P0-3 降级） | ⚠️ 待决策 |
| B6-C2 | blacklist 空 proof | #113 | ✅ merged |
| B6-H1 | executeWithProof 无鉴权 | #104 | ✅ merged |
| B5-H1 | V4 deactivate 接口 | #100 | ✅ merged |
| B5-H2 | V4 pause 死码 | #99 | ✅ merged |
| B4-H1 | emergencyRevoke SP 地址残留 | #101 | ✅ merged |
| B4-H2 | burn() 绕过 + autoApproved 滥权 | main direct (4236935) | ✅ merged |
| B2-N1 | setAPNTsToken 任意切换 | #108 | ✅ merged |
| B2-N2+P3-H2 | break-glass 无偏离限制 | #115 | ✅ merged |
| B2-N3+P3-H1 | 价格 setter 无 bounds | #109 + #110 + #114 | ✅ merged |
| B2-N4+B3-N2 | x402 nonce DoS | #106 | ✅ merged |
| B2-N5 | operator 无 per-user block | 无 PR (P1-1) | ❌ |
| B2-N6 | slashOperator 无 cap/timelock | 无 PR (P0-14) | ❌ |
| B2-N7 | withdrawProtocolRevenue 竞态 | 无 PR (P1-2) | ❌ |
| B2-N8+P0-16 | future-timestamp | #107 | ✅ merged |
| B2-N9+P0-18 | silent sigFailure | #102 | ✅ merged |
| B2-N10 | configureOperator factory | #124 | 🔴 open |
| B2-N12 | retryPendingDebt auth | #124 | 🔴 open |
| B2-N15 | totalTxSponsored++ 时机 | #122 | 🔴 open |
| B3-N1 | agentPolicy 死代码 | #124 | 🔴 open |
| B3-N3+B2-N8 | nonce namespace | #106 | ✅ merged |
| B3-N5 | agent NFT 任意 ERC721 | 无 PR (P1-8) | ❌ |
| B4-M1 | factory 地址不传播 | 无 PR (P1-12) | ❌ |
| B4-M4 | exchangeRate 无限速 | 无 PR (P1-14) | ❌ |
| B4-M5+M-03 | CLOSE_TIMEOUT 硬编码 | 无 PR (P1-15) | ❌ |
| B4-M6+M-04 | MAX_SINGLE_TX_LIMIT 硬编码 | 无 PR (P1-16) | ❌ |
| B4-M7 | recordDebt 无幂等 | 无 PR (P1-17) | ❌ |
| B4-N4 + P2 | renounceFactory 清理 | #127 | 🔴 open |
| B5-M1 | setCachedPrice bounds | #114 | ✅ merged |
| B5-M2 | V4 timelock | 无 PR (P1-19) | ❌ |
| B5-M3 | priceStalenessThreshold range | 无 PR (P1-20) | ❌ |
| B5-M4 | operator→paymaster 永久绑定 | 无 PR (P1-21) | ❌ |
| B5-M5 | Factory calldata 验证 | 无 PR (P1-22) | ❌ |
| B5-dead | getRealtimeTokenCost 死代码 | #126 | 🔴 open |
| B6-M1 | slash+reputation proof namespace | 无 PR (P1-23) | ❌ |
| B6-M2 | BLS threshold timelock | 无 PR (P1-24) | ❌ |
| B6-M3 | removeValidator 缺失 | 无 PR (P1-25) | ❌ |
| B6-M4 | reputation threshold fallback=3 | 无 PR (P1-26) | ❌ |
| B6-M5 | syncToRegistry 权限 | 无 PR (P1-27) | ❌ |
| B6-N2/3 | BLSAggregator constructor | #129 | 🔴 open |
| H-01+B1 | Registry ↔ Staking slash 同步 | #111 | ✅ merged |
| M-01 | exitRole 仅清 COMMUNITY/ENDUSER | #128 | 🔴 open |
| M-02 | sbtHolders 命名错位 | 无 PR (P1-33) | ❌（产品决策） |
| P3-H3 | Chainlink answeredInRound | #126 + #130 | 🔴 open |
| P3-H4 | recordDebt 无上限 | 无 PR (P1-35) | ❌ |
| J2-MAJOR-6 | getEffectiveFacilitatorFee view | #124 | 🔴 open |
| J5-MPC | MPC self-channel + timer reset | #123 | 🔴 open |

---

*本文档基于 2026-04-25 审计报告，映射到截至 2026-05-06 所有安全 PR（#99–#130）的实际状态。*
