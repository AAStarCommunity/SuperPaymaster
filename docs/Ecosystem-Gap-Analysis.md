# 生态系统差距分析 — x402 vs MPP vs SuperPaymaster

> 2026-03-24 | 基于完整生态调研

---

## 1. Coinbase/x402 完整生态组件 (截至 2026-03)

### 协议层
| 组件 | 说明 |
|------|------|
| x402 V1 Spec (2025-05) | HTTP 402 + EIP-3009 (USDC/EURC) |
| x402 V2 Spec (2025-12) | Session 支持、多链 CAIP-2、动态 payTo、多 Facilitator |
| ERC-20 扩展 (2026-03) | Permit2 支持任意 ERC-20; Gas Sponsorship Extensions |
| SIWx (Sign-In-With-X) | CAIP-122 钱包认证，Session 复用 |
| Bazaar Discovery | 服务自动发现 metadata 规范 |

### SDK (多语言)
| 包 | 说明 |
|----|------|
| @x402/core | 核心协议 (transport-agnostic) |
| @x402/evm | EVM 链 EIP-3009 + Permit2 |
| @x402/svm | Solana SPL Token |
| @x402/fetch | fetch 包装器 |
| @x402/axios | Axios 拦截器 |
| @x402/express | Express 中间件 |
| @x402/hono | Hono 中间件 |
| @x402/next | Next.js 路由保护 |
| @x402/paywall | 前端 paywall UI 组件 |
| @x402/extensions | 扩展插件 (Permit2, Bazaar, SIWx) |
| Python SDK | 33.6% 代码占比 |
| Go SDK | 22.0% 代码占比 |
| Java SDK | 初步 |

### Facilitator 基础设施
| 类型 | 说明 |
|------|------|
| CDP Hosted | Coinbase 托管, 1000 笔/月免费, Base 零手续费 |
| Self-hosted | @x402/core 自建 |
| Cloudflare Worker | 边缘 facilitator, 330+ 全球节点 |
| Stellar Facilitator | 免费公共, ~5 秒 finality |
| Multi-Facilitator (V2) | 多 facilitator 并行 |

### Agent 集成
| 组件 | 说明 |
|------|------|
| AgentKit | 区块链交互工具包 (LangChain / MCP) |
| Payments MCP | 一键获得钱包 + onramp + x402 支付 |
| Base MCP Server | Claude/Cursor 链上工具 |
| World AgentKit | World ID 委托给 AI Agent |
| Cloudflare paidTool | MCP 工具按调用收费 |

### 身份
| 组件 | 说明 |
|------|------|
| Coinbase Smart Wallet | ERC-4337 |
| CDP Wallets | 服务端托管 (安全飞地) |
| World ID | 人类身份证明 |
| Privy 嵌入式钱包 | 第三方集成 |
| Circle Programmable Wallets | Circle 集成 |

### 法币
| 组件 | 说明 |
|------|------|
| Coinbase Onramp | 法币 → USDC |
| Coinbase Offramp | USDC → 法币 |
| Payments MCP Onramp | 桌面端 guest checkout |

### 开发者工具
| 工具 | 说明 |
|------|------|
| CDP Console | 项目/API Key/用量管理 |
| API Playground | 交互式调试 |
| AI-Native Docs | AI 助手文档系统 |
| awesome-x402 | 社区资源列表 |

### 合作伙伴 (x402 Foundation, 2025-09)
Coinbase, Cloudflare, Google, Visa, AWS, Circle, Anthropic, Vercel, Stripe, World, Alchemy, Messari, Nansen, Privy, QuickNode, Solana Foundation, Stellar

---

## 2. Stripe/Tempo MPP 完整生态组件

### 协议层
| 组件 | 说明 |
|------|------|
| MPP Spec | Machine Payments Protocol 规范 |
| Charge Intent | 单笔支付意图 |
| Session Intent | 流式支付 (Payment Channel) |
| SKILL.md | Agent 能力声明格式 |

### SDK (多语言)
| 包 | 说明 |
|----|------|
| mppx (TypeScript) | 主 SDK |
| mppx (Rust) | Rust 实现 |
| mppx (Python) | Python 实现 |
| mppx (Go) | Go 实现 |

### 基础设施
| 组件 | 说明 |
|------|------|
| Tempo Chain | Stripe 控制的 L2 |
| Stripe SPT | 稳定支付代币 |
| Stripe 托管结算 | 中心化结算 |
| mpp.dev | Agent 服务目录 |

### 法币
| 组件 | 说明 |
|------|------|
| Stripe 法币入口 | 完整法币支付网络 |
| Visa 集成 | 信用卡/借记卡 |
| SEPA/ACH | 银行转账 |

---

## 3. SuperPaymaster V5.3 当前生态组件

### 协议层
| 组件 | 状态 |
|------|------|
| ERC-4337 Paymaster (多 Operator) | ✅ |
| x402 V2 兼容结算 | ✅ |
| MicroPaymentChannel | ✅ |
| ERC-8004 Agent 身份 | ✅ |
| Agent 信誉系统 | ✅ |
| 社区代币 (xPNTs) | ✅ |

### SDK
| 包 | 状态 |
|----|------|
| @aastar/core | ✅ TypeScript |
| @aastar/x402 | ✅ TypeScript |
| @aastar/channel | ✅ TypeScript |
| @aastar/cli | ✅ TypeScript |
| Python SDK | ❌ 无 |
| Go SDK | ❌ 无 |

### 后端服务
| 组件 | 状态 |
|------|------|
| x402 Facilitator Node | ✅ 代码就绪，未部署 |
| Operator Node | ❌ 未开发 |
| Price Keeper | ❌ 无独立服务 |

### 开发者工具
| 工具 | 状态 |
|------|------|
| Operator Dashboard | ❌ 无 |
| Demo 页面 | ❌ 无 |
| API Playground | ❌ 无 |
| 框架中间件 (Express/Hono/Next) | ❌ 仅 Hono (facilitator) |

### Agent 集成
| 组件 | 状态 |
|------|------|
| MCP Server | ❌ 未开发 |
| LangChain Tool | ❌ 未开发 |
| Agent Demo Bot | ❌ 未开发 |

### 身份
| 组件 | 状态 |
|------|------|
| ERC-8004 Agent NFT | ✅ |
| MySBT | ✅ |
| 嵌入式钱包集成 | ❌ 无 |

### 法币
| 组件 | 状态 |
|------|------|
| 法币入金 | ❌ 无 |

### 服务发现
| 组件 | 状态 |
|------|------|
| SKILL.md | ✅ 模板就绪 |
| Bazaar 式自动发现 | ❌ 无 |
| .well-known 元数据 | ✅ |

---

## 4. 差距优先级 TODO List

### P0 — 必须做（缺失 = 无法 Demo）

| # | 差距 | 对标 | 工作量 | 说明 |
|---|------|------|--------|------|
| 1 | Facilitator Node 公网部署 | x402 CDP Hosted | 1 天 | Railway/Render 一键部署 |
| 2 | Operator Node | Tempo 基础设施 | 1 周 | 价格缓存 + 社区管理 + 赞助配置 |
| 3 | SDK E2E 测试 (Sepolia) | x402 examples | 3 天 | 12 个场景端到端验证 |
| 4 | Agent Demo Bot | AgentKit demo | 3 天 | CLI Agent 演示全流程 |
| 5 | 前端 Demo 页面 | @x402/paywall | 1 周 | Next.js + 钱包连接 + 支付流程 |

### P1 — 建议做（缺失 = 竞争力不足）

| # | 差距 | 对标 | 工作量 | 说明 |
|---|------|------|--------|------|
| 6 | 框架中间件矩阵 | @x402/express, /hono, /next | 1 周 | @aastar/express, @aastar/hono, @aastar/next |
| 7 | MCP Server | Payments MCP, Base MCP | 3 天 | Claude/Cursor 集成 |
| 8 | Paywall UI 组件 | @x402/paywall | 1 周 | React 组件: 钱包连接 + 支付 + 通道管理 |
| 9 | Bazaar 式服务发现 | Bazaar Discovery | 3 天 | /discovery/resources API |
| 10 | Session 支持 | x402 V2 SIWx | 3 天 | 签名后 Session 复用 |
| 11 | 开发者文档站 | docs.x402.org | 1 周 | VitePress / Docusaurus |
| 12 | 示例应用模板 | x402/examples | 3 天 | starter template, video paywall 等 |

### P2 — 未来做（中长期竞争力）

| # | 差距 | 对标 | 工作量 | 说明 |
|---|------|------|--------|------|
| 13 | Python SDK | x402 Python (33%) | 2 周 | Agent 开发者最常用语言 |
| 14 | Go SDK | x402 Go (22%) | 2 周 | 后端服务开发 |
| 15 | 法币入金集成 | Coinbase Onramp | 2 周 | MoonPay / Transak / Ramp |
| 16 | 嵌入式钱包集成 | Privy / Circle | 1 周 | 降低用户门槛 |
| 17 | Cloudflare Worker 部署 | CF Workers x402 | 3 天 | 边缘部署模板 |
| 18 | LangChain / CrewAI 集成 | AgentKit LangChain | 3 天 | AI 框架插件 |
| 19 | 跨链 Agent 信誉同步 | 无对标 (SP 独有) | 2 周 | LayerZero / CCIP |
| 20 | npm 版本监控脚本 | — | 1 天 | 追踪 @x402/*, mppx 版本 |

---

## 5. 我们有而他们没有的独有能力

| 能力 | 说明 | 应用场景 |
|------|------|---------|
| 社区代币 gas 赞助 | xPNTs 任意社区可铸造 | DAO 成员免 gas |
| Agent 分级赞助 | 信誉驱动 BPS + 每日 USD 上限 | 高信誉 Agent 更便宜 |
| 链上信用/债务 | _consumeCredit 内核 | 先用后付 |
| Operator 多租户 | Registry 链上注册 | 一合约服务多社区 |
| MicroPaymentChannel | 离线 voucher + 15 分钟争议 | 流式 AI API 付费 |
| DVT + BLS 验证 | 分布式验证 + 聚合签名 | 去中心化安全 |
| 任何 EVM 链自部署 | deploy-core 一键部署 | 抗审查 |

这些独有能力是竞争差异化的基础，应在文档、Demo 和营销中重点突出。
