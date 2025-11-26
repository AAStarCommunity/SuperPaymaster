# MySBT User Guide

**[English](#english)** | **[中文](#chinese)**

<a name="english"></a>

---

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

---

<a name="chinese"></a>

# MySBT 用户指南

**[English](#english)** | **[中文](#chinese)**

---

## 什么是 MySBT？

MySBT（Mycelium Soul Bound Token）是一种不可转让的身份代币，它：
- 证明你在社区中的会员资格
- 追踪你的链上声誉
- 通过 SuperPaymaster 实现无 Gas 交易
- 绑定你的 NFT 头像

## 前提条件

要铸造 MySBT，你需要：

1. **GToken (GT)**：最少 0.4 GT
   - 0.3 GT 锁定作为质押（可退还，扣除退出费）
   - 0.1 GT 作为铸造费燃烧（不可退还）

2. **钱包**：EOA 或智能账户 (AA)

3. **社区**：一个已注册的社区

## 铸造你的 MySBT

### 方法 1：自动质押铸造（推荐）

单笔交易：授权 + 质押 + 锁定 + 铸造

```javascript
import { parseEther } from 'viem';

// 1. 授权 GToken
await gtokenContract.write.approve([
  MYSBT_ADDRESS,
  parseEther('0.4')  // 0.3 锁定 + 0.1 燃烧
]);

// 2. 使用自动质押铸造
await mysbtContract.write.mintWithAutoStake([
  communityAddress,      // 要加入的第一个社区
  parseEther('0.3'),     // 锁定金额
  '{"avatar": "ipfs://..."}' // 元数据（可选）
]);
```

### 方法 2：预质押铸造

如果你已经有质押的 GT：

```javascript
// 铸造（需要可用质押余额 >= 0.3 GT）
await mysbtContract.write.mint([
  communityAddress,
  '{"avatar": "ipfs://..."}'
]);
```

## 管理你的 SBT

### 查看你的 SBT

```javascript
// 获取你的代币 ID
const tokenId = await mysbtContract.read.userToSBT([userAddress]);

// 获取 SBT 数据
const sbtData = await mysbtContract.read.sbtData([tokenId]);
// 返回：{ holder, firstCommunity, mintedAt, totalCommunities }

// 获取会员资格
const memberships = await mysbtContract.read.getAllMemberships([tokenId]);
```

### 加入更多社区

```javascript
// 加入另一个社区（需要社区的 allowPermissionlessMint = true）
await mysbtContract.write.joinCommunity([
  tokenId,
  newCommunityAddress,
  '{"role": "member"}'  // 元数据
]);
```

### 离开社区

```javascript
// 离开社区
await mysbtContract.write.leaveCommunity([
  tokenId,
  communityAddress
]);
```

### 更新元数据

```javascript
// 更新社区会员资格元数据
await mysbtContract.write.updateMetadata([
  tokenId,
  communityAddress,
  '{"role": "moderator", "level": 5}'
]);
```

### 绑定 NFT 头像

```javascript
// 绑定 NFT 作为你的头像
await mysbtContract.write.bindNFTAvatar([
  tokenId,
  nftContractAddress,
  nftTokenId
]);

// 解绑头像
await mysbtContract.write.unbindNFTAvatar([tokenId]);
```

## 销毁你的 SBT

退出系统并取回质押（扣除退出费）：

```javascript
// 销毁 SBT 并解锁质押
await mysbtContract.write.burn([tokenId]);
```

**注意**：
- 退出费通常为锁定金额的 1%
- 请求解除质押后需等待 7 天才能提取

## 声誉系统

你的 SBT 追踪声誉：

```javascript
// 获取声誉分数
const reputation = await mysbtContract.read.getReputationScore([
  tokenId,
  communityAddress
]);

// 声誉通过以下方式增加：
// - 活跃参与（交易）
// - 在社区的时间
// - 社区贡献
```

### 声誉等级（基于斐波那契）

| 等级 | 所需分数 | 权益 |
|------|---------|------|
| 1 | 0 | 基础成员 |
| 2 | 100 | 增强功能 |
| 3 | 200 | 优先支持 |
| 4 | 400 | 治理参与 |
| ... | 斐波那契增长 | ... |

## 使用 SBT 进行无 Gas 交易

使用 MySBT，你可以用社区 xPNTs 代币支付 Gas：

```javascript
// 你的 SBT 持有者状态会自动在 SuperPaymaster 中注册
// 当你发送带有 paymasterAndData 的 UserOperation 时，系统会：
// 1. 验证你的 SBT 所有权
// 2. 从你的余额中扣除 xPNTs
// 3. 赞助 Gas 费用
```

详细的无 Gas 交易设置请参阅 [开发者集成指南](./DEVELOPER_INTEGRATION_GUIDE.md)。

## Sepolia 测试网

| 合约 | 地址 |
|------|------|
| MySBT v2.4.5 | `0xa4eda5d023ea94a60b1d4b5695f022e1972858e7` |
| GToken | `0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc` |
| GTokenStaking | `0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0` |

## 常见错误

| 错误 | 原因 | 解决方案 |
|------|------|----------|
| `AlreadyHasSBT` | 你已经拥有 SBT | 每个地址只能有一个 SBT |
| `InsufficientStake` | GT 不足 | 获取更多 GT 或质押更多 |
| `CommunityNotRegistered` | 无效的社区 | 检查社区地址 |
| `NotSBTOwner` | 你不拥有此 SBT | 使用正确的 tokenId |
| `CommunityNotAllowingMint` | 无需许可铸造已禁用 | 联系社区管理员 |

## 常见问题

**问：我可以转让我的 SBT 吗？**
答：不可以，MySBT 是灵魂绑定的，不可转让。

**问：我可以拥有多个 SBT 吗？**
答：不可以，每个地址只能有一个 SBT。

**问：如果我销毁 SBT，我的质押会怎样？**
答：你的质押会被解锁（扣除退出费），7 天后可以提取。

**问：我可以加入多个社区吗？**
答：可以，一个 SBT 可以在多个社区拥有会员资格（每个社区资料最多 10 个）。

## 后续步骤

- [社区注册](./COMMUNITY_REGISTRATION.md)
- [无 Gas 交易指南](./DEVELOPER_INTEGRATION_GUIDE.md)
- [MySBT API 参考](./API_MYSBT.md)
