# Paymaster运营者指南 | Paymaster Operator Guide

**English** | [中文](#chinese)

## Overview

As a Paymaster Operator, you can run your own gas sponsorship service and register it with SuperPaymaster to reach more users through the decentralized marketplace.

## 🎯 Why Become a Paymaster Operator?

### Revenue Opportunities
- **Service Fees**: Charge competitive fees for gas sponsorship
- **Volume Scale**: Access to all dApps using SuperPaymaster
- **Market Discovery**: Automatic user acquisition without individual dApp integrations

### Business Models
1. **Sponsored Paymaster**: Free gas for specific user actions (marketing/growth)
2. **ERC-20 Paymaster**: Users pay gas fees with tokens instead of ETH
3. **Subscription Paymaster**: Monthly/yearly plans for gas coverage
4. **API Paymaster**: Per-transaction pricing for dApp partnerships

## 🛠️ Technical Requirements

### 1. Deploy Your Paymaster Contract

Your paymaster must implement the appropriate interface:

```solidity
// For EntryPoint v0.6
import "@account-abstraction-v6/interfaces/IPaymaster.sol";

// For EntryPoint v0.7
import "@account-abstraction-v7/interfaces/IPaymasterV7.sol";

contract MyPaymaster is IPaymasterV7 {
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 requiredPreFund
    ) external returns (bytes memory context, uint256 validationData) {
        // Your validation logic
        // Return validationData = 0 for success
    }
    
    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external {
        // Post-execution logic (optional)
    }
}
```

### 2. Fund Your Paymaster

```solidity
// Deposit ETH to EntryPoint for gas payments
IEntryPoint entryPoint = IEntryPoint(ENTRY_POINT_ADDRESS);
entryPoint.depositTo{value: depositAmount}(address(myPaymaster));

// Add stake for reputation (optional but recommended)
entryPoint.addStake{value: stakeAmount}(unstakeDelaySec);
```

### 3. Register with SuperPaymaster

```solidity
SuperPaymasterV7 router = SuperPaymasterV7(ROUTER_ADDRESS);

// Register your paymaster
router.registerPaymaster(
    address(myPaymaster),    // Your paymaster contract
    100,                     // Fee rate (1% = 100 basis points)
    "My Premium Paymaster"   // Display name
);
```

## 💼 Operations Guide

### Setting Competitive Fees

```solidity
// Update your fee rate to stay competitive
router.updateFeeRate(80);  // Reduce to 0.8%
```

**Fee Strategy Tips:**
- Monitor other paymasters: `router.getActivePaymasters()`
- Lower fees = more user operations routed to you
- Higher fees = better margins but less volume
- Consider dynamic pricing based on network conditions

### Monitoring Your Performance

```solidity
// Check your paymaster statistics
IPaymasterRouter.PaymasterPool memory info = router.getPaymasterInfo(myPaymaster);

console.log("Success Rate:", info.successCount * 100 / info.totalAttempts);
console.log("Total Volume:", info.totalAttempts);
console.log("Current Fee Rate:", info.feeRate);
```

### Managing Liquidity

```javascript
// Monitor your EntryPoint balance
const balance = await entryPoint.balanceOf(myPaymasterAddress);
const threshold = ethers.utils.parseEther("1.0"); // 1 ETH minimum

if (balance.lt(threshold)) {
    // Auto-refill logic
    await entryPoint.depositTo(myPaymasterAddress, {
        value: ethers.utils.parseEther("10.0")
    });
}
```

## 📊 Business Analytics

### Key Metrics to Track

1. **Volume Metrics**
   - Daily/monthly user operations
   - Success vs failure rates
   - Average gas cost per operation

2. **Financial Metrics**
   - Revenue from fees
   - Gas costs (your expenses)
   - Profit margins per operation
   - Return on stake investment

3. **Competitive Metrics**
   - Market share in SuperPaymaster
   - Fee rate compared to competitors
   - User retention rates

### Sample Analytics Dashboard

```javascript
class PaymasterAnalytics {
    async getDailyStats(paymaster) {
        const info = await router.getPaymasterInfo(paymaster);
        const events = await router.queryFilter(
            router.filters.PaymasterSelected(paymaster)
        );
        
        return {
            totalOperations: info.totalAttempts,
            successfulOperations: info.successCount,
            successRate: (info.successCount / info.totalAttempts * 100).toFixed(2),
            dailyVolume: events.filter(e => isToday(e.blockNumber)).length
        };
    }
}
```

## 🚀 Growth Strategies

### 1. Competitive Positioning
- **Price Leadership**: Lowest fees in specific market segments
- **Service Quality**: Higher success rates and faster processing
- **Specialized Services**: Focus on specific use cases (DeFi, Gaming, NFTs)

### 2. Partnership Opportunities
- **Direct dApp Integrations**: Private agreements outside SuperPaymaster
- **Cross-promotion**: Partner with other paymasters for specialized routing
- **Liquidity Partnerships**: Shared gas pools for better capital efficiency

### 3. Advanced Features
- **Dynamic Pricing**: Adjust fees based on network congestion
- **User Scoring**: Different rates for different user tiers
- **Batch Processing**: Optimize gas costs through batching
- **MEV Integration**: Capture additional revenue from MEV opportunities

## 🔧 Technical Integration Examples

### ERC-20 Paymaster Implementation

```solidity
contract ERC20Paymaster is SuperPaymasterV7 {
    IERC20 public token;
    uint256 public exchangeRate; // tokens per ETH
    
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 requiredPreFund
    ) external override returns (bytes memory context, uint256 validationData) {
        // Check user has enough tokens
        uint256 tokenAmount = requiredPreFund * exchangeRate / 1e18;
        require(token.balanceOf(userOp.sender) >= tokenAmount, "Insufficient tokens");
        
        // Return success
        return (abi.encode(userOp.sender, tokenAmount), 0);
    }
    
    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external override {
        (address user, uint256 tokenAmount) = abi.decode(context, (address, uint256));
        
        // Charge user in tokens
        token.transferFrom(user, address(this), tokenAmount);
    }
}
```

### Subscription Paymaster Implementation

```solidity
contract SubscriptionPaymaster is SuperPaymasterV7 {
    mapping(address => uint256) public subscriptions; // user => expiry timestamp
    uint256 public monthlyPrice = 0.01 ether;
    
    function subscribe() external payable {
        require(msg.value >= monthlyPrice, "Insufficient payment");
        subscriptions[msg.sender] = block.timestamp + 30 days;
    }
    
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 requiredPreFund
    ) external override returns (bytes memory context, uint256 validationData) {
        // Check subscription
        require(subscriptions[userOp.sender] > block.timestamp, "Subscription expired");
        
        return ("", 0); // Free for subscribers
    }
}
```

## 📋 Operator Checklist

### Pre-Launch
- [ ] Deploy and test paymaster contract
- [ ] Fund paymaster with sufficient ETH
- [ ] Add stake to EntryPoint (recommended)
- [ ] Register with SuperPaymaster
- [ ] Set up monitoring and alerts
- [ ] Configure auto-refill mechanisms

### Daily Operations
- [ ] Monitor EntryPoint balance
- [ ] Check success rates and performance
- [ ] Analyze competitor fee rates
- [ ] Review daily transaction volume
- [ ] Update fees if necessary

### Growth & Optimization
- [ ] Analyze user behavior patterns
- [ ] A/B test different fee structures
- [ ] Explore partnership opportunities
- [ ] Implement advanced features
- [ ] Scale infrastructure for higher volume

---

<a name="chinese"></a>

# Paymaster运营者指南

[English](#overview) | **中文**

## 概述

作为Paymaster运营者，您可以运营自己的gas赞助服务，并将其注册到SuperPaymaster，通过去中心化市场接触更多用户。

## 🎯 为什么成为Paymaster运营者？

### 收益机会
- **服务费用**: 为gas赞助收取竞争性费用
- **规模效应**: 接触所有使用SuperPaymaster的dApp
- **市场发现**: 无需单独集成即可自动获取用户

### 商业模式
1. **赞助式Paymaster**: 为特定用户行为提供免费gas（营销/增长）
2. **ERC-20 Paymaster**: 用户用代币而非ETH支付gas费
3. **订阅式Paymaster**: 月付/年付的gas覆盖计划
4. **API Paymaster**: 面向dApp合作伙伴的按次计费

## 🛠️ 技术要求

### 1. 部署您的Paymaster合约

您的paymaster必须实现相应的接口：

```solidity
// 用于EntryPoint v0.6
import "@account-abstraction-v6/interfaces/IPaymaster.sol";

// 用于EntryPoint v0.7
import "@account-abstraction-v7/interfaces/IPaymasterV7.sol";

contract MyPaymaster is IPaymasterV7 {
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 requiredPreFund
    ) external returns (bytes memory context, uint256 validationData) {
        // 您的验证逻辑
        // 返回validationData = 0表示成功
    }
    
    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external {
        // 执行后逻辑（可选）
    }
}
```

### 2. 为您的Paymaster充值

```solidity
// 向EntryPoint存入ETH用于gas支付
IEntryPoint entryPoint = IEntryPoint(ENTRY_POINT_ADDRESS);
entryPoint.depositTo{value: depositAmount}(address(myPaymaster));

// 添加质押以提高声誉（可选但推荐）
entryPoint.addStake{value: stakeAmount}(unstakeDelaySec);
```

### 3. 向SuperPaymaster注册

```solidity
SuperPaymasterV7 router = SuperPaymasterV7(ROUTER_ADDRESS);

// 注册您的paymaster
router.registerPaymaster(
    address(myPaymaster),    // 您的paymaster合约
    100,                     // 费率（1% = 100基点）
    "My Premium Paymaster"   // 显示名称
);
```

## 💼 运营指南

### 设置竞争性费率

```solidity
// 更新费率以保持竞争力
router.updateFeeRate(80);  // 降低到0.8%
```

**费率策略提示:**
- 监控其他paymaster: `router.getActivePaymasters()`
- 更低费率 = 更多用户操作路由到您
- 更高费率 = 更好利润率但交易量较少
- 考虑基于网络状况的动态定价

### 监控您的性能

```solidity
// 检查您的paymaster统计信息
IPaymasterRouter.PaymasterPool memory info = router.getPaymasterInfo(myPaymaster);

console.log("成功率:", info.successCount * 100 / info.totalAttempts);
console.log("总交易量:", info.totalAttempts);
console.log("当前费率:", info.feeRate);
```

### 管理流动性

```javascript
// 监控您在EntryPoint的余额
const balance = await entryPoint.balanceOf(myPaymasterAddress);
const threshold = ethers.utils.parseEther("1.0"); // 最低1 ETH

if (balance.lt(threshold)) {
    // 自动充值逻辑
    await entryPoint.depositTo(myPaymasterAddress, {
        value: ethers.utils.parseEther("10.0")
    });
}
```

## 📊 商业分析

### 关键指标追踪

1. **交易量指标**
   - 日/月用户操作数
   - 成功 vs 失败率
   - 每次操作的平均gas成本

2. **财务指标**
   - 费用收入
   - Gas成本（您的支出）
   - 每次操作的利润率
   - 质押投资回报率

3. **竞争指标**
   - 在SuperPaymaster中的市场份额
   - 与竞争对手的费率对比
   - 用户留存率

### 示例分析仪表板

```javascript
class PaymasterAnalytics {
    async getDailyStats(paymaster) {
        const info = await router.getPaymasterInfo(paymaster);
        const events = await router.queryFilter(
            router.filters.PaymasterSelected(paymaster)
        );
        
        return {
            totalOperations: info.totalAttempts,
            successfulOperations: info.successCount,
            successRate: (info.successCount / info.totalAttempts * 100).toFixed(2),
            dailyVolume: events.filter(e => isToday(e.blockNumber)).length
        };
    }
}
```

## 🚀 增长策略

### 1. 竞争定位
- **价格领导**: 在特定市场细分中提供最低费率
- **服务质量**: 更高的成功率和更快的处理速度
- **专业化服务**: 专注于特定用例（DeFi, 游戏, NFT）

### 2.合作机会
- **直接dApp集成**: 在SuperPaymaster之外的私人协议
- **交叉推广**: 与其他paymaster合作进行专业化路由
- **流动性合作**: 共享gas池以提高资本效率

### 3. 高级功能
- **动态定价**: 基于网络拥堵调整费率
- **用户评分**: 为不同用户层级提供不同费率
- **批量处理**: 通过批量优化gas成本
- **MEV集成**: 从MEV机会中获取额外收入

## 🔧 技术集成示例

### ERC-20 Paymaster实现

```solidity
contract ERC20Paymaster is SuperPaymasterV7 {
    IERC20 public token;
    uint256 public exchangeRate; // 每ETH的代币数量
    
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 requiredPreFund
    ) external override returns (bytes memory context, uint256 validationData) {
        // 检查用户是否有足够代币
        uint256 tokenAmount = requiredPreFund * exchangeRate / 1e18;
        require(token.balanceOf(userOp.sender) >= tokenAmount, "代币余额不足");
        
        // 返回成功
        return (abi.encode(userOp.sender, tokenAmount), 0);
    }
    
    function postOp(
        PostOpMode mode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external override {
        (address user, uint256 tokenAmount) = abi.decode(context, (address, uint256));
        
        // 向用户收取代币
        token.transferFrom(user, address(this), tokenAmount);
    }
}
```

### 订阅式Paymaster实现

```solidity
contract SubscriptionPaymaster is SuperPaymasterV7 {
    mapping(address => uint256) public subscriptions; // 用户 => 到期时间戳
    uint256 public monthlyPrice = 0.01 ether;
    
    function subscribe() external payable {
        require(msg.value >= monthlyPrice, "支付不足");
        subscriptions[msg.sender] = block.timestamp + 30 days;
    }
    
    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 requiredPreFund
    ) external override returns (bytes memory context, uint256 validationData) {
        // 检查订阅
        require(subscriptions[userOp.sender] > block.timestamp, "订阅已过期");
        
        return ("", 0); // 订阅用户免费
    }
}
```

## 📋 运营者检查清单

### 启动前
- [ ] 部署和测试paymaster合约
- [ ] 为paymaster充值足够的ETH
- [ ] 向EntryPoint添加质押（推荐）
- [ ] 向SuperPaymaster注册
- [ ] 设置监控和警报
- [ ] 配置自动充值机制

### 日常运营
- [ ] 监控EntryPoint余额
- [ ] 检查成功率和性能
- [ ] 分析竞争对手费率
- [ ] 审查日交易量
- [ ] 必要时更新费率

### 增长与优化
- [ ] 分析用户行为模式
- [ ] A/B测试不同费率结构
- [ ] 探索合作机会
- [ ] 实施高级功能
- [ ] 扩展基础设施以支持更高交易量

---

Built with ❤️ by [AAStarCommunity](https://github.com/AAStarCommunity)