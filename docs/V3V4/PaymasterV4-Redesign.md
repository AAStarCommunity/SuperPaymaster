# PaymasterV4 重新设计文档

## 设计原则

基于 **PaymasterV3_2.sol** 进行优化，去除 Settlement 依赖，实现直接支付模式。

## 关键变更

### ❌ 移除的功能
1. **ChainConfig 系统** - 通过部署参数和 setter 配置每条链
2. **PNT-ETH 汇率系统** - PNT 不再与 ETH 挂钩，使用 USD 定价
3. **智能汇率系统** - 暂不实现
4. **动态服务费** - 暂不实现
5. **Oracle 集成** - 暂不实现

### ✅ 保留的功能
1. **SBT 资格检查** - 用户必须持有 SBT
2. **PNT 余额检查** - 用户必须有足够 PNT
3. **Gas 上限保护** - 防止过度收费
4. **暂停机制** - 紧急停止功能
5. **Owner 权限控制** - 管理员功能

### ✨ 新增功能
1. **Treasury 账户** - 服务商收款账户，实时转账
2. **可配置服务费** - Owner 可调整服务费率（默认 2%）
3. **多 SBT 支持** - 支持多个 SBT 合约地址（如果 gas 成本可接受）
4. **多 GasToken 支持** - 支持多种 PNT 类型（基础 PNTs, aPNTs, bPNTs）
5. **直接支付模式** - validatePaymasterUserOp 中直接收取 PNT

## 核心架构

### 1. PNT 价格体系

```solidity
// PNT 定价（USD）
uint256 public pntPriceUSD;  // 18 decimals, 初始 0.02 USD = 0.02e18

// 服务费（可配置）
uint256 public serviceFeeRate;  // 基点，200 = 2%
uint256 public constant MAX_SERVICE_FEE = 1000;  // 最大 10%

// Gas 上限保护
uint256 public maxGasCostCap;  // 单笔交易最大 gas 成本（wei）
```

### 2. 多地址支持

```solidity
// 支持的 SBT 合约列表
address[] public supportedSBTs;
mapping(address => bool) public isSBTSupported;

// 支持的 GasToken 列表
address[] public supportedGasTokens;
mapping(address => bool) public isGasTokenSupported;

// 管理函数
function addSBT(address sbt) external onlyOwner;
function removeSBT(address sbt) external onlyOwner;
function addGasToken(address token) external onlyOwner;
function removeGasToken(address token) external onlyOwner;
```

### 3. Treasury 系统

```solidity
// 服务商收款账户
address public treasury;

// 设置 treasury
function setTreasury(address _treasury) external onlyOwner {
    require(_treasury != address(0), "Invalid treasury");
    address oldTreasury = treasury;
    treasury = _treasury;
    emit TreasuryUpdated(oldTreasury, _treasury);
}
```

### 4. 直接支付逻辑

```solidity
function validatePaymasterUserOp(
    PackedUserOperation calldata userOp,
    bytes32 /* userOpHash */,
    uint256 maxCost
) external onlyEntryPoint whenNotPaused nonReentrant 
  returns (bytes memory context, uint256 validationData) 
{
    address sender = userOp.getSender();
    
    // 1. 检查 SBT（任意一个即可）
    require(_hasAnySBT(sender), "No valid SBT");
    
    // 2. 应用 gas cap
    uint256 cappedMaxCost = maxCost > maxGasCostCap ? maxGasCostCap : maxCost;
    
    // 3. 计算需要的 PNT 数量
    // 公式：PNT = (gasCostWei / 1e18 * ethPriceUSD + serviceFee) / pntPriceUSD
    // 简化：先预估一个 ETH 价格（如 3000 USD），或从外部获取
    uint256 pntAmount = _calculatePNTAmount(cappedMaxCost);
    
    // 4. 选择用户持有的 GasToken
    address userGasToken = _getUserGasToken(sender, pntAmount);
    require(userGasToken != address(0), "Insufficient PNT balance");
    
    // 5. 直接转账 PNT 到 treasury
    IERC20(userGasToken).transferFrom(sender, treasury, pntAmount);
    
    // 6. 记录 context（用于 postOp 可能的退款）
    context = abi.encode(sender, userGasToken, pntAmount, cappedMaxCost);
    
    return (context, 0);
}
```

### 5. PostOp 逻辑（可选退款）

```solidity
function postOp(
    PostOpMode mode,
    bytes calldata context,
    uint256 actualGasCost,
    uint256 /* actualUserOpFeePerGas */
) external onlyEntryPoint nonReentrant {
    // 解码 context
    (address user, address gasToken, uint256 paidPNT, uint256 maxCost) = 
        abi.decode(context, (address, address, uint256, uint256));
    
    // 计算实际需要的 PNT
    uint256 actualPNT = _calculatePNTAmount(actualGasCost);
    
    // 如果多付了，退款（可选功能）
    if (paidPNT > actualPNT) {
        uint256 refund = paidPNT - actualPNT;
        IERC20(gasToken).transferFrom(treasury, user, refund);
        emit RefundProcessed(user, gasToken, refund);
    }
    
    emit GasPaymentProcessed(user, gasToken, actualPNT, actualGasCost);
}
```

## Gas 优化对比

### V3.2 (with Settlement)
- **validatePaymasterUserOp**: ~50k gas
- **postOp**: ~260k gas (Settlement 记录)
- **总计**: ~310k gas

### V4 (Direct Payment)

#### 方案 A：预付款 + 退款
- **validatePaymasterUserOp**: ~60k gas (直接转账)
- **postOp**: ~40k gas (计算 + 可能的退款)
- **总计**: ~100k gas
- **节省**: ~210k gas (67%)

#### 方案 B：预付款，无退款（推荐）
- **validatePaymasterUserOp**: ~60k gas (直接转账)
- **postOp**: ~5k gas (仅记录事件)
- **总计**: ~65k gas
- **节省**: ~245k gas (79%)

**推荐方案 B**，因为：
1. 用户预付 maxCost 对应的 PNT
2. 即使实际 gas 更少，差额通常很小（< 10%）
3. 省去复杂的退款逻辑，大幅降低 gas
4. Treasury 稍微多收一点，可作为服务费缓冲

## 部署流程

### 不同链的部署策略

每条链使用不同的初始化参数：

```solidity
// Ethereum Mainnet
new PaymasterV4(
    entryPoint,
    owner,
    treasury_mainnet,
    0.02e18,        // pntPriceUSD: $0.02
    200,            // serviceFeeRate: 2%
    0.01 ether,     // maxGasCostCap: 0.01 ETH
    1000e18         // minTokenBalance: 1000 PNT
);

// OP Mainnet  
new PaymasterV4(
    entryPoint,
    owner,
    treasury_op,
    0.02e18,        // pntPriceUSD: $0.02（相同）
    50,             // serviceFeeRate: 0.5%（更低）
    0.005 ether,    // maxGasCostCap: 0.005 ETH（L2 更便宜）
    1000e18         // minTokenBalance: 1000 PNT
);
```

### 部署后配置

```solidity
// 添加支持的 SBT
paymaster.addSBT(sbtContract1);
paymaster.addSBT(sbtContract2);

// 添加支持的 GasToken
paymaster.addGasToken(basePNTs);
paymaster.addGasToken(aPNTs);
paymaster.addGasToken(bPNTs);
```

## 4337 账户部署赞助

### 流程确认 ✅

PaymasterV4 **完全支持**为账户部署赞助 gas：

```
UserOperation {
    sender: 0x1234...5678,  // 未部署的账户地址
    nonce: 0,
    initCode: <factory + createAccount calldata>,  // 部署指令
    callData: <transfer 10 USDT>,                  // 部署后的第一笔交易
    ...
    paymasterAndData: <paymaster address + data>   // PaymasterV4
}

执行流程：
1. EntryPoint 检查 sender 是否部署
2. sender 不存在 → 使用 initCode 部署账户
3. 部署成功 → 调用 account.validateUserOp()
4. 调用 paymaster.validatePaymasterUserOp()
   - 此时账户已部署
   - 检查账户的 SBT 和 PNT 余额
   - 收取 PNT（包含部署 + 交易的总 gas）
5. 执行 callData (transfer 10 USDT)
6. 调用 paymaster.postOp()
   - actualGasCost 包含了部署 + 交易的总费用
```

### 关键点

1. **Paymaster 验证时账户已部署** ✅
   - 所以可以检查 SBT 和 PNT 余额
   
2. **actualGasCost 包含部署费用** ✅
   - PostOp 收到的是**总费用**
   
3. **用户体验优化**
   - 用户只需在未部署的账户地址预存 PNT
   - 一笔 UserOp 完成：部署 + 转账
   - Paymaster 赞助全部 ETH gas

### 特殊处理

对于未部署账户，需要考虑：

```solidity
function validatePaymasterUserOp(...) {
    address sender = userOp.getSender();
    
    // 检查账户是否已部署
    uint256 codeSize;
    assembly {
        codeSize := extcodesize(sender)
    }
    
    if (codeSize == 0) {
        // 账户未部署，正在部署中
        // 此时无法检查 SBT（SBT 在部署后才铸造）
        // 可以：
        // 1. 跳过 SBT 检查，仅检查 PNT
        // 2. 或要求 initCode 中包含 SBT 铸造
        // 3. 或使用白名单机制
    } else {
        // 正常流程
        require(_hasAnySBT(sender), "No SBT");
    }
    
    // PNT 检查照常进行（预存在地址中）
    address userGasToken = _getUserGasToken(sender, pntAmount);
    require(userGasToken != address(0), "Insufficient PNT");
    
    // 直接转账
    IERC20(userGasToken).transferFrom(sender, treasury, pntAmount);
}
```

## 配置项总结

### 构造函数参数
```solidity
constructor(
    address _entryPoint,
    address _owner,
    address _treasury,
    uint256 _pntPriceUSD,      // PNT 价格（USD，18 decimals）
    uint256 _serviceFeeRate,   // 服务费率（基点）
    uint256 _maxGasCostCap,    // Gas 上限
    uint256 _minTokenBalance   // 最小 PNT 余额
)
```

### Owner 可配置项
```solidity
// Treasury 管理
setTreasury(address)

// PNT 价格和费率
setPntPriceUSD(uint256)
setServiceFeeRate(uint256)  // 最大 10%

// Gas 保护
setMaxGasCostCap(uint256)
setMinTokenBalance(uint256)

// SBT 管理
addSBT(address)
removeSBT(address)
getSupportedSBTs() view returns (address[])

// GasToken 管理
addGasToken(address)
removeGasToken(address)
getSupportedGasTokens() view returns (address[])

// 紧急控制
pause()
unpause()
```

## 多地址支持的 Gas 成本

### 单个地址检查
```solidity
// 约 2.6k gas
ISBT(sbt).balanceOf(user)  // SLOAD + external call
```

### 多个地址检查（循环）
```solidity
function _hasAnySBT(address user) internal view returns (bool) {
    uint256 length = supportedSBTs.length;
    for (uint256 i = 0; i < length; i++) {
        if (ISBT(supportedSBTs[i]).balanceOf(user) > 0) {
            return true;  // 找到任意一个即返回
        }
    }
    return false;
}

// Gas 成本：
// - 1 个 SBT: ~2.6k gas
// - 2 个 SBT: ~5.2k gas (最坏情况)
// - 3 个 SBT: ~7.8k gas (最坏情况)
// 平均情况会更低（用户通常持有第一个 SBT）
```

**结论**：支持 2-3 个 SBT 的 gas 成本可接受（< 10k gas）

## 安全考虑

### 1. 重入保护
- ✅ 使用 `nonReentrant` modifier
- ✅ `transferFrom` 在状态更新后

### 2. 零地址检查
- ✅ 所有地址参数验证
- ✅ Treasury 不能为零地址

### 3. 数值溢出
- ✅ Solidity 0.8+ 自动检查
- ✅ Gas 计算使用 uint256

### 4. 权限控制
- ✅ `onlyOwner` 管理配置
- ✅ `onlyEntryPoint` 执行 UserOp

### 5. 紧急停止
- ✅ `pause()` 立即停止服务
- ✅ Owner 可随时调用

## 实现优先级

### Phase 1: 核心功能（MVP）
1. ✅ 基础架构（constructor, modifiers）
2. ✅ 单 SBT、单 GasToken 支持
3. ✅ 直接支付逻辑（无退款）
4. ✅ Treasury 转账
5. ✅ 基础 admin 函数

### Phase 2: 增强功能
1. ✅ 多 SBT 支持
2. ✅ 多 GasToken 支持
3. ✅ 可配置服务费
4. ✅ Gas cap 保护

### Phase 3: 优化（可选）
1. ⚠️ PostOp 退款逻辑
2. ⚠️ Oracle 价格集成
3. ⚠️ 动态费率系统

## 测试策略

### 单元测试
- SBT 检查逻辑
- GasToken 检查逻辑
- PNT 数量计算
- Treasury 转账
- 权限控制

### 集成测试
- 完整 UserOp 流程
- 账户部署赞助
- 多 SBT/Token 场景
- Gas 对比测试

### Gas 基准测试
- V3.2 vs V4 对比
- 不同场景的 gas 消耗
- 优化前后对比

## 总结

PaymasterV4 是 V3.2 的简化和优化版本：

### 核心改进
1. ✅ **去除 Settlement 依赖** - 直接支付，节省 ~245k gas (79%)
2. ✅ **去除链配置系统** - 部署参数 + setter 更简洁
3. ✅ **修正 PNT 价格体系** - USD 定价，不再与 ETH 挂钩
4. ✅ **Treasury 实时转账** - 服务商即时收款
5. ✅ **多地址支持** - 灵活支持多种 SBT 和 GasToken

### 保持简洁
- ❌ 不使用复杂的汇率系统
- ❌ 不使用 Oracle（初期）
- ❌ 不使用动态费率（初期）
- ❌ 不使用链配置（每链独立部署）

### 支持 4337 核心功能
- ✅ 账户部署赞助
- ✅ 批量操作支持
- ✅ Gas 精确计算
