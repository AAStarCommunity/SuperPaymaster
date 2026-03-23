---
name: superpaymaster
version: 0.1.0
description: >
  Gasless transactions and micropayments for Web3 agents.
  ERC-4337 gas sponsorship, x402 payment facilitation,
  streaming micropayments via payment channels.
author: SuperPaymaster Team
license: MIT
install: pnpm add @superpaymaster/sdk
repository: https://github.com/AAStarCommunity/SuperPaymaster
tags:
  - web3
  - payments
  - gas-sponsorship
  - x402
  - erc-4337
  - micropayments
  - agent-economy
capabilities:
  - gas-sponsorship
  - x402-settlement
  - micropayment-channels
  - agent-identity
  - community-tokens
networks:
  - ethereum-sepolia
  - base
  - base-sepolia
  - optimism
---

# SuperPaymaster

Decentralized gas payment infrastructure for Web3 agents and dApps. Provides gas sponsorship via community tokens (xPNTs), x402 payment facilitation, and streaming micropayment channels.

## Quick Start

```bash
pnpm add @superpaymaster/sdk
```

```typescript
import { createSuperPaymasterClient } from "@superpaymaster/sdk";

const client = createSuperPaymasterClient({
  network: "base-sepolia",
  operatorUrl: "https://your-operator.example.com",
});
```

## Capabilities

### 1. Gas Sponsorship (ERC-4337)
Sponsor gas fees for users via community tokens instead of ETH.

```typescript
// Check if a user is eligible for gas sponsorship
const eligible = await client.isEligibleForSponsorship(userAddress);

// Get paymaster data for a UserOperation
const paymasterData = await client.getPaymasterData(userOp, {
  community: "your-community",
});
```

### 2. x402 Payment Settlement
HTTP 402-based payments for API access and agent services.

```typescript
// Settle a USDC payment via EIP-3009
const result = await client.settleX402Payment({
  from: payerAddress,
  to: payeeAddress,
  asset: "USDC",
  amount: "1000000", // 1 USDC
  signature: payerSignature,
});
```

### 3. Micropayment Channels
Streaming payments with off-chain vouchers and on-chain settlement.

```typescript
// Open a payment channel
const channel = await client.openChannel({
  recipient: serviceAddress,
  token: "USDC",
  totalDeposit: "10000000", // 10 USDC
  duration: 3600, // 1 hour
});

// Sign a micropayment voucher (off-chain, instant)
const voucher = await client.signVoucher(channel.id, "100000"); // 0.1 USDC
```

### 4. Agent Identity (ERC-8004)
Register and verify agent identity for reputation-based sponsorship.

```typescript
// Check agent registration
const isAgent = await client.isRegisteredAgent(agentAddress);

// Get sponsorship rate for an agent
const rate = await client.getAgentSponsorshipRate(agentAddress, operatorAddress);
```

## Resources

### Contract Addresses (Sepolia)
- SuperPaymaster: `0x829C3178DeF488C2dB65207B4225e18824696860`
- MicroPaymentChannel: `0x5753e9675f68221cA901e495C1696e33F552ea36`
- aPNTs Token: `0xEA4b9d046285DC21484174C36BbFb58015Ad5E1f`

### API Endpoints
- `GET /health` — Operator status
- `POST /verify` — Verify payment signature (~100ms)
- `POST /settle` — Execute on-chain settlement
- `GET /quote` — Fee rate and supported assets
- `GET /.well-known/x-payment-info` — x402 discovery

### Documentation
- [V5 Design Document](./docs/SuperPaymaster-V5-Design.md)
- [V5 Roadmap](./docs/V5-Roadmap.md)
- [x402 Ecosystem Research](./docs/research-x402-ecosystem-2026-03.md)
