# SuperPaymaster合约改进方案

## 改进目标总结

1. ✅ 统一认知：stGToken是虚拟份额（详见`lock-mechanism.md`）
2. 🔧 优化Gas价格计算：Chainlink集成最佳实践
3. 🔧 aPNT价格管理：初期固定，后期Swap集成
4. 🔧 xPNT/aPNT双重扣费流程设计

---

## 1. 统一认知：stGToken实现机制

### 1.1 业界方案对比

| 项目 | Stake Token | 获得凭证 | Lock方式 | 流动性 |
|------|------------|---------|---------|--------|
| **Lido** | ETH | stETH (ERC-20) | 外部合约lock stETH | ✅ 高（可交易） |
| **Eigenlayer** | ETH/LST | 虚拟份额 | 内置strategy lock | ❌ 低（绑定地址） |
| **我们** | GToken (ERC-20) | **stGToken (虚拟份额)** | **内置multi-locker** | ❌ 低（声誉抵押） |

### 1.2 我们的实现方式

```
┌──────────────────────────────────────────┐
│ 用户质押 GToken（真实ERC-20代币）          │
│   ↓ transferFrom                          │
│ GTokenStaking合约接收GToken               │
│   ↓ 计算份额（Lido公式）                   │
│ 用户获得 stGToken（虚拟uint256，非ERC-20） │
│   ↓ lockStake                             │
│ Registry/SuperPaymaster锁定份额           │
└──────────────────────────────────────────┘
```

**关键点**：
- ✅ **stGToken不是ERC-20代币**，是存储在`StakeInfo`映射中的uint256数字
- ✅ **存储位置**：`GTokenStaking.stakes[user].stGTokenShares`
- ✅ **锁定位置**：`GTokenStaking.locks[user][locker].amount`
- ✅ **Registry记录**：`communityStakes[user].stGTokenLocked`（同步记录，非代币）

### 1.3 为什么不发行ERC-20？

| 考虑因素 | ERC-20方案 | 虚拟份额方案 |
|---------|-----------|-------------|
| DeFi可组合性 | ✅ 高 | ❌ 低 |
| Gas成本 | ❌ 高（transfer/approval） | ✅ 低 |
| 锁定复杂度 | ❌ 需外部approval | ✅ 内置管理 |
| 防套利 | ❌ 可转移 | ✅ 绑定地址 |
| 流动性需求 | ✅ 需要 | ❌ 不需要（长期锁定） |

**结论**：声誉抵押场景使用虚拟份额更优，无需流动性。

详细分析见：[`docs/lock-mechanism.md`](/docs/lock-mechanism.md)

---

## 2. SuperPaymaster Gas价格计算改进

### 2.1 当前实现分析

```solidity
// PaymasterV4.sol 第321-348行
function _calculatePNTAmount(uint256 gasCostWei, address gasToken) internal view returns (uint256) {
    // Step 1: 获取ETH/USD价格
    (, int256 ethUsdPrice,, uint256 updatedAt,) = ethUsdPriceFeed.latestRoundData();

    // ✅ 已实现：Staleness check（1小时）
    if (block.timestamp - updatedAt > 3600) {
        revert PaymasterV4__InvalidTokenBalance();
    }

    uint8 decimals = ethUsdPriceFeed.decimals();
    uint256 ethPriceUSD = uint256(ethUsdPrice) * 1e18 / (10 ** decimals);

    // Step 2: Gas cost (wei) → USD
    uint256 gasCostUSD = (gasCostWei * ethPriceUSD) / 1e18;

    // Step 3: 加上服务费
    uint256 totalCostUSD = gasCostUSD * (BPS_DENOMINATOR + serviceFeeRate) / BPS_DENOMINATOR;

    // Step 4: 获取token价格（从GasToken合约）
    uint256 tokenPriceUSD = IGasTokenPrice(gasToken).getEffectivePrice();

    // Step 5: USD → Token数量
    uint256 tokenAmount = (totalCostUSD * 1e18) / tokenPriceUSD;

    return tokenAmount;
}
```

### 2.2 改进方案：Chainlink集成最佳实践

#### 问题1：ethUsdPriceFeed已经是immutable
```solidity
// PaymasterV4.sol 第62行
AggregatorV3Interface public immutable ethUsdPriceFeed;
```
✅ **已解决**：部署时设置，无法修改（gas优化）

#### 问题2：Staleness check可配置化

```solidity
// 当前：硬编码1小时
if (block.timestamp - updatedAt > 3600) {
    revert PaymasterV4__InvalidTokenBalance();
}

// 改进：可配置
uint256 public priceMaxAge = 3600;  // 默认1小时

function setPriceMaxAge(uint256 _maxAge) external onlyOwner {
    require(_maxAge >= 300 && _maxAge <= 86400, "Invalid range");  // 5分钟-24小时
    priceMaxAge = _maxAge;
}

// 使用
if (block.timestamp - updatedAt > priceMaxAge) {
    revert PaymasterV4__StalePriceFeed();
}
```

#### 问题3：价格为0或负数的边界检查

```solidity
// 改进后的Step 1
(, int256 ethUsdPrice,, uint256 updatedAt,) = ethUsdPriceFeed.latestRoundData();

// ✅ 添加价格有效性检查
require(ethUsdPrice > 0, "Invalid ETH price");

if (block.timestamp - updatedAt > priceMaxAge) {
    revert PaymasterV4__StalePriceFeed();
}
```

#### 问题4：最大Gas成本限制

```solidity
// 添加gasCostCap检查（防止异常高gas导致计算溢出）
function _calculatePNTAmount(uint256 gasCostWei, address gasToken) internal view returns (uint256) {
    // ✅ 新增：检查gas cost上限
    if (gasCostWei > maxGasCostCap) {
        revert PaymasterV4__GasCostTooHigh();
    }

    // ... 原有逻辑
}
```

### 2.3 业界最佳实践对比

| 实践 | Uniswap V3 Oracle | Aave V3 | Compound V3 | **我们当前** | **改进后** |
|------|------------------|---------|-------------|------------|-----------|
| Price feed immutable | ✅ | ✅ | ✅ | ✅ | ✅ |
| Staleness check | ✅ | ✅ | ✅ | ✅ | ✅ |
| Price validation | ✅ | ✅ | ✅ | ❌ | ✅ |
| Configurable timeout | ❌ | ✅ | ✅ | ❌ | ✅ |
| Circuit breaker | ✅ | ✅ | ❌ | ❌ | ⚠️ 可选 |

**建议**：
- ✅ 必需：价格有效性检查（>0）
- ✅ 建议：可配置staleness timeout
- ⚠️ 可选：Circuit breaker（暂停交易）

### 2.4 改进代码示例

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract PaymasterV4Improved {
    // ====================================
    // Storage
    // ====================================

    /// @notice Chainlink ETH/USD price feed (immutable)
    AggregatorV3Interface public immutable ethUsdPriceFeed;

    /// @notice Maximum age of price data (default 1 hour)
    uint256 public priceMaxAge = 3600;

    /// @notice Minimum acceptable ETH/USD price (circuit breaker)
    uint256 public minEthPrice = 1000e18;  // $1000

    /// @notice Maximum acceptable ETH/USD price (circuit breaker)
    uint256 public maxEthPrice = 100000e18;  // $100,000

    // ====================================
    // Errors
    // ====================================

    error PaymasterV4__StalePriceFeed(uint256 age, uint256 maxAge);
    error PaymasterV4__InvalidEthPrice(uint256 price);
    error PaymasterV4__PriceOutOfBounds(uint256 price, uint256 min, uint256 max);
    error PaymasterV4__GasCostTooHigh(uint256 cost, uint256 max);

    // ====================================
    // Improved Price Calculation
    // ====================================

    /**
     * @notice Calculate required token amount for gas cost
     * @dev Uses Chainlink with comprehensive validation
     * @param gasCostWei Gas cost in wei
     * @param gasToken GasToken contract address
     * @return Required token amount
     */
    function _calculatePNTAmount(uint256 gasCostWei, address gasToken)
        internal
        view
        returns (uint256)
    {
        // ✅ Step 0: Validate gas cost
        if (gasCostWei > maxGasCostCap) {
            revert PaymasterV4__GasCostTooHigh(gasCostWei, maxGasCostCap);
        }

        // ✅ Step 1: Get ETH/USD price with comprehensive checks
        (, int256 ethUsdPrice,, uint256 updatedAt,) = ethUsdPriceFeed.latestRoundData();

        // Check 1: Price must be positive
        if (ethUsdPrice <= 0) {
            revert PaymasterV4__InvalidEthPrice(uint256(ethUsdPrice));
        }

        // Check 2: Staleness check
        uint256 priceAge = block.timestamp - updatedAt;
        if (priceAge > priceMaxAge) {
            revert PaymasterV4__StalePriceFeed(priceAge, priceMaxAge);
        }

        // Convert to 18 decimals
        uint8 decimals = ethUsdPriceFeed.decimals();
        uint256 ethPriceUSD = uint256(ethUsdPrice) * 1e18 / (10 ** decimals);

        // Check 3: Circuit breaker (optional)
        if (ethPriceUSD < minEthPrice || ethPriceUSD > maxEthPrice) {
            revert PaymasterV4__PriceOutOfBounds(ethPriceUSD, minEthPrice, maxEthPrice);
        }

        // Step 2: Convert gas cost (wei) to USD
        uint256 gasCostUSD = (gasCostWei * ethPriceUSD) / 1e18;

        // Step 3: Add service fee
        uint256 totalCostUSD = gasCostUSD * (BPS_DENOMINATOR + serviceFeeRate) / BPS_DENOMINATOR;

        // Step 4: Get token's effective price (handles aPNT/xPNT automatically)
        uint256 tokenPriceUSD = IGasTokenPrice(gasToken).getEffectivePrice();

        // Step 5: Convert USD to token amount
        uint256 tokenAmount = (totalCostUSD * 1e18) / tokenPriceUSD;

        return tokenAmount;
    }

    // ====================================
    // Admin Functions
    // ====================================

    /**
     * @notice Update price staleness tolerance
     * @param _maxAge New max age in seconds (300-86400)
     */
    function setPriceMaxAge(uint256 _maxAge) external onlyOwner {
        require(_maxAge >= 300 && _maxAge <= 86400, "Invalid range");
        priceMaxAge = _maxAge;
    }

    /**
     * @notice Update circuit breaker bounds
     * @param _minPrice Minimum acceptable ETH price
     * @param _maxPrice Maximum acceptable ETH price
     */
    function setPriceBounds(uint256 _minPrice, uint256 _maxPrice) external onlyOwner {
        require(_minPrice > 0 && _minPrice < _maxPrice, "Invalid bounds");
        minEthPrice = _minPrice;
        maxEthPrice = _maxPrice;
    }
}
```

---

## 3. aPNT价格管理方案

### 3.1 当前GasTokenV2实现

```solidity
// GasTokenV2.sol
function getEffectivePrice() external view returns (uint256) {
    if (basePriceToken == address(0)) {
        // aPNT base token: 直接返回priceUSD
        return priceUSD;  // 0.02e18
    } else {
        // xPNT derived token: basePrice * exchangeRate
        uint256 basePrice = IGasTokenPrice(basePriceToken).getEffectivePrice();
        return (basePrice * exchangeRate) / 1e18;
    }
}
```

### 3.2 问题：aPNT价格固定为0.02U

```solidity
// 部署时设置
aPNT = new GasTokenV2("Alpha PNT", "aPNT", paymaster, address(0), 1e18, 0.02e18);
//                                                                   ^^^^^^^^^^^^^^
//                                                                   固定价格
```

**问题**：
- ❌ 价格固定，无法反映市场波动
- ❌ 后期需从Swap获取实时价格

### 3.3 改进方案：分阶段价格策略

#### 阶段1：固定价格（初期，当前实现）

```solidity
// GasTokenV2.sol
contract GasTokenV2 {
    uint256 public priceUSD;  // 固定价格（如0.02e18）

    function getEffectivePrice() external view returns (uint256) {
        return priceUSD;  // 直接返回
    }

    // Owner可调整（治理）
    function setPriceUSD(uint256 _newPrice) external {
        require(msg.sender == paymaster, "Only paymaster");
        priceUSD = _newPrice;
    }
}
```

**优势**：
- ✅ 简单可靠
- ✅ Gas成本低
- ✅ 适合初期稳定运营

**劣势**：
- ❌ 需人工调整
- ❌ 无法反映实时市场

#### 阶段2：Swap集成（后期推荐）

```solidity
// GasTokenV2.sol (升级版)
contract GasTokenV2WithSwap {
    uint256 public fixedPriceUSD;      // 保底价格
    address public swapOracle;         // Uniswap V3 TWAP或其他Oracle
    bool public useSwapPrice;          // 是否使用Swap价格

    function getEffectivePrice() external view returns (uint256) {
        if (useSwapPrice && swapOracle != address(0)) {
            // 从Swap获取实时价格
            uint256 swapPrice = ISwapOracle(swapOracle).getPrice(address(this));

            // 使用较高者（保护用户）
            return swapPrice > fixedPriceUSD ? swapPrice : fixedPriceUSD;
        }

        // Fallback：固定价格
        return fixedPriceUSD;
    }

    // Admin: 设置Swap Oracle
    function setSwapOracle(address _oracle, bool _useSwap) external onlyOwner {
        swapOracle = _oracle;
        useSwapPrice = _useSwap;
    }
}
```

**Swap Oracle选项**：

| 方案 | 优势 | 劣势 | Gas成本 |
|------|------|------|--------|
| **Uniswap V3 TWAP** | ✅ 抗操纵 | ⚠️ 需流动性池 | 中 |
| **Chainlink Data Feed** | ✅ 高可靠 | ❌ 需部署feed | 低 |
| **自定义Oracle** | ✅ 灵活 | ❌ 需维护 | 低 |
| **多Oracle聚合** | ✅ 最安全 | ❌ Gas最高 | 高 |

**推荐**：Uniswap V3 TWAP（30分钟均价）

#### 阶段2实现示例：Uniswap V3 TWAP

```solidity
// SwapOracle.sol
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/libraries/OracleLibrary.sol";

contract UniswapV3TWAPOracle {
    IUniswapV3Pool public immutable pool;  // aPNT/USDC池
    uint32 public immutable twapInterval;  // TWAP周期（如1800秒 = 30分钟）

    constructor(address _pool, uint32 _interval) {
        pool = IUniswapV3Pool(_pool);
        twapInterval = _interval;
    }

    /**
     * @notice 获取aPNT的TWAP价格
     * @return priceUSD aPNT价格（18 decimals）
     */
    function getPrice(address token) external view returns (uint256 priceUSD) {
        // 获取TWAP tick
        (int24 arithmeticMeanTick,) = OracleLibrary.consult(address(pool), twapInterval);

        // Tick → 价格
        uint256 quoteAmount = OracleLibrary.getQuoteAtTick(
            arithmeticMeanTick,
            1e18,  // 1 aPNT
            token,
            pool.token1()  // USDC
        );

        // USDC有6 decimals，转换为18 decimals
        priceUSD = quoteAmount * 1e12;

        return priceUSD;
    }
}
```

### 3.4 渐进式迁移路径

```
阶段1（当前）: 固定价格0.02U
   ↓ (3-6个月)
阶段2: 启用Swap Oracle，但保留固定价格作为floor
   ↓ (观察期)
阶段3: 完全依赖Swap价格
```

**你的建议评估**：
> "此价格可能后期从swap合约实时获得，初期固定价格，你觉得这样如何？"

✅ **非常合理**！建议：
1. 初期固定0.02U（已实现）
2. 添加`setPriceUSD()`治理接口（人工调整）
3. 后期集成Uniswap V3 TWAP
4. 使用`max(swapPrice, fixedPrice)`保护用户

---

## 4. xPNT/aPNT双重扣费流程设计

### 4.1 用户提问理解

> "我理解会发生两次扣费:
> - 一次是superpaymster合约作为结算合约，有权利预approve并从用户账户扣除xpnts到paymaster的treasury
> - 一次是从paymaterdeposit到superpaymaster的内部apnts账户扣除对应的apnts。"

### 4.2 扣费流程分析

#### 当前流程（PaymasterV4单独使用）

```
用户发起UserOp
   ↓
EntryPoint调用 validatePaymasterUserOp()
   ↓
PaymasterV4检查用户aPNT余额和allowance
   ↓
PaymasterV4.transferFrom(user, treasury, aPNTAmount)
   ↓
✅ 扣费完成（单次扣费）
```

#### SuperPaymaster共享模式流程（你的理解）

```
                          ┌─────────────────────────┐
                          │ 用户发起UserOp          │
                          │ (指定xPNT支付)          │
                          └────────────┬────────────┘
                                       ↓
                          ┌─────────────────────────┐
                          │ EntryPoint路由          │
                          │ → SuperPaymaster        │
                          └────────────┬────────────┘
                                       ↓
         ┌─────────────────────────────────────────────────────┐
         │ SuperPaymaster (结算合约)                           │
         │                                                     │
         │ 1. 计算gas cost (gwei)                             │
         │ 2. Chainlink获取ETH价格 → USD                       │
         │ 3. USD → aPNT数量 (÷0.02)                           │
         │ 4. 根据汇率计算xPNT数量 (aPNT * 4)                   │
         │                                                     │
         │ ✅ 第一次扣费：                                      │
         │   xPNT.transferFrom(user, paymasterTreasury, xAmount) │
         └────────────┬────────────────────────────────────────┘
                      ↓
         ┌─────────────────────────────────────────────────────┐
         │ ✅ 第二次扣费：                                      │
         │   从Paymaster的EntryPoint deposit扣除aPNT等值的ETH  │
         │   (内部记账，非真实转账)                              │
         │                                                     │
         │   SuperPaymaster.apntBalances[paymaster] -= aPNTAmount │
         └─────────────────────────────────────────────────────┘
```

### 4.3 问题识别

#### 问题1：第二次扣费的"aPNT"是什么？

**混淆点**：
- aPNT是ERC-20代币（用户持有）
- EntryPoint的deposit是ETH（不是aPNT）

**澄清**：
```solidity
// EntryPoint存储的是ETH，不是aPNT
mapping(address => uint256) public balanceOf;  // Paymaster的ETH deposit

// 如果要内部记账aPNT，需要在SuperPaymaster中
mapping(address => uint256) public apntBalances;  // Paymaster的aPNT deposit
```

#### 问题2：为什么需要两次扣费？

**场景**：
1. **用户**：持有xPNT（社区积分）
2. **Paymaster**：需要aPNT充值到SuperPaymaster
3. **SuperPaymaster**：最终用ETH支付EntryPoint

**流程重新设计**：

```
阶段1：Paymaster预充值aPNT到SuperPaymaster
┌────────────────────────────────────────────┐
│ Paymaster.depositAPNT()                    │
│   ↓                                        │
│ aPNT.transferFrom(paymaster, superPM, X)   │
│   ↓                                        │
│ SuperPaymaster.apntBalances[paymaster] += X│
└────────────────────────────────────────────┘

阶段2：用户交易时的双重扣费
┌────────────────────────────────────────────┐
│ ✅ 扣费1：用户xPNT → Paymaster Treasury     │
│   xPNT.transferFrom(user, pmTreasury, xAmt) │
│                                            │
│ ✅ 扣费2：Paymaster aPNT deposit → 消耗     │
│   SuperPaymaster.apntBalances[pm] -= aAmt  │
│                                            │
│ 同时：SuperPaymaster ETH deposit → EP      │
│   (支付EntryPoint真实gas费用)               │
└────────────────────────────────────────────┘
```

### 4.4 完整合约设计

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title SuperPaymasterV2
 * @notice 共享Paymaster路由，支持xPNT→aPNT汇率转换
 */
contract SuperPaymasterV2 {
    // ====================================
    // Storage
    // ====================================

    /// @notice 注册的Paymaster信息
    struct PaymasterInfo {
        address paymasterAddress;
        address xPNTToken;          // 该Paymaster的社区积分
        address basePriceToken;     // aPNT地址
        uint256 exchangeRate;       // xPNT:aPNT汇率（如4e18 = 1:4）
        address treasury;           // 收款地址
        bool isActive;
    }

    /// @notice Paymaster注册表
    mapping(address => PaymasterInfo) public paymasters;

    /// @notice Paymaster的aPNT余额（内部记账）
    mapping(address => uint256) public apntBalances;

    /// @notice aPNT代币地址
    address public immutable aPNT;

    /// @notice EntryPoint地址
    IEntryPoint public immutable entryPoint;

    // ====================================
    // Paymaster Management
    // ====================================

    /**
     * @notice 注册Paymaster到SuperPaymaster
     * @param xPNTToken 社区积分地址
     * @param exchangeRate xPNT:aPNT汇率（1e18 = 1:1, 4e18 = 1:4）
     * @param treasury 收款地址
     */
    function registerPaymaster(
        address xPNTToken,
        uint256 exchangeRate,
        address treasury
    ) external {
        require(!paymasters[msg.sender].isActive, "Already registered");
        require(exchangeRate > 0, "Invalid rate");

        paymasters[msg.sender] = PaymasterInfo({
            paymasterAddress: msg.sender,
            xPNTToken: xPNTToken,
            basePriceToken: aPNT,
            exchangeRate: exchangeRate,
            treasury: treasury,
            isActive: true
        });

        emit PaymasterRegistered(msg.sender, xPNTToken, exchangeRate);
    }

    /**
     * @notice Paymaster充值aPNT到SuperPaymaster
     * @param amount aPNT数量
     */
    function depositAPNT(uint256 amount) external {
        PaymasterInfo storage pm = paymasters[msg.sender];
        require(pm.isActive, "Not registered");

        // 转入aPNT
        IERC20(aPNT).transferFrom(msg.sender, address(this), amount);

        // 内部记账
        apntBalances[msg.sender] += amount;

        emit APNTDeposited(msg.sender, amount);
    }

    /**
     * @notice Paymaster提取aPNT
     * @param amount aPNT数量
     */
    function withdrawAPNT(uint256 amount) external {
        require(apntBalances[msg.sender] >= amount, "Insufficient balance");

        apntBalances[msg.sender] -= amount;
        IERC20(aPNT).transfer(msg.sender, amount);

        emit APNTWithdrawn(msg.sender, amount);
    }

    // ====================================
    // Core Paymaster Logic
    // ====================================

    /**
     * @notice EntryPoint调用：验证并处理支付
     * @param userOp 用户操作
     * @param userOpHash 操作哈希
     * @param maxCost 最大成本（ETH）
     * @return context 上下文数据
     * @return validationData 验证数据
     */
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external returns (bytes memory context, uint256 validationData) {
        // 1. 解析paymasterData: [paymasterAddress(20) | userSpecifiedToken(20)]
        (address paymaster, address userToken) = _parsePaymasterData(userOp.paymasterAndData);

        // 2. 验证Paymaster已注册
        PaymasterInfo storage pm = paymasters[paymaster];
        require(pm.isActive, "Paymaster not active");

        // 3. 计算所需费用
        (uint256 aPNTAmount, uint256 xPNTAmount) = _calculateFees(maxCost, paymaster);

        // 4. 验证Paymaster有足够的aPNT余额
        require(apntBalances[paymaster] >= aPNTAmount, "Insufficient aPNT");

        // 5. 验证用户有足够的xPNT
        address user = userOp.sender;
        require(
            IERC20(pm.xPNTToken).balanceOf(user) >= xPNTAmount,
            "Insufficient xPNT"
        );
        require(
            IERC20(pm.xPNTToken).allowance(user, address(this)) >= xPNTAmount,
            "Insufficient allowance"
        );

        // ✅ 第一次扣费：用户xPNT → Paymaster Treasury
        IERC20(pm.xPNTToken).transferFrom(user, pm.treasury, xPNTAmount);

        // ✅ 第二次扣费：预留Paymaster的aPNT余额（实际扣除在postOp）
        // apntBalances[paymaster] -= aPNTAmount;  // 延迟到postOp

        // 打包上下文
        context = abi.encode(paymaster, user, aPNTAmount, xPNTAmount);
        validationData = 0;  // 验证通过
    }

    /**
     * @notice EntryPoint调用：支付后处理
     * @param mode 模式（OpSucceeded/OpReverted/PostOpReverted）
     * @param context validatePaymasterUserOp返回的上下文
     * @param actualGasCost 实际gas成本（ETH）
     * @param actualUserOpFeePerGas 实际用户操作费用/gas
     */
    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external {
        // 解包上下文
        (address paymaster, address user, uint256 aPNTAmount, uint256 xPNTAmount) =
            abi.decode(context, (address, address, uint256, uint256));

        // ✅ 第二次扣费：扣除Paymaster的aPNT余额
        apntBalances[paymaster] -= aPNTAmount;

        // 记录消费
        emit UserOpProcessed(paymaster, user, xPNTAmount, aPNTAmount, actualGasCost);
    }

    // ====================================
    // Internal Functions
    // ====================================

    /**
     * @notice 计算所需费用
     * @param gasCostWei Gas成本（wei）
     * @param paymaster Paymaster地址
     * @return aPNTAmount 需要的aPNT数量
     * @return xPNTAmount 需要的xPNT数量
     */
    function _calculateFees(uint256 gasCostWei, address paymaster)
        internal
        view
        returns (uint256 aPNTAmount, uint256 xPNTAmount)
    {
        // Step 1: 获取ETH/USD价格
        uint256 ethPriceUSD = _getETHPrice();

        // Step 2: Gas cost (wei) → USD
        uint256 gasCostUSD = (gasCostWei * ethPriceUSD) / 1e18;

        // Step 3: USD → aPNT数量（假设aPNT = $0.02）
        uint256 aPNTPriceUSD = 0.02e18;  // TODO: 后期从GasToken获取
        aPNTAmount = (gasCostUSD * 1e18) / aPNTPriceUSD;

        // Step 4: aPNT → xPNT数量（根据汇率）
        PaymasterInfo storage pm = paymasters[paymaster];
        xPNTAmount = (aPNTAmount * pm.exchangeRate) / 1e18;
        // 例如：exchangeRate = 4e18，则xPNT = aPNT * 4
    }

    /**
     * @notice 获取ETH/USD价格（从Chainlink）
     * @return ethPriceUSD ETH价格（18 decimals）
     */
    function _getETHPrice() internal view returns (uint256 ethPriceUSD) {
        // 实现见上文"2.4 改进代码示例"
        // ...
    }

    /**
     * @notice 解析paymasterData
     * @param paymasterAndData EntryPoint传入的数据
     * @return paymaster Paymaster地址
     * @return userToken 用户指定的token（可选）
     */
    function _parsePaymasterData(bytes calldata paymasterAndData)
        internal
        pure
        returns (address paymaster, address userToken)
    {
        // paymasterAndData格式：
        // [0:20] = SuperPaymaster地址（已知）
        // [20:40] = 目标Paymaster地址
        // [40:60] = 用户指定的token（可选）

        paymaster = address(bytes20(paymasterAndData[20:40]));

        if (paymasterAndData.length >= 60) {
            userToken = address(bytes20(paymasterAndData[40:60]));
        } else {
            userToken = address(0);
        }
    }
}
```

### 4.5 完整扣费示例

#### 场景：Alice使用xPNT支付gas

**前提条件**：
- Alice余额：1000 xPNT
- Paymaster余额：500 aPNT（已充值到SuperPaymaster）
- 汇率：1 aPNT = 4 xPNT（exchangeRate = 4e18）
- aPNT价格：$0.02
- Gas成本：0.001 ETH（假设ETH = $4000）

**计算过程**：
```
1. Gas cost (wei) → USD:
   0.001 ETH * $4000 = $4

2. USD → aPNT:
   $4 / $0.02 = 200 aPNT

3. aPNT → xPNT (汇率1:4):
   200 aPNT * 4 = 800 xPNT
```

**扣费流程**：
```
validatePaymasterUserOp():
  ✅ 扣费1: xPNT.transferFrom(Alice, PaymasterTreasury, 800 xPNT)
     Alice余额: 1000 → 200 xPNT
     Paymaster Treasury: +800 xPNT

postOp():
  ✅ 扣费2: SuperPaymaster.apntBalances[Paymaster] -= 200 aPNT
     Paymaster aPNT余额: 500 → 300 aPNT

同时（EntryPoint内部）:
  SuperPaymaster ETH deposit → 支付EntryPoint
     SuperPaymaster.balanceOf -= 0.001 ETH
```

**最终状态**：
- Alice：-800 xPNT
- Paymaster Treasury：+800 xPNT（可后续兑换/使用）
- Paymaster aPNT余额：-200 aPNT
- SuperPaymaster：-0.001 ETH（支付给EntryPoint）

---

## 5. 实现路线图

### 阶段1：Gas价格计算改进（1-2周）

- [ ] 添加价格有效性检查（>0）
- [ ] 实现可配置的priceMaxAge
- [ ] 添加circuit breaker（可选）
- [ ] 编写单元测试
- [ ] 审计gas优化

### 阶段2：aPNT价格管理（2-3周）

- [ ] 保留固定价格0.02U
- [ ] 添加`setPriceUSD()`治理接口
- [ ] 设计Uniswap V3 TWAP Oracle
- [ ] 实现价格切换逻辑
- [ ] 部署测试网验证

### 阶段3：SuperPaymaster双重扣费（3-4周）

- [ ] 实现PaymasterInfo注册
- [ ] 实现aPNT deposit/withdraw
- [ ] 实现xPNT→aPNT汇率转换
- [ ] 实现validatePaymasterUserOp双重扣费
- [ ] 编写集成测试
- [ ] 前端UI集成

### 阶段4：测试与部署（2周）

- [ ] 完整端到端测试
- [ ] Gas成本分析
- [ ] 安全审计
- [ ] 主网部署
- [ ] 文档更新

---

## 6. 风险与缓解

| 风险 | 影响 | 缓解措施 |
|------|------|---------|
| **Chainlink price stale** | ❌ 交易失败 | ✅ Staleness check + 可配置timeout |
| **aPNT价格波动** | ⚠️ 套利攻击 | ✅ 初期固定价格 + 后期TWAP平滑 |
| **xPNT汇率过时** | ⚠️ 用户损失 | ✅ 治理可调整exchangeRate |
| **Paymaster aPNT余额不足** | ❌ 服务中断 | ✅ 预警机制 + 自动充值 |
| **双重扣费失败** | ❌ 资金锁定 | ✅ 原子性保证 + postOp清理 |

---

## 7. 总结

### 核心改进点

1. ✅ **统一认知**：stGToken是虚拟份额，使用Lido机制
2. ✅ **Chainlink最佳实践**：价格验证 + 可配置staleness + circuit breaker
3. ✅ **aPNT价格渐进式**：固定价格（初期）→ Swap TWAP（后期）
4. ✅ **双重扣费设计**：用户xPNT→Treasury + Paymaster aPNT消耗

### 你的方案评估

| 你的建议 | 评估 | 建议 |
|---------|------|------|
| Chainlink immutable | ✅ 已实现 | 保持 |
| aPNT初期固定0.02U | ✅ 合理 | 添加治理接口 |
| 后期从Swap获取 | ✅ 最佳实践 | 推荐Uniswap V3 TWAP |
| 双重扣费机制 | ✅ 设计清晰 | 按上述流程实现 |

**下一步行动**：选择阶段1开始实现，逐步迭代。

---

**文档版本**: 1.0
**最后更新**: 2025-01-26
**作者**: Claude Code
**审核**: 待技术负责人审批
