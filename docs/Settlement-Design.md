# Settlement Contract Design Document

**Version**: 2.0  
**Last Updated**: 2025-01-05  
**Status**: 🔄 Redesigning with proper state tracking

---

## 🎯 核心需求

### 功能需求
1. **链上记账** - Paymaster 记录用户的 gas 费用
2. **状态跟踪** - 追踪每笔费用的支付状态
3. **批量结算** - 链下转账后批量确认
4. **授权验证** - 只有注册在 SuperPaymaster 的 Paymaster 能记账

### 非功能需求
1. **安全性** - Reentrancy保护、权限控制
2. **可追溯性** - 完整的事件日志
3. **Gas优化** - 批量操作节省gas
4. **可扩展性** - 支持多种支付方式

---

## 📊 数据结构设计

### FeeRecord 结构

每笔费用记录应包含完整的生命周期信息:

```solidity
enum FeeStatus {
    Pending,      // 0 - 已记账，待支付
    Settled,      // 1 - 链下已转账，链上已确认
    Disputed,     // 2 - 有争议（可选，未来扩展）
    Cancelled     // 3 - 已取消（可选，未来扩展）
}

struct FeeRecord {
    uint256 id;              // 唯一记录ID
    address paymaster;       // 记账的Paymaster地址
    address user;            // 用户地址
    address token;           // Token地址（PNT）
    uint256 amount;          // 费用金额（wei）
    uint256 timestamp;       // 记账时间戳
    FeeStatus status;        // 当前状态
    bytes32 userOpHash;      // 关联的UserOperation哈希
    bytes32 settlementHash;  // 链下结算哈希（可选，支付凭证）
}
```

### 存储映射设计

```solidity
// 主存储：recordId => FeeRecord
mapping(uint256 => FeeRecord) public feeRecords;

// 计数器：全局记录ID
uint256 public nextRecordId;

// 索引1：user => recordIds[] (查询用户所有记录)
mapping(address => uint256[]) public userRecords;

// 索引2：user => token => total pending amount (快速查询待支付总额)
mapping(address => mapping(address => uint256)) public pendingAmounts;

// 索引3：token => total pending (全局待支付统计)
mapping(address => uint256) public totalPending;
```

---

## 🔄 状态转换流程

```
┌─────────┐  recordGasFee()   ┌─────────┐  settleFees()    ┌─────────┐
│ None    │ ────────────────> │ Pending │ ───────────────> │ Settled │
└─────────┘                   └─────────┘                  └─────────┘
                                    │
                                    │ cancelFee() (Future)
                                    ↓
                              ┌───────────┐
                              │ Cancelled │
                              └───────────┘
```

### 状态说明

1. **Pending** - 初始状态
   - Paymaster 调用 `recordGasFee()` 创建
   - 累积到 `pendingAmounts[user][token]`
   - 可批量查询

2. **Settled** - 已结算
   - Owner 确认链下转账后调用 `settleFees()`
   - 从 `pendingAmounts` 扣除
   - 记录 `settlementHash`（可选）

3. **Disputed** - 有争议（未来扩展）
   - 用户/Owner 可标记异常记录
   - 需人工介入处理

4. **Cancelled** - 已取消（未来扩展）
   - 错误记账可取消
   - 从 `pendingAmounts` 扣除

---

## 🛠️ 核心函数设计

### 1. recordGasFee() - Paymaster记账

**调用方**: 仅注册的 Paymaster  
**权限检查**: `registry.isPaymasterActive(msg.sender)`

```solidity
function recordGasFee(
    address user,
    address token,
    uint256 amount,
    bytes32 userOpHash
) external override nonReentrant whenNotPaused onlyRegisteredPaymaster returns (uint256 recordId) {
    // Input validation
    require(user != address(0), "Settlement: zero user");
    require(token != address(0), "Settlement: zero token");
    require(amount > 0, "Settlement: zero amount");
    
    // Generate new record ID
    recordId = nextRecordId++;
    
    // Create fee record
    feeRecords[recordId] = FeeRecord({
        id: recordId,
        paymaster: msg.sender,
        user: user,
        token: token,
        amount: amount,
        timestamp: block.timestamp,
        status: FeeStatus.Pending,
        userOpHash: userOpHash,
        settlementHash: bytes32(0)
    });
    
    // Update indexes (CEI pattern: Effects)
    userRecords[user].push(recordId);
    pendingAmounts[user][token] += amount;
    totalPending[token] += amount;
    
    // Emit event (CEI pattern: Interactions)
    emit FeeRecorded(recordId, msg.sender, user, token, amount, userOpHash);
    
    return recordId;
}
```

### 2. settleFees() - 批量确认结算

**调用方**: Owner  
**前提**: 链下已完成转账

**方案A: 通过Record IDs批量确认**
```solidity
function settleFees(
    uint256[] calldata recordIds,
    bytes32 settlementHash  // 可选，链下支付凭证
) external override nonReentrant whenNotPaused onlyOwner {
    require(recordIds.length > 0, "Settlement: empty records");
    
    uint256 totalSettled = 0;
    
    for (uint256 i = 0; i < recordIds.length; i++) {
        uint256 recordId = recordIds[i];
        FeeRecord storage record = feeRecords[recordId];
        
        // Validate record
        require(record.id == recordId, "Settlement: invalid record");
        require(record.status == FeeStatus.Pending, "Settlement: not pending");
        
        // Update state (CEI pattern: Effects)
        record.status = FeeStatus.Settled;
        record.settlementHash = settlementHash;
        
        // Update indexes
        pendingAmounts[record.user][record.token] -= record.amount;
        totalPending[record.token] -= record.amount;
        
        totalSettled += record.amount;
        
        // Emit event
        emit FeeSettled(recordId, record.user, record.token, record.amount, settlementHash);
    }
    
    emit BatchSettled(recordIds.length, totalSettled, settlementHash);
}
```

**方案B: 通过用户地址批量确认**
```solidity
function settleFeesByUsers(
    address[] calldata users,
    address token,
    bytes32 settlementHash
) external override nonReentrant whenNotPaused onlyOwner {
    // 查找所有 users 的 Pending 记录，批量更新状态
    // 实现略...
}
```

### 3. getUserPendingRecords() - 查询用户待支付记录

```solidity
function getUserPendingRecords(
    address user,
    address token
) external view returns (FeeRecord[] memory records) {
    uint256[] memory recordIds = userRecords[user];
    uint256 pendingCount = 0;
    
    // First pass: count pending records
    for (uint256 i = 0; i < recordIds.length; i++) {
        FeeRecord storage record = feeRecords[recordIds[i]];
        if (record.status == FeeStatus.Pending && record.token == token) {
            pendingCount++;
        }
    }
    
    // Second pass: collect pending records
    records = new FeeRecord[](pendingCount);
    uint256 index = 0;
    for (uint256 i = 0; i < recordIds.length; i++) {
        FeeRecord storage record = feeRecords[recordIds[i]];
        if (record.status == FeeStatus.Pending && record.token == token) {
            records[index++] = record;
        }
    }
    
    return records;
}
```

### 4. getPendingAmount() - 快速查询待支付总额

```solidity
function getPendingBalance(
    address user,
    address token
) external view override returns (uint256) {
    return pendingAmounts[user][token];
}
```

---

## 🔐 安全考虑

### 1. 授权验证
- ✅ `onlyRegisteredPaymaster` modifier
- ✅ 检查 `registry.isPaymasterActive(msg.sender)`
- ✅ Registry 地址 immutable

### 2. 重入保护
- ✅ `nonReentrant` on all state-changing functions
- ✅ CEI pattern (Checks-Effects-Interactions)
- ✅ State updates before events

### 3. 状态一致性
- ✅ 双重记账：`feeRecords` 主存储 + `pendingAmounts` 索引
- ✅ 状态更新时同步更新所有相关mapping
- ✅ 批量操作失败则全部回滚

### 4. Gas优化
- ✅ 批量操作减少交易次数
- ✅ 索引mapping加速查询
- ✅ Storage vs Memory 优化

---

## 📝 事件设计

```solidity
event FeeRecorded(
    uint256 indexed recordId,
    address indexed paymaster,
    address indexed user,
    address token,
    uint256 amount,
    bytes32 userOpHash
);

event FeeSettled(
    uint256 indexed recordId,
    address indexed user,
    address indexed token,
    uint256 amount,
    bytes32 settlementHash
);

event BatchSettled(
    uint256 recordCount,
    uint256 totalAmount,
    bytes32 indexed settlementHash
);

event FeeStatusChanged(
    uint256 indexed recordId,
    FeeStatus oldStatus,
    FeeStatus newStatus
);
```

---

## 🎯 使用场景

### 场景1: Paymaster 记录 gas 费用
1. UserOp 执行完成
2. Paymaster.postOp() 调用 Settlement.recordGasFee()
3. 创建 FeeRecord，状态为 Pending
4. 累积到 pendingAmounts

### 场景2: 链下批量转账 + 链上确认
1. Owner 查询所有 Pending 记录
2. 链下通过银行/支付宝批量转账给用户
3. 获得支付凭证哈希
4. 调用 settleFees(recordIds[], settlementHash)
5. 批量更新状态为 Settled

### 场景3: 用户查询待支付金额
1. 用户调用 getPendingBalance(user, PNT)
2. 立即返回总金额（O(1)查询）
3. 可选：调用 getUserPendingRecords() 查看明细

---

## 🔄 与 PaymasterV3 集成

### PaymasterV3.postOp() 修改

```solidity
function _postOp(...) internal {
    (address user, , bytes32 userOpHash) = abi.decode(context, ...);
    
    uint256 gasCostInWei = actualGasCost;
    
    // 记录到Settlement，获取recordId
    uint256 recordId = ISettlement(settlementContract).recordGasFee(
        user,
        gasToken,
        gasCostInWei,
        userOpHash  // 新增参数
    );
    
    emit GasRecorded(user, gasCostInWei, gasToken, recordId);
}
```

---

## 🚀 实施计划

### Phase 1: 更新接口
- [ ] 定义 FeeStatus enum
- [ ] 定义 FeeRecord struct
- [ ] 更新 ISettlement 接口

### Phase 2: 重构 Settlement 合约
- [ ] 添加 FeeRecord 存储
- [ ] 更新 recordGasFee() 函数签名
- [ ] 实现 settleFees() 状态更新逻辑
- [ ] 添加查询函数

### Phase 3: 更新 PaymasterV3
- [ ] 修改 postOp() 传递 userOpHash
- [ ] 更新事件定义

### Phase 4: 测试
- [ ] 单元测试：记账、结算、状态转换
- [ ] 集成测试：PaymasterV3 + Settlement
- [ ] Gas 优化测试

---

## 📊 Gas 估算

| 操作 | 估算 Gas | 说明 |
|------|----------|------|
| recordGasFee() | ~80k | 创建记录 + 更新索引 |
| settleFees(10 records) | ~200k | 批量更新状态 |
| getPendingBalance() | ~3k | View函数，读取mapping |
| getUserPendingRecords() | ~10k/record | View函数，遍历数组 |

**批量结算优势**:
- 单笔结算: 10 records × 50k = 500k gas
- 批量结算: 200k gas
- **节省**: ~60%

---

**审核者**: 待定  
**实施者**: Jason  
**预计完成**: 2025-01-06

---

## 🔐 权限模型与安全性分析 (2025-01-05 补充)

### 核心设计理念: 不可篡改记账 + 只读执行结算

#### 1. 记账阶段 - 完全去信任化

**流程**:
```
UserOp 执行 → EntryPoint.handleOps() 
→ PaymasterV3.postOp() [onlyEntryPoint]
→ Settlement.recordGasFee() [onlyRegisteredPaymaster]
→ 状态: Pending
```

**安全特性**:
- ✅ **触发权限**: 只有 EntryPoint 能调用 postOp
- ✅ **金额确定**: actualGasCost 由链上实际消耗决定，无人工干预
- ✅ **记账权限**: 只有注册的 Paymaster 能记账
- ✅ **不可篡改**: 一旦记录，金额和用户地址无法修改

**代码实现**:
```solidity
// PaymasterV3.sol
function postOp(...) external onlyEntryPoint nonReentrant {
    (address user, , bytes32 userOpHash) = abi.decode(context, ...);
    uint256 gasCostInWei = actualGasCost; // 由 EntryPoint 提供
    
    // 记录到 Settlement，无篡改可能
    ISettlement(settlementContract).recordGasFee(
        user,
        gasToken,
        gasCostInWei,
        userOpHash
    );
}

// Settlement.sol
function recordGasFee(...) external onlyRegisteredPaymaster returns (bytes32) {
    bytes32 key = keccak256(abi.encodePacked(msg.sender, userOpHash));
    
    // 防重放: 同一 userOp 无法重复记账
    require(feeRecords[key].status == FeeStatus.None, "Already recorded");
    
    // 创建不可变记录
    feeRecords[key] = FeeRecord({
        paymaster: msg.sender,
        user: user,
        token: token,
        amount: amount,  // 金额锁定
        timestamp: block.timestamp,
        status: FeeStatus.Pending,
        userOpHash: userOpHash,
        settlementHash: bytes32(0)
    });
}
```

---

#### 2. 结算阶段 - 受限执行权限

**流程**:
```
链下触发 → Settlement.settleFees(recordKeys[], settlementHash)
→ 检查记录状态 = Pending
→ 从用户钱包转账到 treasury (金额已锁定)
→ 状态: Settled
```

**权限限制分析**:

| 操作 | Owner 能做什么 | Owner 不能做什么 |
|------|---------------|----------------|
| **选择账单** | ✅ 选择结算哪些 recordKeys | ❌ 修改账单金额 |
| **执行转账** | ✅ 触发 transferFrom | ❌ 改变收款地址 (treasury 固定) |
| **更新状态** | ✅ Pending → Settled | ❌ 删除或回滚记录 |
| **批量操作** | ✅ 一次结算多个账单 | ❌ 跳过 balance/allowance 检查 |

**代码实现**:
```solidity
function settleFees(
    bytes32[] calldata recordKeys,
    bytes32 settlementHash
) external onlyOwner nonReentrant whenNotPaused {
    for (uint256 i = 0; i < recordKeys.length; i++) {
        bytes32 key = recordKeys[i];
        FeeRecord storage record = feeRecords[key];
        
        // 1. 检查: 记录必须存在且状态为 Pending
        require(record.status == FeeStatus.Pending, "Not pending");
        
        // 2. 检查: 用户余额和授权 (无法绕过)
        uint256 userBalance = IERC20(record.token).balanceOf(record.user);
        uint256 allowance = IERC20(record.token).allowance(record.user, address(this));
        require(userBalance >= record.amount, "Insufficient balance");
        require(allowance >= record.amount, "Insufficient allowance");
        
        // 3. 状态更新 (CEI 模式)
        record.status = FeeStatus.Settled;
        record.settlementHash = settlementHash;
        
        // 4. 转账: 金额和地址都已锁定
        IERC20(record.token).transferFrom(
            record.user,
            treasury,  // ⚠️ 固定收款地址，构造函数设置
            record.amount  // ⚠️ 记账时锁定的金额
        );
    }
}
```

---

#### 3. 多签需求重新评估

**传统观点**: Settlement owner 需要多签保护  
**实际分析**: **不需要**，理由如下:

##### 3.1 Owner 权限有限
- ❌ **不能修改账单金额** - 由 EntryPoint 确定
- ❌ **不能改变收款地址** - treasury 是 immutable
- ❌ **不能绕过安全检查** - balance/allowance 强制验证
- ✅ **只能触发执行** - 按既定规则结算

##### 3.2 可能的恶意行为及影响

| 恶意行为 | 是否可行 | 影响 | 缓解措施 |
|---------|---------|------|---------|
| 修改账单金额 | ❌ 不可行 | - | 金额在记账时锁定 |
| 改变收款地址 | ❌ 不可行 | - | treasury immutable |
| 选择性不结算 | ✅ 可行 | 用户资金卡在 pending | 透明规则 + 监控告警 |
| 批量结算 DoS | ✅ 可行 | Owner 浪费 gas | 影响仅限 owner 自己 |
| 暂停合约 | ✅ 可行 (pause) | 无法记账和结算 | 紧急情况需要，合理权限 |

**结论**: Owner 的恶意行为**无法窃取资金**，最多造成服务中断。

---

#### 4. 真正需要多签的地方

虽然 Settlement owner 不需要多签，但**以下场景仍需考虑**:

##### 4.1 Treasury 地址 (资金接收端) ⭐
```solidity
constructor(address _registry, address _treasury) {
    treasury = _treasury;  // ⚠️ 这个地址应该是多签钱包
}
```

**建议**:
- ✅ Treasury 使用 Gnosis Safe 3/5 多签
- ✅ 所有结算资金进入多签钱包
- ✅ 提取资金需要多人批准

##### 4.2 Owner 私钥丢失风险
- **问题**: Owner 私钥丢失 → 永远无法结算
- **方案A**: Owner 本身使用 2/3 多签 (防丢失)
- **方案B**: 添加 `emergencyOwner` 作为备用
- **方案C**: 使用时间锁 + 治理投票

##### 4.3 紧急情况处理
```solidity
// 可选: 添加紧急结算委员会
mapping(address => bool) public emergencySettlers;

function emergencySettle(...) external {
    require(emergencySettlers[msg.sender], "Not authorized");
    // 强制结算所有 pending
}
```

---

#### 5. 推荐的安全架构

```
┌─────────────────────────────────────────────────────┐
│               EntryPoint (去中心化)                  │
│                       ↓                              │
│             PaymasterV3 (onlyEntryPoint)            │
│                       ↓                              │
│         Settlement (onlyRegisteredPaymaster)        │
│                       ↓                              │
│  记账: 金额锁定, 状态 Pending (不可篡改)            │
└─────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────┐
│          链下触发 (Owner or Keeper)                  │
│                       ↓                              │
│        Settlement.settleFees(recordKeys[])          │
│         (只读执行, 无篡改权限)                       │
│                       ↓                              │
│            Treasury (Gnosis Safe 3/5)               │
│          (资金接收端, 真正需要多签)                  │
└─────────────────────────────────────────────────────┘
```

**关键决策**:
- ✅ **Settlement Owner**: EOA 或 2/3 多签 (防私钥丢失)
- ✅ **Treasury**: 必须是 3/5 多签 (资金安全)
- ✅ **Keeper**: 无需多签 (只读执行)

---

#### 6. 最终建议

**部署配置**:
```solidity
// 部署 Settlement
Settlement settlement = new Settlement(
    registryAddress,
    treasuryMultisigAddress  // ⚠️ 使用 Gnosis Safe 3/5
);

// Owner 转移 (可选)
settlement.transferOwnership(ownerMultisigAddress);  // 2/3 多签防丢失

// 或保持 EOA
// settlement owner = deployer (单签, 接受私钥丢失风险)
```

**风险接受**:
- ✅ Settlement Owner 恶意: 无法窃取资金，只能拒绝服务
- ✅ Owner 私钥丢失: 部署新 Settlement，迁移 Paymaster 配置
- ✅ Treasury 被盗: 多签保护，3/5 门槛

**监控告警**:
- ✅ 监控 pending balance 增长
- ✅ 超过阈值自动结算 (Keeper)
- ✅ 长期未结算账单告警
- ✅ Owner 操作日志审计

---

## 🎯 总结

你的策略**完全正确**:

1. **记账不可篡改** ✅ - EntryPoint 唯一写入权限
2. **金额不可修改** ✅ - actualGasCost 链上确定
3. **执行者只读** ✅ - 无篡改权限
4. **资金流向固定** ✅ - treasury immutable

**不需要 Settlement Owner 多签**，但**需要 Treasury 多签**。

**建议配置**:
- Settlement Owner: EOA (简化操作) 或 2/3 多签 (防丢失)
- Treasury: 3/5 多签 (资金安全)
- Keeper: 自动化脚本 (无需多签)

这个设计在**安全性**和**操作效率**之间达到了最佳平衡。

