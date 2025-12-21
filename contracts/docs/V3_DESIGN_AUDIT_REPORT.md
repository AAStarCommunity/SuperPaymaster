# Mycelium Protocol V3 设计审查报告

**日期**: 2025-11-28  
**审查人**: Claude + User  
**目标**: 验证 v3 实现是否符合预期

---

## 📋 用户需求清单

### 1. Registry 为唯一交互入口
**需求**: 所有操作都通过 Registry 合约,Registry 调用 MySBT 和 GTokenStaking

**当前状态**: ✅ 部分实现
- ✅ Registry 调用 GTokenStaking.lockStake()
- ✅ MySBT 移除了 userMint/mintWithAutoStake
- ❌ **缺失**: MySBT 没有 Registry 授权机制
- ❌ **缺失**: Registry 没有调用 MySBT.airdropMint()

**问题分析**:
```solidity
// 当前: MySBT 只检查是否是 registered community
modifier onlyReg() {
    require(_isValid(msg.sender));  // 任何社区都可以调用
    _;
}

// 应该: 只允许 Registry 合约调用
modifier onlyRegistry() {
    require(msg.sender == REGISTRY, "Only Registry");
    _;
}
```

**影响**: 当前社区仍可以直接调用 MySBT.airdropMint(),绕过 Registry

---

### 2. 所有 Role 注册后都有 SBT
**需求**: 每个角色注册时自动 mint SBT,未来绑定 ENS

**当前状态**: ❌ **未实现**

**问题分析**:
```solidity
// Registry_v3_0_0.sol - registerRole()
function registerRole(bytes32 roleId, address user, bytes calldata roleData) {
    // ... validation
    hasRole[roleId][user] = true;
    roleStakes[roleId][user] = stakeAmount;
    
    // ❌ 缺失: 没有调用 MySBT.mint()
    GTOKEN_STAKING.lockStake(user, roleId, stakeAmount, config.entryBurn);
    emit RoleGranted(roleId, user, stakeAmount);
}
```

**应该**:
```solidity
function registerRole(bytes32 roleId, address user, bytes calldata roleData) {
    // ... validation
    hasRole[roleId][user] = true;
    
    // ✅ Mint SBT for user
    uint256 sbtTokenId = MYSBT.mintForRole(user, roleId, roleData);
    
    // Lock stake
    GTOKEN_STAKING.lockStake(user, roleId, stakeAmount, config.entryBurn);
    
    emit RoleGranted(roleId, user, stakeAmount, sbtTokenId);
}
```

**影响**: 当前注册角色后用户没有 SBT,无法绑定链上身份

---

### 3. 动态 Fee 配置
**需求**: 所有 role 的 fee (stake, lock, burn, exitFee) 可修改,可动态增加 role

**当前状态**: ✅ 已实现

**验证**:
```solidity
// Registry_v3_0_0.sol
struct RoleConfig {
    uint256 minStake;
    uint256 entryBurn;      // ✅ Entry burn
    uint256 exitFeePercent; // ✅ Exit fee
    uint256 minExitFee;
    bool allowPermissionlessMint;
    bool isActive;
}

// ✅ 动态配置
function configureRole(bytes32 roleId, RoleConfig calldata config) 
    external onlyOwner {
    roleConfigs[roleId] = config;
    emit RoleConfigured(roleId, ...);
}
```

**评价**: ✅ 完全符合需求

---

### 4. 完整账目记录
**需求**: 所有账目都有记录

**当前状态**: ✅ 部分实现

**已有**:
```solidity
// ✅ BurnRecord tracking
struct BurnRecord {
    bytes32 roleId;
    uint256 amount;
    uint256 timestamp;
    string purpose;
}
BurnRecord[] public burnHistory;
mapping(address => uint256[]) public userBurnHistory;
```

**缺失**:
- ❌ 没有 Entry burn 记录
- ❌ 没有 Stake lock 记录
- ❌ 没有 Fee 收取记录

**建议增加**:
```solidity
struct AccountRecord {
    bytes32 roleId;
    address user;
    uint256 stakeAmount;
    uint256 entryBurn;
    uint256 exitFee;
    uint256 timestamp;
    string operation; // "REGISTER" | "EXIT" | "SLASH"
}
AccountRecord[] public accountHistory;
```

---

### 5. 自助 Register 流程优化
**需求**: approve + transfer + stake + lock + burn + record + mint 合一

**当前状态**: ❌ **未优化**

**问题分析**:
```solidity
// 当前流程 (用户需要多次交易)
1. user: GTOKEN.approve(Registry, amount)
2. user: GTOKEN.approve(GTokenStaking, amount) 
3. user: Registry.registerRole(...)
   - Registry: GTOKEN.transferFrom(user, burn)
   - Registry: GTokenStaking.lockStake()
   - GTokenStaking: GTOKEN.transferFrom(user, stake)
```

**Gas 问题**: 
- 2次 approve (各 ~45k gas)
- 2次 transferFrom (~30k gas each)
- 总计 ~150k gas overhead

**优化方案: Permit + Multicall**
```solidity
function registerRoleWithPermit(
    bytes32 roleId,
    address user,
    bytes calldata roleData,
    uint256 deadline,
    uint8 v, bytes32 r, bytes32 s
) external {
    // ✅ 使用 ERC20Permit 一次性授权
    GTOKEN.permit(user, address(this), totalAmount, deadline, v, r, s);
    
    // ✅ 一次性转账
    GTOKEN.transferFrom(user, address(this), totalAmount);
    
    // ✅ 内部分配
    _processBurn(entryBurn);
    _processStake(user, roleId, stakeAmount);
    _mintSBT(user, roleId);
}
```

**Gas 节省**: ~60k gas (40% reduction)

---

### 6. Reputation 独立合约
**需求**: 
- SBT 和 Reputation 绑定
- 注销 SBT,reputation 不消失
- Reputation 基于链上行为,隐私记录为分数
- 分数规则由社区确定

**当前状态**: ❌ **未实现**

**设计建议**:

```solidity
// ReputationOracle.sol
contract ReputationOracle {
    // SBT tokenId -> Reputation score
    mapping(uint256 => uint256) public reputationScore;
    
    // SBT tokenId -> Activity records (encrypted)
    mapping(uint256 => bytes32[]) private activityHashes;
    
    // Community-defined scoring rules
    mapping(address => ScoringRule) public communityRules;
    
    struct ScoringRule {
        uint256 baseScore;
        uint256 activityBonus;
        uint256 decayRate;
        uint256 maxScore;
    }
    
    // ✅ Reputation survives SBT burn
    function getReputation(uint256 sbtTokenId) 
        external view returns (uint256) {
        return reputationScore[sbtTokenId];
    }
    
    // ✅ Privacy-preserving activity recording
    function recordActivity(
        uint256 sbtTokenId,
        bytes32 activityHash  // keccak256(abi.encode(activity, timestamp))
    ) external onlyAuthorized {
        activityHashes[sbtTokenId].push(activityHash);
        _updateScore(sbtTokenId);
    }
}
```

---

## 🔍 当前 v3 实现缺陷总结

### Critical Issues (必须修复)

1. **MySBT 授权机制缺失**
   - 影响: 社区可以绕过 Registry 直接 mint SBT
   - 修复: 添加 `onlyRegistry` modifier

2. **Registry 不 mint SBT**
   - 影响: 注册角色后用户没有 SBT
   - 修复: registerRole() 中调用 MySBT.mintForRole()

3. **账目记录不完整**
   - 影响: 无法审计 entry burn, stake lock
   - 修复: 添加 AccountRecord 结构体

### High Priority (建议修复)

4. **Gas 未优化**
   - 影响: 用户需要 2次 approve + 多次交易
   - 修复: 使用 ERC20Permit + multicall

5. **Reputation 合约缺失**
   - 影响: 无法实现社区声誉系统
   - 修复: 创建 ReputationOracle.sol

### Medium Priority (可选)

6. **ENS 支持缺失**
   - 影响: SBT 无法绑定可读名称
   - 修复: 未来集成 ENS resolver

---

## 📊 v3 设计符合度评分

| 需求项 | 符合度 | 评分 | 说明 |
|--------|--------|------|------|
| Registry 唯一入口 | 部分 | 6/10 | 缺少 MySBT 授权 |
| 所有 Role 有 SBT | 否 | 0/10 | ❌ Registry 不 mint SBT |
| 动态 Fee 配置 | 是 | 10/10 | ✅ 完全实现 |
| 完整账目记录 | 部分 | 5/10 | 只有 burn 记录 |
| 自助 Register 优化 | 否 | 2/10 | ❌ 未使用 Permit |
| Reputation 独立 | 否 | 0/10 | ❌ 合约不存在 |

**总体评分**: **3.8/10** ⚠️

---

## ✅ 优化技术方案

### 方案 1: Minimal Fix (最小修复)

**目标**: 修复 Critical Issues

```solidity
// 1. MySBT 授权
contract MySBT_v3 {
    address public immutable REGISTRY;
    
    modifier onlyRegistry() {
        require(msg.sender == REGISTRY, "Only Registry");
        _;
    }
    
    // ✅ 只允许 Registry 调用
    function mintForRole(address user, bytes32 roleId, bytes calldata data) 
        external onlyRegistry returns (uint256) {
        // ... mint logic
    }
}

// 2. Registry mint SBT
contract Registry_v3_0_0 {
    function registerRole(bytes32 roleId, address user, bytes calldata roleData) {
        // ... validation
        
        // ✅ Mint SBT
        uint256 sbtTokenId = MYSBT.mintForRole(user, roleId, roleData);
        
        // ✅ Lock stake
        GTOKEN_STAKING.lockStake(user, roleId, stakeAmount, config.entryBurn);
        
        // ✅ Record account
        _recordAccount(roleId, user, stakeAmount, config.entryBurn, "REGISTER");
        
        emit RoleGranted(roleId, user, stakeAmount, sbtTokenId);
    }
}
```

**Gas 影响**: +~5k gas (SBT mint overhead)

---

### 方案 2: Gas Optimized (Gas 优化)

**目标**: Permit + Multicall

```solidity
contract Registry_v3_0_0 {
    function registerRoleWithPermit(
        bytes32 roleId,
        address user,
        bytes calldata roleData,
        PermitData calldata permit
    ) external nonReentrant {
        RoleConfig memory config = roleConfigs[roleId];
        uint256 totalAmount = config.minStake + config.entryBurn;
        
        // ✅ One-time permit (saves 45k gas)
        GTOKEN.permit(user, address(this), totalAmount, 
            permit.deadline, permit.v, permit.r, permit.s);
        
        // ✅ Single transferFrom (saves 30k gas vs 2 transfers)
        GTOKEN.transferFrom(user, address(this), totalAmount);
        
        // ✅ Internal distribution
        if (config.entryBurn > 0) {
            GTOKEN.transfer(BURN_ADDRESS, config.entryBurn);
        }
        
        // ✅ Approve staking (saves user approval)
        GTOKEN.approve(address(GTOKEN_STAKING), config.minStake);
        
        // ✅ Rest of flow
        uint256 sbtTokenId = MYSBT.mintForRole(user, roleId, roleData);
        GTOKEN_STAKING.lockStake(user, roleId, config.minStake, config.entryBurn);
        
        _recordAccount(...);
        emit RoleGranted(roleId, user, config.minStake, sbtTokenId);
    }
}
```

**Gas 节省**: ~75k gas (50% reduction)

---

### 方案 3: Full Implementation (完整实现)

**增加 Reputation 合约**

```solidity
// ReputationOracle.sol
contract ReputationOracle is Ownable {
    IMySBT public immutable MYSBT;
    
    // sbtTokenId -> reputation score
    mapping(uint256 => uint256) public reputation;
    
    // community -> scoring rule
    mapping(address => ScoringRule) public rules;
    
    struct ScoringRule {
        uint256 baseScore;        // 初始分数
        uint256 activityBonus;    // 每次活动加分
        uint256 decayRate;        // 衰减率 (per day)
        uint256 maxScore;         // 最高分数
    }
    
    // ✅ Record encrypted activity
    function recordActivity(
        uint256 sbtTokenId,
        bytes32 activityHash
    ) external {
        require(MYSBT.ownerOf(sbtTokenId) != address(0), "SBT not exists");
        
        address community = msg.sender;
        ScoringRule memory rule = rules[community];
        
        // ✅ Privacy: only store hash
        emit ActivityRecorded(sbtTokenId, community, activityHash, block.timestamp);
        
        // ✅ Update score
        uint256 newScore = reputation[sbtTokenId] + rule.activityBonus;
        if (newScore > rule.maxScore) newScore = rule.maxScore;
        
        reputation[sbtTokenId] = newScore;
    }
    
    // ✅ Reputation survives SBT burn
    function getReputation(uint256 sbtTokenId) 
        external view returns (uint256) {
        return reputation[sbtTokenId];
    }
}
```

---

## 📋 前端代码影响分析

### Breaking Changes (不向前兼容的变更)

#### 1. MySBT 直接调用被禁止

**变更前 (v2)**:
```javascript
// ❌ 不再允许
await mysbt.userMint(communityAddress, metadata)
await mysbt.mintWithAutoStake(communityAddress, metadata)
```

**变更后 (v3)**:
```javascript
// ✅ 必须通过 Registry
const roleData = ethers.utils.defaultAbiCoder.encode(
    ["string"],
    [metadata]
)
await registry.registerRole(ROLE_ENDUSER, userAddress, roleData)
```

**影响范围**:
- ✅ 已修改: `deprecated/scripts/testSbtMint.js`
- ✅ 已修改: `deprecated/scripts/test-prepare-assets.js`
- ⚠️ 需检查: 所有前端 UI 代码

---

#### 2. GTokenStaking API 变化

**变更前 (v2)**:
```javascript
await gTokenStaking.lockStake(user, amount, "MySBT registration")
await gTokenStaking.unlockStake(user, amount)
```

**变更后 (v3)**:
```javascript
// ❌ 前端不应直接调用 GTokenStaking
// ✅ 通过 Registry 间接调用
await registry.registerRole(roleId, user, roleData) // 内部调用 lockStake
await registry.exitRole(roleId)                     // 内部调用 unlockStake
```

**影响**: 前端移除所有 GTokenStaking 直接调用

---

#### 3. 新增 Permit 支持 (可选)

**Gas 优化版本**:
```javascript
// ✅ 使用 Permit 节省 gas
const deadline = Math.floor(Date.now() / 1000) + 3600
const signature = await signer._signTypedData(
    domain,
    {Permit: [...]},
    {owner: user, spender: registry.address, value: totalAmount, deadline}
)
const {v, r, s} = ethers.utils.splitSignature(signature)

// ✅ 一次交易完成
await registry.registerRoleWithPermit(roleId, user, roleData, {
    deadline, v, r, s
})
```

---

### 需要遍历修改的前端文件

#### JavaScript/TypeScript
```bash
# 1. 搜索所有 MySBT 直接调用
rg "mysbt\.(userMint|mintWithAutoStake|mintOrAddMembership)" --type js

# 2. 搜索所有 GTokenStaking 调用
rg "gTokenStaking\.(lockStake|unlockStake)" --type js

# 3. 搜索所有 registerCommunity 调用
rg "registry\.(registerCommunity|registerEndUser)" --type js
```

#### ABI 更新
```javascript
// abis/Registry_v3.json - 新增
{
  "name": "registerRole",
  "inputs": [
    {"type": "bytes32", "name": "roleId"},
    {"type": "address", "name": "user"},
    {"type": "bytes", "name": "roleData"}
  ],
  "outputs": [{"type": "uint256", "name": "sbtTokenId"}]
}

// abis/MySBT_v3.json - 移除
{
  "name": "userMint",         // ❌ Removed
  "name": "mintWithAutoStake" // ❌ Removed
}
```

---

## 🎯 建议实施步骤

### Phase 1: Critical Fixes (1-2 days)
1. ✅ MySBT 添加 `onlyRegistry` modifier
2. ✅ Registry.registerRole() 调用 MySBT.mintForRole()
3. ✅ 添加 AccountRecord 记录
4. ✅ 编译测试

### Phase 2: Gas Optimization (2-3 days)
5. ✅ 实现 registerRoleWithPermit()
6. ✅ Gas 基准测试
7. ✅ 前端集成 Permit

### Phase 3: Reputation System (3-5 days)
8. ✅ 设计 ReputationOracle.sol
9. ✅ 实现隐私保护机制
10. ✅ 社区规则配置

### Phase 4: Frontend Migration (2-3 days)
11. ✅ 遍历前端代码
12. ✅ 更新所有 ABI 调用
13. ✅ 集成测试

---

## 📝 变更影响记录

| 变更项 | 影响范围 | 影响程度 | 迁移成本 |
|--------|----------|----------|----------|
| MySBT 授权 | 社区直接调用 | 高 | 中 (需修改前端) |
| Register mint SBT | 所有注册流程 | 高 | 低 (后端自动) |
| Permit 支持 | Gas 优化 | 中 | 中 (前端可选) |
| Reputation 合约 | 新增功能 | 低 | 低 (独立模块) |

---

**审查结论**: 
- 当前 v3 实现 **不完全符合** 预期
- 需要 **Critical Fixes** 才能达到设计目标
- 建议采用 **方案 2 (Gas Optimized)** 作为最终实现

**下一步**: 实施 Phase 1 修复

