# SuperPaymaster Registry App - 完整规划方案 v2

> **Version**: 2.0  
> **Date**: 2025-10-09  
> **Status**: Draft for Review  
> **Author**: Claude AI Assistant

---

## 📋 变更记录 (v1 → v2)

1. ✅ Demo Playground 独立为 `aastar.io/demo`
2. ✅ 社区运营者增加独立教程页面 `/operators/launch-guide`
3. ✅ 明确仅支持 MetaMask (移除 WalletConnect)
4. ✅ 添加 UserOperation v0.6/v0.7 TypeScript 接口定义
5. ✅ 明确与主站关系: 独立 repo + 统一导航
6. ✅ 添加社区 Logo/Icon 资源链接

---

## 一、整体架构

### 1.1 产品生态关系

```
AAStar Ecosystem
├─ 主站 (aastar.io)
│   ├─ About/Team/Vision
│   ├─ Products 导航
│   └─ Blog/News
│
├─ AirAccount (airAccount.aastar.io) 【产品站】
│   ├─ 直接面向最终用户
│   ├─ 账户创建和管理
│   └─ 日常交易功能
│
├─ SuperPaymaster (superpaymaster.aastar.io) 【服务站】
│   ├─ 面向开发者和社区运营者
│   ├─ Paymaster 注册和管理
│   ├─ 技术文档和集成指南
│   └─ 跳转到 Demo Playground
│
└─ Demo Playground (aastar.io/demo) 【交互演示】
    ├─ 三个角色的完整测试流程
    ├─ 沙盒环境
    └─ 可嵌入到其他产品页面
```

### 1.2 仓库组织建议

#### **推荐方案: 独立仓库**

```
# Repo 1: 主站
github.com/AAStarCommunity/aastarcommunity.github.io
├─ 静态内容 (Docusaurus/Hugo)
├─ 品牌资源共享 (logos/icons)
└─ 产品导航页

# Repo 2: SuperPaymaster Registry (本项目)
github.com/AAStarCommunity/superpaymaster-registry
├─ Landing & Portal 页面
├─ Registry Explorer
├─ 技术文档
└─ 部署到 superpaymaster.aastar.io

# Repo 3: Demo Playground (独立部署)
github.com/AAStarCommunity/aastar-demo-playground
├─ 三个角色的交互 Demo
├─ 测试环境和沙盒
└─ 部署到 aastar.io/demo
```

**共享资源配置**:
```json
// shared-config.json (所有项目引用)
{
  "branding": {
    "logo": "https://raw.githubusercontent.com/jhfnetboy/MarkDownImg/main/img/202505031325963.png",
    "icon": "https://www.aastar.io/favicon.ico",
    "colors": {
      "primary": "#FF6B35",
      "secondary": "#4A90E2"
    }
  },
  "links": {
    "main": "https://aastar.io",
    "airAccount": "https://airAccount.aastar.io",
    "superPaymaster": "https://superpaymaster.aastar.io",
    "demo": "https://aastar.io/demo"
  }
}
```

---

## 二、站点地图 (SuperPaymaster Registry)

```
superpaymaster.aastar.io
│
├─ 🏠 Landing Page (/)
│   ├─ Hero Section (SVG Animation)
│   ├─ Features Section
│   ├─ Statistics Dashboard
│   └─ Role Selection (2 CTAs)
│
├─ 👨‍💻 Developer Portal (/developer)
│   ├─ What is SuperPaymaster?
│   ├─ Integration Guide
│   │   ├─ SDK Installation
│   │   ├─ Network & ENS Info
│   │   ├─ UserOp Versions (v0.6/v0.7)
│   │   └─ Quick Start Code
│   ├─ API Reference
│   └─ [CTA] Try Developer Demo → aastar.io/demo?role=developer
│
├─ 🏢 Community Operators Portal (/operators)
│   ├─ Why Community Paymaster?
│   ├─ Quick Launch Overview
│   ├─ 📚 Launch Guide (New!) (/operators/launch-guide)
│   │   ├─ Step 1: Preparation
│   │   ├─ Step 2: Deploy Contracts
│   │   ├─ Step 3: Configure Tokens
│   │   ├─ Step 4: Stake & Register
│   │   ├─ Step 5: Test & Monitor
│   │   └─ [CTA] Practice → aastar.io/demo?role=operator
│   ├─ Revenue Model
│   ├─ Protocol Benefits
│   └─ [CTA] Try Operator Demo → aastar.io/demo?role=operator
│
├─ 📊 Registry Explorer (/registry)
│   ├─ Paymaster List (filterable)
│   ├─ Paymaster Detail Pages
│   └─ Transaction History
│
├─ 📖 Documentation (/docs)
│   ├─ Technical Specs
│   ├─ Smart Contract ABIs
│   └─ Integration Examples
│
└─ 🔗 External Links
    ├─ Demo Playground → aastar.io/demo
    ├─ Main Site → aastar.io
    └─ AirAccount → airAccount.aastar.io
```

---

## 三、核心页面详细设计

### 3.1 Landing Page (/)

#### **Header 全站通用设计**

```
┌────────────────────────────────────────────────────┐
│ [AAStar Logo]          SuperPaymaster              │
│                                                    │
│  [Products ▼] [Developers] [Community] [Docs]     │
│                              [Try Demo] [中文/EN]  │
└────────────────────────────────────────────────────┘

Products 下拉菜单:
├─ AirAccount → airAccount.aastar.io
├─ SuperPaymaster → superpaymaster.aastar.io
└─ Demo Playground → aastar.io/demo
```

**Logo 配置**:
```tsx
// components/Header.tsx
const AASTAR_LOGO = "https://raw.githubusercontent.com/jhfnetboy/MarkDownImg/main/img/202505031325963.png";
const AASTAR_ICON = "https://www.aastar.io/favicon.ico";

<Link href="https://aastar.io">
  <img src={AASTAR_LOGO} alt="AAStar Community" height="40" />
</Link>
```

#### **页面布局**

```
┌────────────────────────────────────────────────────┐
│  Header (全站通用)                                  │
├────────────────────────────────────────────────────┤
│                                                    │
│  🎬 Hero Section                                   │
│  ┌──────────────────────────────────────────────┐ │
│  │  [SVG Animation: gas_station_animation.svg]  │ │
│  │                                              │ │
│  │  H1: SuperPaymaster                          │ │
│  │  Tagline: A Decentralized, Negative Cost,   │ │
│  │           Seamless Gas Sponsor Public Goods │ │
│  │           on Ethereum                        │ │
│  │                                              │ │
│  │  [Try Demo →] [Learn More ↓]                 │ │
│  └──────────────────────────────────────────────┘ │
│                                                    │
│  ⭐ Features Section (3 Cards)                     │
│  ┌────────┐  ┌────────┐  ┌────────┐              │
│  │Decentra│  │Permiss-│  │  Free  │              │
│  │lization│  │ionless │  │ Market │              │
│  └────────┘  └────────┘  └────────┘              │
│                                                    │
│  📊 Live Statistics Dashboard                      │
│  ┌────────────────────────────────────────────┐   │
│  │ Network: [All] [Sepolia] [Mainnet] [OP]   │   │
│  │                                            │   │
│  │ Metrics (Real-time from contracts):       │   │
│  │ ├─ Registered Paymasters: 5 →             │   │
│  │ ├─ Supported Gas Tokens: 5 →              │   │
│  │ │   [USDC] [USDT] [DAI] [ETH] [ASTR]      │   │
│  │ ├─ Community Members: 6 →                 │   │
│  │ │   [AAStar][BB][CC][DD][EE][FF]          │   │
│  │ ├─ Sponsored UserOps: 1,035 →             │   │
│  │ └─ Total Gas Saved: $12,450 →             │   │
│  └────────────────────────────────────────────┘   │
│                                                    │
│  🎯 Who Are You? (Role Selection)                  │
│  ┌─────────────────────┐  ┌─────────────────────┐ │
│  │  👨‍💻 I'm a Developer │  │ 🏢 I'm a Community  │ │
│  │                     │  │    Operator         │ │
│  │  Integrate gas      │  │  Launch your own    │ │
│  │  sponsorship into   │  │  Paymaster for      │ │
│  │  your DApp          │  │  your community     │ │
│  │                     │  │                     │ │
│  │  [Get Started →]    │  │  [Get Started →]    │ │
│  │  (Orange gradient)  │  │  (Blue gradient)    │ │
│  └─────────────────────┘  └─────────────────────┘ │
│                                                    │
│  🎮 Try Interactive Demo                           │
│  ┌──────────────────────────────────────────────┐ │
│  │  Experience SuperPaymaster in action         │ │
│  │  • Create an account without ETH             │ │
│  │  • Send transactions with zero gas fees      │ │
│  │  • Deploy your own Paymaster (testnet)       │ │
│  │                                              │ │
│  │  [Launch Demo Playground →]                  │ │
│  │  (Links to aastar.io/demo)                   │ │
│  └──────────────────────────────────────────────┘ │
│                                                    │
│  🌐 Ecosystem Integration                          │
│  ┌──────────────────────────────────────────────┐ │
│  │  Part of AAStar Community Ecosystem          │ │
│  │  [AirAccount] [SuperPaymaster] [OpenPNTs]    │ │
│  │  [OpenCards] [More...]                       │ │
│  └──────────────────────────────────────────────┘ │
│                                                    │
├────────────────────────────────────────────────────┤
│  Footer (全站通用)                                  │
│  Links: About | Docs | GitHub | Twitter | Discord │
└────────────────────────────────────────────────────┘
```

**Statistics 数据源**:
```typescript
// hooks/useStatistics.ts
interface NetworkStats {
  paymasters: number;
  gasTokens: Token[];
  communities: Community[];
  sponsoredOps: number;
  totalSaved: string; // USD
}

// Read from SuperPaymaster contract events
async function fetchStats(network: string): Promise<NetworkStats> {
  const contract = new ethers.Contract(REGISTRY_ADDRESS, ABI, provider);
  const paymasters = await contract.getRegisteredPaymasters();
  // ... aggregate data
}
```

---

### 3.2 Developer Portal (/developer)

```
┌────────────────────────────────────────────────────┐
│  Breadcrumb: Home > Developers                     │
│  Language: [🇬🇧 EN] [🇨🇳 中文]                        │
├────────────────────────────────────────────────────┤
│  📖 Section 1: What is SuperPaymaster?             │
│  ┌──────────────────────────────────────────────┐ │
│  │ SuperPaymaster is a public goods registry    │ │
│  │ for Community Paymasters, providing:         │ │
│  │                                              │ │
│  │ • Smart Router: Auto-select best Paymaster  │ │
│  │ • Multi-token Support: USDC/USDT/DAI/PNTs   │ │
│  │ • ERC-4337 Compatible: v0.6/v0.7/v0.8       │ │
│  │ • Sustainable Revenue Model for communities │ │
│  │                                              │ │
│  │ AAStar Ecosystem:                            │ │
│  │ [AirAccount] [SuperPaymaster] [SDK]          │ │
│  │ [OpenPNTs] [OpenCards] [More...]            │ │
│  └──────────────────────────────────────────────┘ │
│                                                    │
│  🚀 Section 2: Quick Integration Guide             │
│  ┌──────────────────────────────────────────────┐ │
│  │ Step 1: Install SDK                          │ │
│  │ ```bash                                      │ │
│  │ npm install @aastar/sdk                      │ │
│  │ npm install @aastar/paymaster-client         │ │
│  │ ```                                          │ │
│  │ [Copy Commands]                              │ │
│  │                                              │ │
│  │ Step 2: Get SuperPaymaster Contract Address  │ │
│  │ ┌────────────────────────────────────────┐  │ │
│  │ │ Network      │ ENS Name              │  │ │
│  │ ├──────────────┼───────────────────────┤  │ │
│  │ │ Sepolia      │ sepolia.superpaymaster│  │ │
│  │ │              │ .aastar.eth           │  │ │
│  │ │              │ → 0x123...ABC         │  │ │
│  │ ├──────────────┼───────────────────────┤  │ │
│  │ │ OP Sepolia   │ op-sepolia.super...   │  │ │
│  │ │              │ → 0x456...DEF         │  │ │
│  │ ├──────────────┼───────────────────────┤  │ │
│  │ │ OP Mainnet   │ op-mainnet.super...   │  │ │
│  │ │              │ → 0x789...GHI         │  │ │
│  │ └────────────────────────────────────────┘  │ │
│  │ [Copy ENS] [Copy Address]                    │ │
│  │                                              │ │
│  │ Step 3: Choose EntryPoint Version            │ │
│  │ [Tab: v0.6] [Tab: v0.7] [Tab: v0.8 (Soon)]   │ │
│  │                                              │ │
│  │ // EntryPoint v0.6 UserOperation             │ │
│  │ ```typescript                                │ │
│  │ interface UserOperationV6 {                  │ │
│  │   sender: Address                            │ │
│  │   nonce: Hex                                 │ │
│  │   initCode: Hex                              │ │
│  │   callData: Hex                              │ │
│  │   callGasLimit: Hex                          │ │
│  │   verificationGasLimit: Hex                  │ │
│  │   preVerificationGas: Hex                    │ │
│  │   maxPriorityFeePerGas: Hex                  │ │
│  │   maxFeePerGas: Hex                          │ │
│  │   paymasterAndData: Hex  // Set to ENS!     │ │
│  │   signature: Hex                             │ │
│  │ }                                            │ │
│  │ ```                                          │ │
│  │                                              │ │
│  │ // EntryPoint v0.7 UserOperation             │ │
│  │ ```typescript                                │ │
│  │ interface UserOperationV7 {                  │ │
│  │   sender: Address                            │ │
│  │   nonce: Hex                                 │ │
│  │   factory?: Address                          │ │
│  │   factoryData?: Hex                          │ │
│  │   callData: Hex                              │ │
│  │   callGasLimit: Hex                          │ │
│  │   verificationGasLimit: Hex                  │ │
│  │   preVerificationGas: Hex                    │ │
│  │   maxFeePerGas: Hex                          │ │
│  │   maxPriorityFeePerGas: Hex                  │ │
│  │   paymaster?: Address     // Set to ENS!    │ │
│  │   paymasterVerificationGasLimit?: Hex        │ │
│  │   paymasterPostOpGasLimit?: Hex              │ │
│  │   paymasterData?: Hex                        │ │
│  │   signature: Hex                             │ │
│  │ }                                            │ │
│  │ ```                                          │ │
│  │ [Copy TypeScript Interface]                  │ │
│  │                                              │ │
│  │ Step 4: Create Test Accounts                 │ │
│  │ Option A: Use pre-generated accounts         │ │
│  │ Option B: Create via AAStar SDK              │ │
│  │                                              │ │
│  │ ```typescript                                │ │
│  │ import { createAccount } from '@aastar/sdk'  │ │
│  │                                              │ │
│  │ const account = await createAccount({        │ │
│  │   owner: ownerAddress,                       │ │
│  │   network: 'sepolia',                        │ │
│  │ })                                           │ │
│  │ ```                                          │ │
│  │                                              │ │
│  │ Step 5: Get Test Tokens                      │ │
│  │ Faucet: https://faucet.aastar.io            │ │
│  │ • Request SBT (Soul Bound Token)             │ │
│  │ • Request PNTs (Community Points)            │ │
│  │ • Request Test USDT                          │ │
│  │                                              │ │
│  │ Step 6: Send Gasless Transaction             │ │
│  │ ```typescript                                │ │
│  │ import { SuperPaymaster } from '@aastar/sdk' │ │
│  │                                              │ │
│  │ const paymaster = new SuperPaymaster({       │ │
│  │   network: 'sepolia',                        │ │
│  │   paymasterENS: 'sepolia.superpaymaster      │ │
│  │                  .aastar.eth',               │ │
│  │   entryPointVersion: 'v0.7',                 │ │
│  │ })                                           │ │
│  │                                              │ │
│  │ // Send 5 USDT without any ETH!              │ │
│  │ const tx = await paymaster.sendUserOp({      │ │
│  │   from: accountA,                            │ │
│  │   to: accountB,                              │ │
│  │   token: USDT_ADDRESS,                       │ │
│  │   amount: '5000000', // 5 USDT               │ │
│  │   // Paymaster auto-selected based on:      │ │
│  │   // - Your SBT holdings                     │ │
│  │   // - Your PNT balance                      │ │
│  │   // - Best price & reputation               │ │
│  │ })                                           │ │
│  │                                              │ │
│  │ console.log('Tx Hash:', tx.hash)             │ │
│  │ console.log('Gas Paid By:', tx.gasToken)     │ │
│  │ // Output: Gas Paid By: 2.5 PNTs             │ │
│  │ ```                                          │ │
│  │ [Copy Full Example]                          │ │
│  │                                              │ │
│  │ 📊 Example Transaction Report:               │ │
│  │ ┌────────────────────────────────────────┐  │ │
│  │ │ From: 0xAAA...111                      │  │ │
│  │ │ To: 0xBBB...222                        │  │ │
│  │ │ Amount: 5 USDT                         │  │ │
│  │ │ Network: Sepolia                       │  │ │
│  │ │ ─────────────────────────────────      │  │ │
│  │ │ Paymaster: MyCommunity (0x789...)      │  │ │
│  │ │ Gas Cost: 0.0023 ETH                   │  │ │
│  │ │ Paid With: 2.5 MYCOMM-PNT              │  │ │
│  │ │ You Saved: 0.0023 ETH! ✨               │  │ │
│  │ └────────────────────────────────────────┘  │ │
│  └──────────────────────────────────────────────┘ │
│                                                    │
│  🏗️ Section 3: Build Community Paymaster          │
│  ┌──────────────────────────────────────────────┐ │
│  │ Want to help your community launch their     │ │
│  │ own Paymaster?                               │ │
│  │                                              │ │
│  │ → See Community Operators Guide              │ │
│  │ [Go to Operators Portal →]                   │ │
│  └──────────────────────────────────────────────┘ │
│                                                    │
│  📊 Section 4: Comparison Table                    │
│  ┌──────────────────────────────────────────────┐ │
│  │ Feature          │ Traditional │ SuperPM    │ │
│  │──────────────────┼─────────────┼────────────│ │
│  │ ETH Required     │ ✅ Yes      │ ❌ No      │ │
│  │ ERC20 Approve    │ ✅ Yes      │ ❌ No      │ │
│  │ Onboarding Time  │ 10+ mins    │ < 1 min    │ │
│  │ Gas Token Choice │ ETH only    │ Multi-token│ │
│  │ Censorship Risk  │ Medium      │ Low        │ │
│  │ Community Revenue│ None        │ 0-10% fee  │ │
│  └──────────────────────────────────────────────┘ │
│                                                    │
│  🎮 Try It Yourself!                               │
│  [Launch Developer Demo →]                         │
│  (Links to aastar.io/demo?role=developer)         │
│                                                    │
│  📚 Additional Resources                           │
│  • API Reference                                   │
│  • GitHub Repository                               │
│  • Integration Examples                            │
│  • Discord Support Channel                         │
│                                                    │
└────────────────────────────────────────────────────┘
```

**关键技术点**:
1. **ENS 地址显示**: 实时解析 ENS → 合约地址
2. **代码示例可切换**: v0.6/v0.7 Tab 切换
3. **一键复制**: 所有代码块支持复制
4. **语法高亮**: 使用 `react-syntax-highlighter`

---

### 3.3 Community Operators Portal (/operators)

#### **主页: /operators**

```
┌────────────────────────────────────────────────────┐
│  Breadcrumb: Home > Community Operators            │
│  Language: [🇬🇧 EN] [🇨🇳 中文]                        │
├────────────────────────────────────────────────────┤
│  💡 Section 1: Why Community Paymaster?            │
│  ┌──────────────────────────────────────────────┐ │
│  │ Communities face 3 key challenges:           │ │
│  │ 1. Onboarding: Hard to bring users on-chain  │ │
│  │ 2. Engagement: Difficult to track activities│ │
│  │ 3. Sustainability: No revenue model          │ │
│  │                                              │ │
│  │ SuperPaymaster + COS72 Solution:             │ │
│  │                                              │ │
│  │  [SVG: triangle.svg - centered]              │ │
│  │         Tasks → PNTs → Shops                 │ │
│  │                                              │ │
│  │ • Tasks: Members contribute to community     │ │
│  │ • PNTs: Earn community points (gas token)    │ │
│  │ • Shops: Spend PNTs on perks & services      │ │
│  │ • Loop: Sustainable value circulation        │ │
│  └──────────────────────────────────────────────┘ │
│                                                    │
│  🚀 Section 2: How to Launch? (Overview)           │
│  ┌──────────────────────────────────────────────┐ │
│  │ 5 Steps to Launch Your Community Paymaster:  │ │
│  │                                              │ │
│  │ 1. ⚙️ Prepare Accounts & Configuration        │ │
│  │ 2. 📜 Deploy Paymaster Contract               │ │
│  │ 3. 🪙 Create SBT & Gas Token (PNT)            │ │
│  │ 4. 💰 Stake & Register to SuperPaymaster      │ │
│  │ 5. ✅ Test & Monitor                          │ │
│  │                                              │ │
│  │ [Read Detailed Guide →]                      │ │
│  │ [Try in Playground →]                        │ │
│  └──────────────────────────────────────────────┘ │
│                                                    │
│  💰 Section 3: Revenue Model                       │
│  ┌──────────────────────────────────────────────┐ │
│  │ Standalone Mode:                             │ │
│  │ • Use SuperPaymaster for free                │ │
│  │ • Serve your community members               │ │
│  │ • Earn service fee (0-10%, default 2%)       │ │
│  │ • No external dependencies                   │ │
│  │                                              │ │
│  │ Protocol Mode (Advanced):                    │ │
│  │ • Run decentralized validator node           │ │
│  │ • Earn aPNTs rewards                         │ │
│  │ • Accumulate reputation score                │ │
│  │ • Receive GToken distribution                │ │
│  │ • Cross-community value exchange             │ │
│  │                                              │ │
│  │ [Learn More About Protocol →]                │ │
│  └──────────────────────────────────────────────┘ │
│                                                    │
│  🌟 Section 4: Success Stories                     │
│  ┌──────────────────────────────────────────────┐ │
│  │ AAStar Community                             │ │
│  │ • 523 sponsored operations                   │ │
│  │ • 0.12 ETH saved for members                 │ │
│  │ • 45 active users                            │ │
│  │                                              │ │
│  │ BBCommunity                                  │ │
│  │ • 234 sponsored operations                   │ │
│  │ • Custom NFT perks integrated                │ │
│  │ • $500 monthly service fee revenue           │ │
│  └──────────────────────────────────────────────┘ │
│                                                    │
│  🎯 Ready to Start?                                │
│  ┌────────────────┐  ┌────────────────┐          │
│  │ Read Full      │  │ Practice in    │          │
│  │ Tutorial       │  │ Playground     │          │
│  │ [Guide →]      │  │ [Demo →]       │          │
│  └────────────────┘  └────────────────┘          │
│                                                    │
└────────────────────────────────────────────────────┘
```

---

#### **新增: Launch Guide Page - /operators/launch-guide**

这是关键的独立教程页面,类似 GitBook 风格。

```
┌────────────────────────────────────────────────────┐
│  📚 Community Paymaster Launch Guide               │
│  Breadcrumb: Home > Operators > Launch Guide       │
├──────┬─────────────────────────────────────────────┤
│      │                                             │
│ TOC  │  📖 Complete Guide to Launching Your        │
│      │     Community Paymaster                     │
│ ├─ 1 │                                             │
│ ├─ 2 │  ⏱️ Estimated Time: 30-45 minutes            │
│ ├─ 3 │  💰 Required: ~0.1 ETH (testnet free)       │
│ ├─ 4 │  🛠️ Tools: MetaMask + Browser                │
│ └─ 5 │                                             │
│      │  ═══════════════════════════════════════   │
│      │                                             │
│      │  ## Step 1: Preparation                     │
│      │                                             │
│      │  ### 1.1 Accounts Setup                     │
│      │                                             │
│      │  You need 2 accounts:                       │
│      │                                             │
│      │  **A. Owner Account (EOA)**                 │
│      │  • Initial deployment & configuration       │
│      │  • Can transfer ownership later to multisig│
│      │  • Needs ~0.05 ETH for gas                  │
│      │                                             │
│      │  **B. Treasury Account (Multisig)**         │
│      │  • Receives service fee revenue             │
│      │  • Recommended: Gnosis Safe multisig        │
│      │  • One per network                          │
│      │                                             │
│      │  ✅ Checklist:                              │
│      │  □ MetaMask installed                       │
│      │  □ Owner EOA created                        │
│      │  □ Owner has 0.05+ ETH (mainnet) or        │
│      │    testnet ETH (sepolia/op-sepolia)        │
│      │  □ Treasury address prepared                │
│      │                                             │
│      │  ───────────────────────────────────        │
│      │                                             │
│      │  ### 1.2 Network Selection                  │
│      │                                             │
│      │  Choose your deployment network:            │
│      │                                             │
│      │  **Testnet (Recommended for first try)**   │
│      │  • Sepolia: Free ETH from faucet            │
│      │  • OP Sepolia: Fast & cheap                 │
│      │                                             │
│      │  **Mainnet (Production)**                   │
│      │  • Ethereum Mainnet: Highest security       │
│      │  • OP Mainnet: Lower gas costs              │
│      │                                             │
│      │  🔗 Faucets:                                │
│      │  • Sepolia: https://sepoliafaucet.com      │
│      │  • OP Sepolia: https://app.optimism.io/    │
│      │                faucet                       │
│      │                                             │
│      │  ───────────────────────────────────        │
│      │                                             │
│      │  ### 1.3 Community Planning                 │
│      │                                             │
│      │  Define your community parameters:          │
│      │                                             │
│      │  - **Community Name**: e.g., "MyCommunity" │
│      │  - **SBT Name**: e.g., "MyCommunity Member"│
│      │  - **Gas Token (PNT) Name**: e.g.,         │
│      │    "MyCommunity Points"                    │
│      │  - **Token Symbol**: e.g., "MYCOMM-PNT"    │
│      │  - **Initial PNT Supply**: e.g., 1,000,000 │
│      │  - **Service Fee**: 0-10% (default: 2%)    │
│      │                                             │
│      │  💡 Tip: Choose names that reflect your    │
│      │  community's identity!                      │
│      │                                             │
│      │  [Next: Step 2 →]                           │
│      │                                             │
│      │  ═══════════════════════════════════════   │
│      │                                             │
│      │  ## Step 2: Deploy Paymaster Contract       │
│      │                                             │
│      │  ### 2.1 Access Deployment Interface        │
│      │                                             │
│      │  **Option A: Use Playground (Recommended)** │
│      │  Visit: https://aastar.io/demo?role=       │
│      │         operator&step=deploy               │
│      │                                             │
│      │  **Option B: Direct Contract Interaction** │
│      │  Use Etherscan Write Contract interface    │
│      │                                             │
│      │  [Screenshot: Deployment interface]         │
│      │                                             │
│      │  ───────────────────────────────────        │
│      │                                             │
│      │  ### 2.2 Connect Wallet                     │
│      │                                             │
│      │  1. Click "Connect Wallet"                  │
│      │  2. Select MetaMask                         │
│      │  3. Approve connection                      │
│      │  4. Ensure correct network selected         │
│      │                                             │
│      │  ✅ You should see:                         │
│      │  "Connected: 0x123...abc"                   │
│      │                                             │
│      │  ───────────────────────────────────        │
│      │                                             │
│      │  ### 2.3 Fill Deployment Form               │
│      │                                             │
│      │  ```                                        │
│      │  Configuration                              │
│      │  ┌─────────────────────────────────────┐  │
│      │  │ Community Name: [MyCommunity     ]  │  │
│      │  │ Owner: 0x123...abc (Auto-filled)    │  │
│      │  │ Treasury: [0x456...def          ]   │  │
│      │  │ Service Fee: [2 ]% (0-10%)          │  │
│      │  │ Network: [Sepolia ▼]                │  │
│      │  │                                     │  │
│      │  │ [Deploy Paymaster]                  │  │
│      │  └─────────────────────────────────────┘  │
│      │  ```                                        │
│      │                                             │
│      │  ───────────────────────────────────        │
│      │                                             │
│      │  ### 2.4 Confirm Transaction                │
│      │                                             │
│      │  1. Click "Deploy Paymaster"                │
│      │  2. MetaMask popup appears                  │
│      │  3. Review gas cost (~0.02 ETH)             │
│      │  4. Click "Confirm"                         │
│      │                                             │
│      │  [GIF: MetaMask confirmation flow]          │
│      │                                             │
│      │  ⏳ Status: Deploying...                    │
│      │  ⏳ Waiting for confirmation...             │
│      │  ✅ Deployed at: 0x789ABC...DEF             │
│      │                                             │
│      │  🎉 Congratulations! Your Paymaster is     │
│      │  deployed!                                  │
│      │                                             │
│      │  📋 Save this address:                      │
│      │  **Paymaster: 0x789ABC...DEF**              │
│      │                                             │
│      │  [Copy Address] [View on Etherscan]        │
│      │                                             │
│      │  [Next: Step 3 →]                           │
│      │                                             │
│      │  ═══════════════════════════════════════   │
│      │                                             │
│      │  ## Step 3: Create Community Tokens         │
│      │                                             │
│      │  ### 3.1 Deploy SBT (Soul Bound Token)      │
│      │                                             │
│      │  SBT represents community membership.       │
│      │  • Non-transferable                         │
│      │  • Proves membership identity               │
│      │  • Required to use your Paymaster           │
│      │                                             │
│      │  **Deployment Form:**                       │
│      │  ```                                        │
│      │  ┌─────────────────────────────────────┐  │
│      │  │ Token Type: [SBT]                   │  │
│      │  │ Name: [MyCommunity Member       ]   │  │
│      │  │ Symbol: [MYCOMM-SBT            ]    │  │
│      │  │ Base URI: (Optional)                │  │
│      │  │                                     │  │
│      │  │ [Deploy SBT]                        │  │
│      │  └─────────────────────────────────────┘  │
│      │  ```                                        │
│      │                                             │
│      │  ✅ Deployed: 0xSBT123...ABC                │
│      │                                             │
│      │  ───────────────────────────────────        │
│      │                                             │
│      │  ### 3.2 Deploy Gas Token (PNT)             │
│      │                                             │
│      │  PNT is your community's gas payment token. │
│      │  • ERC-20 standard                          │
│      │  • Used to pay for gas in your Paymaster   │
│      │  • Can be earned through community tasks   │
│      │                                             │
│      │  **Deployment Form:**                       │
│      │  ```                                        │
│      │  ┌─────────────────────────────────────┐  │
│      │  │ Token Type: [ERC-20 PNT]            │  │
│      │  │ Name: [MyCommunity Points       ]   │  │
│      │  │ Symbol: [MYCOMM-PNT            ]    │  │
│      │  │ Decimals: [18]                      │  │
│      │  │ Initial Supply: [1000000       ]    │  │
│      │  │                                     │  │
│      │  │ [Deploy PNT]                        │  │
│      │  └─────────────────────────────────────┘  │
│      │  ```                                        │
│      │                                             │
│      │  ✅ Deployed: 0xPNT456...DEF                │
│      │                                             │
│      │  ───────────────────────────────────        │
│      │                                             │
│      │  ### 3.3 Link Tokens to Paymaster           │
│      │                                             │
│      │  Configure your Paymaster to recognize     │
│      │  these tokens:                              │
│      │                                             │
│      │  ```                                        │
│      │  ┌─────────────────────────────────────┐  │
│      │  │ Paymaster: 0x789ABC...DEF           │  │
│      │  │                                     │  │
│      │  │ SBT Address:                        │  │
│      │  │ [0xSBT123...ABC                 ]   │  │
│      │  │ [Set SBT]                           │  │
│      │  │ ✅ SBT configured                    │  │
│      │  │                                     │  │
│      │  │ Gas Token (PNT) Address:            │  │
│      │  │ [0xPNT456...DEF                 ]   │  │
│      │  │ [Set Gas Token]                     │  │
│      │  │ ✅ Gas Token configured              │  │
│      │  └─────────────────────────────────────┘  │
│      │  ```                                        │
│      │                                             │
│      │  🎉 Token setup complete!                  │
│      │                                             │
│      │  [Next: Step 4 →]                           │
│      │                                             │
│      │  ═══════════════════════════════════════   │
│      │                                             │
│      │  ## Step 4: Stake & Register                │
│      │                                             │
│      │  ### 4.1 Why Stake GToken?                  │
│      │                                             │
│      │  Staking GToken serves two purposes:        │
│      │  1. **Anti-spam**: Prevents malicious      │
│      │     Paymaster registration                  │
│      │  2. **Reputation**: Higher stake =         │
│      │     higher trust score                      │
│      │                                             │
│      │  Minimum stake: **10 GToken**               │
│      │  Recommended: 20-50 GToken for higher rank │
│      │                                             │
│      │  ───────────────────────────────────        │
│      │                                             │
│      │  ### 4.2 Get GToken                         │
│      │                                             │
│      │  **Testnet:**                               │
│      │  Visit: https://faucet.aastar.io/gtoken   │
│      │  Request 20 GToken (free)                   │
│      │                                             │
│      │  **Mainnet:**                               │
│      │  Swap ETH for GToken on Uniswap            │
│      │                                             │
│      │  ───────────────────────────────────        │
│      │                                             │
│      │  ### 4.3 Approve & Stake                    │
│      │                                             │
│      │  ```                                        │
│      │  ┌─────────────────────────────────────┐  │
│      │  │ Stake GToken                        │  │
│      │  │                                     │  │
│      │  │ Your Balance: 20 GToken             │  │
│      │  │ Amount to Stake: [10      ] GToken  │  │
│      │  │                                     │  │
│      │  │ ⚡ Step 1: Approve                   │  │
│      │  │ [Approve GToken] → MetaMask popup   │  │
│      │  │ ✅ Approved                          │  │
│      │  │                                     │  │
│      │  │ ⚡ Step 2: Stake                     │  │
│      │  │ [Stake] → MetaMask confirmation     │  │
│      │  │ ✅ Staked: 10 GToken                 │  │
│      │  └─────────────────────────────────────┘  │
│      │  ```                                        │
│      │                                             │
│      │  💡 Tip: You can add more stake anytime    │
│      │  to increase your reputation!               │
│      │                                             │
│      │  ───────────────────────────────────        │
│      │                                             │
│      │  ### 4.4 Register to SuperPaymaster         │
│      │                                             │
│      │  Final step: Register your Paymaster to    │
│      │  the global registry.                       │
│      │                                             │
│      │  ```                                        │
│      │  ┌─────────────────────────────────────┐  │
│      │  │ Register Paymaster                  │  │
│      │  │                                     │  │
│      │  │ Paymaster: 0x789ABC...DEF           │  │
│      │  │ SBT: 0xSBT123...ABC ✓               │  │
│      │  │ Gas Token: 0xPNT456...DEF ✓         │  │
│      │  │ Stake: 10 GToken ✓                  │  │
│      │  │                                     │  │
│      │  │ All requirements met!               │  │
│      │  │                                     │  │
│      │  │ [Register to SuperPaymaster]        │  │
│      │  └─────────────────────────────────────┘  │
│      │  ```                                        │
│      │                                             │
│      │  ⏳ Registering...                          │
│      │  ✅ Registration successful!                │
│      │                                             │
│      │  🎊 Your Paymaster is now LIVE!            │
│      │                                             │
│      │  [View on Registry Explorer]                │
│      │                                             │
│      │  [Next: Step 5 →]                           │
│      │                                             │
│      │  ═══════════════════════════════════════   │
│      │                                             │
│      │  ## Step 5: Test & Monitor                  │
│      │                                             │
│      │  ### 5.1 Issue Test Tokens                  │
│      │                                             │
│      │  Create a test user to verify your         │
│      │  Paymaster works:                           │
│      │                                             │
│      │  ```                                        │
│      │  ┌─────────────────────────────────────┐  │
│      │  │ Test User Setup                     │  │
│      │  │                                     │  │
│      │  │ User Address:                       │  │
│      │  │ [0xUSER123...ABC               ]    │  │
│      │  │                                     │  │
│      │  │ [Mint 1 SBT to User]                │  │
│      │  │ ✅ SBT issued                        │  │
│      │  │                                     │  │
│      │  │ [Send 100 PNTs to User]             │  │
│      │  │ ✅ 100 PNTs sent                     │  │
│      │  └─────────────────────────────────────┘  │
│      │  ```                                        │
│      │                                             │
│      │  ───────────────────────────────────        │
│      │                                             │
│      │  ### 5.2 Run Test Transaction               │
│      │                                             │
│      │  Simulate a real user transaction:          │
│      │                                             │
│      │  - User sends 5 USDT to another address    │
│      │  - Gas paid with your community's PNT      │
│      │  - No ETH required!                         │
│      │                                             │
│      │  [Run Test in Playground →]                 │
│      │                                             │
│      │  **Expected Result:**                       │
│      │  ```                                        │
│      │  ✅ Transaction successful                  │
│      │  Gas Cost: 0.0023 ETH                       │
│      │  Paid with: 2.5 MYCOMM-PNT                  │
│      │  Service Fee: 0.05 PNT (2%)                 │
│      │  Treasury Balance: +0.05 PNT                │
│      │  ```                                        │
│      │                                             │
│      │  ───────────────────────────────────        │
│      │                                             │
│      │  ### 5.3 Monitor Performance                │
│      │                                             │
│      │  Track your Paymaster's activity:           │
│      │                                             │
│      │  **Registry Explorer:**                     │
│      │  https://superpaymaster.aastar.io/        │
│      │  registry?pm=0x789ABC...DEF                │
│      │                                             │
│      │  **Key Metrics:**                           │
│      │  - Total sponsored operations               │
│      │  - Gas saved for users                      │
│      │  - Service fee revenue                      │
│      │  - Reputation score                         │
│      │  - Active users                             │
│      │                                             │
│      │  ───────────────────────────────────        │
│      │                                             │
│      │  ### 5.4 EntryPoint Management              │
│      │                                             │
│      │  Your Paymaster needs ETH balance in       │
│      │  EntryPoint contracts to pay for actual    │
│      │  gas (it then collects PNTs from users).   │
│      │                                             │
│      │  ```                                        │
│      │  ┌─────────────────────────────────────┐  │
│      │  │ EntryPoint Balance Management       │  │
│      │  │                                     │  │
│      │  │ [v0.6] [v0.7] [v0.8]                │  │
│      │  │                                     │  │
│      │  │ Current Balance: 0.1 ETH            │  │
│      │  │ Recommended: 0.5+ ETH               │  │
│      │  │                                     │  │
│      │  │ Actions:                            │  │
│      │  │ • Deposit: [Amount] [Deposit]       │  │
│      │  │ • Stake: [Amount] [Stake]           │  │
│      │  │ • Withdraw: [Amount] [Withdraw]     │  │
│      │  └─────────────────────────────────────┘  │
│      │  ```                                        │
│      │                                             │
│      │  💡 Monitor balance regularly to avoid     │
│      │  service interruption!                      │
│      │                                             │
│      │  ═══════════════════════════════════════   │
│      │                                             │
│      │  ## 🎉 Congratulations!                     │
│      │                                             │
│      │  You've successfully launched your         │
│      │  Community Paymaster!                       │
│      │                                             │
│      │  ### Next Steps:                            │
│      │                                             │
│      │  1. **Promote to Community**                │
│      │     - Share Paymaster address               │
│      │     - Explain how members get SBT & PNTs   │
│      │     - Create onboarding guide               │
│      │                                             │
│      │  2. **Set Up PNT Distribution**             │
│      │     - Define earning rules (tasks, etc.)   │
│      │     - Create reward mechanisms              │
│      │     - Consider gamification                 │
│      │                                             │
│      │  3. **Monitor & Optimize**                  │
│      │     - Track usage metrics                   │
│      │     - Adjust service fee if needed          │
│      │     - Refill EntryPoint balance             │
│      │                                             │
│      │  4. **Consider Protocol Mode**              │
│      │     - Run validator node                    │
│      │     - Earn additional rewards               │
│      │     - Join decentralized network            │
│      │                                             │
│      │  ───────────────────────────────────        │
│      │                                             │
│      │  ### Resources:                             │
│      │                                             │
│      │  • [API Documentation]                      │
│      │  • [Smart Contract Source Code]             │
│      │  • [Community Discord]                      │
│      │  • [FAQ & Troubleshooting]                  │
│      │                                             │
│      │  ───────────────────────────────────        │
│      │                                             │
│      │  ### Common Issues:                         │
│      │                                             │
│      │  **Q: Transaction fails with "Insufficient │
│      │  PNT balance"**                             │
│      │  A: User needs more PNTs. Distribute PNTs  │
│      │  or ask them to earn through tasks.        │
│      │                                             │
│      │  **Q: "Paymaster not found" error**        │
│      │  A: Ensure registration completed. Check   │
│      │  on Registry Explorer.                      │
│      │                                             │
│      │  **Q: Service fee not accumulating**       │
│      │  A: Verify treasury address is correct.    │
│      │  Check transaction logs.                    │
│      │                                             │
│      │  [More FAQ →]                               │
│      │                                             │
└──────┴─────────────────────────────────────────────┘
```

**关键设计要点**:
1. **TOC 侧边栏**: 快速导航到任意步骤
2. **检查清单**: 每步完成后可勾选
3. **可视化辅助**: 大量截图、GIF、流程图
4. **实践入口**: 每个关键步骤都有 "Try in Playground" CTA
5. **错误处理**: FAQ 和常见问题排查
6. **进度保存**: (可选) 用户完成进度存储在 LocalStorage

---

### 3.4 Demo Playground (aastar.io/demo)

**重要**: 这是独立部署的应用,需要独立的仓库。

#### **架构设计**

```
aastar.io/demo
├─ URL Parameters:
│   ?role=end-user     → 直接进入终端用户 Demo
│   ?role=operator     → 直接进入运营者 Demo
│   ?role=developer    → 直接进入开发者 Demo
│   ?network=sepolia   → 预设网络
│   ?step=deploy       → 跳转到特定步骤 (operator)
│
├─ Components:
│   ├─ RoleSelector (默认页)
│   ├─ EndUserFlow
│   ├─ OperatorFlow
│   ├─ DeveloperFlow
│   └─ SharedComponents (WalletConnect, TransactionStatus, etc.)
│
└─ State Management: Zustand
    ├─ Role
    ├─ Network
    ├─ Step Progress
    ├─ Test Accounts
    └─ Transaction History
```

#### **入口页面: Role Selector**

```
┌────────────────────────────────────────────────────┐
│  [AAStar Logo]      Demo Playground                │
│                                                    │
│  [Network: Sepolia ▼] [EN/中文]                     │
├────────────────────────────────────────────────────┤
│                                                    │
│  🎮 Choose Your Demo Experience                    │
│                                                    │
│  ┌─────────────────────────────────────────────┐  │
│  │  👤 End User                                │  │
│  │  ────────────────────────────────────────── │  │
│  │  Experience gasless transactions            │  │
│  │  • Create account with email/passkey        │  │
│  │  • Get free test tokens                     │  │
│  │  • Send USDT without ETH                    │  │
│  │                                             │  │
│  │  ⏱️ 5 minutes                                │  │
│  │  [Start Demo →]                             │  │
│  └─────────────────────────────────────────────┘  │
│                                                    │
│  ┌─────────────────────────────────────────────┐  │
│  │  🏢 Community Operator                      │  │
│  │  ────────────────────────────────────────── │  │
│  │  Launch your community Paymaster            │  │
│  │  • Deploy Paymaster contract                │  │
│  │  • Create SBT & Gas Token                   │  │
│  │  • Stake & Register                         │  │
│  │                                             │  │
│  │  ⏱️ 15 minutes                               │  │
│  │  [Start Demo →]                             │  │
│  └─────────────────────────────────────────────┘  │
│                                                    │
│  ┌─────────────────────────────────────────────┐  │
│  │  👨‍💻 Developer                              │  │
│  │  ────────────────────────────────────────── │  │
│  │  Integrate SuperPaymaster SDK               │  │
│  │  • Install SDK                              │  │
│  │  • Configure UserOperation                  │  │
│  │  • Send gasless transaction                 │  │
│  │                                             │  │
│  │  ⏱️ 10 minutes                               │  │
│  │  [Start Demo →]                             │  │
│  └─────────────────────────────────────────────┘  │
│                                                    │
│  💡 All demos run on testnet - safe to experiment! │
│                                                    │
└────────────────────────────────────────────────────┘
```

#### **End User Flow**

(之前规划保持不变,仅调整钱包连接部分)

**关键变化**:
```tsx
// Only MetaMask support
const connectWallet = async () => {
  if (typeof window.ethereum === 'undefined') {
    alert('Please install MetaMask!');
    window.open('https://metamask.io/download/', '_blank');
    return;
  }
  
  const provider = new ethers.BrowserProvider(window.ethereum);
  await provider.send('eth_requestAccounts', []);
  // ...
}
```

#### **Operator Flow**

完全遵循 Launch Guide 的 5 步流程,但以交互形式呈现。

```
┌────────────────────────────────────────────────────┐
│  🏢 Community Operator Demo                        │
│                                                    │
│  Progress: [▓▓▓▓░░░░░░] Step 2 of 5                │
├────────────────────────────────────────────────────┤
│  Current Step: Deploy Paymaster Contract           │
│                                                    │
│  [Full Guide] [Skip to Step...] [Reset Demo]      │
│                                                    │
│  ┌──────────────────────────────────────────────┐ │
│  │ ⚙️ Configuration                              │ │
│  │                                              │ │
│  │ Community Name:                              │ │
│  │ [MyCommunity                            ]    │ │
│  │                                              │ │
│  │ Owner (Connected Wallet):                    │ │
│  │ 0x123...abc ✓                                │ │
│  │                                              │ │
│  │ Treasury Address:                            │ │
│  │ [0x456...def                            ]    │ │
│  │ 💡 Recommended: Use multisig (Gnosis Safe)   │ │
│  │                                              │ │
│  │ Service Fee:                                 │ │
│  │ [====•=====] 2% (0-10%)                      │ │
│  │                                              │ │
│  │ Network:                                     │ │
│  │ [Sepolia ▼] (Auto-detected from wallet)     │ │
│  │                                              │ │
│  │ Estimated Gas: ~0.02 ETH                     │ │
│  │                                              │ │
│  │ [Connect MetaMask] or [Deploy Paymaster]     │ │
│  └──────────────────────────────────────────────┘ │
│                                                    │
│  💡 Tip: Read the Launch Guide for detailed       │
│  explanations. This demo lets you practice!        │
│                                                    │
└────────────────────────────────────────────────────┘
```

**步骤导航**:
- Step 1: Preparation (说明页 + 检查清单)
- Step 2: Deploy Paymaster (交互表单)
- Step 3: Create Tokens (两个表单: SBT + PNT)
- Step 4: Stake & Register (两步交互)
- Step 5: Test (模拟用户交易)

**每步完成后显示**:
```
✅ Step 2 Complete!
Paymaster deployed at: 0x789ABC...DEF
[Copy Address] [View on Etherscan] [Next Step →]
```

#### **Developer Flow**

遵循 Developer Portal 的集成步骤。

```
┌────────────────────────────────────────────────────┐
│  👨‍💻 Developer Integration Demo                     │
│                                                    │
│  Progress: [▓▓▓▓▓▓░░░░] Step 3 of 5                │
├────────────────────────────────────────────────────┤
│  Current Step: Send Gasless Transaction            │
│                                                    │
│  [Code View] [Interactive View]                    │
│                                                    │
│  ┌──────────────────────────────────────────────┐ │
│  │ Terminal Simulator                           │ │
│  │                                              │ │
│  │ $ node send-transaction.js                   │ │
│  │                                              │ │
│  │ 🔍 Initializing SuperPaymaster client...     │ │
│  │ ✅ Connected to sepolia.superpaymaster.      │ │
│  │    aastar.eth                                │ │
│  │ ✅ Resolved to: 0x123...ABC                  │ │
│  │                                              │ │
│  │ 🔍 Checking account assets...                │ │
│  │ ✅ SBT: AAStar Member (0xSBT...)             │ │
│  │ ✅ PNTs: 100 MYCOMM-PNT                      │ │
│  │                                              │ │
│  │ 🔍 Finding best Paymaster...                 │ │
│  │ ℹ️  Candidates: 3 Paymasters found           │ │
│  │ ℹ️  Evaluating: MyCommunity, AAStar, BB...   │ │
│  │ ✅ Selected: MyCommunity Paymaster           │ │
│  │    Reason: Accepts MYCOMM-PNT, 2% fee       │ │
│  │                                              │ │
│  │ 📤 Building UserOperation v0.7...            │ │
│  │ ✅ UserOp constructed                        │ │
│  │                                              │ │
│  │ 📤 Sending to Bundler...                     │ │
│  │ ⏳ Waiting for confirmation...               │ │
│  │ ✅ Transaction confirmed!                    │ │
│  │                                              │ │
│  │ Tx Hash: 0x789DEF...GHI                      │ │
│  │ [View Full Report ↓]                         │ │
│  └──────────────────────────────────────────────┘ │
│                                                    │
│  📊 Transaction Report                             │
│  ┌──────────────────────────────────────────────┐ │
│  │ From: 0xAAA...111 (Contract Account)         │ │
│  │ To: 0xBBB...222                              │ │
│  │ Asset: 5 USDT                                │ │
│  │ ───────────────────────────────────────       │ │
│  │ Paymaster: MyCommunity (0x789...)            │ │
│  │ Gas Cost: 0.0023 ETH                         │ │
│  │ Paid With: 2.5 MYCOMM-PNT                    │ │
│  │ Service Fee: 0.05 PNT                        │ │
│  │ You Saved: 0.0023 ETH! ✨                     │ │
│  │ ───────────────────────────────────────       │ │
│  │ EntryPoint: v0.7 (0x0000...0007)             │ │
│  │ Block: #12345678                             │ │
│  │                                              │ │
│  │ [Download JSON] [Share] [Try Again]          │ │
│  └──────────────────────────────────────────────┘ │
│                                                    │
│  [Next: Advanced Tests →]                          │
│                                                    │
└────────────────────────────────────────────────────┘
```

---

### 3.5 Registry Explorer (/registry)

(之前规划保持不变)

```
┌────────────────────────────────────────────────────┐
│  📊 SuperPaymaster Registry Explorer               │
│  Network: [All Networks ▼]                         │
│  Search: [🔍 Address, name, or token...]            │
├────────────────────────────────────────────────────┤
│                                                    │
│  Registered Paymasters (15)                        │
│  [Sort: Reputation ▼] [Filter: Active ✓]          │
│                                                    │
│  ┌──────────────────────────────────────────────┐ │
│  │ Name       │ Network │ Ops │ Reputation     │ │
│  ├────────────┼─────────┼─────┼────────────────┤ │
│  │ AAStar PM  │ Sepolia │ 523 │ ⭐⭐⭐⭐⭐ (98)  │ │
│  │ MyCommunity│ Sepolia │  45 │ ⭐⭐⭐⭐ (85)    │ │
│  │ BBCommunity│ OP Sep  │ 234 │ ⭐⭐⭐⭐⭐ (95)  │ │
│  │ ...                                          │ │
│  └──────────────────────────────────────────────┘ │
│                                                    │
│  [Click row for details]                           │
│                                                    │
└────────────────────────────────────────────────────┘
```

**Paymaster Detail Modal**:
```
┌────────────────────────────────────────────────────┐
│  Paymaster: MyCommunity                      [✕]  │
├────────────────────────────────────────────────────┤
│  Address: 0x789ABC...DEF [Copy]                    │
│  Owner: 0x123...456 [Etherscan →]                  │
│  Treasury: 0x456...789                             │
│  Network: Sepolia                                  │
│  Status: 🟢 Active                                  │
│                                                    │
│  Tokens:                                           │
│  • SBT: MYCOMM-SBT (0xSBT...)                      │
│  • Gas Token: MYCOMM-PNT (0xPNT...)                │
│                                                    │
│  Stats:                                            │
│  ┌──────────────────────────────────────────────┐ │
│  │ Total Operations: 45                         │ │
│  │ Gas Saved: 0.1035 ETH ($190)                 │ │
│  │ Active Users: 12                             │ │
│  │ Staked: 10 GToken                            │ │
│  │ Reputation: 85/100 (⭐⭐⭐⭐)                   │ │
│  │ Service Fee: 2%                              │ │
│  │ Uptime: 99.8%                                │ │
│  └──────────────────────────────────────────────┘ │
│                                                    │
│  Recent Transactions: [View All →]                 │
│  • 0x123... 2 hours ago (5 USDT)                   │
│  • 0x456... 5 hours ago (10 DAI)                   │
│  • 0x789... 1 day ago (3 USDC)                     │
│                                                    │
│  [Use This Paymaster] [View Contract]              │
│                                                    │
└────────────────────────────────────────────────────┘
```

---

## 四、技术实现细节

### 4.1 前端技术栈

#### **SuperPaymaster Registry (superpaymaster.aastar.io)**

```json
{
  "framework": "Next.js 14 (App Router)",
  "language": "TypeScript",
  "styling": "Tailwind CSS + Framer Motion",
  "web3": {
    "provider": "ethers.js v6",
    "wallet": "MetaMask only",
    "ens": "ethers.js ENS resolver"
  },
  "state": "React Context API",
  "charts": "Recharts",
  "markdown": "react-markdown (for docs)",
  "code": "react-syntax-highlighter"
}
```

#### **Demo Playground (aastar.io/demo)**

```json
{
  "framework": "Next.js 14 (App Router)",
  "language": "TypeScript",
  "styling": "Tailwind CSS + Framer Motion",
  "web3": {
    "provider": "ethers.js v6",
    "wallet": "MetaMask only",
    "userOp": "@aastar/sdk (custom)"
  },
  "state": "Zustand (for complex flow state)",
  "terminal": "xterm.js (for terminal simulator)",
  "animation": "Lottie (for success animations)"
}
```

### 4.2 智能合约接口

#### **SuperPaymaster Registry Contract**

```solidity
// SuperPaymaster.sol (Registry)
interface ISuperPaymaster {
  // Registration
  function registerPaymaster(
    address paymasterAddress,
    address sbtToken,
    address gasToken,
    uint256 stakeAmount
  ) external;
  
  // Query
  function getRegisteredPaymasters() external view returns (address[] memory);
  function getPaymasterInfo(address pm) external view returns (PaymasterInfo memory);
  
  // Smart Router
  function findBestPaymaster(
    address user,
    address gasToken
  ) external view returns (address bestPaymaster);
  
  struct PaymasterInfo {
    address owner;
    address treasury;
    address sbtToken;
    address gasToken;
    uint256 stake;
    uint256 reputation;
    uint8 serviceFee;
    bool isActive;
  }
}
```

#### **PaymasterV4 Contract**

```solidity
// PaymasterV4.sol (Community Paymaster Template)
interface IPaymasterV4 {
  // Configuration
  function setSBT(address sbtAddress) external onlyOwner;
  function setGasToken(address tokenAddress) external onlyOwner;
  function setServiceFee(uint8 fee) external onlyOwner;
  
  // EntryPoint interactions
  function deposit() external payable;
  function addStake(uint32 unstakeDelaySec) external payable;
  function withdrawTo(address payable withdrawAddress, uint256 amount) external;
  
  // ERC-4337 required
  function validatePaymasterUserOp(
    UserOperation calldata userOp,
    bytes32 userOpHash,
    uint256 maxCost
  ) external returns (bytes memory context, uint256 validationData);
  
  function postOp(
    PostOpMode mode,
    bytes calldata context,
    uint256 actualGasCost
  ) external;
}
```

### 4.3 关键功能实现

#### **ENS 解析**

```typescript
// utils/ens.ts
import { ethers } from 'ethers';

const ENS_MAPPINGS = {
  sepolia: 'sepolia.superpaymaster.aastar.eth',
  'op-sepolia': 'op-sepolia.superpaymaster.aastar.eth',
  'op-mainnet': 'op-mainnet.superpaymaster.aastar.eth',
};

export async function resolvePaymasterAddress(
  network: string,
  provider: ethers.Provider
): Promise<string> {
  const ensName = ENS_MAPPINGS[network];
  if (!ensName) throw new Error(`Network ${network} not supported`);
  
  try {
    const address = await provider.resolveName(ensName);
    if (!address) throw new Error('ENS resolution failed');
    return address;
  } catch (error) {
    // Fallback to hardcoded addresses
    return FALLBACK_ADDRESSES[network];
  }
}

const FALLBACK_ADDRESSES = {
  sepolia: '0x123...',
  'op-sepolia': '0x456...',
  'op-mainnet': '0x789...',
};
```

#### **UserOperation 构造器**

```typescript
// utils/userOpBuilder.ts
import { ethers } from 'ethers';

export class UserOpBuilder {
  private version: '0.6' | '0.7';
  
  constructor(version: '0.6' | '0.7') {
    this.version = version;
  }
  
  async buildUserOp(params: UserOpParams): Promise<UserOperation> {
    if (this.version === '0.6') {
      return this.buildV06(params);
    } else {
      return this.buildV07(params);
    }
  }
  
  private buildV06(params: UserOpParams): UserOperationV6 {
    return {
      sender: params.sender,
      nonce: await this.getNonce(params.sender),
      initCode: params.initCode || '0x',
      callData: params.callData,
      callGasLimit: ethers.toBeHex(params.callGasLimit || 100000),
      verificationGasLimit: ethers.toBeHex(200000),
      preVerificationGas: ethers.toBeHex(50000),
      maxFeePerGas: ethers.toBeHex(params.maxFeePerGas),
      maxPriorityFeePerGas: ethers.toBeHex(params.maxPriorityFeePerGas),
      paymasterAndData: params.paymasterAddress, // ENS or address
      signature: '0x', // Placeholder
    };
  }
  
  private buildV07(params: UserOpParams): UserOperationV7 {
    return {
      sender: params.sender,
      nonce: await this.getNonce(params.sender),
      factory: params.factory,
      factoryData: params.factoryData,
      callData: params.callData,
      callGasLimit: ethers.toBeHex(params.callGasLimit || 100000),
      verificationGasLimit: ethers.toBeHex(200000),
      preVerificationGas: ethers.toBeHex(50000),
      maxFeePerGas: ethers.toBeHex(params.maxFeePerGas),
      maxPriorityFeePerGas: ethers.toBeHex(params.maxPriorityFeePerGas),
      paymaster: params.paymasterAddress, // ENS or address
      paymasterVerificationGasLimit: ethers.toBeHex(100000),
      paymasterPostOpGasLimit: ethers.toBeHex(50000),
      paymasterData: '0x',
      signature: '0x', // Placeholder
    };
  }
}
```

#### **MetaMask 钱包连接**

```typescript
// hooks/useMetaMask.ts
import { useState, useEffect } from 'react';
import { ethers } from 'ethers';

export function useMetaMask() {
  const [account, setAccount] = useState<string | null>(null);
  const [provider, setProvider] = useState<ethers.BrowserProvider | null>(null);
  const [network, setNetwork] = useState<string | null>(null);
  
  useEffect(() => {
    if (typeof window.ethereum !== 'undefined') {
      const provider = new ethers.BrowserProvider(window.ethereum);
      setProvider(provider);
      
      // Listen for account changes
      window.ethereum.on('accountsChanged', (accounts: string[]) => {
        setAccount(accounts[0] || null);
      });
      
      // Listen for network changes
      window.ethereum.on('chainChanged', (chainId: string) => {
        window.location.reload(); // Recommended by MetaMask
      });
    }
  }, []);
  
  const connect = async () => {
    if (!provider) {
      alert('Please install MetaMask!');
      window.open('https://metamask.io/download/', '_blank');
      return;
    }
    
    try {
      const accounts = await provider.send('eth_requestAccounts', []);
      setAccount(accounts[0]);
      
      const network = await provider.getNetwork();
      setNetwork(network.name);
    } catch (error) {
      console.error('Failed to connect:', error);
    }
  };
  
  const disconnect = () => {
    setAccount(null);
  };
  
  return { account, provider, network, connect, disconnect };
}
```

#### **Playground 状态管理**

```typescript
// stores/playgroundStore.ts
import { create } from 'zustand';
import { persist } from 'zustand/middleware';

interface PlaygroundState {
  // Role
  role: 'end-user' | 'operator' | 'developer' | null;
  setRole: (role: PlaygroundState['role']) => void;
  
  // Network
  network: string;
  setNetwork: (network: string) => void;
  
  // Progress
  currentStep: number;
  stepData: Record<string, any>;
  setStep: (step: number) => void;
  saveStepData: (step: number, data: any) => void;
  
  // Operator flow specific
  paymasterAddress?: string;
  sbtAddress?: string;
  gasTokenAddress?: string;
  
  // Transactions
  transactions: Transaction[];
  addTransaction: (tx: Transaction) => void;
  
  // Reset
  reset: () => void;
}

export const usePlaygroundStore = create<PlaygroundState>()(
  persist(
    (set) => ({
      role: null,
      network: 'sepolia',
      currentStep: 0,
      stepData: {},
      transactions: [],
      
      setRole: (role) => set({ role }),
      setNetwork: (network) => set({ network }),
      setStep: (currentStep) => set({ currentStep }),
      saveStepData: (step, data) =>
        set((state) => ({
          stepData: { ...state.stepData, [step]: data },
        })),
      addTransaction: (tx) =>
        set((state) => ({
          transactions: [...state.transactions, tx],
        })),
      reset: () =>
        set({
          role: null,
          currentStep: 0,
          stepData: {},
          transactions: [],
        }),
    }),
    {
      name: 'playground-storage',
    }
  )
);
```

### 4.4 部署配置

#### **SuperPaymaster Registry (Vercel)**

```yaml
# vercel.json
{
  "buildCommand": "pnpm build",
  "outputDirectory": ".next",
  "devCommand": "pnpm dev",
  "installCommand": "pnpm install",
  "framework": "nextjs",
  "regions": ["sfo1"],
  "env": {
    "NEXT_PUBLIC_SEPOLIA_RPC": "@sepolia-rpc",
    "NEXT_PUBLIC_OP_SEPOLIA_RPC": "@op-sepolia-rpc",
    "NEXT_PUBLIC_OP_MAINNET_RPC": "@op-mainnet-rpc"
  }
}
```

#### **Demo Playground (独立部署到 aastar.io/demo)**

需要与主站协调路由:

**选项 A: 主站 Nginx 反向代理**
```nginx
# aastar.io nginx config
location /demo {
  proxy_pass http://demo-playground-service:3000;
  proxy_set_header Host $host;
  proxy_set_header X-Real-IP $remote_addr;
}
```

**选项 B: Vercel 子路径部署**
```json
// vercel.json for demo-playground
{
  "rewrites": [
    { "source": "/demo/:path*", "destination": "/:path*" }
  ]
}
```

然后主站设置重定向:
```
aastar.io/demo → demo-playground.vercel.app
```

---

## 五、开发路线图

### Phase 1: 基础框架 (Week 1-2)

**SuperPaymaster Registry**
- [x] 项目初始化 (Next.js + TypeScript + Tailwind)
- [x] 基础组件库 (Button, Card, Header, Footer)
- [x] Landing Page (静态内容 + 模拟数据)
- [x] Developer Portal (文档页面,无交互)
- [x] Operators Portal 主页 (说明页)
- [x] 响应式设计

**Demo Playground**
- [x] 项目初始化 (独立 repo)
- [x] Role Selector 页面
- [x] 基础 UI 组件
- [x] MetaMask 连接组件

### Phase 2: 智能合约集成 (Week 3-4)

**SuperPaymaster Registry**
- [ ] ethers.js 集成
- [ ] ENS 解析功能
- [ ] Registry Explorer (读取链上数据)
- [ ] Statistics Dashboard (实时数据)
- [ ] Network 切换功能

**Demo Playground**
- [ ] End User Flow (完整流程)
  - [ ] 账户创建模拟
  - [ ] Faucet 集成
  - [ ] 交易发送
  - [ ] 报告生成
- [ ] MetaMask 交互完善

### Phase 3: Operator 功能 (Week 5-6)

**SuperPaymaster Registry**
- [ ] `/operators/launch-guide` 完整教程页面
  - [ ] TOC 侧边栏
  - [ ] 5个步骤详细内容
  - [ ] 截图/GIF 素材制作
  - [ ] FAQ 编写
- [ ] 教程页面与 Playground 联动

**Demo Playground**
- [ ] Operator Flow (完整流程)
  - [ ] Step 1: Preparation
  - [ ] Step 2: Deploy Paymaster
  - [ ] Step 3: Create Tokens (SBT + PNT)
  - [ ] Step 4: Stake & Register
  - [ ] Step 5: Test & Monitor
- [ ] 进度保存 (LocalStorage)
- [ ] 错误处理和提示

### Phase 4: Developer 功能 (Week 7-8)

**SuperPaymaster Registry**
- [ ] Developer Portal 代码示例优化
- [ ] API 文档页面
- [ ] 集成示例仓库 (GitHub)

**Demo Playground**
- [ ] Developer Flow (完整流程)
  - [ ] SDK 安装模拟
  - [ ] 配置生成器
  - [ ] 账户创建 API
  - [ ] 交易构造器
  - [ ] Terminal 模拟器 (xterm.js)
- [ ] 代码复制功能
- [ ] 交易报告详细版

### Phase 5: 优化与测试 (Week 9-10)

**All Projects**
- [ ] 性能优化 (代码分割、懒加载)
- [ ] 错误边界和错误处理
- [ ] 加载状态优化
- [ ] 国际化 (中英文切换)
- [ ] SEO 优化
- [ ] Analytics 集成 (Google Analytics)
- [ ] 用户测试 (Alpha 用户)
- [ ] Bug 修复

### Phase 6: 上线准备 (Week 11-12)

**Deployment**
- [ ] 域名配置
  - [ ] superpaymaster.aastar.io
  - [ ] aastar.io/demo 路由配置
- [ ] SSL 证书
- [ ] Vercel 生产部署
- [ ] 环境变量配置
- [ ] 监控告警设置 (Sentry)

**Documentation**
- [ ] 开发文档
- [ ] 部署文档
- [ ] 用户手册
- [ ] API 文档

**Marketing**
- [ ] 宣传素材 (截图、视频)
- [ ] 社交媒体发布
- [ ] 社区公告

---

## 六、关键决策与建议

### 6.1 仓库组织

**✅ 推荐: 独立仓库**

**理由**:
1. **技术栈差异**: Registry 是展示站,Playground 是交互重的 Web3 应用
2. **部署独立性**: Registry 可能每月更新,Playground 可能每周迭代
3. **团队协作**: 不同团队可以并行开发,减少冲突
4. **性能优化**: 独立优化,Playground 不影响主站加载速度

**共享资源方案**:
- 创建 `@aastar/shared-config` npm 包
- 包含: Logo/Icon URLs, 色彩变量, 通用组件
- 两个项目都引用这个包

```bash
# Shared config package
pnpm create @aastar/shared-config
cd shared-config
pnpm init

# In Registry project
pnpm add @aastar/shared-config

# In Playground project
pnpm add @aastar/shared-config
```

### 6.2 Playground 部署方案

**✅ 推荐: 独立域名 + Nginx 反向代理**

```
用户访问: aastar.io/demo
          ↓
主站 Nginx: 检测 /demo 路径
          ↓
反向代理: demo.aastar.io (内部服务)
          ↓
返回: Playground 应用
```

**优点**:
- URL 统一 (用户看到 aastar.io/demo)
- 部署独立 (Playground 可以独立更新)
- 性能好 (Nginx 缓存)

**备选方案**: Vercel Subdomain + 主站重定向
- aastar.io/demo → demo-aastar.vercel.app
- 简单但 URL 会变化

### 6.3 社区运营者引导

**✅ 推荐: 教程页面 + Playground 联动**

**理由**:
1. **学习曲线**: 先看教程理解原理,再实操
2. **双向引流**: 教程吸引阅读,Playground 增强体验
3. **降低失败率**: 教程详细说明,Playground 即时反馈
4. **SEO 友好**: 教程页面利于搜索引擎收录

**不推荐**: 仅 Playground,没有详细教程
- 原因: 运营者需要理论 + 实践结合

### 6.4 钱包集成

**✅ 确认: 仅 MetaMask**

**实现简化**:
```typescript
// 移除 WalletConnect, RainbowKit 等
// 仅保留 MetaMask 检测

if (typeof window.ethereum === 'undefined') {
  alert('Please install MetaMask!');
  window.open('https://metamask.io/download/', '_blank');
}
```

**未来扩展**: 如果需要其他钱包,建议使用 `wagmi` 但仅启用 MetaMask connector

---

## 七、资源清单

### 7.1 设计资源

**Logo & Icon**
```
Community Logo:
https://raw.githubusercontent.com/jhfnetboy/MarkDownImg/main/img/202505031325963.png

Community Icon:
https://www.aastar.io/favicon.ico
```

**SVG Assets**
```
Gas Station Animation: 
/public/gas_station_animation.svg

Triangle Diagram:
/public/triangle.svg
```

**Color Palette**
```css
/* Primary */
--orange: #FF6B35;
--orange-light: #FF8C42;
--blue: #4A90E2;
--blue-dark: #357ABD;

/* Semantic */
--success: #4CAF50;
--warning: #FFC107;
--error: #F44336;

/* Neutral */
--gray-50: #F9FAFB;
--gray-700: #374151;
--gray-900: #111827;
```

### 7.2 智能合约地址

**SuperPaymaster Registry**
```
Sepolia: TBD (待部署)
OP Sepolia: TBD
OP Mainnet: TBD

ENS Names:
sepolia.superpaymaster.aastar.eth
op-sepolia.superpaymaster.aastar.eth
op-mainnet.superpaymaster.aastar.eth
```

**EntryPoint Contracts**
```
v0.6: 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789
v0.7: 0x0000000071727De22E5E9d8BAf0edAc6f37da032
v0.8: TBD (未发布)
```

**Token Factories**
```
SBT Factory: TBD
PNT Factory: TBD
SimpleAccount Factory: 0x... (from ERC-4337 reference)
```

### 7.3 API 端点

```
Faucet API:
https://faucet.aastar.io
  GET /request-sbt?address=0x...
  GET /request-pnt?address=0x...&amount=100
  GET /request-usdt?address=0x...

Account API:
https://api.aastar.io
  POST /account/create
  GET /account/{address}
  POST /account/recover

ENS Resolver:
Built-in ethers.js resolver
```

### 7.4 外部文档链接

```
ERC-4337 Official: https://eips.ethereum.org/EIPS/eip-4337
Account Abstraction Docs: https://docs.alchemy.com/docs/account-abstraction
Gnosis Safe: https://gnosis-safe.io
MetaMask Docs: https://docs.metamask.io
```

---

## 八、FAQ

### Q1: 为什么要独立部署 Playground?

**A**: 
1. Playground 是交互重的应用,需要大量 Web3 交互
2. 独立部署便于快速迭代测试功能
3. 可以被其他产品 (AirAccount) 复用

### Q2: Operator 教程页面和 Playground 的区别?

**A**:
- **Launch Guide**: 详细的图文教程,解释"为什么"和"怎么做"
- **Playground**: 安全的沙盒环境,让用户"亲手试试"
- 联动: 教程中多处链接到 Playground,Playground 也引导阅读教程

### Q3: 如果用户不想用 MetaMask 怎么办?

**A**: 
- 目前仅支持 MetaMask,因为它是最流行的钱包
- 未来可以考虑支持 Coinbase Wallet, WalletConnect
- 建议在页面显著位置提示: "Please install MetaMask to continue"

### Q4: 如何处理不同网络的切换?

**A**:
```typescript
// 自动检测用户钱包网络
const network = await provider.getNetwork();
if (network.chainId !== EXPECTED_CHAIN_ID) {
  // 提示用户切换网络
  await window.ethereum.request({
    method: 'wallet_switchEthereumChain',
    params: [{ chainId: ethers.toQuantity(EXPECTED_CHAIN_ID) }],
  });
}
```

### Q5: Playground 的测试代币如何管理?

**A**:
- **方案 A**: 实时调用 Faucet API (可能被限流)
- **方案 B**: 预创建 50 个测试账户,轮流分配给用户
- **推荐方案 B**: 更稳定,用户体验好

### Q6: 如何保证 ENS 解析的可用性?

**A**:
```typescript
// Fallback strategy
try {
  const address = await provider.resolveName(ensName);
  if (!address) throw new Error();
  return address;
} catch {
  // Use hardcoded addresses as fallback
  return FALLBACK_ADDRESSES[network];
}
```

---

## 总结

本规划文档 v2 版本完成了以下优化:

### ✅ 核心变更
1. **Demo Playground 独立部署** - aastar.io/demo,可被多个产品复用
2. **Operator 教程页面** - 新增 `/operators/launch-guide` 详细教程
3. **仅支持 MetaMask** - 简化钱包集成,降低开发复杂度
4. **明确仓库组织** - 推荐独立 repo + 共享配置包
5. **UserOperation 接口** - 添加 v0.6/v0.7 TypeScript 定义
6. **品牌资源集成** - Logo/Icon 统一管理

### 📐 架构亮点
- **清晰的信息架构**: Landing → Role Portal → Playground → Registry
- **三条用户路径**: 开发者、运营者、终端用户各有专属流程
- **理论与实践结合**: 教程页面 + 交互 Playground 双管齐下
- **可扩展性**: 独立部署便于未来迭代

### 🎯 开发重点
1. **Phase 1-2** (4周): 基础框架 + 链上数据集成
2. **Phase 3-4** (4周): Operator 和 Developer 完整流程
3. **Phase 5-6** (4周): 优化、测试、上线

### 📊 下一步行动
1. **Review 本文档** - 确认规划是否符合预期
2. **设计稿产出** - UI/UX 设计师根据规划制作高保真原型
3. **合约准备** - 部署测试网合约,提供 ABI 和地址
4. **启动开发** - 前端团队按 Phase 1 开始实施

---

**文档位置**: `/Users/jason/Dev/mycelium/my-exploration/projects/SuperPaymaster/registry-app/registry-app-planning-v2.md`

期待你的反馈! 🚀
