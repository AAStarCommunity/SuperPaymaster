# PaymasterV4 最终设计文档（已确认）

## 📋 设计确认日期
2025-01-XX - 与用户讨论后的最终版本

## ✅ 已确认的设计决策

### 1. 服务费配置 ✅

**设计**：服务费是可配置的，不是固定的

```solidity
// 构造函数初始化（例如 2%）
uint256 public serviceFeeRate;  // 200 = 2%

constructor(..., uint256 _serviceFeeRate) {
    serviceFeeRate = _serviceFeeRate;
}

// Owner 可随时修改
function setServiceFeeRate(uint256 _newRate) external onlyOwner {
    require(_newRate <= MAX_SERVICE_FEE, "Fee too high");  // 最大 10%
    serviceFeeRate = _newRate;
    emit ServiceFeeUpdated(oldRate, _newRate);
}
```

### 2. GasToken 选择逻辑 ✅

**设计**：支持用户在 UserOp 中指定 GasToken

#### paymasterAndData 结构（v0.7）

```solidity
// ERC-4337 v0.7 标准
paymasterAndData = abi.encodePacked(
    address(paymaster),      // 20 bytes - Paymaster 地址
    uint128(validUntil),     // 16 bytes - 有效期截止
    uint128(validAfter),     // 16 bytes - 有效期开始
    address(gasToken)        // 20 bytes - 指定的 GasToken 地址
);

// 总长度：20 + 16 + 16 + 20 = 72 bytes
```

#### 选择逻辑

```solidity
function validatePaymasterUserOp(...) {
    address userGasToken;
    
    // 1. 尝试从 paymasterData 解析指定的 token
    if (userOp.paymasterAndData.length >= 72) {
        address specifiedToken = address(
            bytes20(userOp.paymasterAndData[52:72])
        );
        
        // 验证 token 是否支持
        if (specifiedToken != address(0) && isGasTokenSupported[specifiedToken]) {
            userGasToken = specifiedToken;
        }
    }
    
    // 2. 如果未指定或不支持，自动选择余额足够的 token
    if (userGasToken == address(0)) {
        userGasToken = _getUserGasToken(sender, pntAmount);
    }
    
    require(userGasToken != address(0), "No valid gas token");
}
```

**重要**：所有构造 UserOp 的脚本都需要更新！

### 3. 退款策略 ✅

**设计**：多付不退款，但记录事件用于链下分析

**理由**：
- Gas 估算偏差小（尤其 L2）
- 退款需要 ~40k gas
- 简化 postOp 逻辑
- 链下可定期批量结算

```solidity
function postOp(
    PostOpMode mode,
    bytes calldata context,
    uint256 actualGasCost,
    uint256 actualUserOpFeePerGas
) external onlyEntryPoint {
    // 解码 context
    (address user, address gasToken, uint256 paidPNT) = 
        abi.decode(context, (address, address, uint256));
    
    // 记录实际消耗（用于链下分析）
    emit ActualGasRecorded(user, gasToken, actualGasCost, paidPNT);
    
    // 不退款 - 节省 gas
}
```

### 4. Owner 可修改的参数 ✅

| 参数 | 初始值示例 | Owner 可修改 | Setter 函数 |
|------|-----------|--------------|-------------|
| gasToUSDRate | 4500e18 | ✅ | setGasToUSDRate(uint256) |
| pntPriceUSD | 0.02e18 | ✅ | setPntPriceUSD(uint256) |
| serviceFeeRate | 200 (2%) | ✅ | setServiceFeeRate(uint256) |
| maxGasCostCap | 0.01 ether | ✅ | setMaxGasCostCap(uint256) |
| minTokenBalance | 1000e18 | ✅ | setMinTokenBalance(uint256) |
| treasury | 0x... | ✅ | setTreasury(address) |

### 5. SBT 数量限制 ✅

**设计**：限制最多 5 个 SBT

**理由**：
- 平均情况：~3k gas（第一个命中）
- 最坏情况：~13k gas（5 个全检查）
- 足够灵活：支持 5 种 SBT 类型

```solidity
uint256 public constant MAX_SBTS = 5;
uint256 public constant MAX_GAS_TOKENS = 10;  // GasToken 可以更多

function addSBT(address sbt) external onlyOwner {
    require(supportedSBTs.length < MAX_SBTS, "Too many SBTs");
    require(sbt != address(0), "Zero address");
    require(!isSBTSupported[sbt], "Already exists");
    
    supportedSBTs.push(sbt);
    isSBTSupported[sbt] = true;
    emit SBTAdded(sbt);
}
```

### 6. PNT 计算逻辑 ✅

**设计**：使用两个独立的价格参数

#### 核心概念

```solidity
// 1. Gas to USD 比率（相对固定，以 ETH 某个价格为基准）
uint256 public gasToUSDRate;  // 例如：4500e18 = $4500/ETH

// 2. PNT 价格（浮动，根据市场调整）
uint256 public pntPriceUSD;   // 例如：0.02e18 = $0.02/PNT
```

#### 计算公式

```solidity
function _calculatePNTAmount(uint256 gasCostWei) internal view returns (uint256) {
    // 步骤 1: 计算 gas 成本（USD）
    // gasCostWei 是实际的 ETH 成本（wei）
    // gasToUSDRate 是 1 ETH = $X USD
    // gasCostUSD = gasCostWei * gasToUSDRate / 1e18
    uint256 gasCostUSD = (gasCostWei * gasToUSDRate) / 1e18;
    
    // 步骤 2: 加上服务费
    // serviceFeeRate 是基点（200 = 2%）
    uint256 totalCostUSD = gasCostUSD * (10000 + serviceFeeRate) / 10000;
    
    // 步骤 3: 转换为 PNT
    // pntAmount = totalCostUSD / pntPriceUSD
    uint256 pntAmount = (totalCostUSD * 1e18) / pntPriceUSD;
    
    return pntAmount;
}
```

#### 计算示例

**假设**：
- gasToUSDRate = 4500e18 ($4500/ETH)
- pntPriceUSD = 0.02e18 ($0.02/PNT)
- serviceFeeRate = 200 (2%)
- gasCostWei = 0.01 ether

**计算**：
1. gasCostUSD = 0.01 * 4500 = $45
2. totalCostUSD = $45 * 1.02 = $45.9
3. pntAmount = $45.9 / $0.02 = 2295 PNT

**调整 PNT 价格**：
- pntPriceUSD 降至 0.01e18 ($0.01/PNT)
- pntAmount = $45.9 / $0.01 = **4590 PNT** ✅ (翻倍)

**ETH 短期波动**：
- ETH 涨到 $5000，但 gasToUSDRate 仍是 $4500
- pntAmount 不变 ✅

#### Owner 调整

```solidity
// 调整 gas-to-USD 比率（ETH 价格长期变化时）
function setGasToUSDRate(uint256 _rate) external onlyOwner {
    require(_rate > 0, "Invalid rate");
    uint256 oldRate = gasToUSDRate;
    gasToUSDRate = _rate;
    emit GasToUSDRateUpdated(oldRate, _rate);
}

// 调整 PNT 价格（PNT 市场价格变化时）✅ 主要调整项
function setPntPriceUSD(uint256 _price) external onlyOwner {
    require(_price > 0, "Invalid price");
    uint256 oldPrice = pntPriceUSD;
    pntPriceUSD = _price;
    emit PntPriceUpdated(oldPrice, _price);
}
```

### 7. 未部署账户处理 ✅

**设计**：区分已部署和未部署账户

**背景**：
- SBT/NFT 铸造需要账户已部署
- `safeMint(address to)` 需要调用 `to.onERC721Received()`
- 未部署账户无法响应

```solidity
function validatePaymasterUserOp(...) external {
    address sender = userOp.getSender();
    
    // 检查账户是否已部署
    uint256 codeSize;
    assembly {
        codeSize := extcodesize(sender)
    }
    
    if (codeSize == 0) {
        // ====== 账户未部署 ======
        // 跳过 SBT 检查（无法检查）
        // 仅检查 PNT 余额（预存在地址中）
        
        // 计算 PNT 数量
        uint256 cappedMaxCost = maxCost > maxGasCostCap ? maxGasCostCap : maxCost;
        uint256 pntAmount = _calculatePNTAmount(cappedMaxCost);
        
        // 查找用户的 GasToken
        address userGasToken = _selectGasToken(userOp, sender, pntAmount);
        require(userGasToken != address(0), "Insufficient PNT for deployment");
        
        // 直接转账
        IERC20(userGasToken).transferFrom(sender, treasury, pntAmount);
        
        emit DeploymentSponsored(sender, userGasToken, pntAmount);
        
    } else {
        // ====== 账户已部署 ======
        // 正常检查：SBT + PNT
        
        // 1. 检查 SBT
        require(_hasAnySBT(sender), "No valid SBT");
        
        // 2. 计算并收取 PNT
        uint256 cappedMaxCost = maxCost > maxGasCostCap ? maxGasCostCap : maxCost;
        uint256 pntAmount = _calculatePNTAmount(cappedMaxCost);
        
        address userGasToken = _selectGasToken(userOp, sender, pntAmount);
        require(userGasToken != address(0), "Insufficient PNT");
        
        IERC20(userGasToken).transferFrom(sender, treasury, pntAmount);
        
        emit GasPaymentProcessed(sender, userGasToken, pntAmount, cappedMaxCost);
    }
    
    // 编码 context（用于 postOp）
    context = abi.encode(sender, userGasToken, pntAmount);
    return (context, 0);
}
```

**安全考虑**：
- 未部署账户没有 SBT 保护
- 依赖 PNT 预存（用户需提前转 PNT 到未来地址）
- 可以考虑添加 factory 白名单（可选）

## 📦 构造函数签名

```solidity
constructor(
    address _entryPoint,
    address _owner,
    address _treasury,
    uint256 _gasToUSDRate,      // 例如：4500e18 ($4500/ETH)
    uint256 _pntPriceUSD,       // 例如：0.02e18 ($0.02/PNT)
    uint256 _serviceFeeRate,    // 例如：200 (2%)
    uint256 _maxGasCostCap,     // 例如：0.01 ether
    uint256 _minTokenBalance    // 例如：1000e18
)
```

## 🔧 配置管理脚本

需要创建脚本：`scripts/configure-paymaster.js`

```javascript
// 配置 SBT
await paymaster.addSBT(sbtContract1);
await paymaster.addSBT(sbtContract2);
await paymaster.addSBT(sbtContract3);

// 配置 GasToken
await paymaster.addGasToken(basePNTs);
await paymaster.addGasToken(aPNTs);
await paymaster.addGasToken(bPNTs);

// 验证配置
const sbts = await paymaster.getSupportedSBTs();
const tokens = await paymaster.getSupportedGasTokens();
```

## 📊 部署示例

### Ethereum Mainnet

```solidity
PaymasterV4 paymasterMainnet = new PaymasterV4(
    0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789,  // EntryPoint v0.7
    msg.sender,                                   // owner
    0x1234...treasury_mainnet,                   // treasury
    4500e18,                                      // gasToUSDRate: $4500/ETH
    0.02e18,                                      // pntPriceUSD: $0.02
    200,                                          // serviceFeeRate: 2%
    0.01 ether,                                   // maxGasCostCap
    1000e18                                       // minTokenBalance: 1000 PNT
);
```

### OP Mainnet

```solidity
PaymasterV4 paymasterOP = new PaymasterV4(
    0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789,  // EntryPoint v0.7
    msg.sender,                                   // owner
    0x5678...treasury_op,                        // treasury (不同)
    4500e18,                                      // gasToUSDRate: $4500/ETH (相同)
    0.02e18,                                      // pntPriceUSD: $0.02 (相同)
    50,                                           // serviceFeeRate: 0.5% (更低)
    0.005 ether,                                  // maxGasCostCap (更低)
    1000e18                                       // minTokenBalance
);
```

## 📝 事件定义

```solidity
// Gas 支付事件
event GasPaymentProcessed(
    address indexed user,
    address indexed gasToken,
    uint256 pntAmount,
    uint256 gasCostWei
);

// 账户部署赞助事件
event DeploymentSponsored(
    address indexed user,
    address indexed gasToken,
    uint256 pntAmount
);

// PostOp 记录事件
event ActualGasRecorded(
    address indexed user,
    address indexed gasToken,
    uint256 actualGasCost,
    uint256 paidPNT
);

// 配置更新事件
event GasToUSDRateUpdated(uint256 oldRate, uint256 newRate);
event PntPriceUpdated(uint256 oldPrice, uint256 newPrice);
event ServiceFeeUpdated(uint256 oldRate, uint256 newRate);
event MaxGasCostCapUpdated(uint256 oldCap, uint256 newCap);
event MinTokenBalanceUpdated(uint256 oldBalance, uint256 newBalance);
event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
event SBTAdded(address indexed sbt);
event SBTRemoved(address indexed sbt);
event GasTokenAdded(address indexed token);
event GasTokenRemoved(address indexed token);
```

## 🔒 安全特性

1. **重入保护**: `nonReentrant` modifier
2. **零地址检查**: 所有地址参数验证
3. **权限控制**: `onlyOwner` 和 `onlyEntryPoint`
4. **Gas 上限保护**: `maxGasCostCap`
5. **服务费上限**: 最大 10%
6. **紧急停止**: `pause()` / `unpause()`
7. **数量限制**: MAX_SBTS = 5

## 📈 Gas 估算

| 操作 | Gas 成本 | 说明 |
|------|----------|------|
| validatePaymasterUserOp (已部署) | ~60k | SBT 检查 + PNT 转账 |
| validatePaymasterUserOp (未部署) | ~55k | 仅 PNT 转账 |
| postOp | ~5k | 仅事件记录 |
| **总计** | **~65k** | **vs V3.2 的 ~310k** |
| **节省** | **245k (79%)** | |

## ✅ 验收标准

- [x] 基于 V3.2 架构
- [x] gasToUSDRate + pntPriceUSD 双参数
- [x] pntPriceUSD 可修改且影响计算
- [x] 支持 paymasterData 指定 GasToken
- [x] 多付不退款，记录事件
- [x] 所有参数 owner 可配置
- [x] SBT 限制 5 个
- [x] 支持未部署账户（跳过 SBT 检查）
- [x] postOp 记录事件
- [ ] 测试完成
- [ ] 部署验证

## 🎯 关键改进点总结

1. **价格体系** ✅
   - gasToUSDRate: 固定 gas-USD 比率
   - pntPriceUSD: 浮动 PNT 价格
   - 调整 pntPriceUSD 直接影响收取的 PNT 数量

2. **用户体验** ✅
   - 支持在 UserOp 中指定 GasToken
   - 自动选择余额足够的 token
   - 支持账户部署赞助

3. **灵活配置** ✅
   - 所有关键参数 owner 可修改
   - 动态添加/移除 SBT 和 GasToken
   - Treasury 可更换

4. **Gas 优化** ✅
   - 直接支付，无 Settlement
   - 空的 postOp（仅事件）
   - 79% gas 节省

5. **安全性** ✅
   - 未部署账户特殊处理
   - 数量限制（MAX_SBTS = 5）
   - 全面的权限控制

---

**文档状态**: ✅ 已确认，可以执行实现
**确认日期**: 2025-01-XX
**确认人**: Jason (用户)
