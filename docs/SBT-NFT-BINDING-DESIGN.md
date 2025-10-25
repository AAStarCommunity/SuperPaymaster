# SBT + NFT 绑定机制设计

## 🎯 设计目标

**两层身份体系**：
1. **基础身份层**：MySBT（白板 SBT，无许可 mint）
2. **社区身份层**：Community NFT（社区发行，需授权）

**核心理念**：
- 任何人都可以 mint 协议白板 SBT（lock 0.3 sGT）
- 要加入社区，需在 SBT 上绑定该社区的 NFT
- 一个 SBT 可以绑定多个社区 NFT（多社区成员身份）
- 绑定/解绑需要验证 NFT 所有权

## 🏗️ 架构设计

### 1. MySBT 增强（NFT Binding）

**新增存储结构**：

```solidity
/// @notice SBT 绑定的 NFT 列表
/// @dev tokenId => community => NFT contract address
mapping(uint256 => mapping(address => address)) public boundNFTs;

/// @notice 反向映射：NFT => SBT tokenId
/// @dev NFT contract => NFT tokenId => SBT tokenId
mapping(address => mapping(uint256 => uint256)) public nftToSBT;

/// @notice SBT 绑定的所有社区列表
/// @dev tokenId => community addresses
mapping(uint256 => address[]) public sbtCommunities;

/// @notice NFT 绑定记录
struct NFTBinding {
    address nftContract;    // NFT 合约地址
    uint256 nftTokenId;     // NFT token ID
    uint256 bindTime;       // 绑定时间
    bool isActive;          // 是否激活
}

/// @notice 完整绑定记录
/// @dev SBT tokenId => community => NFTBinding
mapping(uint256 => mapping(address => NFTBinding)) public bindings;
```

**核心函数**：

```solidity
/**
 * @notice 绑定社区 NFT 到 SBT
 * @param sbtTokenId SBT token ID
 * @param community 社区地址
 * @param nftContract 社区 NFT 合约地址
 * @param nftTokenId NFT token ID
 */
function bindNFT(
    uint256 sbtTokenId,
    address community,
    address nftContract,
    uint256 nftTokenId
) external;

/**
 * @notice 解绑社区 NFT
 * @param sbtTokenId SBT token ID
 * @param community 社区地址
 */
function unbindNFT(uint256 sbtTokenId, address community) external;

/**
 * @notice 验证用户在社区的身份
 * @param user 用户地址
 * @param community 社区地址
 * @return hasMembership True if user has active community membership
 */
function verifyCommunityMembership(
    address user,
    address community
) external view returns (bool);

/**
 * @notice 获取 SBT 绑定的所有社区
 * @param sbtTokenId SBT token ID
 * @return communities 社区地址列表
 */
function getBoundCommunities(uint256 sbtTokenId)
    external
    view
    returns (address[] memory communities);

/**
 * @notice 获取社区绑定的 NFT 信息
 * @param sbtTokenId SBT token ID
 * @param community 社区地址
 * @return binding NFT 绑定信息
 */
function getCommunityBinding(uint256 sbtTokenId, address community)
    external
    view
    returns (NFTBinding memory binding);
```

## 📋 使用流程

### Step 1: Mint 白板 SBT（基础身份）

```solidity
// User mints MySBT (protocol white-label SBT)
mysbt.mintSBT(community);
// Lock: 0.3 sGT
// Fee: 0.1 GT (burned)
// Result: User gets blank SBT with tokenId
```

此时用户拥有：
- ✅ 基础身份 SBT
- ❌ 无社区成员身份

### Step 2: 获取社区 NFT（社区授权）

社区可以通过多种方式发行 NFT：
1. **Whitelist Mint**：社区白名单用户可 mint
2. **Purchase**：用户购买社区 NFT
3. **Airdrop**：社区空投给活跃用户
4. **Achievement**：完成任务解锁

```solidity
// Example: User gets community NFT
communityNFT.mint(user);  // 社区授权 mint
```

### Step 3: 绑定 NFT 到 SBT（激活社区身份）

```solidity
// User binds community NFT to their SBT
uint256 sbtTokenId = mysbt.userCommunityToken(user, baseCommunity);
mysbt.bindNFT(
    sbtTokenId,
    targetCommunity,
    communityNFTContract,
    nftTokenId
);
```

**验证要求**：
1. ✅ 用户是 SBT owner
2. ✅ 用户是 NFT owner
3. ✅ NFT 未被其他 SBT 绑定
4. ✅ 该社区位置未被占用

绑定后：
- ✅ 用户拥有该社区成员身份
- ✅ 可在该社区使用 paymaster 服务
- ✅ 可享受社区权益

### Step 4: 验证社区成员身份

```solidity
// Paymaster validates user's community membership
bool isMember = mysbt.verifyCommunityMembership(user, community);

if (isMember) {
    // Allow gas sponsorship
} else {
    revert("Not a community member");
}
```

### Step 5: 解绑 NFT（退出社区）

```solidity
// User unbinds NFT from SBT
mysbt.unbindNFT(sbtTokenId, community);
```

**效果**：
- ❌ 失去该社区成员身份
- ✅ NFT 归还给用户（可交易/转移）
- ✅ SBT 仍然保留（可绑定其他社区）

## 🔐 安全机制

### 1. NFT 所有权验证

```solidity
function bindNFT(...) external {
    // Verify NFT ownership
    require(
        IERC721(nftContract).ownerOf(nftTokenId) == msg.sender,
        "Not NFT owner"
    );

    // Verify SBT ownership
    require(
        ownerOf(sbtTokenId) == msg.sender,
        "Not SBT owner"
    );

    // Verify NFT not already bound
    require(
        nftToSBT[nftContract][nftTokenId] == 0,
        "NFT already bound"
    );
}
```

### 2. NFT 锁定机制（可选）

**方案 A**：NFT 托管（推荐）
- 绑定时，NFT 转移到 MySBT 合约托管
- 解绑时，NFT 归还给用户
- **优点**：防止 NFT 转移后仍保留社区身份
- **缺点**：NFT 不可交易

```solidity
function bindNFT(...) external {
    // Transfer NFT to MySBT contract for custody
    IERC721(nftContract).transferFrom(msg.sender, address(this), nftTokenId);

    // Record binding
    bindings[sbtTokenId][community] = NFTBinding({
        nftContract: nftContract,
        nftTokenId: nftTokenId,
        bindTime: block.timestamp,
        isActive: true
    });
}
```

**方案 B**：NFT 保留（灵活）
- 绑定时，NFT 仍在用户钱包
- 验证时，检查用户是否仍持有 NFT
- **优点**：NFT 可交易、可展示
- **缺点**：NFT 转移后需要重新绑定

```solidity
function verifyCommunityMembership(address user, address community)
    external
    view
    returns (bool)
{
    uint256 sbtTokenId = userCommunityToken[user][baseCommunity];
    NFTBinding memory binding = bindings[sbtTokenId][community];

    if (!binding.isActive) return false;

    // Real-time NFT ownership check
    return IERC721(binding.nftContract).ownerOf(binding.nftTokenId) == user;
}
```

### 3. 防止重复绑定

```solidity
// 一个 NFT 只能绑定一个 SBT
mapping(address => mapping(uint256 => uint256)) public nftToSBT;

function bindNFT(...) external {
    require(nftToSBT[nftContract][nftTokenId] == 0, "NFT already bound");
    nftToSBT[nftContract][nftTokenId] = sbtTokenId;
}
```

## 🎨 社区 NFT 定制

社区可以定制自己的 NFT：

### 1. 自定义图片

```solidity
contract CommunityNFT is ERC721URIStorage {
    function tokenURI(uint256 tokenId)
        public
        view
        override
        returns (string memory)
    {
        return string(abi.encodePacked(
            "ipfs://",
            communityBaseURI,
            "/",
            Strings.toString(tokenId),
            ".json"
        ));
    }
}
```

### 2. 自定义属性

```json
{
  "name": "MyDAO Member #123",
  "description": "Active member of MyDAO community",
  "image": "ipfs://Qm.../member.png",
  "attributes": [
    {
      "trait_type": "Community",
      "value": "MyDAO"
    },
    {
      "trait_type": "Tier",
      "value": "Gold"
    },
    {
      "trait_type": "Join Date",
      "value": "2025-01-15"
    }
  ]
}
```

### 3. 动态 NFT（可升级）

```solidity
contract DynamicCommunityNFT is ERC721 {
    mapping(uint256 => uint256) public memberTier;

    function upgradeTier(uint256 tokenId) external onlyOwner {
        memberTier[tokenId]++;
        // Update metadata
    }
}
```

## 📊 数据结构示例

### 用户 Alice 的身份体系

```
Alice's Wallet: 0x123...

MySBT (Base Identity):
  tokenId: 42
  locked: 0.3 sGT
  owner: Alice (0x123...)

Bound Communities:
  1. DAO-A:
     NFT: DaoAMemberNFT #15
     Tier: Gold
     Joined: 2025-01-01

  2. DAO-B:
     NFT: DaoBMemberNFT #89
     Tier: Silver
     Joined: 2025-02-15

  3. Gaming-C:
     NFT: GamerNFT #234
     Level: 10
     Joined: 2025-03-01
```

### 验证流程

```solidity
// Paymaster checks if Alice is member of DAO-A
bool isMember = mysbt.verifyCommunityMembership(
    0x123...,  // Alice's address
    daoA       // DAO-A community address
);

// Result: true (Alice has bound DaoAMemberNFT #15)
```

## 🚀 实现优先级

### Phase 1 (MVP)
1. ✅ MySBT 基础功能（已完成）
2. ✅ MySBTFactory（已完成）
3. 🔜 NFT 绑定核心功能
   - bindNFT()
   - unbindNFT()
   - verifyCommunityMembership()

### Phase 2 (增强)
1. 🔜 NFT 托管机制（方案 A）
2. 🔜 多社区身份管理 UI
3. 🔜 社区 NFT 定制模板

### Phase 3 (高级)
1. 🔜 动态 NFT 升级
2. 🔜 跨社区信誉积分
3. 🔜 身份聚合查询

## ❓ 待讨论问题

1. **NFT 托管 vs NFT 保留**：你更倾向哪种方案？
   - 托管：更安全，防止身份转移
   - 保留：更灵活，NFT 可交易展示

2. **社区 NFT 发行方式**：
   - 社区自己部署 NFT 合约？
   - 协议提供统一 NFT 模板？
   - 两者都支持？

3. **绑定数量限制**：
   - 一个 SBT 最多绑定多少个社区？
   - 无限制 vs 设置上限（如 10 个）？

4. **解绑冷却期**：
   - 是否需要解绑冷却期（如 7 天）？
   - 防止频繁切换社区身份

5. **SBT burn 时 NFT 处理**：
   - burn SBT 时自动解绑所有 NFT？
   - 或要求先解绑所有 NFT 才能 burn？

## 📝 下一步行动

请确认以下设计方向：
1. NFT 托管方案选择（A or B）
2. 社区 NFT 发行方式
3. 绑定数量限制策略
4. 其他自定义需求

确认后我将实现 Phase 1 核心功能。
