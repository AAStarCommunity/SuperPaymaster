# SuperPaymaster Dashboard

**English** | [中文](#中文说明)

A comprehensive web dashboard for managing the SuperPaymaster decentralized gas payment router. This interface allows developers and paymaster operators to interact with the SuperPaymaster ecosystem.

## 🎯 Features

### For dApp Developers
- **Router Overview**: View current paymaster marketplace status
- **Best Paymaster Selection**: See which paymaster offers the lowest fees
- **Integration Examples**: Complete code samples for integration
- **Real-time Statistics**: Track routing success rates and performance

### For Paymaster Operators
- **Contract Deployment**: Deploy paymaster contracts with guided wizard
- **Registration Management**: Register paymasters with SuperPaymaster
- **Fund Management**: Deposit/withdraw ETH for gas sponsorship
- **Performance Analytics**: Monitor success rates and earnings
- **Fee Rate Management**: Update competitive fee rates

### Key Pages
1. **Dashboard** (`/`) - Overview of the SuperPaymaster ecosystem
2. **Register Paymaster** (`/register`) - Register existing paymaster contracts
3. **Deploy Paymaster** (`/deploy`) - Deploy and configure new paymasters
4. **Manage Paymaster** (`/manage`) - Operator control panel
5. **API Examples** (`/examples`) - Integration guides and code samples

## 🚀 Quick Start

### Prerequisites
- Node.js 18+ and npm/yarn
- A Web3 wallet (MetaMask recommended)
- Sepolia testnet ETH for testing

### Installation

1. **Clone and Install**
```bash
git clone https://github.com/AAStarCommunity/SuperPaymaster-Contract.git
cd SuperPaymaster-Contract/frontend
npm install
```

2. **Configure Environment**
```bash
cp .env.local.example .env.local
```

Edit `.env.local`:
```env
# Using MetaMask only - no WalletConnect needed

# Sepolia configuration  
NEXT_PUBLIC_CHAIN_ID=11155111
NEXT_PUBLIC_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY"
NEXT_PUBLIC_EXPLORER_URL="https://sepolia.etherscan.io"

# EntryPoint addresses (standard)
NEXT_PUBLIC_ENTRY_POINT_V6="0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789"
NEXT_PUBLIC_ENTRY_POINT_V7="0x0000000071727De22E5E9d8BAf0edAc6f37da032"
NEXT_PUBLIC_ENTRY_POINT_V8="0x0000000071727De22E5E9d8BAf0edAc6f37da032"

# SuperPaymaster addresses (update after deployment)
NEXT_PUBLIC_SUPER_PAYMASTER_V6="0x..."
NEXT_PUBLIC_SUPER_PAYMASTER_V7="0x..."
NEXT_PUBLIC_SUPER_PAYMASTER_V8="0x..."
```

3. **Start Development Server**
```bash
npm run dev
```

Visit `http://localhost:3000` to see the dashboard.

## 📖 Usage Guide

### For dApp Developers

#### 1. View Marketplace Status
- Navigate to the dashboard to see active paymasters
- Check current best paymaster and fee rates
- Monitor router statistics and success rates

#### 2. Integration Code Examples
- Visit `/examples` for complete integration guides
- Copy-paste ready code for React, Node.js, and Solidity
- Learn best practices for UserOperation sponsorship

#### 3. Test Integration
- Use the provided examples to integrate SuperPaymaster
- Submit test UserOperations to verify gas sponsorship
- Monitor transaction success rates

### For Paymaster Operators

#### 1. Deploy a New Paymaster
```
Dashboard → Deploy Paymaster → Configure → Deploy → Fund → Register
```

- Choose EntryPoint version (v6/v7/v8)
- Set initial parameters (name, fee rate, deposit)
- Deploy contract with guided wizard
- Automatically register with SuperPaymaster (optional)

#### 2. Register Existing Paymaster
```
Dashboard → Register Paymaster → Configure → Submit
```

- Enter paymaster contract address
- Set competitive fee rate
- Provide descriptive name
- Submit registration transaction

#### 3. Manage Operations
```
Dashboard → Manage Paymaster → Control Panel
```

- **Fund Management**: Deposit/withdraw ETH
- **Fee Updates**: Adjust rates for competitiveness  
- **Performance Monitoring**: View success rates and statistics
- **Balance Alerts**: Get notified of low balance warnings

## 🛠️ Technical Architecture

### Frontend Stack
- **Next.js 14** - React framework with App Router
- **TypeScript** - Type-safe development
- **Tailwind CSS** - Utility-first styling
- **wagmi/viem** - Ethereum interactions
- **MetaMask** - Wallet connection (no WalletConnect)

### Smart Contract Integration
- **SuperPaymaster Router** - Main routing contract
- **Simple Paymaster Template** - Basic paymaster implementation
- **Multi-version Support** - Compatible with EntryPoint v0.6/v0.7/v0.8

### Key Features
- **Responsive Design** - Works on desktop and mobile
- **Real-time Updates** - Live blockchain data integration
- **Error Handling** - Comprehensive error reporting
- **Transaction Tracking** - Monitor transaction status
- **Multi-wallet Support** - Compatible with popular wallets

## 🔧 Development

### Project Structure
```
frontend/
├── src/
│   ├── app/           # Next.js App Router pages
│   ├── components/    # Reusable UI components
│   ├── lib/          # Utilities and configurations
│   └── types/        # TypeScript type definitions
├── public/           # Static assets
└── package.json     # Dependencies and scripts
```

### Key Files
- `src/lib/contracts.ts` - Contract addresses and ABIs
- `src/lib/wagmi.ts` - Web3 configuration
- `src/types/index.ts` - TypeScript interfaces

### Available Scripts
```bash
npm run dev        # Start development server
npm run build      # Build for production
npm run start      # Start production server
npm run lint       # Run ESLint
```

### Adding New Features
1. Create new components in `src/components/`
2. Add pages in `src/app/[page]/page.tsx`
3. Update types in `src/types/index.ts`
4. Test with development server

## 🌐 Deployment

### Frontend Deployment
Deploy to Vercel, Netlify, or similar platforms:

```bash
# Build the application
npm run build

# Deploy to Vercel
npx vercel

# Or deploy to Netlify
npm run build && npx netlify deploy --prod --dir=out
```

### Environment Configuration
Make sure to set these environment variables in your deployment platform:
- `NEXT_PUBLIC_SUPER_PAYMASTER_V7` (and v6, v8)
- Other `NEXT_PUBLIC_*` variables from `.env.local`
- No WalletConnect configuration needed - using MetaMask only

## 🔗 Integration Examples

### Basic Usage (JavaScript)
```javascript
import { ethers } from 'ethers';

// Connect to SuperPaymaster
const router = new ethers.Contract(
  '0x...', // SuperPaymaster address
  SuperPaymasterABI,
  provider
);

// Get best paymaster
const [paymaster, feeRate] = await router.getBestPaymaster();

// Use in UserOperation
const userOp = {
  // ... your user operation
  paymaster: '0x...', // SuperPaymaster address
  paymasterAndData: '0x...' // SuperPaymaster address + data
};
```

### React Hook
```typescript
import { useSuperPaymaster } from './hooks/useSuperPaymaster';

function MyComponent() {
  const { bestPaymaster, sponsorUserOperation } = useSuperPaymaster(
    '0x...', // SuperPaymaster address
    SuperPaymasterABI
  );

  const handleSponsoredTransaction = async (userOp) => {
    const sponsoredUserOp = await sponsorUserOperation(userOp);
    // Submit to bundler...
  };
}
```

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/amazing-feature`
3. Commit changes: `git commit -m 'Add amazing feature'`
4. Push to branch: `git push origin feature/amazing-feature`
5. Open a Pull Request

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](../LICENSE) file for details.

## 🔗 Links

- **Main Repository**: [SuperPaymaster-Contract](https://github.com/AAStarCommunity/SuperPaymaster-Contract)
- **Documentation**: [Operator Guide](../PAYMASTER_OPERATOR_GUIDE.md)
- **Community**: [AAStarCommunity](https://github.com/AAStarCommunity)

---

<a name="中文说明"></a>

# SuperPaymaster 控制面板

[English](#superpaymaster-dashboard) | **中文**

SuperPaymaster去中心化燃料费支付路由器的综合Web控制面板。此界面允许开发者和paymaster运营者与SuperPaymaster生态系统进行交互。

## 🎯 功能特性

### 面向dApp开发者
- **路由器概览**: 查看当前paymaster市场状态
- **最佳Paymaster选择**: 查看哪个paymaster提供最低费率
- **集成示例**: 完整的集成代码示例
- **实时统计**: 追踪路由成功率和性能

### 面向Paymaster运营者
- **合约部署**: 通过引导向导部署paymaster合约
- **注册管理**: 向SuperPaymaster注册paymaster
- **资金管理**: 存入/提取用于燃料费赞助的ETH
- **性能分析**: 监控成功率和收益
- **费率管理**: 更新竞争性费率

### 关键页面
1. **控制面板** (`/`) - SuperPaymaster生态系统概览
2. **注册Paymaster** (`/register`) - 注册现有paymaster合约
3. **部署Paymaster** (`/deploy`) - 部署和配置新paymaster
4. **管理Paymaster** (`/manage`) - 运营者控制面板
5. **API示例** (`/examples`) - 集成指南和代码示例

## 🚀 快速开始

### 前置要求
- Node.js 18+ 和 npm/yarn
- Web3钱包 (推荐MetaMask)
- Sepolia测试网ETH用于测试

### 安装

1. **克隆和安装**
```bash
git clone https://github.com/AAStarCommunity/SuperPaymaster-Contract.git
cd SuperPaymaster-Contract/frontend
npm install
```

2. **配置环境**
```bash
cp .env.local.example .env.local
```

编辑 `.env.local`:
```env
# 仅使用MetaMask - 无需WalletConnect

# Sepolia配置  
NEXT_PUBLIC_CHAIN_ID=11155111
NEXT_PUBLIC_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY"
NEXT_PUBLIC_EXPLORER_URL="https://sepolia.etherscan.io"

# EntryPoint地址 (标准地址)
NEXT_PUBLIC_ENTRY_POINT_V6="0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789"
NEXT_PUBLIC_ENTRY_POINT_V7="0x0000000071727De22E5E9d8BAf0edAc6f37da032"
NEXT_PUBLIC_ENTRY_POINT_V8="0x0000000071727De22E5E9d8BAf0edAc6f37da032"

# SuperPaymaster地址 (部署后更新)
NEXT_PUBLIC_SUPER_PAYMASTER_V6="0x..."
NEXT_PUBLIC_SUPER_PAYMASTER_V7="0x..."
NEXT_PUBLIC_SUPER_PAYMASTER_V8="0x..."
```

3. **启动开发服务器**
```bash
npm run dev
```

访问 `http://localhost:3000` 查看控制面板。

## 📖 使用指南

### dApp开发者

#### 1. 查看市场状态
- 导航到控制面板查看活跃的paymaster
- 检查当前最佳paymaster和费率
- 监控路由器统计和成功率

#### 2. 集成代码示例
- 访问 `/examples` 获取完整集成指南
- 复制粘贴React、Node.js和Solidity的现成代码
- 学习UserOperation赞助的最佳实践

#### 3. 测试集成
- 使用提供的示例集成SuperPaymaster
- 提交测试UserOperation以验证燃料费赞助
- 监控交易成功率

### Paymaster运营者

#### 1. 部署新Paymaster
```
控制面板 → 部署Paymaster → 配置 → 部署 → 充值 → 注册
```

- 选择EntryPoint版本 (v6/v7/v8)
- 设置初始参数 (名称、费率、存款)
- 通过引导向导部署合约
- 自动注册到SuperPaymaster (可选)

#### 2. 注册现有Paymaster
```
控制面板 → 注册Paymaster → 配置 → 提交
```

- 输入paymaster合约地址
- 设置竞争性费率
- 提供描述性名称
- 提交注册交易

#### 3. 管理操作
```
控制面板 → 管理Paymaster → 控制面板
```

- **资金管理**: 存入/提取ETH
- **费率更新**: 调整费率以提高竞争力
- **性能监控**: 查看成功率和统计信息
- **余额警报**: 获取低余额警告通知

## 🛠️ 技术架构

### 前端技术栈
- **Next.js 14** - 带App Router的React框架
- **TypeScript** - 类型安全开发
- **Tailwind CSS** - 实用优先的样式
- **wagmi/viem** - 以太坊交互
- **MetaMask** - 钱包连接（无WalletConnect）

### 智能合约集成
- **SuperPaymaster Router** - 主要路由合约
- **Simple Paymaster Template** - 基础paymaster实现
- **多版本支持** - 兼容EntryPoint v0.6/v0.7/v0.8

### 关键特性
- **响应式设计** - 桌面和移动端均可使用
- **实时更新** - 实时区块链数据集成
- **错误处理** - 全面的错误报告
- **交易追踪** - 监控交易状态
- **多钱包支持** - 兼容流行钱包

## 🌐 部署

### 前端部署
部署到Vercel、Netlify或类似平台:

```bash
# 构建应用
npm run build

# 部署到Vercel
npx vercel

# 或部署到Netlify
npm run build && npx netlify deploy --prod --dir=out
```

### 环境配置
确保在部署平台中设置这些环境变量:
- `NEXT_PUBLIC_SUPER_PAYMASTER_V7` (以及v6, v8)
- 其他来自 `.env.local` 的 `NEXT_PUBLIC_*` 变量
- 仅使用MetaMask，无需WalletConnect配置

## 🤝 贡献

1. Fork仓库
2. 创建特性分支: `git checkout -b feature/amazing-feature`
3. 提交更改: `git commit -m 'Add amazing feature'`
4. 推送到分支: `git push origin feature/amazing-feature`
5. 开启Pull Request

## 📄 许可证

此项目采用MIT许可证 - 查看[LICENSE](../LICENSE)文件了解详情。

---

Built with ❤️ by [AAStarCommunity](https://github.com/AAStarCommunity)