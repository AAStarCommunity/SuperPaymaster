# SuperPaymaster V5 Roadmap 生态评估报告

> Version: 1.1.0 | Date: 2026-03-22 | Status: V5 Pre-Implementation Assessment

---

## 目录

1. [评估结论](#1-评估结论)
2. [三项目生态能力矩阵](#2-三项目生态能力矩阵)
3. [V5.1-V5.3 竞争力评估](#3-v51-v53-竞争力评估)
4. [核心差距与弥补策略](#4-核心差距与弥补策略)
5. [SDK 诉求清单](#5-sdk-诉求清单)
6. [AirAccount 诉求清单](#6-airaccount-诉求清单)
7. [协同发展路线图](#7-协同发展路线图)
8. [风险与依赖分析](#8-风险与依赖分析)

---

## 1. 评估结论

### 能不能称为"社区化去中心化微支付基础设施"？

**可以，且具备独特竞争优势。**

完成 V5.1-V5.3 后，SuperPaymaster + SDK + AirAccount 三件套构成完整的社区化支付协议栈：

```
┌──────────────────────────────────────────────────────────┐
│              SuperPaymaster V5 生态全景                    │
├──────────────────────────────────────────────────────────┤
│                                                            │
│  ┌─────────────────┐   ┌────────────────┐                 │
│  │   AirAccount     │   │  ERC-8004      │                │
│  │   Smart Wallet   │   │  Agent Identity│                │
│  │                  │   │                │                 │
│  │  · 8 签名算法     │   │  · Agent NFT   │                │
│  │  · Session Key   │←→│  · Reputation  │  ← Layer 4     │
│  │  · AI Agent Key  │   │  · Validation  │    Identity    │
│  │  · Tier Guard    │   │                │                 │
│  │  · Social Recov  │   └────────────────┘                │
│  └────────┬─────────┘                                      │
│           │ paymasterAndData                                │
│  ┌────────▼──────────────────────────────────────────┐    │
│  │  SuperPaymaster V5 (链上合约)                       │    │
│  │                                                      │    │
│  │  V5.1: _consumeCredit() + chargeMicroPayment()     │    │
│  │  V5.2: settleX402Payment() + MicroPaymentChannel   │ ← Layer 2-3│
│  │  V5.3: isRegisteredAgent() + agentPolicies         │    Payment │
│  │                                                      │    │
│  │  Registry · GTokenStaking · xPNTs · MySBT           │    │
│  └────────┬──────────────────────────────────────────┘    │
│           │ ABI + Addresses                                 │
│  ┌────────▼──────────────────────────────────────────┐    │
│  │  @aastar/sdk (15 packages)                          │    │
│  │                                                      │    │
│  │  @aastar/paymaster  — PaymasterClient               │    │
│  │  @aastar/enduser    — UserLifecycle                 │ ← Layer 1 │
│  │  @aastar/operator   — OperatorLifecycle             │    SDK    │
│  │  @aastar/airaccount — AirAccount 集成               │    │
│  │  @aastar/core       — 27 ABI + Actions              │    │
│  │                                                      │    │
│  │  [待新增] @aastar/x402        — Facilitator SDK     │    │
│  │  [待新增] @aastar/channel     — Payment Channel     │    │
│  │  [待新增] @aastar/discovery   — SKILL.md + OpenAPI  │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                            │
│  ┌────────────────────────────────────────────────────┐    │
│  │  开发者工具                                          │    │
│  │  · CLI (@superpaymaster/cli)                        │    │
│  │  · Keeper (price update service)                    │ ← Tooling │
│  │  · SKILL.md (AI Agent discovery)                    │    │
│  │  · Operator Node (x402 Facilitator)                 │    │
│  └────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────┘
```

### 与 Tempo/Coinbase 的类比关系

| 角色 | Tempo 生态 | Coinbase 生态 | SuperPaymaster 生态 |
|------|-----------|--------------|-------------------|
| **链/结算层** | Tempo L1 (专有链) | Base L2 | 任何 EVM 链 (Ethereum/Optimism/Base) |
| **账户系统** | Tempo Wallet | Coinbase Smart Wallet | **AirAccount** (8 算法, TEE KMS) |
| **支付协议** | MPP (Charge + Session) | x402 (Charge only) | SuperPaymaster V5 (Charge + Session) |
| **身份层** | Stripe KYC | Coinbase Identity | **ERC-8004 + MySBT** (无许可) |
| **SDK** | mppx (TS/Rust/Python/Go) | CDP SDK | **@aastar/sdk** (TS, 15 packages) |
| **Agent 发现** | SKILL.md + mpp.dev | Coinbase AgentKit | SKILL.md + OpenAPI x-payment-info |
| **部署模式** | Stripe 托管 | Coinbase 托管 | **任何人自部署（开源）** |

**一句话定位**：Tempo 是 "Stripe 的支付区块链"，Coinbase 是 "中心化支付 API"，SuperPaymaster 是 **"社区自己的支付基础设施"**。

---

## 2. 三项目生态能力矩阵

### 当前能力（V4.1.0 阶段）

| 能力 | SuperPaymaster | SDK (@aastar) | AirAccount | 总评 |
|------|---------------|---------------|------------|------|
| **Gas 赞助** | ✅ validatePaymasterUserOp | ✅ PaymasterClient, middleware | ✅ paymasterAndData 集成 | **完整** |
| **社区管理** | ✅ Registry + Staking + Slash | ✅ OperatorLifecycle | — | **完整** |
| **身份验证** | ✅ MySBT + sbtHolders | ✅ SBT client | ✅ BLS/ECDSA/P256 | **完整** |
| **Token 经济** | ✅ xPNTs + aPNTs + exchangeRate | ✅ TokenClient | — | **完整** |
| **价格预言** | ✅ Chainlink + DVT 校验 | ✅ Keeper service | — | **完整** |
| **信誉系统** | ✅ ReputationSystem | ✅ reputation actions | — | **完整** |
| **ERC-4337 账户** | — (不负责) | ✅ SimpleAccount | ✅ 8 算法 + Factory | **完整** |
| **Session Key** | — | — | ✅ SessionKeyValidator | **AirAccount 独有** |
| **AI Agent Key** | — | — | ✅ AgentSessionKeyValidator | **AirAccount 独有** |
| **ERC-8004** | — | — | ✅ setAgentWallet (M7.16) | **AirAccount 先行** |
| **x402 支付** | ❌ 无 | ❌ 无 | — | **V5.2 待建** |
| **微支付通道** | ❌ 无 | ❌ 无 | — | **V5.2 待建** |
| **SKILL.md** | ❌ 无 | ❌ 无 | — | **V5.3 待建** |
| **MCP 支付** | ❌ 无 | ❌ 无 | — | **V5.3 待建** |

### 关键发现

1. **AirAccount 的 Session Key 和 AI Agent Session 是 V5.2 Payment Channel 的天然基础** — Agent 可以用 AgentSessionKeyValidator 签署 EIP-712 Voucher，无需暴露主密钥

2. **AirAccount 的 ERC-8004 集成 (M7.16) 已经先行** — `setAgentWallet()` 将 Agent NFT ID 映射到 Session Key，SuperPaymaster V5.3 的 `isRegisteredAgent()` 可以直接查询

3. **SDK 的 4 层抽象架构 (L1-L4) 已经为扩展 x402/Channel 模块提供了框架** — 只需新增 packages，不需要重构

---

## 3. V5.1-V5.3 竞争力评估

### 逐层对比

#### Layer 1: Gas 消除 / 结算层

| 能力 | Tempo | Coinbase | SuperPaymaster V5 | 优势方 |
|------|-------|---------|-------------------|--------|
| Gas 消除方式 | 协议原生 (稳定币付 Gas) | Coinbase Paymaster | ERC-4337 Paymaster | Tempo (原生) |
| 适用链 | 仅 Tempo 链 | 仅 Base (主推) | **任何 EVM 链** | **SP (多链)** |
| 运营模式 | Stripe 托管 | Coinbase 托管 | **多 Operator 自部署** | **SP (去中心化)** |
| 计费内核 | Fee Sponsorship | 按笔收费 | `_consumeCredit()` | 对等 |

#### Layer 2-3: 支付协议

| 能力 | Tempo/MPP | Coinbase/x402 | SuperPaymaster V5 | 优势方 |
|------|-----------|--------------|-------------------|--------|
| 单笔支付 | Charge Intent | x402 PaymentPayload | `settleX402Payment()` | 对等 |
| 流式微支付 | Session Intent | ❌ 无 | `MicroPaymentChannel.sol` | Tempo ≈ SP |
| 支付通道签名 | EIP-712 Voucher | — | EIP-712 Voucher | 对等 |
| Session Key 集成 | IAccountKeychain | — | **AirAccount SessionKeyValidator** | **SP (更成熟)** |
| AI Agent 集成 | — | — | **AirAccount AgentSessionKeyValidator** | **SP 独有** |
| 法币入口 | Stripe SPT + Visa | Coinbase Pay | ❌ 无 | Tempo (法币) |
| 结算资产 | 稳定币 + 法币 | USDC | USDC + aPNTs/xPNTs | Tempo (多轨) |

#### Layer 4: 身份 / 发现

| 能力 | Tempo | Coinbase | SuperPaymaster V5 | 优势方 |
|------|-------|---------|-------------------|--------|
| 用户身份 | Stripe KYC | Coinbase Identity | **ERC-8004 + MySBT** (无许可) | **SP (去中心化)** |
| Agent 身份 | — | Coinbase AgentKit | **AirAccount ERC-8004 binding** | **SP (链上)** |
| 服务发现 | SKILL.md + mpp.dev | CDP catalog | SKILL.md + OpenAPI + ERC-8004 Registry | 对等 |
| 分级赞助 | — | — | `agentPolicies` (信誉驱动) | **SP 独有** |
| Agent 签名安全 | 无特殊保护 | 无特殊保护 | **AirAccount Tier Guard + 速率限制** | **SP 独有** |

### 综合评分

```
                    Tempo/MPP    Coinbase/x402    SuperPaymaster V5.3
Gas 消除              ★★★★★        ★★★☆☆            ★★★★☆
单笔支付              ★★★★☆        ★★★★☆            ★★★★☆
流式微支付            ★★★★★        ☆☆☆☆☆            ★★★★☆
身份/发现             ★★★☆☆        ★★★☆☆            ★★★★★
去中心化程度          ★★☆☆☆        ★☆☆☆☆            ★★★★★
账户安全              ★★★☆☆        ★★★☆☆            ★★★★★ (AirAccount)
SDK 成熟度            ★★★★★        ★★★★☆            ★★★☆☆ (待补)
生态采用量            ★★★★☆        ★★★★★            ★☆☆☆☆ (待建)
法币支持              ★★★★★        ★★★★☆            ☆☆☆☆☆
多链覆盖              ★☆☆☆☆        ★★☆☆☆            ★★★★★
─────────────────────────────────────────────────────────
总分 (50)              35            28               36
```

**结论**：技术能力对等甚至局部超越（身份/去中心化/账户安全/多链），但 SDK 成熟度和生态采用量是主要短板。

### 支付协议栈全景对比

| 能力层 | Tempo/MPP | Coinbase x402 | SuperPaymaster V5.3 |
|--------|-----------|---------------|---------------------|
| **Gas 消除** | 协议原生（仅 Tempo 链） | Coinbase Paymaster（中心化） | ERC-4337 Paymaster（任何 EVM 链，多 Operator） |
| **单笔支付** | Charge Intent | x402 PaymentPayload | `settleX402Payment()` + EIP-3009/Permit2 |
| **流式微支付** | Session Intent + Payment Channel | 无 | `MicroPaymentChannel.sol` + EIP-712 Voucher |
| **身份/发现** | SKILL.md + mpp.dev 目录 | CDP | ERC-8004 + SKILL.md + OpenAPI x-payment-info |
| **SDK** | mppx (TS/Rust/Python/Go) | x402 SDK | `@superpaymaster/cli` + Operator Node |
| **部署模式** | Stripe 托管 | Coinbase 托管 | **任何人自部署（开源）** |

**核心定位差异**：Tempo 是 "Stripe 的支付区块链"，x402 是 "Coinbase 的支付协议"，SuperPaymaster 是 **"社区自己的支付基础设施"**。三者架构对等，运营模式根本不同。

---

## 4. 核心差距与弥补策略

### 差距 1 (P0): SDK 成熟度（关键，必须立即弥补）

| 维度 | Tempo/MPP | SuperPaymaster |
|------|-----------|----------------|
| 语言覆盖 | TS + Rust + Python + Go | 仅规划中 |
| 框架适配 | Express/Hono/Next.js/Elysia/Cloudflare | 无 |
| Client 封装 | `mppx.fetch()` 一行代码 | 无 |
| Agent 工具 | CLI + `npx mppx` | 规划中 |

**策略**：不是从零构建——**在现有 @aastar/sdk 架构上扩展 3 个新 package**：

```
@aastar/x402         ← V5.2: x402 验证/结算 + Facilitator middleware
@aastar/channel      ← V5.2: Payment Channel client + Voucher 签名
@aastar/discovery    ← V5.3: SKILL.md hosting + OpenAPI 发现 + MCP 支付信号
```

SDK 的 L1-L4 层级架构已就绪，只需插入新模块。V5.2 优先交付 TypeScript SDK（`@superpaymaster/sdk`），采用 mppx 的 Method 插件 + Middleware 架构模式（已在 Design Doc 7.7.4 详细设计）。后续扩展 Rust/Python。详见 [Section 5](#5-sdk-诉求清单)。

### 差距 2 (P1): 生态采用量（通过运营弥补）

| 维度 | Tempo/MPP | Coinbase x402 | SuperPaymaster |
|------|-----------|---------------|----------------|
| 服务数 | 主网首日 100+ | 131K txns/day | Sepolia 测试阶段 |
| Facilitator 数 | Stripe 生态 | 30+ | 1 (AAStar) |
| 融资 | $500M Series A | Coinbase 资源 | 社区驱动 |

**策略**（不需要代码变更）：
1. **SKILL.md 优先上线** — 让每个 AI Agent 框架（Claude、GPT、Cursor）都能一句话接入
2. **社区 Operator 激励** — 首批 10 个社区 Operator 免费部署，手续费全归 Operator
3. **x402 兼容** — 接入现有 x402 生态的 30+ Facilitator 流量（SuperPaymaster 可验证任何 x402 payment）
4. **ERC-8004 联盟** — MetaMask/Google/Coinbase 联合推动的标准，40+ 链部署，搭便车
5. **AirAccount 用户基底** — 已部署的 AirAccount 用户可直接使用 gasless + 微支付

### 差距 3 (P2): 法币入口（长期可选）

| 维度 | Tempo/MPP | SuperPaymaster |
|------|-----------|----------------|
| 法币支付 | Stripe SPT（信用卡） | 无 |
| Lightning | Lightspark 集成 | 无 |

**策略**：V5.2 的 x402 Facilitator 架构是 **Method 插件式**。未来可扩展：
- `stripe.spt()` — 如果 Stripe 开放 SPT API
- `lightning.bolt11()` — 通过 Lightspark SDK
- 但这是 **V5.4+** 的事，不是核心差距

### 差距 4 (P3): 专有链优势——非差距，是定位差异

Tempo 有自己的 L1（300ms finality、亚美分手续费、无代币 Gas）。SuperPaymaster 运行在以太坊/L2 上。
- Tempo 只能在 Tempo 链上工作
- SuperPaymaster 在**任何 EVM 链**上工作（Ethereum、Optimism、Base、Arbitrum...）
- 甚至可以部署到 Tempo 链上作为补充

### 差距优先级总结

```
P0（必须弥补）: SDK 成熟度 → V5.2 交付 TypeScript SDK
P1（通过运营弥补）: 生态采用量 → SKILL.md + Operator 激励 + x402 兼容
P2（长期可选）: 法币入口 → Method 插件扩展
P3（非差距）: 专有链 → 这是差异化优势，不是劣势
```

**一句话**：技术架构对等完成后（V5.3），核心差距从"能力"转移到"生态"——SDK 和 Operator 网络的建设速度决定了 SuperPaymaster 能否真正成为 Agent Economy 的社区支付层。

---

## 5. SDK 诉求清单

> 以下是 SuperPaymaster V5 对 @aastar/sdk 提出的具体能力诉求。

### 5.1 V5.1 对 SDK 的诉求

#### S1.1: 更新 SuperPaymaster ABI 和 Actions

**现状**：`@aastar/core` 包含 SuperPaymaster ABI (79KB, 400+ functions)，但不包含 V5 新增函数。

**诉求**：
```typescript
// packages/core/src/actions/superPaymaster.ts — 新增
export async function chargeMicroPayment(client, params: {
  operator: Address;
  user: Address;
  usdAmount: bigint;
  nonce: bigint;
  deadline: bigint;
  signature: Hex;
}): Promise<Hash>;

export async function getConsumedCredit(client, params: {
  operator: Address;
  user: Address;
}): Promise<{ totalUsd: bigint; lastTimestamp: bigint }>;
```

**工作量**：ABI 更新 + 2 个新 action 函数。约 1 天。

#### S1.2: EIP-712 签名工具

**现状**：SDK 没有 EIP-712 typed data 签名工具。

**诉求**：
```typescript
// packages/core/src/utils/eip712.ts — 新增
export function signMicroPayment(walletClient, params: {
  operator: Address;
  user: Address;
  amount: bigint;
  nonce: bigint;
  deadline: bigint;
  superPaymasterAddress: Address;
  chainId: number;
}): Promise<Hex>;
```

**工作量**：viem 的 `signTypedData` 封装。约 0.5 天。

### 5.2 V5.2 对 SDK 的诉求

#### S2.1: 新增 `@aastar/x402` package

**诉求**：x402 Facilitator 客户端 SDK。

```typescript
// packages/x402/src/index.ts
export class X402FacilitatorClient {
  // --- Facilitator Server SDK ---

  /** Express/Hono middleware: 拦截请求, 返回 402 challenge */
  middleware(config: { amount: string; asset: Address }): Middleware;

  /** 验证 x402 支付凭证 (调用链上 verifyX402Payment) */
  verify(credential: X402Credential): Promise<VerifyResult>;

  /** 执行链上结算 (调用 settleX402Payment) */
  settle(credential: X402Credential): Promise<SettleResult>;

  /** 查询 Facilitator 费率 */
  quote(params: QuoteParams): Promise<QuoteResult>;

  // --- Agent Client SDK ---

  /** Drop-in fetch replacement (自动处理 402) */
  fetch(url: string, init?: RequestInit): Promise<Response>;

  /** 手动解析 402 challenge */
  parseChallenge(response: Response): X402Challenge;

  /** 手动构建 payment credential */
  buildCredential(challenge: X402Challenge): Promise<X402Credential>;
}
```

**架构参考**：借鉴 mppx 的 Method 插件模式。Facilitator 支持多种支付方法（x402 charge、session channel、aPNTs 内部转账），通过 compose 组合。

**工作量**：新 package。约 3-5 天。

#### S2.2: 新增 `@aastar/channel` package

**诉求**：Payment Channel 客户端。

```typescript
// packages/channel/src/index.ts
export class PaymentChannelClient {
  /** 开通支付通道 (链上) */
  openChannel(params: {
    payee: Address;
    token: Address;
    deposit: bigint;
    authorizedSigner?: Address;  // 可以是 AirAccount Session Key
  }): Promise<{ channelId: Hex; txHash: Hash }>;

  /** 签署累积式 Voucher (链下, 零 gas) */
  signVoucher(params: {
    channelId: Hex;
    cumulativeAmount: bigint;
  }): Promise<SignedVoucher>;

  /** 追加存款 */
  topUp(channelId: Hex, amount: bigint): Promise<Hash>;

  /** 请求关闭通道 */
  requestClose(channelId: Hex): Promise<Hash>;

  /** 结算通道 (payee 调用) */
  settleChannel(channelId: Hex, voucher: SignedVoucher): Promise<Hash>;

  /** 查询通道状态 */
  getChannel(channelId: Hex): Promise<ChannelState>;
}
```

**与 AirAccount 的协同**：`authorizedSigner` 可以直接使用 AirAccount 的 Session Key 地址——Agent 用 Session Key 签 Voucher，主钱包密钥安全离线。

**工作量**：新 package + EIP-712 签名。约 3-5 天。

#### S2.3: Operator Node 框架 (链下服务)

**诉求**：开源的 Facilitator 节点框架。

```typescript
// packages/operator-node/src/server.ts
export function createOperatorNode(config: {
  superPaymasterAddress: Address;
  operatorPrivateKey: Hex;
  chain: Chain;
  challengeSecret: string;  // HMAC secret (无状态 challenge)
}): {
  app: HonoApp;  // 或 Express
  endpoints: {
    'GET /health': HealthHandler;
    'POST /verify': VerifyHandler;
    'POST /settle': SettleHandler;
    'GET /quote': QuoteHandler;
    'GET /.well-known/x-payment-info': DiscoveryHandler;
  };
};
```

**关键设计**：采用 HMAC-SHA256 无状态 challenge（借鉴 MPP），无需 Redis/DB。水平扩展无限制。

**工作量**：新 package。约 5-7 天。

### 5.3 V5.3 对 SDK 的诉求

#### S3.1: 新增 `@aastar/discovery` package

**诉求**：服务发现 + SKILL.md 托管。

```typescript
// packages/discovery/src/index.ts

/** SKILL.md 托管服务 */
export function serveSkillFile(config: {
  name: string;
  description: string;
  commands: SkillCommand[];
}): RequestHandler;  // GET /SKILL.md

/** OpenAPI x-payment-info 注入 */
export function injectPaymentInfo(spec: OpenAPISpec, config: {
  facilitator: Address;
  assets: string[];
  methods: ('charge' | 'session')[];
}): OpenAPISpec;

/** MCP 支付信号 */
export function mcpPaymentRequired(params: {
  facilitator: Address;
  asset: Address;
  amount: string;
}): JsonRpcError;  // code: -32042
```

**工作量**：约 2-3 天。

#### S3.2: 更新 `@aastar/enduser` — ERC-8004 双通道验证

**诉求**：
```typescript
// packages/enduser/src/UserLifecycle.ts — 扩展

/** 检查 Gas 赞助资格 (双通道: SBT OR ERC-8004 Agent) */
async checkEligibility(params: {
  user: Address;
  operator: Address;
  checkERC8004?: boolean;  // 新增: 查询 ERC-8004 Registry
}): Promise<{
  eligible: boolean;
  channel: 'sbt' | 'erc8004' | 'none';
  reputationScore?: bigint;
  sponsorshipRate?: bigint;
}>;
```

**工作量**：扩展现有函数。约 1 天。

#### S3.3: CLI 工具 (`@superpaymaster/cli`)

**诉求**：Agent 可用的命令行工具。

```bash
# 安装
pnpm add -g @superpaymaster/cli

# 核心命令
superpaymaster connect --network sepolia
superpaymaster check <address>          # 检查 Gas 赞助资格
superpaymaster operators --community <name>  # 查找 Operator
superpaymaster sponsor --operator <addr> --userop <json>  # 赞助 UserOp
superpaymaster pay --to <url> --amount <usd>  # x402 支付
superpaymaster channel open --payee <addr> --deposit 10  # 开通支付通道
superpaymaster channel sign --id <id> --amount 0.50  # 签 Voucher
superpaymaster discover --tag "gas-sponsorship"  # 服务发现
```

**依赖**：基于 `@aastar/sdk` 的 L2 Workflow 层构建，复用所有现有逻辑。

**工作量**：约 5-7 天。

### SDK 诉求汇总

| 优先级 | Package | 诉求 | 对应 V5 | 工作量 |
|--------|---------|------|---------|--------|
| P0 | `@aastar/core` | ABI 更新 + chargeMicroPayment action | V5.1 | 1 天 |
| P0 | `@aastar/core` | EIP-712 签名工具 | V5.1 | 0.5 天 |
| P1 | **`@aastar/x402`** | 新 package: Facilitator SDK | V5.2 | 3-5 天 |
| P1 | **`@aastar/channel`** | 新 package: Payment Channel client | V5.2 | 3-5 天 |
| P1 | **`@aastar/operator-node`** | 新 package: Facilitator 节点框架 | V5.2 | 5-7 天 |
| P2 | **`@aastar/discovery`** | 新 package: SKILL.md + OpenAPI + MCP | V5.3 | 2-3 天 |
| P2 | `@aastar/enduser` | ERC-8004 双通道验证 | V5.3 | 1 天 |
| P2 | **`@superpaymaster/cli`** | CLI 工具 | V5.3 | 5-7 天 |
| — | — | **总计** | — | **~21-30 天** |

---

## 6. AirAccount 诉求清单

> 以下是 SuperPaymaster V5 对 AirAccount 提出的具体能力诉求。

### 6.1 V5.1 对 AirAccount 的诉求

#### A1.1: SuperPaymaster V5 ABI 兼容

**现状**：AirAccount 的 `onboard-4-gasless-transfer.ts` 已集成 SuperPaymaster V4 的 `paymasterAndData`。

**诉求**：V5.1 的 `chargeMicroPayment()` 不走 EntryPoint，而是直接调用合约。AirAccount 需要支持这种非 UserOp 的支付路径。

```typescript
// scripts/test-micropayment.ts — 新增 E2E 测试
// 1. AirAccount 用 Session Key 签 EIP-712 MicroPayment
// 2. 直接调用 SuperPaymaster.chargeMicroPayment()
// 3. 无需 EntryPoint / Bundler
```

**工作量**：新增 1 个 E2E 测试脚本。约 0.5 天。

### 6.2 V5.2 对 AirAccount 的诉求（关键协同点）

#### A2.1: Session Key 作为 Payment Channel 的 authorizedSigner

**这是最重要的协同点。**

AirAccount 的 `SessionKeyValidator` (algId 0x08) 已经实现了时间限制的委托签名。SuperPaymaster V5.2 的 `MicroPaymentChannel` 需要 `authorizedSigner` 来签署 EIP-712 Voucher。

**诉求**：

```solidity
// AirAccount 侧：确认 Session Key 可用于 EIP-712 签名
// SessionKeyValidator 当前只验证 UserOp 签名
// 需要确认：Session Key 的私钥是否也可以在链下签 EIP-712 typed data？
```

**答案：可以。** Session Key 本质上是一个 ECDSA 私钥，它在链下可以签署任何数据（包括 EIP-712 Voucher）。AirAccount 的 `SessionKeyValidator` 只负责链上的 UserOp 验证；链下签名是通用 ECDSA 操作，不需要 AirAccount 合约参与。

**但需要验证**：

```typescript
// AirAccount 应新增 E2E 测试验证此流程：
// scripts/test-payment-channel-session.ts

// 1. Agent 通过 AirAccount 创建 Session Key (algId 0x08)
const sessionKey = await createSessionKey({
  duration: 86400,  // 24h
  contractScope: paymentChannelAddress,
  selectorScope: '0x...',  // settleChannel selector
  spendCap: parseEther('10'),
});

// 2. 用 Session Key 签 EIP-712 Voucher (链下)
const voucher = await signTypedData({
  privateKey: sessionKey.privateKey,
  domain: { name: 'MicroPaymentChannel', chainId, verifyingContract },
  types: { Voucher: [{ name: 'channelId', type: 'bytes32' }, { name: 'cumulativeAmount', type: 'uint128' }] },
  primaryType: 'Voucher',
  message: { channelId, cumulativeAmount: parseEther('0.50') },
});

// 3. Payee 提交 Voucher 结算 (链上)
await settleChannel(channelId, voucher);
```

**工作量**：1 个 E2E 测试 + 文档。约 1 天。

#### A2.2: AgentSessionKeyValidator 速率限制与 Payment Channel 协同

**现状**：AirAccount M7.14 的 `AgentSessionKeyValidator` 已有：
- `velocityLimit`: 时间窗口内最大调用次数
- `callTargetAllowlist`: 预批准合约白名单
- `spendCap`: 累计消费上限

**诉求**：将 `MicroPaymentChannel` 合约地址加入 `callTargetAllowlist`，使 Agent 只能：
- 签署 Voucher（链下，无限制）
- 调用 `topUpChannel` 时受 `spendCap` 限制（链上，有安全边界）

**工作量**：配置级变更，约 0.5 天。

### 6.3 V5.3 对 AirAccount 的诉求

#### A3.1: ERC-8004 Agent Identity → SuperPaymaster 赞助资格

**现状**：AirAccount M7.16 已实现 `setAgentWallet(agentId, walletAddress, erc8004Registry)`。

**诉求**：确保此映射可被 SuperPaymaster V5.3 的 `isRegisteredAgent()` 正确查询。

```solidity
// SuperPaymaster V5.3:
function isRegisteredAgent(address account) public view returns (bool) {
    // Query ERC-8004 Identity Registry
    // Check if account owns any agent NFT
    return IERC721(agentIdentityRegistry).balanceOf(account) > 0;
}

// AirAccount 侧需要确保：
// 1. AirAccount 地址是 ERC-8004 NFT 的 owner (balanceOf > 0)
// 2. 或者 AirAccount 通过 setAgentWallet 被关联到一个 agentId
```

**协同机制**：
```
AirAccount 用户注册 ERC-8004 Agent NFT
    → ERC-8004 Identity Registry 记录 (agentId → AirAccount address)
    → SuperPaymaster.isRegisteredAgent(airAccountAddr) == true
    → Agent 自动获得 Gas 赞助资格，无需额外注册 SBT
```

**工作量**：确认接口兼容 + 1 个集成测试。约 1 天。

#### A3.2: AirAccount 作为 x402 Agent Client

**诉求**：AirAccount 的 AI Agent 可以通过 Session Key 自动完成 x402 支付流程：

```
AI Agent (AirAccount Session Key)
    → 发起 HTTP 请求 → 收到 402
    → 用 Session Key 签署 EIP-3009 授权 (USDC transferWithAuthorization)
    → 重试请求，附带 Authorization: Payment credential
    → 200 OK
```

**AirAccount 需要支持**：
1. Session Key 签署 EIP-3009 `transferWithAuthorization` — 需要确认 Session Key 可以代表 AirAccount 签署 EIP-712 数据
2. 或者通过 UserOp 路径：Session Key → UserOp → AirAccount.execute(USDC.transferWithAuthorization) → SuperPaymaster 代付 Gas

**工作量**：E2E 测试验证。约 1 天。

### AirAccount 诉求汇总

| 优先级 | 诉求 | 对应 V5 | 工作量 |
|--------|------|---------|--------|
| P0 | V5 ABI 兼容 + chargeMicroPayment E2E | V5.1 | 0.5 天 |
| **P0** | **Session Key 签 EIP-712 Voucher E2E 验证** | **V5.2** | **1 天** |
| P1 | AgentSessionKey + PaymentChannel callTarget 配置 | V5.2 | 0.5 天 |
| P1 | ERC-8004 → isRegisteredAgent 集成测试 | V5.3 | 1 天 |
| P2 | AirAccount 作为 x402 Agent Client E2E | V5.3 | 1 天 |
| — | **总计** | — | **~4 天** |

---

## 7. 协同发展路线图

### 三项目并行开发时间线

```
                    V5.1            V5.2               V5.3
                 (4 weeks)       (6 weeks)          (6 weeks)
                 ─────────       ──────────         ──────────

SuperPaymaster  [_consumeCredit] [x402 Settle]     [ERC-8004]
  合约          [chargeMicro]    [PaymentChannel]   [agentPolicies]
                [EIP-1153]       [facilitatorFee]   [SKILL.md meta]

SDK             [ABI update]     [@aastar/x402]     [@aastar/discovery]
  @aastar       [EIP-712 util]   [@aastar/channel]  [CLI tool]
                                 [Operator Node]    [ERC-8004 check]

AirAccount      [V5 compat E2E]  [SessionKey +]     [ERC-8004 →]
  合约+脚本                       [Voucher E2E]      [isRegistered]
                                 [AgentKey config]  [x402 client E2E]
```

### 关键交付里程碑

| 里程碑 | 完成标志 | 三项目交付物 |
|--------|---------|------------|
| **M1: Gas+微支付内核** | `chargeMicroPayment()` E2E 通过 | SP: 合约 + SDK: ABI/action + AA: E2E 脚本 |
| **M2: x402 Facilitator** | Operator Node 可部署 + 完成一笔 x402 结算 | SP: settle 合约 + SDK: x402 包 + Node 框架 |
| **M3: Payment Channel** | Agent 用 AirAccount Session Key 签 Voucher 完成流式支付 | SP: Channel 合约 + SDK: channel 包 + AA: Session Key E2E |
| **M4: Agent 发现** | AI Agent 通过 SKILL.md 自动发现并接入 | SP: agentPolicies + SDK: discovery + CLI + AA: ERC-8004 集成 |
| **M5: 生态启动** | 首批 3 个 Operator 上线 | 全栈集成测试通过 |

### 接口契约（三项目间的约定）

```
SuperPaymaster ←→ SDK:
  · SDK 读取 deployments/config.<network>.json 获取所有合约地址
  · SDK 使用 contracts/abis/ 下的 ABI 文件 (sync_to_sdk.sh 同步)
  · 新合约函数发布后 24h 内 SDK 更新 actions

SuperPaymaster ←→ AirAccount:
  · AirAccount 通过标准 ERC-4337 paymasterAndData 集成 (不改合约)
  · V5.2 Payment Channel: AirAccount Session Key 地址作为 authorizedSigner
  · V5.3 ERC-8004: SuperPaymaster 查询 ERC-8004 Registry (AirAccount 只需注册)

SDK ←→ AirAccount:
  · @aastar/airaccount 包已存在 (53 TS files)
  · 新增 Payment Channel 签名需通过 @aastar/channel 包调用 Session Key
  · CLI 工具支持 AirAccount 钱包格式
```

---

## 8. 风险与依赖分析

### 技术风险

| 风险 | 影响 | 缓解 |
|------|------|------|
| EIP-3009 支持有限 (非 USDC token) | x402 settle 路径受限 | Permit2 后备路径已设计 (V5.2 F2) |
| Payment Channel 争议窗口设计 | 资金锁定时间 vs 安全性 trade-off | 参考 Tempo 的可配置窗口 + 社区治理 |
| ERC-8004 标准未最终确定 | 接口可能变更 | 使用 adapter 模式隔离 |
| Session Key 签署 EIP-712 的安全隐患 | Session Key 泄露 → Voucher 伪造 | AirAccount 的 spendCap + velocityLimit 提供安全边界 |

### 依赖风险

| 依赖 | 风险 | 缓解 |
|------|------|------|
| Chainlink Price Feed | 停止更新 → 价格过期 | DVT 校验 + 手动更新后备 (Keeper) |
| ERC-4337 EntryPoint v0.7 | 标准演进 → API 变化 | AirAccount V7 已固定版本 |
| viem 库 | 版本不兼容 | SDK 和 AirAccount 已统一使用 viem |
| Tempo/MPP 开源代码 | 许可证变更 | 所有参考代码 Apache 2.0，提取模式不依赖运行时 |

### 非技术风险

| 风险 | 影响 | 缓解 |
|------|------|------|
| Tempo 吞噬市场 | Agent 选择 Tempo 而非 SP | 差异化: 多链 + 社区自部署 + 无 KYC |
| x402 标准分裂 | MPP vs x402 不兼容 | 两者已互补 (MPP charge = x402 charge)，SP 两边都支持 |
| 首批 Operator 不足 | 冷启动问题 | AAStar 自身作为首个 Operator + 学术社区 (CMU) |

---

## 9. 实施计划与评分追踪

### 分支与 Worktree 策略

基于当前 `feature/uups-migration` 分支，开设三个并行 worktree：

```
feature/uups-migration (当前, V4.1.0 稳定基线)
    │
    ├── feature/v5.1-consume-credit     ← worktree: .claude/worktrees/v5.1
    │   纯合约重构 + 新增函数，不依赖其他 V5 分支
    │
    ├── feature/v5.2-x402-facilitator   ← worktree: .claude/worktrees/v5.2
    │   新增独立合约 (MicroPaymentChannel.sol) + SuperPaymaster 扩展
    │   可与 V5.1 并行开发（独立文件）
    │
    └── feature/v5.3-erc8004-discovery  ← worktree: .claude/worktrees/v5.3
        新增配置/查询函数 + 链下交付物
        可与 V5.1/V5.2 并行开发（独立文件 + 链下代码）

串行集成:
    V5.1 完成 → merge to feature/v5.2 → 集成测试
    V5.2 完成 → merge to feature/v5.3 → 集成测试
    V5.3 完成 → merge to main → 全量回归测试
```

**并行可行性分析**：

| 工作项 | 文件冲突风险 | 并行条件 |
|--------|-------------|---------|
| V5.1 `_consumeCredit()` | 修改 SuperPaymaster.sol (postOp 重构) | 独立进行 |
| V5.2 `settleX402Payment()` | 新增函数到 SuperPaymaster.sol | 新函数，不冲突 |
| V5.2 `MicroPaymentChannel.sol` | **新增独立合约** | 完全并行 |
| V5.3 `isRegisteredAgent()` | 新增函数到 SuperPaymaster.sol | 新函数，不冲突 |
| V5.3 SKILL.md / CLI | **链下代码** | 完全并行 |

**结论**：V5.1 修改现有函数（postOp 重构），V5.2/V5.3 新增函数和独立合约——**三者可并行开发，串行集成**。

### 阶段性评分追踪

完成每个 V5.x 后，重新评估竞争力评分：

```
维度                当前(V4.1)  V5.1完成  V5.2完成  V5.3完成  目标
─────────────────────────────────────────────────────────
Gas 消除             ★★★★☆    ★★★★☆   ★★★★☆   ★★★★☆   ★★★★☆
单笔支付             ☆☆☆☆☆    ★★☆☆☆   ★★★★☆   ★★★★☆   ★★★★☆
流式微支付           ☆☆☆☆☆    ☆☆☆☆☆   ★★★★☆   ★★★★☆   ★★★★☆
身份/发现            ★★☆☆☆    ★★☆☆☆   ★★☆☆☆   ★★★★★   ★★★★★
去中心化程度         ★★★★★    ★★★★★   ★★★★★   ★★★★★   ★★★★★
账户安全(AirAccount) ★★★★★    ★★★★★   ★★★★★   ★★★★★   ★★★★★
SDK 成熟度           ★★☆☆☆    ★★★☆☆   ★★★★☆   ★★★★☆   ★★★★★
生态采用量           ★☆☆☆☆    ★☆☆☆☆   ★★☆☆☆   ★★★☆☆   ★★★★☆
法币支持             ☆☆☆☆☆    ☆☆☆☆☆   ☆☆☆☆☆   ☆☆☆☆☆   ★★☆☆☆
多链覆盖             ★★★★★    ★★★★★   ★★★★★   ★★★★★   ★★★★★
─────────────────────────────────────────────────────────
总分 (50)              22        26       33       36       42
vs Tempo (35)         -13        -9       -2       +1       +7
vs Coinbase (28)       -6        -2       +5       +8      +14
```

**关键拐点**：V5.2 完成后首次接近 Tempo (33 vs 35)，V5.3 完成后首次超越 (36 vs 35)。

### 详细实施计划文档

| 文档 | 路径 | 内容 |
|------|------|------|
| **Master Plan** | [docs/V5-Implementation-Plan.md](./V5-Implementation-Plan.md) | 高维度进度安排、分支策略、集成路径 |
| **V5.1 Plan** | [docs/V5.1-Plan.md](./V5.1-Plan.md) | `_consumeCredit` 提取 + `chargeMicroPayment` 详细任务、验收标准 |
| **V5.2 Plan** | [docs/V5.2-Plan.md](./V5.2-Plan.md) | x402 Facilitator + Payment Channel 详细任务、验收标准 |
| **V5.3 Plan** | [docs/V5.3-Plan.md](./V5.3-Plan.md) | ERC-8004 + SKILL.md + Agent Discovery 详细任务、验收标准 |

---

## 附录: 关联文档索引

| 文档 | 路径 | 描述 |
|------|------|------|
| V5 Roadmap | [docs/V5-Roadmap.md](./V5-Roadmap.md) | V5 完整路线图 (v1.4.0) |
| V5 Design Doc | [docs/SuperPaymaster-V5-Design.md](./SuperPaymaster-V5-Design.md) | V5 架构设计 (v0.6.0) |
| Tempo/MPP Research | [docs/research-stripe-tempo-mpp.md](./research-stripe-tempo-mpp.md) | Stripe Tempo 深度研究 (v1.1.0) |
| UUPS Upgrade Doc | [docs/UUPS-upgrade-doc.md](./UUPS-upgrade-doc.md) | UUPS 代理架构文档 |
| SDK 项目 | `../aastar-sdk/` | 15 packages monorepo |
| AirAccount 合约 | `../airaccount-contract/` | ERC-4337 智能钱包 |
| AirAccount KMS | `../AirAccount/` | Rust TEE 密钥管理 |
