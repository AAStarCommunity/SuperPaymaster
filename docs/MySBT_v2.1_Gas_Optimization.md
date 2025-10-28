# MySBT v2.1 Gas Optimization Analysis

**日期**: 2025-10-28
**当前版本**: v2.1
**优化目标**: v2.2

## Current Gas Consumption

| Operation | Current Gas | Breakdown |
|-----------|-------------|-----------|
| **First Mint** | ~392k | ERC721 mint (50k) + Storage (280k) + Logic (62k) |
| **Add Membership** | ~186k | Array push (100k) + Index (20k) + Logic (66k) |
| **Bind NFT** | ~165k | Storage (80k) + ERC721 check (40k) + Logic (45k) |
| **Record Activity** | **~65k** | **2x SSTORE (40k) + Logic (25k)** ⚠️ |

## Optimization Strategies

### 🔥 Priority 1: Event-Based Activity Tracking

**Current Implementation**:
```solidity
function recordActivity(address user) external override {
    // ... validation

    // ❌ 写入 2 个存储槽 (~40k gas)
    _memberships[tokenId][idx].lastActiveTime = block.timestamp;
    weeklyActivity[tokenId][community][currentWeek] = true;

    emit ActivityRecorded(tokenId, msg.sender, currentWeek, block.timestamp);
}
```

**Optimized v2.2**:
```solidity
// Option A: 纯事件驱动 (推荐)
function recordActivity(address user) external override {
    if (!_isValidCommunity(msg.sender)) return;
    uint256 tokenId = userToSBT[user];
    if (tokenId == 0) return;

    uint256 idx = membershipIndex[tokenId][msg.sender];
    if (idx >= _memberships[tokenId].length ||
        _memberships[tokenId][idx].community != msg.sender) return;

    // ✅ 只发送事件 (~5k gas)
    emit ActivityRecorded(
        tokenId,
        msg.sender,
        block.timestamp / 1 weeks,
        block.timestamp
    );
}

// 声誉计算从 The Graph 查询活动数据
function getCommunityReputation(address user, address community)
    external
    view
    override
    returns (uint256 score)
{
    uint256 tokenId = userToSBT[user];
    if (tokenId == 0) return 0;

    // 使用外部声誉计算器（从链下查询活动）
    if (reputationCalculator != address(0)) {
        (score, ) = IReputationCalculator(reputationCalculator)
            .calculateReputation(user, community, tokenId);
        return score;
    }

    // 默认计算不包括活动（仅 base + NFT）
    return _calculateDefaultReputation(tokenId, community);
}
```

**Gas Savings**: 65k → **5k** (节省 92%)
**Requirements**: The Graph 或链下索引器
**Impact**: Paymaster 每笔交易节省 60k gas

**Option B: 位图追踪 (无需链下)**:
```solidity
// 位图存储：一个 uint256 存 256 周活动
mapping(uint256 => mapping(address => uint256)) public activityBitmap;

function recordActivity(address user) external override {
    // ... validation

    uint256 currentWeek = block.timestamp / 1 weeks;
    uint256 bitPosition = currentWeek % 256;  // 循环使用

    // ✅ 位运算 + SSTORE (~25k gas)
    activityBitmap[tokenId][msg.sender] |= (1 << bitPosition);

    emit ActivityRecorded(tokenId, msg.sender, currentWeek, block.timestamp);
}

function _calculateDefaultReputation(uint256 tokenId, address community)
    internal
    view
    returns (uint256 score)
{
    // ... base + NFT

    // 从位图读取活动
    uint256 bitmap = activityBitmap[tokenId][community];
    uint256 currentWeek = block.timestamp / 1 weeks;

    for (uint256 i = 0; i < ACTIVITY_WINDOW; i++) {
        uint256 weekPos = (currentWeek - i) % 256;
        if ((bitmap & (1 << weekPos)) != 0) {
            score += ACTIVITY_BONUS;
        }
    }
}
```

**Gas Savings**: 65k → **25k** (节省 62%)
**Trade-off**: 最多追踪 256 周（~5 年）

---

### ⭐ Priority 2: Packed Storage Structs

**Current Implementation**:
```solidity
struct SBTData {
    address holder;          // slot 0 (20 bytes)
    address firstCommunity;  // slot 1 (20 bytes)
    uint256 mintedAt;        // slot 2 (32 bytes)
    uint256 totalCommunities; // slot 3 (32 bytes)
}
// Total: 4 storage slots = ~80k gas on first write
```

**Optimized v2.2**:
```solidity
struct SBTData {
    address holder;               // slot 0: bytes 0-19
    uint96 totalCommunities;      // slot 0: bytes 20-31 (max 2^96)
    address firstCommunity;       // slot 1: bytes 0-19
    uint40 mintedAt;              // slot 1: bytes 20-24 (до 2106 года)
}
// Total: 2 storage slots = ~40k gas on first write
// Gas Savings: ~40k per new user
```

**Additional Packing**:
```solidity
struct CommunityMembership {
    address community;        // slot 0: bytes 0-19
    uint40 joinedAt;          // slot 0: bytes 20-24
    uint40 lastActiveTime;    // slot 0: bytes 25-29
    bool isActive;            // slot 0: byte 30
    // metadata 保持独立存储（string 无法打包）
    string metadata;          // slot 1+
}
// Saves 2 slots per membership (~40k gas)
```

**Gas Savings**: ~80k per new user (First Mint + Add Membership)

---

### 🚀 Priority 3: Optimize Array Operations

**Current Issue**:
```solidity
// 动态数组 push 很昂贵
_memberships[tokenId].push(CommunityMembership({...}));  // ~100k gas
```

**Option A: 固定大小数组**:
```solidity
// 限制最大社区数量
uint8 public constant MAX_COMMUNITIES = 32;

mapping(uint256 => CommunityMembership[32]) public memberships;
mapping(uint256 => uint8) public membershipCount;

function mintOrAddMembership(...) {
    // ... validation

    uint8 count = membershipCount[tokenId];
    require(count < MAX_COMMUNITIES, "Max communities reached");

    memberships[tokenId][count] = CommunityMembership({...});
    membershipCount[tokenId] = count + 1;
    membershipIndex[tokenId][msg.sender] = count;
}
```

**Gas Savings**: ~30k per membership (避免动态扩展)

**Option B: Mapping instead of Array**:
```solidity
// 使用 mapping 替代动态数组
mapping(uint256 => mapping(uint256 => CommunityMembership)) public membershipsByIndex;

function mintOrAddMembership(...) {
    uint256 currentCount = sbtData[tokenId].totalCommunities;

    membershipsByIndex[tokenId][currentCount] = CommunityMembership({...});
    membershipIndex[tokenId][msg.sender] = currentCount;

    sbtData[tokenId].totalCommunities++;
}

// 需要额外函数获取所有成员
function getMemberships(uint256 tokenId) external view returns (...) {
    uint256 count = sbtData[tokenId].totalCommunities;
    CommunityMembership[] memory result = new CommunityMembership[](count);

    for (uint256 i = 0; i < count; i++) {
        result[i] = membershipsByIndex[tokenId][i];
    }

    return result;
}
```

**Gas Savings**: ~50k per membership (读取变贵，写入便宜)

---

### 💡 Priority 4: Calldata Optimization

**Current**:
```solidity
function mintOrAddMembership(address user, string memory metadata)
    external
    returns (uint256 tokenId, bool isNewMint)
```

**Optimized**:
```solidity
function mintOrAddMembership(address user, string calldata metadata)
    external
    returns (uint256 tokenId, bool isNewMint)
```

**Gas Savings**: ~5-10k (避免 memory 复制)

---

## Recommended Implementation Plan

### Phase 1: Event-Based Activity (Breaking Change)
- [ ] 修改 `recordActivity()` 为纯事件驱动
- [ ] 部署 The Graph 子图索引活动
- [ ] 更新 DefaultReputationCalculator 从链下读取
- [ ] Gas 节省: **60k per transaction**

### Phase 2: Storage Packing (Non-Breaking)
- [ ] 重构 `SBTData` 为紧凑结构
- [ ] 重构 `CommunityMembership` 为紧凑结构
- [ ] 部署新版本 v2.2
- [ ] Gas 节省: **~80k per new user**

### Phase 3: Array Optimization (Breaking Change)
- [ ] 评估实际使用：用户平均加入几个社区？
- [ ] 如果 <10: 使用固定数组
- [ ] 如果 >10: 使用 mapping
- [ ] Gas 节省: **~30-50k per membership**

---

## Total Gas Savings Estimate

| Scenario | Current | Optimized | Savings |
|----------|---------|-----------|---------|
| **First Mint** | 392k | ~270k | **122k (31%)** |
| **Add Membership** | 186k | ~110k | **76k (41%)** |
| **Record Activity** | 65k | ~5k | **60k (92%)** |
| **Paymaster Tx (with activity)** | 65k | ~5k | **60k (92%)** |

### Cost Savings (at 30 gwei)

| Operation | Current | Optimized | USD Saved |
|-----------|---------|-----------|-----------|
| First Mint | $35 | $24 | **$11** |
| Add Membership | $17 | $10 | **$7** |
| Paymaster Tx | $6 | $0.45 | **$5.55** |

**Annual Savings** (假设 10,000 用户, 每人 50 笔交易):
- First Mint: $110,000
- Paymaster: **$2,775,000** (60k × 50 × 10,000 × 30 gwei × $3000/ETH)

---

## Trade-offs

### Event-Based Activity
**Pros**:
- ✅ 92% gas 节省
- ✅ 灵活的链下分析
- ✅ 无状态膨胀

**Cons**:
- ❌ 需要链下基础设施
- ❌ 声誉计算依赖外部系统
- ❌ 初期开发成本高

### Storage Packing
**Pros**:
- ✅ 31-41% gas 节省
- ✅ 无破坏性变更
- ✅ 无外部依赖

**Cons**:
- ❌ 代码复杂度增加
- ❌ 类型限制（uint40 vs uint256）

### Fixed Arrays
**Pros**:
- ✅ 30-50k gas 节省
- ✅ 可预测的成本

**Cons**:
- ❌ 限制社区数量
- ❌ 可能需要升级机制

---

## Recommendation

**立即实施** (v2.2):
1. ✅ Storage packing (SBTData + CommunityMembership)
2. ✅ Calldata optimization
3. ⏭️  暂缓事件化（等 The Graph 部署）

**后续版本** (v2.3):
1. ✅ Event-based activity tracking
2. ✅ The Graph 子图部署
3. ✅ 外部声誉计算器

**评估后决定** (v2.4):
1. ⏸️  Array vs Mapping (需实际使用数据)
2. ⏸️  固定大小数组限制

---

**编写人**: Claude Code
**审核状态**: Pending User Review
**实施优先级**: High (可节省 $2.7M/年)
