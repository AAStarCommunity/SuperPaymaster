# AI Agent 支付、x402 协议与微支付标准深度研究报告

> **作者**: Jason Jiao | **日期**: 2026-03-21 | **版本**: v1.0
>
> **关键词**: AI Agent Economy, x402 Protocol, ERC-8004, Micropayment, ERC-4337, Paymaster, Machine-to-Machine Payment

---

## 目录

1. [AI Agent 经济与支付](#1-ai-agent-经济与支付)
2. [x402 协议深度分析](#2-x402-协议深度分析)
3. [EIP-8004 及相关支付 EIP](#3-eip-8004-及相关支付-eip)
4. [微支付（Micropayment）方案研究](#4-微支付micropayment方案研究)
5. [跨链支付与结算](#5-跨链支付与结算)
6. [对 SuperPaymaster 微支付设计的启示](#6-对-superpaymaster-微支付设计的启示)
7. [参考文献](#7-参考文献)

---

## 1. AI Agent 经济与支付

### 1.1 Agentic Economy 概念和发展

Agentic Economy（智能体经济）是指由自主运行的 AI Agent 作为经济参与者，独立执行交易、消费资源和提供服务的新型经济形态。根据 McKinsey 的预测，到 2030 年，Agentic Commerce 的全球市场规模将达到 **3 至 5 万亿美元**。AI Agent 市场本身预计将从 2025 年的 78.4 亿美元增长到 2030 年的 526.2 亿美元，复合年增长率达 **46.3%**。

Agentic Economy 的核心特征包括：
- **自主决策**: Agent 能够在无人干预的情况下完成资源采购、服务调用和支付
- **高频微额交易**: Agent 间的交易频率远超人类，Binance 创始人赵长鹏指出 "AI Agents 的支付次数将是人类的百万倍"
- **Machine-to-Machine (M2M)**: Agent 与 Agent 之间的直接经济互动成为主流
- **实时结算**: 200ms 级别的支付确认取代传统 2-3 天的 ACH 结算周期

截至 2025 年底，区块链吞吐量已在五年内提升了 100 倍（从 25 TPS 到 3,400 TPS），2025 年 9 月单月稳定币交易量突破 **1.25 万亿美元**，2025 年全年稳定币转账量达到 **33 万亿美元**（同比增长 72%），证明区块链网络已能支撑多 Agent 系统每日数千次微支付的交易密度。

### 1.2 AI Agent 的链上支付需求

AI Agent 选择加密货币而非传统银行体系进行支付的核心原因：

| 维度 | 传统支付 | 加密支付 |
|------|---------|---------|
| 开户门槛 | 需要身份验证（KYC），软件无法完成 | 仅需一个私钥 |
| 最低手续费 | ~$0.30（信用卡最低费用） | ~$0.00025（Solana）/ ~$0.001（Base L2） |
| 结算速度 | 2-3 天（ACH）/ T+1（信用卡） | 200ms - 12s |
| 可编程性 | 有限 | 智能合约原生支持 |
| 无人值守 | 需人工授权 | 支持自主执行 |
| 跨境支付 | 复杂、费用高 | 全球统一、低成本 |

Agent 支付的四大核心需求：
1. **高频 (High-frequency)**: 每秒处理数千笔微交易
2. **小额 (Micro-amount)**: 单笔低至 $0.001 以下（每次 API 调用计费）
3. **自主 (Autonomous)**: 无需人类逐笔审批
4. **M2M (Machine-to-Machine)**: Agent 间直接结算，无人类中介

### 1.3 AI Agent 钱包方案

#### 1.3.1 Coinbase AgentKit + Agentic Wallets

Coinbase 的 AgentKit 是当前最成熟的 AI Agent 钱包基础设施，于 2025 年推出初始版本，2026 年 2 月发布了 **Agentic Wallets** 重大升级。

**核心能力**:
- **Authenticate**: 钱包身份验证
- **Fund**: 资金充值
- **Send**: 发送支付
- **Trade**: 资产交易
- **Earn**: 收益管理

**关键特性**:
- 框架无关（framework-agnostic）和钱包无关（wallet-agnostic）设计
- 支持免手续费稳定币支付
- 与 x402 协议原生集成
- 已处理超过 **5,000 万笔交易**

**World AgentKit 集成（2026 年 3 月）**: Sam Altman 联合创立的 World 项目发布了与 Coinbase AgentKit 集成的工具包，让 AI Agent 能够携带 World ID 人类身份验证的加密证明，使 Agent 成为可验证的经济参与者而非可疑的自动化流量。

#### 1.3.2 Visa CLI

2026 年 3 月 18 日，Visa Crypto Labs 发布了 **Visa CLI**，一个实验性命令行工具，允许 AI Agent 在不嵌入 API 密钥的情况下发起卡支付。该工具实现了亚秒级延迟的 "Agentic Commerce"，将集成时间从数周缩短到数小时。

#### 1.3.3 Alchemy AI Agent Wallet

2026 年 3 月，Alchemy 为 AI Agent 提供了加密钱包服务，报道称 **80% 的 Fortune 500 公司**目前已在运行 AI Agent，这些企业正在加速接入链上支付能力。

### 1.4 Agent-to-Agent (A2A) 支付场景

#### 1.4.1 Google Agent2Agent (A2A) 协议

Google 于 2025 年 4 月发布了 A2A 协议，旨在让不同公司和平台的 AI Agent 能够安全地通信和协作。核心支付场景包括：

- **实时采购 (Real-time Purchases)**: 用户让 Agent 搜索商品，Agent 自主比价、下单和支付
- **协调任务 (Coordinated Tasks)**: 用户规划旅行，Agent 同时与多个商户 Agent 交互，执行加密签名的预订
- **Agent 雇佣 Agent**: 一个 Agent 支付另一个 Agent 完成子任务（如数据分析、图像生成）

#### 1.4.2 Google Agent Payments Protocol (AP2)

2025 年 9 月，Google Cloud 与 Coinbase 联合推出了 **AP2 (Agent Payments Protocol)**，一个由超过 **60 家组织**共同参与的开放支付协议。

**核心架构概念 — Mandate（授权令）**:
AP2 的核心创新是引入了加密签名的 **Mandate**（授权令），作为用户意图的防篡改证明。

三种 Mandate 类型：
1. **Cart Mandate ("Human-Present")**: 商户签名购物车保证履行，用户签名批准
2. **Intent Mandate ("Human-Not-Present")**: 用户预先批准条件，授权 Agent 后续自主行动
3. **Payment Mandate**: 从 Cart/Intent Mandate 派生的最小化支付凭证

**AP2 角色模型**:
- **User**: 意图发起者
- **Agent**: 代表用户执行任务
- **Credential Provider**: 管理支付方式和认证
- **Merchant Endpoint**: 接收 Mandate 并执行结算
- **Issuer/Network**: 授权交易

**支付方式**: AP2 同时支持信用卡/借记卡、稳定币和实时银行转账。通过与 Coinbase 的 **A2A x402 扩展**，支持加密货币微支付和 Agent 间即时结算。

#### 1.4.3 Stripe Tempo Machine Payments Protocol (MPP)

2026 年 3 月 18 日，由 Stripe 和 Paradigm 支持的 **Tempo 区块链**主网上线，同时发布了 **Machine Payments Protocol (MPP)**。

**核心创新 — Sessions（会话）**:
MPP 引入了 **"Sessions"** 原语 —— 本质上是 "OAuth for Money"：
- Agent 一次性授权一个消费上限
- 随后在消费服务（数据、计算、API 调用）时持续流式微支付
- 使真正的 Pay-per-use 支付在互联网规模上可行

**生态支持**: Stripe、Visa、Lightspark 已将该标准扩展至卡支付、钱包和 Bitcoin Lightning。上线首日，支付目录已包含超过 **100 个服务**（模型提供商、计算平台、数据 API）。

### 1.5 Agent 的资产管理和授权模型

当前 Agent 资产管理的主流方案：

| 方案 | 描述 | 代表项目 |
|------|------|---------|
| **Smart Account (ERC-4337)** | 可编程授权逻辑、支出策略、Gas 代付 | Coinbase Agentic Wallets |
| **Session Keys** | 临时密钥、限定范围和时间的操作权限 | Tempo MPP Sessions |
| **Mandate-based** | 加密签名的用户授权令，不可篡改 | Google AP2 |
| **Credit System** | 预付费积分制，按使用量扣减 | Nevermined Flex Credits |
| **Spending Caps** | 设定每日/每周消费上限 | "Agent 每天最多在工具上花 $5" |
| **Multi-sig / DAO** | 多签或治理授权大额支出 | Safe Multisig |

**Nevermined 的 Credit 模型**尤其值得关注：
- **Flex Credits**: 预付费消费单元，可在多种定价结构间通用
- **Cost-based**: 基础成本 + 固定利润率（如 $0.002/1000 tokens + 20%）
- **Usage Tiering**: 免费额度 + 付费超额
- **Outcome-based**: 按结果付费（如 $5/每次预约成功，3% 订单金额）
- **Tamper-proof Metering**: 创建时加密签名的使用事件，不可追溯修改

---

## 2. x402 协议深度分析

### 2.1 设计理念

x402 是由 **Coinbase** 于 2025 年 5 月推出、**Coinbase 和 Cloudflare** 于 2025 年 9 月联合成立基金会的互联网原生支付开放标准。其核心理念是复活长期闲置的 HTTP 402 "Payment Required" 状态码，将支付嵌入 HTTP 协议本身。

**设计哲学**:
- **互联网原生**: 支付作为 HTTP 的一等公民，而非外部集成
- **Agent 优先**: 为 AI Agent 的自主支付场景设计
- **稳定币结算**: 使用 USDC/USDT 等稳定币，避免加密货币波动风险
- **去中心化**: 无需中介平台，点对点结算
- **低门槛**: 开发者无需维护区块链节点即可接入

### 2.2 技术架构

#### 2.2.1 四角色模型

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
                                  │ (Verification │
                                  │  + Settlement)│
                                  └──────┬───────┘
                                         │
                                         ▼
                                  ┌──────────────┐
                                  │  Blockchain   │
                                  │ (Base/Solana/ │
                                  │  Polygon...)  │
                                  └──────────────┘
```

四个核心角色：
1. **Client（客户端/Agent）**: 发起资源请求，签名支付
2. **Resource Server（资源服务器）**: 提供 API/数据/计算等服务，定义价格
3. **Facilitator（协调者）**: 验证支付有效性，执行链上结算
4. **Blockchain（区块链）**: 最终结算层

#### 2.2.2 支付流程（12 步详细流程）

```
1.  Client → Server:    GET /api/resource (无支付信息)
2.  Server → Client:    402 Payment Required + PAYMENT-REQUIRED header
3.  Client:             解析 PaymentRequired，选择支付方案
4.  Client:             创建 PaymentPayload，签名交易
5.  Client → Server:    GET /api/resource + PAYMENT-SIGNATURE header
6.  Server → Facilitator: POST /verify (验证支付有效性)
7.  Facilitator → Server:  验证结果（通过/拒绝）
8.  Server → Facilitator: POST /settle (执行链上结算)
9.  Facilitator → Chain:   提交链上交易
10. Chain → Facilitator:   确认交易
11. Facilitator → Server:  返回 PaymentExecutionResponse
12. Server → Client:       200 OK + PAYMENT-RESPONSE header + 资源
```

#### 2.2.3 HTTP Header 规范

**V2 更新后的 Header（符合标准规范，替换了 X-* 前缀）**:

| Header | 方向 | 描述 |
|--------|------|------|
| `PAYMENT-REQUIRED` | Server → Client | Base64 编码的 PaymentRequired 对象 |
| `PAYMENT-SIGNATURE` | Client → Server | Base64 编码的 PaymentPayload（已签名） |
| `PAYMENT-RESPONSE` | Server → Client | 区块链交易详情 |
| `SIGN-IN-WITH-X` | Client → Server | 基于 CAIP-122 的钱包身份认证（V2 即将推出） |

**PaymentRequired 结构示例**:
```json
{
  "scheme": "exact",
  "networkId": "eip155:8453",
  "maxAmountRequired": "10000",
  "resource": "https://api.example.com/premium-data",
  "description": "Premium API access",
  "mimeType": "application/json",
  "payTo": "0x1234...abcd",
  "maxTimeoutSeconds": 60,
  "asset": "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
  "extra": {}
}
```

### 2.3 支持的支付方式

#### 2.3.1 Exact Scheme（精确支付）

最基础的支付方案：转移精确金额（如支付 $1 阅读一篇文章）。

**支持的链和资产**:

| 链 | 资产 | 特点 |
|----|------|------|
| **Base (EVM)** | USDC | Coinbase 主推，手续费极低 |
| **Solana (SVM)** | USDC | 占 x402 交易量 50-80%，~400ms 确认 |
| **Polygon** | USDC/USDT | 低手续费 EVM 链 |
| **Avalanche** | USDC | 高吞吐量 |
| **Stellar** | USDC | 企业级支付 |
| **MultiversX** | 多资产 | 新兴链支持 |
| **Cronos** | 多资产 | CRO 生态 |

#### 2.3.2 V2 新增支付方案

V2 引入了模块化支付方案（Payment Scheme）注册机制：
- **传统支付**: ACH、SEPA、信用卡网络
- **Wallet Sessions**: 基于钱包身份的会话制支付（类似订阅）
- **Dynamic Routing**: 按请求动态选择支付接收方（适用于多租户/市场平台）

### 2.4 SDK 和集成方式

**官方 SDK**:
- **TypeScript/JavaScript**: `@x402/client`, `@x402/server`, `@x402/paywall`
- **Rust**: `x402-rs`（axum/tower 框架集成）
- **Python**: 社区实现

**集成模式**:

```typescript
// Server 端（以 Express 为例）
import { x402Middleware } from '@x402/server';

app.use('/premium', x402Middleware({
  price: '1000',  // 0.001 USDC (6 decimals)
  asset: 'USDC',
  network: 'base',
  facilitatorUrl: 'https://facilitator.x402.org'
}));

// Client 端（Agent）
import { x402Client } from '@x402/client';

const response = await x402Client.fetch('https://api.example.com/premium', {
  wallet: agentWallet,
  maxPayment: '10000'  // 最多支付 0.01 USDC
});
```

**V2 生命周期钩子（Lifecycle Hooks）**:
```
before_payment → payment_execution → after_payment
before_settlement → settlement_execution → after_settlement
```
开发者可注入自定义逻辑：条件路由、自定义指标、复杂故障恢复。

### 2.5 x402 与传统 API 定价对比

| 维度 | 传统 API（Stripe/PayPal） | x402 |
|------|--------------------------|------|
| 最低交易额 | ~$0.30（信用卡最低费用） | ~$0.0001（稳定币） |
| 结算速度 | T+1 到 T+3 天 | 200ms - 12s |
| 计费模型 | 月度订阅/预付费 | 按次/按量即时结算 |
| Agent 支持 | 需要 API Key + OAuth | 钱包签名即可 |
| 跨境费用 | 2.5-3.5% 额外费率 | 链上手续费（~$0.001） |
| 开发集成 | 完整 API 对接 | HTTP Middleware 即可 |
| 账户系统 | 需注册、KYC | 无需账户，钱包即身份 |

### 2.6 Coinbase 在 x402 中的角色

Coinbase 在 x402 生态系统中扮演多重角色：

1. **协议发起者**: x402 由 Coinbase 首创并开源
2. **基金会联合创始人**: 与 Cloudflare 共同创立 x402 Foundation（2025 年 9 月），Google 和 Visa 随后加入
3. **基础设施提供商**: Coinbase Developer Platform (CDP) 提供 Facilitator 服务
4. **钱包提供商**: AgentKit + Agentic Wallets 为 Agent 提供原生支付能力
5. **链运营商**: Base L2 是 x402 的首选结算链之一
6. **标准推动者**: 推动 x402 与 Google A2A、AP2 的集成

### 2.7 当前采用状态和案例

截至 2026 年 3 月的关键数据：

- **累计交易量**: 超过 **1 亿笔**支付（V2 发布后 3 个月内）
- **交易金额**: 处理 **$2,400 万**（截至 2025 年 12 月 7,500 万笔时的数据）
- **Nevermined 市场**: 138 万笔交易，72,500 买家，1,000 卖家
- **Cloudflare 集成**: "Pay-per-Crawl" 功能测试版
- **Google Cloud**: AP2 使用 x402 进行链上结算
- **Stellar**: 官方集成 x402 支持 Agent Economy
- **Cronos**: 推出官方 x402 Facilitator

**典型用例**:
- **API 付费访问**: AI 模型、数据集、计算、存储的按次计费
- **创作者微支付**: 打赏、付费内容、小额互动
- **MCP Server 付费**: 通过 x402 对 MCP Server 调用收费（Zuplo 方案）
- **Agent-to-Agent 服务**: Agent 互相支付完成子任务

---

## 3. EIP-8004 及相关支付 EIP

### 3.1 ERC-8004: Trustless Agents

#### 3.1.1 提案背景

ERC-8004 "Trustless Agents" 于 2025 年 8 月 13 日提出，2025 年 8 月 21 日正式发布，2026 年 1 月 29 日在**以太坊主网上线**。它是 AI Agent 链上信任基础设施的核心标准。

**设计理念**: ERC-8004 将区块链作为**控制平面（Control Plane）**，保持身份标识和信任信号在链上，而将细节丰富的数据（Agent 描述、能力列表等）放在链下。

#### 3.1.2 三大注册表

**1. Identity Registry（身份注册表）**

基于 ERC-721 NFT 标准，每个 Agent 获得一个全局唯一标识符：

```
全局 ID = eip155:{chainId}:{registryAddress}:{agentId}
```

核心接口:
```solidity
// 注册 Agent（铸造身份 NFT）
function register(string tokenURI) returns (uint256 agentId);

// 设置/获取链上元数据
function setMetadata(uint256 agentId, string key, bytes value);
function getMetadata(uint256 agentId, string key) returns (bytes value);
```

`tokenURI` 指向链下的 JSON 注册文件，包含：
- Agent 元数据（名称、描述、能力）
- 服务端点（A2A、MCP、OASF）
- Web3 原语（钱包地址、DID、ENS 名称）
- 支持的信任模型（`supportedTrust`）

**2. Reputation Registry（声誉注册表）**

带预授权的标准化反馈机制：

```solidity
// 给予反馈（需要预授权）
function giveFeedback(
    uint256 agentId,       // 目标 Agent
    uint8 score,           // 0-100 评分
    bytes32 tag1,          // 主分类
    bytes32 tag2,          // 子分类
    string calldata fileuri, // 链下上下文
    bytes32 filehash,      // 完整性哈希
    bytes memory feedbackAuth  // 授权签名
) external;

// 撤销反馈
function revokeFeedback(uint256 agentId, uint64 feedbackIndex) external;

// 聚合查询
function getSummary(
    uint256 agentId,
    address[] calldata clientAddresses,
    bytes32 tag1,
    bytes32 tag2
) returns (uint64 count, uint8 averageScore);
```

声誉系统的反垃圾机制：
- **预授权**: 只有获得授权的 `clientAddress` 才能提交反馈
- **索引限制**: `indexLimit` 控制每个授权者的最大提交次数
- **过期机制**: `expiry` 时间戳自动失效
- **链上+链下**: 简单过滤在链上，复杂聚合在链下

**3. Validation Registry（验证注册表）**

灵活的第三方验证框架，支持多种验证模型：

```solidity
// 发起验证请求
function validationRequest(
    address validatorAddress, // 验证者合约地址
    uint256 agentId,          // 被验证 Agent
    string requestUri,        // 链下验证数据
    bytes32 requestHash       // 数据承诺
) external;

// 提交验证响应
function validationResponse(
    bytes32 requestHash,
    uint8 response,           // 0-100 验证结果谱
    string responseUri,       // 证据/审计路径
    bytes32 responseHash,
    bytes32 tag               // 自定义分类
) external;

// 查询验证状态
function getValidationStatus(bytes32 requestHash)
    returns (address validator, uint256 agentId, uint8 response,
             bytes32 tag, uint256 lastUpdate);
```

支持的验证模型：
- **Stake-backed Re-execution**: 质押担保的重新执行验证
- **zkML (Zero-Knowledge ML)**: 零知识机器学习证明
- **TEE Attestation**: 可信执行环境证明
- **Governance Review**: 治理投票审查

#### 3.1.3 与支付的关系

ERC-8004 **刻意将支付排除在范围之外**，采用正交设计：
- 身份/信誉层：ERC-8004
- 支付层：x402 / AP2 / 其他
- 组合使用：通过 `supportedTrust` 字段声明，通过 Reputation 中的 proof-of-payment 字段关联交易

这种解耦设计使得 ERC-8004 可以与任何支付方案组合使用，而不被锁定在单一支付轨道。

### 3.2 EIP-7528: ETH (Native Asset) Address Convention

**提案内容**: 为 ETH 在与 ERC-20 代币同一上下文中使用时定义一个标准化的地址占位符。

**标准地址**: `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE`

**对支付的影响**:
- 统一了 ETH 和 ERC-20 代币在支付接口中的表示
- Paymaster 可以用相同接口处理 ETH 和 ERC-20 支付
- 简化了多资产支付的路由逻辑
- SuperPaymaster 中的 `consumeCredit` 系列函数可以统一处理不同资产类型

### 3.3 EIP-7702: Account Abstraction 的新时代

**核心内容**: EIP-7702 允许 EOA（外部拥有账户）在交易期间将执行委托给指定的智能合约，弥合了 EOA 和智能合约钱包之间的功能鸿沟。于 2025 年以太坊 **Pectra 升级**中正式上线。

**对支付流程的简化**:

1. **批量交易**: EOA 可以在一笔交易中完成 approve + transfer + 业务逻辑，无需分步操作
2. **灵活 Gas 支付**: 支持通过 ERC-20 代币支付 Gas 费用，或由第三方赞助
3. **减少交易数**: 原先需要 2-3 笔交易的流程可以合并为 1 笔
4. **与 ERC-4337 互补**: EOA 获得类似智能钱包的能力，但无需部署新合约

**对 Paymaster 的影响**:
- EIP-7702 使得 EOA 用户也能享受 Paymaster 的 Gas 代付服务
- 降低了 Account Abstraction 的入门门槛
- SuperPaymaster 的用户覆盖范围从 Smart Account 扩展到所有 EOA

### 3.4 ERC-3525: Semi-Fungible Token (SFT)

**核心模型**: `<ID, SLOT, VALUE>` 三元标量模型

```
Token {
  id: uint256      // 唯一标识（如 NFT）
  slot: uint256    // 分类槽位（同 slot 内 value 可互换）
  value: uint256   // 可分割的数值（如同质化代币）
}
```

**在支付中的潜在应用**:
- **Credit Voucher**: 充值凭证/信用额度的表示（slot = 社区, value = 剩余额度）
- **分期支付**: 将大额支付拆分为多个 SFT，按时间释放
- **多级会员**: 同一 slot 内不同 value 代表不同等级的服务权益
- **可转让额度**: 信用额度可以在用户间转移（value transfer）

**与 SuperPaymaster 的关联**:
xPNTs 代币本质上类似 SFT 的思想 —— 同一社区（slot）内的代币互相可替换（value），但不同社区的代币不可互换。ERC-3525 可能为未来的跨社区信用额度系统提供更灵活的表示方式。

### 3.5 EIP-1153: Transient Storage Opcodes

**核心内容**: 引入 `TLOAD` 和 `TSTORE` 两个新操作码，操作与 `SLOAD`/`SSTORE` 类似但数据在交易结束后自动清除。

**Gas 成本**: 约 100 gas（对比 `SSTORE` 的 20,000 gas 首次写入）

**对微支付优化的意义**:

1. **重入锁优化**: Paymaster 的重入保护从 ~20,000 gas 降至 ~100 gas
2. **临时状态跟踪**: 在一笔交易内追踪多次调用的累计消费，无需永久存储
3. **Flash Accounting**: 类似 Uniswap V4 的闪电记账模式，先记录再结算
4. **Batch Payment**: 批量微支付在交易内汇总，最终只写一次永久存储

**具体优化场景（对 SuperPaymaster）**:
```solidity
// 使用 transient storage 优化 reentrancy guard
// 节约 ~19,900 gas per transaction

// 批量 Agent 交易中的临时计费
// tstore(agent_address, cumulative_cost)
// 交易结束时一次性 sstore 更新总消费
```

### 3.6 其他支付相关的 EIP/ERC 提案

| 提案 | 名称 | 与支付的关系 |
|------|------|-------------|
| **ERC-4337** | Account Abstraction | Paymaster 机制的基础标准 |
| **EIP-8141** | Native Account Abstraction | 以太坊原生 AA，未来可能替代 ERC-4337 |
| **ERC-7683** | Cross-Chain Intents | 跨链意图标准，统一跨链支付接口 |
| **ERC-20** | Fungible Token | 稳定币支付的基础标准 |
| **EIP-2612** | Permit (ERC-20 Extension) | 无 Gas 批准，简化支付授权流程 |
| **ERC-4626** | Tokenized Vault | 收益型支付和储蓄产品的基础 |
| **EIP-7201** | Namespaced Storage Layout | UUPS 代理升级的存储安全保障 |

---

## 4. 微支付（Micropayment）方案研究

### 4.1 Payment Channel（State Channel）方案

**基本原理**: 双方在智能合约中锁定一定资金作为保证金，随后在链下进行一系列微支付，仅在通道开启和关闭时提交链上交易。

**技术架构**:
```
开通通道 (on-chain) → 链下微支付 × N → 关闭通道 (on-chain)
     ↓                    ↓                    ↓
  锁定资金            签名状态更新          结算最终余额
```

**优缺点分析**:

| 优点 | 缺点 |
|------|------|
| 即时确认（毫秒级） | 需要锁定资金 |
| 几乎零手续费 | 双方都需在线（或委托） |
| 交易隐私（链下） | 通道容量有限 |
| 理论上无限 TPS | 路由复杂（多跳支付） |

**代表项目**:
- **Bitcoin Lightning Network**: 最成熟的 Payment Channel 网络
- **Raiden Network (Ethereum)**: 以太坊版 Lightning
- **Sprites**: 学术研究优化方案，支持跨通道原子支付

**2025-2026 发展**: Galaxy Digital 预测 State Channel 将处理 25-30% 的 Layer 2 交易。MIT 2023 年的论文已提出基于格密码学的抗量子 State Channel，目标 2026-2027 年实现。

### 4.2 Rollup-based 微支付

**核心思路**: 利用 Layer 2 Rollup 的低 Gas 成本，直接在 L2 上执行微支付交易。

**方案对比**:

| 方案 | Gas 成本/笔 | 确认时间 | 适用场景 |
|------|------------|---------|---------|
| **Base (Optimistic Rollup)** | ~$0.001 | 2s (soft), 7d (finality) | x402 主推链 |
| **Arbitrum** | ~$0.001 | 250ms (soft) | DeFi 微支付 |
| **zkSync** | ~$0.005 | 数分钟（证明生成） | 高安全需求 |
| **Starknet** | ~$0.003 | 数小时（证明生成） | 大规模批量 |
| **Solana** | ~$0.00025 | 400ms | x402 主力链 |
| **Tempo (Stripe)** | 极低 | 亚秒 | MPP 原生链 |

**关键趋势**: L2 的 Gas 成本已低到可以直接执行微支付，无需额外的 Payment Channel 层。这是 x402 选择直接链上结算而非 Channel 方案的根本原因。

### 4.3 Streaming Payment（流式支付）

#### 4.3.1 Superfluid Protocol

**核心创新**: Super Token — ERC-20 标准的扩展，支持持续、自动化的价值传输。

**关键特性**:
- **Money Streaming**: 按秒计费的持续支付流（如工资、订阅）
- **Distributions**: 一对多的代币分发
- **Super Token**: 包装任何 ERC-20 为可流式传输的代币
- **GDA (General Distribution Agreement)**: 通用分发协议

**规模**: 超过 **121 万用户**，部署在 10 条链上（Polygon、Arbitrum、Optimism、Avalanche、Ethereum 等）。

**与 Agent 支付的结合**:
```
Agent ──────$0.001/秒────────► API Provider
       (持续流式支付，按秒扣费)
```

Agent 在使用 API 期间开启支付流，停止使用时关闭，实现真正的 Pay-per-second。

#### 4.3.2 Sablier Protocol

**核心模式**: 时间锁定的托管流——在固定时间段内线性释放代币。

**主要应用**:
- Vesting 计划
- Grant 分发
- 薪资流
- DAO RetroPGF（Optimism 已采用）

#### 4.3.3 LlamaPay

**特点**: 极简的薪资流协议，专注 DAO 场景，无手续费模型。

### 4.4 Pay-per-use 链上模型

当前主流的 Pay-per-use 链上模型：

**1. 预存-扣减模型（Deposit-Deduct）**
```solidity
// 用户预存资金
function deposit() external payable;

// 每次使用时扣减
function consumeCredit(address user, uint256 amount) internal;
```
这是 **SuperPaymaster 的 `_consumeCredit_pure()`** 采用的核心模型。

**2. 即时支付模型（Instant Pay）**
```
每次 API 调用 → 签名支付 → 验证 → 结算 → 返回结果
```
这是 **x402** 的核心模型。

**3. Session 模型（会话制）**
```
开启 Session（设定消费上限）→ 多次调用（累计扣费）→ 关闭 Session（结算）
```
这是 **Tempo MPP** 的核心模型。

**4. Credit Bundle 模型（额度包）**
```
购买 N 次调用额度 → 使用时扣减 → 额度用尽重新购买
```
这是 **Nevermined Flex Credits** 的核心模型。

**模型对比**:

| 模型 | 首次成本 | 单次成本 | 灵活性 | 适用场景 |
|------|---------|---------|--------|---------|
| 预存-扣减 | 中（需预存） | 极低（仅状态更新） | 中 | Paymaster Gas 代付 |
| 即时支付 | 无 | 中（每次链上交易） | 高 | API 按次收费 |
| Session | 低（一次授权） | 极低（链下累计） | 高 | Agent 长时间任务 |
| Credit Bundle | 中（批量购买） | 极低（链下扣减） | 中 | 企业 SaaS |

### 4.5 Subscription（订阅制）链上实现

链上订阅的关键技术组件：

**1. 智能合约自动扣费**
```solidity
// Approve 授权 + 定时调用
function processSubscription(address subscriber) external {
    require(block.timestamp >= nextPaymentTime[subscriber]);
    IERC20(token).transferFrom(subscriber, address(this), subscriptionFee);
    nextPaymentTime[subscriber] += interval;
}
```

**2. Superfluid 流式订阅**
```
订阅 = 持续的 Super Token 流
月费 $10 = $0.000003858/秒的持续支付
取消 = 关闭流
```

**3. ERC-20 Permit + 预授权**
利用 EIP-2612 Permit 实现一次签名授权后的自动扣费。

**4. 按量计费 (Usage-based)**
结合链上 Metering 和智能合约自动计算：
- API 调用次数追踪
- 资源消耗量度量
- 基于实际使用的分级定价

**当前市场**: SubscribeOnChain、Request Finance、Superfluid 等平台支持链上订阅，稳定币（USDC、PYUSD、EUROC）是主流支付媒介。

### 4.6 链上计量和账单系统

**三层架构**:

```
┌─────────────────────────────────┐
│    Metering Layer (计量层)       │
│  事件追踪 / 使用量度量 / 签名   │
├─────────────────────────────────┤
│    Pricing Layer (定价层)        │
│  Cost-plus / Tiering / Outcome  │
├─────────────────────────────────┤
│    Settlement Layer (结算层)     │
│  Stablecoin / Credit / Stream   │
└─────────────────────────────────┘
```

**Nevermined 的实现**:
- **实时事件处理**: 15,000 events/second
- **创建时签名**: 使用事件在创建时即被加密签名
- **只追加账本**: 不可追溯修改
- **逐行定价验证**: 支持独立审计
- **客户可访问**: API/CSV 导出

**Chainlink Data Streams Billing**:
- 链上计费与数据流绑定
- 按查询次数收费
- 自动化的费用结算

---

## 5. 跨链支付与结算

### 5.1 跨链桥支付方案

跨链支付的核心挑战：不同链上的资产如何安全、高效地转移和结算。

**2025-2026 市场格局**:
- LayerZero 占跨链桥交易量的 **75%**，日处理 120 万条消息
- CCIP 跨链转账金额在 2025 年暴增 **1,972%** 至 77.7 亿美元
- Delphi Digital 预测到 2027 年 60% 的互操作性协议将消失

### 5.2 Chainlink CCIP (Cross-Chain Interoperability Protocol)

**架构**: Chainlink 的去中心化预言机网络作为跨链消息和代币转移的安全层。

**CCIP 2.0 (2025 Q4 / 2026 初)**:
- 机构可选择自身风险偏好（安全性 vs 速度）
- Swift 银行系统集成 CCIP，连接公链和私链
- 支持在伦敦私有账本上结算交易并反映到公共 Ethereum L2

**对支付的意义**:
- **跨链 Gas 代付**: Paymaster 在 Chain A 收款，用户在 Chain B 使用服务
- **统一结算**: 多链交易在单一链上结算
- **传统金融桥接**: 银行通过 CCIP 与链上支付互通

### 5.3 LayerZero OFT (Omnichain Fungible Token)

**核心概念**: OFT 让代币原生存在于多条链上，无需传统桥接。

**技术特点**:
- **可自定义 DVN**: 开发者可为每条消息选择验证者（Google Cloud、Chainlink、Polyhedra）
- **2025 年收购 Stargate**: 消息传递和流动性层合并为统一栈
- **日均交易**: 120 万条消息，2.93 亿美元日均转账

**对 SuperPaymaster 的启示**:
xPNTs 代币未来可通过 LayerZero OFT 标准实现跨链存在——用户在任何链上持有的 xPNTs 都可用于 SuperPaymaster 的 Gas 代付。

### 5.4 Wormhole 跨链消息传递

**现状**: 经历 2022 年 3.25 亿美元黑客攻击和 2025 年 4 月 USDC 桥冻结 14 亿美元的事件后，Wormhole 的市场信任度有所下降，但仍是重要的跨链基础设施。

### 5.5 跨链支付标准化趋势

**IEEE 3221.01-2025**: 跨链互操作性的 IEEE 标准

**ERC-7683**: Cross-Chain Intents 标准，定义了统一的跨链意图表示格式，使不同的跨链协议可以互操作。

**市场整合预期**: Chainlink CCIP 和 LayerZero 将成为机构级互操作性的主导者。

---

## 6. 对 SuperPaymaster 微支付设计的启示

### 6.1 与 `_consumeCredit_pure()` 设计最相关的标准和协议

SuperPaymaster 的 `_consumeCredit_pure()` 函数实现了一个**预存-扣减（Deposit-Deduct）**模型，这与以下方案高度相关：

#### 6.1.1 直接对标

| 标准/协议 | 相关性 | 具体关联 |
|-----------|--------|---------|
| **EIP-1153 (Transient Storage)** | ★★★★★ | 批量 UserOp 中的临时计费优化，一笔交易内多次 `_consumeCredit` 调用的中间状态可用 transient storage，最终只写一次 `sstore` |
| **Nevermined Flex Credits** | ★★★★★ | 几乎完全对标的信用额度扣减模型，按量付费+预存机制 |
| **x402 Exact Scheme** | ★★★★☆ | 精确金额支付方案，但 x402 是即时链上结算而非预存扣减 |
| **Tempo MPP Sessions** | ★★★★☆ | 会话制消费上限 + 流式扣减，比单次 `_consumeCredit` 更灵活 |
| **ERC-3525 SFT** | ★★★☆☆ | 可为信用额度提供更灵活的 ID+Slot+Value 表示，支持跨社区额度转移 |
| **EIP-7528** | ★★★☆☆ | 统一 ETH/ERC-20 在支付接口中的表示 |
| **Superfluid Streaming** | ★★☆☆☆ | 流式支付模式与 Paymaster 的按次计费不同，但可用于持续型服务 |

#### 6.1.2 优化建议

```
当前:  UserOp → _consumeCredit_pure() → sstore(新余额)
                                        [~20,000 gas]

优化后: UserOp₁ → tstore(临时累计)     [~100 gas]
       UserOp₂ → tload + tstore        [~200 gas]
       ...
       UserOpN → tload + sstore(最终)   [~20,100 gas]

节省: (N-1) × ~19,900 gas
```

### 6.2 x402 模式如何与 ERC-4337 Paymaster 结合

#### 6.2.1 当前架构差异

```
x402 模式:
  Agent → HTTP 402 → 签名支付 → USDC Transfer → 获取资源

ERC-4337 Paymaster 模式:
  User → UserOp → Bundler → EntryPoint → Paymaster.validatePaymasterUserOp()
                                        → 执行交易 → Paymaster.postOp()
```

#### 6.2.2 集成方案

Coinbase 已在 GitHub 上提出了 **x402 + ERC-4337 集成提案** (Issue #639)：

**方案 A: x402 作为 Paymaster 的资金来源**
```
Agent 通过 x402 支付 → 资金进入 Paymaster 合约 → Paymaster 赞助 UserOp Gas
```
x402 支付为 Paymaster 补充 deposit，Paymaster 继续使用 ERC-4337 标准流程赞助 Gas。

**方案 B: Paymaster 作为 x402 的 Facilitator**
```
x402 PaymentRequired → Agent 签名 UserOp → Paymaster 验证 + 结算 → 执行链上交易
```
Paymaster 扮演 x402 Facilitator 角色，将 x402 支付验证嵌入 `validatePaymasterUserOp()`。

**方案 C: 混合模式（推荐）**
```
                    ┌──────────────┐
                    │   x402 Layer │  (服务付费)
                    │  HTTP 402    │
                    └──────┬───────┘
                           ▼
┌─────────┐     ┌──────────────────┐     ┌──────────────┐
│  Agent   │ ──►│  SuperPaymaster  │ ──► │  EntryPoint  │
│ (Smart   │     │  (Gas 代付 +     │     │  (ERC-4337)  │
│ Account) │ ◄──│   xPNTs 结算)    │ ◄── │              │
└─────────┘     └──────────────────┘     └──────────────┘
```

x402 处理服务层支付（API 调用费），SuperPaymaster 处理基础层支付（Gas 费）。两者互补而非竞争。

#### 6.2.3 SuperPaymaster 的独特价值

在 x402/AP2/MPP 的生态中，SuperPaymaster 占据了一个独特的位置：

| 层级 | 协议 | 功能 |
|------|------|------|
| **应用层支付** | x402 / AP2 / MPP | Agent 为服务付费（API、数据、计算） |
| **Gas 层代付** | **SuperPaymaster** | 社区为用户/Agent 代付 Gas |
| **身份信任层** | ERC-8004 | Agent 身份验证和声誉管理 |
| **结算层** | Base / Solana / Ethereum | 最终链上结算 |

**SuperPaymaster 是唯一一个专注于社区化 Gas 代付的协议**——x402 等协议解决的是 "Agent 为资源付费" 的问题，而 SuperPaymaster 解决的是 "谁来付 Gas" 的问题。

### 6.3 Agent 支付场景对 Paymaster 的新需求

基于 2025-2026 年 Agent Economy 的发展，SuperPaymaster 需要考虑以下新需求：

#### 6.3.1 Agent 身份集成

```solidity
// 新增: 支持 ERC-8004 Agent 身份验证
function validatePaymasterUserOp(
    PackedUserOperation calldata userOp,
    bytes32 userOpHash,
    uint256 maxCost
) external returns (bytes memory context, uint256 validationData) {
    // 1. 验证 Agent 的 ERC-8004 身份
    // 2. 查询 Agent 的 Reputation Score
    // 3. 基于信誉动态调整 Gas 赞助策略
    // 4. 高信誉 Agent → 更高赞助额度 / 更低费率
}
```

#### 6.3.2 Session-based Gas 预算

受 Tempo MPP Sessions 启发：
```solidity
// Agent 开启 Gas 预算会话
function openGasSession(
    address agent,
    uint256 maxGasBudget,  // 最大 Gas 预算
    uint256 expiry         // 过期时间
) external;

// 每次 UserOp 自动从 session 扣减
// 无需每次 approve
```

#### 6.3.3 多 Agent 批量赞助

```solidity
// 一笔交易赞助多个 Agent 的 Gas
function batchSponsor(
    address[] agents,
    uint256[] maxGasPerAgent
) external;
```

#### 6.3.4 Dynamic Pricing（动态定价）

基于实时 Agent 活跃度和链上拥堵程度动态调整赞助策略：
- Agent 信誉评分影响 Gas 赞助比例
- 链上 Gas 价格高时自动降低赞助上限
- 社区代币（xPNTs）汇率实时调整

#### 6.3.5 跨链 Gas 代付

利用 LayerZero/CCIP 实现：
- 用户在 Chain A 持有 xPNTs
- 在 Chain B 使用 SuperPaymaster 代付 Gas
- 跨链消息同步扣减 Chain A 上的 xPNTs 余额

### 6.4 建议的技术选型和架构方向

#### 6.4.1 短期优化（v4.2 - v4.3）

| 优化项 | 技术方案 | 预期效果 |
|--------|---------|---------|
| **Transient Storage 优化** | EIP-1153 TLOAD/TSTORE | 批量 UserOp 节省 ~19,900 gas/笔 |
| **EIP-7702 兼容** | 支持 delegated EOA | 用户覆盖范围扩大 |
| **EIP-7528 标准化** | 统一 ETH/ERC-20 接口 | 简化多资产支付逻辑 |
| **Credit Session** | 会话制额度管理 | 减少链上交互次数 |

#### 6.4.2 中期拓展（v5.0）

| 拓展方向 | 技术方案 | 战略意义 |
|---------|---------|---------|
| **ERC-8004 集成** | Identity + Reputation 查询 | Agent 身份可验证，信誉驱动赞助 |
| **x402 Facilitator 模式** | 实现 Paymaster-as-Facilitator | 连接 Agent 服务支付生态 |
| **Streaming Gas** | Superfluid 集成 | 持续型服务的 Gas 流式代付 |
| **Agent 专用 API** | REST/gRPC + x402 PayWall | Paymaster 服务本身可被 Agent 发现和支付 |

#### 6.4.3 长期愿景（v6.0+）

| 方向 | 技术方案 | 目标 |
|------|---------|------|
| **跨链 Paymaster** | LayerZero OFT + CCIP | xPNTs 跨链 + 多链 Gas 代付 |
| **AP2 集成** | Google AP2 Mandate 支持 | 企业级 Agent 支付 |
| **MPP 兼容** | Tempo Sessions 支持 | 与 Stripe 生态打通 |
| **zkML 验证** | Agent 行为零知识证明 | 可验证的 Agent Gas 使用 |

#### 6.4.4 推荐架构演进路线

```
Phase 1 (当前 v4.x):
  SuperPaymaster ← ERC-4337 ← xPNTs/aPNTs
  [社区 Gas 代付基础设施]

Phase 2 (v5.x):
  SuperPaymaster ← ERC-4337 + x402 Facilitator ← xPNTs + USDC
  + ERC-8004 Identity/Reputation
  [Agent-aware Gas 代付 + 服务支付网关]

Phase 3 (v6.x):
  SuperPaymaster Network ← Multi-chain (LayerZero/CCIP)
  + AP2 Mandate + MPP Session
  + Streaming Gas (Superfluid)
  [跨链 Agent Economy 基础设施]
```

---

## 7. 参考文献

### x402 协议
1. [x402 Official Website - Internet-Native Payments Standard](https://www.x402.org/)
2. [Coinbase x402 GitHub Repository](https://github.com/coinbase/x402)
3. [Coinbase Developer Documentation - x402](https://docs.cdp.coinbase.com/x402/welcome)
4. [Introducing x402 V2: Evolving the Standard](https://www.x402.org/writing/x402-v2-launch)
5. [x402 Facilitator Documentation](https://docs.x402.org/core-concepts/facilitator)
6. [Introducing x402 - Coinbase Blog](https://www.coinbase.com/developer-platform/discover/launches/x402)
7. [Inside x402: Is It the Future of Online Payments? - DWF Labs](https://www.dwf-labs.com/research/inside-x402-how-a-forgotten-http-code-becomes-the-future-of-autonomous-payments)
8. [x402 Protocol Architecture for AI Agents - Chainstack](https://chainstack.com/x402-protocol-for-ai-agents/)
9. [Launching the x402 Foundation - Cloudflare Blog](https://blog.cloudflare.com/x402/)
10. [x402 on Stellar](https://stellar.org/blog/foundation-news/x402-on-stellar)
11. [x402 Feature Request: EIP-4337 Support - GitHub Issue #639](https://github.com/coinbase/x402/issues/639)

### ERC-8004 及相关 EIP
12. [ERC-8004: Trustless Agents - Official EIP](https://eips.ethereum.org/EIPS/eip-8004)
13. [ERC-8004 Practical Explainer - Composable Security](https://composable-security.com/blog/erc-8004-a-practical-explainer-for-trustless-agents/)
14. [ERC-8004 Explained - Backpack Exchange](https://learn.backpack.exchange/articles/erc-8004-explained)
15. [ERC-8004 with Reputation & Validation - BuildBear](https://www.buildbear.io/blog/erc-8004)
16. [ERC-7528: ETH Address Convention](https://eips.ethereum.org/EIPS/eip-7528)
17. [EIP-7702: Smart EOAs Deep Dive](https://hackmd.io/@colinlyguo/SyAZWMmr1x)
18. [ERC-3525: Semi-Fungible Token](https://eips.ethereum.org/EIPS/eip-3525)
19. [EIP-1153: Transient Storage Opcodes](https://eips.ethereum.org/EIPS/eip-1153)

### AI Agent 经济与支付
20. [The Convergence of AI and Cryptocurrency - Chainalysis](https://www.chainalysis.com/blog/ai-and-crypto-agentic-payments/)
21. [The Agent Economy: Blockchain-Based Foundation - arXiv](https://arxiv.org/html/2602.14219v1)
22. [Crypto Settlements in Agentic Economy Statistics - Nevermined](https://nevermined.ai/blog/crypto-settlements-agentic-economy-statistics)
23. [CV VC Insights: AI Agents as Catalyst for Onchain Finance](https://www.cvvc.com/blogs/cv-vc-insights-ai-agents-as-the-catalyst-for-onchain-finance)
24. [AI Agent Payment Infrastructure - Tiger Research](https://reports.tiger-research.com/p/aiagentpayment-eng)
25. [AI Agent Payment Systems Guide 2026 - Nevermined](https://nevermined.ai/blog/ai-agent-payment-systems)

### Agent 钱包与工具
26. [Coinbase AgentKit GitHub](https://github.com/coinbase/agentkit)
27. [Coinbase Agentic Wallets Launch](https://www.coinbase.com/developer-platform/discover/launches/agentic-wallets)
28. [World AgentKit with x402 - CoinDesk](https://www.coindesk.com/tech/2026/03/17/sam-altman-s-world-teams-up-with-coinbase-to-prove-there-is-a-real-person-behind-every-ai-transaction)
29. [Visa CLI for AI Agent Payments](https://www.cryptotimes.io/2026/03/19/visa-introduces-cli-for-ai-agents-to-make-crypto-payments/)

### Agent 支付协议
30. [Google AP2 - Agent Payments Protocol](https://cloud.google.com/blog/products/ai-machine-learning/announcing-agents-to-payments-ap2-protocol)
31. [AP2 Protocol Documentation](https://ap2-protocol.org/)
32. [Google x402 + A2A Extension](https://www.coinbase.com/developer-platform/discover/launches/google_x402)
33. [Stripe Tempo Mainnet Launch](https://www.coindesk.com/tech/2026/03/18/stripe-led-payments-blockchain-tempo-goes-live-with-protocol-for-ai-agents)
34. [Tempo Machine Payments Protocol - Unchained](https://unchainedcrypto.com/tempo-mainnet-launches-with-ai-agent-payment-standard/)
35. [Visa AI Agent Stablecoin Payments - CoinDesk](https://www.coindesk.com/tech/2026/03/15/visa-is-ready-for-ai-agents-so-is-coinbase-they-re-building-very-different-internets/)

### 微支付与流式支付
36. [Superfluid Protocol](https://superfluid.org/)
37. [Sablier Token Streaming Models](https://blog.sablier.com/overview-token-streaming-models/)
38. [State Channels for Micropayments - TokenMinds](https://tokenminds.co/blog/knowledge-base/state-channels-for-micropayments)

### 跨链支付
39. [Chainlink CCIP for Banks - BlockEden](https://blockeden.xyz/blog/2026/01/12/chainlink-ccip-cross-chain-interoperability-tradfi-bridge/)
40. [Cross-Chain Messaging Comparison - Yellow](https://yellow.com/research/cross-chain-messaging-comparing-ibc-wormhole-layerzero-ccip-and-more)
41. [Multi-Chain Stablecoin Payments Guide 2026 - AlphaPoint](https://alphapoint.com/blog/multi-chain-stablecoin-payments-the-enterprise-infrastructure-guide-for-2026)

### 链上订阅与计费
42. [On-Chain Subscription Billing - SubscribeOnChain](https://subscribeonchain.com/2025/10/02/how-proration-enhances-onchain-subscription-billing-for-saas-and-web3-platforms/)
43. [Stablecoin Payments in Subscription Platforms - TransFi](https://www.transfi.com/blog/stablecoin-payments-in-subscription-platforms-automating-billing-via-smart-contracts)
44. [Making x402 Programmable - Nevermined](https://nevermined.ai/blog/making-x402-programmable)

---

> **免责声明**: 本报告基于 2025-2026 年 3 月公开可获取的信息编写，相关协议和标准仍在快速发展中。具体技术细节请以官方文档和最新版本为准。
