# P0 上线前必修清单（Stage 1）

**日期**: 2026-04-26（V4 决策更新于 2026-04-28）
**分支**: `security/audit-2026-04-25`
**目标**: 1-2 周内完成 P0 修复 → Sepolia 测试 → 1-3 个月 Optimism mainnet 内测 → 公开主网
**关联文档**:
- `docs/security/2026-04-25-review.md` （完整审计，2057 行）
- `docs/security/2026-04-26-decision-records.md` （D1-D8 用户决策）
- `docs/security/2026-04-26-threat-model.md` （信任模型 + 24 条威胁场景）
- `docs/security/2026-04-26-p0-prelaunch.md` （英文版，本文档为对应中文版）

---

## 1. 三档拆分方法论

review.md §5.3 的 18 条 P0 + 32 条 P1 + ~70 条 P2/P3 拆为三档：

| 档位 | 阶段 | 时间窗口 | 损失容忍 | 修复门控 |
|---|---|---|---|---|
| **Stage 1：上线前必修** | Optimism mainnet beta 前 | 1-2 周 | 0 — 匿名攻击者存在 | 全部合并后才能部署 |
| **Stage 2：Beta 阶段修** | Optimism 内测 | 1-3 个月 | 低 — 实验性资金，仅 N 个合作方 | 内测期间 UUPS 升级 |
| **Stage 3：搭车修** | 持续 | 长期 | 0 — 非功能性改动 | 跟随 Stage 1/2 PR 一起发 |

### 1.1 Stage 1（上线前）入选规则

**满足任一条件**即必须上线前修：

1. **匿名可调** — 攻击者无需 role / 无需 stake / 无身份即可触发
2. **永久损坏** — 一旦触发，链上无法恢复（合约 brick / 治理永久 DoS / 账目永久错乱）
3. **现有授权被滥用** — 利用用户正常行为的副作用（例：用户给 USDC 标准 `approve(facilitator, MAX)`）
4. **加密学绕过** — 完全绕过签名/证明验证
5. **信任边界违反** — 角色越过其声明的信任级别（参见 threat-model §3.1）

### 1.2 Stage 2（Beta 阶段）降级规则

**全部满足**才能延后到内测期：

1. 攻击需要治理权（multisig 角色 / `onlyOwner` setter）
2. UUPS 升级即可修复，无需状态迁移
3. 存在手动 workaround（提取资金 / 多签否决 / 链下监控 + 关停）
4. Beta 损失有限（用户少 + 实验性资金）

### 1.3 Stage 3（搭车）入选规则

- 非安全：代码风格 / 文档 / 注释 / 事件补全
- 低争用下的性能（gas 优化，不阻塞）
- 不改行为的 storage 布局清理
- 仅 SDK 面的命名 / API rename

---

## 2. P0 上线前必修清单一览

经 D1-D8 决策 + Codex Phase 6 复审 + 2026-04-28 V4 上线确认，**最终 17 项 P0**（其中 P0-12 拆为 12a/12b 两个子修复）：

| # | ID | 来源 | Codex | 威胁 | 标题 | 推荐 |
|---|---|---|---|---|---|---|
| P0-1 | B6-C1a | review §B6 | 🆕 已细化 | T-01 | BLS 聚合签名伪造 | **保留 Stage 1** |
| P0-2 | B6-C1b | review §B6 | ✅ | T-02 | Validator 注册无 stake 校验 | **保留 Stage 1** |
| P0-3 | B6-C2 | review §B6 | ⚠️ +Codex B-N4 | T-04 | Blacklist 伪造 + 跨链重放 | **保留 Stage 1** |
| P0-4 | B6-H1 | review §B6 | ✅ | T-04 | `executeWithProof` 无鉴权 | **保留 Stage 1** |
| P0-5 | B5-H1 | review §B5 | ✅ | T-11 | V4 Paymaster `deactivate` 接口断裂 | **保留 Stage 1**（V4 同 V3 上线） |
| P0-6 | B5-H2 | review §B5 | ✅ | T-12 | V4 Paymaster `pause()` 死代码 | **保留 Stage 1**（V4 同 V3 上线） |
| P0-7 | B4-H1 | review §B4 | ✅ | T-13 | xPNTs `emergencyRevoke` 不完整 | **保留 Stage 1** |
| P0-8 | B4-H2 | review §B4 | ✅ | T-14 | xPNTs burn 防火墙绕过 | **保留 Stage 1** |
| P0-9 | B2-N1 | review §B2 | ✅ | T-10 | `setAPNTsToken` 任意切换 | **保留 Stage 1** |
| P0-10 | B2-N2 + P3-H2 | review §B2 + §P3 | ⚠️ Codex 细化（D8） | T-06 | Chainlink 紧急路径 + 偏离阈值 | **保留 Stage 1**（D8 锁定） |
| P0-11 | B2-N3 + B4-M2 + P3-H1 | 多处 | ✅ | T-16 | 多处价格 setter 无 bounds | **保留 Stage 1**（V4 PaymasterBase 暴露） |
| P0-12a | B2-N4（D4 第 1 部分） | review §B2 | ✅ | T-05 | x402 Direct path：asset 必须是 xPNTs | **保留 Stage 1** |
| P0-12b | （D4 新增） | decision-records D4 | 🆕 D4 | T-05 | x402 Direct path：社区核准的 facilitator 白名单 | **保留 Stage 1** |
| P0-13 | B3-N3 + B2-N8 | review §B3 + §B2 | ✅ | T-15 | x402 nonce DoS（per-asset 三元组 key） | **保留 Stage 1** |
| P0-14 | H-01 | review §H + B1 | ✅ | T-07 | Slash 同步 Registry ↔ Staking | **保留 Stage 1** |
| P0-15 | J2-BLOCKER-1 | review §J2 | ✅ | T-17 | `dryRunValidation` 缺失 | **候选-Beta**（仅 UX，可延后） |
| P0-16 | Codex B-N1 | review §6.B | 🆕 Codex | T-08 | 未来时间戳绕过 staleness | **保留 Stage 1** |
| P0-17 | Codex B-N5 | review §6.B | 🆕 Codex | T-09 | DVT `proposalId` 预占毒化 | **保留 Stage 1** |

**推荐总结**（2026-04-28 V4 决策后）：
- **保留 Stage 1（17 项）**: P0-1 ~ P0-14, P0-16, P0-17（含 P0-12a/12b 两个子项）
- **候选-Beta（1 项）**: P0-15（`dryRunValidation` 是纯 UX，非安全）

即 **17 项坚定 Stage 1** + **1 项 UX 待你判断**。

> **讨论流程**：我们逐条过。每条我提供 bug 证据 + Codex 状态 + 业务场景 + 必要性论证。你判定保留 Stage 1 / 移到 Stage 2 / 完全砍掉。17-18 条全部确认后，本文档即为最终 Stage 1 修复清单。

---

## 3. 逐条深度分析

> 每条格式：来源 / 文件:行号 / Codex 复审状态 / 威胁场景 / bug 是什么 / 业务场景 / 必要性 / 推荐 / 修复方案 / 工作量 / 待用户决策

---

### P0-1: BLS 聚合签名伪造

**来源**: B6-C1a（review.md §Phase 2 B6）
**文件:行号**: `contracts/src/modules/monitoring/BLSAggregator.sol` —— 整个 `verify()` 函数
**Codex Phase 6**: 🆕 独立确认（T-01）
**威胁场景**: T-01

**bug 是什么**：
`BLSAggregator.verify(message, signerMask, pkAgg, sig)` 把 `pkAgg`（聚合公钥）作为**调用者传入的参数**接受。配对方程 `e(pk_agg, H(m)) == e(g1, sig)` 在数学上对调用者**自由选择**的任意 (sig, pkAgg) 组合都成立。合约**没有**交叉校验：`pkAgg` 必须由 `signerMask` 选中的链上 `blsPublicKeys[validator]` 重新聚合得到。

**代码证据**：
```solidity
// BLSAggregator.sol — 当前行为（简写）
function verify(bytes32 message, bytes32 signerMask, bytes pkAgg, bytes sig) {
    // 配对检查直接用调用者的 pkAgg
    require(BLS12_381.pairing(pkAgg, H(message), G1, sig));
    // ❌ 永远不从链上 validator PK 重建 pkAgg
}
```

**业务场景**：
匿名攻击者调 `Registry.updateOperatorBlacklist(operator=victim, proof=forged)`。Aggregator 返回 true。受害 operator 被列入黑名单 → 无法服务用户。攻击者再调 `executeSlashWithBLS` 抽干受害者的 GToken 质押。**单个攻击者，0 stake，0 role，可瞬间清掉任意 operator 的资金。**

**必要性**：
- **类型**：加密学绕过（规则 #4）+ 匿名可调（规则 #1）
- **匿名？** 是 —— `verify()` 没访问控制
- **永久？** Slash + blacklist 都是永久状态变更
- **损失上限**：单 operator 的 stake + 服务可用性；累计跨所有 operator = 灾难级
- **可恢复？** Owner 可手动恢复 list + 通过治理还原 stake，但声誉/SLA 损害已成
- **可探测？** 是（事件触发），但没用 —— 损害瞬间发生

**推荐**: ✅ **保留 Stage 1** —— 任何人，任何时候，0 成本。

**修复方案**: BLSAggregator 必须自己从 `signerMask` + 链上 `blsPublicKeys` 重建 `pkAgg`：
```solidity
function verify(bytes32 message, uint256 signerMask, bytes sig) {
    bytes memory pkAgg = _reconstructPkAgg(signerMask);
    require(BLS12_381.pairing(pkAgg, H(message), G1, sig));
}
```
+ 删除 `BLSValidator.sol`（per review.md P0-1 修复指引）。

**工作量**：1-2 天代码 + 2-3 天 fuzz/invariant 测试（BLS pairing 边界条件）

**待你决策**：无 —— 必须修。❓ 但：用现成的 solady / 经审计库的聚合 PK 辅助函数，还是手写？

---

### P0-2: Validator 注册无 stake 校验

**来源**: B6-C1b（review.md §Phase 2 B6）
**文件:行号**: `contracts/src/modules/monitoring/DVTValidator.sol::addValidator`、`BLSAggregator.sol::registerValidator`
**Codex Phase 6**: ✅ 已确认
**威胁场景**: T-02

**bug 是什么**：
`addValidator(addr, blsPK)` 是 `onlyOwner`，接受任意地址。**没有**校验 `addr` 是否持有 `ROLE_DVT`，也没校验 `GTokenStaking.roleLocks[addr][ROLE_DVT].amount >= minStake`。owner（或被攻陷的 admin）可加入无 stake 的 validator；与 P0-1 组合，即便有 stake 的 validator，伪造签名也能绕过 stake 经济约束。

**业务场景**：
- Owner 加 7 个无 stake 的 key → 整个 quorum 无人有 skin in the game
- 或：owner 加友好 validator 但未质押 → 经济安全崩塌
- 即便 owner 善意，**没有 stake gate = 设计本身不强制 skin-in-the-game**

**必要性**：
- **类型**：信任边界违反（规则 #5）—— DVT validator 在 threat-model §3.1 是"PARTIAL TRUST"；partial trust 必须有 stake gating
- **匿名？** 否（owner 操作）
- **但**：与 P0-1 组合后，变成匿名可利用
- **永久？** 否 —— owner 可移除 validator（P1-25 加 removal）
- **可恢复？** 是，通过治理

**推荐**: ✅ **保留 Stage 1** —— 即便 owner 善意，纵深防御必须立得住。没有 stake gate，整个 DVT 经济安全只是表演。

**修复方案**:
```solidity
function addValidator(address addr, bytes blsPK) onlyOwner {
    require(registry.hasRole(addr, ROLE_DVT), "not DVT role");
    require(staking.roleLocks(addr, ROLE_DVT).amount >= minStake, "stake too low");
    // ... 现有逻辑
}
```

**工作量**：4 小时代码 + 1 天测试

**待你决策**：DVT 角色的 **minStake 下限**是多少？目前在 Registry 按 role 配置，但没有审计验证的具体数值。建议：≥ 10 倍预期 slash 数量，让 slash 经济意义有效。

---

### P0-3: Blacklist 伪造 + 跨链重放

**来源**: B6-C2（review.md）+ Codex B-N4（review.md §6.B）
**文件:行号**: `contracts/src/core/Registry.sol:377-393`（`updateOperatorBlacklist`）
**Codex Phase 6**: ⚠️ Codex 细化 —— 新增跨链重放向量（B-N4）
**威胁场景**: T-04 + T-19

**bug 是什么**：
1.（原 B6-C2）`updateOperatorBlacklist` 在 `BLS_AGGREGATOR_ADDRESS == address(0)` 时接受空 `proof`，且任意 caller（无 `onlyBLSAggregator`）
2.（Codex B-N4）即便要求 proof，BLS 消息哈希**不包含** `chainId` / `proposalId` / `nonce` → 链 A 上的合法 blacklist proof 可在链 B 重放（例：Optimism testnet → Optimism mainnet），因为同一 operator 地址可能同时存在于两条链

**业务场景**：
-（Codex 之前）匿名用户调 `updateOperatorBlacklist(victim, true, "")` → 受害者被审查
-（Codex 新增）多链部署场景：攻击者从一条链（例如 Optimism testnet 上一次合法的 slash 提案）抓取一个真实 proof，在 Optimism mainnet 重放对同一 operator 地址 → mainnet 黑名单被应用，没有经过正常治理投票

**必要性**：
- **类型**：匿名可调（规则 #1）+ 跨链重放（规则 #4 子类）
- **匿名？** 是（当前代码）
- **永久？** Blacklist 可由 owner 反向操作，但服务可用性损害已成
- **损失上限**：单 operator 服务可用性 × 受害数量
- **可恢复？** 是（owner 反向），但反应式

**推荐**: ✅ **保留 Stage 1** —— 两个向量都匿名可利用。

**修复方案**:
```solidity
function updateOperatorBlacklist(address op, bool flag, bytes proof) external {
    require(msg.sender == BLS_AGGREGATOR_ADDRESS, "only aggregator");
    require(proof.length > 0, "proof required");
    // BLS 消息包含 chainId + proposalId + nonce
    bytes32 msgHash = keccak256(abi.encode(
        block.chainid,
        proposalId,
        op,
        flag,
        proposalNonce++ // 单调递增
    ));
    require(blsAggregator.verify(msgHash, signerMask, sig));
    // ...
}
```

**工作量**：4 小时代码 + 1 天测试

**待你决策**：用全局 `proposalNonce` per (operator, flag) 元组，还是单一全局计数器？全局更简单；per-tuple 防止"通过烧 nonce 来 grief"。

---

### P0-4: `executeWithProof` 无鉴权

**来源**: B6-H1（review.md §Phase 2 B6）
**文件:行号**: `contracts/src/modules/monitoring/DVTValidator.sol:86-105`
**Codex Phase 6**: ✅ 已确认
**威胁场景**: T-04（关联）

**bug 是什么**：
`executeWithProof(proposalId, target, data, proof)` 没 caller 限制。结合 P0-1（BLS 伪造）+ P0-2（无 stake），匿名 caller 可提交伪造 proof 在 DVT 上下文中执行任意 `target.call(data)` 操作。

**业务场景**：
攻击者伪造 proof → 调 `executeWithProof(proposalId, RegistryAddress, slashCalldata, forgedProof)` → 触发任意 slash 操作。即便 P0-1 没修，没有 `onlyValidator` / `onlyBLSAggregator` 意味着任何持有"看起来合法的"proof 的 caller 都能驱动 DVT 操作。

**必要性**：
- **类型**：匿名可调（规则 #1）+ 信任边界违反（规则 #5）
- **匿名？** 是
- **永久？** 取决于 `target.call(data)` —— 若触发 slash/blacklist 即永久
- **损失上限**：DVT 能做的任何事（即：协议级治理操作）

**推荐**: ✅ **保留 Stage 1** —— P0-1 的纵深防御。

**修复方案**:
```solidity
modifier onlyAuthorizedExecutor() {
    require(
        msg.sender == BLS_AGGREGATOR_ADDRESS ||
        registry.hasRole(msg.sender, ROLE_DVT),
        "not authorized"
    );
    _;
}
function executeWithProof(...) external onlyAuthorizedExecutor { ... }
```

**工作量**：2 小时

**待你决策**：`executeWithProof` 是否仅限 BLSAggregator 调用（单一来源），还是允许任何 DVT 角色成员？单一来源更干净；多源在 aggregator 宕机时有 backup 路径。

---

### P0-5: V4 Paymaster `deactivate/activate` 接口断裂

**来源**: B5-H1（review.md §Phase 2 B5）
**文件:行号**: `contracts/src/paymasters/v4/Paymaster.sol:82-91`
**Codex Phase 6**: ✅ 已确认
**威胁场景**: T-11

**bug 是什么**：
PaymasterV4 调用 `Registry.deactivate(...)` 和 `Registry.activate(...)` —— 这两个函数在 V3 Registry 上**不存在**。V3 API 用 `exitRole(roleId)` / `assignRole(...)`。V4 → V3 的所有 deactivate/activate 调用**静默 revert**。

**业务场景**：
- AOA 模式 operator（社区运行自己的 PaymasterV4）发现安全事件 → 想 deactivate 止血
- 调 `paymaster.deactivate()` → revert
- Operator 必须手动抽干自己的 deposit（多笔 tx）+ 通过 Registry 注销 → 持续流血几分钟到几小时

**必要性**：
- **类型**：设计（规则 #5 与 V3 接口不匹配）
- **匿名？** 否
- **永久？** 否 —— 手动 workaround 存在
- **损失上限**：事件响应窗口内的流血（分钟到小时）
- **可恢复？** 是（手动）

**推荐**: ✅ **保留 Stage 1** —— 用户 2026-04-28 确认：V4 与 V3 一同在 Optimism beta 上线。AOA 模式社区从第一天就需要链上紧急停机。

**修复方案**:
```solidity
function deactivate() external onlyOwner {
    registry.exitRole(uint256(keccak256("PAYMASTER_AOA")));
    emit Deactivated();
}
```

**工作量**：2 小时

**待你决策**：无 —— V4 上线决策已锁定。

---

### P0-6: V4 Paymaster `pause()` 永远不触发

**来源**: B5-H2（review.md §Phase 2 B5）
**文件:行号**: `contracts/src/paymasters/v4/PaymasterBase.sol:83/165/207`（`whenNotPaused` modifier）
**Codex Phase 6**: ✅ 已确认
**威胁场景**: T-12

**bug 是什么**：
`whenNotPaused` modifier 挂在 validation/postOp 路径上，但**没有** `pause()` / `unpause()` setter 翻转布尔值。Modifier 永远在做 false 检查 —— 即"paused" 永远不可能被设为 true。死代码误导 operator 以为有紧急 pause 能力。

**业务场景**：
同 P0-5：operator 想在事件中停机 → 链上无原语 → 必须手动抽 deposit。

**必要性**：
同 P0-5。

**推荐**: ✅ **保留 Stage 1** —— 同 P0-5；V4 在 beta 上线。

**修复方案**:
```solidity
bool public paused;
event Paused();
event Unpaused();
function pause() external onlyOwner { paused = true; emit Paused(); }
function unpause() external onlyOwner { paused = false; emit Unpaused(); }
```

**工作量**：2 小时

**待你决策**：无 —— V4 上线决策已锁定。

---

### P0-7: xPNTs `emergencyRevokePaymaster` 不完整

**来源**: B4-H1（review.md §Phase 2 B4）
**文件:行号**: `contracts/src/tokens/xPNTsToken.sol:437-444 + 298-319`
**Codex Phase 6**: ✅ 已确认
**威胁场景**: T-13

**bug 是什么**：
`emergencyRevokePaymaster()` 把 `autoApprovedSpenders[currentSP] = false`，但**没有把 `SUPERPAYMASTER_ADDRESS` 置零**。被攻陷的 SP 仍可调 `burnFromWithOpHash(user, amount, opHash)`，因为该路径检查 `msg.sender == SUPERPAYMASTER_ADDRESS`，不查 autoApproved 映射。

**业务场景**：
- SP 被发现攻陷（SP 私钥泄露 / 升级漏洞）
- Community owner 调 `emergencyRevokePaymaster()` 想止损
- 被攻陷 SP 持续 burn user xPNTs（在 $100/tx 防火墙内但持续）
- Community operator 困惑 —— 以为 revoke 起作用了

**必要性**：
- **类型**：事件响应能力（规则 #5 —— 信任边界违反：SP 攻陷后是 BOUNDED TRUST）
- **匿名？** 否（被攻陷 SP）
- **永久？** 否，但持续损害直到完整诊断
- **损失上限**：$100/tx × tx频率 × 诊断时间

**推荐**: ✅ **保留 Stage 1** —— 即便在 beta 中，事件响应也至关重要。如果 SP 在 beta 中被攻陷，operator 需要**一个调用即可完全停机**。

**修复方案**:
```solidity
function emergencyRevokePaymaster() external onlyCommunityOwner {
    autoApprovedSpenders[SUPERPAYMASTER_ADDRESS] = false;
    SUPERPAYMASTER_ADDRESS = address(0); // ← 加这一行
    emit EmergencyRevoked();
}
```

或加 `bool public emergencyDisabled` 并门控 burn 路径：
```solidity
function burnFromWithOpHash(...) external {
    require(!emergencyDisabled, "emergency stop");
    // ...
}
```

**工作量**：2 小时代码 + 1 天测试

**待你决策**：revoke 后社区如何**升级到新 SP**？是否有 `setNewSuperPaymaster()` 路径，还是 xPNTs token 必须重新部署？这是 runbook 问题。

---

### P0-8: xPNTs `burn(address, uint256)` 防火墙绕过

**来源**: B4-H2（review.md §Phase 2 B4）
**文件:行号**: `contracts/src/tokens/xPNTsToken.sol:476-492`
**Codex Phase 6**: ✅ 已确认
**威胁场景**: T-14

**bug 是什么**：
`burn(address user, uint256 amount)` 重载（address-uint 变体）在 autoApproved spender 路径下绕过 `_spendAllowance`。autoApproved spender 可调 `burn(victimUser, amount)` burn 任意用户余额，无需明确 allowance 检查，上限 MAX_SINGLE_TX_LIMIT（$100）。

**业务场景**：
- 被攻陷 facilitator（autoApproved spender）连续调 `burn(user1, $100)` → `burn(user2, $100)` → ...
- 每笔在防火墙内（$100/tx）但累计无上限
- 直到社区检测 + revoke（P0-7），$100 × N 用户已没

**必要性**：
- **类型**：spender 匿名（规则 #5 信任边界 —— facilitator 是 BOUNDED TRUST，但边界是单笔不是累计）
- **匿名？** 否，但 spender 是 bounded-trust 角色
- **永久？** Burn 是永久（ERC20 supply 减少）
- **损失上限**：$100 × 用户数 × revoke 前时间

**推荐**: ✅ **保留 Stage 1** —— 与 P0-7（revoke 不完整）组合，是真实的抽干向量。

**修复方案**:
```solidity
function burn(address from, uint256 amount) external {
    if (from != msg.sender) {
        _spendAllowance(from, msg.sender, amount); // ← 永远强制
    }
    _burn(from, amount);
    require(amount <= MAX_SINGLE_TX_LIMIT);
}
```

**工作量**：2 小时

**待你决策**：是否加 **per-user-per-day 累计 cap**（例如 $500/user/day 跨所有 autoApproved spender）？这会限制"连续 burn 多用户"模式。建议：加。

---

### P0-9: `setAPNTsToken` 任意切换

**来源**: B2-N1（review.md §Phase 2 B2）
**文件:行号**: `contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol:250-255`
**Codex Phase 6**: ✅ 已确认
**威胁场景**: T-10

**bug 是什么**：
Owner 可在 `protocolRevenue + Σ aPNTsBalance > 0` 时调 `setAPNTsToken(newToken)`。切换后新 token 余额为 0；旧余额被搁浅 → 所有 operator 被冻结无法访问 deposit。

**业务场景**：
- Owner 误调 `setAPNTsToken(wrongAddress)`（typo / 钓鱼 / multisig 协调错误）
- 或：恶意 owner 切换以抽干 operator 服务能力，再勒索切换回去
- 所有注册 operator 同时失去 aPNTs 访问权
- **永久资金搁浅**，除非 owner 手动迁移所有余额

**必要性**：
- **类型**：永久损坏（规则 #2）
- **匿名？** 否（owner 操作 —— 但 multisig 少数派 + owner key 攻陷场景适用）
- **永久？** 实质永久 —— 恢复需要逐 operator 手动迁移
- **损失上限**：所有 operator deposit

**推荐**: ✅ **保留 Stage 1** —— 即便 owner 是 multisig + timelock（per D5-bis），timelock 窗口期间是热事件中；这道护栏防止意外 + 恶意。

**修复方案**:
```solidity
function setAPNTsToken(address newToken) external onlyOwner {
    require(totalTrackedBalance == 0 && protocolRevenue == 0, "balances exist");
    APNTS_TOKEN = newToken; // (或用迁移 helper 显式 transfer)
    emit APNTsTokenChanged(newToken);
}
```

或用迁移 helper：
```solidity
function setAPNTsTokenWithMigration(address newToken) external onlyOwner {
    require(timelocked24h);
    // 显式迁移余额
    // ...
}
```

**工作量**：4 小时代码 + 1 天测试

**待你决策**：`setAPNTsToken` 是否预期在生产中调用？per D3（Code Launch），aPNTs 是固定的。如果永不预期调用，可改 `revert` 或不暴露（用 immutable + UUPS impl swap 处理迁移）。

---

### P0-10: Chainlink 紧急路径 + 价格偏离阈值（per D8）

**来源**: B2-N2 + P3-H2（review.md §Phase 2 B2 + §Phase 3）
**文件:行号**: `contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol:342-376`（`updatePriceDVT`）
**Codex Phase 6**: ⚠️ Codex 细化 —— Codex 论证我原方案"宕机时拒绝"逻辑反了；用户 D8 选 (b) 收紧 + 不禁用
**威胁场景**: T-06

**bug 是什么**：
1.（B2-N2）`updatePriceDVT` 的 owner 紧急路径绕过 Chainlink 偏离阈值检查
2.（P3-H2）当 Chainlink 自身 stale，偏离检查失去意义 → 紧急路径实质无界
3.（Codex 细化）"宕机时拒绝"方向错了 —— 应**收紧**而非禁用

**业务场景**：
- **场景 A（oracle 宕机）**: Chainlink mainnet 宕机（历史 2-3 次）。没有紧急路径 → paymaster 停止赞助 → 用户 tx 失败 → operator SLA 破坏。
- **场景 B（oracle 攻击）**: Chainlink 被污染（2022 年 BNB 案例）。Paymaster 自动用坏价格 → operator 被抽干。
- **场景 C（治理滥用）**: Multisig 少数派在 Chainlink 真实宕机时调 `updatePriceDVT` 设极端价格 → 通过偏斜价格抽干。

D8 决策：保留紧急路径，收紧 ±20% 边界 + 1h emergency timelock + 状态机。

**必要性**：
- **类型**：信任边界违反（规则 #5）—— owner 信任有边界；没有边界，"BOUNDED TRUST" 是假的
- **匿名？** 否（owner 操作）
- **永久？** 否（下一次合法 oracle 更新覆盖）
- **损失上限**：单次更新偏斜 × 紧急窗口期间 volume

**推荐**: ✅ **保留 Stage 1** —— D8 已锁定此修复方向。没有它，beta operator 在 oracle 宕机时面临治理滥用风险。

**修复方案**（per D8）:
```solidity
enum PriceMode { CHAINLINK, EMERGENCY }
PriceMode public priceMode;
uint256 public emergencyQueuedAt;
uint256 public emergencyPendingPrice;

function emergencySetPrice(uint256 newPrice) external onlyOwner {
    require(_chainlinkStale(), "chainlink fresh, no emergency");
    require(newPrice >= cachedPrice * 80 / 100, "below ±20% bound");
    require(newPrice <= cachedPrice * 120 / 100, "above ±20% bound");
    emergencyPendingPrice = newPrice;
    emergencyQueuedAt = block.timestamp;
    emit EmergencyPriceQueued(newPrice);
}

function executeEmergencyPrice() external {
    require(block.timestamp >= emergencyQueuedAt + 1 hours, "timelock");
    cachedPrice = emergencyPendingPrice;
    priceMode = PriceMode.EMERGENCY;
    emit EmergencyPriceExecuted(emergencyPendingPrice);
    // 链下 Slack webhook listener
}
```

**工作量**：2-3 天代码 + 2 天测试

**待你决策**：
- ❓ "Chainlink stale" 阈值是多少？1h？4h？（建议：1h 用于常规，owner 手动 override）
- ❓ `emergencySetPrice` 需要 multisig 还是 `onlyOwner` 即可？（建议：5/7 multisig + 1h timelock）

---

### P0-11: 多处价格 setter 无 bounds

**来源**: B2-N3 + B4-M2 + P3-H1（review.md §B2 + §B4 + §P3）
**文件:行号**:
- `SuperPaymaster.sol:260-265`（`setAPNTsPriceUSD`）
- `xPNTsFactory.sol:337-344`（价格相关 setter）
- `PaymasterBase.sol:474-478`（`setCachedPrice`）
**Codex Phase 6**: ✅ 已确认
**威胁场景**: T-16

**bug 是什么**：
SP / Factory / PaymasterBase 三处独立的价格 setter 都**没有** MIN/MAX 边界、没有单笔 delta 上限、没有 timelock。Owner（或被攻陷的 owner）可瞬间设置任意价格。

**业务场景**：
- 与 P0-10 相同场景，但多个表面
- 不一致：每个 setter 行为不同 → operator 困惑

**必要性**：
- **类型**：设计（规则 #5）
- **匿名？** 否（owner 操作）
- **永久？** 否
- **损失上限**：单次更新偏斜

**推荐**: ✅ **保留 Stage 1** —— 用户 2026-04-28 确认：V4 在 beta 上线。V4 PaymasterBase 价格路径是三处暴露 setter 之一，留它无保护 = V4 直接攻击面。把三处统一为 `BoundedPriceFeed` 模块和 P0-10 一起在一个 PR 解决。

**修复方案**:
```solidity
contract BoundedPriceFeed {
    uint256 public price;
    uint256 public lastUpdate;
    uint256 public constant MIN = 1e16;   // $0.01
    uint256 public constant MAX = 1e20;   // $100
    uint256 public constant DELTA_BPS = 1000; // ±10% per update

    function setPrice(uint256 newPrice) external onlyOwner {
        require(newPrice >= MIN && newPrice <= MAX);
        if (price != 0) {
            require(newPrice >= price * (10000 - DELTA_BPS) / 10000);
            require(newPrice <= price * (10000 + DELTA_BPS) / 10000);
        }
        // 24h timelock for non-emergency
        price = newPrice;
        lastUpdate = block.timestamp;
    }
}
```

通过继承 / 模块组合应用到三处 setter。

**工作量**：3-4 天代码 + 2 天测试

**待你决策**：无 —— V4 上线决策锁定 Stage 1。

---

### P0-12a: x402 Direct path —— asset 必须是 xPNTs

**来源**: B2-N4（review.md）+ D4 用户决策
**文件:行号**: `contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol:1161-1169`
**Codex Phase 6**: ✅ 已确认
**威胁场景**: T-05

**bug 是什么**：
`settleX402PaymentDirect(asset, from, to, amount, ...)` 调 `IERC20(asset).transferFrom(from, to, amount)`，但**没检查** `asset` 是否是注册的 xPNTs token。用户对 USDC 做了标准 `approve(facilitator, MAX)`（完全正常的模式），如果 facilitator 被攻陷 → 通过 Direct path 被抽干。

**业务场景**：
- 用户给 facilitator approve USDC（例：x402 标准支付）
- Facilitator key 泄露
- 攻击者调 `settleX402PaymentDirect(USDC, victim, attacker, victim's_balance)` → 抽干
- xPNTs 受防火墙 + $100/tx 限保护；**USDC 在当前代码中没此保护**

**必要性**：
- **类型**：现有授权被滥用（规则 #3）—— 利用用户正常行为
- **匿名？** 否（facilitator）但 facilitator key 攻陷在 threat-model 是 BOUNDED TRUST
- **永久？** 否 —— 用户可重新 approve，但资金已没
- **损失上限**：用户 USDC 授权额度（通常无限）

**推荐**: ✅ **保留 Stage 1** —— 即便 beta 合作方有限，USDC 抽干在任何 beta 用户做标准 infinite-approve 时都是真实风险。

**修复方案**（per D4）:
```solidity
function settleX402PaymentDirect(address asset, ...) external {
    require(xPNTsFactory.isXPNTs(asset), "Direct: asset must be xPNTs");
    // ...
}
```

加 `xPNTsFactory.isXPNTs(address)` view（每次 `deployToken` 时记录）。

**工作量**：4 小时

**待你决策**：无 —— D4 已锁定。

---

### P0-12b: x402 Direct path —— 社区核准的 facilitator 白名单

**来源**: D4 用户决策（decision-records.md）
**文件:行号**: `settleX402PaymentDirect` + `xPNTsToken` 新需求
**Codex Phase 6**: 🆕 新增（D4 驱动）
**威胁场景**: T-05（扩展）

**bug 是什么**：
per D4：每个 xPNTs token 应让社区 owner 指定哪些 facilitator 被核准。当前 autoApprovedSpenders 是单一全局映射，没有社区控制的 rotation 接口。

**业务场景**：
- Community A 部署 xPNTs A。社区想用 AAStar 的默认 facilitator + 自己的备用 facilitator
- Community B 只用自己的 facilitator
- D4 模型：per-xPNTs `approvedFacilitators[]` 由社区 multisig 控制

不修这条：
- 所有 xPNTs auto-trust 同一个全局 facilitator → 跨社区 blast radius

**必要性**：
- **类型**：信任边界违反（规则 #5）—— 社区信任作用域泄漏
- **匿名？** 否（facilitator 操作）
- **永久？** 否
- **损失上限**：单 community xPNTs × 所有 approved facilitator

**推荐**: ✅ **保留 Stage 1** —— D4 锁定。

**修复方案**:
```solidity
// xPNTsToken
mapping(address => bool) public approvedFacilitators;
function addApprovedFacilitator(address f) external onlyCommunityMultisig {
    approvedFacilitators[f] = true;
    emit FacilitatorApproved(f);
}
function removeApprovedFacilitator(address f) external onlyCommunityMultisig {
    approvedFacilitators[f] = false;
    emit FacilitatorRemoved(f);
}

// xPNTsFactory.deployToken — 加 initialApprovedFacilitators 参数
function deployToken(..., address[] calldata initialFacilitators) external returns (address) {
    // ... clone and init ...
    for (uint i; i < initialFacilitators.length; i++) {
        token.addApprovedFacilitator(initialFacilitators[i]);
    }
}

// SuperPaymaster
function settleX402PaymentDirect(address asset, ...) external {
    require(xPNTsFactory.isXPNTs(asset), "must be xPNTs");
    require(IXPNTsToken(asset).approvedFacilitators(msg.sender), "facilitator not approved by community");
    // ...
}
```

**工作量**：1-2 天代码 + 1 天测试

**待你决策**：
- ❓ 社区部署默认 facilitator —— 自动 add AAStar 的？还是默认空 + 社区显式 add？
- ❓ 新社区的 **community multisig** 是什么？每个社区部署自己的 Safe，还是用模板？

---

### P0-13: x402 nonce DoS（per-asset 三元组 key）

**来源**: B3-N3 + B2-N8 + L-03（review.md §B3 + §B2）
**文件:行号**: `contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol:1148-1157`（`x402SettlementNonces`）
**Codex Phase 6**: ✅ 已确认
**威胁场景**: T-15

**bug 是什么**：
`x402SettlementNonces[nonce] = true` 把 nonce 放在全局命名空间。匿名攻击者可预先烧合法 settlement 的 nonce：观察 pending settlement 意图 → 用相同 nonce 在不同 (asset, from) 上下文先提交一笔 → 合法 settlement revert "nonce used"。

**业务场景**：
- 用户签 EIP-3009 settlement，nonce = `0xabcd...`
- 攻击者通过 mempool / 链下渠道观察到
- 攻击者抢先提交 dummy settlement，`(asset=任意, from=任意, nonce=0xabcd...)` 占坑
- 用户合法 settlement 现在 revert → DoS

**必要性**：
- **类型**：匿名可调（规则 #1）DoS
- **匿名？** 是
- **永久？** 否（per-tx）
- **损失上限**：单笔交易被 grief

**推荐**: ✅ **保留 Stage 1** —— Beta 期间匿名 DoS 不可接受，会损害发布信誉。

**修复方案**:
```solidity
mapping(bytes32 => bool) public x402SettlementNonces; // 结构不变
function _x402NonceKey(address asset, address from, bytes32 nonce) pure returns (bytes32) {
    return keccak256(abi.encode(asset, from, nonce));
}

// settle 中：
bytes32 key = _x402NonceKey(asset, from, nonce);
require(!x402SettlementNonces[key], "nonce used");
x402SettlementNonces[key] = true;
```

**工作量**：2 小时

**待你决策**：无 —— 修复方向清晰。

---

### P0-14: Slash 同步 Registry ↔ Staking

**来源**: H-01（review.md Phase 1）+ B1-confirmed（Phase 2 B1）
**文件:行号**: `Registry.sol:211-213` + `GTokenStaking.sol::slashByDVT`（及相关）
**Codex Phase 6**: ✅ 已确认
**威胁场景**: T-07

**bug 是什么**：
当 `GTokenStaking.slashByDVT(user, role, amount)` 减少 `roleLocks[user][role].amount` 时，`Registry.roleStakes[user][role]` **没有更新**。`Registry.topUpStake` 读 stale 的 Registry 值，可能高估实际由 Staking 支撑的数量。

**业务场景**：
- Operator A 在 Staking.roleLocks 锁了 1000 GToken
- Operator A 行为不端 → DVT slash 500 → Staking.roleLocks = 500
- Registry.roleStakes 仍显示 1000
- Operator A 调 `Registry.topUpStake(role, 100)` → Registry 加 100 → 读出 1100
- 实际：仅 600 由 Staking 支撑 → 多算 500
- 如果 `topUpStake` 受当前 stake 影响（例如 role 分配），op 获得不公平优势

此外：任何读 Registry.roleStakes 的 UI / SDK 显示错误值 → 用户信任受损。

**必要性**：
- **类型**：账目完整性（规则 #2 永久损坏，状态分歧）
- **匿名？** 否
- **永久？** 直到手动 resync
- **损失上限**：单次 slash 漂移 × stale-read 使用次数
- **可探测？** 是（链下查询对比）

**推荐**: ✅ **保留 Stage 1** —— INV-12（Registry == Staking）是 Codex 标记的 4 个"最高影响失效"不变量之一。这里的漂移是静默的且会复合。

**修复方案**:
```solidity
// GTokenStaking.slashByDVT
function slashByDVT(address user, uint256 role, uint256 amount) external onlyAuthorized {
    // ... 现有 slash 逻辑 ...
    roleLocks[user][role].amount -= amount;

    // 新增：回调 Registry
    IRegistry(REGISTRY).syncStakeFromStaking(user, role, roleLocks[user][role].amount);
}

// Registry
function syncStakeFromStaking(address user, uint256 role, uint256 newAmount) external {
    require(msg.sender == address(staking), "only staking");
    roleStakes[user][role] = newAmount;
    emit StakeSyncedFromStaking(user, role, newAmount);
}
```

**工作量**：4-6 小时代码 + 2 天测试 + invariant 测试

**待你决策**：是否让 `topUpStake` 也直接读 Staking 而不是 Registry storage？这会让 Staking 成为唯一真相来源（推荐）。Registry.roleStakes 变成 cache。

---

### P0-15: `dryRunValidation` 缺失（UX）

**来源**: J2-BLOCKER-1（review.md §Phase 4 J2）
**文件:行号**: `contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol:738-795`（`validatePaymasterUserOp` 6 处静默拒绝路径）
**Codex Phase 6**: ✅ 已确认；Codex 建议在 validationData 高位 bits 编码原因
**威胁场景**: T-17

**bug 是什么**：
`validatePaymasterUserOp` 在 6 条不同路径返回 SIG_FAILURE（config 不存在 / 已暂停 / user 不合格 / 被 block / 限速 / 余额不足）—— bundler/UI 看不到区别。无法诊断 tx 为何被拒。

**业务场景**：
- 用户通过 dApp 提交 userOp
- Bundler 模拟，得到 SIG_FAILURE
- 返回通用 "paymaster validation failed"
- Operator 无法 debug，user 无法恢复，dApp 无法显示可操作错误
- → **UX 差，不是安全问题**

**必要性**：
- **类型**：性能 / UX
- **匿名？** N/A（UX）
- **永久？** 否
- **损失上限**：用户困惑 / 支持工单

**推荐**: ⚠️ **候选-Beta** —— UX 问题，非安全。Stage 1 可只加事件 + 在 Stage 2 加完整 view。

**保留 Stage 1 的反论**：Beta 用户有限；没有 dryRun，每次失败 tx 都变成 SP 团队的 debug 会话。时间成本 > 修复成本。

**修复方案**:
```solidity
function dryRunValidation(PackedUserOperation calldata userOp, uint256 maxCost)
    external view returns (bool ok, bytes32 reasonCode)
{
    // 镜像 validatePaymasterUserOp 中的所有检查
    if (!config.isConfigured) return (false, "OPERATOR_NOT_CONFIGURED");
    if (config.isPaused) return (false, "OPERATOR_PAUSED");
    if (!isEligibleForSponsorship(sender)) return (false, "USER_NOT_ELIGIBLE");
    // ... 等等
    return (true, "");
}
```

加上 validatePaymasterUserOp 中的事件原因发射：
```solidity
emit ValidationFailed(userOpHash, reasonCode);
```

**工作量**：1 天代码 + 1 天测试 + SDK 集成

**待你决策**：
- ❓ Stage 1（beta UX 必需）还是 Stage 2（仅可观测性）？
- ❓ 如果 Stage 2：Stage 1 至少需要事件日志吗？

---

### P0-16: 未来时间戳绕过 staleness（Codex 发现）

**来源**: Codex B-N1（review.md §6.B）
**文件:行号**:
- `SP.updatePriceDVT:347`（cache 写入）
- `PaymasterBase.setCachedPrice:474`（cache 写入）
- `PaymasterBase:299`（postOp 下溢风险）
**Codex Phase 6**: 🆕 Codex 独立新发现
**威胁场景**: T-08

**bug 是什么**：
Cache 更新接受任意 `updatedAt` 时间戳。如果 caller 写 `updatedAt = far_future`，staleness 检查 `block.timestamp - updatedAt < threshold` 永远通过 → 旧或任意价格永久使用。更糟：`PaymasterBase:299` postOp 做减法，当 `updatedAt > block.timestamp` 时下溢，**永久 brick** 该 operator 的 postOp。

**业务场景**：
- 有权调 `updatePriceDVT` 的 DVT validator 意外或恶意设置未来时间戳
- 后续交易：使用 stale 价格（直到下次合法更新）
- 更糟：postOp 下溢 brick = operator 所有未来 tx 在 postOp revert → 赞助断裂

这是**伪装成参数错误的永久 brick 攻击**。

**必要性**：
- **类型**：永久损坏（规则 #2）+ 信任边界违反（规则 #5）
- **匿名？** 否（DVT validator）但 PARTIAL TRUST per threat-model
- **永久？** 是 —— postOp brick 永久直到 UUPS 升级
- **损失上限**：Operator 整个服务可用性

**推荐**: ✅ **保留 Stage 1** —— Codex 最精确的发现；微小修复防止永久 brick。

**修复方案**:
```solidity
function updatePriceDVT(int256 newPrice, uint8 newDecimals, uint256 updatedAt) external {
    require(updatedAt <= block.timestamp, "future timestamp not allowed");
    cachedPrice = PriceCache(newPrice, newDecimals, updatedAt);
}
// + setCachedPrice (PaymasterBase:474) 同样的 guard
// + PaymasterBase:299 安全减法
```

**工作量**：2 小时代码 + 1 天测试

**待你决策**：无 —— 修复方向清晰。

---

### P0-17: DVT `proposalId` 预占毒化（Codex 发现）

**来源**: Codex B-N5（review.md §6.B）
**文件:行号**: `contracts/src/modules/monitoring/DVTValidator.sol:59/73/86`（`markProposalExecuted`、`createProposal`）
**Codex Phase 6**: 🆕 Codex 独立新发现
**威胁场景**: T-09

**bug 是什么**：
`markProposalExecuted(proposalId)` 把 `executed[proposalId] = true` 应用到任意 proposalId。匿名 caller 可预占任意 proposalId。之后当合法 proposal X 被创建并尝试执行，`if (executed[X]) revert AlreadyExecuted()` —— proposal **永远无法执行**。`createProposal` 不重置 `executed[id] = false`。

**业务场景**：
- 攻击者刷 `markProposalExecuted(0x000...000)` 到 `markProposalExecuted(0xfff...fff)` —— 整个 256-bit proposalId 空间标记 "executed"
- 之后合法 slash proposal 永远无法执行（proposalId 空间冲突）
- Workaround：使用极大随机 proposalId，但若攻击者观察到即将到来的 ID 即可针对性预占
- **永久治理 DoS** 针对攻击者预占的任何 proposalId

**必要性**：
- **类型**：匿名可调（规则 #1）+ 永久损坏（规则 #2）
- **匿名？** 是（`markProposalExecuted` 无访问控制）
- **永久？** 是 —— 一旦 executed=true，无法翻转
- **损失上限**：特定 proposalId DoS

**推荐**: ✅ **保留 Stage 1** —— Codex 发现，匿名可调，永久。修复简单。

**修复方案**:
```solidity
// 选项 A：限制 caller
function markProposalExecuted(uint256 proposalId) external onlyAuthorizedExecutor {
    require(proposalExists[proposalId], "proposal not created");
    require(!executed[proposalId], "already executed");
    executed[proposalId] = true;
}

// 选项 B：createProposal 校验唯一
function createProposal(uint256 proposalId, ...) external {
    require(!proposalExists[proposalId], "id already used");
    proposalExists[proposalId] = true;
    // ...
}
```

（建议 A + B 同时上，纵深防御。）

**工作量**：2 小时代码 + 1 天测试

**待你决策**：无 —— 修复方向清晰。

---

## 4. Stage 1 内部执行顺序

所有 P0 确认后，按此顺序执行以最小化集成风险：

### Wave 1 —— 共识与身份（第 1 周）
1. P0-1 BLS 伪造（kernel）
2. P0-2 Validator stake gate（依赖 P0-1 设计）
3. P0-3 Blacklist 伪造 + 链重放
4. P0-4 executeWithProof 鉴权
5. P0-17 proposalId 预占毒化（DVT 相关，同区域）

→ 全部 BLS/DVT 共识修复。跑专项 fuzz/invariant 测试。

### Wave 2 —— 资金与价格（第 1.5 周）
6. P0-9 setAPNTsToken guard
7. P0-10 紧急路径收紧（per D8）
8. P0-11 BoundedPriceFeed 统一
9. P0-16 未来时间戳 guard
10. P0-12a x402 asset 白名单
11. P0-12b x402 社区核准 facilitator
12. P0-13 x402 nonce per-asset 三元组
13. P0-14 slash 同步 Registry ↔ Staking

→ 跑 `INV-03`（revenue 守恒）、`INV-12`（registry/staking 相等）、x402 invariant 测试。

### Wave 3 —— Tokens 与 V4（第 2 周）
14. P0-7 xPNTs emergencyRevoke
15. P0-8 xPNTs burn 防火墙
16. P0-5 V4 deactivate
17. P0-6 V4 pause
18. P0-15 dryRunValidation（如保留 Stage 1）

→ Sepolia 部署 + 完整 E2E 测试套件。

### Tier 1 Codex 复审
- 所有 Wave 1-3 合并后，发 Codex 全 P0 复审，再上 mainnet beta。

---

## 5. 决策汇总表 —— 逐条 review

供你逐条勾选确认：

| # | 标题 | 我的推荐 | 你的选择 | 备注 |
|---|---|---|---|---|
| P0-1 | BLS 伪造 | 保留 | __ | 灾难级匿名 |
| P0-2 | Validator stake gate | 保留 | __ | 纵深防御 |
| P0-3 | Blacklist 伪造 + 重放 | 保留 | __ | 匿名审查 |
| P0-4 | executeWithProof 鉴权 | 保留 | __ | 匿名 DVT 执行 |
| P0-5 | V4 deactivate | 保留 | ✅ | V4 同 V3 上线 (2026-04-28) |
| P0-6 | V4 pause | 保留 | ✅ | V4 同 V3 上线 (2026-04-28) |
| P0-7 | xPNTs emergencyRevoke | 保留 | __ | 事件响应 |
| P0-8 | xPNTs burn 绕过 | 保留 | __ | 持续抽干 |
| P0-9 | setAPNTsToken | 保留 | __ | 永久 brick |
| P0-10 | Chainlink 紧急路径 | 保留 (D8) | __ | D8 锁定 |
| P0-11 | 多处价格 setter | 保留 | ✅ | V4 PaymasterBase 暴露 (2026-04-28) |
| P0-12a | x402 asset 白名单 | 保留 | __ | USDC 抽干 |
| P0-12b | x402 社区 facilitator | 保留 (D4) | __ | D4 锁定 |
| P0-13 | x402 nonce DoS | 保留 | __ | 匿名 DoS |
| P0-14 | Slash 同步 | 保留 | __ | 不变量破裂 |
| P0-15 | dryRunValidation | 候选-Beta | __ | UX |
| P0-16 | 未来时间戳 | 保留 | __ | 永久 brick |
| P0-17 | proposalId 预占毒化 | 保留 | __ | 匿名永久 DoS |

**逐条讨论时待你解决的开放问题**：
1. (P0-2) DVT minStake 下限数额
2. ~~(P0-5/6) V4 mainnet beta 上线？~~ ✅ **2026-04-28 已确认：V4 与 V3 同上线**
3. (P0-7) Revoke 后如何升级到新 SP？
4. (P0-8) 是否加 per-user-per-day 累计 cap？
5. (P0-9) `setAPNTsToken` 部署后是否还会调？
6. (P0-10) Chainlink stale 阈值（1h？4h？）
7. (P0-10) `emergencySetPrice` 是否需 multisig？
8. (P0-12b) 社区部署默认 facilitator —— 自动 add AAStar 的？
9. (P0-12b) Per-community multisig 模板
10. (P0-14) 让 Staking 成为唯一真相来源（Registry 当 cache）？
11. (P0-15) Stage 1（完整 dryRun）还是 Stage 2（仅事件）？

---

## 6. 附录 —— Stage 2（Beta 阶段）+ Stage 3（搭车）预览

### 6.1 Stage 2 Beta 阶段候选

包括：
- **review.md §5.3.2 全部 P1 项（32 项）** —— operator UX、V4 清理、V5.3 Agent 删除（per D1）、MPC 通道改进
- **Codex P1-41/42**（review.md §6.B）—— GTokenStaking 退出费 owner bypass + Chainlink 价格 >0 检查
- **D5-bis (a) 实施**：governance slash 通过 owner multisig + timelock
- **D3 实施**：aPNTsSaleContract 设计 + 部署
- **D7**：sbtHolders → eligibleHolders 重命名（SDK breaking change，与其他 ABI 改动一起 batch）
- **如果你降级了的 P0 候选**：仅 P0-15（如选 Stage 2）

详细列表会在 Stage 1 清单确认后写入 `2026-04-26-p1-beta.md`。

### 6.2 Stage 3 搭车候选

包括：
- **review.md §5.3.4 全部 P3** —— 注释、NatSpec、storage 布局清理、命名
- **review.md §5.3.3 中纯文档/风格的 P2** —— `B2-N18..29`、`B3-N14..17/N18/N19`、`B5-N6..N9`、`L-04 / I-01..04`、`B1-N12..15`
- **EIP-1153 transient cache 文档移除**（per D2）
- **Agent sponsorship 代码移除**（per D1）—— 实际比搭车大，但无新功能；放在 Stage 2 Wave

---

## 7. 流程

1. **现在**：你读本文档，挑一条开始讨论（建议先确认 KEEP 项，再判断 P0-15 候选-Beta 项）
2. **每条**：我提供需要的额外业务上下文；你判定 上线前 / Beta / 砍掉
3. **17 条全部完成后**：本文档更新为最终决策。开放问题全部解决
4. **执行前**：按你的偏好，对最终 P0 清单跑 Codex 复审
5. **执行**：Wave 1 → Wave 2 → Wave 3，每 Wave 配专项测试
6. **最终**：Codex 复审 → Sepolia 部署 → Optimism mainnet beta

---

## 8. 修订记录

- 2026-04-26（initial）: 基于 D1-D8 + Codex Phase 6 + threat-model.md 拆分；提议 14 KEEP + 4 候选-Beta
- 2026-04-28（V4 上线决策）: 用户确认 V4 (AOA 模式) 与 V3 同时在 Optimism beta 上线；P0-5、P0-6、P0-11 升至 KEEP。最终：**17 KEEP + 1 候选-Beta（仅 P0-15 dryRun）**
- 2026-04-28（中文版）: 创建本中文版（`-zh.md`），与英文版（`p0-prelaunch.md`）双语并行维护
- 2026-04-28（逐条最终确认）: 用户确认 6 个设计要点：
  - **P0-1**: 框架表述修正 —— 匿名灾难是 P0-1 + P0-4 组合（P0-4 的 `executeWithProof` 是无鉴权入口）；修复用 `_reconstructPkAgg(signerMask)` 从链上 PK 重建，采用 solady 标准 BLS helper
  - **P0-2**: DVT `minStake` = 20 → **200 ether GToken**，通过 `Registry.configureRole` 调（不改合约，只调部署期配置）；`addValidator` 动态读 staking 配置中的 minStake
  - **P0-3**: caller 收紧到 `msg.sender == blsAggregator`（非 `isReputationSource`）；强制 proof 必填；消息包含 `chainId + proposalId + nonce`（防重放）
  - **P0-7**: 用 `emergencyDisabled` flag（**非**置零地址）—— 一刀切两条 burn 路径；恢复路径用已有 `setSuperPaymasterAddress` + 新增 `unsetEmergencyDisabled`
  - **P0-8**: **per-spender 日 cap**（非 per-user）；默认 50_000 ether xPNTs（约 $1000 @ $0.02），社区多签可调。用户负担：0
  - **P0-11**: 每个 setter 内联 `require()`（**不**抽公共 `BoundedSetter` mixin）；3 个价格语义独立
  - **P0-15**: 留 Stage 1（beta UX 必需 —— 完整 `dryRunValidation` view）
- 2026-04-28（执行启动）: 3 个并行 git worktree + 分支建好：`fix/p0-wave1-consensus`、`fix/p0-wave2-funds-price`、`fix/p0-wave3-tokens-v4`。全部从 `main` 拉。审计分支 `security/audit-2026-04-25` 留给文档。
