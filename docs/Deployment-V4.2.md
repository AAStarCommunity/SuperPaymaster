# PaymasterV4.2 Deployment Guide

**Version**: v4.2
**Date**: 2025-10-26
**Breaking Changes**: Yes (from v4.1)

---

## Overview

This guide covers deploying PaymasterV4_1 v4.2 with Chainlink price feed integration and GasTokenV2 with price management.

### What's New in v4.2

- ✅ **Chainlink Integration**: Real-time ETH/USD prices
- ✅ **Token Price Management**: Each GasToken manages its own price
- ✅ **Immutable Registry**: Set once in constructor
- ✅ **Base/Derived Tokens**: Multi-tier token pricing support

---

## Prerequisites

### Required Tools

- [Foundry](https://book.getfoundry.sh/getting-started/installation) (forge, cast, anvil)
- Node.js v18+ (for frontend)
- MetaMask or compatible wallet
- RPC endpoint for target network
- Etherscan API key (for verification)

### Required Addresses

1. **EntryPoint v0.7**: Get from [ERC-4337 docs](https://docs.stackup.sh/docs/entity-addresses)
2. **Registry**: Deploy SuperPaymasterRegistry first
3. **Treasury**: Your fee collection address
4. **Chainlink ETH/USD Feed**: Auto-detected or manual

---

## Part 1: Deploy PaymasterV4_1

### Step 1: Setup Environment

Create `.env` file in `contracts/` directory:

```bash
# Network RPC
SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/YOUR_KEY
ETHEREUM_RPC_URL=https://mainnet.infura.io/v3/YOUR_KEY

# Deployment Accounts
DEPLOYER_PRIVATE_KEY=0x...
OWNER_ADDRESS=0x...  # Paymaster owner
TREASURY_ADDRESS=0x...  # Fee recipient

# EntryPoint v0.7
ENTRY_POINT=0x0000000071727De22E5E9d8BAf0edAc6f37da032

# Parameters
SERVICE_FEE_RATE=200  # 2% (in basis points)
MAX_GAS_COST_CAP=1000000000000000000  # 1 ETH (wei)
MIN_TOKEN_BALANCE=1000000000000000000000  # 1000 tokens (wei)

# Registry (REQUIRED - Immutable!)
REGISTRY_ADDRESS=0x...  # SuperPaymasterRegistry address

# Chainlink (Optional - auto-detected if not set)
# CHAINLINK_ETH_USD_FEED=0x...

# Optional Initial Resources
SBT_ADDRESS=0x...  # Optional SBT contract
GAS_TOKEN_ADDRESS=0x...  # Optional initial GasToken

# Verification
ETHERSCAN_API_KEY=...
NETWORK=sepolia  # For deployment filename
```

### Step 2: Deploy Paymaster

#### Using Forge Script

```bash
# Load environment
source .env

# Deploy to Sepolia (with verification)
forge script contracts/script/DeployPaymasterV4_1_V2.s.sol:DeployPaymasterV4_1_V2 \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv

# Deploy to Mainnet
forge script contracts/script/DeployPaymasterV4_1_V2.s.sol:DeployPaymasterV4_1_V2 \
  --rpc-url $ETHEREUM_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

**Expected Output**:
```
=== PaymasterV4_1 v4.2 Deployment ===
Network: Sepolia
Chain ID: 11155111

Core Addresses:
  EntryPoint: 0x0000000071727De22E5E9d8BAf0edAc6f37da032
  Owner: 0x...
  Treasury: 0x...

Pricing (NEW):
  Chainlink ETH/USD Feed: 0x694AA1769357215DE4FAC081bf1f309aDC325306
  (Token prices managed by GasToken contracts)

Parameters:
  ServiceFeeRate: 200 bps
  MaxGasCostCap: 1000000000000000000 wei
  MinTokenBalance: 1000000000000000000000 wei

Registry (Immutable):
  Registry: 0x...

=== Deployment Successful ===
PaymasterV4_1: 0x...
Version: PaymasterV4.1-Registry-v1.1.0
Registry (immutable): 0x...
Chainlink Feed: 0x694AA1769357215DE4FAC081bf1f309aDC325306

Deployment info saved to: contracts/deployments/paymaster-v4_1-v2-sepolia.json
```

### Step 3: Fund Paymaster

```bash
# Get deployed address
PAYMASTER=0x...  # From deployment output

# Add deposit (required by EntryPoint)
cast send $PAYMASTER "addDeposit()" \
  --value 1ether \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY

# Add stake (if required by EntryPoint)
cast send $PAYMASTER "addStake(uint32)" 86400 \
  --value 0.1ether \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY

# Verify deposit
cast call $PAYMASTER "getDeposit()" \
  --rpc-url $SEPOLIA_RPC_URL
```

---

## Part 2: Deploy GasTokens

### Option A: Base Token (e.g., aPNT)

#### Setup .env

```bash
TOKEN_NAME="Alpha Points"
TOKEN_SYMBOL="aPNT"
PAYMASTER_ADDRESS=0x...  # From Part 1
BASE_PRICE_TOKEN=0x0000000000000000000000000000000000000000  # address(0) for base
EXCHANGE_RATE=1000000000000000000  # 1e18 (1:1 ratio)
PRICE_USD=20000000000000000  # 0.02e18 ($0.02)
```

#### Deploy

```bash
forge script contracts/script/DeployGasTokenV2.s.sol:DeployGasTokenV2 \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

**Output**:
```
Deploying GasTokenV2: aPNT
  Paymaster: 0x...
  Exchange Rate: 1000000000000000000
GasTokenV2 deployed: 0x...
Effective Price: 20000000000000000  ($0.02)
```

### Option B: Derived Token (e.g., xPNT - 4× value)

#### Setup .env

```bash
TOKEN_NAME="X Points"
TOKEN_SYMBOL="xPNT"
PAYMASTER_ADDRESS=0x...
BASE_PRICE_TOKEN=0x...  # aPNT address from Option A
EXCHANGE_RATE=4000000000000000000  # 4e18 (1:4 ratio, 1 xPNT = 4 aPNT)
PRICE_USD=0  # Ignored for derived tokens
```

#### Deploy

```bash
forge script contracts/script/DeployGasTokenV2.s.sol:DeployGasTokenV2 \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  -vvvv
```

**Output**:
```
Deploying GasTokenV2: xPNT
  Paymaster: 0x...
  Exchange Rate: 4000000000000000000
  Base Price Token: 0x...  (aPNT)
GasTokenV2 deployed: 0x...
Effective Price: 80000000000000000  ($0.08 = $0.02 × 4)
```

### Step 4: Register Tokens to Paymaster

```bash
APNT=0x...  # aPNT address
XPNT=0x...  # xPNT address

# Add aPNT
cast send $PAYMASTER "addGasToken(address)" $APNT \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY

# Add xPNT
cast send $PAYMASTER "addGasToken(address)" $XPNT \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY

# Verify
cast call $PAYMASTER "getSupportedGasTokens()" \
  --rpc-url $SEPOLIA_RPC_URL
```

---

## Part 3: Register to SuperPaymasterRegistry

```bash
REGISTRY=0x...  # From .env
FEE_RATE=200  # 2% in basis points
COMMUNITY_NAME="My Awesome Paymaster"

cast send $REGISTRY \
  "registerPaymaster(address,uint256,string)" \
  $PAYMASTER \
  $FEE_RATE \
  "$COMMUNITY_NAME" \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY

# Verify registration
cast call $REGISTRY "isPaymasterActive(address)" $PAYMASTER \
  --rpc-url $SEPOLIA_RPC_URL
```

---

## Part 4: Mint Tokens to Users

```bash
USER_ADDRESS=0x...
AMOUNT=1000000000000000000000  # 1000 tokens (18 decimals)

# Mint aPNT
cast send $APNT "mint(address,uint256)" $USER_ADDRESS $AMOUNT \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY

# Verify balance
cast call $APNT "balanceOf(address)" $USER_ADDRESS \
  --rpc-url $SEPOLIA_RPC_URL

# Verify auto-approval to paymaster
cast call $APNT "allowance(address,address)" $USER_ADDRESS $PAYMASTER \
  --rpc-url $SEPOLIA_RPC_URL
# Should return: 115792089237316195423570985008687907853269984665640564039457584007913129639935 (max uint256)
```

---

## Verification & Testing

### 1. Verify Chainlink Integration

```bash
# Get current ETH price
cast call $PAYMASTER "ethUsdPriceFeed()" \
  --rpc-url $SEPOLIA_RPC_URL
# Returns: 0x694AA1769357215DE4FAC081bf1f309aDC325306

# Query Chainlink directly
FEED=0x694AA1769357215DE4FAC081bf1f309aDC325306
cast call $FEED "latestRoundData()" \
  --rpc-url $SEPOLIA_RPC_URL
# Returns: (roundId, price, startedAt, updatedAt, answeredInRound)
# Example: price = 450000000000 (8 decimals) = $4,500
```

### 2. Verify Token Prices

```bash
# Get aPNT price
cast call $APNT "getPrice()" --rpc-url $SEPOLIA_RPC_URL
# Returns: 20000000000000000 ($0.02)

cast call $APNT "getEffectivePrice()" --rpc-url $SEPOLIA_RPC_URL
# Returns: 20000000000000000 ($0.02)

# Get xPNT price
cast call $XPNT "getEffectivePrice()" --rpc-url $SEPOLIA_RPC_URL
# Returns: 80000000000000000 ($0.08 = $0.02 × 4)
```

### 3. Estimate Gas Cost

```bash
# Estimate cost for 0.001 ETH gas (in aPNT)
GAS_WEI=1000000000000000  # 0.001 ETH

cast call $PAYMASTER "estimatePNTCost(uint256,address)" \
  $GAS_WEI \
  $APNT \
  --rpc-url $SEPOLIA_RPC_URL
# Example: 225000000000000000000 (225 aPNT if ETH=$4500)

# Estimate cost in xPNT
cast call $PAYMASTER "estimatePNTCost(uint256,address)" \
  $GAS_WEI \
  $XPNT \
  --rpc-url $SEPOLIA_RPC_URL
# Example: 56250000000000000000 (56.25 xPNT)
```

### 4. Test UserOperation

See [ERC-4337 Testing Guide](https://docs.stackup.sh/docs/guides/testing-locally) for full UserOp testing.

---

## Price Management

### Update Base Token Price

```bash
# Update aPNT price to $0.03
NEW_PRICE=30000000000000000  # 0.03e18

cast send $APNT "setPrice(uint256)" $NEW_PRICE \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY

# xPNT effective price updates automatically
cast call $XPNT "getEffectivePrice()" --rpc-url $SEPOLIA_RPC_URL
# Returns: 120000000000000000 ($0.12 = $0.03 × 4)
```

### Update Exchange Rate

```bash
# Update xPNT exchange rate to 1:5
NEW_RATE=5000000000000000000  # 5e18

cast send $XPNT "setExchangeRate(uint256)" $NEW_RATE \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY

cast call $XPNT "getEffectivePrice()" --rpc-url $SEPOLIA_RPC_URL
# Returns: 100000000000000000 ($0.10 = $0.02 × 5)
```

---

## Chainlink Feed Addresses

### Mainnet

| Network | Chain ID | ETH/USD Feed |
|---------|----------|--------------|
| Ethereum | 1 | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` |
| Polygon | 137 | `0xAB594600376Ec9fD91F8e885dADF0CE036862dE0` |
| Arbitrum | 42161 | `0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612` |
| Optimism | 10 | `0x13e3Ee699D1909E989722E753853AE30b17e08c5` |
| Base | 8453 | `0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70` |
| BSC | 56 | `0x9ef1B8c0E4F7dc8bF5719Ea496883DC6401d5b2e` |

### Testnet

| Network | Chain ID | ETH/USD Feed |
|---------|----------|--------------|
| Sepolia | 11155111 | `0x694AA1769357215DE4FAC081bf1f309aDC325306` |
| Amoy | 80002 | `0xF0d50568e3A7e8259E16663972b11910F89BD8e7` |
| Arbitrum Sepolia | 421614 | `0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165` |
| Optimism Sepolia | 11155420 | `0x61Ec26aA57019C486B10502285c5A3D4A4750AD7` |
| Base Sepolia | 84532 | `0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1` |

**Full list**: See `contracts/script/ChainlinkFeeds.sol`

---

## Troubleshooting

### Error: "Stale price"

**Cause**: Chainlink data is older than 1 hour.

**Solution**: Wait for Chainlink to update, or deploy with a custom mock feed for testing.

### Error: "Registry address is immutable"

**Cause**: Trying to call `setRegistry()` which no longer exists.

**Solution**: Registry address must be set in constructor. Re-deploy if incorrect.

### Error: "Unsupported network"

**Cause**: Chainlink feed not configured for this chain.

**Solution**: Set `CHAINLINK_ETH_USD_FEED` manually in `.env`.

### Token price returns 0

**Cause**: Base token price not set, or derived token's base token is invalid.

**Solution**:
```bash
# For base token
cast send $APNT "setPrice(uint256)" 20000000000000000 --rpc-url ...

# For derived token, verify base token
cast call $XPNT "basePriceToken()" --rpc-url ...
```

---

## Security Checklist

- [ ] Registry address verified (IMMUTABLE!)
- [ ] Chainlink feed address correct for network
- [ ] Treasury address is secure multisig
- [ ] Service fee rate ≤ 10% (1000 basis points)
- [ ] Paymaster has sufficient deposit
- [ ] Tokens added to paymaster
- [ ] Test with small amounts first
- [ ] Contract verified on Etherscan
- [ ] Audit completed (for mainnet)

---

## Next Steps

1. **Frontend Integration**: Update UI to use new constructor
2. **Monitoring**: Set up Chainlink price feed monitoring
3. **User Onboarding**: Mint tokens to users
4. **Documentation**: Update user-facing docs
5. **Testing**: Run integration tests with UserOperations

---

**Support**: security@aastar.community
**Documentation**: https://github.com/aastar/SuperPaymaster
**Last Updated**: 2025-10-26
