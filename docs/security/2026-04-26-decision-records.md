# SuperPaymaster Audit Decision Records

**Date**: 2026-04-26
**Branch**: `security/audit-2026-04-25`
**Related**: `docs/security/2026-04-25-review.md` (§5.6 + §6.E)
**Status**: User decisions captured; pending Step 0 threat model + invariant harness before fix execution

本文档记录 audit 9 个关键决策点的业务上下文、用户决策、以及评审。形式上独立于 review.md，便于明天之后讨论执行计划时对照。

---

## 决策汇总

| # | 决策 | 用户选择 | 我的评估 |
|---|---|---|---|
| D1 | Agent sponsorship 折扣 | **删除** | ✅ 一致 |
| D2 | EIP-1153 transient cache | **删文档** | ✅ 一致 |
| D3 | aPNTs mint 权限模型 | **Code Launch 销售合约**（多签 mint + 市场销售） | ✅ 接受方向；优于我的提议 |
| D4 | x402 Direct settle 路径 | **短期 + 长期都 (b)**：限定 asset == xPNTs only | ✅ 同意；但有 5 个 concern 需补丁 |
| D5 | governance slash 多签门槛 | **并存**（标准 3-of-5 + FastTrack 5-of-7） | ✅ 一致 |
| D5-bis | Optimistic Governance Slash 是否继续？ | （未明示，默认接受 D5 之上的 timelock 方案） | ⚠️ 需确认 |
| D6 | CLOSE_TIMEOUT 默认值 | **(a) immutable** | ✅ 一致 |
| D7 | sbtHolders 设计意图 | **(a) 重命名 `eligibleHolders`** | ✅ 一致 |
| D8 | P0-11 break-glass 修复方向 | **(b) 收紧 + 不禁用** | ✅ 一致；具体细则已确认 |

**总评**：8/9 决策达成一致；D3 用户提供了更好的方案（Code Launch 模型）；D4 用户的判断比我合理但需要 5 个补充控制；D5-bis 需要明示。

---

## D1：Agent sponsorship 折扣 — 删除

### 业务上下文（昨日已分析）

V5.3 的 "Agent-native gas sponsorship" 是核心叙事，但代码层面是半成品（8 个 storage slot 占位、`_applyAgentSponsorship` 没在主路径调用、AgentRegistry mainnet 上无数据）。

### 用户决策

**删除**。

### 评估

✅ **赞同**。

**理由**：
1. ERC-8004 / Agent NFT 生态尚未起飞，没有真实 partner
2. 半成品代码 = 攻击面（占位 storage 容易被升级时遗忘）
3. UUPS 可扩 `__gap`，未来需要时通过升级加回，**痛但可控**
4. Codex Phase 6 也将 P0-15 降为 P1（"是产品决策不是 P0 安全"）

**实施动作**：
- 删除 `_applyAgentSponsorship`、`isRegisteredAgent` 调用点
- 删除 `agentPolicies`, `_agentDailySpend`, `agentIdentityRegistry`, `agentReputationRegistry` storage（8 slots）
- `__gap[40] → __gap[48]`
- 删除 `setAgentPolicies`, `setAgentRegistries`, `getAgentSponsorshipRate` 等公共函数
- 删除接口 `IAgentIdentityRegistry.sol`, `IAgentReputationRegistry.sol`
- SDK：`@aastar/core/actions/agent.ts` 标记为 deprecated（保留导出但 throw "feature removed"）
- 文档：CHANGELOG 注明 v6.0 可能 reintroduce

---

## D2：EIP-1153 transient cache — 仅删文档

### 业务上下文

文档已写"V5.3 用 transient cache 优化 same-operator batch"，**但代码里实际没实施**（虚假宣传）。优化场景仅适用于 100+ 笔同 operator 的大 batch。

### 用户决策

**删除文档**（不实施）。

### 评估

✅ **赞同**。

**理由**：
1. ERC-7562 storage rules 对 transient 在 paymaster validation 阶段的兼容性需要重测，引入风险
2. 真实 ROI 低（仅大 batch operator 受益，每天 < 100 笔的 operator 0 收益）
3. V5.3 已稳定，引入新优化必须重跑全量 bundler 兼容测试

**实施动作**：
- 删除 review.md / Final Report / aastar-sdk CHANGELOG 中关于 EIP-1153 的描述
- 在 `docs/UUPS-upgrade-doc.md` Appendix C（知识库）保留"为何不实施"的记录，避免后续误以为遗漏
- **不删除** `__gap` 槽位（保留给未来需要时使用）

---

## D3：aPNTs mint 权限模型 — Code Launch 销售合约

### 业务上下文（用户补充的新模型）

**用户描述（2026-04-26）**：

> aPNTs 通过 Code Launch（销售合约）销售。销售合约接受各种 token，无需许可。价格由市场和多签合约**共同决定**：
> - **多签合约事先 mint** 数量 → 控制供给（基于 AAStar 社区的服务承诺与服务能力）
> - **市场决定购买** → 决定销售价格的浮动
> - 有一个**基础锚定价格**（对应 AAStar 服务的价值）
> - **不是纯市场化**：因为是 utility token 对应承诺的服务；如果无限制销售 aPNTs 而 AAStar 不能兑现服务，会有问题
> - **初期中心化，未来也不会完全去中心化**：本身是社区对标服务的 utility token

**与我昨日提议的对比**：

| 维度 | 我的 (b) GToken 质押 | 用户的 Code Launch | 我的 (a) 协议 mint |
|---|---|---|---|
| Mint 控制 | operator stake GToken → 自动兑换 | AAStar 多签按服务能力评估后 mint | owner 直接 mint |
| 销售机制 | 1:1 兑换，无销售合约 | 销售合约接受多种 token，价格浮动 | owner 内部分发 |
| 价格形成 | 锚定 GToken 价格 | 锚定 + 市场浮动 | 完全协议定价 |
| 监管定性 | LST 类（更安全） | utility token sale（中等风险） | 发行人责任高 |
| 与 SDSS 一致 | ✅ | ⚠️ 不同模型 | ❌ |

### 评估

✅ **接受用户方向**，且**优于我的提议**。

**为什么用户方案更优**：

1. **承认 AAStar 服务能力的真实约束**：aPNTs 是 utility token（兑换服务），不是抽象金融工具。我提的 GToken 质押模型本质上是把"质押者风险"和"服务承诺"绑死，但 SP 团队承诺服务的能力**不依赖于 GToken 质押者**——这种绑定是错位的。
2. **多签 mint 限制供给 = 防止超发兑现挤兑**：和 USDC/USDT 模型一致（Tether 公司控制 mint，但有储备背书）
3. **接受多种 token 购买 = 降低用户进入门槛**：用户不必先获取 GToken 才能用 SP，可以直接 USDC/ETH 购买
4. **市场定价机制 = 反映服务真实价值**：如果 AAStar 服务变好，市场会愿意溢价；服务变差，价格回归锚定值
5. **不强求完全去中心化 = 务实**：utility token 本来就不该完全市场化（监管 + 服务承诺约束）

**两个 concern 需要在销售合约设计时回答**：

1. **多签 mint 频率与公开度**
   - 是否定期公开 mint 计划？（半年一次 / 季度一次？）
   - 多签成员如何评估"服务能力"？需要量化指标（active operator 数 / 月度 GMV / oracle uptime）
   - 突发增 mint 是否需要 timelock？

2. **基础锚定价格如何决定？**
   - 锚定到什么？（USD？ETH？AAStar 服务的成本计算？）
   - 销售合约是固定价格（peg）还是 bonding curve？
   - 价格偏离锚定多少时多签介入？

**实施动作（建议）**：

| 步骤 | 内容 | 时间 |
|---|---|---|
| 1 | 设计 `aPNTsSaleContract` —— 接受 ERC20 列表 / 多签 mint 接口 / 销售记录 / 价格预言机 | 1 周设计 + 1 周 review |
| 2 | 多签合约：决定 mint quota（基于服务能力评估） | 已有 5-of-7 multisig 可复用 |
| 3 | 价格锚定方案：v1 fixed peg（$0.02/aPNTs，对应当前服务成本），v2 引入 bonding curve | v1 短期 / v2 长期 |
| 4 | aPNTs 改为非可转移（仅 SaleContract 可分发，operator 无法 P2P 流通） | **重要决策** |
| 5 | 文档：`docs/economics/aPNTs-launch-2026-Q3.md` 落地白皮书 | 与销售合约同步 |

**第 4 项需要用户决策**：aPNTs 是否允许在 operator 之间流通（二级市场）？
- 流通：增加流动性 + 价格发现 + 但脱锚风险大
- 不流通：完全 utility，仅"购买 → 消耗"路径

---

## D4：x402 Direct settle 路径 — 短期 + 长期都 (b) 限定 xPNTs

### 业务上下文

x402 v2 有两条路径：
- **EIP-3009**：payer 离线签 → facilitator 提交 → USDC 直转。**安全完整**。
- **Direct**：靠事先 `approve` → facilitator 单方 `transferFrom`。

### 用户决策

> "短期是 B，长期也是 B。每次都弹出用户是一个烦恼和障碍。USDC 弹（自然就是 B），xPNTs 不弹（已内置 approve）。x402 v2 两条路径并行存在没有问题。说出你的 concern。"

用户的核心论点：
1. UX：每次签名 = 障碍，xPNTs 内置 approve 是优势
2. asset 分流：USDC 走 EIP-3009、xPNTs 走 Direct
3. 两条路径并行清晰

### 评估

✅ **同意核心方向**。`xPNTs.autoApprovedSpenders` + `MAX_SINGLE_TX_LIMIT = 5000 ether ($100)` + 防火墙（"只能转给自己或 SP"）已经构建了硬约束 → 即便 facilitator 滥用也有上限。**用户的判断在 UX 维度更对**。

**但 5 个 concern 必须在合约层面落地，否则两条路径并行不安全**：

#### Concern 1：Direct path 必须硬限制 asset 类型 ⚠️ **CRITICAL**

**问题**：当前 `settleX402PaymentDirect()` 没有 asset 白名单检查 → 任何 ERC20 都能走 Direct path。

**真实风险**：用户对 USDC `approve(facilitator, MAX)`（普通的"无限授权"操作） → facilitator 可以用 settleDirect 反复扣款。

**修复**（10 行代码）：
```solidity
function settleX402PaymentDirect(...) external {
    require(xPNTsFactory.isXPNTs(asset), "Direct path: asset must be xPNTs");
    // ... 其余逻辑
}
```

**xPNTsFactory 需要新增**：
```solidity
mapping(address => bool) public isXPNTs;
function _registerToken(address token) internal { isXPNTs[token] = true; }
```

#### Concern 2：Auto-approve 机制必须能 revoke 与 rotate ⚠️ **HIGH**

**问题**：xPNTs 部署时 `autoApprovedSpenders[facilitator] = true`，但当前代码的 spender rotation 机制不清晰。

**真实风险**：
- Facilitator 私钥泄露 → 所有 xPNTs holder 暴露（虽有 $100/tx 上限，但可以连续滥用）
- Facilitator 升级到新地址 → 旧 facilitator 仍有权限

**需要审计**（建议加入 P0-13 子项）：
- `xPNTsToken.addAutoApprovedSpender` / `removeAutoApprovedSpender` 是否存在并且权限正确？
- 谁能 rotate facilitator？（建议 multisig + timelock）
- 老 facilitator 的 allowance 是否在 remove 时被清零？

#### Concern 3：跨 community xPNTs 的 facilitator 隔离 ⚠️ **MEDIUM**

**问题**：每个 community 有自己的 xPNTs（factory clones），是否所有 xPNTs 都 auto-approve **同一个** facilitator？

**真实风险**：
- Community A 的 admin 不希望 community B 的 facilitator 操作 A 的 xPNTs
- 但当前模型如果是单 facilitator，A 没有选择权

**澄清需求**：
- xPNTs 部署时由 community 选择 trust 哪些 facilitator？还是 SP 协议层默认？
- 如果协议默认，需要"opt-out"机制

**实施建议**：xPNTs deploy 参数加 `address[] approvedFacilitators`，community 自主指定。

#### Concern 4：单笔上限的语义 ⚠️ **MEDIUM**

**当前**：`MAX_SINGLE_TX_LIMIT = 5000 ether ($100 @ $0.02/aPNTs)`

**问题**：
- 这是 single-tx 上限，但 facilitator 可以**连续**调用 → 一笔 $100，10 笔 $1000，100 笔 $10000
- 是否需要 daily / per-user-per-day 累计上限？

**建议**：
- 加 `mapping(address => uint256) public spentToday[user]`，每日上限可配置（默认 $500/day/user）
- 或者：facilitator 每笔必须递增 nonce + 时间戳验证（已有 `x402SettlementNonces`，但未限速）

#### Concern 5：用户主动 revoke 路径 ⚠️ **LOW**

**问题**：用户能不能 `approve(facilitator, 0)` revoke？xPNTs auto-approve 是绕过标准 ERC20 approve 的，标准 revoke 可能无效。

**修复**：xPNTs 需提供 `userOptOutAutoApprove(facilitator)` 函数 + UI 入口，让担心的用户可以退出。

### 实施动作

| 优先级 | 动作 | 时间 |
|---|---|---|
| **P0** | settleX402PaymentDirect 加 `require(xPNTsFactory.isXPNTs(asset))` | 30 分钟 |
| **P0** | 审计 `addAutoApprovedSpender` / `removeAutoApprovedSpender` 权限 | 1 天 |
| **P1** | xPNTs 部署参数加 `approvedFacilitators` 数组 | 2 天 |
| **P1** | 加 daily-cap 累计限额 | 1 天 |
| **P2** | 加 `userOptOutAutoApprove` | 1 天 |
| **P3** | SDK 文档明确"USDC → EIP-3009 path / xPNTs → Direct path"分流 | 半天 |

---

## D5：governance slash 多签门槛 — 并存

### 业务上下文

DVT 全员掉线时无法 slash → operator 跑路风险。需要 governance slash 作为"最后救济"。

### 用户决策

**(c) 二者并存**：标准路径 3-of-5（72h challenge）+ FastTrack 5-of-7（24h timelock）。

### 评估

✅ **赞同**。

类比 Compound governance + Pause Guardian。多签可以 7 人共池：
- 标准路径：3 票发起 + 72h challenge → permissionless execute
- 紧急路径：5 票发起 + 24h timelock → 自动 execute

**实施动作**：
- 实现 `OptimisticGovernanceSlash.sol`（已有设计文档 `2026-04-25-governance-slash-design.md`）
- 多签部署 Safe（5/7 签名集合）
- 与 D5-bis 决策结合

---

## D5-bis（Codex 提出）：Optimistic Governance Slash 是否真的需要？

### 业务上下文

Codex Phase 6 复审：`SuperPaymaster.slashOperator()` 已有 owner 路径，B6-C1c 不算单点失败。如果接受 owner multisig + 7d timelock 即终极治理，可以不做 Optimistic challenge window 那套复杂方案（节省 3 周工期）。

### 用户决策

**未明示**。从 D5 选 (c) 推断：用户接受 Optimistic 模型。

### 我的建议（请用户明示）

**短期建议接受 Codex 的"先 owner multisig + timelock"方向**：
- 1 周可上线，对接 5/7 multisig + 7d timelock（紧急 1d）
- v6.0 升级再做 Optimistic challenge

**理由**：
- 当前没有 mainnet 部署，没有真实跑路案例
- 多签 + timelock 已经能在 DVT 失效时救场
- Optimistic 的去中心化收益在 5/7 multisig 已经足够 trust 时收益边际递减

**❓ 待用户确认**：
- 选 (a)：先 owner multisig + timelock，v6.0 升 Optimistic
- 选 (b)：直接做 Optimistic（按 D5 选的并存方案）

---

## D6：CLOSE_TIMEOUT — (a) immutable

### 业务上下文

MicroPaymentChannel 的 `CLOSE_TIMEOUT = 900s` hardcoded，不同链 block time 差异导致 900s 在 mainnet 是 75 blocks（合理偏长）、L2 上是 450 blocks（过长）。

### 用户决策

**(a) immutable 构造参数**。

### 评估

✅ **赞同**。

**实施动作**：
- 改 `uint256 public immutable CLOSE_TIMEOUT;`
- 构造器接受 `_closeTimeout` 参数
- 部署脚本：mainnet 600s / Optimism 120s / Anvil 30s

---

## D7：sbtHolders → eligibleHolders 重命名

### 业务上下文

`sbtHolders[user]` 实际被任何 role 写入（COMMUNITY/PAYMASTER/ENDUSER/...），但命名误导。

### 用户决策

**(a) 重命名 `eligibleHolders`**，保留语义"任何 role holder 可被赞助"。

### 评估

✅ **赞同**。

**实施动作**：
- `sbtHolders` → `eligibleHolders` 改名（合约 + 接口 + ABI + SDK）
- 注释明确"any role holder qualifies"
- ABI 重新提取并同步 SDK
- CHANGELOG 标记 breaking rename

---

## D8：P0-11 break-glass 修复 — (b) 收紧 + 不禁用

### 业务上下文

Chainlink 失效场景（mainnet outage / 攻击者污染 oracle）。我的原方案是"拒绝交易"，Codex REFINE："在最需要 break-glass 的时候反而禁用 break-glass"。

### 用户决策

**(b) 收紧 + 不禁用**。具体：
- Owner-only 紧急 setPrice 路径
- Timelock（紧急时 1h，平时 7d）
- 价格变动 ±20% 上下界
- 事件强通知（Slack webhook）

### 评估

✅ **完全赞同 Codex + 用户的判断**。

**实施动作**：

| 控制 | 实施 |
|---|---|
| Owner-only 紧急 path | `function emergencySetPrice(uint256 newPrice) onlyOwner` |
| 双 timelock | `mapping(uint256 => uint256) emergencyQueuedAt`，紧急 1h / 平时 7d |
| ±20% 上下界 | `require(newPrice >= cachedPrice * 80/100 && newPrice <= cachedPrice * 120/100)` |
| 事件通知 | `emit EmergencyPriceQueued / Executed` + 部署 webhook listener |
| 状态机 | `enum PriceMode { CHAINLINK, EMERGENCY }`，进入 EMERGENCY 后必须显式退出 |

**注意**：
- "紧急" 触发条件需要明确：Chainlink updatedAt 超过 N 小时？还是手动判断？
- 推荐：自动判断（updatedAt > 1 hour 自动允许 emergencySetPrice），但 setPrice 仍需 owner

---

## 整体评估

### 用户决策的优点

1. **D3 Code Launch 模型**：比我提的 GToken 质押模型更贴合"AAStar 社区 utility token"定位，承认服务承诺约束，监管定位清晰
2. **D4 反驳**：UX 优先的判断是对的；对 xPNTs 的 auto-approve 机制有信心是基于代码已有的 firewall + $100 上限
3. **D8 接受 Codex**：表现出愿意根据更优论证调整自己原决策的成熟度

### 需要澄清的问题

1. **D3 Code Launch 的两个细节**（mint 频率、锚定价格）需要在销售合约设计文档里展开
2. **D3 第 4 项**：aPNTs 是否允许 operator 间二级流通？（影响合约设计）
3. **D5-bis**：是否接受 Codex 的"先 owner multisig + timelock，v6.0 升 Optimistic"建议？

### 风险评估

经过用户决策，**P0 列表预计调整**：

| 原 P0 | 新状态 |
|---|---|
| P0-13 (x402 Direct path 漏洞) | 拆为 P0-13a (asset 白名单) + P1-13b/c/d (auto-approve / cross-community / daily cap) |
| P0-15 (Agent sponsorship daily cap 截断) | **删除**（D1 删除整个功能） |
| P0-3 (B6-C1c slash 单点) | 降为 P1（D5-bis 选 (a) 后只需 multisig + timelock） |
| P0-11 (Chainlink break-glass) | 保留 P0，方向调整为"收紧不禁用" |

**预计 P0 数量**：从 19-21 调整到 **15-17**（取决于 D5-bis）。

---

## 建议的下一步

按 review.md §6.E 的方法学指引（Codex 强调）：**修复前先建威胁模型 + invariant 测试基础设施**。

### 第 1 步：写威胁模型（建议 1-2 天）

**输出文件**：`docs/security/2026-04-26-threat-model.md`

**内容**：
1. **Trust assumption 显式列表**：
   - Owner multisig（5/7）—— trust
   - DVT validator quorum —— partial trust
   - Chainlink oracle —— partial trust（D8 已加 fallback）
   - xPNTs factory —— trust（D4 引入 isXPNTs 后强制中心化白名单）
   - x402 facilitator —— bounded trust（受 firewall + tx limit 约束）
2. **每个 P0 重新评分**：根据 trust 假设，区分"安全 bug"（违背 trust 边界）vs"治理风险"（信任假设之内的中心化）
3. **Attacker 模型**：
   - External：恶意 user / 公开调用者
   - Operator：注册 operator 滥用
   - Validator：DVT 内部恶意
   - Multisig：5/7 中 N 人合谋
4. **失效场景表**：每个失效点的可探测性 / 可恢复性 / 经济损失上限

### 第 2 步：建 invariant 测试基础设施（建议 3-5 天）

**目标**：用 Echidna long-run 覆盖 Codex 强调的 4 个状态机/账目断裂高风险点：
1. `Registry.roleStakes ↔ GTokenStaking.roleLocks` 一致性
2. SP `protocolRevenue + Σ aPNTsBalance + inflight` 守恒
3. `x402SettlementNonces` replay map 单调性
4. price timestamp monotonicity（防 D8 + B-N1 future timestamp）

**输出文件**：`contracts/test/v3/invariants/*.t.sol` + `echidna-invariants.yaml`

### 第 3 步：开始 fix execution（建议按 review.md §5.5 Wave 1-5 顺序）

经 D1-D8 决策调整后的执行顺序：

**Wave 1 — Consensus & Stake**（DVT/BLS）
- B6-C1a/C1b/C2 → BLS 真实验签 + validator stake gating + proposalId 防预占
- D5 + D5-bis：确认后实施 governance slash

**Wave 2 — Funds & Price**（资金安全）
- D8：Chainlink break-glass 收紧
- D4 P0：settleX402PaymentDirect 加 isXPNTs 白名单
- B-N1：future timestamp guard
- xPNTs auto-approve 审计

**Wave 3 — Cleanup**（D1 / D2）
- 删除 Agent sponsorship 整套
- 删除 EIP-1153 文档

**Wave 4 — Refactor**（D6 / D7 + D3 设计）
- CLOSE_TIMEOUT immutable 化
- sbtHolders → eligibleHolders 重命名
- D3 Code Launch 销售合约**设计文档**（实施延后到 v6.0）

**Wave 5 — P1 + 测试 + 文档**

### 时间估算

| 阶段 | 时间 |
|---|---|
| Step 1 威胁模型 | 1-2 天 |
| Step 2 invariant 基础设施 | 3-5 天 |
| Wave 1 (consensus) | 1-2 周 |
| Wave 2 (funds) | 1 周 |
| Wave 3 (cleanup) | 2 天 |
| Wave 4 (refactor + D3 design) | 1 周 |
| Wave 5 (P1 + tests) | 1-2 周 |
| Codex Tier 1 复审 | 1-2 天 |
| **合计** | **6-8 周** |

---

## 待用户回复的开放问题

1. **D5-bis**：先 owner multisig + timelock（1 周），v6.0 升 Optimistic？还是直接做 Optimistic（3 周）？
2. **D3 第 4 项**：aPNTs 是否允许 operator 间二级流通？
3. **D3 锚定价格**：基础锚定价 $0.02/aPNTs 是否合理？依据是？
4. **D4 Concern 3**：xPNTs deploy 时的 `approvedFacilitators` 数组，由 community 自主指定还是 SP 协议层默认？
5. **威胁模型 Step 1**：是否同意先做威胁模型再写代码？还是优先 Wave 1 的 BLS/DVT 修复？

---

## 用户最终回复（2026-04-26 第二轮）

针对文档末尾"待用户回复的开放问题"5 项，用户已逐一明示：

### Q1：D5-bis → 选 (a)

**用户原文**：
> "推荐：(a) 先 owner multisig + timelock。Codex 的判断是对的——现有 owner 路径已经能救场，先不做 Optimistic 那套。但必须明确写入路线图：v6.0 升级 Optimistic Slash。用你的建议。"

**结论**：先 owner 5/7 multisig + timelock（紧急 1d / 平时 7d），v6.0 升 Optimistic Governance Slash。

**对 P0 的影响**：P0-3（B6-C1c slash 单点）**降为 P1**。SP.slashOperator() 已存在，配 multisig + timelock 即可救场。

**路线图必修条目**：
- v5.4 / v5.5：implement owner multisig governance slash + timelock
- v6.0：implement Optimistic Governance Slash with challenge window

### Q2：D3 二级流通 → 不提供

**用户原文**：
> "目前不提供二级市场交易，只有社区提供的销售合约入口。未来看情况，大概率不会，因为价格区域稳定 + 小幅波动和提升（因为服务成本上涨）。"

**结论**：aPNTs **设计为非可转移 / 仅协议内分发与消耗**。
- Mint 路径：仅 `aPNTsSaleContract`（多签控制）
- Transfer 路径：仅"协议内"（SP 内部 aPNTsBalance 调整 / sale → operator / operator → user via xPNTs / SP 销毁）
- **P2P transfer 关闭**

**对合约设计影响**：
- aPNTs 不实现标准 ERC20 `transfer` / `transferFrom`（或 `transfer` 限定为 sale → operator 路径）
- 替代：实现 internal `_distribute` / `_consume` 函数，仅 `aPNTsSaleContract` / `SuperPaymaster` 可调
- 防止 operator 之间私下倒卖 aPNTs 配额（= 防止"配额二级市场"）

### Q3：D3 锚定价格 → "计价单位"论

**用户原文**：
> "实际上定价并不是具体的 point，而是基于 point 来定价我们的服务。比如说我提供的服务，他只是计价单位。所以锚定什么价格只是单位的大小，跟锚定是否合理实际上没有直接关系，而是由我们锚定的服务来决定的。比如说我帮用户提供这种针对指定合约的赞助服务（游戏类的 dApp），他希望赞助用户使用，那我收多少个这个价格合适呢？根据市场价再折算成 aPNTs。换句话说，我们提供的是服务，服务绑定了 aPNTs，这个服务肯定是根据市场价来计的。所以 aPNTs 锚定什么价格只是单位大小的力度不同。"

**评估**：✅ **论证清晰且对**。我之前问错了问题。aPNTs 不是"价值"对象，是"计量"对象。$0.02 / aPNTs 是单位粗细（类似 1 元 vs 1 分钱），与服务实际价值无关。重要的是：

1. **服务本身按市场价定价** → 折算成 aPNTs
2. **operator 收 N 个 aPNTs 是基于服务的市场价 × 单位换算**
3. **多签 mint 数量基于 AAStar 的服务能力** → 控制总供给
4. **市场价格小幅浮动**反映服务成本变化（gas 费上涨等）

**对合约设计影响**：
- aPNTs 不需要"价格预言机"
- aPNTsSaleContract 销售时，**接受 token 的兑换比例**才是价格机制（e.g., 1 USDC = 50 aPNTs，但 1 aPNTs ≠ $0.02 in any other context）
- 文档化重点：**aPNTs 是 unit of account，不是 store of value**

### Q4：D4 approvedFacilitators → 社区多签指定

**用户原文**：
> "由社区多签来指定。目前是每个社区可以部署自己的 facilitator，也可以使用其他社区的（需要是 xPNTs）。AAStar 提供的只是一个可选。"

**结论**：xPNTs deploy 时，由 community owner（多签）指定 trusted facilitators 列表：
- Default：AAStar 协议提供的 facilitator（可选，不强制）
- Community 可部署自己的 facilitator
- Community 可使用其他社区的 facilitator（前提：是 xPNTs 协议兼容的）

**对合约设计影响**：

```solidity
// xPNTsFactory.deployToken(...) 增加参数
function deployToken(
    string communityName,
    string communityENS,
    uint256 exchangeRate,
    address[] calldata initialApprovedFacilitators  // ← 新增
) external returns (address);

// xPNTsToken
mapping(address => bool) public approvedFacilitators;  // 取代/增强 autoApprovedSpenders
function addApprovedFacilitator(address f) external onlyCommunityMultisig;
function removeApprovedFacilitator(address f) external onlyCommunityMultisig;

// settleX402PaymentDirect
require(xPNTsFactory.isXPNTs(asset), "Direct path: asset must be xPNTs");
require(IXPNTsToken(asset).approvedFacilitators(msg.sender), "facilitator not approved by community");
```

**注意**：autoApprovedSpenders 的现有 firewall（"只能转给自己或 SP"）+ MAX_SINGLE_TX_LIMIT 仍然保留，新模型是在其基础上再加一层 community-controlled facilitator 白名单。

### Q5：威胁模型先行 → 同意

**用户决策**：先做威胁模型 → review → 确认后再开始写代码。

**下一步**：现在开始写 `docs/security/2026-04-26-threat-model.md`，独立文档，写完后用户 review。

---

## P0 列表更新（基于第二轮决策）

| 原 P0 | 决策影响 | 新状态 |
|---|---|---|
| P0-3 (B6-C1c slash 单点) | D5-bis (a) | **降为 P1**（multisig + timelock 即可） |
| P0-13 (X402 Direct path) | D4 multi-facilitator | **保留 P0**，分子项：P0-13a (asset 白名单)、P0-13b (community facilitator 白名单) |
| P0-14 (Owner-slash cap) | D5-bis (a) | **保留 P0**（multisig 仍需 cap，但 cap 形式可改为 challenge window） |
| P0-15 (Agent sponsorship) | D1 删除 | **删除整个 feature**，不再列入 P0 |
| P0-11 (Chainlink break-glass) | D8 (b) | **保留 P0**，方向调整为"收紧 + 不禁用" |
| Codex P0-19 (B-N1 future timestamp) | 无关 | 保留 P0 |
| Codex P0-20 (B-N5 proposalId pre-poison) | 无关 | 保留 P0 |
| Codex P0-21 (D8 emergency setPrice 路径) | D8 (b) | 合并到 P0-11 |

**预计 P0 数量**：从 19-21 → **15-17 项**（P0-3 降级 / P0-15 删除 / P0-21 合并 → -3；P0-13 拆分 → +1）

---

## 修订记录

- 2026-04-26 (initial): 用户对 D1-D8 9 个决策点逐一答复；本文档记录决策 + 业务上下文 + 评估 + 下一步
- 2026-04-26 (第二轮): 用户对 5 个开放问题逐一明示；P0 列表预计调整（19-21 → 15-17）；威胁模型先行确认
