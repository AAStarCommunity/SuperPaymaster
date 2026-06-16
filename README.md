# SuperPaymaster

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![arXiv](https://img.shields.io/badge/arXiv-2605.05774-b31b1b.svg)](https://arxiv.org/abs/2605.05774)

**Decentralized Payment & Gas Sponsorship Infrastructure for ERC-4337**

**[English](#english)** | **[中文](#chinese)**

> **v5.4.0-beta.1-redeploy** (God-Split Beta · X402Facilitator + PolicyRegistry + Timelock) — Sepolia Testnet Live
> · [Release Notes](https://github.com/AAStarCommunity/SuperPaymaster/releases/tag/v5.4.0-beta.1-redeploy)
> · [Integration Guide](./docs/integration/v5.3.3-beta.2-integration-guide.md)
> · [Coverage Report](./docs/coverage-report-2026-06-02.md)

<a name="english"></a>

---

## What is SuperPaymaster?

SuperPaymaster is a **multi-mode payment infrastructure** for the ERC-4337 Account Abstraction ecosystem. It goes beyond simple gas sponsorship — combining gasless transactions, x402 resource payments, micropayment channels, and AI agent economy into a unified on-chain settlement layer.

> **Research paper**: Huifeng Jiao, Nathapon Udomlertsakul. *"SuperPaymaster: Eliminating Centralized Signer Authority via Asset-Oriented Abstraction to Reconcile Usability and Decentralization in Account Abstraction"* — [arXiv:2605.05774](https://arxiv.org/abs/2605.05774). Introduces Asset-Oriented Abstraction (AOA), anchoring sponsorship authority in on-chain Gas Cards instead of off-chain signers; ~49% gas reduction vs. commercial baselines on Optimism Mainnet.

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
| **x402 Settlement** *(contracts live; SDK signing [integrating](https://github.com/AAStarCommunity/aastar-sdk/issues/39))* | HTTP 402 + EIP-3009 | Single-payment resource purchases — client pays USDC/xPNTs per request | V5.1 |
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
| **SuperPaymaster** | 5.4.0¹ | UUPS Proxy | AOA+ shared paymaster — gas sponsorship, x402, agent policies, credit/debt |
| **X402Facilitator** | 1.0.0 | Standalone | x402 settlement split out of SuperPaymaster — EIP-3009 USDC + xPNTs direct settle, fee model |
| **PolicyRegistry** | 1.0.0 | Standalone | Shared on-chain governance-gated spend policy (checkPolicy / recordSpend) |
| **TimelockController** | OZ v5.0.2 | Governance | Delayed-execution governor for upgrades & privileged ops |
| **Registry** | 5.4.0 | UUPS Proxy | Community/node registration, role management, BLS replay protection, slashing |
| **PaymasterV4** | 4.3.0 | EIP-1167 Proxy | AOA independent paymaster per community |
| **GToken** | 2.0.0 | ERC20 | Governance token (21M cap, mintable, burnable) |
| **GTokenStaking** | 3.2.0 | Immutable | Role-based staking with burn mechanism, DVT/governance slashing |
| **MySBT** | 3.1.3 | ERC721 (Soulbound) | Identity + reputation, community membership, SBT-gated sponsorship |
| **xPNTsFactory** | 2.0.0 | Clones | Deploys per-community xPNTs gas tokens |
| **ReputationSystem** | 1.0.0 | — | Community-rule-based reputation scoring |
| **BLSAggregator** | 1.0.0 | — | BLS12-381 threshold signature aggregation |
| **DVTValidator** | 1.0.0 | — | Distributed validator consensus (7-of-13 quorum) |
| **PaymasterFactory** | 1.0.0 | — | EIP-1167 proxy factory for PaymasterV4 instances |

> ¹ The v5.4 GA bump is **applied**: the on-chain `version()` strings are now `SuperPaymaster-5.4.0` and `Registry-5.4.0` (god-split: settlement + policy extracted to standalone `X402Facilitator` / `PolicyRegistry`). The standalone contracts keep their own `1.0.0` versions.

### V5 Feature Highlights

**V5.1 — x402 Settlement** *(contracts live; `@aastar/x402` SDK signing integrating — [aastar-sdk#39](https://github.com/AAStarCommunity/aastar-sdk/issues/39))*
- `settleX402Payment()` — EIP-3009 `transferWithAuthorization` for USDC-native settlement; recipient bound into the nonce (C-03)
- `settleX402PaymentDirect()` — xPNTs settle gated by a payer EIP-712 `X402PaymentAuthorization` signature (C-02) + factory/facilitator whitelist
- *`chargeMicroPayment()` (off-path metered charge) — **designed, not deployed**; the session/limited-payment use case is covered by AirAccount Session Keys at the account layer (see division of labor below)*

**V5.2 — Micropayment Channel**
- `MicroPaymentChannel` contract — open/sign/settle streaming sessions
- EIP-712 cumulative voucher signing with dispute window
- Batch settlement for high-frequency micro-charges

**V5.3 — Agent Economy (ERC-8004)**
- Dual-channel eligibility: SBT holders OR registered AI agents
- `AgentSponsorshipPolicy` — per-operator tiered BPS rates + daily USD cap
- `_submitSponsorshipFeedback()` — on-chain reputation feedback loop
- EIP-1153 transient storage cache for same-operator batch optimization

### AAStar Stack & Division of Labor

SuperPaymaster is the **settlement & gas-sponsorship layer** — it pairs with
[AirAccount](https://github.com/AAStarCommunity/airaccount-contract) (the account layer) rather
than duplicating it:

| Concern | Layer | Owner |
|---------|-------|-------|
| WHO can sign & WITH what limits (passkey, session keys, target/selector/velocity/quota, recovery) | Account | **AirAccount** |
| WHO pays gas & HOW it settles (gasless sponsorship, xPNTs credit/debt, reputation pricing, x402 + channel settlement) | Settlement | **SuperPaymaster** |

This is why SuperPaymaster does **not** implement spending-limit or session-payment logic — those
are enforced by AirAccount Session Keys at the account, and SuperPaymaster sponsors & settles.
Announcement copy (Twitter / Discord / blog): [`docs/announcements/`](./docs/announcements/).

### Security Architecture

- **UUPS Upgradeable Proxies** for Registry and SuperPaymaster
- **ReentrancyGuard** on all state-changing functions
- **Two-tier slashing**: aPNTs (operational) + GToken stake (governance)
- **DVT/BLS consensus**: 7-of-13 Byzantine quorum for validator operations
- **Chainlink oracle** with staleness check, price bounds ($100–$100K), and keeper cache
- **Zero-address guards** on all setter functions (L-04 audit fix)
- **BLS replay protection** with non-zero proposalId enforcement (H-02 audit fix)
- **CEI order** in postOp with nonReentrant double protection (H-01 audit fix)

**v5.3.3-beta.2 security hardening** (6 audit fixes, all on-chain-verified — see
[Coverage Report](./docs/coverage-report-2026-06-02.md)):
- **C-01** balance-aware credit ceiling · **C-02** signed x402 direct settle (EIP-712 `X402PaymentAuthorization`)
- **C-03** recipient-bound EIP-3009 nonce · **C-04** postOp out-of-gas floor (`MIN_POST_OP_GAS`)
- **H-01** chunked `retryPendingDebt` · **H-02** PoP-gated permissionless BLS registration (switch default OFF)

**v5.3.3-beta.4/.5 audit 2nd-pass** (`comprehensive-audit-2026-06-11`, Opus adversarial review — 14 findings triaged, 4 fixed + 10 wontfix/deferred):
- **H-1** credit ceiling enforced in validation regardless of balance (Plan A) · **M-1** x402 EIP-3009 payer-signed `maxFee` + fee-on-transfer guard + front-run fix (`receiveWithAuthorization`)
- **M-6** `exitRole` fund release gated on Staking source-of-truth · **L-9** `MicroPaymentChannel` fee-on-transfer delta-credit · **L-7** `ProposalMarkedExecuted` audit event
- 10 findings closed as permissionless-by-design / trusted-boundary / unreachable after Opus challenge; RC-2 deprecated, H-6 reduced via governance (operator Safe multisig + rate-change proposal flow). Full triage: [`docs/planning/backlog-triage-2026-06-14.md`](./docs/planning/backlog-triage-2026-06-14.md)

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

> `v5.4.0-beta.1-redeploy` (Sepolia, 2026-06-16). Always read live addresses from
> [`deployments/config.sepolia.json`](./deployments/config.sepolia.json).

| Contract | Proxy | Implementation |
|----------|-------|----------------|
| Registry | `0x3F920B25f8b65988359C372F66F036E48adFc556` | `0x1770338C0669d3333473a72CF0c164Ccc640Dc34` |
| SuperPaymaster | `0x030025f40d509b1a99547bAEb3795bD27F7182b7` | `0x24a94572cfB6Ca6C8dE107431043556D461d8cFf` |
| X402Facilitator | — | `0x326Fc3413c8A0185b0179B971C69813B6dFD971B` |
| PolicyRegistry | — | `0x8c2488d46d5447418558c38AA6441720df656094` |
| TimelockController | — | `0xB734df3c0A1809bc06708512363D368Ac51dF1A2` |
| ReputationSystem | — | `0x7fEd690E1663755e24a1C9d6164336809d68a578` |
| GToken | — | `0x20a051502a7AE6e40cfFd6EBe59057538E698984` |
| GTokenStaking | — | `0x3B363598746Ea57314d4869B160940948c569D48` |
| MySBT | — | `0x072A0D12f4212B6baD7c6d0A633eaffbDE9105bF` |
| xPNTsFactory | — | `0xCec3655525a112882E74Fb7C26AcB267a07724cb` |
| PaymasterFactory | — | `0x0Aa06EA5295eeD4D48c93c594Db1CBf3626971A5` |
| BLSAggregator | — | `0x15387e161c1b3dAe7c66Fbd5c1F32837B58B2e79` |
| DVTValidator | — | `0x19BA9829C784E4A41b68960b9c0bA55f83718997` |
| MicroPaymentChannel | — | `0x405851A141Cde827E33247d4D4089Af2814c2FF5` |

**EntryPoint v0.7**: `0x0000000071727De22E5E9d8BAf0edAc6f37da032`

**Mainnet**: Pending audit — deployment after Beta stabilization.

---

## Documentation

### Architecture & Design
- [Contract Architecture](./docs/CONTRACT_ARCHITECTURE.md) — Dependency graph, data structures, constructor params
- [UUPS Upgrade Guide](./docs/UUPS-upgrade-doc.md) — Storage layout, upgrade flow, security analysis, knowledge base
- [DVT + BLS Architecture](./docs/DVT_BLS_Architecture.md) — Decentralized validator technology & BLS signature aggregation
- [Oracle Failover Mechanism](./docs/Oracle_Failover_Mechanism.md) — Chainlink degradation & DVT auto-switch
- [Price Cache Technical Reference](./docs/Price_Cache_Technical_Reference.md) — Price cache implementation details
- [Registry Role Mechanism](./contracts/docs/Registry_Role_Mechanism.md) — Role configuration, management, exit fees
- [Admin Configuration Rights](./docs/Admin_Configuration_Rights.md) — Permission matrix for admin operations
- [Credit System Design](./docs/Phase7_Credit_System_Redesign.md) — User credit/debt system architecture
- [Contract Version Map](./docs/VERSION_MAP.md) — On-chain version mapping & governance roadmap

### V5 Design & Roadmap
- [V5 Design Document](./docs/SuperPaymaster-V5-Design.md) — `_consumeCredit()`, x402 settlement, ERC-8004 integration
- [V5 Roadmap](./docs/V5-Roadmap.md) — Evolution from gas sponsorship to Agent Economy
- [V5 Implementation Plan](./docs/V5-Implementation-Plan.md) — 16-week schedule, worktree strategy, milestone tracking
- [V5.1 Plan](./docs/V5.1-Plan.md) — Agent-Native Gas Sponsorship & `chargeMicroPayment()`
- [V5.2 Plan](./docs/V5.2-Plan.md) — x402 Facilitator + MicroPaymentChannel
- [V5.3 Plan](./docs/V5.3-Plan.md) — ERC-8004 Agent Discovery + SKILL.md + CLI
- [V5 Acceptance Report](./docs/V5-Acceptance-Report.md) — Feature verification & test results

### Research
- [x402 Ecosystem Research](./docs/research-x402-ecosystem-2026-03.md) — Coinbase x402, Cloudflare Workers, settlement methods
- [Agent + x402 + Micropayment Research](./docs/research-agent-x402-micropayment.md) — Agent economy & payment channel design
- [Spores Protocol Design](./docs/Spores-protocol-design-2026.md) — Decentralized revenue sharing network

### Developer Guides
- [**Beta Integration Guide (v5.3.3-beta.2)**](./docs/integration/v5.3.3-beta.2-integration-guide.md) — beta entry: ready vs pending (x402), prerequisites, `dryRunValidation` pre-flight
- [Developer Integration Guide](./docs/DEVELOPER_INTEGRATION_GUIDE.md) — Gasless, x402, micropayment scenarios
- [SDK x402 Integration](./docs/integration/sdk-x402-integration.md) — EIP-3009 + direct settle signing (post-C-02)
- [SDK E2E Scenario Guide](./docs/SDK-E2E-Scenario-Guide.md) — 7 complete user scenarios
- [Ecosystem Services Setup](./docs/ECOSYSTEM-SERVICES-SETUP-GUIDE.md) — Operator node, facilitator, keeper
- [Registry v4.1 SDK Migration](./docs/registry-v4.1-sdk-migration.md) — Interface changes, viem examples, error mapping
- [Deployment Guide](./docs/DEPLOYMENT_V3_GUIDE.md) — Secure deployment with Foundry Keystore

### User Guides
- [MySBT User Guide](./docs/MYSBT_USER_GUIDE.md) — Minting and managing SBT tokens
- [Community Registration](./docs/COMMUNITY_REGISTRATION.md) — Registering your community
- [Paymaster Operator Guide](./docs/PAYMASTER_OPERATOR_GUIDE.md) — Operating AOA/AOA+ paymasters

### API References
- [SuperPaymaster API](./docs/API_SUPERPAYMASTER.md) (v5.4.0-beta.1)
- [Registry API](./docs/API_REGISTRY.md) (V4.1.0)
- [MySBT API](./docs/API_MYSBT.md)

### Security & Audits
- [Security Policy](./docs/SECURITY.md) — Vulnerability reporting
- [Security PGP](./docs/SECURITY_PGP.md) — PGP keys & bug bounty
- [Challenger Review](./docs/challenger-review-2026-03-26.md) — Adversarial review report
- [Kimi AI Audit Report](./docs/Kimi_SuperPaymaster_Full_Audit_Report.md) — Full security audit
- [Codeex Audit](./docs/codeex-audit-2026-03-20.md) — Static analysis & doc consistency audit

### Testing
- [Anvil Testing Guide](./docs/Anvil_Testing_Guide.md) — Local Anvil environment setup
- [E2E Test Guide](./docs/E2E-TEST-GUIDE.md) — End-to-end Sepolia test suite
- [Gasless Test Guide](./docs/GASLESS_TEST_GUIDE.md) — Testing gasless transactions

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

This project is licensed under the [Apache License, Version 2.0](LICENSE).  
Copyright 2024-present MushroomDAO Contributors.  
See [NOTICE](./NOTICE) · [TRADEMARK.md](./TRADEMARK.md) · [LICENSE-zh.md](./LICENSE-zh.md) · [TRADEMARK-zh.md](./TRADEMARK-zh.md) for details.

---

<a name="chinese"></a>

# SuperPaymaster — 去中心化支付与 Gas 赞助基础设施

**[English](#english)** | **[中文](#chinese)**

> **v5.4.0-beta.1-redeploy**（God-Split Beta · X402Facilitator + PolicyRegistry + Timelock）— Sepolia 测试网运行中

## SuperPaymaster 是什么？

SuperPaymaster 是 ERC-4337 账户抽象生态的**多模式支付基础设施**。它不仅仅是 Gas 赞助——而是将无 Gas 交易、x402 资源支付、微支付通道和 AI Agent 经济统一到一个链上结算层中。

> **研究论文**: Huifeng Jiao, Nathapon Udomlertsakul. *"SuperPaymaster: Eliminating Centralized Signer Authority via Asset-Oriented Abstraction to Reconcile Usability and Decentralization in Account Abstraction"* — [arXiv:2605.05774](https://arxiv.org/abs/2605.05774)。提出**资产导向抽象 (AOA)**，将 Gas 赞助权限锚定在链上 Gas Card 而非链下签名服务；在 Optimism 主网相比商业基线降低约 49% gas 成本。

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
| **SuperPaymaster** | 5.4.0¹ | UUPS 代理 | AOA+ 共享 Paymaster — Gas 赞助、x402、Agent 策略、信用/债务 |
| **X402Facilitator** | 1.0.0 | 独立合约 | 从 SuperPaymaster 拆分的 x402 结算 — EIP-3009 USDC + xPNTs 直接结算、费用模型 |
| **PolicyRegistry** | 1.0.0 | 独立合约 | 共享的链上、受治理门控的消费策略（checkPolicy / recordSpend） |
| **TimelockController** | OZ v5.0.2 | 治理 | 升级与特权操作的延时执行治理器 |
| **Registry** | 5.4.0 | UUPS 代理 | 社区/节点注册、角色管理、BLS 重放保护、惩罚 |
| **PaymasterV4** | 4.3.0 | EIP-1167 代理 | AOA 独立 Paymaster |
| **GToken** | 2.0.0 | ERC20 | 治理代币（2100 万上限，限量发行） |
| **GTokenStaking** | 3.2.0 | 不可变 | 基于角色的质押 + 燃烧机制，DVT/治理惩罚 |
| **MySBT** | 3.1.3 | ERC721（灵魂绑定） | 身份 + 声誉，社区会员，SBT 门控赞助 |
| **xPNTsFactory** | 2.0.0 | Clones | 部署每社区 xPNTs Gas 代币 |
| **ReputationSystem** | 1.0.0 | — | 基于社区规则的声誉评分 |
| **BLSAggregator** | 1.0.0 | — | BLS12-381 阈值签名聚合 |
| **DVTValidator** | 1.0.0 | — | 分布式验证者共识（7/13 拜占庭法定人数） |

> ¹ v5.4 GA 版本号已**落地**：链上 `version()` 字符串现为 `SuperPaymaster-5.4.0` 与 `Registry-5.4.0`（god-split：结算与策略拆分为独立 `X402Facilitator` / `PolicyRegistry`）。独立合约保留各自的 `1.0.0` 版本号。

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

> `v5.4.0-beta.1-redeploy`（Sepolia，2026-06-16）。请始终从 [`deployments/config.sepolia.json`](./deployments/config.sepolia.json) 读取实时地址。

| 合约 | 代理地址 | 实现地址 |
|------|----------|----------|
| Registry | `0x3F920B25f8b65988359C372F66F036E48adFc556` | `0x1770338C0669d3333473a72CF0c164Ccc640Dc34` |
| SuperPaymaster | `0x030025f40d509b1a99547bAEb3795bD27F7182b7` | `0x24a94572cfB6Ca6C8dE107431043556D461d8cFf` |
| X402Facilitator | — | `0x326Fc3413c8A0185b0179B971C69813B6dFD971B` |
| PolicyRegistry | — | `0x8c2488d46d5447418558c38AA6441720df656094` |
| TimelockController | — | `0xB734df3c0A1809bc06708512363D368Ac51dF1A2` |
| ReputationSystem | — | `0x7fEd690E1663755e24a1C9d6164336809d68a578` |
| GToken | — | `0x20a051502a7AE6e40cfFd6EBe59057538E698984` |
| GTokenStaking | — | `0x3B363598746Ea57314d4869B160940948c569D48` |
| MySBT | — | `0x072A0D12f4212B6baD7c6d0A633eaffbDE9105bF` |
| MicroPaymentChannel | — | `0x405851A141Cde827E33247d4D4089Af2814c2FF5` |

**EntryPoint v0.7**: `0x0000000071727De22E5E9d8BAf0edAc6f37da032`

完整地址见 [`deployments/config.sepolia.json`](./deployments/config.sepolia.json)

---

## 文档

### 架构与设计
- [合约架构](./docs/CONTRACT_ARCHITECTURE.md) — 依赖图、数据结构、构造参数
- [UUPS 升级指南](./docs/UUPS-upgrade-doc.md) — 存储布局、升级流程、安全分析
- [DVT + BLS 架构](./docs/DVT_BLS_Architecture.md) — 去中心化验证者 & BLS 签名聚合
- [预言机降级机制](./docs/Oracle_Failover_Mechanism.md) — Chainlink 降级 & DVT 切换
- [价格缓存技术参考](./docs/Price_Cache_Technical_Reference.md) — 价格缓存实现
- [角色机制](./contracts/docs/Registry_Role_Mechanism.md) — 角色配置、管理、退出费用
- [管理权限矩阵](./docs/Admin_Configuration_Rights.md) — 管理操作权限
- [信用系统设计](./docs/Phase7_Credit_System_Redesign.md) — 用户信用/债务系统
- [合约版本映射](./docs/VERSION_MAP.md) — 链上版本号 & 治理路线图

### V5 设计与路线图
- [V5 设计文档](./docs/SuperPaymaster-V5-Design.md) — `_consumeCredit()`、x402、ERC-8004 集成
- [V5 路线图](./docs/V5-Roadmap.md) — 从 Gas 代付到 Agent Economy 的演进
- [V5 实施计划](./docs/V5-Implementation-Plan.md) — 16 周进度、Worktree 并行策略
- [V5.1 计划](./docs/V5.1-Plan.md) — Agent-Native Gas & `chargeMicroPayment()`
- [V5.2 计划](./docs/V5.2-Plan.md) — x402 Facilitator + MicroPaymentChannel
- [V5.3 计划](./docs/V5.3-Plan.md) — ERC-8004 Agent Discovery + SKILL.md + CLI
- [V5 验收报告](./docs/V5-Acceptance-Report.md) — 功能验证 & 测试结果

### 研究
- [x402 生态研究](./docs/research-x402-ecosystem-2026-03.md) — Coinbase x402、Cloudflare Workers
- [Agent + x402 + 微支付研究](./docs/research-agent-x402-micropayment.md) — Agent 经济 & 支付通道
- [Spores 协议设计](./docs/Spores-protocol-design-2026.md) — 去中心化分润网络

### 开发者指南
- [开发者集成指南](./docs/DEVELOPER_INTEGRATION_GUIDE.md) — 无 Gas、x402、微支付场景
- [SDK E2E 场景指南](./docs/SDK-E2E-Scenario-Guide.md) — 7 个完整用户场景
- [生态服务部署](./docs/ECOSYSTEM-SERVICES-SETUP-GUIDE.md) — Operator 节点、Facilitator、Keeper
- [Registry v4.1 SDK 迁移](./docs/registry-v4.1-sdk-migration.md) — 接口变更、viem 示例
- [部署指南](./docs/DEPLOYMENT_V3_GUIDE.md) — Foundry Keystore 安全部署

### 用户指南
- [MySBT 用户指南](./docs/MYSBT_USER_GUIDE.md) — 铸造和管理 SBT 代币
- [社区注册指南](./docs/COMMUNITY_REGISTRATION.md) — 注册你的社区
- [Paymaster 运营指南](./docs/PAYMASTER_OPERATOR_GUIDE.md) — 运营 AOA/AOA+ Paymaster

### API 参考
- [SuperPaymaster API](./docs/API_SUPERPAYMASTER.md) (v5.4.0-beta.1)
- [Registry API](./docs/API_REGISTRY.md) (V4.1.0)
- [MySBT API](./docs/API_MYSBT.md)

### 安全与审计
- [安全策略](./docs/SECURITY.md) | [安全 PGP](./docs/SECURITY_PGP.md)
- [对抗性审查](./docs/challenger-review-2026-03-26.md) | [Kimi AI 审计](./docs/Kimi_SuperPaymaster_Full_Audit_Report.md)
- [Codeex 审计](./docs/codeex-audit-2026-03-20.md)

### 测试
- [Anvil 测试指南](./docs/Anvil_Testing_Guide.md) — 本地环境
- [E2E 测试指南](./docs/E2E-TEST-GUIDE.md) — Sepolia 端到端测试
- [Gasless 测试指南](./docs/GASLESS_TEST_GUIDE.md) — 无 Gas 交易测试

---

## 安全

- 400+ Foundry 测试通过（含 UUPS 升级、V5 特性、模糊测试）
- Echidna 属性测试
- 内部对抗性审查完成
- 外部审计待主网部署前完成

**报告漏洞**: jason@aastar.io 或 david@aastar.io

---

## 许可证

本项目使用 [Apache 许可证 2.0 版](LICENSE)（英文原版，具有法律效力）。  
中文参考译本见 [LICENSE-zh.md](./LICENSE-zh.md)（非官方，不具法律效力）。  
版权归属见 [NOTICE](./NOTICE)。
