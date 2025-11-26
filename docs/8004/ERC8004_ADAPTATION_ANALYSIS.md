# SuperPaymaster × ERC-8004 Adaptation Analysis

**[English](#english)** | **[中文](#chinese)**

<a name="english"></a>

---

## Executive Summary

This document analyzes how the SuperPaymaster ecosystem can **natively support** [ERC-8004 (Trustless Agents)](https://eips.ethereum.org/EIPS/eip-8004), leveraging our existing infrastructure (MySBT, Registry, Reputation System) to become a native participant in the emerging autonomous AI agent economy.

**Key Decision**: We adopt **Native Integration** (no adapter layer) to minimize complexity and cost.

## ERC-8004 Overview

ERC-8004 introduces three on-chain registries for trustless agent interaction:

| Registry | Purpose | SuperPaymaster Mapping |
|----------|---------|------------------------|
| **Identity Registry** | Agent identification | MySBT v2.5.0 (native) |
| **Reputation Registry** | Feedback mechanism | ReputationAccumulator v2.0 (native) |
| **Validation Registry** | Task verification | JuryContract (MyTask repo) |

## AI Agent Gas Sponsorship Path

### How It Works

```
┌─────────────────────────────────────────────────────────────────────┐
│                    AI Agent (Any Form)                               │
│  App / Plugin / Bot / API Client / Autonomous Service               │
└─────────────────────────────┬───────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Discovery Layer                                   │
│  • API: api.aastar.io/superpaymaster                                │
│  • ENS: superpaymaster.eth (planned)                                │
│  • On-chain: SuperPaymasterV2 contract address                      │
└─────────────────────────────┬───────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Prerequisites                                     │
│  1. Agent holds MySBT (Identity Proof / AgentID)                    │
│  2. Agent holds xPNTs (Gas Token for community)                     │
│  3. Agent knows SuperPaymaster address                              │
└─────────────────────────────┬───────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Transaction Flow                                  │
│  1. Agent builds UserOperation                                      │
│  2. paymasterAndData = SuperPaymaster + operator + gasLimits        │
│  3. Submit to Bundler                                               │
│  4. SuperPaymaster validates: SBT ownership + xPNTs balance         │
│  5. Gas sponsored, transaction executed                             │
│  6. PostOp: xPNTs deducted from agent's balance                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Key Points

- **Frictionless**: Agent only needs our API/ENS address + assets
- **Universal**: Works for any Agent form (App, Plugin, Bot, API)
- **Self-service**: No manual registration, just hold MySBT + xPNTs

## Community-Based Sponsorship

### Definition

- **Community** = Registered operator in Registry (e.g., "AAStar Community")
- **Resource Pool** = Community's ETH deposit in EntryPoint
- **Members** = Users/Agents holding MySBT membership in that community

### How It Works

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Community Resource Pool                           │
│                                                                      │
│  Community Operator                                                  │
│  ├── Deposits ETH to EntryPoint                                     │
│  ├── Issues xPNTs to members                                        │
│  └── Sets gas sponsorship rules                                     │
│                                                                      │
│  Community Members (Agents)                                          │
│  ├── Hold MySBT with community membership                           │
│  ├── Hold xPNTs (community gas token)                               │
│  └── Share community's gas budget                                   │
│                                                                      │
│  Cost Recovery                                                       │
│  └── xPNTs deducted per transaction                                 │
└─────────────────────────────────────────────────────────────────────┘
```

## Debt Tracking (Clarification)

### SuperPaymaster's Role (Provider, NOT Collector)

SuperPaymaster provides **data and services**, NOT debt collection:

| What We Provide | Description |
|-----------------|-------------|
| Transaction records | On-chain tx history, gas costs |
| xPNTs consumption | Accumulated usage per agent |
| Debt status queries | API for checking outstanding balances |
| State change services | Mark debt paid, update limits |

**Debt collection is community's responsibility** - we only provide the data infrastructure.

## Native Integration Strategy

### Why No Adapter Layer?

| Aspect | Adapter Pattern | Native Integration |
|--------|-----------------|-------------------|
| Contract count | +3 new contracts | 0 new contracts |
| Gas overhead | Higher (extra calls) | Minimal |
| Maintenance | More complexity | Single codebase |
| Upgrade cost | Double migrations | Standard upgrade |

**Decision**: Native integration is simpler and cheaper.

---

## MySBT v2.5.0 (Identity Registry)

### Changes Required

```solidity
// NEW: Storage additions
mapping(uint256 => string) private _tokenURIs;           // Agent Card URI
mapping(uint256 => mapping(string => bytes)) private _agentMetadata;

// NEW: ERC-8004 Identity functions
function register(string calldata tokenURI) external returns (uint256 agentId);
function getMetadata(uint256 agentId, string calldata key) external view returns (bytes memory);
function setMetadata(uint256 agentId, string calldata key, bytes calldata value) external;
function setTokenURI(uint256 tokenId, string calldata tokenURI) external;

// NEW: ERC-8004 Events
event Registered(uint256 indexed agentId, string tokenURI, address indexed owner);
event MetadataSet(uint256 indexed agentId, string indexed indexedKey, string key, bytes value);
```

### Impact Assessment

| Change | Complexity | Size Impact | Migration |
|--------|------------|-------------|-----------|
| `_tokenURIs` mapping | Low | +0.3KB | None |
| `_agentMetadata` mapping | Low | +0.5KB | None |
| `register()` function | Low | +0.3KB | None |
| `get/setMetadata()` | Low | +0.4KB | None |
| Events | Low | +0.1KB | None |
| **Total** | **Low** | **~1.6KB** | **None** |

### Key Design

- `agentId` = `tokenId` (no separate ID system)
- Existing mint functions continue to work
- `register()` is alternative entry point for ERC-8004 clients

---

## ReputationAccumulator v2.0 (Reputation Registry)

### Current vs ERC-8004 Comparison

| Aspect | Current System | ERC-8004 Standard |
|--------|---------------|-------------------|
| Layers | Community + Global | Single (Global) |
| Source | Activity-based (auto) | Client feedback (manual) |
| Tags | Community address | bytes32 tag1/tag2 |
| Scope | Community-specific | Agent-wide |

### Integration Strategy

**Keep both systems**, add ERC-8004 as third feedback source:

```
Agent Reputation Score =
    Community Score (activity-based) +
    Global Score (aggregate) +
    Client Feedback Score (ERC-8004)
```

### EIP-191 Signature Authorization Explained

```solidity
// feedbackAuth structure
struct FeedbackAuth {
    uint256 agentId;           // Target agent
    address clientAddress;      // Who can give feedback
    uint64 indexLimit;          // Max feedback entries
    uint256 expiry;             // Authorization expiry
    uint256 chainId;            // Chain ID
    address identityRegistry;   // MySBT address
    address signerAddress;      // Who signed this
}

// Usage: Agent authorizes client to give feedback
// 1. Agent signs FeedbackAuth with EIP-191
// 2. Client calls giveFeedback() with signature
// 3. Contract verifies signature
// 4. Prevents random accounts from spam feedback
```

**Simple explanation**: "I (agent) authorize you (client) to give me up to N feedback scores before expiry date."

### Changes Required

```solidity
// NEW: Client feedback storage
mapping(uint256 => mapping(address => Feedback[])) private _clientFeedback;
mapping(uint256 => address[]) private _feedbackClients;

// NEW: ERC-8004 Reputation functions
function giveFeedback(
    uint256 agentId,
    uint8 score,
    bytes32 tag1,
    bytes32 tag2,
    string calldata fileuri,
    bytes32 filehash,
    bytes calldata feedbackAuth
) external;

function revokeFeedback(uint256 agentId, uint64 feedbackIndex) external;

function getSummary(
    uint256 agentId,
    address[] calldata clientAddresses,
    bytes32 tag1,
    bytes32 tag2
) external view returns (uint64 count, uint8 averageScore);

// Compatibility: Map community to tag
function communityToTag(address community) public pure returns (bytes32) {
    return bytes32(uint256(uint160(community)));
}
```

---

## JuryContract (Validation Registry)

**Location**: [MyTask Repository](https://github.com/jhfnetboy/MyTask)

This contract will be developed in the MyTask repo as it's part of the task/jury system. See separate design document in MyTask.

---

## Architecture (Native, No Adapter)

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          ERC-8004 Interfaces                              │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────┐   │
│  │ IERC8004        │  │ IERC8004        │  │ IERC8004                │   │
│  │ IdentityRegistry│  │ ReputationReg   │  │ ValidationRegistry      │   │
│  └────────┬────────┘  └────────┬────────┘  └────────────┬────────────┘   │
└───────────┼─────────────────────┼──────────────────────┼─────────────────┘
            │                     │                      │
            │ implements          │ implements           │ implements
            │                     │                      │
┌───────────▼─────────────────────▼──────────────────────▼─────────────────┐
│                     SuperPaymaster Contracts (Native ERC-8004)            │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────┐   │
│  │ MySBT v2.5.0    │  │ Reputation      │  │ JuryContract            │   │
│  │ (Identity)      │  │ Accumulator v2  │  │ (in MyTask repo)        │   │
│  │                 │  │                 │  │                         │   │
│  │ + Registry      │  │ + Community     │  │ + GTokenStaking         │   │
│  │   v2.2.1        │  │ + Global        │  │   integration           │   │
│  │                 │  │ + Client (8004) │  │                         │   │
│  └────────┬────────┘  └────────┬────────┘  └────────────┬────────────┘   │
│           │                    │                        │                 │
│           └────────────────────┼────────────────────────┘                 │
│                                ▼                                          │
│                    ┌─────────────────────────┐                            │
│                    │ SuperPaymasterV2 v2.3.3 │                            │
│                    │ (Gasless Transactions)  │                            │
│                    └─────────────────────────┘                            │
└──────────────────────────────────────────────────────────────────────────┘
```

## Security Considerations

1. **Identity Spoofing**: MySBT soulbound nature prevents transfer attacks
2. **Reputation Gaming**: EIP-191 signature authorization prevents spam
3. **Jury Collusion**: Multi-party consensus + staking requirements (MyTask)
4. **Gas Griefing**: Reputation-based gas limits

## References

- [ERC-8004 Specification](https://eips.ethereum.org/EIPS/eip-8004)
- [ERC-8004 Discussion](https://ethereum-magicians.org/t/erc-8004-trustless-agents/25098)
- [Awesome ERC-8004 Resources](https://github.com/sudeepb02/awesome-erc8004)
- [MyTask Project](https://github.com/jhfnetboy/MyTask)

---

<a name="chinese"></a>

# SuperPaymaster × ERC-8004 适配分析

**[English](#english)** | **[中文](#chinese)**

---

## 执行摘要

本文档分析 SuperPaymaster 生态系统如何**原生支持** [ERC-8004 (Trustless Agents)](https://eips.ethereum.org/EIPS/eip-8004)，利用现有基础设施成为自治 AI 代理经济的原生参与者。

**核心决策**：采用**原生集成**（无适配器层），以最小化复杂度和成本。

## AI 代理 Gas 赞助路径

### 工作流程

```
┌─────────────────────────────────────────────────────────────────────┐
│                    AI 代理（任何形态）                                │
│  App / 插件 / 机器人 / API 客户端 / 自治服务                         │
└─────────────────────────────┬───────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    发现层                                            │
│  • API: api.aastar.io/superpaymaster                                │
│  • ENS: superpaymaster.eth（规划中）                                 │
│  • 链上: SuperPaymasterV2 合约地址                                   │
└─────────────────────────────┬───────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    前置条件                                          │
│  1. 代理持有 MySBT（身份证明 / AgentID）                             │
│  2. 代理持有 xPNTs（社区 Gas 代币）                                  │
│  3. 代理知道 SuperPaymaster 地址                                     │
└─────────────────────────────┬───────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    交易流程                                          │
│  1. 代理构建 UserOperation                                          │
│  2. paymasterAndData = SuperPaymaster + operator + gasLimits        │
│  3. 提交到 Bundler                                                  │
│  4. SuperPaymaster 验证: SBT 所有权 + xPNTs 余额                     │
│  5. Gas 被赞助，交易执行                                             │
│  6. PostOp: 从代理余额扣除 xPNTs                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### 关键点

- **无感接入**：代理只需知道我们的 API/ENS 地址 + 持有资产
- **通用性**：适用于任何代理形态（App、插件、机器人、API）
- **自助式**：无需手动注册，只需持有 MySBT + xPNTs

## 社区化赞助

### 定义

- **社区** = Registry 中注册的运营商（如"AAStar 社区"）
- **资源池** = 社区在 EntryPoint 的 ETH 存款
- **成员** = 在该社区持有 MySBT 会员资格的用户/代理

### 工作原理

```
┌─────────────────────────────────────────────────────────────────────┐
│                    社区资源池                                        │
│                                                                      │
│  社区运营商                                                          │
│  ├── 向 EntryPoint 存入 ETH                                         │
│  ├── 向成员发行 xPNTs                                                │
│  └── 设置 Gas 赞助规则                                               │
│                                                                      │
│  社区成员（代理）                                                     │
│  ├── 持有带社区会员资格的 MySBT                                      │
│  ├── 持有 xPNTs（社区 Gas 代币）                                     │
│  └── 共享社区的 Gas 预算                                             │
│                                                                      │
│  成本回收                                                            │
│  └── 每笔交易扣除 xPNTs                                              │
└─────────────────────────────────────────────────────────────────────┘
```

## 债务追踪（澄清）

### SuperPaymaster 的角色（提供者，非催收者）

SuperPaymaster 提供**数据和服务**，而非债务催收：

| 我们提供的 | 描述 |
|-----------|------|
| 交易记录 | 链上交易历史、Gas 成本 |
| xPNTs 消耗 | 每个代理的累计使用量 |
| 债务状态查询 | 查询未结余额的 API |
| 状态变更服务 | 标记债务已付、更新限额 |

**债务催收是社区的责任** - 我们只提供数据基础设施。

## 原生集成策略

### 为什么不用适配器层？

| 方面 | 适配器模式 | 原生集成 |
|------|-----------|----------|
| 合约数量 | +3 个新合约 | 0 个新合约 |
| Gas 开销 | 更高（额外调用） | 最小化 |
| 维护成本 | 更复杂 | 单一代码库 |
| 升级成本 | 双重迁移 | 标准升级 |

**决策**：原生集成更简单、成本更低。

---

## MySBT v2.5.0（身份注册表）

### 需要的改动

```solidity
// 新增：存储
mapping(uint256 => string) private _tokenURIs;           // Agent Card URI
mapping(uint256 => mapping(string => bytes)) private _agentMetadata;

// 新增：ERC-8004 身份函数
function register(string calldata tokenURI) external returns (uint256 agentId);
function getMetadata(uint256 agentId, string calldata key) external view returns (bytes memory);
function setMetadata(uint256 agentId, string calldata key, bytes calldata value) external;
function setTokenURI(uint256 tokenId, string calldata tokenURI) external;

// 新增：ERC-8004 事件
event Registered(uint256 indexed agentId, string tokenURI, address indexed owner);
event MetadataSet(uint256 indexed agentId, string indexed indexedKey, string key, bytes value);
```

### 影响评估

| 改动 | 复杂度 | 大小影响 | 迁移 |
|------|--------|----------|------|
| `_tokenURIs` 映射 | 低 | +0.3KB | 无 |
| `_agentMetadata` 映射 | 低 | +0.5KB | 无 |
| `register()` 函数 | 低 | +0.3KB | 无 |
| `get/setMetadata()` | 低 | +0.4KB | 无 |
| 事件 | 低 | +0.1KB | 无 |
| **总计** | **低** | **~1.6KB** | **无** |

### 关键设计

- `agentId` = `tokenId`（无独立 ID 系统）
- 现有 mint 函数继续工作
- `register()` 是 ERC-8004 客户端的替代入口

---

## ReputationAccumulator v2.0（声誉注册表）

### 当前 vs ERC-8004 对比

| 方面 | 当前系统 | ERC-8004 标准 |
|------|---------|---------------|
| 层级 | 社区 + 全局 | 单层（全局） |
| 来源 | 基于活动（自动） | 客户端反馈（手动） |
| 标签 | 社区地址 | bytes32 tag1/tag2 |
| 范围 | 社区特定 | 代理全局 |

### 集成策略

**保留两套系统**，添加 ERC-8004 作为第三个反馈来源：

```
代理声誉分 =
    社区分（基于活动） +
    全局分（聚合） +
    客户端反馈分（ERC-8004）
```

### EIP-191 签名授权解释

```solidity
// feedbackAuth 结构
struct FeedbackAuth {
    uint256 agentId;           // 目标代理
    address clientAddress;      // 谁可以给反馈
    uint64 indexLimit;          // 最大反馈条数
    uint256 expiry;             // 授权过期时间
    uint256 chainId;            // 链 ID
    address identityRegistry;   // MySBT 地址
    address signerAddress;      // 签名者
}

// 用法：代理授权客户端给反馈
// 1. 代理用 EIP-191 签名 FeedbackAuth
// 2. 客户端调用 giveFeedback() 带签名
// 3. 合约验证签名
// 4. 防止随机账户发垃圾反馈
```

**简单解释**："我（代理）授权你（客户端）在过期时间前给我最多 N 条反馈评分。"

---

## JuryContract（验证注册表）

**位置**：[MyTask 仓库](https://github.com/jhfnetboy/MyTask)

该合约将在 MyTask 仓库开发，因为它是任务/陪审团系统的一部分。详见 MyTask 的设计文档。

---

## 架构（原生，无适配器）

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          ERC-8004 接口                                    │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────┐   │
│  │ IERC8004        │  │ IERC8004        │  │ IERC8004                │   │
│  │ IdentityRegistry│  │ ReputationReg   │  │ ValidationRegistry      │   │
│  └────────┬────────┘  └────────┬────────┘  └────────────┬────────────┘   │
└───────────┼─────────────────────┼──────────────────────┼─────────────────┘
            │                     │                      │
            │ 实现                 │ 实现                 │ 实现
            │                     │                      │
┌───────────▼─────────────────────▼──────────────────────▼─────────────────┐
│                     SuperPaymaster 合约（原生 ERC-8004）                  │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────────────────┐   │
│  │ MySBT v2.5.0    │  │ Reputation      │  │ JuryContract            │   │
│  │ (身份)          │  │ Accumulator v2  │  │ (在 MyTask 仓库)        │   │
│  │                 │  │                 │  │                         │   │
│  │ + Registry      │  │ + 社区层        │  │ + GTokenStaking         │   │
│  │   v2.2.1        │  │ + 全局层        │  │   集成                  │   │
│  │                 │  │ + 客户端 (8004) │  │                         │   │
│  └────────┬────────┘  └────────┬────────┘  └────────────┬────────────┘   │
│           │                    │                        │                 │
│           └────────────────────┼────────────────────────┘                 │
│                                ▼                                          │
│                    ┌─────────────────────────┐                            │
│                    │ SuperPaymasterV2 v2.3.3 │                            │
│                    │ (无 Gas 交易)           │                            │
│                    └─────────────────────────┘                            │
└──────────────────────────────────────────────────────────────────────────┘
```

## 安全考虑

1. **身份伪造**：MySBT 灵魂绑定特性防止转让攻击
2. **声誉刷分**：EIP-191 签名授权防止垃圾信息
3. **陪审团串通**：多方共识 + 质押要求（MyTask）
4. **Gas 攻击**：基于声誉的 Gas 限制

## 参考资料

- [ERC-8004 规范](https://eips.ethereum.org/EIPS/eip-8004)
- [ERC-8004 讨论](https://ethereum-magicians.org/t/erc-8004-trustless-agents/25098)
- [Awesome ERC-8004 资源](https://github.com/sudeepb02/awesome-erc8004)
- [MyTask 项目](https://github.com/jhfnetboy/MyTask)
