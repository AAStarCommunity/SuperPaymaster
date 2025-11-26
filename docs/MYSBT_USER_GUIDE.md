# MySBT User Guide

## What is MySBT?

MySBT (Mycelium Soul Bound Token) is a non-transferable identity token that:
- Proves your membership in communities
- Tracks your on-chain reputation
- Enables gasless transactions via SuperPaymaster
- Binds to your NFT avatar

## Prerequisites

To mint a MySBT, you need:

1. **GToken (GT)**: Minimum 0.4 GT
   - 0.3 GT locked as stake (refundable with exit fee)
   - 0.1 GT burned as mint fee (non-refundable)

2. **A Wallet**: EOA or Smart Account (AA)

3. **Community**: A registered community to join

## Minting Your MySBT

### Method 1: Auto-Stake Mint (Recommended)

Single transaction: approve + stake + lock + mint

```javascript
import { parseEther } from 'viem';

// 1. Approve GToken
await gtokenContract.write.approve([
  MYSBT_ADDRESS,
  parseEther('0.4')  // 0.3 lock + 0.1 burn
]);

// 2. Mint with auto-stake
await mysbtContract.write.mintWithAutoStake([
  communityAddress,      // First community to join
  parseEther('0.3'),     // Lock amount
  '{"avatar": "ipfs://..."}' // Metadata (optional)
]);
```

### Method 2: Pre-Staked Mint

If you already have staked GT:

```javascript
// Mint (requires available staked balance >= 0.3 GT)
await mysbtContract.write.mint([
  communityAddress,
  '{"avatar": "ipfs://..."}'
]);
```

## Managing Your SBT

### View Your SBT

```javascript
// Get your token ID
const tokenId = await mysbtContract.read.userToSBT([userAddress]);

// Get SBT data
const sbtData = await mysbtContract.read.sbtData([tokenId]);
// Returns: { holder, firstCommunity, mintedAt, totalCommunities }

// Get memberships
const memberships = await mysbtContract.read.getAllMemberships([tokenId]);
```

### Join Additional Communities

```javascript
// Join another community (requires community's allowPermissionlessMint = true)
await mysbtContract.write.joinCommunity([
  tokenId,
  newCommunityAddress,
  '{"role": "member"}'  // Metadata
]);
```

### Leave a Community

```javascript
// Leave a community
await mysbtContract.write.leaveCommunity([
  tokenId,
  communityAddress
]);
```

### Update Metadata

```javascript
// Update community membership metadata
await mysbtContract.write.updateMetadata([
  tokenId,
  communityAddress,
  '{"role": "moderator", "level": 5}'
]);
```

### Bind NFT Avatar

```javascript
// Bind an NFT as your avatar
await mysbtContract.write.bindNFTAvatar([
  tokenId,
  nftContractAddress,
  nftTokenId
]);

// Unbind avatar
await mysbtContract.write.unbindNFTAvatar([tokenId]);
```

## Burning Your SBT

To exit the system and recover your stake (minus exit fee):

```javascript
// Burn SBT and unlock stake
await mysbtContract.write.burn([tokenId]);
```

**Note**:
- Exit fee is typically 1% of locked amount
- You must wait 7 days after requesting unstake to withdraw

## Reputation System

Your SBT tracks reputation:

```javascript
// Get reputation score
const reputation = await mysbtContract.read.getReputationScore([
  tokenId,
  communityAddress
]);

// Reputation increases with:
// - Active participation (transactions)
// - Time in community
// - Community contributions
```

### Reputation Levels (Fibonacci-based)

| Level | Score Required | Benefits |
|-------|---------------|----------|
| 1 | 0 | Basic member |
| 2 | 100 | Enhanced features |
| 3 | 200 | Priority support |
| 4 | 400 | Governance participation |
| ... | Fibonacci growth | ... |

## Using SBT for Gasless Transactions

With MySBT, you can use community xPNTs tokens for gas:

```javascript
// Your SBT holder status is automatically registered in SuperPaymaster
// When you send a UserOperation with paymasterAndData, the system:
// 1. Verifies your SBT ownership
// 2. Deducts xPNTs from your balance
// 3. Sponsors the gas fee
```

See [Developer Integration Guide](./DEVELOPER_INTEGRATION_GUIDE.md) for detailed gasless transaction setup.

## Sepolia Testnet

| Contract | Address |
|----------|---------|
| MySBT v2.4.5 | `0xa4eda5d023ea94a60b1d4b5695f022e1972858e7` |
| GToken | `0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc` |
| GTokenStaking | `0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0` |

## Common Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `AlreadyHasSBT` | You already own an SBT | One SBT per address |
| `InsufficientStake` | Not enough GT | Get more GT or stake more |
| `CommunityNotRegistered` | Invalid community | Check community address |
| `NotSBTOwner` | You don't own this SBT | Use correct tokenId |
| `CommunityNotAllowingMint` | Permissionless mint disabled | Contact community admin |

## FAQ

**Q: Can I transfer my SBT?**
A: No, MySBT is soulbound and non-transferable.

**Q: Can I have multiple SBTs?**
A: No, one SBT per address.

**Q: What happens to my stake if I burn my SBT?**
A: Your stake is unlocked (minus exit fee) and can be withdrawn after 7 days.

**Q: Can I join multiple communities?**
A: Yes, one SBT can have memberships in multiple communities (max 10 per community profile).

## Next Steps

- [Community Registration](./COMMUNITY_REGISTRATION.md)
- [Gasless Transaction Guide](./DEVELOPER_INTEGRATION_GUIDE.md)
- [MySBT API Reference](./API_MYSBT.md)
