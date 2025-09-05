# SuperPaymaster - Decentralized Gas Payment Router

**English** | [中文](#chinese)

SuperPaymaster is a decentralized gas payment router that enables Account Abstraction applications to automatically select the most cost-effective paymaster from a competitive marketplace. It supports multiple EntryPoint versions (v0.6, v0.7, v0.8) and provides seamless gas sponsorship for your users.

## 🎯 What is SuperPaymaster?

SuperPaymaster acts as an intelligent router that:
- **Connects** your dApp to multiple paymaster providers
- **Selects** the best paymaster based on fee rates and availability 
- **Routes** user operations to the most cost-effective option
- **Manages** paymaster registration and marketplace dynamics

Instead of integrating with individual paymasters, integrate once with SuperPaymaster and get access to the entire ecosystem.

## 🏗️ Architecture

```
Your dApp → SuperPaymaster Router → Best Available Paymaster → EntryPoint
```

SuperPaymaster consists of three main contracts:
- **SuperPaymasterV6**: For EntryPoint v0.6 compatibility
- **SuperPaymasterV7**: For EntryPoint v0.7 with PackedUserOperation support
- **SuperPaymasterV8**: For EntryPoint v0.8 with EIP-7702 delegation support

## 🚀 Quick Start

### 1. Deploy SuperPaymaster Router

Choose the version that matches your EntryPoint:

```solidity
// For EntryPoint v0.7
SuperPaymasterV7 router = new SuperPaymasterV7(
    entryPointAddress,    // Your EntryPoint contract
    owner,               // Router owner address
    250                 // Router fee rate (2.5%)
);
```

### 2. Register Paymasters

Paymaster providers can register their services:

```solidity
// Register a paymaster with 1% fee rate
router.registerPaymaster(
    paymasterAddress,
    100,                // Fee rate in basis points (100 = 1%)
    "My Paymaster"     // Display name
);
```

### 3. Use in Your dApp

```javascript
// Get the best available paymaster
const [paymasterAddress, feeRate] = await router.getBestPaymaster();

// Use in your UserOperation
const userOp = {
    // ... your user operation fields
    paymaster: routerAddress,  // Use SuperPaymaster as paymaster
    // ... other fields
};
```

### 4. Route User Operations

SuperPaymaster automatically:
1. Finds the best available paymaster (lowest fee rate)
2. Routes your UserOperation to that paymaster
3. Handles success/failure tracking
4. Updates marketplace statistics

## 📋 For Developers

### Integration Guide

#### Option 1: Direct Integration

```solidity
import "./src/SuperPaymasterV7.sol";

contract MyContract {
    SuperPaymasterV7 public router;
    
    constructor(address _router) {
        router = SuperPaymasterV7(_router);
    }
    
    function getBestOption() external view returns (address, uint256) {
        return router.getBestPaymaster();
    }
}
```

#### Option 2: Interface Integration

```solidity
import "./src/interfaces/IPaymasterRouter.sol";

contract MyContract {
    IPaymasterRouter public router;
    
    function selectPaymaster() external view returns (address) {
        (address best,) = router.getBestPaymaster();
        return best;
    }
}
```

### Available Functions

#### Core Functions
- `getBestPaymaster()` - Get the most cost-effective paymaster
- `getActivePaymasters()` - List all active paymasters
- `getPaymasterInfo(address)` - Get detailed paymaster information
- `simulatePaymasterSelection(userOp)` - Preview selection without gas cost

#### Management Functions (Owner Only)
- `registerPaymaster(address, uint256, string)` - Add new paymaster
- `setPaymasterStatus(address, bool)` - Activate/deactivate paymaster
- `setRouterFeeRate(uint256)` - Update router fee
- `emergencyRemovePaymaster(address)` - Emergency removal

### Events

```solidity
event PaymasterRegistered(address indexed paymaster, uint256 feeRate, string name);
event PaymasterSelected(address indexed paymaster, address indexed user, uint256 feeRate);
event FeeRateUpdated(address indexed paymaster, uint256 oldFeeRate, uint256 newFeeRate);
```

## 🔧 Development Setup

### Prerequisites
- [Foundry](https://book.getfoundry.sh/)
- [Node.js](https://nodejs.org/) (for additional tooling)

### Installation

```bash
# Clone the repository
git clone https://github.com/AAStarCommunity/SuperPaymaster-Contract.git
cd SuperPaymaster-Contract

# Install dependencies
forge install

# Build contracts
forge build
```

### Testing

```bash
# Run all tests
forge test

# Run with verbosity
forge test -vvv

# Run specific test
forge test --match-test testPaymasterSelection
```

### Deployment

```bash
# Deploy to local network
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast

# Deploy to testnet
forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast --verify
```

## 💼 For Paymaster Providers

### How to Join the Marketplace

1. **Deploy your paymaster** contract that implements the standard interface
2. **Register with SuperPaymaster** by calling `registerPaymaster()`
3. **Set competitive fees** to attract more user operations
4. **Maintain sufficient balance** in the EntryPoint for routing availability

### Fee Structure

- **Router Fee**: Small percentage taken by SuperPaymaster (configurable)
- **Paymaster Fee**: Your fee rate in basis points (100 = 1%)
- **Selection Algorithm**: Currently lowest-fee-first (V2 will add reputation)

### Benefits

- **Automatic Discovery**: Users find your paymaster without integration
- **Competitive Marketplace**: Fair competition based on fees and performance  
- **Statistics Tracking**: Success rates and usage analytics
- **Multi-version Support**: Reach users on different EntryPoint versions

## 🌐 Network Support

| Network | EntryPoint v0.6 | EntryPoint v0.7 | EntryPoint v0.8 |
|---------|----------------|----------------|----------------|
| Ethereum Mainnet | ✅ | ✅ | 🔄 Soon |
| Polygon | ✅ | ✅ | 🔄 Soon |
| Arbitrum | ✅ | ✅ | 🔄 Soon |
| Optimism | ✅ | ✅ | 🔄 Soon |

## 📖 Examples

Check the `examples/` directory for:
- Basic integration examples
- Advanced routing strategies
- Paymaster provider setup
- Frontend integration guides

---

<a name="chinese"></a>

# SuperPaymaster - 去中心化燃料费支付路由器

[English](#english) | **中文**

SuperPaymaster 是一个去中心化的燃料费支付路由器，使账户抽象应用能够自动从竞争性市场中选择最具成本效益的paymaster。支持多个EntryPoint版本（v0.6, v0.7, v0.8），为用户提供无缝的燃料费赞助服务。

## 🎯 什么是SuperPaymaster？

SuperPaymaster充当智能路由器：
- **连接** 您的dApp到多个paymaster提供商
- **选择** 基于费率和可用性的最佳paymaster
- **路由** 用户操作到最具成本效益的选项
- **管理** paymaster注册和市场动态

无需与各个paymaster单独集成，只需与SuperPaymaster集成一次即可访问整个生态系统。

## 🏗️ 架构设计

```
您的dApp → SuperPaymaster路由器 → 最佳可用Paymaster → EntryPoint
```

SuperPaymaster包含三个主要合约：
- **SuperPaymasterV6**: 兼容EntryPoint v0.6
- **SuperPaymasterV7**: 兼容EntryPoint v0.7，支持PackedUserOperation
- **SuperPaymasterV8**: 兼容EntryPoint v0.8，支持EIP-7702委托

## 🚀 快速开始

### 1. 部署SuperPaymaster路由器

选择与您的EntryPoint匹配的版本：

```solidity
// 用于EntryPoint v0.7
SuperPaymasterV7 router = new SuperPaymasterV7(
    entryPointAddress,    // 您的EntryPoint合约地址
    owner,               // 路由器所有者地址
    250                 // 路由器费率 (2.5%)
);
```

### 2. 注册Paymaster

Paymaster提供商可以注册他们的服务：

```solidity
// 注册费率为1%的paymaster
router.registerPaymaster(
    paymasterAddress,
    100,                // 费率（基点，100 = 1%）
    "My Paymaster"     // 显示名称
);
```

### 3. 在dApp中使用

```javascript
// 获取最佳可用paymaster
const [paymasterAddress, feeRate] = await router.getBestPaymaster();

// 在UserOperation中使用
const userOp = {
    // ... 您的用户操作字段
    paymaster: routerAddress,  // 使用SuperPaymaster作为paymaster
    // ... 其他字段
};
```

### 4. 路由用户操作

SuperPaymaster自动执行：
1. 找到最佳可用paymaster（最低费率）
2. 将UserOperation路由到该paymaster
3. 处理成功/失败跟踪
4. 更新市场统计信息

## 📋 开发者指南

### 集成指南

#### 方案1：直接集成

```solidity
import "./src/SuperPaymasterV7.sol";

contract MyContract {
    SuperPaymasterV7 public router;
    
    constructor(address _router) {
        router = SuperPaymasterV7(_router);
    }
    
    function getBestOption() external view returns (address, uint256) {
        return router.getBestPaymaster();
    }
}
```

#### 方案2：接口集成

```solidity
import "./src/interfaces/IPaymasterRouter.sol";

contract MyContract {
    IPaymasterRouter public router;
    
    function selectPaymaster() external view returns (address) {
        (address best,) = router.getBestPaymaster();
        return best;
    }
}
```

### 可用函数

#### 核心函数
- `getBestPaymaster()` - 获取最具成本效益的paymaster
- `getActivePaymasters()` - 列出所有活跃的paymaster
- `getPaymasterInfo(address)` - 获取详细的paymaster信息
- `simulatePaymasterSelection(userOp)` - 预览选择而不消耗gas

#### 管理函数（仅所有者）
- `registerPaymaster(address, uint256, string)` - 添加新paymaster
- `setPaymasterStatus(address, bool)` - 激活/停用paymaster
- `setRouterFeeRate(uint256)` - 更新路由器费率
- `emergencyRemovePaymaster(address)` - 紧急移除

### 事件

```solidity
event PaymasterRegistered(address indexed paymaster, uint256 feeRate, string name);
event PaymasterSelected(address indexed paymaster, address indexed user, uint256 feeRate);
event FeeRateUpdated(address indexed paymaster, uint256 oldFeeRate, uint256 newFeeRate);
```

## 🔧 开发环境设置

### 前置要求
- [Foundry](https://book.getfoundry.sh/)
- [Node.js](https://nodejs.org/) (用于额外工具)

### 安装

```bash
# 克隆仓库
git clone https://github.com/AAStarCommunity/SuperPaymaster-Contract.git
cd SuperPaymaster-Contract

# 安装依赖
forge install

# 构建合约
forge build
```

### 测试

```bash
# 运行所有测试
forge test

# 详细输出
forge test -vvv

# 运行特定测试
forge test --match-test testPaymasterSelection
```

### 部署

```bash
# 部署到本地网络
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast

# 部署到测试网
forge script script/Deploy.s.sol --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast --verify
```

## 💼 Paymaster提供商指南

### 如何加入市场

1. **部署您的paymaster**合约，实现标准接口
2. **向SuperPaymaster注册**，调用`registerPaymaster()`
3. **设置竞争性费率**以吸引更多用户操作
4. **在EntryPoint中保持充足余额**以确保路由可用性

### 费率结构

- **路由器费率**: SuperPaymaster收取的小比例费用（可配置）
- **Paymaster费率**: 您的费率，以基点计算（100 = 1%）
- **选择算法**: 当前为最低费率优先（V2将添加声誉评分）

### 优势

- **自动发现**: 用户无需集成即可找到您的paymaster
- **竞争性市场**: 基于费率和性能的公平竞争
- **统计跟踪**: 成功率和使用分析
- **多版本支持**: 接触不同EntryPoint版本的用户

## 🌐 网络支持

| 网络 | EntryPoint v0.6 | EntryPoint v0.7 | EntryPoint v0.8 |
|------|----------------|----------------|----------------|
| 以太坊主网 | ✅ | ✅ | 🔄 即将支持 |
| Polygon | ✅ | ✅ | 🔄 即将支持 |
| Arbitrum | ✅ | ✅ | 🔄 即将支持 |
| Optimism | ✅ | ✅ | 🔄 即将支持 |

## 📖 示例

查看`examples/`目录获取：
- 基本集成示例
- 高级路由策略
- Paymaster提供商设置
- 前端集成指南

## 🤝 贡献

欢迎贡献！请查看我们的[贡献指南](CONTRIBUTING.md)了解如何参与。

## 📄 许可证

本项目采用MIT许可证 - 查看[LICENSE](LICENSE)文件了解详情。

## 🔗 链接

- **文档**: [docs.superpaymaster.xyz](https://docs.superpaymaster.xyz)
- **GitHub**: [SuperPaymaster-Contract](https://github.com/AAStarCommunity/SuperPaymaster-Contract)
- **社区**: [AAStarCommunity](https://github.com/AAStarCommunity)
- **论文**: 即将发布的学术研究

---

Built with ❤️ by [AAStarCommunity](https://github.com/AAStarCommunity)