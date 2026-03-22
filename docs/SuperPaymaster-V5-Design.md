# SuperPaymaster V5 Design Document

> Version: 0.6.0 | Date: 2026-03-22 | Branch: `feature/micropayment`
>
> **相关文档**：
> - [V5 Roadmap（版本规划与商业分析）](V5-Roadmap.md)
> - [AI Agent 支付、x402、ERC-8004 深度研究](research-agent-x402-micropayment.md)
> - [AA 历史与 Native AA 研究](research-aa-history-and-native-aa.md)
> - [AA 钱包演进研究](research-aa-wallets-evolution.md)

---

## 一、要解决什么问题？

当前 SuperPaymaster **只有一个入口**：EIP-4337 的 `validatePaymasterUserOp` + `postOp`。这意味着：

1. **只能为 UserOperation 付 Gas** — 无法为非 ERC-4337 场景（Agent 调用 API、x402 付费资源、链上高频微交易）提供支付能力
2. **计费逻辑与 EIP-4337 深度耦合** — `postOp` 内硬编码了 Gas→aPNTs 换算、protocol fee、debt 记录，无法复用
3. **不支持未来 Native AA** — EIP-7702 让 EOA 获得了智能合约能力，EIP-8141 Frame Transaction 将彻底改变 AA 交互方式，当前架构无法适配
4. **AI Agent 经济的支付空白** — Agentic Economy 预计 2030 年 3-5 万亿美元，Agent 需要按次/按量付费，但链上缺乏标准化微支付基础设施

## 二、要做什么 Feature？

核心：**从 SuperPaymaster 中抽取通用计费内核，并开放多入口支付能力。**

| Feature | 说明 |
|---------|------|
| **`_consumeCredit()`** | 从 `postOp` 中提取的纯计费函数，只关心 "谁、通过谁、花了多少 USD 等值" |
| **`chargeMicroPayment()`** | 新增 public 方法，接受 EIP-712 签名，为非 4337 场景提供微支付 |
| **`postOp` 重构** | 原有 4337 逻辑保持兼容，内部调用 `_consumeCredit()` |
| **EIP-1153 批量优化** | 多笔 UserOp 在同一交易中使用 transient storage 累积计费，最终只写一次 storage |
| **EIP-7702 兼容** | EOA 通过 7702 委托后可直接使用微支付，无需部署智能账户 |

## 三、架构改动

### 关键约束：Registry 不能改代码

Registry 是 UUPS proxy，理论上可以升级，但我们选择不动它。原因：
- Registry 管理的是角色/社区/质押，已经稳定
- 微支付是 SuperPaymaster 的职责，不应污染 Registry
- 减少升级风险

### 改动范围：仅 SuperPaymaster（UUPS 升级）

```
┌─────────────────────────────────────────────────────┐
│                SuperPaymaster v5.0.0                │
│                                                     │
│  ┌───────────────────────────────────────────────┐  │
│  │        _consumeCredit() ← 计费内核            │  │
│  │  (user, operator, usdAmount) → 扣余额+记债务  │  │
│  └──────────────────┬────────────────────────────┘  │
│          ┌──────────┼──────────┐                    │
│          │          │          │                    │
│  ┌───────▼──┐  ┌────▼────┐  ┌─▼──────────┐        │
│  │ postOp   │  │ charge  │  │ Future:    │        │
│  │(EIP-4337)│  │ Micro   │  │ EIP-8141   │        │
│  │          │  │ Payment │  │ Native AA  │        │
│  │ 不变，   │  │ (新增)  │  │ (预留)     │        │
│  │ 内部调用 │  │ EIP-712 │  │            │        │
│  │ _consume │  │ 签名    │  │            │        │
│  └──────────┘  └─────────┘  └────────────┘        │
│                                                     │
│  不依赖 Registry 新函数，                            │
│  只读取已有的: sbtHolders, operators, userOpState   │
└─────────────────────────────────────────────────────┘
```

### 具体改动：

**1. SuperPaymaster.sol（升级 implementation）**
- 提取 `_consumeCredit()` internal 函数（从 `postOp` 中剥离）
- 新增 `chargeMicroPayment(operator, user, usdAmount, nonce, deadline, signature)` external 方法
- 新增 EIP-712 domain separator + 微支付签名验证
- 新增 `microPaymentNonces` mapping 防重放
- `postOp` 改为调用 `_consumeCredit()` — **外部行为零变化**

**2. ISuperPaymaster.sol（接口扩展）**
- 新增 `chargeMicroPayment` 接口定义
- 新增事件 `MicroPaymentCharged`

**3. 不改动的合约：**
- Registry — 不动
- GTokenStaking — 不动
- MySBT — 不动
- xPNTsToken — 不动（debt 记录机制已有）
- xPNTsFactory — 不动

**部署方式**：对已部署的 SuperPaymaster proxy 执行 `upgradeToAndCall(newImpl, "")`，代理地址不变，所有 operator 配置/余额/状态完整保留。

---

## 四、x402 协议集成

### 4.1 x402 协议概述

x402 是由 **Coinbase** 于 2025 年 5 月推出的互联网原生支付开放标准，复活了长期闲置的 HTTP 402 "Payment Required" 状态码，将支付嵌入 HTTP 协议本身。2025 年 9 月 Coinbase 与 Cloudflare 联合成立 x402 Foundation，Google 和 Visa 随后加入。截至 2026 年 3 月已处理超过 **1 亿笔**支付。

**四角色模型**：

```
┌─────────┐     HTTP Request      ┌─────────────────┐
│  Client  │ ──────────────────►  │  Resource Server │
│ (Agent)  │ ◄──────────────────  │  (API Provider)  │
│          │   402 + Requirements  │                  │
│          │ ──────────────────►  │                  │
│          │   Request + Payment   │                  │──┐
│          │ ◄──────────────────  │                  │  │ verify
│          │   200 + Resource      │                  │  │ + settle
└─────────┘                       └─────────────────┘  │
                                         │              │
                                         ▼              │
                                  ┌──────────────┐     │
                                  │  Facilitator  │ ◄──┘
                                  │ (验证+结算)    │
                                  └──────┬───────┘
                                         │
                                         ▼
                                  ┌──────────────┐
                                  │  Blockchain   │
                                  │ (Base/Solana) │
                                  └──────────────┘
```

**支付流程**：Client 请求资源 → Server 返回 402 + 价格要求 → Client 签名支付 → Server 通过 Facilitator 验证+结算 → 返回资源。全程无需账户系统，钱包签名即身份。

**V2 关键升级**（2026 年 2 月）：
- **传输无关**：从 HTTP-only 扩展到支持 MCP、A2A 等任意传输协议
- **模块化支付方案**：支持 ACH、SEPA、信用卡等非加密支付
- **生命周期钩子**：`before_payment → payment_execution → after_payment` 可注入自定义逻辑

### 4.2 SuperPaymaster 如何原生支持 x402

Coinbase 已在 GitHub 上提出 **x402 + ERC-4337 集成提案**（Issue #639）。SuperPaymaster 可以从两个维度原生支持 x402：

#### 维度 A：SuperPaymaster 作为 x402 Facilitator

SuperPaymaster 天然适合担任 x402 的 Facilitator 角色——验证支付并执行结算：

```
x402 PaymentRequired → Agent 签名 → SuperPaymaster 验证 + _consumeCredit() → 结算
```

具体映射：

| x402 Facilitator 职责 | SuperPaymaster 对应能力 |
|----------------------|----------------------|
| **verify**: 验证支付签名有效性 | EIP-712 签名验证（`chargeMicroPayment` 已实现） |
| **settle**: 执行链上结算 | `_consumeCredit()` 扣减 operator 余额 + 记录 debt |
| **balance check**: 检查付款方余额 | `operators[].aPNTsBalance` 查询 |
| **price conversion**: 金额换算 | Chainlink oracle + `_calculateAPNTsAmount()` |

**新增合约接口**：

```solidity
/// @notice x402 Facilitator: verify payment validity (view, no state change)
function verifyX402Payment(
    address operator,
    address user,
    uint256 usdAmount,
    uint256 nonce,
    uint256 deadline,
    bytes calldata signature
) external view returns (bool valid, string memory reason);

/// @notice x402 Facilitator: settle payment (state change)
/// Internally calls _consumeCredit()
function settleX402Payment(
    address operator,
    address user,
    uint256 usdAmount,
    uint256 nonce,
    uint256 deadline,
    bytes calldata signature
) external returns (bytes32 txHash);
```

这两个函数本质上是 `chargeMicroPayment()` 的拆分版本，符合 x402 Facilitator 的 verify/settle 两步模型。

> **注意**：上述接口处理的是 **aPNTs/xPNTs 路径**（Operator 余额内结算）。对于 **USDC 等外部稳定币**的 x402 标准结算路径（EIP-3009 `transferWithAuthorization` / Permit2），详见 [V5 Roadmap V5.2 章节](V5-Roadmap.md)。两种路径互补：xPNTs 路径在 V5.1 即可实现，USDC 路径在 V5.2 新增。

#### 维度 B：x402 作为 Operator 充值入口

社区 Operator 可以通过 x402 收取服务费用，收入自动转化为 aPNTs 存入 SuperPaymaster：

```
用户 → x402 支付 USDC → Operator 的 x402 Server → 自动 swap USDC→aPNTs → deposit() → SuperPaymaster
```

这使得 Operator 的 Gas 代付资金可以通过 x402 服务收入自动补充，形成闭环经济。

#### 维度 C：混合模式（推荐架构）

```
                    ┌──────────────┐
                    │   x402 Layer │  (服务付费：API调用、数据、计算)
                    │  HTTP 402    │
                    └──────┬───────┘
                           ▼
┌─────────┐     ┌──────────────────┐     ┌──────────────┐
│  Agent   │ ──►│  SuperPaymaster  │ ──► │  EntryPoint  │
│ (Smart   │     │  (Gas 代付 +     │     │  (ERC-4337)  │
│ Account) │ ◄──│   xPNTs 结算)    │ ◄── │              │
└─────────┘     └──────────────────┘     └──────────────┘
```

**x402 处理应用层支付**（Agent 为服务付费），**SuperPaymaster 处理基础层支付**（社区为用户/Agent 代付 Gas）。两者互补而非竞争。SuperPaymaster 的独特价值在于：它是唯一专注于**社区化 Gas 代付**的协议。

### 4.3 x402 集成的合约改动

| 改动 | 说明 |
|------|------|
| `verifyX402Payment()` | 新增 view 函数，x402 Facilitator verify 端点 |
| `settleX402Payment()` | 新增 external 函数，内部调用 `_consumeCredit()` |
| EIP-712 typehash | 新增 `X402_PAYMENT_TYPEHASH`（与 `MICROPAYMENT_TYPEHASH` 共享签名验证逻辑） |

**不需要改动 Registry**：x402 集成完全在 SuperPaymaster 内部完成，只读取 Registry 已有的 `sbtHolders`、`operators` 数据。

---

## 五、ERC-8004 集成

### 5.1 ERC-8004 "Trustless Agents" 概述

ERC-8004 于 2025 年 8 月提出，2026 年 1 月在以太坊主网上线，是 AI Agent 链上信任基础设施的核心标准。作者包括来自 MetaMask、Ethereum Foundation、Google、Coinbase 的核心开发者。

**设计理念**：区块链作为**控制平面（Control Plane）**，身份和信任信号在链上，细节数据（Agent 描述、能力等）在链下。

**三大注册表**：

```
┌─────────────────────────────────────────────────────────┐
│                    ERC-8004 Layer                        │
│                                                          │
│  ┌──────────────┐  ┌───────────────┐  ┌──────────────┐  │
│  │   Identity    │  │  Reputation   │  │  Validation  │  │
│  │  Registry     │  │   Registry    │  │  Registry    │  │
│  │  (ERC-721)    │  │  (Feedback)   │  │  (Req/Resp)  │  │
│  │              │  │              │  │              │  │
│  │ register()   │  │ giveFeedback()│  │ validation   │  │
│  │ setMetadata()│  │ getSummary() │  │ Request()    │  │
│  │ getMetadata()│  │ revoke       │  │ Response()   │  │
│  │              │  │ Feedback()   │  │              │  │
│  └──────────────┘  └───────────────┘  └──────────────┘  │
│                                                          │
│  已部署在 40+ 链（确定性地址）:                             │
│  Identity:   0x8004A169...                               │
│  Reputation: 0x8004BAa1...                               │
│  Validation: 0x8004CbB2...                               │
└─────────────────────────────────────────────────────────┘
```

**关键特性**：
- **Identity Registry**：基于 ERC-721，每个 Agent 获得全局唯一 ID = `eip155:{chainId}:{registryAddress}:{agentId}`
- **Reputation Registry**：带预授权的标准化反馈（0-100 评分 + tag 分类），防垃圾机制（预授权 + 索引限制 + 过期）
- **Validation Registry**：灵活的第三方验证（支持 Stake-backed Re-execution、zkML、TEE Attestation、Governance Review）

**关键设计决策**：ERC-8004 **刻意将支付排除在范围之外**，采用正交设计。身份/信誉层（ERC-8004）与支付层（x402 / Paymaster）解耦，通过 `supportedTrust` 字段声明关联。

### 5.2 SuperPaymaster 如何原生支持 ERC-8004

#### 5.2.1 Agent 身份验证集成

SuperPaymaster 可以在 `validatePaymasterUserOp` 和 `chargeMicroPayment` 中查询 ERC-8004 Identity Registry，验证调用方是否为注册 Agent：

```solidity
// ERC-8004 Identity Registry interface (read-only)
interface IAgentIdentityRegistry {
    function ownerOf(uint256 agentId) external view returns (address);
    function getMetadata(uint256 agentId, string calldata key) external view returns (bytes memory);
}

/// @notice Check if an address is a registered ERC-8004 agent
function isRegisteredAgent(address account) public view returns (bool) {
    // Query ERC-8004 Identity Registry at deterministic address
    // Returns true if account owns at least one agent NFT
}
```

**不修改 Registry 合约**：Agent 身份查询是直接调用 ERC-8004 在链上已部署的合约（确定性地址），不需要在我们的 Registry 中添加任何代码。

#### 5.2.2 信誉驱动的 Gas 赞助策略

结合 ERC-8004 Reputation Registry 和我们已有的 ReputationSystem，实现信誉驱动的差异化赞助：

```
Agent Reputation Score (ERC-8004)
        +
Community Reputation Score (ReputationSystem)
        ↓
┌─────────────────────────────────┐
│   Dynamic Sponsorship Policy    │
│                                 │
│  高信誉 Agent: 100% Gas 赞助    │
│  中信誉 Agent: 50% Gas 赞助     │
│  低/无信誉:    需自付 Gas        │
└─────────────────────────────────┘
```

**新增合约接口**：

```solidity
/// @notice Set ERC-8004 registry addresses (owner only, one-time config)
function setAgentRegistries(
    address identityRegistry,
    address reputationRegistry
) external onlyOwner;

/// @notice Query agent reputation from ERC-8004 and apply sponsorship policy
function getAgentSponsorshipRate(
    uint256 agentId,
    address operator
) external view returns (uint256 sponsorshipBPS);
```

#### 5.2.3 DVT 作为 ERC-8004 Validation Bridge

我们已有的 DVT（Distributed Validator Technology）可以注册为 ERC-8004 Validation Registry 的验证者，将 SuperPaymaster 的 slash/reputation 数据暴露给整个 ERC-8004 生态：

```
DVTValidator ──注册为──► ERC-8004 Validation Registry
     │                           │
     │  slash/reputation 数据     │  第三方可查询
     ▼                           ▼
SuperPaymaster               其他 Agent 系统
```

这使得 SuperPaymaster 的 Operator 信誉数据成为更大 Agent 生态信任网络的一部分。

#### 5.2.4 Gas 赞助反馈上链

每次 SuperPaymaster 成功赞助一笔交易，可以向 ERC-8004 Reputation Registry 提交正向反馈，累积 Agent 的链上信誉：

```solidity
// In _consumeCredit() or postOp():
// After successful gas sponsorship, submit feedback to ERC-8004
IAgentReputationRegistry(reputationRegistry).giveFeedback(
    agentId,        // Agent who received sponsorship
    90,             // High score for successful tx
    "gas-sponsor",  // tag1: category
    "success",      // tag2: subcategory
    "",             // No off-chain context needed
    bytes32(0),     // No file hash
    feedbackAuth    // Pre-authorized signature
);
```

### 5.3 ERC-8004 集成的合约改动

| 改动 | 说明 |
|------|------|
| `agentIdentityRegistry` 状态变量 | 存储 ERC-8004 Identity Registry 地址 |
| `agentReputationRegistry` 状态变量 | 存储 ERC-8004 Reputation Registry 地址 |
| `setAgentRegistries()` | owner-only 配置函数 |
| `isRegisteredAgent()` | view 函数，查询 Agent 身份 |
| `getAgentSponsorshipRate()` | view 函数，计算信誉驱动的赞助比例 |
| `_consumeCredit()` 内可选反馈 | 赞助成功后向 Reputation Registry 提交反馈 |

**不需要改动 Registry**：所有 ERC-8004 交互都是 SuperPaymaster 直接调用已部署的标准合约。

---

## 六、综合架构

### 6.1 四层协议栈

基于 x402 + ERC-8004 研究，SuperPaymaster v5.0 在 Agent Economy 中的定位清晰为**四层协议栈**：

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 4: Identity & Trust (身份信任层)                       │
│  ERC-8004 Identity + Reputation + Validation                │
│  → Agent 身份验证、信誉评分、行为验证                          │
└────────────────────────┬────────────────────────────────────┘
                         │ 查询信誉 → 决定赞助策略
┌────────────────────────▼────────────────────────────────────┐
│  Layer 3: Service Payment (应用支付层)                        │
│  x402 Protocol + Google AP2 + Stripe MPP                    │
│  → Agent 为 API/数据/计算付费                                 │
└────────────────────────┬────────────────────────────────────┘
                         │ x402 Settlement → _consumeCredit()
┌════════════════════════▼════════════════════════════════════┐
║  Layer 2: Gas Sponsorship (Gas 代付层) ← SuperPaymaster     ║
║                                                              ║
║  ┌────────────────────────────────────────────────────┐      ║
║  │           _consumeCredit() ← 统一计费内核            │      ║
║  │     (user, operator, usdAmount) → 扣余额+记债务      │      ║
║  └──────┬──────────┬──────────┬──────────┬────────────┘      ║
║         │          │          │          │                    ║
║  ┌──────▼──┐ ┌─────▼────┐ ┌──▼────┐ ┌───▼──────┐           ║
║  │ postOp  │ │ charge   │ │ x402  │ │ Future:  │           ║
║  │(EIP-4337│ │ Micro    │ │Settle │ │ EIP-8141 │           ║
║  │ 不变)   │ │ Payment  │ │ ment  │ │ Native   │           ║
║  │         │ │(EIP-712) │ │       │ │ AA       │           ║
║  └─────────┘ └──────────┘ └───────┘ └──────────┘           ║
║                                                              ║
║  ERC-8004 查询: isRegisteredAgent() → 差异化赞助              ║
║  Oracle 定价: Chainlink + aPNTs/xPNTs 汇率                   ║
║  Debt 追踪: xPNTsToken.recordDebt() (已有)                   ║
╚══════════════════════════════════════════════════════════════╝
                         │
┌────────────────────────▼────────────────────────────────────┐
│  Layer 1: Settlement (结算层)                                │
│  Ethereum / Base / Optimism / Arbitrum                       │
│  → 最终链上结算                                               │
└─────────────────────────────────────────────────────────────┘
```

### 6.2 SuperPaymaster v5.0 完整改动清单

| # | 改动 | 类型 | 依赖 |
|---|------|------|------|
| 1 | 提取 `_consumeCredit()` internal | 重构 | 无 |
| 2 | `postOp` 调用 `_consumeCredit()` | 重构 | #1 |
| 3 | `chargeMicroPayment()` + EIP-712 | 新增 | #1 |
| 4 | `microPaymentNonces` mapping | 新增 | #3 |
| 5 | `verifyX402Payment()` view | 新增 | #3（共享签名逻辑） |
| 6 | `settleX402Payment()` external | 新增 | #1 |
| 7 | `setAgentRegistries()` owner-only | 新增 | 无 |
| 8 | `isRegisteredAgent()` view | 新增 | #7 |
| 9 | `getAgentSponsorshipRate()` view | 新增 | #7, #8 |
| 10 | EIP-1153 batch optimization | 优化 | #1 |
| 11 | EIP-7702 delegated EOA 支持 | 兼容 | #3 |
| 12 | 事件: `MicroPaymentCharged`, `X402PaymentSettled` | 新增 | #3, #6 |

**不改动的合约**：Registry, GTokenStaking, MySBT, xPNTsToken, xPNTsFactory — 全部零改动。

### 6.3 版本演进路线

```
Phase 1 (当前 v4.x):
  SuperPaymaster ← ERC-4337 ← xPNTs/aPNTs
  [社区 Gas 代付基础设施]

Phase 2 (v5.0 ← 本次升级):
  SuperPaymaster ← ERC-4337 + chargeMicroPayment + x402 Facilitator
  + ERC-8004 Identity/Reputation 查询
  [Agent-aware Gas 代付 + 微支付网关]

Phase 3 (v6.0 未来):
  SuperPaymaster Network ← Multi-chain (LayerZero/CCIP)
  + Google AP2 Mandate + Stripe MPP Session
  + Streaming Gas (Superfluid)
  [跨链 Agent Economy 基础设施]
```

### 6.4 部署策略

1. 编写新的 SuperPaymaster v5 implementation 合约
2. 运行完整 Foundry 测试套件（含新增微支付/x402/ERC-8004 测试）
3. 对已部署 proxy 执行 `upgradeToAndCall(newImpl, "")`
4. 调用 `setAgentRegistries()` 配置 ERC-8004 注册表地址
5. 验证所有现有功能不受影响（postOp、operator config、pricing 等）

代理地址不变，所有 operator 配置、余额、状态完整保留。

---

## 七、实施关键细节

### 7.1 `_consumeCredit()` 精确提取方案

#### 当前 `postOp` 逐步分解（v4.1.0, 行 817-879）

| 步骤 | 当前代码 | V5 归属 | 原因 |
|------|---------|---------|------|
| 1 | `abi.decode(context)` — 解码 token, estimatedXPNTs, user, initialAPNTs, userOpHash, operator | **postOp** | ERC-4337 context 格式，其他入口不使用 |
| 2 | Rate limit: `userOpState[operator][user].lastTimestamp = uint48(block.timestamp)` | **postOp** | 防刷攻击，但 chargeMicroPayment 也需要 → 复用 |
| 3 | `if (mode == postOpReverted) return` | **postOp** | ERC-4337 特有的失败模式 |
| 4 | `_calculateAPNTsAmount(actualGasCost, false)` | **postOp** | Gas→aPNTs 转换是 Gas 代付特有逻辑 |
| 5 | Protocol fee markup: `finalCharge = actualAPNTs * (1 + protocolFeeBPS/10000)` | **_consumeCredit()** | 通用计费逻辑 |
| 6 | Refund: `if finalCharge < initialAPNTs → refund excess to operator` | **postOp** | 预授权退款是 ERC-4337 特有（validate 预扣 → postOp 退差） |
| 7 | `operators[operator].aPNTsBalance` 更新 + `protocolRevenue` 更新 | **_consumeCredit()** | 通用余额管理 |
| 8 | `xPNTsToken.recordDebt(user, xPNTsDebt)` + pending fallback | **_consumeCredit()** | 通用债务记录 |

#### 目标接口

```solidity
/// @dev Universal billing kernel
/// @param operator Community operator bearing the cost
/// @param user End user generating the charge
/// @param aPNTsBase Base aPNTs amount (before protocol fee)
/// @param preDeducted True if operator balance was pre-deducted in validation (postOp mode)
function _consumeCredit(
    address operator,
    address user,
    uint256 aPNTsBase,
    bool preDeducted
) internal returns (uint256 finalCharge) {
    OperatorConfig storage config = operators[operator];

    // 1. Apply protocol fee markup
    finalCharge = (aPNTsBase * (BPS_DENOMINATOR + protocolFeeBPS)) / BPS_DENOMINATOR;
    uint256 protocolFee = finalCharge - aPNTsBase;
    protocolRevenue += protocolFee;

    // 2. Deduct from operator (skip for postOp — already deducted in validatePaymasterUserOp)
    if (!preDeducted) {
        if (config.aPNTsBalance < uint128(finalCharge))
            revert InsufficientOperatorBalance();
        config.aPNTsBalance -= uint128(finalCharge);
    }

    // 3. Record debt in xPNTs
    uint256 xPNTsDebt = (finalCharge * config.exchangeRate) / 1e18;
    try IxPNTsToken(config.xPNTsToken).recordDebt(user, xPNTsDebt) {} catch {
        pendingDebts[config.xPNTsToken][user] += xPNTsDebt;
        emit DebtRecordFailed(config.xPNTsToken, user, xPNTsDebt);
    }

    // 4. Update operator stats
    config.totalSpent += uint128(finalCharge);
    config.totalTxSponsored++;

    emit CreditConsumed(operator, user, finalCharge, xPNTsDebt);
}
```

#### 重构后的 postOp

```solidity
function postOp(PostOpMode mode, bytes calldata context, uint256 actualGasCost, uint256 actualUserOpFeePerGas)
    external override onlyEntryPoint nonReentrant
{
    if (context.length == 0) return;
    (address token, uint256 estimatedXPNTs, address user, uint256 initialAPNTs,
     bytes32 userOpHash, address operator) = abi.decode(context, (address, uint256, address, uint256, bytes32, address));

    // Rate limit (UNCHANGED)
    if (operators[operator].minTxInterval > 0) {
        userOpState[operator][user].lastTimestamp = uint48(block.timestamp);
    }
    if (mode == PostOpMode.postOpReverted) return;

    // Gas→aPNTs conversion (UNCHANGED)
    uint256 actualAPNTs = _calculateAPNTsAmount(actualGasCost, false);

    // Refund excess to operator (postOp-specific: validate pre-deducted initialAPNTs)
    if (actualAPNTs < initialAPNTs) {
        uint256 refund = initialAPNTs - actualAPNTs;
        if (refund > type(uint128).max) refund = type(uint128).max;
        if (refund > protocolRevenue) refund = protocolRevenue;
        operators[operator].aPNTsBalance += uint128(refund);
        protocolRevenue -= refund;
    }

    // Delegate to billing kernel (preDeducted=true)
    uint256 chargeBase = Math.min(actualAPNTs, initialAPNTs);
    _consumeCredit(operator, user, chargeBase, true);
}
```

**外部行为验证**：
- 事件：`TransactionSponsored` → `CreditConsumed`（字段等价，可保留旧事件名做兼容 emit）
- Operator balance 变化 → 数学等价
- xPNTs debt 记录 → 完全保留
- 所有 revert 条件 → 不变

### 7.2 Storage Layout 升级规划

#### 当前存储布局（v4.1.0）

```
Slot  Variable                    Type                    Source
────  ────────                    ────                    ──────
0     _owner                      address                 OwnableUpgradeable
1     _status                     uint256                 ReentrancyGuard
2     APNTS_TOKEN                 address                 SuperPaymaster
3     xpntsFactory                address                 SuperPaymaster
4     treasury                    address                 SuperPaymaster
5     operators                   mapping                 SuperPaymaster
6     userOpState                 mapping                 SuperPaymaster
7     sbtHolders                  mapping                 SuperPaymaster
8     slashHistory                mapping                 SuperPaymaster
9     aPNTsPriceUSD               uint256                 SuperPaymaster
10-11 cachedPrice                 PriceCache (struct)     SuperPaymaster
12    protocolFeeBPS              uint256                 SuperPaymaster
13    BLS_AGGREGATOR              address                 SuperPaymaster
14    totalTrackedBalance         uint256                 SuperPaymaster
15    protocolRevenue             uint256                 SuperPaymaster
16    pendingDebts                mapping                 SuperPaymaster
17    priceStalenessThreshold     uint256                 SuperPaymaster
18    oracleDecimals              uint8                   SuperPaymaster
19-66 __gap[48]                   uint256[48]             SuperPaymaster

Immutables (in bytecode): REGISTRY, ETH_USD_PRICE_FEED, entryPoint
Initializable: ERC-7201 namespaced storage (no linear collision)
```

#### 新增变量 — Gap 消耗计划

| 版本 | 新增变量 | 类型 | Gap 消耗 |
|------|---------|------|---------|
| **V5.1** | `microPaymentNonces` | `mapping(address => uint256)` | 1 slot |
| **V5.1** | `_DOMAIN_SEPARATOR` (EIP-712) | `bytes32` | 1 slot |
| **V5.2** | `facilitatorFeeBPS` | `uint256` | 1 slot |
| **V5.2** | `operatorFacilitatorFees` | `mapping(address => uint256)` | 1 slot |
| **V5.3** | `agentIdentityRegistry` + `agentReputationRegistry` | `address` + `address` (packed) | 1 slot |
| **V5.3** | `agentPolicies` | `mapping(address => AgentSponsorshipPolicy[])` | 1 slot |

**总计**：消耗 6 slots → `__gap[42]`，剩余 42 个 gap slots，安全充足。

> **常量不占 slot**：`MICROPAYMENT_TYPEHASH`、`X402_PAYMENT_TYPEHASH` 等 bytes32 constant 不消耗存储。

### 7.3 EIP-712 + reinitializer 策略

当前 `initialize()` 使用 `initializer` 修饰符（版本 1）。V5.1 需要初始化 EIP-712 domain separator，使用 `reinitializer(2)`：

```solidity
/// @notice V5 upgrade initialization — sets EIP-712 domain separator
function initializeV5() external reinitializer(2) {
    _DOMAIN_SEPARATOR = keccak256(abi.encode(
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
        keccak256("SuperPaymaster"),
        keccak256("5.0.0"),
        block.chainid,
        address(this)  // proxy address (correct in delegatecall context)
    ));
}
```

**升级流程**（单笔交易完成）：

```solidity
// upgradeToAndCall 同时完成升级 + 初始化
proxy.upgradeToAndCall(
    newV5Impl,
    abi.encodeCall(SuperPaymasterV5.initializeV5, ())
);
// 代理地址不变，所有状态保留，新增 EIP-712 domain separator
```

**跨链注意**：`block.chainid` 确保 domain separator 在不同链上不同，防止跨链重放。

### 7.4 Access Control 与 Rate Limiting

#### `chargeMicroPayment()` 完整访问控制

```solidity
function chargeMicroPayment(
    address operator, address user, uint256 usdAmount,
    uint256 nonce, uint256 deadline, bytes calldata signature
) external nonReentrant {
    // 1. Time validity
    if (block.timestamp > deadline) revert ExpiredSignature();

    // 2. Nonce (sequential, prevent replay)
    if (microPaymentNonces[user] != nonce) revert InvalidNonce();
    microPaymentNonces[user]++;

    // 3. EIP-712 signature verification
    bytes32 structHash = keccak256(abi.encode(
        MICROPAYMENT_TYPEHASH, operator, user, usdAmount, nonce, deadline
    ));
    bytes32 digest = keccak256(abi.encodePacked("\x19\x01", _DOMAIN_SEPARATOR, structHash));

    // 4. Signer validation (ECDSA for EOA, ERC-1271 for smart accounts)
    if (!SignatureChecker.isValidSignatureNow(user, digest, signature))
        revert InvalidSignature();

    // 5. Identity check: SBT (current) OR ERC-8004 agent (V5.3)
    if (!sbtHolders[user] && !isRegisteredAgent(user))
        revert UnauthorizedUser();

    // 6. Operator availability
    OperatorConfig storage config = operators[operator];
    if (!config.isConfigured || config.isPaused)
        revert OperatorNotAvailable();

    // 7. Rate limiting (reuses existing userOpState + minTxInterval)
    if (config.minTxInterval > 0) {
        UserOperatorState storage state = userOpState[operator][user];
        if (block.timestamp - state.lastTimestamp < config.minTxInterval)
            revert RateLimited();
        state.lastTimestamp = uint48(block.timestamp);
    }

    // 8. Convert USD → aPNTs → _consumeCredit
    uint256 aPNTsAmount = _calculateAPNTsAmountFromUSD(usdAmount);
    _consumeCredit(operator, user, aPNTsAmount, false);

    emit MicroPaymentCharged(operator, user, usdAmount, aPNTsAmount);
}
```

**调用方**：Permissionless（任何人可提交），安全性完全依赖用户签名。
**身份验证**：复用 `sbtHolders`（已有）+ `isRegisteredAgent()`（V5.3 新增）。
**速率限制**：复用 `operators[].minTxInterval` + `userOpState`（已有）。

### 7.5 现有能力复用矩阵

| V5 新能力 | 复用的已有模块 | 新增代码量 |
|----------|--------------|-----------|
| `_consumeCredit()` | `postOp` 步骤 5-8 提取 | ~40 行 |
| EIP-712 签名验证 | — (新建，使用 OZ `ECDSA` + `SignatureChecker`) | ~30 行 |
| `microPaymentNonces` | — (新建 mapping) | ~5 行 |
| x402 verify/settle (xPNTs 路径) | `_consumeCredit` + 签名验证 | ~50 行 |
| x402 settle (USDC 路径, V5.2) | EIP-3009 / Permit2 (外部调用) | ~80 行 |
| ERC-8004 身份查询 (V5.3) | `sbtHolders` 逻辑扩展 | ~20 行 |
| 信誉驱动赞助 (V5.3) | `ReputationSystem` (已有) | ~30 行 |
| Rate limiting | `userOpState` + `minTxInterval` (完全复用) | 0 行 |
| Debt recording | `xPNTsToken.recordDebt()` (完全复用) | 0 行 |
| Oracle pricing | `_calculateAPNTsAmount()` (完全复用) | 0 行 |
| Operator config | `operators` mapping (完全复用) | 0 行 |
| Pending debt fallback | `pendingDebts` + `retryPendingDebt` (完全复用) | 0 行 |

**结论**：V5.1 新增约 ~125 行合约代码 + ~300 行测试。**80%+ 功能基于已有模块复用**，升级风险可控。

### 7.6 V5.4-V5.5 前向兼容

V5.4（dShop）和 V5.5（dEscrow）是**独立合约**，不修改 SuperPaymaster：

| 集成点 | 机制 | SuperPaymaster 改动 |
|--------|------|-------------------|
| Shop 购买 Gas 赞助 | 用户通过 UserOp 调用 `shop.purchase()` → postOp → `_consumeCredit` | 零改动（已有 ERC-4337 流程） |
| Shop 商品支付 | Shop 合约直接调用 ERC-20 `transferFrom` | 零改动 |
| Escrow 资金锁定/释放 | ShopEscrow 独立处理 | 零改动 |
| DVT 仲裁 | 复用 `DVTValidator` + `BLSAggregator` | 零改动 |

**关键设计决策**：`_consumeCredit()` 的 `preDeducted` 参数和 permissionless `chargeMicroPayment()` 已为 V5.4-V5.5 的支付场景预留了足够灵活性。

### 7.7 Tempo/MPP 战术级技术借鉴

以下是从 Tempo 开源代码库（Apache 2.0）中提取的具体代码模式，可直接用于 V5.1/V5.2/V5.3 实现。

#### 7.7.1 V5.1 借鉴：EIP-712 与 solady

**来源**: `tempo-std/src/interfaces/ITempoStreamChannel.sol` + `tempo/tips/ref-impls/src/TempoStreamChannel.sol`

Tempo 使用 [solady](https://github.com/Vectorized/solady) 的 `EIP712` 基类（我们已有 solady 依赖），取代手动计算 domain separator：

```solidity
// Tempo 的做法 (推荐)
import {EIP712} from "solady/utils/EIP712.sol";

contract SuperPaymaster is EIP712, ... {
    function _domainNameAndVersion() internal pure override
        returns (string memory name, string memory version) {
        name = "SuperPaymaster";
        version = "5.0.0";
    }

    // 验证签名时直接使用 _hashTypedData()
    bytes32 digest = _hashTypedData(structHash);
    // 替代手动: keccak256("\x19\x01" || _DOMAIN_SEPARATOR || structHash)
}
```

**优势**：
- 自动处理 `block.chainid` 变更（fork 后自动重算 domain separator）
- 省去 `_DOMAIN_SEPARATOR` 存储槽（不再消耗 1 slot gap）
- solady EIP712 已审计，gas 优化

**V5.1 Storage Layout 调整**：`_DOMAIN_SEPARATOR` 从 gap 消耗列表中移除，V5.1 仅消耗 1 slot（`microPaymentNonces`）。

#### 7.7.2 V5.2 借鉴：MPP 无状态 Challenge ID

**来源**: `mppx/src/Challenge.ts` + `pympp/src/__init__.py`

MPP 最精妙的设计是 **HMAC-SHA256 无状态 Challenge ID**——服务端无需数据库即可验证 challenge 的真实性：

```
challenge_id = base64url(
    HMAC-SHA256(
        server_secret,
        realm | method | intent | base64url(JCS(request)) | expires | digest | opaque
    )
)
```

**SuperPaymaster 的 x402 Facilitator 可以直接使用此模式**：

```typescript
// Operator Node (链下服务) — 验证 x402 challenge 无需数据库
function computeChallengeId(params: {
    realm: string,        // "paymaster.aastar.io"
    method: string,       // "superpaymaster"
    intent: string,       // "charge"
    request: object,      // { amount, communityId, xpntsToken, paymasterAddress }
    expires?: string,
    secretKey: string,
}): string {
    const input = [
        params.realm,
        params.method,
        params.intent,
        base64url(JSON.stringify(params.request, Object.keys(params.request).sort())),
        params.expires ?? "",
        "",  // digest
        "",  // opaque
    ].join("|");
    return base64url(hmacSha256(params.secretKey, input));
}
```

**影响**：V5.2 的 Operator Node 框架可以完全无状态部署（无 Redis/数据库依赖），安全性由密码学保证。

#### 7.7.3 V5.2 借鉴：Payment Channel 流式微支付

**来源**: `tempo-std/src/interfaces/ITempoStreamChannel.sol`（完整 Escrow 接口）

Tempo 的 Session Intent 使用 Payment Channel + EIP-712 Voucher 实现流式微支付。**核心数据结构可以直接移植**：

```solidity
// SuperPaymaster V5.2+ Session 扩展 (基于 Tempo TempoStreamChannel)
struct MicroPaymentChannel {
    address payer;            // Agent/用户
    address payee;            // Operator
    address token;            // aPNTs 地址
    address authorizedSigner; // 委托签名者 (session key)
    uint128 deposit;          // 预授权上限
    uint128 settled;          // 累计已结算金额（单调递增）
    uint64 closeRequestedAt;  // 强制关闭请求时间
    bool finalized;
}

// Voucher EIP-712 TypeHash (借鉴 Tempo)
bytes32 constant VOUCHER_TYPEHASH =
    keccak256("Voucher(bytes32 channelId,uint128 cumulativeAmount)");

// Channel ID = keccak256(payer, payee, token, salt, authorizedSigner, address(this), chainid)
// 绑定合约地址 + chainId → 防跨链、跨合约重放

// 核心创新：累计金额 (cumulative) 而非增量 (delta)
// → 无需 per-session nonce，自然防重放
// → 每个 voucher = "我已累计消费 X"
// → settle() 只转 delta = cumulativeAmount - channel.settled
```

**Escrow 合约函数**（可独立部署或内嵌 SuperPaymaster）:

```solidity
function openChannel(address payee, address token, uint128 deposit, bytes32 salt, address authorizedSigner)
    external returns (bytes32 channelId);

function settleChannel(bytes32 channelId, uint128 cumulativeAmount, bytes calldata signature)
    external;  // payee 中间结算

function topUpChannel(bytes32 channelId, uint128 additionalDeposit) external;  // payer 追加

function closeChannel(bytes32 channelId, uint128 cumulativeAmount, bytes calldata signature)
    external;  // payee 关闭并结算

function requestCloseChannel(bytes32 channelId) external;  // payer 强制关闭 (15min grace)

function withdrawChannel(bytes32 channelId) external;  // payer grace period 后提款
```

**设计决策**：Payment Channel 可以作为独立合约部署（不修改 SuperPaymaster proxy），由 SuperPaymaster 通过接口调用。这样 V5.1 的 `_consumeCredit()` + V5.2 的 Payment Channel 形成完整的"单次计费 + 流式计费"双模式。

#### 7.7.4 V5.2 借鉴：SDK 中间件架构

**来源**: `mppx/src/server/Mppx.ts` + `mppx/src/middlewares/`

mppx 的 server SDK 使用了极优雅的**中间件注入模式**，值得 SuperPaymaster SDK 完全借鉴：

```typescript
// SuperPaymaster x402 Facilitator SDK (借鉴 mppx 架构)
// 1. Method 定义 (插件化)
const superpaymaster = Method.from({
    name: 'superpaymaster',
    intent: 'charge',
    schema: {
        credential: { payload: z.object({ userOpHash: z.string(), type: z.literal('userop') }) },
        request: z.object({
            amount: z.string(),
            communityId: z.string(),
            xpntsToken: z.string(),
            paymasterAddress: z.string(),
        }),
    },
});

// 2. Server 中间件 (Hono)
const mppx = Mppx.create({
    methods: [superpaymaster.verify({ ... })],
    secretKey: process.env.MPP_SECRET_KEY,  // HMAC 无状态
    realm: 'paymaster.aastar.io',
});
app.post('/api/resource', mppx.charge({ amount: '100' }), handler);

// 3. Client fetch wrapper (Agent 端)
const mppx = Mppx.create({ methods: [superpaymaster.client({ account })] });
const res = await mppx.fetch('/api/resource');
// 自动处理 402 → 构建 UserOp → 提交 → 重试
```

**关键架构模式**：
- `Transport` 抽象：HTTP / MCP / SSE 三种传输，同一套支付逻辑
- `Store` 接口：KV 抽象（Cloudflare KV / Redis / Memory），用于 session 状态
- `compose()`：多支付方法 compose（同时支持 xPNTs + USDC + Stripe SPT）
- **Push/Pull 两种凭证模式**：Push = Agent 广播交易发 txHash，Pull = Agent 签名由服务端广播

**SDK 依赖策略**：不依赖 mppx npm 包本身（Stripe 绑定太紧），而是借鉴其架构模式构建 `@superpaymaster/facilitator-sdk`，使用相同的 HTTP 402 协议规范（IETF Payment Auth Scheme，两者向后兼容）。

#### 7.7.5 V5.3 借鉴：SKILL.md Agent 自动发现

**来源**: `tempo.xyz/SKILL.md` + Tempo 官方文档 `docs.tempo.xyz/guide/using-tempo-with-ai`

Tempo 的 SKILL.md 安装流程：

```
1. 用户对 Agent 说: "install tempo.xyz/SKILL.md"
2. Agent 下载 SKILL.md → 保存到 .claude/skills/tempo/SKILL.md
3. SKILL.md 包含:
   - YAML frontmatter (name, description, trigger 条件)
   - 安装命令: curl -fsSL https://tempo.xyz/install | bash
   - 核心 CLI 命令: wallet login, services search, request
   - 支付处理指令
4. Agent 自动安装 CLI → 创建钱包 → 可使用 MPP 支付
```

SuperPaymaster V5.3 应实现等价机制：`paymaster.aastar.io/SKILL.md`

```yaml
---
name: superpaymaster
description: >
  SuperPaymaster enables gasless transactions and micropayments for Web3 agents.
  Use this skill when the user needs gas sponsorship, community-based payment services,
  or x402 facilitator functionality via SuperPaymaster infrastructure.
---

# SuperPaymaster Agent Skill

## Setup
1. Install CLI: `pnpm add -g @superpaymaster/cli`
2. Connect: `superpaymaster connect --network sepolia`
3. Register: `superpaymaster register --identity erc8004`

## Core Commands
- Check eligibility: `superpaymaster check <address>`
- Find operators: `superpaymaster operators --community <name>`
- Sponsor gas: `superpaymaster sponsor --operator <addr> --userop <json>`
- Micropayment: `superpaymaster charge --operator <addr> --amount <usd> --sign`

## Service Discovery
- `GET /openapi.json` → OpenAPI doc with x-payment-info extensions
- `GET /operators` → available community operators with rates

## x402 Facilitator
For paid API resources, SuperPaymaster handles 402 challenges automatically:
- Detects 402 Payment Required responses
- Finds best operator for the user's community
- Signs and submits payment via chargeMicroPayment or UserOp
- Retries request with payment credential
```

#### 7.7.6 V5.3 借鉴：OpenAPI 服务发现

**来源**: `mpp-specs/specs/extensions/draft-payment-discovery-00.md`

MPP 定义了两个 OpenAPI 扩展用于支付服务发现：

```json
{
    "openapi": "3.1.0",
    "info": { "title": "SuperPaymaster API", "version": "5.0.0" },
    "x-service-info": {
        "categories": ["payment", "infrastructure"],
        "docs": {
            "homepage": "https://paymaster.aastar.io",
            "apiReference": "https://paymaster.aastar.io/docs",
            "llms": "https://paymaster.aastar.io/llms.txt"
        }
    },
    "paths": {
        "/api/sponsor": {
            "post": {
                "summary": "Sponsor gas for UserOperation",
                "x-payment-info": {
                    "intent": "charge",
                    "method": "superpaymaster",
                    "amount": null,
                    "currency": "0x...",
                    "description": "Gas cost varies by operation complexity"
                }
            }
        }
    }
}
```

**V5.3 应提供此标准化 OpenAPI 文档**，使任何兼容 MPP/x402 的 Agent 都能自动发现 SuperPaymaster 服务。

#### 7.7.7 V5.2/V5.3 借鉴：MCP Transport 支付

**来源**: `mpp-specs/specs/extensions/transports/draft-payment-transport-mcp-00.md`

MPP 为 MCP (Model Context Protocol) 定义了 JSON-RPC 支付错误码：

```json
{
    "jsonrpc": "2.0", "id": 1,
    "error": {
        "code": -32042,
        "message": "Payment Required",
        "data": {
            "httpStatus": 402,
            "challenges": [{
                "id": "...", "realm": "paymaster.aastar.io",
                "method": "superpaymaster", "intent": "charge",
                "request": { "amount": "1000", "communityId": "..." }
            }]
        }
    }
}
```

SuperPaymaster 的 MCP Server（V5.3 已在 ERC-8004 metadata 中声明）应实现此错误码，使 Agent 通过 MCP 工具调用时也能自动处理支付。

#### 7.7.8 依赖策略：可控性分析

| 借鉴来源 | 许可证 | 依赖方式 | 可控性 |
|----------|--------|----------|--------|
| `tempo-std` ITempoStreamChannel 接口 | Apache 2.0 | 参考实现，不引入包 | ✅ 完全可控 |
| MPP HTTP 402 协议规范 | CC0 公共领域 | 遵循开放标准 | ✅ 完全可控 |
| mppx SDK 架构模式 | Apache 2.0 | 参考模式，自建 SDK | ✅ 完全可控 |
| solady EIP712 基类 | MIT | 已有依赖 | ✅ 已引入 |
| OpenZeppelin ECDSA | MIT | 已有依赖 | ✅ 已引入 |
| SKILL.md 格式 | 开放标准 (Anthropic) | 遵循标准格式 | ✅ 完全可控 |
| OpenAPI x-payment-info 扩展 | CC0 | 遵循开放标准 | ✅ 完全可控 |
| MCP JSON-RPC Transport | 开放标准 | 遵循标准 | ✅ 完全可控 |
| Cloudflare mpp-proxy 代码 | Apache 2.0 | 参考实现 | ✅ 完全可控 |

**原则**：所有借鉴均为"参考模式 + 遵循开放标准"，不引入任何运行时包依赖（除已有的 solady/OZ）。无 Stripe/Tempo 绑定。

---

## 八、参考文献

### x402 协议
1. [x402 Official Website](https://www.x402.org/)
2. [Coinbase x402 GitHub](https://github.com/coinbase/x402)
3. [x402 V2 Launch](https://www.x402.org/writing/x402-v2-launch)
4. [x402 + ERC-4337 Integration Proposal - Issue #639](https://github.com/coinbase/x402/issues/639)
5. [x402 Foundation - Cloudflare Blog](https://blog.cloudflare.com/x402/)

### ERC-8004
6. [ERC-8004: Trustless Agents - Official EIP](https://eips.ethereum.org/EIPS/eip-8004)
7. [ERC-8004 Practical Explainer](https://composable-security.com/blog/erc-8004-a-practical-explainer-for-trustless-agents/)
8. [ERC-8004 with Reputation & Validation](https://www.buildbear.io/blog/erc-8004)

### AI Agent Economy
9. [Agentic Economy - Chainalysis](https://www.chainalysis.com/blog/ai-and-crypto-agentic-payments/)
10. [Coinbase AgentKit + Agentic Wallets](https://www.coinbase.com/developer-platform/discover/launches/agentic-wallets)
11. [Google AP2 Protocol](https://ap2-protocol.org/)
12. [Stripe Tempo MPP](https://www.coindesk.com/tech/2026/03/18/stripe-led-payments-blockchain-tempo-goes-live-with-protocol-for-ai-agents/)

### Stripe Tempo & MPP
19. [MPP Official Specification](https://mpp.dev/overview) — HTTP 402 Payment Auth Scheme, charge + session intents
20. [MPP Session Intent (Payment Channel + EIP-712 Voucher)](https://mpp.dev/payment-methods/tempo/session) — 流式微支付参考
21. [Tempo TIP-20 Token Standard](https://tempo.xyz/blog/tip-20-a-token-standard-for-payments) — Transfer Memo + Payment Lanes
22. [mppx TypeScript SDK](https://github.com/tempoxyz/mpp) — drop-in `fetch` replacement for HTTP 402
23. [Cloudflare MPP Proxy](https://github.com/cloudflare/mpp-proxy) — x402/MPP 中间件参考
24. [ACP (OpenAI + Stripe)](https://github.com/agentic-commerce-protocol/agentic-commerce-protocol) — Agent 商务协议

### 相关 EIP
13. [EIP-1153: Transient Storage](https://eips.ethereum.org/EIPS/eip-1153)
14. [EIP-7702: Smart EOAs](https://eips.ethereum.org/EIPS/eip-7702)
15. [EIP-7528: ETH Address Convention](https://eips.ethereum.org/EIPS/eip-7528)
16. [EIP-8141: Frame Transaction (Native AA)](https://eips.ethereum.org/EIPS/eip-8141) — Hegotia fork 目标 2026 H2
17. [EIP-8141 开发者影响分析](https://www.openfort.io/blog/eip-8141-means-for-developers)
18. [Native AA 现状分析 Q1/2026](https://blog.biconomy.io/native-account-abstraction-state-of-art-and-pending-proposals-q1-26/)

> **详细研究报告**：
> - AI Agent 支付、x402、ERC-8004 深度研究：`docs/research-agent-x402-micropayment.md`
> - Stripe Tempo & MPP 深度研究（含 SuperPaymaster 借鉴分析）：`docs/research-stripe-tempo-mpp.md`
