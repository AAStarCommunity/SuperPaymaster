# SuperPaymaster V2 Deployment Configuration Guide

## Overview

After deploying SuperPaymaster V2 contract, the owner **must** complete configuration steps before operators can register and deposit aPNTs.

## Error: InvalidConfiguration (0xc52a9bd3)

### Symptom
Users encounter error `0xc52a9bd3` when calling `depositAPNTs()`:
```
MetaMask - RPC Error: execution reverted {code: 3, message: 'execution reverted', data: '0xc52a9bd3'}
```

### Root Cause
The `aPNTsToken` address in SuperPaymaster contract is `address(0)` (not configured).

### Fix: Set aPNTs Token Address

The contract owner must call:
```solidity
function setAPNTsToken(address newAPNTsToken) external onlyOwner
```

#### Example using cast:
```bash
# Get aPNTs token address from shared-config
APNTS_ADDRESS="0x..." # Replace with actual aPNTs address from sepolia config

# Call setAPNTsToken (as contract owner)
cast send $SUPERPAYMASTER_ADDRESS \
  "setAPNTsToken(address)" \
  $APNTS_ADDRESS \
  --rpc-url $SEPOLIA_RPC \
  --private-key $OWNER_PRIVATE_KEY
```

#### Example using ethers.js:
```typescript
import { ethers } from 'ethers';

const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
const owner = new ethers.Wallet(OWNER_PRIVATE_KEY, provider);

const superPaymaster = new ethers.Contract(
  SUPERPAYMASTER_ADDRESS,
  ["function setAPNTsToken(address newAPNTsToken) external"],
  owner
);

const tx = await superPaymaster.setAPNTsToken(APNTS_ADDRESS);
await tx.wait();

console.log("✅ aPNTs token configured");
```

## Post-Deployment Configuration Checklist

### 1. Set aPNTs Token Address (Required)
```solidity
setAPNTsToken(address aPNTsToken)
```
- **When**: Immediately after deployment
- **Who**: Contract owner
- **Why**: Required for operators to deposit aPNTs

### 2. Configure Staking Contract (Required)
Ensure GTokenStaking has SuperPaymaster as authorized locker:
```solidity
// In GTokenStaking contract
authorizeLocker(superPaymasterAddress, minStake, maxStake, "SuperPaymaster V2")
```

### 3. Set Treasury Address (Optional)
```solidity
setSuperPaymasterTreasury(address treasury)
```
- **When**: Before operators start transacting
- **Who**: Contract owner
- **Why**: Defines where aPNTs fees are collected

### 4. Configure Exchange Rate (Optional)
```solidity
setGlobalExchangeRate(uint256 rate)
```
- **When**: Before operators start transacting
- **Who**: Contract owner
- **Why**: Defines aPNTs to native token conversion rate

## Verification

After configuration, verify:

```bash
# Check aPNTs token address
cast call $SUPERPAYMASTER_ADDRESS "aPNTsToken()" --rpc-url $SEPOLIA_RPC

# Should return non-zero address, e.g.:
# 0x000000000000000000000000<aPNTs_address>
```

## Common Issues

### Issue: "InvalidConfiguration" when depositing aPNTs
- **Cause**: `aPNTsToken == address(0)`
- **Fix**: Call `setAPNTsToken(address)`

### Issue: "UnauthorizedLocker" when registering operator
- **Cause**: SuperPaymaster not authorized in GTokenStaking
- **Fix**: Call `GTokenStaking.authorizeLocker(superPaymaster, ...)`

### Issue: Operators can't stake
- **Cause**: GTokenStaking authorization missing or insufficient stake limits
- **Fix**: Verify authorization and update stake limits if needed

## Contract Addresses (Sepolia)

Update these from your deployment:
- SuperPaymaster V2: `<deployed_address>`
- aPNTs Token: `<from_shared_config>`
- GTokenStaking: `<from_shared_config>`

## References

- SuperPaymaster V2 source: `contracts/src/paymasters/v2/core/SuperPaymasterV2.sol`
- Error definitions: Line 251-260
- Configuration functions: Line 768-777 (setAPNTsToken)
