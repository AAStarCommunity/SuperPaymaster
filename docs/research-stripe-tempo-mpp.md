# Stripe Tempo & MPP 深度研究报告

> Version: 1.1.0 | Date: 2026-03-22 | Author: Claude Code Research

---

## 目录

1. [Tempo 区块链技术架构](#1-tempo-区块链技术架构)
2. [MPP 协议深度分析](#2-mpp-machine-payments-protocol-深度分析)
3. [SPT 共享支付令牌](#3-spt-shared-payment-tokens)
4. [ACP 代理商务协议](#4-acp-agentic-commerce-protocol)
5. [生态系统全景](#5-生态系统全景)
6. [开发者体验与集成](#6-开发者体验与集成)
7. [MPP vs x402 竞争格局](#7-mpp-vs-x402-竞争格局)
8. [SuperPaymaster 借鉴分析](#8-superpaymaster-借鉴分析)
   - 8.1-8.5: 战略/产品/技术栈/生态/行动建议
   - 8.6: [深度代码级借鉴（战术层）](#86-深度代码级借鉴战术层)
9. [参考资源](#9-参考资源)

---

## 1. Tempo 区块链技术架构

### 1.1 基本定位

Tempo 是由 **Stripe** 和 **Paradigm** 共同孵化的独立公司开发的 **Layer-1 区块链**，专为稳定币支付设计。与以太坊等通用区块链不同，Tempo 将所有架构决策优化为支付场景——高吞吐、低延迟、亚美分级手续费、合规内嵌。

| 参数 | 值 |
|------|-----|
| 类型 | Layer-1, EVM 兼容 (Osaka hardfork) |
| 执行引擎 | Reth SDK (Paradigm 的 Rust Ethereum 客户端) |
| 共识机制 | Simplex BFT (via Commonware) |
| TPS | 测试网 20,000; 目标 200,000+ |
| 出块时间 | ~300-600ms |
| 最终性 | 确定性最终性, ~0.5 秒, 无链重组 |
| Gas 代币 | **无原生代币**; 以任意稳定币支付 gas |
| 链 ID (主网) | 4217 |
| 链 ID (测试网 Moderato) | 42431 |
| Token 标准 | TIP-20 (ERC-20 支付增强超集) |
| 许可证 | Apache 2.0 |
| 主网上线 | 2026-03-18 |
| 融资 | Series A $500M, 估值 $5B (2025-10) |

### 1.2 Simplex BFT 共识

Tempo 采用 **Simplex BFT** 共识协议，由 [Commonware](https://github.com/commonwarexyz/monorepo) 实现。Tempo 对 Commonware 进行了 **$25M 战略投资**。

核心特性：
- **仅需两轮达成安全性**：Propose → Vote（传统 PBFT 需 3 轮）
- **跨区块流水线化**：构建下一区块的同时异步完成当前区块确认
- **确定性最终性**：无链重组，正常 0.5 秒完成
- **BLS 签名聚合**：缓冲验证，处理每秒数千签名
- **理论延迟**（1/3 故障，80ms 网络延迟）：

| 协议 | 确认时间 |
|------|---------|
| **Simplex** | **400ms** |
| Algorand Agreement | 480ms |
| ICC | 560ms |
| HotStuff | 2480ms |

论文：ePrint 2023/463, 发表于 TCC 2023, 作者 Benjamin Y. Chan & Rafael Pass (Cornell)

### 1.3 无原生代币模型

这是 Tempo 最激进的设计决策：

- **Gas 费用以 USD 稳定币支付**（USDC, USDT, USDB）
- **内嵌 Fee AMM** 自动将用户支付的稳定币转换为验证者偏好的稳定币
- 验证者不收取"区块奖励"，收入来自 Gas 费
- **无代币意味着无投机**——所有价值流转通过稳定币

支持的稳定币：
- USDC (Circle) — 主网: `0x20c000000000000000000000b9537d11c60e8b50`
- USDT (Tether)
- USDB (Bridge/Stripe 发行)

### 1.4 TIP-20 代币标准

TIP-20 是 ERC-20 的支付增强超集，完全向后兼容 ERC-20：

| 功能 | 描述 |
|------|------|
| 转账备注 (Memos) | 32 字节备注附加到 transfer/mint/burn，用于发票 ID |
| TIP-403 合规策略 | 外部策略注册表——白名单/黑名单控制 |
| 奖励分发 | Opt-in 收益分发系统 |
| 专用支付通道 | Payment Lanes，消除 noisy neighbor 竞争 |
| 原生对账 | on-transfer memos + commitment patterns |
| 转账成本 | < $0.001 |

### 1.5 原生账户特性

Tempo 协议层原生支持：

- **批量支付 (Batched Payments)**：原子化多操作（payroll, settlements, refunds）
- **Gas 代付 (Fee Sponsorship)**：应用可替用户支付 gas——**协议原生，非 ERC-4337**
- **定时支付 (Scheduled Payments)**：协议级别定期/定时付款
- **WebAuthn/P256 认证**：Passkeys 生物识别、安全飞地、跨设备同步

### 1.6 Stripe 全栈整合

```
                    Stripe Dashboard / PaymentIntents API
                              ↕
                    Stripe 合规、税务、欺诈检测
                              ↕
                    Bridge (稳定币发行 & 流动性 API)
                              ↕
                    Privy (钱包 & 密钥管理)
                              ↕
                    Tempo L1 (链上结算层)
```

商户结算流程：
1. Agent/用户在 Tempo 上以 USDC 支付
2. Stripe 自动检测链上结算
3. 通过 Bridge 将稳定币转换为法币
4. 资金结算到商户 Stripe 余额
5. 按标准 Stripe payout schedule 付款到银行账户

### 1.7 团队与融资

| 信息 | 详情 |
|------|------|
| CEO | Matt Huang (Paradigm 联合创始人, Stripe 董事会成员) |
| 首席研究员 | Dankrad Feist (前以太坊核心研究员) |
| 团队规模 | ~40-50 人 |
| Series A | $500M, 估值 $5B, 2025-10 |
| 投资方 | Thrive Capital, Greenoaks Capital |
| 战略投资 | $25M → Commonware |
| 首批投资者 | Stripe, Paradigm |

### 1.8 验证者网络

- 主网启动时为**许可制**，约 4 个验证者
- 设计合作伙伴（验证者候选）：Visa, Mastercard, OpenAI, Deutsche Bank, UBS, Shopify, Klarna
- 路线图：过渡为无许可 PoS

### 1.9 与以太坊的关系

Tempo 是**独立 L1**，不是 L2，但深度兼容以太坊生态：
- EVM 兼容（Osaka hardfork），支持 Solidity
- 开发工具完全兼容：Foundry, Hardhat, 所有 JSON-RPC 方法
- 通过标准桥接连接以太坊（理想情况下由 Circle 运营官方 USDC 桥）
- Bridge (Stripe 子公司) 作为跨链流动性协调层

---

## 2. MPP (Machine Payments Protocol) 深度分析

### 2.1 协议概述

MPP 由 **Tempo Labs** 和 **Stripe** 共同撰写，标准化了 HTTP 402 Payment Required 的支付流程。已提交 **IETF 标准轨道**草案。

- 官网: [mpp.dev](https://mpp.dev)
- 规范仓库: [github.com/tempoxyz/mpp-specs](https://github.com/tempoxyz/mpp-specs)
- Stripe 文档: [docs.stripe.com/payments/machine/mpp](https://docs.stripe.com/payments/machine/mpp)

### 2.2 HTTP 402 核心流程

```
Client                                    Server
  |                                         |
  |  1. GET /api/resource                   |
  |  ─────────────────────────────────────> |
  |                                         |
  |  2. 402 Payment Required                |
  |     WWW-Authenticate: Payment           |
  |     (challenge: 金额/方法/接收地址/     |
  |      HMAC 绑定 challenge ID)            |
  |  <───────────────────────────────────── |
  |                                         |
  |  3. 完成支付 (链上/SPT/Lightning)       |
  |                                         |
  |  4. GET /api/resource                   |
  |     Authorization: Payment credential   |
  |  ─────────────────────────────────────> |
  |                                         |
  |  5. 200 OK + Payment-Receipt header     |
  |  <───────────────────────────────────── |
```

### 2.3 协议模块结构（四层）

```
┌─────────────────────────────────────────┐
│  Extensions: discovery, identity        │
├─────────────────────────────────────────┤
│  Methods: Tempo, Stripe SPT,           │
│           Lightning, Card (Visa)        │
├─────────────────────────────────────────┤
│  Intents: charge, session, auth         │
├─────────────────────────────────────────┤
│  Core: HTTP 402 语义, IANA 注册表       │
└─────────────────────────────────────────┘
```

### 2.4 两种支付意图

#### Charge Intent（一次性支付）

用于逐请求计费（pay-per-call API）：

```typescript
// Server (mppx + Hono)
import { Mpp } from 'mppx'
import { tempo, ChargeIntent } from 'mppx/methods/tempo'

const mpp = Mpp.create({
  method: tempo({
    intents: { charge: new ChargeIntent() },
    recipient: "0x742d35Cc6634...",
  }),
})

app.get('/paid', mpp.pay({ amount: '0.50' }), (c) => {
  return c.json({ data: '...' })
})
```

#### Session Intent（流式支付）⭐ 核心创新

用于持续性 Agent 交互（LLM token 计费、数据流等）：

```
Agent                    Server              On-chain Escrow
  |                        |                      |
  | ──── deposit($10) ────────────────────────────>|  ← 1. 开通通道
  |                        |                      |
  | ── request + voucher₁ ──>|                    |  ← 2. 签发 EIP-712 voucher
  |                        | verify sig (μs)      |     "我已累计消费 $0.01"
  |<── response + receipt ──|                      |
  |                        |                      |
  | ── request + voucher₂ ──>|                    |     "我已累计消费 $0.02"
  |<── response + receipt ──|                      |
  |          ...           |                      |
  | ── request + voucher_N ──>|                   |     "我已累计消费 $3.50"
  |<── response + receipt ──|                      |
  |                        |                      |
  |                        |── close(voucher_N) ──>|  ← 3. 结算: 服务器取走 $3.50
  |<── refund($6.50) ──────────────────────────────|     退还 $6.50 给 Agent
```

**核心机制：**
1. Agent 将资金存入链上 escrow 合约，设定 `maxDeposit` 上限
2. 每次消费资源，client 签署 EIP-712 typed data voucher，累计金额递增
3. 签名验证是纯 CPU 运算 (ecrecover)，**微秒级延迟，无需 RPC/链上调用**
4. 资金不足时可追加存款，无需关闭通道
5. 服务器以最高金额 voucher 调用 `close()`，链上结算最终余额

**核心优势：** 数千次微交易聚合为单次链上结算。可实现**逐 LLM token 计费**级别的粒度。

### 2.5 支持的支付方法

| 方法 | 类型 | 场景 | 提供方 |
|------|------|------|--------|
| Tempo | 稳定币 (TIP-20) | 亚秒结算，< $0.001 费用 | Tempo Labs |
| Stripe SPT | 信用卡/钱包/BNPL | 法币支付通道 | Stripe |
| Lightning | Bitcoin BOLT11 | 比特币微支付 | Lightspark |
| Card (mpp-card) | 加密网络令牌 | 直接 Visa 卡支付 | Visa |

### 2.6 传输绑定

MPP 不仅支持 HTTP，还支持：
- **HTTP Transport**：标准 WWW-Authenticate / Authorization headers
- **MCP/JSON-RPC Transport**：用于 AI 工具调用的支付流

---

## 3. SPT (Shared Payment Tokens)

### 3.1 定义

SPT 是 Stripe 为 Agent 支付创建的**新支付原语**——作用域受限的、一次性的支付方法授权令牌。Agent 无需看到用户信用卡信息即可代表用户发起支付。

**类比：** SPT 就像信用卡的"代客钥匙"——只能在特定商户、特定金额范围内使用一次。

### 3.2 工作流程

```
User                Agent              Stripe API          Merchant
 |                    |                    |                   |
 | 1. 授权支付方法 ──>|                    |                   |
 |                    | 2. 请求 SPT ──────>|                   |
 |                    |    (payment_method, |                   |
 |                    |     usage_limits,   |                   |
 |                    |     seller_details) |                   |
 |                    | 3. 返回 spt_xxx <──|                   |
 |                    |                    |                   |
 |                    | 4. 提交 SPT ───────────────────────────>|
 |                    |                    |                   |
 |                    |                    | 5. PaymentIntent <─|
 |                    |                    |    (spt_xxx)       |
 |                    |                    | 6. 处理收费 ──────>|
```

### 3.3 安全约束

- 单次使用
- 限定特定商户
- 限定金额上限 (`max_amount`)
- 分钟级过期 (`expires_at`)
- 可随时撤销
- 不暴露底层支付凭证

### 3.4 Webhook 事件

| 事件 | 接收方 | 含义 |
|------|--------|------|
| `shared_payment.granted_token.used` | 商户 | SPT 已用于支付 |
| `shared_payment.granted_token.deactivated` | 商户 | SPT 撤销/过期 |
| `shared_payment.issued_token.used` | Agent | 支付完成通知 |
| `shared_payment.issued_token.deactivated` | Agent | 令牌失效通知 |

---

## 4. ACP (Agentic Commerce Protocol)

### 4.1 基本信息

| 项目 | 详情 |
|------|------|
| 全名 | Agentic Commerce Protocol |
| 维护方 | **OpenAI + Stripe** (Founding Maintainers) |
| 许可证 | Apache 2.0 |
| GitHub | [agentic-commerce-protocol](https://github.com/agentic-commerce-protocol/agentic-commerce-protocol) |
| Stars | 1,281 |
| 状态 | Beta |

### 4.2 ACP vs MPP 的关系

- **ACP**：高层商务协议——Agent 如何发现商品、创建购物车、结算。定义"买什么"和"怎么买"
- **MPP**：底层支付协议——Agent 如何在 HTTP 层完成支付。定义"怎么付钱"
- 两者通过 **SPT** 作为共同支付原语连接

### 4.3 核心 API

| 方法 | 端点 | 用途 |
|------|------|------|
| POST | `/checkouts` | 创建结账会话 |
| GET | `/checkouts/:id` | 获取结账状态 |
| PUT | `/checkouts/:id` | 更新商品/地址 |
| POST | `/checkouts/:id/complete` | 完成支付 |
| POST | `/checkouts/:id/cancel` | 取消 |

支持：实体商品（带配送）、数字商品、订阅、异步购买。

---

## 5. 生态系统全景

### 5.1 Agentic Payment 协议栈

```
┌─────────────────────────────────────────────────┐
│  Discovery    │ ACP (OpenAI+Stripe)             │
│               │ Agent Skills / SKILL.md          │
│               │ MPP Payments Directory (100+)    │
├─────────────────────────────────────────────────┤
│  Payment      │ MPP (Tempo+Stripe) ← Session    │
│  Protocol     │ x402 (Coinbase)    ← Per-request │
│               │ AP2 (Google)       ← Trust/Auth  │
├─────────────────────────────────────────────────┤
│  Settlement   │ Tempo L1 (payments-native)       │
│               │ Base L2 (Coinbase)               │
│               │ Ethereum L1 / other EVM          │
├─────────────────────────────────────────────────┤
│  Fiat Bridge  │ Bridge (Stripe) → Bank Account   │
│               │ Circle (USDC native issuance)    │
└─────────────────────────────────────────────────┘
```

### 5.2 主网合作伙伴

| 类别 | 合作方 | 角色 |
|------|--------|------|
| **AI 模型** | OpenAI, Anthropic | 设计合作伙伴, Agent 消费方 |
| **支付网络** | Visa, Mastercard | MPP 卡支付扩展, mpp-card SDK |
| **银行** | Standard Chartered, Deutsche Bank, UBS | 验证者候选, 合规伙伴 |
| **新银行** | Nubank, Revolut, Ramp | 消费端集成 |
| **电商** | Shopify, DoorDash | Agent 购物场景 |
| **合规** | Elliptic | AML/KYC 链上分析 |
| **预言机** | RedStone | 价格数据 |
| **开发工具** | Alchemy, Dune Analytics | RPC, 数据分析 |
| **BNPL** | Affirm, Klarna | SPT 扩展支付方式 |
| **Infrastructure** | Cloudflare, Chainstack | MPP 代理, RPC 节点 |

### 5.3 SKILL.md Agent 发现机制

Tempo 生态使用 **SKILL.md** 文件格式让 AI Agent 自动发现和集成付费服务：

```markdown
---
name: parallel-mpp
description: Use Parallel search/extract APIs via MPP
---

## Instructions
Use Parallel search/extract APIs instead of built-in web search.
Ensure mppx >= 0.4.1 is available.

## Endpoints
- Search ($0.01): POST /api/search
- Extract ($0.01/URL): POST /api/extract
```

Agent 读取 SKILL.md → 加载到 `.claude/skills/` → 自动发现并调用付费 API。

### 5.4 MPP Payments Directory

主网发布时 [mpp.dev/services](https://mpp.dev/services) 已有 **100+ 集成服务**：

| 类别 | 代表服务 |
|------|---------|
| 模型提供商 | Anthropic, OpenAI |
| 开发者基础设施 | Alchemy, Dune Analytics |
| 计算平台 | Merit Systems, Parallel Web Systems |
| 电商 | Shopify |
| 浏览器 | Browserbase (headless browser) |
| 邮件 | PostalForm (编程式实体邮件) |
| 数据 | 多家数据 API 提供商 |

---

## 6. 开发者体验与集成

### 6.1 Agent 端：mppx.fetch()

**核心理念**：`mppx.fetch()` 是 `fetch` 的 drop-in replacement，自动处理 402 challenge-response。

```typescript
// Agent 侧 — 开发者只写一行
const response = await mppx.fetch('https://api.example.com/data')
// mppx 自动处理:
// 1. 收到 402 → 解析支付要求
// 2. 与钱包交互签署交易
// 3. 重试请求带 Authorization: Payment
// 开发者只收到 200 或非支付错误
```

Session（流式支付）：

```typescript
import { tempo } from 'mppx/client'

const session = tempo.session({ maxDeposit: '10.00' })
session.sse('https://api.example.com/stream')  // SSE 流自动签发 voucher
```

CLI 工具：

```bash
npx mppx account create              # 创建钱包
npx mppx account view --show-key     # 查看详情
npx mppx https://api.example.com/endpoint --method POST -J '{"query":"topic"}'
```

### 6.2 服务端：Stripe PaymentIntents API

```typescript
// 方式一: Stripe API (需要 API 版本 2026-03-04.preview)
const paymentIntent = await stripe.paymentIntents.create({
  amount: 100,  // cents
  currency: 'usd',
  payment_method_types: ['crypto'],
  payment_method_options: {
    crypto: { mode: 'deposit', deposit_options: { networks: ['tempo'] } }
  }
})

// 方式二: mppx Server SDK
import { Mppx, tempo } from 'mppx/server'
const mppx = Mppx.create({
  methods: [tempo.charge({
    currency: PATH_USD,
    recipient: recipientAddress
  })]
})
```

### 6.3 SDK 矩阵

| 语言 | 包名 | 仓库 | 框架支持 |
|------|------|------|----------|
| TypeScript | `mppx` | [tempoxyz/mpp](https://github.com/tempoxyz/mpp) | Express, Next.js, Hono, Elysia, Cloudflare Workers |
| Python | `pympp` | [tempoxyz/pympp](https://github.com/tempoxyz/pympp) | — |
| Rust | `mpp-rs` | [tempoxyz/mpp-rs](https://github.com/tempoxyz/mpp-rs) | tower, axum, reqwest-middleware |
| Go | — | [tempoxyz/tempo-go](https://github.com/tempoxyz/tempo-go) | — |
| Visa Card | `mpp-card` | Visa 官方 | JWE 动态数据 |

### 6.4 开发工具

| 工具 | 描述 | 仓库 |
|------|------|------|
| tempo-foundry | Foundry fork with Tempo support | [tempoxyz/tempo-foundry](https://github.com/tempoxyz/tempo-foundry) |
| tempo-std | Solidity 库 for Tempo | [tempoxyz/tempo-std](https://github.com/tempoxyz/tempo-std) |
| tempo-apps | 应用 monorepo | [tempoxyz/tempo-apps](https://github.com/tempoxyz/tempo-apps) |
| mpp-proxy | Cloudflare MPP 代理 | [cloudflare/mpp-proxy](https://github.com/cloudflare/mpp-proxy) |

---

## 7. MPP vs x402 竞争格局

### 7.1 详细对比

| 维度 | MPP (Stripe/Tempo) | x402 (Coinbase) |
|------|---------------------|------------------|
| **发起方** | Tempo Labs + Stripe | Coinbase + x402 Foundation |
| **HTTP 机制** | Payment Auth Scheme (IETF draft) | PAYMENT-REQUIRED + PAYMENT-SIGNATURE |
| **支付模型** | charge + **session** (流式) | 仅 per-request |
| **结算速度** | ~0.5s (Tempo) | 链依赖 (~200ms - 数秒) |
| **支付方式** | 稳定币 + 法币卡 + Lightning | 纯链上稳定币 |
| **合规/欺诈** | 内置 (Stripe 基础设施) | 开发者自行处理 |
| **流式微支付** | Payment channel + EIP-712 vouchers | 无 |
| **注册要求** | 需要 Stripe 账户 | 无需注册 |
| **x402 兼容** | **向后兼容 x402** | 原生 |
| **供应商锁定** | 较紧 Stripe 集成 | 完全供应商中立 |
| **采用量 (2026/3)** | 主网首日 100+ 服务 | ~131K 笔/天, $28K 交易量 |

### 7.2 核心差异

**x402** 是轻量级"原子支付嵌入 HTTP"方案——每请求一笔链上交易，无许可、供应商中立。

**MPP** 增加了 session 层，通过 payment channel + EIP-712 voucher 实现**持续流式支付**，更适合 Agent 高频交互。但引入 Stripe 依赖。

**关键事实：Stripe 同时支持两个协议**——MPP 是 Stripe 的首选，但 x402 的 charge intent 可直接映射到 MPP。两者互补多于竞争。

### 7.3 对 Paymaster 概念的挑战

Tempo 的"无代币"模型是对传统 Paymaster 的根本性挑战：

- Tempo 在**协议层**解决了"用稳定币支付 Gas"——无需 Paymaster 中介
- Fee Sponsorship 是协议原生功能——无需 ERC-4337 EntryPoint
- 稳定币直接支付 Gas 费——无需 Token 兑换

但这仅适用于 Tempo 链。在以太坊/L2 生态中，Paymaster 仍然是必需的基础设施。

---

## 8. SuperPaymaster 借鉴分析

### 8.1 战略启示

#### 8.1.1 "Gas 是楔子"战略的验证

Tempo 的架构证实了 V5 Roadmap 的核心判断：**Gas 代付本身不是护城河，支付层才是**。

- Tempo 直接在协议层消灭了 Gas 问题（用稳定币付 Gas）
- 但 Tempo 真正的价值在 MPP (支付协议) + SPT (支付原语) + ACP (商务协议)
- **SuperPaymaster 的路径完全正确**：从 Gas 代付出发，向 `chargeMicroPayment` + x402 Facilitator 演进

#### 8.1.2 双层协议栈

Tempo 展示了清晰的两层分离：
- **底层**: Gas/结算（Tempo 链 或 Paymaster）
- **上层**: 支付协议（MPP 或 x402）

SuperPaymaster V5 的架构应明确对齐这个分层：
- **V5.1 `_consumeCredit()`** = 底层计费内核（对标 Tempo 的 Fee Sponsorship）
- **V5.2 x402 Facilitator** = 上层支付协议集成（对标 MPP 的 charge intent）
- **V5.3 ERC-8004 identity** = 发现层（对标 ACP + SKILL.md）

#### 8.1.3 Session 模式的重要性

MPP 的 **Session Intent** 是最值得借鉴的创新：

- 当前 x402 和 SuperPaymaster 都是"每请求一笔交易"模式
- Session 模式将数千次微交易聚合为一次链上结算
- **对 SuperPaymaster 的启示**：V5.2 的 `chargeMicroPayment()` 可以增加 session 变体

#### 8.1.4 市场定位差异化

| 维度 | Tempo/MPP | SuperPaymaster |
|------|-----------|----------------|
| 目标用户 | 企业（有 Stripe 账户） | 社区/DAO/独立开发者 |
| 许可模式 | 需 Stripe KYC | 无许可，任何人可部署 |
| 代币模型 | 无原生代币（纯稳定币） | xPNTs 社区代币驱动经济循环 |
| Gas 方案 | 协议原生（仅 Tempo 链） | ERC-4337 Paymaster（任何 EVM 链） |
| 支付方式 | 多轨（稳定币+法币+Lightning） | xPNTs + x402 (USDC) |
| 部署模式 | Stripe 托管 | 自部署（开源框架） |

**一句话差异**：Tempo/MPP 是"Stripe 的支付区块链"，SuperPaymaster 是"社区自己的支付基础设施"。

### 8.2 产品特性借鉴

#### 8.2.1 Payment Channel / Session Keys

**MPP Session Intent 的技术要素：**

```
1. Escrow 合约: deposit(amount) → lock funds
2. EIP-712 Voucher: {nonce, cumulativeAmount, signature}
3. 服务端验证: ecrecover (μs 级, 无 RPC)
4. 结算: close(lastVoucher) → 链上清算
```

**SuperPaymaster 可借鉴的实现：**

```solidity
// V5.2+ 可选: Session-based chargeMicroPayment
struct MicroPaymentSession {
    address operator;
    address user;
    uint256 maxDeposit;       // 预授权上限
    uint256 cumulativeCharged; // 累计消费
    uint256 expiresAt;
    bool isActive;
}

// 开通 Session (一次链上交易)
function openSession(
    address operator,
    uint256 maxDeposit,
    uint256 duration
) external returns (bytes32 sessionId);

// 消费 (链下签名验证, 无 gas)
function claimSession(
    bytes32 sessionId,
    uint256 cumulativeAmount,
    bytes calldata userSignature  // EIP-712
) external;

// 关闭结算 (一次链上交易)
function closeSession(bytes32 sessionId) external;
```

**优势**：数千次微支付只需 2 次链上交易（open + close），中间全部链下验证。

#### 8.2.2 转账备注 (Transfer Memos)

TIP-20 的 32 字节转账备注非常实用：

```solidity
// xPNTsToken 可借鉴: 增加 transferWithMemo
function transferWithMemo(address to, uint256 amount, bytes32 memo) external returns (bool);
// memo 用途: 发票 ID, 服务引用, 对账标识
```

#### 8.2.3 服务发现

MPP 的 Payments Directory + SKILL.md 机制值得学习：

- SuperPaymaster 可以维护一个 **Operator Directory**
- 每个 Operator 发布自己的服务描述（类似 SKILL.md）
- Agent 可自动发现哪个社区可以赞助 Gas、提供什么服务

#### 8.2.4 多支付轨道 (Multi-Rail)

MPP 支持多种支付方法（Tempo 稳定币 + Stripe SPT + Lightning）。SuperPaymaster 可以：

- V5.1: aPNTs 内部计费（当前）
- V5.2: x402 USDC 外部结算（计划中）
- Future: Lightning / Stripe SPT 扩展轨道

### 8.3 技术栈借鉴

#### 8.3.1 直接可用的开源代码

| 仓库 | 借鉴点 | 适用于 |
|------|--------|--------|
| [tempoxyz/mpp-specs](https://github.com/tempoxyz/mpp-specs) | HTTP 402 challenge-response 规范 | V5.2 x402 Facilitator 实现 |
| [tempoxyz/tempo-std](https://github.com/tempoxyz/tempo-std) | Solidity 支付库 | Session 合约参考 |
| [tempoxyz/mpp](https://github.com/tempoxyz/mpp) | TypeScript server SDK | SDK 层 x402 server 实现参考 |
| [cloudflare/mpp-proxy](https://github.com/cloudflare/mpp-proxy) | Cloudflare Worker MPP 代理 | x402 proxy 中间件参考 |
| [tempoxyz/tempo-foundry](https://github.com/tempoxyz/tempo-foundry) | Foundry fork | 如果部署到 Tempo |

#### 8.3.2 EIP-712 Voucher 实现参考

MPP Session 的 EIP-712 voucher 签名机制与 SuperPaymaster V5.2 的 `chargeMicroPayment()` 完全对齐：

```solidity
// MPP Session Voucher 结构 (参考 tempo-std)
bytes32 constant VOUCHER_TYPEHASH = keccak256(
    "Voucher(bytes32 sessionId,uint256 cumulativeAmount,uint256 nonce)"
);

// SuperPaymaster V5.2 已设计的 MicroPayment 结构
bytes32 constant MICROPAYMENT_TYPEHASH = keccak256(
    "MicroPayment(address operator,address user,uint256 amount,uint256 nonce,uint256 deadline)"
);
```

两者使用相同的 EIP-712 + ecrecover 验证模式，可以共享签名验证逻辑。

#### 8.3.3 Fee AMM 概念

Tempo 的 Fee AMM（Gas 费自动转换为验证者偏好稳定币）启发：

- SuperPaymaster 已有 `exchangeRate` 机制（xPNTs ↔ aPNTs 汇率）
- 可以扩展为更动态的 AMM 式定价：基于供需自动调整 `exchangeRate`

### 8.4 生态借鉴

#### 8.4.1 Operator Directory → Community Registry

MPP 的 [mpp.dev/services](https://mpp.dev/services) 是中心化目录。SuperPaymaster 可以做去中心化版本：

```
Registry.sol 已有:
  - communityByName(name) → address
  - getRoleMembers(ROLE_PAYMASTER_SUPER) → address[]

扩展方向:
  - 每个 Operator 发布 JSON metadata (IPFS)
  - 包含: 服务描述、费率、支持的 token、API endpoint
  - Agent 可查询 Registry 发现最优 Operator
```

#### 8.4.2 多链扩展策略

Tempo 是独立 L1，但也通过 Bridge 连接多链。SuperPaymaster 可以：

- 保持以太坊/L2 为主战场（Tempo 不覆盖的领域）
- 考虑部署到 Tempo 链作为补充（Tempo 的 Fee Sponsorship 是原生的，但社区代币经济循环仍然需要 SuperPaymaster）

### 8.5 行动建议优先级

| 优先级 | 行动 | 对标 Tempo/MPP | 时间线 |
|--------|------|---------------|--------|
| P0 | 完成 V5.1 `_consumeCredit()` 提取 | Fee Sponsorship 内核 | V5.1 |
| P0 | 完成 V5.2 `chargeMicroPayment()` EIP-712 | MPP charge intent | V5.2 |
| P1 | 添加 Session-based 微支付 (Payment Channel) | MPP session intent | V5.2.1 |
| P1 | x402 Facilitator Server SDK | mppx server SDK | V5.2 SDK |
| P2 | Operator Discovery API | MPP Payments Directory | V5.3+ |
| P2 | xPNTs transferWithMemo | TIP-20 memos | V5.x |
| P3 | 动态 exchangeRate (AMM 式) | Fee AMM | Future |
| P3 | Tempo 链部署 | 多链扩展 | Future |

### 8.6 深度代码级借鉴（战术层）

> 以下内容来自对 mpp-specs、tempo-std、mppx 三个仓库的深度代码审计。

#### 8.6.1 MPP 协议规范细节（mpp-specs）

**HMAC-SHA256 无状态 Challenge ID**

MPP 的 challenge ID 不存储在数据库中，而是通过 HMAC 计算绑定所有支付参数：

```
challengeId = HMAC-SHA256(
  server_secret,
  "intent|method|amount|currency|resource|recipient|expiry"
)
```

7 个位置参数通过管道符连接。验证时服务器用相同 secret 重新计算 HMAC 对比，无需任何持久化存储。

**SuperPaymaster Operator Node 借鉴**：V5.2 的 Operator Node 可采用同样模式——收到 x402 请求时生成 HMAC challenge，验证时重新计算对比。省去 Redis/DB 依赖，无状态水平扩展。

**Charge Intent 完整 JSON Schema**

```json
{
  "version": 1,
  "intent": "charge",
  "method": "tempo",
  "amount": "1000000",
  "asset": "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
  "recipient": "0x742d35Cc6634...",
  "expiry": 1711234567,
  "challengeId": "hmac-derived-id",
  "metadata": { "resource": "/api/data", "requestId": "..." }
}
```

**Session Intent 完整协议流**

```
1. Client → POST /session/open
   Body: { maxDeposit: "10000000", token: "USDC", duration: 3600 }
   ← 201: { sessionId, escrowAddress, depositTx }

2. Client → on-chain deposit (ERC-20 approve + escrow.deposit)

3. Client → GET /api/resource
   Header: Authorization: Payment session=<sessionId>,
           voucher=<EIP-712-signed-cumulative-amount>
   ← 200: { data, receipt: { cumulativeSettled, remaining } }

4. [Repeat step 3 with increasing cumulative amounts]

5. Server → on-chain escrow.settle(lastVoucher)
   ← Remaining funds auto-refunded to client
```

**SSE 流式事件格式（Session）**

```
event: payment-status
data: {"status":"active","settled":"0.50","remaining":"9.50"}

event: payment-required
data: {"reason":"deposit-low","topUpAmount":"5.00"}

event: session-closing
data: {"reason":"timeout","finalSettlement":"3.50"}
```

#### 8.6.2 tempo-std Solidity 合约接口（完整）

**ITempoStreamChannel — 支付通道核心接口**

```solidity
interface ITempoStreamChannel {
    struct Channel {
        address sender;
        address recipient;
        address token;
        address authorizedSigner;  // Session key delegation
        uint128 balance;
        uint128 settled;
        uint64 closeRequestedAt;
        bool finalized;
    }

    function open(
        address recipient,
        address token,
        uint128 amount,
        address authorizedSigner
    ) external returns (bytes32 channelId);

    function settle(
        bytes32 channelId,
        uint128 cumulativeAmount,  // NOT delta — cumulative total
        bytes calldata signature
    ) external;

    function topUp(bytes32 channelId, uint128 amount) external;
    function close(bytes32 channelId) external;
    function requestClose(bytes32 channelId) external;
    function withdraw(address token, uint128 amount) external;

    // Events
    event ChannelOpened(bytes32 indexed channelId, address sender, address recipient, uint128 amount);
    event ChannelSettled(bytes32 indexed channelId, uint128 cumulativeAmount);
    event ChannelClosed(bytes32 indexed channelId, uint128 finalAmount);
    event CloseRequested(bytes32 indexed channelId, uint64 requestedAt);

    // Errors
    error ChannelNotFound();
    error ChannelFinalized();
    error InsufficientBalance();
    error UnauthorizedSigner();
    error CloseNotRequested();
    error DisputePeriodNotElapsed();
}
```

**关键实现模式**：
- `cumulativeAmount` 是累积总值，不是增量——天然防重放
- `authorizedSigner` 允许 Session Key 签名，冷钱包无需在线
- `requestClose()` 启动争议窗口，`close()` 在窗口结束后执行
- 所有 channel 数据通过 `channelId = keccak256(sender, recipient, token, nonce)` 索引

**IAccountKeychain — Session Key 管理**

```solidity
interface IAccountKeychain {
    struct SessionKey {
        address key;
        uint256 spendLimit;    // Per-session spending cap
        uint256 spent;
        uint64 validUntil;
        bool revoked;
    }

    function addSessionKey(address key, uint256 spendLimit, uint64 validUntil) external;
    function revokeSessionKey(address key) external;
    function isValidSessionKey(address account, address key) external view returns (bool);
}
```

**IFeeManager — Fee Sponsorship 机制**

```solidity
interface IFeeManager {
    // Sponsor registers and deposits funds
    function registerSponsor(address sponsor) external;
    function depositSponsorFunds(address sponsor, uint128 amount) external;

    // Check if tx fee should be sponsored
    function shouldSponsor(address tx_sender, address sponsor) external view returns (bool);

    // Execute sponsored fee payment
    function payFee(address tx_sender, address sponsor, uint128 feeAmount) external;
}
```

**对 SuperPaymaster 的映射**：FeeManager 的 `registerSponsor` + `depositSponsorFunds` + `shouldSponsor` + `payFee` 四步流程，完全对应我们的 `configureOperator` + `deposit` + `validatePaymasterUserOp` + `_consumeCredit`。

**IFeeAMM — 固定费率 Gas 费转换**

```solidity
interface IFeeAMM {
    // Fixed-rate swap: M=9970, SCALE=10000 → 0.3% fee
    function swap(address tokenIn, address tokenOut, uint128 amountIn)
        external returns (uint128 amountOut);
    function quote(address tokenIn, address tokenOut, uint128 amountIn)
        external view returns (uint128 amountOut);
}
```

#### 8.6.3 mppx TypeScript SDK 架构（完整）

**核心类型系统**

```typescript
// Challenge — server 发出的支付挑战
interface Challenge {
  version: 1;
  intent: 'charge' | 'session' | 'auth';
  method: string;          // "tempo", "stripe-spt", "lightning"
  amount: string;          // Wei/smallest unit
  asset: string;           // Token contract address
  recipient: string;       // Payee address
  expiry: number;          // Unix timestamp
  challengeId: string;     // HMAC-derived
  metadata?: Record<string, string>;
}

// Credential — client 支付后的凭证
interface Credential {
  challengeId: string;
  txHash?: string;         // Push mode: client broadcasts
  signedPayload?: string;  // Pull mode: server broadcasts
  method: string;
}

// Receipt — server 确认后的收据
interface Receipt {
  challengeId: string;
  status: 'settled' | 'pending' | 'failed';
  txHash: string;
  settledAmount: string;
  settledAt: number;
}
```

**Server Middleware 架构**

```typescript
// 创建 MPP 实例 — Method 插件模式
const mpp = Mpp.create({
  methods: [
    tempo.charge({ recipient, currency: PATH_USD }),
    tempo.session({ recipient, escrowAddress }),
    stripe.spt({ publishableKey }),
  ],
  store: new KVStore(),  // Challenge 存储 (optional with HMAC)
});

// Hono 中间件
app.get('/paid-api', mpp.pay({ amount: '0.50' }), handler);

// Express 中间件
app.get('/paid-api', mpp.express({ amount: '0.50' }), handler);

// Next.js Route Handler
export const GET = mpp.nextjs({ amount: '0.50' }, handler);
```

**Client Fetch Wrapper**

```typescript
// Drop-in fetch replacement with auto 402 handling
const response = await mppx.fetch('https://api.example.com/data', {
  method: 'POST',
  body: JSON.stringify({ query: 'hello' }),
  // mppx automatically:
  // 1. Detects 402 response
  // 2. Parses WWW-Authenticate: Payment challenge
  // 3. Signs/broadcasts payment
  // 4. Retries with Authorization: Payment credential
});
```

**Multi-Method Compose**

```typescript
// Compose multiple payment methods — client picks the best
const mpp = Mpp.create({
  methods: compose([
    tempo.charge({ ... }),     // Crypto (fast, cheap)
    stripe.spt({ ... }),       // Card (familiar, fiat)
    lightning.bolt11({ ... }), // Bitcoin (privacy)
  ]),
});
// Challenge includes all available methods; client chooses
```

**Store Interface**

```typescript
// Pluggable storage for challenge state (when not using HMAC)
interface Store {
  get(key: string): Promise<string | null>;
  set(key: string, value: string, ttl?: number): Promise<void>;
  delete(key: string): Promise<void>;
}
// Implementations: MemoryStore, KVStore (Cloudflare), RedisStore
```

**mpp-proxy (Cloudflare) 架构**

```
Client Request → Cloudflare Worker (mpp-proxy)
                    │
                    ├── Check Authorization header
                    │   ├── Has valid credential → Forward to origin + JWT
                    │   └── No credential → Return 402 + challenge
                    │
                    └── Origin Server receives:
                        ├── Original request headers
                        └── X-Payment-Verified: true (JWT signed)
```

**SuperPaymaster SDK 可借鉴的架构**：

```typescript
// packages/x402-facilitator-sdk/
import { SuperPaymaster } from '@superpaymaster/sdk';

const sp = SuperPaymaster.create({
  methods: [
    sp.gasSponsorship({ operator, network: 'sepolia' }),
    sp.x402Charge({ facilitator, asset: 'USDC' }),
    sp.x402Session({ facilitator, maxDeposit: '10.00' }),
  ],
  wallet: viemWalletClient,
});

// Agent-side: auto-handle gas + payment
const result = await sp.fetch('https://api.community.xyz/service');
```

#### 8.6.4 可控依赖评估

| 组件 | 许可证 | 运行时依赖? | 可控性 |
|------|--------|------------|--------|
| mpp-specs (协议规范) | CC0-1.0 | 否 (纯规范) | 完全可控 — 自行实现 |
| tempo-std (Solidity) | Apache 2.0 | 否 (参考代码) | 完全可控 — 提取接口模式 |
| mppx (TS SDK) | Apache 2.0 | 可选 | 可控 — fork 或参考架构自建 |
| mpp-proxy (CF Worker) | Apache 2.0 | 否 (参考代码) | 完全可控 — 自建 Worker |
| pympp (Python) | Apache 2.0 | 否 | 完全可控 — 验证 HMAC 算法 |
| EIP-712 (标准) | CC0 | 否 (标准) | 完全可控 — 已在使用 |
| solady EIP712 (库) | MIT | 可选 | 可控 — 已是项目依赖 |

**结论**：所有借鉴来源均为开放许可 (Apache 2.0 / CC0 / MIT)，无任何运行时硬依赖。SuperPaymaster 可自由提取设计模式和代码参考，不产生供应商锁定。

---

## 9. 参考资源

### 9.1 官方资源

| 资源 | URL |
|------|-----|
| Tempo 官网 | https://tempo.xyz |
| Tempo 主网博客 | https://tempo.xyz/blog/mainnet/ |
| Tempo 文档 | https://docs.tempo.xyz |
| MPP 官网 | https://mpp.dev |
| MPP 服务目录 | https://mpp.dev/services |
| MPP 规格仓库 | https://github.com/tempoxyz/mpp-specs |
| Stripe MPP 文档 | https://docs.stripe.com/payments/machine/mpp |
| Stripe MPP 博客 | https://stripe.com/blog/machine-payments-protocol |
| Stripe SPT 文档 | https://docs.stripe.com/agentic-commerce/concepts/shared-payment-tokens |
| Stripe ACP 文档 | https://docs.stripe.com/agentic-commerce/protocol |
| ACP GitHub | https://github.com/agentic-commerce-protocol |
| Cloudflare MPP 文档 | https://developers.cloudflare.com/agents/agentic-payments/mpp/ |
| Visa mpp-card 公告 | https://corporate.visa.com/en/sites/visa-perspectives/innovation/visa-card-specification-sdk-for-machine-payments-protocol.html |

### 9.2 GitHub 仓库

| 仓库 | Stars | 语言 | 描述 |
|------|-------|------|------|
| [tempoxyz/tempo](https://github.com/tempoxyz/tempo) | 889 | Rust | Tempo 区块链主仓库 |
| [tempoxyz/mpp-specs](https://github.com/tempoxyz/mpp-specs) | 38 | Python/HTML | MPP 规范 |
| [tempoxyz/mpp](https://github.com/tempoxyz/mpp) | 27 | TypeScript | MPP TypeScript 实现 |
| [tempoxyz/mpp-rs](https://github.com/tempoxyz/mpp-rs) | 49 | Rust | MPP Rust SDK |
| [tempoxyz/pympp](https://github.com/tempoxyz/pympp) | 17 | Python | MPP Python SDK |
| [tempoxyz/tempo-foundry](https://github.com/tempoxyz/tempo-foundry) | 72 | Rust | Foundry Tempo fork |
| [tempoxyz/tempo-std](https://github.com/tempoxyz/tempo-std) | 63 | Solidity | Tempo Solidity 库 |
| [tempoxyz/tempo-ts](https://github.com/tempoxyz/tempo-ts) | 72 | TypeScript | Tempo TS 工具 |
| [tempoxyz/tempo-apps](https://github.com/tempoxyz/tempo-apps) | 181 | TypeScript | 应用 monorepo |
| [tempoxyz/tempo-go](https://github.com/tempoxyz/tempo-go) | 62 | Go | Go SDK |
| [tempoxyz/wallet](https://github.com/tempoxyz/wallet) | 32 | Rust | 钱包实现 |
| [tempoxyz/docs](https://github.com/tempoxyz/docs) | 11 | MDX | 文档 |
| [cloudflare/mpp-proxy](https://github.com/cloudflare/mpp-proxy) | 48 | TypeScript | Cloudflare MPP 代理 |
| [agentic-commerce-protocol](https://github.com/agentic-commerce-protocol/agentic-commerce-protocol) | 1,281 | JavaScript | ACP 规范 |

### 9.3 分析与报道

- [Fortune: Stripe-backed Tempo launches](https://fortune.com/2026/03/18/stripe-tempo-paradigm-mpp-ai-payments-protocol/)
- [Insights4VC: Tempo 深度分析](https://insights4vc.substack.com/p/tempo-stripes-blockchain-for-stablecoin)
- [DeFi Prime: MPP vs x402](https://defiprime.com/stripe-mpp-vs-x402)
- [The Block: Commonware $25M 投资](https://www.theblock.co/post/378059/stripe-backed-tempo-venture-bet-25-million-investment-open-source-commonware)
- [CoinDesk: Tempo 主网上线](https://www.coindesk.com/tech/2026/03/18/stripe-led-payments-blockchain-tempo-goes-live-with-protocol-for-ai-agents)
- [Lex Sokolin: Tempo as Apple of Payment Blockchains](https://lex.substack.com/p/analysis-stripes-tempo-is-building)
- [Tempo FAQ (非官方)](https://www.seangoedecke.com/tempo-faq/)
- [Simplex BFT 论文](https://simplex.blog/)

### 9.4 网络连接

| 网络 | RPC (HTTPS) | Chain ID |
|------|-------------|----------|
| 主网 | `https://rpc.tempo.xyz` | 4217 |
| 测试网 Moderato | `https://rpc.moderato.tempo.xyz` | 42431 |
