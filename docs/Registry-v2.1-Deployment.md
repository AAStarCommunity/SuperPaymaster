# Registry v2.1 Deployment Guide

## Overview

Registry v2.1 is an upgrade from v2.0 with the following improvements:
- **Configurable node types**: 4 types (PAYMASTER_AOA, PAYMASTER_SUPER, ANODE, KMS) instead of hardcoded 2
- **Progressive slash**: 2%-10% based on failure count (vs fixed 10%)
- **Governance functions**: `configureNodeType()`, `setSuperPaymasterV2()`
- **Backward compatible**: Existing v2.0 communities work unchanged

## Prerequisites

### Required Contracts (Already Deployed on Sepolia)

| Contract | Address | Status |
|----------|---------|--------|
| GToken | `0x868F843723a98c6EECC4BF0aF3352C53d5004147` | ✅ |
| GTokenStaking | `0xD8235F8920815175BD46f76a2cb99e15E02cED68` | ✅ |
| SuperPaymasterV2 | `0xb96d8BC6d771AE5913C8656FAFf8721156AC8141` | ✅ |
| Registry v2.0 | `0x6806e4937038e783cA0D3961B7E258A3549A0043` | 🔄 Will coexist |

### Environment Variables

```bash
# Set in .env file
SEPOLIA_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/YOUR_API_KEY"
PRIVATE_KEY="your_private_key_here"
ETHERSCAN_API_KEY="your_etherscan_api_key"
```

## Deployment Steps

### Step 1: Deploy Registry v2.1

```bash
cd /Volumes/UltraDisk/Dev2/aastar/SuperPaymaster

# Dry run (simulation)
forge script script/DeployRegistryV2_1.s.sol:DeployRegistryV2_1 \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  -vvvv

# Actual deployment with verification
forge script script/DeployRegistryV2_1.s.sol:DeployRegistryV2_1 \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

**Expected Output**:
```
=== Registry v2.1 Deployment ===
Deployer: 0x...
Chain ID: 11155111
GTokenStaking (existing): 0xD8235F8920815175BD46f76a2cb99e15E02cED68

1. Deploying Registry v2.1...
   Registry v2.1: 0x... (NEW ADDRESS)

2. Configuring SuperPaymasterV2 address...
   SuperPaymasterV2 set to: 0xb96d8BC6d771AE5913C8656FAFf8721156AC8141

=== Deployment Summary ===
Registry v2.1: 0x... (SAVE THIS ADDRESS)
```

### Step 2: Add Registry as Locker in GTokenStaking

**CRITICAL**: Registry must be added as a locker to lock stGTokens.

```bash
# Get the deployed Registry v2.1 address from Step 1
REGISTRY_V2_1="0x..." # Replace with actual address

# Add Registry as locker
cast send 0xD8235F8920815175BD46f76a2cb99e15E02cED68 \
  "addLocker(address)" \
  $REGISTRY_V2_1 \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

**Verify**:
```bash
cast call 0xD8235F8920815175BD46f76a2cb99e15E02cED68 \
  "isLocker(address)(bool)" \
  $REGISTRY_V2_1 \
  --rpc-url $SEPOLIA_RPC_URL
# Should return: true
```

### Step 3: Update Configuration Files

#### 3.1 Update SuperPaymaster .env

```bash
cd /Volumes/UltraDisk/Dev2/aastar/SuperPaymaster

# Add to .env
echo "V2_1_REGISTRY=$REGISTRY_V2_1" >> .env
```

#### 3.2 Update Registry Frontend

```bash
cd /Volumes/UltraDisk/Dev2/aastar/registry

# Update src/config/networkConfig.ts
```

**Edit `src/config/networkConfig.ts`**:
```typescript
const sepoliaConfig: NetworkConfig = {
  // ...
  contracts: {
    // ...
    registry: "0x838da93c815a6E45Aa50429529da9106C0621eF0", // v1.2 (keep)
    registryV2: "0x6806e4937038e783cA0D3961B7E258A3549A0043", // v2.0 (keep)
    registryV2_1: "0x...", // ← ADD THIS: New v2.1 address
    // ...
  }
};
```

#### 3.3 Update Vercel Environment Variables

```bash
# Production
echo "YOUR_REGISTRY_V2_1_ADDRESS" | vercel env add VITE_REGISTRY_V2_1_ADDRESS production

# Preview
echo "YOUR_REGISTRY_V2_1_ADDRESS" | vercel env add VITE_REGISTRY_V2_1_ADDRESS preview
```

## Verification

### Verify Contract on Etherscan

Visit: `https://sepolia.etherscan.io/address/$REGISTRY_V2_1`

Check:
- ✅ Contract verified
- ✅ `nodeTypeConfigs(0)` returns correct AOA config
- ✅ `superPaymasterV2()` returns SuperPaymaster address

### Verify Node Type Configs

```bash
# PAYMASTER_AOA (NodeType = 0)
cast call $REGISTRY_V2_1 \
  "nodeTypeConfigs(uint8)(uint256,uint256,uint256,uint256,uint256)" \
  0 \
  --rpc-url $SEPOLIA_RPC_URL

# Expected: (30000000000000000000, 10, 2, 1, 10)
# = (30 GT, 10 failures, 2% base, +1% increment, 10% max)
```

### Test Registration

```bash
# Test registering a community (requires stGToken)
# Use frontend: http://localhost:5173/operator
# Or script: script/v2/TestRegistryLaunchPaymaster.s.sol
```

## Rollback Plan

If issues occur, frontend can easily switch back to v2.0:

```typescript
// src/config/networkConfig.ts
registryV2: "0x6806e4937038e783cA0D3961B7E258A3549A0043", // Revert to v2.0
```

Registry v2.1 and v2.0 can coexist - they are separate contracts sharing the same GTokenStaking.

## Troubleshooting

### Error: "Locker not authorized"
**Solution**: Run Step 2 to add Registry as locker in GTokenStaking

### Error: "Insufficient stGToken"
**Solution**: User needs to stake more GToken via GTokenStaking.stake()

### Error: "Name already registered"
**Solution**: Community name is case-insensitive unique. Choose different name.

## Migration Path

### For Existing v2.0 Communities

**No action required**. v2.0 communities can:
1. Continue using Registry v2.0
2. OR migrate to v2.1 by re-registering (requires unstaking from v2.0 first)

**Recommended**: New communities use v2.1, existing communities stay on v2.0 until ready.

## Cost Analysis

| Operation | Gas Cost | USD (at 50 gwei, $3000 ETH) |
|-----------|----------|----------------------------|
| Deploy Registry v2.1 | ~3.5M gas | ~$525 |
| addLocker() | ~50k gas | ~$7.5 |
| setSuperPaymasterV2() | ~45k gas | ~$6.75 |
| **Total** | **~3.6M gas** | **~$540** |

## Next Steps

1. ✅ Deploy Registry v2.1 to Sepolia
2. ✅ Add as locker in GTokenStaking
3. ✅ Update all config files
4. ✅ Update RegistryExplorer to support multiple registries
5. ✅ Test end-to-end registration flow
6. 🔄 Monitor for 1 week before mainnet deployment

---

**Deployed**: TBD
**Deployer**: TBD
**Registry v2.1 Address**: TBD
