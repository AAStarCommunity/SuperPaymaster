# MySBT v2.3 - Security Fixes Implementation Guide

**Date**: 2025-10-28
**Version**: v2.2 → v2.3 (Security Enhanced)
**Status**: Ready to implement

---

## 修复清单

### 🔴 High Priority (Must Fix)

#### H-1: 添加速率限制到 `recordActivity`

**当前问题**: 无速率限制，可被spam攻击
**Gas影响**: +5k
**修复难度**: ⭐⭐☆☆☆

**代码修改**:

```solidity
// 1. 添加存储
/// @notice Last activity time: tokenId => community => timestamp
mapping(uint256 => mapping(address => uint256)) public lastActivityTime;

/// @notice Minimum interval between activities (5 minutes)
uint256 public constant MIN_ACTIVITY_INTERVAL = 5 minutes;

// 2. 修改 recordActivity
function recordActivity(address user) external override whenNotPaused {
    // Revert instead of silent fail for better tracking
    if (!_isValidCommunity(msg.sender)) {
        revert CommunityNotRegistered(msg.sender);
    }

    uint256 tokenId = userToSBT[user];
    if (tokenId == 0) revert NoSBTFound(user);

    uint256 idx = membershipIndex[tokenId][msg.sender];
    if (idx >= _memberships[tokenId].length ||
        _memberships[tokenId][idx].community != msg.sender) {
        revert MembershipNotFound(tokenId, msg.sender);
    }

    // ✅ Rate limiting
    uint256 lastActivity = lastActivityTime[tokenId][msg.sender];
    if (block.timestamp < lastActivity + MIN_ACTIVITY_INTERVAL) {
        revert ActivityTooFrequent(tokenId, msg.sender, lastActivity + MIN_ACTIVITY_INTERVAL);
    }

    lastActivityTime[tokenId][msg.sender] = block.timestamp;

    // Emit event
    uint256 currentWeek = block.timestamp / 1 weeks;
    emit ActivityRecorded(tokenId, msg.sender, currentWeek, block.timestamp);
}

// 3. 添加错误定义
error ActivityTooFrequent(uint256 tokenId, address community, uint256 nextAllowedTime);
```

---

#### H-2: 验证NFT所有权 (实时)

**当前问题**: NFT转移后仍保留bonus
**Gas影响**: +3k per reputation query
**修复难度**: ⭐⭐⭐☆☆

**代码修改**:

```solidity
function _calculateDefaultReputation(uint256 tokenId, address community)
    internal
    view
    returns (uint256 score)
{
    // Base score
    score = BASE_REPUTATION;

    // ✅ Verify NFT ownership in real-time
    NFTBinding memory binding = nftBindings[tokenId][community];
    if (binding.isActive) {
        try IERC721(binding.nftContract).ownerOf(binding.nftTokenId) returns (address owner) {
            if (owner == sbtData[tokenId].holder) {
                score += NFT_BONUS;
            }
            // If owner changed, NFT bonus is automatically removed
        } catch {
            // NFT contract error or NFT burned, no bonus
        }
    }

    return score;
}
```

---

#### M-1: 添加 Pausable 机制

**修复难度**: ⭐☆☆☆☆

**代码修改**:

```solidity
// 1. 继承 Pausable
import "@openzeppelin/contracts/utils/Pausable.sol";

contract MySBT_v2_1 is ERC721, Pausable, ReentrancyGuard, IMySBT {

// 2. 添加 whenNotPaused 到关键函数
function mintOrAddMembership(address user, string calldata metadata)
    external
    override
    whenNotPaused // ✅ Add this
    onlyRegisteredCommunity
    nonReentrant
    returns (uint256 tokenId, bool isNewMint)
{
    // ...
}

function bindCommunityNFT(address community, address nftContract, uint256 nftTokenId)
    external
    whenNotPaused // ✅ Add this
    nonReentrant
{
    // ...
}

function recordActivity(address user) external override whenNotPaused {
    // ...
}

// 3. 添加 pause/unpause 函数
function pause() external onlyDAO {
    _pause();
    emit ContractPaused(msg.sender, block.timestamp);
}

function unpause() external onlyDAO {
    _unpause();
    emit ContractUnpaused(msg.sender, block.timestamp);
}

// 4. 添加事件
event ContractPaused(address indexed by, uint256 timestamp);
event ContractUnpaused(address indexed by, uint256 timestamp);
```

---

### 🟡 Medium Priority (Recommended)

#### M-2: 增强事件数据

**代码修改**:

```solidity
// 1. 更新事件定义
event ActivityRecorded(
    uint256 indexed tokenId,
    address indexed community,
    uint256 week,
    uint256 timestamp,
    bytes32 activityType,  // ✅ New: "transaction", "governance", "social"
    bytes data             // ✅ New: Additional metadata
);

// 2. 更新函数签名
function recordActivity(
    address user,
    bytes32 activityType,   // ✅ New parameter
    bytes calldata data     // ✅ New parameter
) external override whenNotPaused {
    // ... validation

    emit ActivityRecorded(
        tokenId,
        msg.sender,
        currentWeek,
        block.timestamp,
        activityType,
        data
    );
}

// 3. Paymaster调用示例
mySBT.recordActivity(
    user,
    bytes32("transaction"),  // Activity type
    abi.encode(txHash, gasUsed)  // Additional data
);
```

---

#### M-4: 输入验证

**代码修改**:

```solidity
function mintOrAddMembership(address user, string calldata metadata)
    external
    override
    whenNotPaused
    onlyRegisteredCommunity
    nonReentrant
    returns (uint256 tokenId, bool isNewMint)
{
    // ✅ Input validation
    if (user == address(0)) revert InvalidAddress(user);
    if (bytes(metadata).length == 0) revert InvalidParameter("metadata empty");
    if (bytes(metadata).length > 1024) revert InvalidParameter("metadata too long");

    // ... rest of function
}

function bindCommunityNFT(address community, address nftContract, uint256 nftTokenId)
    external
    whenNotPaused
    nonReentrant
{
    // ✅ Input validation
    if (community == address(0)) revert InvalidAddress(community);
    if (nftContract == address(0)) revert InvalidAddress(nftContract);

    // ... rest of function
}
```

---

### 🟢 Low Priority (Nice to Have)

#### L-1: 版本追踪

```solidity
string public constant VERSION = "2.3.0";
uint256 public constant VERSION_CODE = 230;

event ContractUpgraded(string oldVersion, string newVersion, uint256 timestamp);
```

#### L-3: Admin事件

```solidity
event RegistryUpdated(address indexed oldRegistry, address indexed newRegistry, uint256 timestamp);
event MinLockAmountUpdated(uint256 oldAmount, uint256 newAmount, uint256 timestamp);
event MintFeeUpdated(uint256 oldFee, uint256 newFee, uint256 timestamp);
event DAOMultisigUpdated(address indexed oldDAO, address indexed newDAO, uint256 timestamp);

function setRegistry(address registry) external onlyDAO {
    if (registry == address(0)) revert InvalidAddress(registry);
    address oldRegistry = REGISTRY;
    REGISTRY = registry;
    emit RegistryUpdated(oldRegistry, registry, block.timestamp);
}

function setMinLockAmount(uint256 amount) external onlyDAO {
    uint256 oldAmount = minLockAmount;
    minLockAmount = amount;
    emit MinLockAmountUpdated(oldAmount, amount, block.timestamp);
}

function setMintFee(uint256 fee) external onlyDAO {
    uint256 oldFee = mintFee;
    mintFee = fee;
    emit MintFeeUpdated(oldFee, fee, block.timestamp);
}

function setDAOMultisig(address newDAO) external onlyDAO {
    if (newDAO == address(0)) revert InvalidAddress(newDAO);
    address oldDAO = daoMultisig;
    daoMultisig = newDAO;
    emit DAOMultisigUpdated(oldDAO, newDAO, block.timestamp);
}
```

---

## 测试更新

### 新增测试用例

```solidity
// Test rate limiting
function test_RecordActivity_RateLimiting() public {
    vm.prank(community1);
    sbt.mintOrAddMembership(user1, "ipfs://metadata1");

    // First activity - should succeed
    vm.prank(community1);
    sbt.recordActivity(user1);

    // Second activity immediately - should fail
    vm.prank(community1);
    vm.expectRevert(abi.encodeWithSelector(
        IMySBT.ActivityTooFrequent.selector,
        1,
        community1,
        block.timestamp + 5 minutes
    ));
    sbt.recordActivity(user1);

    // After 5 minutes - should succeed
    vm.warp(block.timestamp + 5 minutes);
    vm.prank(community1);
    sbt.recordActivity(user1);
}

// Test NFT ownership verification
function test_Reputation_NFTTransferred() public {
    // Mint SBT and bind NFT
    vm.prank(community1);
    sbt.mintOrAddMembership(user1, "ipfs://metadata1");

    nft.mint(user1, 1);
    vm.prank(user1);
    sbt.bindCommunityNFT(community1, address(nft), 1);

    // Reputation with NFT = 20 + 3 = 23
    assertEq(sbt.getCommunityReputation(user1, community1), 23);

    // Transfer NFT away
    vm.prank(user1);
    nft.transferFrom(user1, user2, 1);

    // Reputation without NFT = 20
    assertEq(sbt.getCommunityReputation(user1, community1), 20);
}

// Test pause mechanism
function test_Pause_BlocksOperations() public {
    // Pause contract
    vm.prank(dao);
    sbt.pause();

    // Minting should fail
    vm.prank(community1);
    vm.expectRevert("Pausable: paused");
    sbt.mintOrAddMembership(user1, "ipfs://metadata1");

    // Unpause
    vm.prank(dao);
    sbt.unpause();

    // Minting should succeed
    vm.prank(community1);
    (uint256 tokenId,) = sbt.mintOrAddMembership(user1, "ipfs://metadata1");
    assertEq(tokenId, 1);
}
```

---

## Gas影响分析

| 修复 | Gas影响 | 值得吗？ |
|------|---------|----------|
| H-1: 速率限制 | +5k | ✅ 安全 > Gas |
| H-2: NFT验证 | +3k | ✅ 正确性关键 |
| M-1: Pausable | +2k | ✅ 紧急停止必需 |
| M-4: 输入验证 | +1k | ✅ 防止错误输入 |
| L-3: 事件 | +0.5k | ✅ 可观测性 |
| **总计** | **+11.5k** | ✅ 可接受 |

**recordActivity 最终gas**: 34k + 5k = **~39k** (仍比v2.1的65k省40%)

---

## 实施步骤

### Step 1: 创建新文件 (推荐)

```bash
# 保留 v2.1 作为参考
cp src/paymasters/v2/tokens/MySBT_v2.1.sol \
   src/paymasters/v2/tokens/MySBT_v2.3.sol

# 在 v2.3 中应用所有修复
```

### Step 2: 应用修复

按优先级顺序应用：
1. ✅ 导入 Pausable
2. ✅ 添加 lastActivityTime mapping
3. ✅ 修改 recordActivity 添加速率限制
4. ✅ 修改 _calculateDefaultReputation 添加NFT验证
5. ✅ 所有关键函数添加 whenNotPaused
6. ✅ 添加 pause/unpause 函数
7. ✅ 添加输入验证
8. ✅ 添加管理员事件

### Step 3: 更新测试

```bash
# 复制测试文件
cp contracts/test/MySBT_v2.1.t.sol \
   contracts/test/MySBT_v2.3.t.sol

# 添加新测试用例
```

### Step 4: 运行测试

```bash
forge test --match-path contracts/test/MySBT_v2.3.t.sol -vv
```

### Step 5: Gas报告

```bash
forge test --match-path contracts/test/MySBT_v2.3.t.sol --gas-report
```

---

## 兼容性

### 与 v2.2 的区别

| 特性 | v2.2 | v2.3 |
|------|------|------|
| 事件驱动 | ✅ | ✅ |
| 速率限制 | ❌ | ✅ |
| NFT实时验证 | ❌ | ✅ |
| Pausable | ❌ | ✅ |
| 输入验证 | 部分 | ✅ 完整 |
| 管理员事件 | 部分 | ✅ 完整 |

### The Graph Subgraph

需要更新 mapping.ts 以处理新的 ActivityRecorded 事件参数：

```typescript
// 更新事件handler签名
export function handleActivityRecorded(event: ActivityRecorded): void {
  let activity = new Activity(id);
  activity.tokenId = event.params.tokenId;
  activity.community = event.params.community;
  activity.week = event.params.week;
  activity.timestamp = event.params.timestamp;
  activity.activityType = event.params.activityType.toString(); // ✅ New
  activity.metadata = event.params.data; // ✅ New
  activity.save();
}
```

---

## 部署建议

### Testnet (Sepolia)

```bash
# 1. 部署 v2.3
forge script script/DeployMySBT_v2.3.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify

# 2. 测试所有功能
# 3. 验证gas消耗
# 4. 测试pause/unpause
# 5. 测试速率限制
```

### Mainnet

**前置条件**:
- [ ] Sepolia测试完成
- [ ] 外部审计通过 (Trail of Bits/OpenZeppelin)
- [ ] Bug Bounty 运行2周无严重问题
- [ ] 社区投票通过

---

## 总结

### v2.3 改进

✅ **安全性**: 速率限制 + NFT验证 + Pausable
✅ **可观测性**: 完整事件 + 管理员日志
✅ **健壮性**: 输入验证 + 错误处理
✅ **Gas效率**: 仍比v2.1省40%

### 下一步

1. **本周**: 实施v2.3修复
2. **下周**: Sepolia部署 + 测试
3. **2周后**: 准备审计
4. **1个月后**: 主网部署

---

**Status**: Ready to implement
**Estimated Time**: 2-3 days
**Test Coverage Target**: >95%
**Gas Increase**: +11.5k (acceptable for security)
