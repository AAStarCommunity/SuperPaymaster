# SuperPaymaster

**Decentralized Payment & Gas Sponsorship Infrastructure for ERC-4337**

**[English](#english)** | **[中文](#chinese)**

> **Beta 0.22** (Internal: V5.3) — Sepolia Testnet Live

<a name="english"></a>

---

## What is SuperPaymaster?

SuperPaymaster is a **multi-mode payment infrastructure** for the ERC-4337 Account Abstraction ecosystem. It goes beyond simple gas sponsorship — combining gasless transactions, x402 resource payments, micropayment channels, and AI agent economy into a unified on-chain settlement layer.

### Who is it for?

- **Communities**: Sponsor gas fees for members using community tokens (xPNTs)
- **AI Agents**: Discover and pay for on-chain services via ERC-8004 identity + x402
- **Developers**: Integrate gasless UX, micropayments, or x402 settlement with battle-tested contracts
- **Operators**: Run decentralized paymaster nodes with DVT/BLS consensus

---

## Payment Modes

SuperPaymaster supports **4 payment channels** in a single contract system:

| Mode | Protocol | Description | Since |
|------|----------|-------------|-------|
| **Gas Sponsorship** | ERC-4337 | Operators pre-fund aPNTs; users pay zero gas, repay in xPNTs (community tokens) | V3 |
| **x402 Settlement** | HTTP 402 + EIP-3009 | Single-payment resource purchases — client pays USDC/xPNTs per request | V5.1 |
| **Micropayment Channel** | EIP-712 Vouchers | Streaming micro-charges with off-chain signing and batch on-chain settlement | V5.2 |
| **Agent Sponsorship** | ERC-8004 | Reputation-driven tiered gas sponsorship for registered AI agents | V5.3 |

### Two Operating Modes

- **AOA+ Mode** (SuperPaymaster): Shared multi-operator paymaster with Registry-based community management
- **AOA Mode** (PaymasterV4): Independent per-community paymasters deployed via EIP-1167 minimal proxy factory

---

## Architecture

```
                    ┌──────────────────────────────────┐
                    │         EntryPoint v0.7           │
                    │   (ERC-4337 Standard)             │
                    └──────────┬───────────────────────┘
                               │
              ┌────────────────┼────────────────┐
              ▼                ▼                ▼
   ┌──────────────────┐ ┌───────────┐ ┌──────────────────┐
   │  SuperPaymaster   │ │ Paymaster │ │ MicroPayment     │
   │  (AOA+ Shared)    │ │ V4 (AOA)  │ │ Channel          │
   │  ┌──────────────┐ │ │ EIP-1167  │ │ EIP-712 Vouchers │
   │  │ Gas Sponsor  │ │ │ Proxies   │ │ Batch Settle     │
   │  │ x402 Settle  │ │ └───────────┘ └──────────────────┘
   │  │ Agent Policy │ │
   │  │ Credit/Debt  │ │
   │  └──────────────┘ │
   └────────┬──────────┘
            │
   ┌────────┼──────────────────────────────────┐
   │        ▼            ▼            ▼        │
   │   ┌─────────┐ ┌─────────┐ ┌───────────┐  │
   │   │Registry │ │ MySBT   │ │ GToken    │  │
   │   │ (UUPS)  │ │ (SBT)   │ │ Staking   │  │
   │   └─────────┘ └─────────┘ └───────────┘  │
   │        ▼            ▼                     │
   │   ┌──────────┐ ┌──────────────┐           │
   │   │xPNTs     │ │ Reputation   │           │
   │   │Factory   │ │ System       │           │
   │   └──────────┘ └──────────────┘           │
   │                                           │
   │   ┌──────────┐ ┌──────────────┐           │
   │   │DVT       │ │ BLS          │           │
   │   │Validator │ │ Aggregator   │           │
   │   └──────────┘ └──────────────┘           │
   └───────────────────────────────────────────┘
              Supporting Contracts
```

### Core Contracts

| Contract | Version | Type | Role |
|----------|---------|------|------|
| **SuperPaymaster** | 5.3.0 | UUPS Proxy | AOA+ shared paymaster — gas sponsorship, x402, agent policies, credit/debt |
| **Registry** | 4.1.0 | UUPS Proxy | Community/node registration, role management, BLS replay protection, slashing |
| **PaymasterV4** | 4.3.0 | EIP-1167 Proxy | AOA independent paymaster per community |
| **GToken** | 2.0.0 | ERC20 | Governance token (21M cap, mintable, burnable) |
| **GTokenStaking** | 3.2.0 | Immutable | Role-based staking with burn mechanism, DVT/governance slashing |
| **MySBT** | 3.1.3 | ERC721 (Soulbound) | Identity + reputation, community membership, SBT-gated sponsorship |
| **xPNTsFactory** | 2.0.0 | Clones | Deploys per-community xPNTs gas tokens |
| **ReputationSystem** | 1.0.0 | — | Community-rule-based reputation scoring |
| **BLSAggregator** | 1.0.0 | — | BLS12-381 threshold signature aggregation |
| **DVTValidator** | 1.0.0 | — | Distributed validator consensus (7-of-13 quorum) |
| **PaymasterFactory** | 1.0.0 | — | EIP-1167 proxy factory for PaymasterV4 instances |

### V5 Feature Highlights

**V5.1 — x402 Exact Settlement**
- `settleX402Payment()` — EIP-3009 `transferWithAuthorization` for USDC-native settlement
- `settleX402PaymentDirect()` — `transferFrom` for xPNTs (auto-approved by factory)
- `chargeMicroPayment()` — EIP-712 signed deferred settlement

**V5.2 — Micropayment Channel**
- `MicroPaymentChannel` contract — open/sign/settle streaming sessions
- EIP-712 cumulative voucher signing with dispute window
- Batch settlement for high-frequency micro-charges

**V5.3 — Agent Economy (ERC-8004)**
- Dual-channel eligibility: SBT holders OR registered AI agents
- `AgentSponsorshipPolicy` — per-operator tiered BPS rates + daily USD cap
- `_submitSponsorshipFeedback()` — on-chain reputation feedback loop
- EIP-1153 transient storage cache for same-operator batch optimization

### Security Architecture

- **UUPS Upgradeable Proxies** for Registry and SuperPaymaster
- **ReentrancyGuard** on all state-changing functions
- **Two-tier slashing**: aPNTs (operational) + GToken stake (governance)
- **DVT/BLS consensus**: 7-of-13 Byzantine quorum for validator operations
- **Chainlink oracle** with staleness check, price bounds ($100–$100K), and keeper cache
- **Zero-address guards** on all setter functions (L-04 audit fix)
- **BLS replay protection** with non-zero proposalId enforcement (H-02 audit fix)
- **CEI order** in postOp with nonReentrant double protection (H-01 audit fix)

---

## Quick Start

### Prerequisites

- [Foundry](https://book.getfoundry.sh/) (Solidity 0.8.33, via-IR, Cancun EVM)
- [Node.js](https://nodejs.org/) v18+
- [pnpm](https://pnpm.io/)

### Build & Test

```bash
# Clone and init submodules
git clone https://github.com/AAStarCommunity/SuperPaymaster.git
cd SuperPaymaster
./init-submoduel.sh

# Build
forge build

# Run all tests (400+ tests)
forge test

# Run specific test suite
forge test --match-path contracts/test/v3/Registry.t.sol

# Run with gas report
forge test --gas-report

# Echidna fuzz testing
echidna . --config echidna.yaml
```

### Deploy

```bash
# Deploy to local Anvil
./deploy-core anvil

# Deploy to Sepolia
./deploy-core sepolia

# Prepare test accounts
./prepare-test sepolia

# Run E2E gasless tests
cd script/gasless-tests && pnpm install && ./run-all-tests.sh
```

For secure mainnet deployment with Foundry Keystore, see [Deployment Guide](./docs/DEPLOYMENT_V3_GUIDE.md).

---

## Contract Addresses (Sepolia)

| Contract | Proxy | Implementation |
|----------|-------|----------------|
| Registry | `0xD88CF5316c64f753d024fcd665E69789b33A5EB6` | `0x84bB9e3CAfb90C5938731A6dA1ADdee301F0B2D0` |
| SuperPaymaster | `0x829C3178DeF488C2dB65207B4225e18824696860` | `0xf4d022Ea721Aaa1Dec8CC8f3B630547D34C6c972` |
| ReputationSystem | — | `0x3384317Da5312077218C990CeB1010CCb5dc5897` |
| GToken | — | `0x868F8437F1be18008B31E4E590e62C0BfD81B72c` |
| GTokenStaking | — | `0x92eD5b65A97E98ee84B3d3d73aA33F678B68a64B` |
| MySBT | — | `0xc108584B5b6bc7D95e55E12FCEFa61108cE0D378` |
| xPNTsFactory | — | `0xC2AFEA04f06C2A8d2A19cCd1839DFaf84b6bC1e0` |
| PaymasterFactory | — | `0x65Cf6C4ab3d40f3C919b6F3CADC09Efb72817920` |

**EntryPoint v0.7**: `0x0000000071727De22E5E9d8BAf0edAc6f37da032`

**Mainnet**: Pending audit — deployment after Beta stabilization.

---

## Documentation

### Architecture & Design
- [Contract Architecture](./docs/CONTRACT_ARCHITECTURE.md)
- [UUPS Upgrade Guide](./docs/UUPS-upgrade-doc.md)
- [DVT + BLS Architecture](./docs/DVT_BLS_Architecture.md)
- [V5 Design Overview](./docs/SuperPaymaster-V5-Design.md)
- [x402 Ecosystem Research](./docs/research-x402-ecosystem-2026-03.md)
- [Agent + x402 + Micropayment Research](./docs/research-agent-x402-micropayment.md)

### Developer Guides
- [Developer Integration Guide](./docs/DEVELOPER_INTEGRATION_GUIDE.md) — Gasless, x402, micropayment scenarios
- [SDK E2E Scenario Guide](./docs/SDK-E2E-Scenario-Guide.md) — 7 complete user scenarios
- [Ecosystem Services Setup](./docs/ECOSYSTEM-SERVICES-SETUP-GUIDE.md) — Operator node, facilitator, keeper

### API References
- [SuperPaymaster API](./docs/API_SUPERPAYMASTER.md) (V5.3.0)
- [Registry API](./docs/API_REGISTRY.md) (V4.1.0)
- [MySBT API](./docs/API_MYSBT.md)

### Security
- [Security Policy](./docs/SECURITY.md)
- [Audit Fix Summary](./docs/challenger-review-2026-03-26.md)

### Testing
- [Anvil Testing Guide](./docs/Anvil_Testing_Guide.md)
- [E2E Test Guide](./docs/E2E-TEST-GUIDE.md)
- [Gasless Test Guide](./docs/GASLESS_TEST_GUIDE.md)

---

## Repository Structure

```
SuperPaymaster/
├── contracts/
│   ├── src/
│   │   ├── paymasters/
│   │   │   ├── superpaymaster/v3/   # SuperPaymaster (UUPS)
│   │   │   └── v4/                  # PaymasterV4 (AOA mode)
│   │   ├── core/
│   │   │   ├── Registry.sol         # Community registry (UUPS)
│   │   │   ├── GTokenStaking.sol    # Staking + slashing
│   │   │   └── PaymasterFactory.sol # EIP-1167 factory
│   │   ├── tokens/
│   │   │   ├── GToken.sol           # Governance token
│   │   │   ├── MySBT.sol            # Soulbound identity
│   │   │   ├── xPNTsFactory.sol     # Community token factory
│   │   │   └── xPNTsToken.sol       # Community gas token
│   │   ├── modules/
│   │   │   ├── validators/          # BLS validator
│   │   │   ├── monitoring/          # DVT + BLS aggregator
│   │   │   └── reputation/          # Reputation system
│   │   └── interfaces/              # Contract interfaces
│   ├── test/                        # 400+ Foundry tests
│   ├── script/                      # Forge deployment scripts
│   └── lib/                         # Dependencies (OZ, Chainlink, Solady)
├── script/
│   └── gasless-tests/               # E2E Sepolia test suite
├── deployments/                     # Config per network
├── docs/                            # All documentation
├── abis/                            # Extracted ABI JSONs
└── subgraph/                        # The Graph indexing
```

---

## Security

- 400+ Foundry tests passing (including UUPS upgrade, V5 feature, fuzz tests)
- Echidna property-based fuzzing
- Internal adversarial review completed
- External audit pending for mainnet deployment

**Report a Vulnerability**: jason@aastar.io or david@aastar.io — see [Security Policy](./docs/SECURITY.md)

---

## Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/amazing-feature`
3. Run tests: `forge test`
4. Commit: `git commit -m 'feat: Add amazing feature'`
5. Open a Pull Request

**Code style**: `forge fmt` — Solidity 0.8.33, comments in English.

---

## Links

- **Website**: [aastar.io](https://aastar.io)
- **Dashboard**: [superpaymaster.aastar.io](https://superpaymaster.aastar.io)
- **GitHub**: [AAStarCommunity](https://github.com/AAStarCommunity)
- **Registry Frontend**: [AAStarCommunity/registry](https://github.com/AAStarCommunity/registry)

---

## License

MIT — see [LICENSE](./LICENSE)

---

<a name="chinese"></a>

# SuperPaymaster — 去中心化支付与 Gas 赞助基础设施

**[English](#english)** | **[中文](#chinese)**

> **Beta 0.22** (内部版本: V5.3) — Sepolia 测试网运行中

## SuperPaymaster 是什么？

SuperPaymaster 是 ERC-4337 账户抽象生态的**多模式支付基础设施**。它不仅仅是 Gas 赞助——而是将无 Gas 交易、x402 资源支付、微支付通道和 AI Agent 经济统一到一个链上结算层中。

### 面向谁？

- **社区**: 用社区代币 (xPNTs) 为成员赞助 Gas 费
- **AI Agent**: 通过 ERC-8004 身份 + x402 发现并支付链上服务
- **开发者**: 集成无 Gas UX、微支付或 x402 结算
- **运营商**: 运行去中心化 Paymaster 节点（DVT/BLS 共识）

---

## 支付模式

| 模式 | 协议 | 描述 | 版本 |
|------|------|------|------|
| **Gas 赞助** | ERC-4337 | 运营商预存 aPNTs，用户零 Gas 交易，以 xPNTs 偿还 | V3 |
| **x402 结算** | HTTP 402 + EIP-3009 | 单次资源购买 — USDC/xPNTs 按请求付费 | V5.1 |
| **微支付通道** | EIP-712 凭证 | 流式微额扣费，链下签名 + 批量链上结算 | V5.2 |
| **Agent 赞助** | ERC-8004 | 基于声誉的分级 Gas 赞助（注册 AI Agent） | V5.3 |

### 双模式运营

- **AOA+ 模式** (SuperPaymaster): 共享多运营商 Paymaster，Registry 管理社区
- **AOA 模式** (PaymasterV4): 每社区独立 Paymaster，EIP-1167 最小代理工厂部署

---

## 核心合约

| 合约 | 版本 | 类型 | 职责 |
|------|------|------|------|
| **SuperPaymaster** | 5.3.0 | UUPS 代理 | AOA+ 共享 Paymaster — Gas 赞助、x402、Agent 策略、信用/债务 |
| **Registry** | 4.1.0 | UUPS 代理 | 社区/节点注册、角色管理、BLS 重放保护、惩罚 |
| **PaymasterV4** | 4.3.0 | EIP-1167 代理 | AOA 独立 Paymaster |
| **GToken** | 2.0.0 | ERC20 | 治理代币（2100 万上限，限量发行） |
| **GTokenStaking** | 3.2.0 | 不可变 | 基于角色的质押 + 燃烧机制，DVT/治理惩罚 |
| **MySBT** | 3.1.3 | ERC721（灵魂绑定） | 身份 + 声誉，社区会员，SBT 门控赞助 |
| **xPNTsFactory** | 2.0.0 | Clones | 部署每社区 xPNTs Gas 代币 |
| **ReputationSystem** | 1.0.0 | — | 基于社区规则的声誉评分 |
| **BLSAggregator** | 1.0.0 | — | BLS12-381 阈值签名聚合 |
| **DVTValidator** | 1.0.0 | — | 分布式验证者共识（7/13 拜占庭法定人数） |

---

## V5 特性

**V5.1 — x402 精确结算**
- `settleX402Payment()` — EIP-3009 USDC 原生结算（节省 19% Gas）
- `settleX402PaymentDirect()` — xPNTs 直接转账（工厂自动授权）

**V5.2 — 微支付通道**
- `MicroPaymentChannel` 合约 — 开通/签名/结算流式会话
- EIP-712 累计凭证签名 + 争议窗口

**V5.3 — Agent 经济 (ERC-8004)**
- 双通道资格：SBT 持有者 **或** 注册 AI Agent
- `AgentSponsorshipPolicy` — 每运营商分级 BPS 费率 + 每日 USD 上限
- 声誉反馈闭环 + EIP-1153 瞬态存储优化

---

## 快速开始

```bash
# 克隆并初始化子模块
git clone https://github.com/AAStarCommunity/SuperPaymaster.git
cd SuperPaymaster && ./init-submoduel.sh

# 构建
forge build

# 运行所有测试（400+）
forge test

# 部署到本地 Anvil
./deploy-core anvil

# 部署到 Sepolia
./deploy-core sepolia
```

---

## 合约地址（Sepolia 测试网）

| 合约 | 代理地址 | 实现地址 |
|------|----------|----------|
| Registry | `0xD88CF531...` | `0x84bB9e3C...` |
| SuperPaymaster | `0x829C3178...` | `0xf4d022Ea...` |
| ReputationSystem | — | `0x3384317D...` |

**EntryPoint v0.7**: `0x0000000071727De22E5E9d8BAf0edAc6f37da032`

完整地址见 [`deployments/config.sepolia.json`](./deployments/config.sepolia.json)

---

## 文档

- [合约架构](./docs/CONTRACT_ARCHITECTURE.md) | [UUPS 升级指南](./docs/UUPS-upgrade-doc.md)
- [开发者集成指南](./docs/DEVELOPER_INTEGRATION_GUIDE.md) — 无 Gas、x402、微支付场景
- [SDK E2E 场景指南](./docs/SDK-E2E-Scenario-Guide.md) — 7 个完整用户场景
- [SuperPaymaster API](./docs/API_SUPERPAYMASTER.md) | [Registry API](./docs/API_REGISTRY.md)
- [安全策略](./docs/SECURITY.md) | [审计修复总结](./docs/challenger-review-2026-03-26.md)

---

## 安全

- 400+ Foundry 测试通过（含 UUPS 升级、V5 特性、模糊测试）
- Echidna 属性测试
- 内部对抗性审查完成
- 外部审计待主网部署前完成

**报告漏洞**: jason@aastar.io 或 david@aastar.io

---

## 许可证

MIT — 见 [LICENSE](./LICENSE)
