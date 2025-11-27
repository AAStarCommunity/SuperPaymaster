# MySBT Airdrop Mint Function

## Overview

The `airdropMint` function enables **Operator-paid** SBT minting, where communities can airdrop SBTs to users without requiring any user interaction or approval.

## Function Signature

```solidity
function airdropMint(address user, string memory metadata)
    external
    whenNotPaused
    nonReentrant
    onlyRegisteredCommunity
    returns (uint256 tokenId, bool isNewMint)
```

## Key Features

### ✅ True Airdrop Experience
- **No user approval needed** - Users don't need to sign any transactions
- **No user gas fees** - Operator pays all gas
- **No user GToken** - Operator provides all GToken needed
- **Instant delivery** - SBT appears in user's wallet immediately

### 💰 Operator Pays Everything

The operator (registered community) pays:
1. **mintFee** (0.1 GT) - Burned to dead address
2. **minLockAmount** (0.3 GT) - Staked for user
3. **Gas fees** - All transaction costs

**Total cost per airdrop: 0.4 GT + gas**

## How It Works

### Step 1: Operator Preparation
```solidity
// Operator must approve MySBT contract to spend GToken
// Total needed: (mintFee + minLockAmount) * numberOfUsers
uint256 totalNeeded = (0.1 ether + 0.3 ether) * userCount; // 0.4 GT per user
gToken.approve(mySBTAddress, totalNeeded);
```

### Step 2: Execute Airdrop Mint
```solidity
// Operator calls airdropMint for each user
(uint256 tokenId, bool isNewMint) = mySBT.airdropMint(
    userAddress,
    '{"communityAddress": "0x...", "communityName": "MyDAO", "nodeType": "PAYMASTER_SUPER"}'
);
```

### Step 3: Behind the Scenes
The contract automatically:
1. ✅ Transfers 0.3 GT from operator to MySBT contract
2. ✅ Approves GTokenStaking to spend 0.3 GT
3. ✅ Calls `stakeFor(user, 0.3 GT)` - user becomes beneficiary
4. ✅ Locks the stake with `lockStake(user, 0.3 GT, "MySBT Airdrop")`
5. ✅ Burns 0.1 GT mintFee from operator's balance
6. ✅ Mints SBT to user

### Step 4: User Experience
- ✅ User receives SBT in their wallet
- ✅ User has 0.3 GT staked on their behalf
- ✅ User can burn SBT if they don't want it
- ✅ Zero interaction required

## Usage in Batch Minting

### Frontend Integration

```typescript
// In BatchContractService.ts
async executeBatchAirdrop(
  contractAddress: string,
  addresses: string[],
  metadata: string,
  onProgress?: (current: number, total: number) => void
): Promise<BatchMintResult> {
  if (!this.signer) {
    throw new Error('Wallet not connected');
  }

  // Calculate total GToken needed
  const totalGTokenNeeded = ethers.parseEther('0.4').mul(addresses.length);

  // Check operator's GToken balance and approval
  const gTokenContract = new ethers.Contract(
    GTOKEN_ADDRESS,
    ['function approve(address, uint256)', 'function balanceOf(address) view returns (uint256)'],
    this.signer
  );

  const balance = await gTokenContract.balanceOf(this.signer.address);
  if (balance < totalGTokenNeeded) {
    throw new Error(`Insufficient GToken. Need ${ethers.formatEther(totalGTokenNeeded)} GT`);
  }

  // Approve MySBT contract
  const approveTx = await gTokenContract.approve(contractAddress, totalGTokenNeeded);
  await approveTx.wait();

  // Execute batch airdrop
  const mySBT = new ethers.Contract(
    contractAddress,
    ['function airdropMint(address user, string memory metadata) returns (uint256, bool)'],
    this.signer
  );

  const results = [];
  for (let i = 0; i < addresses.length; i++) {
    try {
      const tx = await mySBT.airdropMint(addresses[i], metadata);
      const receipt = await tx.wait();

      results.push({
        address: addresses[i],
        success: true,
        txHash: receipt.hash
      });

      if (onProgress) {
        onProgress(i + 1, addresses.length);
      }
    } catch (error) {
      results.push({
        address: addresses[i],
        success: false,
        error: error.message
      });
    }
  }

  return { results };
}
```

## Pre-Check Requirements

### For Operator
- ✅ Must be a registered community in Registry
- ✅ Must have sufficient GToken balance: `0.4 GT × number_of_users`
- ✅ Must approve MySBT contract to spend GToken
- ✅ Must have sufficient ETH for gas fees

### For Users
- ❌ No requirements! (That's the point)
- ✅ Will receive SBT automatically
- ✅ Will have GToken staked on their behalf
- ✅ Can burn SBT later if unwanted

## Comparison: Airdrop vs Regular Mint

| Feature | `airdropMint()` | `mintOrAddMembership()` |
|---------|----------------|-------------------------|
| User approval needed | ❌ No | ✅ Yes |
| User must have GToken | ❌ No | ✅ Yes (0.4 GT) |
| User must stake GToken | ❌ No | ✅ Yes |
| Who pays mintFee | Operator | User |
| Who provides stake | Operator | User |
| User gas fees | ❌ None | ✅ Required |
| Best for | Mass airdrops | Individual minting |

## Security Considerations

### ✅ Protected by `onlyRegisteredCommunity`
Only registered communities can airdrop SBTs, preventing spam.

### ✅ Rate Limiting (Optional)
Consider implementing rate limits in your frontend:
```typescript
const MAX_AIRDROPS_PER_HOUR = 1000;
const DELAY_BETWEEN_AIRDROPS = 100; // ms
```

### ✅ Operator GToken Balance Check
Always verify operator has sufficient GToken before starting batch airdrop.

### ✅ Duplicate Prevention
Contract automatically rejects duplicate mints for same user+community.

## Cost Calculation

### Per Airdrop
- GToken cost: **0.4 GT** (0.1 fee + 0.3 stake)
- Gas cost: ~**150,000 gas** (varies by network conditions)

### Example: 100 Users Airdrop
- GToken needed: **40 GT**
- Gas needed (at 50 gwei): ~**0.75 ETH**
- Total fiat cost (at $2000/ETH, $5/GT): ~**$1,700**

## Events Emitted

```solidity
event SBTMinted(address indexed user, uint256 indexed tokenId, address indexed community, uint256 timestamp);
```

## Error Codes

- `InvalidAddress` - User address is zero address
- `InvalidParameter` - Metadata empty or too long (>1024 bytes)
- `CommunityNotRegistered` - Caller is not a registered community
- `MembershipAlreadyExists` - User already has SBT from this community
- `InsufficientGTokenBalance` - Operator doesn't have enough GToken
- `ERC20: insufficient allowance` - Operator hasn't approved MySBT contract

## Deployment Checklist

- [ ] Deploy MySBT_v2.3.2 with `airdropMint` function
- [ ] Verify GTokenStaking has `stakeFor` function
- [ ] Update frontend to use `airdropMint` for batch operations
- [ ] Remove allowance checks for airdrop mode
- [ ] Test with small batch (5-10 users)
- [ ] Monitor gas costs and optimize batch size
- [ ] Set up operator GToken monitoring/alerts

## Migration Guide

### From `mintOrAddMembership` to `airdropMint`

**Before** (user-paid):
```typescript
// User needs to approve
await gToken.approve(mySBTAddress, ethers.parseEther('0.4'));
await mySBT.mintOrAddMembership(userAddress, metadata);
```

**After** (operator-paid):
```typescript
// Only operator needs to approve (once for all users)
await gToken.approve(mySBTAddress, ethers.parseEther('0.4').mul(userCount));

// No user interaction needed
for (const user of users) {
  await mySBT.airdropMint(user, metadata);
}
```

## FAQ

**Q: Can users reject airdrops?**
A: Users receive SBTs automatically. They can burn them later if unwanted.

**Q: Who owns the staked GToken?**
A: The user owns it. Operator just provides it. User can unstake later following normal unstaking rules.

**Q: Is this gas-efficient for small batches?**
A: For <10 users, consider regular mint. For 10+ users, airdrop is more convenient despite higher operator costs.

**Q: Can I airdrop to addresses that already have SBTs?**
A: Yes, it will add a new community membership (no fees charged for existing SBT holders).

## Version

- **Contract**: MySBT_v2.3.2
- **Function**: `airdropMint`
- **Added**: 2025-11-19
- **Status**: ✅ Ready for deployment
