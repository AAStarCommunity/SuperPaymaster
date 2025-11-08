# SuperPaymaster - Decentralized Gas Payment

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
- [Node.js](https://nodejs.org/) (for frontend dashboard)

### Project Structure

```
SuperPaymaster-Contract/
├── src/                     # Smart contracts source code
├── test/                    # Contract tests
├── script/                  # Deployment scripts
├── frontend/                # Next.js dashboard application
├── singleton-paymaster/     # Git submodule for Pimlico singleton paymaster templates
├── docs/                    # Documentation files
├── scripts/                 # Utility scripts
│   ├── build-all.sh        # Build all contracts (SuperPaymaster + singleton)
│   ├── compile-singleton-paymaster.sh  # Compile singleton paymaster contracts
│   ├── deploy-superpaymaster.sh       # Deploy SuperPaymaster contracts
│   ├── start-frontend.sh   # Start frontend development server
│   └── test-contracts.sh   # Run contract tests
├── CLAUDE.md               # AI assistant instructions
├── GEMINI.md               # AI assistant instructions
└── README.md               # This file
```

### Installation

```bash
# Clone the repository
git clone https://github.com/AAStarCommunity/SuperPaymaster-Contract.git
cd SuperPaymaster-Contract

# Initialize git submodules (for singleton-paymaster templates)
git submodule update --init --recursive

# Install Foundry dependencies
forge install

# Build all contracts (SuperPaymaster + singleton templates)
./scripts/build-all.sh

# Install frontend dependencies (optional - for dashboard)
cd frontend && npm install && cd ..
```

### Available Scripts

The project includes several utility scripts in the `scripts/` directory:

#### Contract Scripts
```bash
# Build all contracts (SuperPaymaster and singleton templates)
./scripts/build-all.sh

# Run contract tests
./scripts/test-contracts.sh

# Deploy SuperPaymaster to Sepolia (requires .env setup)
./scripts/deploy-superpaymaster.sh

# Compile singleton paymaster contracts and generate ABIs for frontend
./scripts/compile-singleton-paymaster.sh
```

#### Frontend Scripts
```bash
# Start frontend development server
./scripts/start-frontend.sh
# This will install dependencies if needed and start the dashboard at http://localhost:3000
```

### Testing

```bash
# Run all tests
./scripts/test-contracts.sh
# Or directly with forge:
forge test

# Run with verbosity
forge test -vvv

# Run specific test
forge test --match-test testPaymasterSelection
```

### Deployment

```bash
# Deploy to Sepolia testnet (requires .env configuration)
./scripts/deploy-superpaymaster.sh

# Or deploy manually with forge
forge script script/DeploySuperpaymaster.s.sol:DeploySuperpaymaster \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $SEPOLIA_PRIVATE_KEY \
  --broadcast
```

### Frontend Dashboard

The project includes a Next.js dashboard for managing SuperPaymaster deployments:

```bash
# Start the frontend dashboard
./scripts/start-frontend.sh

# Visit http://localhost:3000 to access the dashboard
```

Features:
- Deploy SuperPaymaster contracts (V6, V7, V8)
- Register and manage paymasters
- View paymaster marketplace
- Monitor contract statistics
- Support for multiple EntryPoint versions with proper version detection

### Recent Improvements

#### v1.3.0 - Project Structure Reorganization
- **New Structure**: Created `docs/` and `scripts/` folders for better organization
- **Documentation**: Moved all documentation files to `docs/` (except CLAUDE.md, GEMINI.md, README.md)
- **Scripts**: Consolidated all utility scripts in `scripts/` with proper path resolution
- **Submodule**: Restored `singleton-paymaster` as git submodule for latest Pimlico templates

#### v1.2.0 - Frontend Fixes
- **Version Detection**: Fixed V8 paymasters incorrectly showing as V7
- **Smart Detection**: Implemented intelligent version detection based on actual registration status
- **Version Indicators**: Added version badges to all 5 deployment steps
- **Environment Variables**: Added fallback handling for Next.js static compilation
- **ABI References**: Fixed undefined SIMPLE_PAYMASTER_ABI errors

## 💼 For Paymaster Operators

> **👥 Become a Paymaster Operator**: Run your own gas sponsorship service and earn fees by serving the SuperPaymaster marketplace. See detailed [Paymaster Operator Guide](./PAYMASTER_OPERATOR_GUIDE.md).

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

## 📚 Technical Documentation

### V2 System Architecture Docs
- **[V2 Contract Dependencies and Mock Analysis](docs/V2_CONTRACT_DEPENDENCIES_AND_MOCK_ANALYSIS.md)** - Complete dependency graph, Constructor parameter analysis, Mock code impact assessment
- **[GToken Incident Report (2025-10-25)](docs/GTOKEN_INCIDENT_2025-10-25.md)** - Detailed analysis of MockERC20 incident and prevention measures
- **[Project Change History](docs/Changes.md)** - Detailed development records for all Phases

### Key Features
- ✅ Contract dependency visualization charts
- ✅ Constructor immutability analysis
- ✅ GToken reference mechanism explanation
- ✅ Mock code usage summary
- ✅ User migration strategy recommendations

---

<a name="chinese"></a>

# SuperPaymaster - 去中心化燃料费支付

[English](#english) | **中文**

SuperPaymaster 是一个去中心化的燃料费支付服务，使账户抽象应用能够自动从竞争性市场中选择最具成本效益的paymaster。支持多个EntryPoint版本（v0.6, v0.7, v0.8），为用户提供无缝的燃料费赞助服务。

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
- [Node.js](https://nodejs.org/) (用于前端仪表板)

### 项目结构

```
SuperPaymaster-Contract/
├── src/                     # 智能合约源码
├── test/                    # 合约测试
├── script/                  # 部署脚本
├── frontend/                # Next.js仪表板应用
├── singleton-paymaster/     # Pimlico singleton paymaster模板的Git子模块
├── docs/                    # 文档文件
├── scripts/                 # 工具脚本
│   ├── build-all.sh        # 构建所有合约 (SuperPaymaster + singleton)
│   ├── compile-singleton-paymaster.sh  # 编译singleton paymaster合约
│   ├── deploy-superpaymaster.sh       # 部署SuperPaymaster合约
│   ├── start-frontend.sh   # 启动前端开发服务器
│   └── test-contracts.sh   # 运行合约测试
├── CLAUDE.md               # AI助手指令
├── GEMINI.md               # AI助手指令
└── README.md               # 本文件
```

### 安装

```bash
# 克隆仓库
git clone https://github.com/AAStarCommunity/SuperPaymaster-Contract.git
cd SuperPaymaster-Contract

# 初始化git子模块 (用于singleton-paymaster模板)
git submodule update --init --recursive

# 安装Foundry依赖
forge install

# 构建所有合约 (SuperPaymaster + singleton模板)
./scripts/build-all.sh

# 安装前端依赖 (可选 - 用于仪表板)
cd frontend && npm install && cd ..
```

### 可用脚本

项目在`scripts/`目录中包含多个工具脚本：

#### 合约脚本
```bash
# 构建所有合约 (SuperPaymaster和singleton模板)
./scripts/build-all.sh

# 运行合约测试
./scripts/test-contracts.sh

# 部署SuperPaymaster到Sepolia (需要配置.env)
./scripts/deploy-superpaymaster.sh

# 编译singleton paymaster合约并为前端生成ABI
./scripts/compile-singleton-paymaster.sh
```

#### 前端脚本
```bash
# 启动前端开发服务器
./scripts/start-frontend.sh
# 如需要会自动安装依赖并在 http://localhost:3000 启动仪表板
```

### 测试

```bash
# 运行所有测试
./scripts/test-contracts.sh
# 或者直接使用forge:
forge test

# 详细输出
forge test -vvv

# 运行特定测试
forge test --match-test testPaymasterSelection
```

### 部署

```bash
# 部署到Sepolia测试网 (需要配置.env)
./scripts/deploy-superpaymaster.sh

# 或者使用forge手动部署
forge script script/DeploySuperpaymaster.s.sol:DeploySuperpaymaster \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $SEPOLIA_PRIVATE_KEY \
  --broadcast
```

### 前端仪表板

项目包含用于管理SuperPaymaster部署的Next.js仪表板：

```bash
# 启动前端仪表板
./scripts/start-frontend.sh

# 访问 http://localhost:3000 使用仪表板
```

功能特性:
- 部署SuperPaymaster合约 (V6, V7, V8)
- 注册和管理paymaster
- 查看paymaster市场
- 监控合约统计
- 支持多EntryPoint版本并正确检测版本

### 最近改进

#### v1.3.0 - 项目结构重组
- **新结构**: 创建`docs/`和`scripts/`文件夹以更好地组织
- **文档**: 将所有文档文件移至`docs/` (除了CLAUDE.md, GEMINI.md, README.md)
- **脚本**: 将所有工具脚本整合到`scripts/`并正确处理路径解析
- **子模块**: 恢复`singleton-paymaster`作为git子模块以获取最新Pimlico模板

#### v1.2.0 - 前端修复
- **版本检测**: 修复V8 paymaster错误显示为V7的问题
- **智能检测**: 实现基于实际注册状态的智能版本检测
- **版本指示器**: 为所有5个部署步骤添加版本标识
- **环境变量**: 为Next.js静态编译添加回退处理
- **ABI引用**: 修复未定义的SIMPLE_PAYMASTER_ABI错误

## 💼 Paymaster运营者指南

> **👥 成为Paymaster运营者**: 运营您自己的gas赞助服务，通过为SuperPaymaster市场提供服务来赚取费用。查看详细的[Paymaster运营者指南](./PAYMASTER_OPERATOR_GUIDE.md)。

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

## 📚 技术文档

### V2 系统架构文档
- **[V2 合约依赖关系和 Mock 分析](docs/V2_CONTRACT_DEPENDENCIES_AND_MOCK_ANALYSIS.md)** - 完整的依赖关系图、Constructor 参数分析、Mock 代码影响评估
- **[GToken 事件报告 (2025-10-25)](docs/GTOKEN_INCIDENT_2025-10-25.md)** - MockERC20 事件详细分析和防范措施
- **[项目变更历史](docs/Changes.md)** - 所有 Phase 的详细开发记录

### 关键特性
- ✅ 合约依赖关系可视化图表
- ✅ Constructor 不可变性分析
- ✅ GToken 引用方式详解
- ✅ Mock 代码使用情况汇总
- ✅ 用户迁移策略建议

## 🔗 链接

- **文档**: [docs.superpaymaster.xyz](https://docs.superpaymaster.xyz)
- **GitHub**: [SuperPaymaster-Contract](https://github.com/AAStarCommunity/SuperPaymaster-Contract)
- **社区**: [AAStarCommunity](https://github.com/AAStarCommunity)
- **论文**: 即将发布的学术研究

---

Built with ❤️ by [AAStarCommunity](https://github.com/AAStarCommunity)
