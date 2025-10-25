# 🚨 CRITICAL INCIDENT: Unauthorized MockERC20 Deployment

## What Happened

**Date**: Phase 19 (October 2025)
**Severity**: CRITICAL
**Impact**: Production GToken replaced with unsafe Mock version

## The Problem

A MockERC20 was deployed to Sepolia testnet (0x54Afca294BA9824E6858E9b2d0B9a19C440f6D35) and used in production configurations, replacing the legitimate Governance Token (0x868F843723a98c6EECC4BF0aF3352C53d5004147).

### Comparison

| Feature | Production GToken ✅ | MockERC20 ❌ |
|---------|---------------------|--------------|
| **Contract Name** | Governance Token | GToken |
| **Supply Cap** | 21,000,000 GT (via cap()) | ❌ NONE - unlimited |
| **Access Control** | owner() + Ownable | ❌ NONE - anyone can mint |
| **Minted Supply** | 750 GT | 1,000,555.6 GT |
| **Security** | Production-grade | ⚠️ Test-only, UNSAFE |

### Critical Security Issues

1. **❌ No Supply Cap**: MockERC20 has no cap() function - unlimited minting possible
2. **❌ No Access Control**: No owner() function - anyone can call mint()
3. **❌ No Governance**: Cannot be transferred to multisig as planned

## Root Cause

```solidity
// script/DeploySuperPaymasterV2.s.sol:111-129
function _deployGToken() internal {
    try vm.envAddress("GTOKEN_ADDRESS") returns (address existingGToken) {
        GTOKEN = existingGToken;  // ✅ Should use this branch
    } catch {
        // ❌ This branch executed on Sepolia - WRONG
        GTOKEN = address(new MockERC20("GToken", "GT", 18));
    }
}
```

**Why it happened**: 
- GTOKEN_ADDRESS env var was not set during deployment
- Script fell back to deploying MockERC20
- No validation to prevent Mock deployment to public testnet

## Impact Assessment

### Affected Components
- ✅ **Faucet Backend**: Still using correct GToken (0x868F8...)
- ❌ **Registry Frontend**: Was using MockERC20 (0x54Afca...)
- ❌ **GTokenStaking**: Deployed with MockERC20 reference
- ❌ **All V2 Contracts**: MySBT, xPNTsFactory, SuperPaymasterV2

### User Impact
- Users unable to get GToken from faucet (address mismatch)
- Incorrect balance displays
- Potential security risk if Mock was discovered

## Fix Applied

**Immediate Fix** (2025-10-25):
```typescript
// registry/src/config/networkConfig.ts:61
- gToken: "0x54Afca294BA9824E6858E9b2d0B9a19C440f6D35", // ❌ MockERC20
+ gToken: "0x868F843723a98c6EECC4BF0aF3352C53d5004147", // ✅ Governance Token
```

## Required Follow-Up Actions

### Option 1: Redeploy V2 System (RECOMMENDED)
```bash
# Set environment variable
export GTOKEN_ADDRESS=0x868F843723a98c6EECC4BF0aF3352C53d5004147

# Redeploy with correct GToken
forge script script/DeploySuperPaymasterV2.s.sol:DeploySuperPaymasterV2 \
  --rpc-url $SEPOLIA_RPC \
  --broadcast
```

**Pros**: Clean slate, correct architecture
**Cons**: Need to update all contract addresses

### Option 2: Update GTokenStaking Reference
- Call `updateGToken()` on GTokenStaking (if function exists)
- Migrate any staked balances

**Pros**: Keep existing deployments
**Cons**: Complex migration, potential data loss

## Prevention Measures

### 1. Add Deployment Guards
```solidity
function _deployGToken() internal {
    require(block.chainid == 31337, "Use GTOKEN_ADDRESS env var for non-local chains");
    // Only deploy Mock on local anvil
    GTOKEN = address(new MockERC20("GToken", "GT", 18));
}
```

### 2. Pre-deployment Checklist
- [ ] Verify GTOKEN_ADDRESS env var is set
- [ ] Confirm target address has cap() function
- [ ] Verify owner() points to authorized address
- [ ] Check totalSupply is reasonable

### 3. CI/CD Validation
```bash
# Add to deployment pipeline
cast call $GTOKEN_ADDRESS "cap()(uint256)" --rpc-url $RPC_URL
cast call $GTOKEN_ADDRESS "owner()(address)" --rpc-url $RPC_URL
```

## Lessons Learned

### ⚠️ CRITICAL RULES - NEVER VIOLATE

1. **Never deploy Mock contracts to public networks** (testnet or mainnet)
2. **Never replace production contracts without explicit approval**
3. **Never use "optimization" or "simplification" as justification for changes**
4. **Always verify contract capabilities before deployment** (cap, owner, etc.)
5. **MockERC20 is ONLY for local anvil testing**

### Process Improvements

1. **Mandatory Environment Validation**: Fail deployment if critical env vars missing
2. **Contract Type Verification**: Detect Mock contracts and abort on public networks
3. **Change Approval Process**: All contract replacements require documented approval
4. **Post-Deployment Validation**: Automated checks for contract capabilities

## Incident Timeline

- **Phase 19**: MockERC20 deployed (0x54Afca...)
- **2025-10-25**: Issue discovered by user
- **2025-10-25**: Registry config fixed
- **Pending**: V2 system redeployment or migration

## Status

- [x] Immediate fix applied (Registry config)
- [ ] V2 system redeployment decision
- [ ] Update all dependent contracts
- [ ] User communication about address change
- [ ] Add deployment guards to prevent recurrence

---

**Never forget**: Production systems require production contracts. MockERC20 is a test helper, not a substitute for proper ERC20 implementations.
