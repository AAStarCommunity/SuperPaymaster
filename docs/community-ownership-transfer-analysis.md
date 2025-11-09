# Community Ownership Transfer Analysis

## Overview

When transferring community ownership from old owner `0xE3D28Aa77c95d5C098170698e5ba68824BFC008d` to new owner `0x16dF788ed4ed1Fc384e52dC832A6a6C3A23bdEBf`, multiple contract states need to be updated.

## Affected Contracts and Variables

### 1. Registry v2.2.0 (`0x028aB52B4E0EF26820043ca4F1B5Fe14FfC1EF75`)

**Function**: `transferCommunityOwnership(address newOwner)`

**Updates** (lines 274-295):
```solidity
// Storage mappings updated:
mapping(address => CommunityProfile) public communities; // Main profile storage
mapping(string => address) private communityByName;      // Name → address index
mapping(string => address) private communityByENS;       // ENS → address index
mapping(address => address) private communityBySBT;      // SBT → address index
```

**What happens**:
1. Copies `communities[oldOwner]` to `communities[newOwner]`
2. Updates `profile.community = newOwner`
3. Updates all index mappings to point to `newOwner`
4. Deletes `communities[oldOwner]`
5. Emits `CommunityOwnershipTransferred(oldOwner, newOwner, timestamp)`

**✅ Complete**: This function handles ALL Registry state updates.

### 2. SuperPaymaster V2 (`0xfaB5B2A129DF8308a70DA2fE77c61001e4Df58BC`)

**Storage**:
```solidity
struct Account {
    uint256 stGTokenLocked;
    uint256 stakedAt;
    uint256 aPNTsBalance;
    uint256 totalSpent;
    // ... more fields
    address treasury;  // ⚠️ STORES OLD OWNER ADDRESS
    // ... more fields
}

mapping(address => Account) public accounts; // Keyed by OPERATOR address, not community
```

**Issue**:
- `accounts[operatorAddress].treasury` still points to old owner
- This treasury address receives xPNTs from users
- Needs manual update via `updateTreasury(address newTreasury)`

**Function**: `updateTreasury(address newTreasury)` (line 375)
```solidity
function updateTreasury(address newTreasury) external {
    if (accounts[msg.sender].stakedAt == 0) revert NotRegistered(msg.sender);
    if (newTreasury == address(0)) revert InvalidAddress(newTreasury);

    accounts[msg.sender].treasury = newTreasury;
    emit TreasuryUpdated(msg.sender, newTreasury);
}
```

**⚠️ Requires separate call**: Operator must call `updateTreasury(newOwner)` after Registry transfer.

### 3. GTokenStaking (`0xbebF9B4c6a4CdB92ac184Af211adB13a0B9BF6c0`)

**Storage**:
```solidity
struct LockInfo {
    uint256 amount;
    uint256 lockedAt;
    string purpose;
    address beneficiary;  // Usually the locker (Registry or SuperPaymaster)
}

mapping(address => mapping(address => LockInfo)) public locks; // user → locker → info
```

**Issue**:
- `locks[oldOwner][Registry]` contains locked stake
- Community transfer doesn't automatically move stakes
- New owner needs to stake separately OR old owner needs to unlock first

**⚠️ Manual handling required**: Stakes remain locked under old owner address.

## Complete Transfer Process

### Current Implementation (Registry only)

```typescript
// CommunityDetail.tsx - executeTransferOwnership function
const txData = registryInterface.encodeFunctionData("transferCommunityOwnership", [newOwner]);
await signer.sendTransaction({ to: registryAddress, data: txData });
```

**Result**: ✅ Registry updated, ⚠️ SuperPaymaster treasury unchanged

### Recommended: Batch Transfer (Registry + SuperPaymaster)

#### Option A: Two-Step Manual Process

**Step 1**: Transfer via Registry
```solidity
// Call as current owner
Registry.transferCommunityOwnership(newOwner);
```

**Step 2**: Update SuperPaymaster treasury
```solidity
// Call as operator (if operator == old owner, need to transfer first)
SuperPaymaster.updateTreasury(newOwner);
```

**Problem**: If operator address == old community owner, operator loses control after Step 1.

#### Option B: Safe Multi-Call (Recommended)

Use Safe wallet to batch both transactions:

```typescript
const transactions = [
  // Tx 1: Transfer Registry ownership
  {
    to: REGISTRY_ADDRESS,
    data: registryInterface.encodeFunctionData("transferCommunityOwnership", [newOwner]),
    value: "0"
  },
  // Tx 2: Update SuperPaymaster treasury (if registered)
  {
    to: SUPERPAYMASTER_ADDRESS,
    data: superPaymasterInterface.encodeFunctionData("updateTreasury", [newOwner]),
    value: "0"
  }
];

await sdk.txs.send({ txs: transactions });
```

**Benefits**:
- Atomic execution (all or nothing)
- No intermediate state
- Works even if operator == community owner

#### Option C: Registry Helper Function (Future Enhancement)

Add to Registry contract:
```solidity
function transferCommunityOwnershipWithSuperPaymaster(
    address newOwner,
    address superPaymasterAddress
) external nonReentrant {
    // 1. Standard Registry transfer
    transferCommunityOwnership(newOwner);

    // 2. If caller is registered in SuperPaymaster, update treasury
    try ISuperPaymasterV2(superPaymasterAddress).accounts(msg.sender) returns (Account memory acc) {
        if (acc.stakedAt > 0) {
            // Caller is registered operator, can update treasury
            ISuperPaymasterV2(superPaymasterAddress).updateTreasury(newOwner);
        }
    } catch {
        // Not registered or call failed, skip SuperPaymaster update
    }
}
```

## Implementation Recommendations

### For Frontend (CommunityDetail.tsx)

1. **Check if community is registered in SuperPaymaster**:
```typescript
const checkSuperPaymasterRegistration = async (ownerAddress: string) => {
  const account = await superPaymaster.accounts(ownerAddress);
  return account.stakedAt > 0;
};
```

2. **Show warning if registered**:
```tsx
{isSuperPaymasterRegistered && (
  <div className="warning-box">
    ⚠️ This community is registered in SuperPaymaster.
    The treasury address will need to be updated separately after transfer.
  </div>
)}
```

3. **Provide post-transfer instructions**:
```tsx
After transfer, the operator should:
1. Connect as operator wallet: {operatorAddress}
2. Call updateTreasury(newOwner) on SuperPaymaster
3. Verify treasury updated: SuperPaymaster.accounts(operator).treasury == newOwner
```

### For Safe Wallet Integration

Enable batch transfer with automatic SuperPaymaster update:

```typescript
const handleBatchTransferOwnership = async (newOwner: string) => {
  const transactions: BaseTransaction[] = [];

  // Tx 1: Registry transfer
  transactions.push({
    to: registryAddress,
    data: registryInterface.encodeFunctionData("transferCommunityOwnership", [newOwner]),
    value: "0"
  });

  // Tx 2: SuperPaymaster treasury update (if applicable)
  const isRegistered = await checkSuperPaymasterRegistration(currentOwner);
  if (isRegistered) {
    transactions.push({
      to: superPaymasterAddress,
      data: superPaymasterInterface.encodeFunctionData("updateTreasury", [newOwner]),
      value: "0"
    });
  }

  // Send batch transaction
  if (isSafeApp && sdk) {
    await sdk.txs.send({ txs: transactions });
  } else {
    // MetaMask: sequential transactions
    for (const tx of transactions) {
      await signer.sendTransaction(tx);
    }
  }
};
```

## Summary

| Contract | Variable | Update Method | Automatic? |
|----------|----------|---------------|------------|
| Registry | `communities[address]` | `transferCommunityOwnership()` | ✅ Yes |
| Registry | `communityByName[name]` | `transferCommunityOwnership()` | ✅ Yes |
| Registry | `communityByENS[ens]` | `transferCommunityOwnership()` | ✅ Yes |
| Registry | `communityBySBT[sbt]` | `transferCommunityOwnership()` | ✅ Yes |
| SuperPaymaster | `accounts[operator].treasury` | `updateTreasury()` | ❌ No - Manual call required |
| GTokenStaking | `locks[user][locker]` | N/A | ❌ No - Remains under old owner |

**Recommended Solution**: Implement batch transaction support in frontend to call both `transferCommunityOwnership` and `updateTreasury` atomically via Safe multisig.
