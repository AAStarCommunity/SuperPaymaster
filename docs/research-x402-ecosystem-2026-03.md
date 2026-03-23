# x402 Ecosystem Research Report (2026-03-23)

## Overview

Research into open source frameworks from standard-setting organizations for building our Operator Node (P0) and SKILL.md agent discovery (P1).

## 1. Coinbase — x402 Protocol

**Repo**: [coinbase/x402](https://github.com/coinbase/x402) (5,800+ stars, Apache 2.0)
**Languages**: TypeScript (43%), Python (34%), Go (22%)

### Architecture

Three-entity model: **Client** (payer) → **Resource Server** (payee) → **Facilitator** (verifier/settler)

```
Client → GET /resource → Server returns 402 + PaymentRequirements
Client → Signs payment → GET /resource + X-PAYMENT header
Server → POST /verify to Facilitator → Validates (~100ms)
Server → Returns resource
Server → POST /settle to Facilitator → On-chain (~2s on Base)
```

### TypeScript SDK Packages

```
@x402/core          — Core protocol types & utilities
@x402/evm           — EVM settlement (EIP-3009, Permit2)
@x402/svm           — Solana settlement
@x402/fetch         — Client: fetch wrapper with auto-402 handling
@x402/axios         — Client: axios interceptor
@x402/express       — Server middleware (Express)
@x402/hono          — Server middleware (Hono)
@x402/next          — Server middleware (Next.js)
@x402/paywall       — UI paywall component
@x402/extensions    — V2 plugin system
```

### Settlement Paths (EVM Exact Scheme)

| Priority | Method | Target Tokens | Contract |
|----------|--------|---------------|----------|
| 1 | EIP-3009 `transferWithAuthorization` | USDC, EURC | Token contract |
| 2 | Permit2 + x402ExactPermit2Proxy | Any ERC-20 | `0x402085c2...E20001` |
| 3 | ERC-7710 delegation | Smart accounts | delegationManager |

### Fee Structure

- First 1,000 settlements/month: free
- Additional: $0.001 per settlement
- Gas on Base: ~$0.001 per USDC transfer

### x402 V2 (Dec 2025)

- Multi-chain support (Base, Solana, L2s)
- Plugin architecture for custom chains/facilitators
- Wallet sessions (subscription-style access)
- Backward compatible with V1

### Key Reference: Facilitator Example

```
coinbase/x402/examples/typescript/facilitator/
  ├── verify/route.ts    — POST /verify endpoint
  └── settle/route.ts    — POST /settle endpoint
```

---

## 2. Stripe/Tempo — MPP (Machine Payments Protocol)

**Spec**: [mpp.dev](https://mpp.dev/) | [tempoxyz/mpp-specs](https://github.com/tempoxyz/mpp-specs) (40 stars)
**SDK**: `mppx` (TypeScript), `pympp` (Python), `mpp` (Rust)
**License**: CC0 specs, Apache 2.0/MIT tooling

### Protocol Architecture

Same HTTP 402 foundation as x402, but uses "Payment" HTTP Authentication Scheme:

```
WWW-Authenticate: Payment (challenge)
Authorization: Payment (credential)
Payment-Receipt (receipt)
```

### Two Intent Types

| Intent | Description | Settlement |
|--------|-------------|------------|
| **Charge** | One-time, per-request. Maps directly to x402 exact scheme | On-chain |
| **Session** | Pre-fund escrow → off-chain vouchers → batch settle | Payment channel |

**Session Intent** — directly comparable to our MicroPaymentChannel:
- Client deposits into on-chain escrow
- Signs off-chain vouchers per resource consumed
- Server verifies with fast signature check (no RPC calls)
- Periodic batch settlement

### SDK Pattern (mppx)

```typescript
// Server
import { Mppx, tempo } from 'mppx/server'
const mppx = new Mppx({ methods: [tempo()] })
const handler = mppx.charge({ amount: '1' })

// Client
import { Mppx, tempo } from 'mppx/client'
const mppx = new Mppx({ methods: [tempo()] })
// Global fetch auto-handles 402 responses
```

### Tempo Blockchain (Stripe + Paradigm)

- L1 purpose-built for payments (100,000+ TPS, sub-second finality)
- Testnet stage, expected mainnet 2026
- Bridge (acquired by Stripe for $1.1B): USDB stablecoin infrastructure
- Open Issuance: any business can launch custom stablecoin

### SuperPaymaster Compatibility

Our `MicroPaymentChannel.sol` implements MPP's Session Intent pattern:
- Cumulative EIP-712 vouchers = MPP off-chain vouchers
- `authorizedSigner` = Session Key delegation
- 15-min dispute window = Settlement batching
- `settleChannel()` + `closeChannel()` = Batch settlement

---

## 3. Paradigm — Infrastructure & Standards

### Core Projects

| Project | Stars | Relevance |
|---------|-------|-----------|
| [Foundry](https://github.com/foundry-rs/foundry) | 10,235 | Our dev toolchain |
| [Reth](https://github.com/paradigmxyz/reth) | 5,485 | Node implementation |
| [Alloy](https://github.com/alloy-rs/alloy) | 1,260 | Rust EVM library |
| [Viem](https://github.com/wevm/viem) | 3,423 | Our preferred TS library |
| [Wagmi](https://github.com/wevm/wagmi) | 6,679 | React hooks |

### Permit2 (Uniswap/Paradigm)

**Repo**: [Uniswap/permit2](https://github.com/Uniswap/permit2) (918 stars)

Key architectural patterns:
- **Nonce Bitmap**: Non-sequential nonces for parallel signing (vs. our simple mapping)
- **Witness Mode**: Extra data in signature (receiver address enforcement)
- **Zero passive allowance**: Even if contract is compromised, can't drain
- **Address**: `0x000000000022D473030F116dDEE9F6B43aC78BA3` (all chains)

### UniswapX: Intent Settlement Pattern

```
Swapper signs Order → Filler competes to fill → Reactor settles via Permit2
```

**Key insight**: Filler pays gas, profits from spread. Same as x402 facilitator model.

### ERC-7683: Cross-Chain Intents

```solidity
interface IOriginSettler {
    function openFor(GaslessCrossChainOrder order, bytes signature, bytes originFillerData) external;
}
interface IDestinationSettler {
    function fill(bytes32 orderId, bytes originData, bytes fillerData) external;
}
```

### Across Prime: Bonded Relayer Model

Most relevant to our facilitator design:
- Facilitator stakes bond (like GToken staking)
- Pays gas upfront, recoups from facilitator fee
- Merkle root sync for cross-chain settlement

---

## 4. Cloudflare — Edge Payment Infrastructure

### x402 Foundation (Co-founded with Coinbase)

Neutral governance for x402 protocol standardization.

### Workers x402 Middleware

```typescript
import { paymentMiddleware } from "x402-hono";
app.use(paymentMiddleware("0xWallet", {
  "/premium": { price: "$0.10", network: "base-sepolia" },
}, { url: "https://x402.org/facilitator" }));
```

### MCP paidTool (Workers Agents SDK)

```typescript
// Agent pays per-tool-call
this.server.paidTool("square", "Squares a number", 0.01, ...);
```

### Deferred Payment Scheme (Cloudflare Innovation)

- Decouples cryptographic handshake from settlement
- HTTP Message Signatures with JWK public keys
- Batch/subscription settlement (daily/weekly/monthly)
- Designed for millions TPS (pay-per-crawl)

**Insight**: Maps directly to our `chargeMicroPayment()` approach — verify signature immediately, settle aPNTs deduction in batch.

### Agents SDK

**Repo**: [cloudflare/agents](https://github.com/cloudflare/agents) (4,603 stars)

Client-side payment with viem:
```typescript
import { withX402Client } from "agents/x402";
import { privateKeyToAccount } from "viem/accounts";
this.x402Client = withX402Client(mcpClient, { network: "base-sepolia", account });
```

---

## 5. Ecosystem Projects

### Decentralized Facilitators

| Project | Approach | Status |
|---------|----------|--------|
| [ChaosChain/chaoschain-x402](https://github.com/ChaosChain/chaoschain-x402) | BFT via Chainlink CRE DON + ERC-8004 | Beta |
| [second-state/x402-facilitator](https://github.com/second-state/x402-facilitator) | WasmEdge/LlamaEdge + x402 | Active |

### Google AP2 + x402

[google-agentic-commerce/a2a-x402](https://github.com/google-agentic-commerce/a2a-x402)
- x402 = only stablecoin facilitator for AP2
- 60+ partners (Mastercard, PayPal, Adyen)
- Verifiable Digital Credentials (VDCs)

### ERC-8004 Implementations

| Repo | Description |
|------|-------------|
| [erc-8004/erc-8004-contracts](https://github.com/erc-8004/erc-8004-contracts) | Official contracts |
| Identity Registry Sepolia | `0x8004A818BFB912233c491871b3d84c89A494BD9e` |
| Reputation Registry Sepolia | `0x8004B663056A597Dffe9eCcC1965A193B7388713` |

### Agent Skills (Anthropic)

**Repo**: [anthropics/skills](https://github.com/anthropics/skills) (101k stars)
**Spec**: [agentskills.io/specification](https://agentskills.io/specification)

Progressive disclosure: metadata (~100 tokens) → instructions (<5000 tokens) → resources (on-demand)

---

## 6. Design Implications for SuperPaymaster

### P0: Operator Node Architecture

Based on x402 + MPP + Cloudflare patterns:

```
packages/x402-facilitator-node/
├── src/
│   ├── server.ts           # Hono HTTP (x402 compatible)
│   ├── verify.ts           # /verify — EIP-3009/Permit2 sig check
│   ├── settle.ts           # /settle — call settleX402Payment on-chain
│   ├── quote.ts            # /quote — operator fee rate
│   ├── health.ts           # /health — operator status
│   ├── well-known.ts       # /.well-known/x-payment-info
│   ├── methods/            # Plugin architecture (x402 V2 compatible)
│   │   ├── eip3009.ts      # USDC native settlement
│   │   ├── direct.ts       # xPNTs direct settlement
│   │   └── channel.ts      # MicroPaymentChannel session
│   ├── transport.ts        # HTTP 402 + MCP -32042
│   └── config.ts           # Environment config
├── Dockerfile
└── package.json
```

### P1: SKILL.md + Agent Discovery

```yaml
---
name: superpaymaster
description: >
  Gasless transactions and micropayments for Web3 agents.
  ERC-4337 gas sponsorship, x402 payment facilitation,
  streaming micropayments via payment channels.
install: pnpm add -g @superpaymaster/cli
---
```

### Key Differentiators vs Competitors

| Capability | Coinbase x402 | Stripe MPP | ChaosChain | **SuperPaymaster** |
|------------|---------------|------------|------------|---------------------|
| EIP-3009 USDC | ✅ | ❌ (Tempo) | ✅ | ✅ |
| Payment Channel | ❌ | ✅ (Session) | ❌ | ✅ MicroPaymentChannel |
| Gas Sponsorship | ❌ | ❌ | ❌ | ✅ ERC-4337 |
| Community Tokens | ❌ | ❌ | ❌ | ✅ xPNTs |
| Agent Sponsorship | ❌ | ❌ | ❌ | ✅ AgentSponsorshipPolicy |
| BFT Verification | ❌ | ❌ | ✅ CRE | ✅ DVT/BLS |
| ERC-8004 Identity | ❌ | ❌ | ✅ | ✅ dual-channel |
| Deferred Settlement | ❌ | ✅ | ❌ | ✅ chargeMicroPayment |
