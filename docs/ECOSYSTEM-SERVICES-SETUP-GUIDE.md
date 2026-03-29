# SuperPaymaster V5.3 Ecosystem Services Setup Guide

This guide covers spinning up the full SuperPaymaster operator stack from scratch:
1. **x402-facilitator-node** — HTTP server that verifies and settles x402 payments
2. **Price Keeper** — daemon that keeps the on-chain price cache fresh
3. **MCP Server** — Model Context Protocol server for AI agent integration

---

## Prerequisites

| Requirement | Version |
|-------------|---------|
| Node.js | ≥ 18 |
| pnpm | ≥ 8 |
| Sepolia RPC | Alchemy / Infura / QuickNode |
| Operator EOA | Funded with ETH (gas) + aPNTs (deposit) |
| Deployed contracts | SuperPaymaster V5.3.0 proxy |

Deployed Sepolia addresses (from `deployments/config.sepolia.json`):

| Contract | Address |
|----------|---------|
| SuperPaymaster proxy | `0x829C3178DeF488C2dB65207B4225e18824696860` |
| MicroPaymentChannel | `0x5753e9675f68221cA901e495C1696e33F552ea36` |
| Registry proxy | `0xD88CF5316c64f753d024fcd665E69789b33A5EB6` |
| aPNTs | `0xEA4b9d046285DC21484174C36BbFb58015Ad5E1f` |
| USDC (Sepolia) | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` |

---

## Part 1: x402-facilitator-node

The facilitator node is a Hono HTTP server that operators run to handle x402 payment requests. It exposes `/verify`, `/settle`, `/quote`, and `/.well-known/x-payment-info`.

### 1.1 Install and Build

```bash
cd packages/x402-facilitator-node
pnpm install
pnpm build          # compiles TypeScript → dist/
```

### 1.2 Configure Environment

Create `.env` from the template:

```bash
cat > .env << 'EOF'
# ── Required ──────────────────────────────────────────────────
# Ethereum RPC (must support eth_getLogs, eth_call)
RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY

# Operator EOA — must have ROLE_PAYMASTER_SUPER in Registry
# This wallet calls settleX402Payment on-chain; fund with ETH for gas
OPERATOR_PRIVATE_KEY=0xYOUR_OPERATOR_PRIVATE_KEY

# SuperPaymaster proxy address (V5.3.0 on Sepolia)
SUPER_PAYMASTER_ADDRESS=0x829C3178DeF488C2dB65207B4225e18824696860

# ── Optional ──────────────────────────────────────────────────
# Defaults: 3402 (port), 11155111 (Sepolia), http://localhost:3402
PORT=3402
CHAIN_ID=11155111
NETWORK=sepolia
BASE_URL=https://your-facilitator.example.com

# USDC address (auto-detected from CHAIN_ID if omitted)
# USDC_ADDRESS=0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238

# Optional: HMAC challenge for bot protection
# ENABLE_HMAC_CHALLENGE=true
# HMAC_SECRET=your-random-secret-here
EOF
```

**Security note**: `OPERATOR_PRIVATE_KEY` only needs ETH for gas. The USDC being settled flows from the payer to the payee — the operator never holds the payment asset.

### 1.3 Register Operator On-Chain

Before the facilitator can call `settleX402Payment`, the operator must have `ROLE_PAYMASTER_SUPER`:

```bash
# One-time setup: register as PAYMASTER_SUPER (requires GTOKEN stake)
# See docs/OPERATOR_REGISTRATION_GUIDE.md for the full staking flow

# Verify registration:
cast call $REGISTRY "hasRole(bytes32,address)(bool)" \
  $(cast keccak 'PAYMASTER_SUPER') \
  $OPERATOR_ADDRESS \
  --rpc-url $RPC_URL
```

### 1.4 Run the Server

```bash
# Development (hot reload)
pnpm dev

# Production
pnpm start
```

Expected startup output:
```
x402 Facilitator Node starting on port 3402
  Network: sepolia (chainId: 11155111)
  SuperPaymaster: 0x829C3178DeF488C2dB65207B4225e18824696860
  Listening on http://localhost:3402
```

### 1.5 Verify Endpoints

```bash
# Health
curl http://localhost:3402/health

# x402 payment capabilities
curl http://localhost:3402/.well-known/x-payment-info | jq .

# Quote current fees
curl http://localhost:3402/quote | jq .
```

Expected `.well-known` response:
```json
{
  "schemes": ["eip3009", "direct"],
  "assets": [
    { "address": "0x1c7D4B196...", "symbol": "USDC", "decimals": 6 }
  ],
  "facilitatorAddress": "0xYOUR_OPERATOR",
  "feeBPS": 200
}
```

### 1.6 Docker Deployment

```dockerfile
# Dockerfile (place in packages/x402-facilitator-node/)
FROM node:20-alpine
RUN corepack enable && corepack prepare pnpm@latest --activate
WORKDIR /app
COPY package.json pnpm-lock.yaml ./
RUN pnpm install --frozen-lockfile --prod
COPY dist/ ./dist/
EXPOSE 3402
CMD ["node", "dist/index.js"]
```

Build and run:

```bash
# Build image
docker build -t superpaymaster-facilitator:latest \
  -f packages/x402-facilitator-node/Dockerfile \
  packages/x402-facilitator-node/

# Run with env file
docker run -d \
  --name facilitator \
  --env-file packages/x402-facilitator-node/.env \
  -p 3402:3402 \
  superpaymaster-facilitator:latest

# Check logs
docker logs -f facilitator
```

### 1.7 HMAC Bot Protection (Optional)

Enable to require clients to prove they hold the challenge secret before settlement:

```bash
# In .env:
ENABLE_HMAC_CHALLENGE=true
HMAC_SECRET=$(openssl rand -hex 32)
```

When enabled:
- `POST /verify` response includes `X-Challenge: <hex-nonce>`
- Client must include `X-HMAC: HMAC-SHA256(secret, challenge+payment_data)` in `POST /settle`
- Server uses `crypto.subtle.verify()` (constant-time) to validate

---

## Part 2: Price Keeper

The Price Keeper is a daemon that periodically calls `updatePrice()` on SuperPaymaster (and PaymasterV4 instances) to keep the cached ETH/USD price fresh. Stale price (> 1 hour) causes validation to fall back to real-time oracle reads, which is gas-inefficient.

### 2.1 Location

The Price Keeper lives in the `aastar-sdk` repo (sibling directory):

```
../aastar-sdk/packages/keeper/
```

### 2.2 Install

```bash
cd ../aastar-sdk
pnpm install
pnpm -r build --filter @aastar/keeper
```

### 2.3 Configure

```bash
cat > ../aastar-sdk/.env.keeper << 'EOF'
# RPC endpoint
RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY

# Keeper EOA private key (only needs ETH for gas, no special role required)
PRIVATE_KEY=0xYOUR_KEEPER_PRIVATE_KEY

# Contracts to keep fresh (comma-separated)
PAYMASTER_ADDRESSES=0x829C3178DeF488C2dB65207B4225e18824696860

# Update interval in seconds (default: 1800 = 30 min; staleness threshold = 3600)
UPDATE_INTERVAL=1800

# Optional: PaymasterV4 instances to also refresh
# PAYMASTERV4_ADDRESSES=0xABC...,0xDEF...
EOF
```

### 2.4 Run

```bash
cd ../aastar-sdk
source .env.keeper

# Run once (manual refresh)
pnpm keeper run --once

# Run as daemon (continuous loop)
pnpm keeper run keep
```

Expected output:
```
[Keeper] Starting price keeper daemon
[Keeper] Interval: 1800s
[Keeper] Updating SuperPaymaster 0x829C3178... → tx: 0xabc123...
[Keeper] Price updated: $3,127.45 (ETH/USD)
[Keeper] Next update in 1800s
```

### 2.5 Systemd Service (Linux Production)

```ini
# /etc/systemd/system/sp-keeper.service
[Unit]
Description=SuperPaymaster Price Keeper
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/aastar-sdk
EnvironmentFile=/opt/aastar-sdk/.env.keeper
ExecStart=/usr/bin/node packages/keeper/dist/cli.js run keep
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable sp-keeper
sudo systemctl start sp-keeper
sudo journalctl -u sp-keeper -f
```

### 2.6 Verify Price Freshness

```bash
# Check current cached price on-chain
cast call $SUPER_PAYMASTER \
  "cachedPrice()(int256,uint256,uint80,uint8)" \
  --rpc-url $RPC_URL

# Output: price (8 decimals), updatedAt (unix timestamp), roundId, decimals
# If (block.timestamp - updatedAt) > 3600 → price is stale
```

---

## Part 3: MCP Server (AI Agent Integration)

The MCP (Model Context Protocol) server exposes SuperPaymaster contract reads as tools for AI agents (Claude, GPT, etc.), enabling agents to query gas sponsorship eligibility, check credit limits, and trigger x402 payments without writing raw RPC calls.

### 3.1 Location

```
packages/mcp-server/          # (if exists in this repo)
# OR
../aastar-sdk/packages/mcp/   # in aastar-sdk
```

### 3.2 Install and Build

```bash
cd packages/mcp-server   # or aastar-sdk/packages/mcp
pnpm install
pnpm build
```

### 3.3 Configure

```bash
cat > .env << 'EOF'
# RPC (read-only, no signing required for read tools)
RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
CHAIN_ID=11155111

# Contract addresses (loaded from config if omitted)
SUPER_PAYMASTER_ADDRESS=0x829C3178DeF488C2dB65207B4225e18824696860
REGISTRY_ADDRESS=0xD88CF5316c64f753d024fcd665E69789b33A5EB6
MICRO_PAYMENT_CHANNEL=0x5753e9675f68221cA901e495C1696e33F552ea36

# Optional: facilitator node URL for x402 payment flows
FACILITATOR_URL=http://localhost:3402

# MCP server transport (stdio or sse)
MCP_TRANSPORT=stdio
EOF
```

### 3.4 Run

```bash
# stdio transport (for Claude Desktop / local agent)
node dist/index.js

# SSE transport (for remote agent access)
MCP_TRANSPORT=sse PORT=3403 node dist/index.js
```

### 3.5 Register with Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "superpaymaster": {
      "command": "node",
      "args": ["/path/to/packages/mcp-server/dist/index.js"],
      "env": {
        "RPC_URL": "https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY",
        "CHAIN_ID": "11155111",
        "SUPER_PAYMASTER_ADDRESS": "0x829C3178DeF488C2dB65207B4225e18824696860"
      }
    }
  }
}
```

### 3.6 Available MCP Tools

| Tool | Description |
|------|-------------|
| `sp_isEligible(user)` | Check if user is eligible for gas sponsorship |
| `sp_getCreditLimit(user)` | Get user's credit limit by reputation tier |
| `sp_getOperator(operator)` | Read operator config (balance, token, rate) |
| `sp_getReputation(user)` | Read global reputation score from Registry |
| `sp_quoteX402(url)` | Get x402 payment quote from facilitator |
| `sp_openChannel(payee, token, deposit)` | Open a MicroPaymentChannel |
| `sp_getChannel(channelId)` | Read channel state |

---

## Part 4: Full Stack Startup Checklist

Run through these in order when setting up a fresh operator node:

```bash
# ─── Pre-flight ───────────────────────────────────────────────
# 1. Fund operator EOA with ETH (≥ 0.05 ETH for gas)
# 2. Fund operator with aPNTs (≥ 1000 for deposit)
# 3. Register as PAYMASTER_SUPER via Registry (see OPERATOR_REGISTRATION_GUIDE.md)

# ─── Deposit to SuperPaymaster ────────────────────────────────
cast send $APNTS_ADDRESS \
  "approve(address,uint256)" $SUPER_PAYMASTER_ADDRESS $(cast to-wei 500) \
  --private-key $OPERATOR_PRIVATE_KEY --rpc-url $RPC_URL

cast send $SUPER_PAYMASTER_ADDRESS \
  "deposit(uint256)" $(cast to-wei 500) \
  --private-key $OPERATOR_PRIVATE_KEY --rpc-url $RPC_URL

# ─── Configure operator (set xPNTs token + exchange rate) ─────
cast send $SUPER_PAYMASTER_ADDRESS \
  "configureOperator(address,address,uint256)" \
  $XPNTS_ADDRESS $TREASURY_ADDRESS $(cast to-wei 1) \
  --private-key $OPERATOR_PRIVATE_KEY --rpc-url $RPC_URL

# ─── Set facilitator fee (x402 operations) ────────────────────
# 200 BPS = 2% fee (onlyOwner on SuperPaymaster)
cast send $SUPER_PAYMASTER_ADDRESS \
  "setFacilitatorFeeBPS(uint256)" 200 \
  --private-key $OWNER_PRIVATE_KEY --rpc-url $RPC_URL

# ─── Start Price Keeper ───────────────────────────────────────
cd ../aastar-sdk && pnpm keeper run keep &

# ─── Start Facilitator Node ───────────────────────────────────
cd /path/to/SuperPaymaster/packages/x402-facilitator-node
pnpm start &

# ─── Verify everything ────────────────────────────────────────
# Run E2E checks
cd /path/to/SuperPaymaster/script/gasless-tests
node check-contracts.js
node check-balances.js
node test-group-G1-reputation-gated-sponsorship.js
node test-group-G2-agent-identity-sponsorship.js
node test-group-G3-credit-tier-escalation.js
```

### Quick Health Check Script

```bash
#!/bin/bash
# ecosystem-health.sh — checks all 3 services

echo "=== SuperPaymaster Ecosystem Health ==="

# 1. Price freshness
CACHED=$(cast call $SUPER_PAYMASTER "cachedPrice()(int256,uint256,uint80,uint8)" --rpc-url $RPC_URL)
UPDATED_AT=$(echo "$CACHED" | awk 'NR==2')
NOW=$(date +%s)
AGE=$((NOW - UPDATED_AT))
if [ $AGE -gt 3600 ]; then
  echo "❌ Price STALE: ${AGE}s old (threshold: 3600s)"
else
  echo "✅ Price fresh: ${AGE}s old"
fi

# 2. Facilitator node
if curl -sf http://localhost:3402/health > /dev/null; then
  echo "✅ Facilitator node: UP"
else
  echo "❌ Facilitator node: DOWN (http://localhost:3402)"
fi

# 3. Operator deposit
BALANCE=$(cast call $SUPER_PAYMASTER "operators(address)(uint128,uint96,bool,bool,address,uint32,uint48,address,uint256,uint256)" \
  $OPERATOR_ADDRESS --rpc-url $RPC_URL | head -1)
echo "   Operator aPNTs balance: $(cast from-wei $BALANCE)"
```

---

## Troubleshooting

### "Price stale" errors during UserOp validation

The cached ETH/USD price is older than `priceUpdateThreshold` (default 1 hour). The postOp still works (falls back to real-time oracle) but validation may reject.

**Fix**: Ensure the Price Keeper is running and the keeper EOA has enough ETH for gas.

```bash
# Manual refresh
cast send $SUPER_PAYMASTER "updatePrice()" \
  --private-key $KEEPER_PRIVATE_KEY --rpc-url $RPC_URL
```

### "OnlyRegistry" revert in GTokenStaking

The `lockStake` or `topUpStake` caller is not the Registry proxy address.

**Fix**: Ensure `GTokenStaking.REGISTRY` matches the current Registry proxy (`0xD88CF5316...`). GTokenStaking has an immutable REGISTRY set at deployment.

### Facilitator returns 403 on `/settle`

The operator EOA lacks `ROLE_PAYMASTER_SUPER` in the Registry.

**Fix**: Register via Registry (requires GToken stake). See `OPERATOR_REGISTRATION_GUIDE.md`.

### "TotalStakeExceedsCap" on stake

Total staked GToken has hit 21M cap (equals total GToken supply).

**Fix**: Wait for other operators to unstake, or reduce stake amount.

### MCP server tools return stale data

The MCP server caches RPC results for performance. Restart the MCP server or reduce cache TTL.
