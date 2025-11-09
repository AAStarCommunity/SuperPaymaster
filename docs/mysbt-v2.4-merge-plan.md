# MySBT v2.4.0 合并方案

**创建时间**: 2025-10-31
**目标**: 合并 MySBTWithNFTBinding 的高级 NFT 绑定功能到 MySBT v2.3.3，实现唯一白板 SBT 愿景

---

## 🎯 愿景确认

### ❌ 错误理解（两个独立 SBT）

```
场景 A: 用户在 MySBT v2.3.3 (0x3cE0AB...) 中 mint tokenId #42
场景 B: 用户在 MySBTWithNFTBinding (0xABC...) 中 mint tokenId #7

→ 两个独立的 SBT 系统，用户需要在每个社区 mint 新 SBT
```

### ✅ 正确愿景（唯一白板 SBT）

```
用户 Alice mint MySBT → tokenId #42（全局唯一白板）
├─ 加入 MyDAO 社区 → 向 #42 写入 MyDAO 成员信息
├─ 加入 GameFi 社区 → 向 #42 写入 GameFi 成员信息
├─ 绑定 Bored Ape #123 → 双模式绑定到 #42（CUSTODIAL/NON_CUSTODIAL）
├─ 退出 MyDAO → 从 #42 移除 MyDAO 信息（7天冷却期）
└─ 保留 GameFi 和 NFT 绑定

全程只有一个 SBT tokenId #42，不需要在每个社区 mint 新的 SBT
```

---

## 📋 功能对比与合并计划

| 功能模块 | MySBT v2.3.3 当前 | MySBTWithNFTBinding | MySBT v2.4.0 合并后 |
|---------|------------------|---------------------|-------------------|
| **白板 SBT** | ✅ 唯一协议核心 | ❌ 社区独立部署 | ✅ **保留唯一白板** |
| **社区成员管理** | ✅ joinCommunity/leaveCommunity | ❌ 无 | ✅ **保留** |
| **NFT 绑定模式** | ⚠️ 单一模式（简单） | ✅ 双模式（CUSTODIAL/NON_CUSTODIAL） | ✅ **升级为双模式** |
| **解绑冷却期** | ❌ 即时解绑 | ✅ 7天冷却期（request → execute） | ✅ **新增冷却期** |
| **质押递增** | ❌ 无 | ✅ 11+ 绑定需额外质押（1 stGT/个） | ✅ **新增质押递增** |
| **burnSBT 退出** | ✅ 完整退出机制 | ❌ 无 | ✅ **保留** |
| **Reputation** | ✅ 声誉计算接口 | ⚠️ 部分支持 | ✅ **保留并增强** |

---

## 🔧 具体合并步骤

### Step 1: 新增数据结构

**在 MySBT v2.3.3 中新增**：

```solidity
// ====================================
// Enums (新增)
// ====================================

/// @notice NFT binding mode
enum NFTBindingMode {
    CUSTODIAL,      // NFT transferred to contract (safer)
    NON_CUSTODIAL   // NFT stays in user wallet (flexible)
}

// ====================================
// Structs (升级)
// ====================================

/// @notice NFT binding record (升级版)
struct NFTBinding {
    address nftContract;
    uint256 nftTokenId;
    uint256 bindTime;
    bool isActive;
    NFTBindingMode mode;           // 👈 新增：绑定模式
}

/// @notice Unbind request (新增)
struct UnbindRequest {
    uint256 requestTime;
    bool pending;
}

// ====================================
// Storage (新增)
// ====================================

/// @notice Unbind cooldown period (7 days)
uint256 public constant UNBIND_COOLDOWN = 7 days;

/// @notice Extra stake required per binding after 10
uint256 public constant EXTRA_STAKE_PER_BINDING = 1 ether; // 1 stGT

/// @notice Free binding limit
uint256 public constant FREE_BINDING_LIMIT = 10;

/// @notice Unbind requests: SBT tokenId => community => UnbindRequest
mapping(uint256 => mapping(address => UnbindRequest)) public unbindRequests;

/// @notice Binding counts: SBT tokenId => total bindings
mapping(uint256 => uint256) public bindingCounts;

/// @notice Extra stake locked: user => locked amount
mapping(address => uint256) public extraStakeLocked;
```

---

### Step 2: 升级 NFT 绑定函数

**替换 `bindCommunityNFT()` 为增强版本**：

```solidity
/**
 * @notice Bind NFT to SBT with mode selection
 * @param community Community address
 * @param nftContract NFT contract address
 * @param nftTokenId NFT token ID
 * @param mode CUSTODIAL (transfer to contract) or NON_CUSTODIAL (keep in wallet)
 */
function bindCommunityNFT(
    address community,
    address nftContract,
    uint256 nftTokenId,
    NFTBindingMode mode  // 👈 新增参数
) external whenNotPaused nonReentrant {
    // ✅ 保留原有验证逻辑
    if (community == address(0)) revert InvalidAddress(community);
    if (nftContract == address(0)) revert InvalidAddress(nftContract);

    uint256 tokenId = userToSBT[msg.sender];
    if (tokenId == 0) revert NoSBTFound(msg.sender);

    // ✅ 检查是否已绑定
    if (nftBindings[tokenId][community].isActive) {
        revert CommunityAlreadyBound(tokenId, community);
    }

    // 👉 新增：验证 NFT 所有权
    IERC721 nft = IERC721(nftContract);
    if (nft.ownerOf(nftTokenId) != msg.sender) {
        revert NotNFTOwner(msg.sender, nftContract, nftTokenId);
    }

    // 👉 新增：质押递增检查
    _checkAndLockExtraStake(msg.sender, tokenId);

    // 👉 新增：根据模式处理 NFT
    if (mode == NFTBindingMode.CUSTODIAL) {
        // CUSTODIAL 模式：转移 NFT 到合约
        nft.safeTransferFrom(msg.sender, address(this), nftTokenId);
    }
    // NON_CUSTODIAL 模式：NFT 保留在用户钱包

    // ✅ 记录绑定（升级版）
    nftBindings[tokenId][community] = NFTBinding({
        nftContract: nftContract,
        nftTokenId: nftTokenId,
        bindTime: block.timestamp,
        isActive: true,
        mode: mode  // 👈 新增字段
    });

    // 👉 新增：更新绑定计数
    bindingCounts[tokenId]++;

    emit NFTBound(tokenId, community, nftContract, nftTokenId, mode);
}
```

---

### Step 3: 新增解绑冷却期机制

**新增两步解绑流程**：

```solidity
/**
 * @notice Request to unbind NFT (step 1: initiate cooldown)
 * @param community Community address
 */
function requestUnbindNFT(address community) external whenNotPaused {
    uint256 tokenId = userToSBT[msg.sender];
    if (tokenId == 0) revert NoSBTFound(msg.sender);

    NFTBinding memory binding = nftBindings[tokenId][community];
    if (!binding.isActive) {
        revert MembershipNotFound(tokenId, community);
    }

    unbindRequests[tokenId][community] = UnbindRequest({
        requestTime: block.timestamp,
        pending: true
    });

    emit UnbindRequested(tokenId, community, block.timestamp + UNBIND_COOLDOWN);
}

/**
 * @notice Execute unbind after cooldown (step 2: finalize)
 * @param community Community address
 */
function executeUnbindNFT(address community) external whenNotPaused nonReentrant {
    uint256 tokenId = userToSBT[msg.sender];
    if (tokenId == 0) revert NoSBTFound(msg.sender);

    UnbindRequest memory request = unbindRequests[tokenId][community];
    if (!request.pending) {
        revert NoUnbindRequest(tokenId, community);
    }

    uint256 elapsed = block.timestamp - request.requestTime;
    if (elapsed < UNBIND_COOLDOWN) {
        revert UnbindCooldownNotFinished(UNBIND_COOLDOWN - elapsed);
    }

    NFTBinding memory binding = nftBindings[tokenId][community];

    // 👉 根据模式返还 NFT
    if (binding.mode == NFTBindingMode.CUSTODIAL) {
        // CUSTODIAL 模式：从合约转回给用户
        IERC721(binding.nftContract).safeTransferFrom(
            address(this),
            msg.sender,
            binding.nftTokenId
        );
    }
    // NON_CUSTODIAL 模式：NFT 本就在用户钱包，无需操作

    // 清除绑定记录
    nftBindings[tokenId][community].isActive = false;
    delete unbindRequests[tokenId][community];

    // 👉 新增：更新绑定计数并释放额外质押
    bindingCounts[tokenId]--;
    _releaseExtraStake(msg.sender, tokenId);

    emit NFTUnbound(tokenId, community, binding.nftContract, binding.nftTokenId);
}
```

---

### Step 4: 新增质押递增机制

**新增内部函数**：

```solidity
/**
 * @notice Check and lock extra stake if needed
 * @dev Called during bindCommunityNFT()
 */
function _checkAndLockExtraStake(address user, uint256 tokenId) internal {
    uint256 currentBindings = bindingCounts[tokenId];

    // 前 10 个绑定免费
    if (currentBindings < FREE_BINDING_LIMIT) {
        return;
    }

    // 11+ 绑定需要额外质押
    uint256 userStake = GTOKEN_STAKING.getUserStake(user);
    uint256 requiredExtra = (currentBindings - FREE_BINDING_LIMIT + 1) * EXTRA_STAKE_PER_BINDING;
    uint256 currentExtra = extraStakeLocked[user];

    if (userStake < requiredExtra + currentExtra) {
        revert InsufficientStakeForBinding(
            requiredExtra + currentExtra,
            userStake
        );
    }

    // 锁定额外质押
    GTOKEN_STAKING.lockStake(user, EXTRA_STAKE_PER_BINDING);
    extraStakeLocked[user] += EXTRA_STAKE_PER_BINDING;

    emit ExtraStakeLocked(user, tokenId, EXTRA_STAKE_PER_BINDING);
}

/**
 * @notice Release extra stake after unbinding
 * @dev Called during executeUnbindNFT()
 */
function _releaseExtraStake(address user, uint256 tokenId) internal {
    uint256 currentBindings = bindingCounts[tokenId];

    // 如果绑定数降回 10 以下，释放额外质押
    if (currentBindings >= FREE_BINDING_LIMIT) {
        return;
    }

    uint256 toRelease = EXTRA_STAKE_PER_BINDING;
    if (extraStakeLocked[user] >= toRelease) {
        GTOKEN_STAKING.unlockStake(user, toRelease);
        extraStakeLocked[user] -= toRelease;

        emit ExtraStakeReleased(user, tokenId, toRelease);
    }
}
```

---

### Step 5: 升级 burnSBT 退出机制

**在 burnSBT() 中新增 NFT 检查**：

```solidity
function burnSBT(uint256 tokenId) external whenNotPaused nonReentrant {
    // ✅ 保留原有验证逻辑
    if (ownerOf(tokenId) != msg.sender) {
        revert NotSBTOwner(msg.sender, tokenId);
    }

    address user = msg.sender;

    // 👉 新增：检查是否有未解绑的 NFT
    if (bindingCounts[tokenId] > 0) {
        revert MustUnbindAllNFTsFirst(tokenId, bindingCounts[tokenId]);
    }

    // ✅ 保留原有退出逻辑
    // - 退出所有社区
    // - 解锁质押
    // - 收取 exitFee
    // - burn SBT token

    _burn(tokenId);

    emit SBTBurned(user, tokenId);
}
```

---

## 🗑️ 废弃组件

### 合并后需要废弃的合约和组件：

1. ❌ **MySBTWithNFTBinding.sol** - 功能已合并到 MySBT v2.4.0
2. ❌ **MySBTFactory.sol** - 不再需要社区独立部署 SBT
3. ❌ **MySBTFactory 部署地址** - `0x7ffd4b7db8a60015fad77530892505bd69c6b8ec`

### 保留组件：

1. ✅ **MySBT v2.4.0** - 唯一白板 SBT（升级版）
2. ✅ **Registry v2.1.3** - 社区注册系统
3. ✅ **GTokenStaking v2** - 质押管理
4. ✅ **DefaultReputationCalculator** - 声誉计算（可选）

---

## 📝 测试计划

### 新增测试用例：

```solidity
// test/MySBT_v2.4.t.sol

function test_DualModeNFTBinding() public {
    // 测试 CUSTODIAL 和 NON_CUSTODIAL 两种模式
}

function test_UnbindCooldownPeriod() public {
    // 测试 7天冷却期机制
}

function test_ExtraStakeLocking() public {
    // 测试 11+ 绑定的质押递增
}

function test_BurnWithPendingNFTs() public {
    // 测试有未解绑 NFT 时 burn 应该失败
}

function test_SingleSBTMultipleCommunities() public {
    // 测试用户只有一个 SBT，可加入多个社区
}
```

---

## 🚀 部署计划

### Phase 1: 开发与测试

1. ✅ 创建 `MySBT_v2.4.0.sol`
2. ✅ 合并所有功能
3. ✅ 编写完整测试
4. ✅ 运行测试：`forge test`

### Phase 2: 部署新合约

```bash
# 部署 MySBT v2.4.0
forge script script/DeployMySBT_v2.4.0.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

### Phase 3: 配置

```bash
# 1. 配置 GTokenStaking locker
cast send $GTOKEN_STAKING "configureLocker(address,bool,uint256,address[],address[],address)" \
  $MYSBT_V2_4_0 true 0.1ether [] [] 0x0

# 2. 设置 Registry
cast send $MYSBT_V2_4_0 "setRegistry(address)" $REGISTRY
```

### Phase 4: 更新所有依赖

1. 更新 `@aastar/shared-config` 中的 MySBT 地址
2. 更新文档中的合约地址
3. 废弃 MySBTFactory 相关文档

---

## 📊 对比总结

| 项目 | v2.3.3（旧） | v2.4.0（新） | 改进 |
|------|-------------|-------------|------|
| **SBT 数量** | 1个（协议核心） | 1个（唯一白板） | ✅ 保持唯一 |
| **社区成员** | ✅ 支持 | ✅ 支持 | ✅ 保留 |
| **NFT 绑定** | ⚠️ 单一模式 | ✅ 双模式（CUSTODIAL/NON_CUSTODIAL） | ✅ 升级 |
| **解绑冷却** | ❌ 即时 | ✅ 7天冷却期 | ✅ 新增安全机制 |
| **质押递增** | ❌ 无 | ✅ 11+ 绑定需额外质押 | ✅ 防止滥用 |
| **退出机制** | ✅ burnSBT | ✅ burnSBT（增强检查） | ✅ 更安全 |

---

## ✅ 验收标准

1. ✅ 用户只需 mint 一次 SBT（tokenId 唯一）
2. ✅ 用户可加入/退出多个社区（数据都写入同一个 tokenId）
3. ✅ NFT 绑定支持双模式（CUSTODIAL/NON_CUSTODIAL）
4. ✅ 解绑需要 7天冷却期
5. ✅ 11+ 绑定需要额外质押
6. ✅ burnSBT 时必须先解绑所有 NFT
7. ✅ 所有测试通过
8. ✅ 文档更新完整

---

**下一步**：开始实现 MySBT v2.4.0 合约代码
