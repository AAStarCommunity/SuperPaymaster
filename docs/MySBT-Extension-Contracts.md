# MySBT v2.4.5 扩展合约方案

**创建日期**: 2024-11-24
**版本**: 1.0
**状态**: 待部署

---

## 背景

MySBT v2.4.5为满足以太坊合约大小限制（24,576 bytes），移除了NFT绑定和声誉计算功能。这些功能通过外部扩展合约提供，保持核心MySBT轻量化的同时提供完整功能。

---

## 架构设计

### 核心原则
1. **最小化MySBT依赖**: 扩展合约只需要MySBT的基础查询接口
2. **独立存储**: 所有扩展数据存储在扩展合约中，不占用MySBT存储
3. **可选部署**: 项目可根据需要选择性部署扩展合约
4. **无缝集成**: 前端可透明调用扩展合约，用户体验不变

### MySBT接口依赖

扩展合约只依赖以下MySBT接口：
```solidity
interface IMySBT {
    function getUserSBT(address user) external view returns (uint256 tokenId);
    function getSBTData(uint256 tokenId) external view returns (SBTData memory);
    function getMemberships(uint256 tokenId) external view returns (CommunityMembership[] memory);
    function getCommunityMembership(uint256 tokenId, address community) external view returns (CommunityMembership memory);
}
```

---

## 1. MySBTAvatarManager - NFT头像管理

### 功能概述
管理SBT持有者的NFT头像，支持绑定外部NFT、设置自定义头像、委托头像使用权。

### 核心功能

#### 1.1 绑定NFT
```solidity
function bindNFT(address nftContract, uint256 nftTokenId) external
```
- 验证调用者拥有SBT
- 验证调用者拥有目标NFT
- 绑定NFT到SBT（第一个绑定的NFT自动成为默认头像）
- 支持绑定多个NFT

#### 1.2 解绑NFT
```solidity
function unbindNFT(address nftContract, uint256 nftTokenId) external
```
- 将绑定的NFT标记为inactive
- 如果是当前头像，清除头像设置

#### 1.3 设置头像
```solidity
function setAvatar(address nftContract, uint256 nftTokenId) external
```
- 设置自定义头像（支持自己拥有的NFT或被委托的NFT）
- 不需要先绑定（灵活性更高）

#### 1.4 委托头像使用权
```solidity
function delegateAvatarUsage(address nftContract, uint256 nftTokenId, address delegate) external
```
- NFT所有者可以委托其他用户使用该NFT作为头像
- 用例: 社区徽章NFT可以被所有社区成员使用

#### 1.5 社区默认头像
```solidity
function setCommunityDefaultAvatar(string memory avatarURI) external
```
- 社区可以设置默认头像URI
- 当用户没有绑定NFT时，使用社区默认头像

### 查询接口

```solidity
// 获取SBT头像URI（优先级: 自定义NFT > 第一个绑定的NFT > 社区默认）
function getAvatarURI(uint256 tokenId) external view returns (string memory);

// 获取所有绑定的NFT
function getAllNFTBindings(uint256 tokenId) external view returns (NFTBinding[] memory);

// 获取活跃的NFT绑定
function getActiveNFTBindings(uint256 tokenId) external view returns (NFTBinding[] memory);

// 检查NFT是否已绑定
function isNFTBound(uint256 tokenId, address nftContract, uint256 nftTokenId) external view returns (bool);
```

### 数据结构

```solidity
struct NFTBinding {
    address nftContract;
    uint256 nftTokenId;
    uint256 bindTime;
    bool isActive;
}

struct AvatarSetting {
    address nftContract;
    uint256 nftTokenId;
    bool isCustom; // true = 用户手动设置, false = 自动使用第一个绑定的NFT
}
```

### 存储映射

```solidity
mapping(uint256 => NFTBinding[]) private _bindings;              // SBT tokenId => NFT绑定列表
mapping(uint256 => AvatarSetting) public avatars;                // SBT tokenId => 头像设置
mapping(address => string) public communityDefaultAvatar;        // 社区 => 默认头像URI
mapping(address => mapping(uint256 => mapping(address => bool))) public avatarDelegation; // NFT => tokenId => 被委托者 => 是否允许
```

### 使用示例

```javascript
// 1. 绑定NFT
await avatarManager.bindNFT("0xNFT_CONTRACT", 123);

// 2. 设置自定义头像
await avatarManager.setAvatar("0xNFT_CONTRACT", 456);

// 3. 查询头像
const avatarURI = await avatarManager.getAvatarURI(tokenId);

// 4. 社区设置默认头像
await avatarManager.setCommunityDefaultAvatar("ipfs://Qm...");

// 5. 委托头像使用权（社区徽章场景）
await avatarManager.delegateAvatarUsage("0xBADGE_NFT", 1, "0xUSER_ADDRESS");
```

---

## 2. MySBTReputationAccumulator - 声誉积累系统

### 功能概述
计算和管理SBT持有者的声誉值，支持社区特定声誉和全局声誉，可配置评分规则。

### 核心功能

#### 2.1 声誉计算公式

```
社区声誉 = 基础分 + (活跃度奖励 × 活动次数) + 时间加权分
```

- **基础分**: 加入社区即获得（默认20分）
- **活跃度奖励**: 每次活动增加（默认1分/次，最多10次）
- **时间加权分**: 基于加入时长（每周1分，最多52周）

#### 2.2 评分规则配置

```solidity
struct ScoringRules {
    uint256 baseScore;          // 基础分（默认20）
    uint256 activityBonus;      // 每次活动奖励（默认1）
    uint256 activityWindow;     // 活动统计时间窗口（默认4周）
    uint256 maxActivities;      // 最多统计活动次数（默认10）
    uint256 timeDecayFactor;    // 时间衰减因子（默认100 = 1%/周）
    uint256 minInterval;        // 活动最小间隔（默认5分钟）
}
```

#### 2.3 设置评分规则

```solidity
function setScoringRules(address community, ScoringRules memory rules) external onlyOwner
```
- 支持全局默认规则（community = address(0)）
- 支持社区自定义规则

#### 2.4 缓存机制（可选）

```solidity
function configureCaching(bool enabled, uint256 validityPeriod) external onlyOwner
```
- 启用缓存可减少链上计算（节省gas）
- 缓存有效期内返回缓存值
- 适合高频查询场景

#### 2.5 批量更新缓存

```solidity
function batchUpdateCachedScores(uint256[] calldata tokenIds, address[] calldata communities) external
```
- 支持off-chain indexer或keeper定期批量更新
- 平衡gas成本和数据实时性

### 查询接口

```solidity
// 获取社区声誉
function getCommunityReputation(address user, address community) external view returns (uint256);

// 获取全局声誉（所有社区总和）
function getGlobalReputation(address user) external view returns (uint256);

// 获取声誉详细分解
function getReputationBreakdown(address user, address community) external view returns (
    uint256 communityScore,
    uint256 activityCount,
    uint256 timeWeightedScore,
    uint256 baseScore
);

// 获取评分规则
function getScoringRules(address community) external view returns (ScoringRules memory);

// 检查缓存是否有效
function isCachedScoreValid(uint256 tokenId, address community) external view returns (bool, uint256);
```

### 活动记录机制

**注意**: MySBT v2.4.5只存储`lastActivityTime`，不存储完整活动历史。准确的活动统计需要：

1. **链上事件**: 监听MySBT的`ActivityRecorded`事件
2. **The Graph**: 使用subgraph索引活动历史
3. **Off-chain Indexer**: 后端服务监听事件并更新缓存

```solidity
// MySBT中的活动记录事件
event ActivityRecorded(
    uint256 indexed tokenId,
    address indexed community,
    uint256 week,
    uint256 timestamp
);
```

### 使用示例

```javascript
// 1. 查询社区声誉
const score = await reputationAccumulator.getCommunityReputation(userAddress, communityAddress);

// 2. 查询全局声誉
const globalScore = await reputationAccumulator.getGlobalReputation(userAddress);

// 3. 获取详细分解
const breakdown = await reputationAccumulator.getReputationBreakdown(userAddress, communityAddress);
console.log('基础分:', breakdown.baseScore);
console.log('活动次数:', breakdown.activityCount);
console.log('时间加权分:', breakdown.timeWeightedScore);
console.log('总分:', breakdown.communityScore);

// 4. 设置社区自定义规则
await reputationAccumulator.setScoringRules(communityAddress, {
    baseScore: 50,
    activityBonus: 2,
    activityWindow: 8 * 7 * 24 * 3600, // 8周
    maxActivities: 20,
    timeDecayFactor: 50, // 0.5%/周
    minInterval: 10 * 60 // 10分钟
});

// 5. 启用缓存（1小时有效期）
await reputationAccumulator.configureCaching(true, 3600);

// 6. Keeper批量更新缓存
await reputationAccumulator.batchUpdateCachedScores(
    [tokenId1, tokenId2, tokenId3],
    [community1, community2, community3]
);
```

### 实现注意事项

**当前限制**: `_countRecentActivities()`返回0（占位实现）

需要完整实现需要：

1. **MySBT改进**:
```solidity
// 在MySBT中添加weeklyActivity映射
mapping(uint256 => mapping(address => mapping(uint256 => bool))) public weeklyActivity;
```

2. **The Graph集成**:
```graphql
type Activity @entity {
  id: ID!
  tokenId: BigInt!
  community: Bytes!
  week: BigInt!
  timestamp: BigInt!
}
```

3. **前端整合**:
```javascript
// 查询链上缓存 + The Graph事件
const onChainScore = await reputationAccumulator.getCommunityReputation(user, community);
const activities = await graphClient.getActivities(tokenId, community, startWeek, endWeek);
```

---

## 3. 部署指南

### 部署顺序

1. ✅ MySBT v2.4.5（已部署）
   - `0xa4eda5d023ea94a60b1d4b5695f022e1972858e7`

2. **部署MySBTAvatarManager**
```bash
forge script script/DeployMySBTAvatarManager.s.sol \
  --constructor-args 0xa4eda5d023ea94a60b1d4b5695f022e1972858e7 \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

3. **部署MySBTReputationAccumulator**
```bash
forge script script/DeployMySBTReputationAccumulator.s.sol \
  --constructor-args 0xa4eda5d023ea94a60b1d4b5695f022e1972858e7 \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

### Gas成本估算

| 操作 | Gas消耗（估算） |
|-----|----------------|
| 部署AvatarManager | ~2,500,000 |
| 部署ReputationAccumulator | ~2,800,000 |
| bindNFT | ~80,000 |
| setAvatar | ~50,000 |
| getCommunityReputation | 0 (view) |
| updateCachedScore | ~100,000 |

---

## 4. 前端集成

### ABI导入

```javascript
import MySBTAvatarManagerABI from './abi/MySBTAvatarManager.json';
import MySBTReputationAccumulatorABI from './abi/MySBTReputationAccumulator.json';

const avatarManager = new ethers.Contract(
  AVATAR_MANAGER_ADDRESS,
  MySBTAvatarManagerABI,
  provider
);

const reputationAccumulator = new ethers.Contract(
  REPUTATION_ACCUMULATOR_ADDRESS,
  MySBTReputationAccumulatorABI,
  provider
);
```

### React Hook示例

```typescript
// hooks/useSBTAvatar.ts
export function useSBTAvatar(address: string) {
  const { data: tokenId } = useReadContract({
    address: MYSBT_ADDRESS,
    abi: MySBTABI,
    functionName: 'getUserSBT',
    args: [address]
  });

  const { data: avatarURI } = useReadContract({
    address: AVATAR_MANAGER_ADDRESS,
    abi: MySBTAvatarManagerABI,
    functionName: 'getAvatarURI',
    args: [tokenId],
    enabled: !!tokenId
  });

  return { tokenId, avatarURI };
}

// hooks/useSBTReputation.ts
export function useSBTReputation(address: string, community: string) {
  const { data: score } = useReadContract({
    address: REPUTATION_ACCUMULATOR_ADDRESS,
    abi: MySBTReputationAccumulatorABI,
    functionName: 'getCommunityReputation',
    args: [address, community]
  });

  const { data: breakdown } = useReadContract({
    address: REPUTATION_ACCUMULATOR_ADDRESS,
    abi: MySBTReputationAccumulatorABI,
    functionName: 'getReputationBreakdown',
    args: [address, community]
  });

  return { score, breakdown };
}
```

---

## 5. 升级路径

### v2.5.x计划
- MySBT回调支持：mint时自动设置默认头像
- 活动记录增强：MySBT内置weeklyActivity mapping
- 声誉算法优化：支持更复杂的衰减曲线

### v3.x计划
- Diamond模式重构：所有功能模块化为facets
- 动态升级：无需重新部署即可添加新功能
- 跨链支持：声誉和头像跨链同步

---

## 6. 安全考虑

### MySBTAvatarManager
- ✅ NFT所有权验证（ownerOf）
- ✅ SBT所有权验证（getUserSBT）
- ✅ 重复绑定检查
- ✅ 优雅降级（try/catch for tokenURI）

### MySBTReputationAccumulator
- ✅ onlyOwner权限控制（评分规则）
- ✅ 缓存有效期验证
- ✅ 活动计数上限保护
- ✅ 社区成员验证

---

## 7. 已知限制

1. **活动统计不完整**: 当前实现返回0，需要The Graph或后端索引
2. **无跨合约调用**: MySBT不会自动调用扩展合约
3. **手动缓存更新**: 需要keeper或用户主动触发缓存更新
4. **Gas成本**: 首次查询声誉需要遍历所有社区成员（可通过缓存优化）

---

## 8. 联系方式

- **合约源码**: `contracts/src/paymasters/v2/extensions/`
- **部署文档**: `docs/v2.4.5-v2.3.3-deployment.md`
- **优化决策**: `docs/MySBT_v2.4.5_Optimization_Decision.md`
