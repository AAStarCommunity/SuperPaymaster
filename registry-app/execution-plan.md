# SuperPaymaster Registry & Demo 开发执行计划

> **Version**: 1.0  
> **Date**: 2025-10-09  
> **Status**: Ready for Execution  
> **Technology**: Vite + React + TypeScript

---

## 📋 调研总结

### ✅ 现有资源确认

#### 1. 合约部署信息 (Sepolia)
```json
{
  "paymasterV4": "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445",
  "entryPoint": "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
  "treasury": "0x411BD567E46C0781248dbB6a9211891C032885e5",
  "pntToken": "0xD14E87d8D8B69016Fcc08728c33799bD3F66F180",
  "sbtToken": "0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f",
  "simpleAccount": "0x94FC9B8B7cAb56C01f20A24E37C2433FCe88A10D",
  "owner": "0x411BD567E46C0781248dbB6a9211891C032885e5",
  "recipient": "0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA"
}
```

#### 2. PaymasterV4 合约关键特性
基于 `/contracts/src/v3/PaymasterV4.sol` 分析:

**核心功能**:
- ✅ EntryPoint v0.7 兼容
- ✅ 支持多个 SBT (最多 5 个)
- ✅ 支持多个 GasToken (最多 10 个)
- ✅ 直接支付模式 (Direct Payment, 无 Settlement)
- ✅ 服务费率可配置 (默认 2%, 最高 10%)
- ✅ Gas 成本上限保护
- ✅ 用户可指定 GasToken 或自动选择

**关键函数**:
```solidity
// 验证并扣除 PNT
function validatePaymasterUserOp(
  PackedUserOperation calldata userOp,
  bytes32 userOpHash,
  uint256 maxCost
) external returns (bytes memory context, uint256 validationData);

// 后置处理
function postOp(
  PostOpMode mode,
  bytes calldata context,
  uint256 actualGasCost,
  uint256 actualUserOpFeePerGas
) external;
```

**管理员函数**:
- `addSupportedSBT(address sbt)` - 添加支持的 SBT
- `addSupportedGasToken(address token)` - 添加支持的 GasToken
- `setTreasury(address)` - 设置 Treasury 地址
- `setServiceFeeRate(uint256)` - 设置服务费率
- `pause()` / `unpause()` - 紧急暂停

#### 3. Faucet API 现状
**已有端点**: `/api/mint.js`
- ✅ 支持 SBT mint
- ✅ 支持 PNT mint (100 PNT)
- ✅ 频率限制 (每地址每小时 2 次)

**需要扩展**: 
- ❌ USDT mint
- ❌ SimpleAccount 创建
- ❌ 批量测试账户初始化

#### 4. RPC 和网络
- **Sepolia RPC**: `https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N`
- **Chain ID**: 11155111
- **Block Explorer**: `https://sepolia.etherscan.io`

#### 5. 设计资源
- ✅ `gas_station_animation.svg` - 已找到
- ✅ `triangle.svg` - 已找到
- ✅ 社区 Logo: `https://raw.githubusercontent.com/jhfnetboy/MarkDownImg/main/img/202505031325963.png`
- ✅ 社区 Icon: `https://www.aastar.io/favicon.ico`

#### 6. Registry-App 现有代码评估
**位置**: `/projects/SuperPaymaster/registry-app/`

**可复用资源**:
- ✅ `public/gas_station_animation.svg`
- ✅ `public/triangle.svg`
- ✅ `superpaymaster-app.md` (产品设计文档)
- ✅ `registry-app-planning-v2.md` (规划文档)

**不复用内容**:
- ❌ `src/` Next.js 代码 (改用 Vite + React)
- ❌ `next.config.js`, `next-env.d.ts` 等 Next.js 配置

**处理方案**: 复制资源到新 repo 后,删除 `registry-app/` 目录

---

## 🎯 技术栈确认

### Demo Playground (`demo`)
```json
{
  "framework": "Vite 5",
  "ui": "React 18 + TypeScript",
  "styling": "Tailwind CSS + Framer Motion",
  "routing": "@tanstack/react-router",
  "state": "Zustand",
  "web3": "ethers.js v6",
  "terminal": "xterm.js",
  "code-highlight": "react-syntax-highlighter"
}
```

### Registry App (`registry`)
```json
{
  "framework": "Vite 5",
  "ui": "React 18 + TypeScript",
  "styling": "Tailwind CSS + Framer Motion",
  "routing": "@tanstack/react-router",
  "state": "Zustand",
  "web3": "ethers.js v6",
  "charts": "Recharts",
  "markdown": "react-markdown + remark-gfm"
}
```

### Shared Config (`aastar-shared-config`)
```json
{
  "framework": "TypeScript Library",
  "build": "tsup",
  "type": "npm package"
}
```

---

## 📦 仓库组织

```
AAStarCommunity/
├── demo                          # Demo Playground
│   └── 部署: aastar.io/demo
├── registry                      # SuperPaymaster Registry
│   └── 部署: superpaymaster.aastar.io
└── aastar-shared-config         # 共享配置包
    └── 发布: @aastar/shared-config (npm)
```

---

## 🚀 执行计划

### Phase 1: 仓库初始化和共享配置 (Day 1)

#### 1.1 Clone 仓库
```bash
cd /Users/jason/Dev/mycelium/my-exploration/projects

# Clone 三个仓库
git clone git@github.com:AAStarCommunity/demo.git
git clone git@github.com:AAStarCommunity/registry.git
git clone git@github.com:AAStarCommunity/aastar-shared-config.git
```

#### 1.2 创建共享配置包

**目标**: 提供统一的品牌、合约、网络配置

**项目初始化**:
```bash
cd aastar-shared-config
pnpm init

# 安装依赖
pnpm add -D typescript tsup @types/node
```

**目录结构**:
```
aastar-shared-config/
├── package.json
├── tsconfig.json
├── tsup.config.ts
├── src/
│   ├── index.ts              # 统一导出
│   ├── branding.ts           # Logo, Icon, Colors
│   ├── contracts.ts          # 合约地址和 ABI
│   ├── networks.ts           # RPC URLs, Chain IDs
│   └── constants.ts          # 通用常量
└── README.md
```

**核心文件内容**:

`src/branding.ts`:
```typescript
export const BRANDING = {
  logo: "https://raw.githubusercontent.com/jhfnetboy/MarkDownImg/main/img/202505031325963.png",
  icon: "https://www.aastar.io/favicon.ico",
  colors: {
    primary: "#FF6B35",
    primaryLight: "#FF8C42",
    secondary: "#4A90E2",
    secondaryDark: "#357ABD",
    success: "#4CAF50",
    warning: "#FFC107",
    error: "#F44336",
    gray50: "#F9FAFB",
    gray700: "#374151",
    gray900: "#111827"
  }
} as const;

export const LINKS = {
  main: "https://aastar.io",
  airAccount: "https://airAccount.aastar.io",
  superPaymaster: "https://superpaymaster.aastar.io",
  demo: "https://aastar.io/demo",
  github: "https://github.com/AAStarCommunity",
  discord: "https://discord.gg/aastar"
} as const;
```

`src/contracts.ts`:
```typescript
export const CONTRACTS = {
  sepolia: {
    paymasterV4: "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445",
    entryPointV07: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
    pntToken: "0xD14E87d8D8B69016Fcc08728c33799bD3F66F180",
    sbtToken: "0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f",
    simpleAccount: "0x94FC9B8B7cAb56C01f20A24E37C2433FCe88A10D",
    treasury: "0x411BD567E46C0781248dbB6a9211891C032885e5",
    // 待补充
    simpleAccountFactory: "0x...",
    gasTokenFactory: "0x...",
    superPaymasterRegistry: "0x..."
  }
} as const;

// ABI 导出 (从 contracts/out/ 复制)
export { PaymasterV4ABI } from './abis/PaymasterV4';
export { GasTokenV2ABI } from './abis/GasTokenV2';
export { SimpleAccountABI } from './abis/SimpleAccount';
```

`src/networks.ts`:
```typescript
export const NETWORKS = {
  sepolia: {
    chainId: 11155111,
    name: "Sepolia",
    rpcUrl: "https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N",
    blockExplorer: "https://sepolia.etherscan.io",
    nativeCurrency: {
      name: "Sepolia ETH",
      symbol: "ETH",
      decimals: 18
    }
  }
} as const;

export type SupportedNetwork = keyof typeof NETWORKS;
```

**发布配置**:
```json
// package.json
{
  "name": "@aastar/shared-config",
  "version": "0.1.0",
  "type": "module",
  "main": "./dist/index.js",
  "module": "./dist/index.mjs",
  "types": "./dist/index.d.ts",
  "exports": {
    ".": {
      "import": "./dist/index.mjs",
      "require": "./dist/index.js",
      "types": "./dist/index.d.ts"
    }
  },
  "files": ["dist"],
  "scripts": {
    "build": "tsup src/index.ts --format cjs,esm --dts",
    "prepublishOnly": "pnpm build"
  }
}
```

**提交并发布**:
```bash
git add .
git commit -m "feat: initial shared config package"
git push

# 发布到 npm (可选, 或使用 GitHub Packages)
pnpm publish --access public
```

#### 1.3 复制资源文件

**从 registry-app 复制到新 repos**:
```bash
# 复制 SVG 到 Demo
cp registry-app/public/gas_station_animation.svg demo/public/
cp registry-app/public/triangle.svg demo/public/

# 复制 SVG 到 Registry
cp registry-app/public/gas_station_animation.svg registry/public/
cp registry-app/public/triangle.svg registry/public/

# 复制文档到 Registry (参考用)
cp registry-app/superpaymaster-app.md registry/docs/
cp registry-app/registry-app-planning-v2.md registry/docs/
```

---

### Phase 2: Faucet API 扩展 (Day 1-2)

#### 2.1 新增端点

**位置**: `/projects/SuperPaymaster/faucet-app/api/`

**新增文件**:

##### `api/mint-usdt.js`
```javascript
const { ethers } = require("ethers");

// Mock USDT ABI (ERC20)
const USDT_ABI = [
  "function mint(address to, uint256 amount) external",
  "function balanceOf(address owner) external view returns (uint256)"
];

const USDT_ADDRESS = process.env.USDT_CONTRACT_ADDRESS || "0x..."; // 待部署
const USDT_MINT_AMOUNT = ethers.parseUnits("10", 6); // 10 USDT (6 decimals)

export default async function handler(req, res) {
  // CORS
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  
  if (req.method === "OPTIONS") return res.status(200).end();
  if (req.method !== "POST") return res.status(405).json({ error: "Method not allowed" });

  try {
    const { address } = req.body;
    
    // 验证地址
    if (!address || !/^0x[a-fA-F0-9]{40}$/.test(address)) {
      return res.status(400).json({ error: "Invalid address" });
    }
    
    // 初始化 provider
    const provider = new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);
    const signer = new ethers.Wallet(process.env.SEPOLIA_PRIVATE_KEY, provider);
    
    // Mint USDT
    const usdtContract = new ethers.Contract(USDT_ADDRESS, USDT_ABI, signer);
    const tx = await usdtContract.mint(address, USDT_MINT_AMOUNT);
    const receipt = await tx.wait();
    
    return res.status(200).json({
      success: true,
      txHash: receipt.hash,
      amount: "10 USDT",
      recipient: address
    });
  } catch (error) {
    console.error("Mint USDT error:", error);
    return res.status(500).json({ error: error.message });
  }
}
```

##### `api/create-account.js`
```javascript
const { ethers } = require("ethers");

// SimpleAccountFactory ABI
const FACTORY_ABI = [
  "function createAccount(address owner, uint256 salt) external returns (address)",
  "function getAddress(address owner, uint256 salt) external view returns (address)"
];

const FACTORY_ADDRESS = process.env.SIMPLE_ACCOUNT_FACTORY || "0x..."; // 待确认

export default async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  
  if (req.method === "OPTIONS") return res.status(200).end();
  if (req.method !== "POST") return res.status(405).json({ error: "Method not allowed" });

  try {
    const { owner, salt = 0 } = req.body;
    
    if (!owner || !/^0x[a-fA-F0-9]{40}$/.test(owner)) {
      return res.status(400).json({ error: "Invalid owner address" });
    }
    
    const provider = new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);
    const signer = new ethers.Wallet(process.env.SEPOLIA_PRIVATE_KEY, provider);
    
    const factory = new ethers.Contract(FACTORY_ADDRESS, FACTORY_ABI, signer);
    
    // 预计算地址
    const accountAddress = await factory.getAddress(owner, salt);
    
    // 检查是否已部署
    const code = await provider.getCode(accountAddress);
    if (code !== "0x") {
      return res.status(200).json({
        success: true,
        accountAddress,
        alreadyDeployed: true
      });
    }
    
    // 创建账户
    const tx = await factory.createAccount(owner, salt);
    const receipt = await tx.wait();
    
    return res.status(200).json({
      success: true,
      txHash: receipt.hash,
      accountAddress,
      owner,
      salt
    });
  } catch (error) {
    console.error("Create account error:", error);
    return res.status(500).json({ error: error.message });
  }
}
```

##### `api/init-pool.js`
```javascript
const { ethers } = require("ethers");
const fs = require("fs");
const path = require("path");

// 管理员专用: 初始化测试账户池
export default async function handler(req, res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  
  if (req.method === "OPTIONS") return res.status(200).end();
  if (req.method !== "POST") return res.status(405).json({ error: "Method not allowed" });

  try {
    const { adminKey, count = 20 } = req.body;
    
    // 验证管理员权限
    if (adminKey !== process.env.ADMIN_SECRET) {
      return res.status(403).json({ error: "Forbidden" });
    }
    
    const provider = new ethers.JsonRpcProvider(process.env.SEPOLIA_RPC_URL);
    const signer = new ethers.Wallet(process.env.SEPOLIA_PRIVATE_KEY, provider);
    
    const accounts = [];
    
    for (let i = 0; i < count; i++) {
      // 创建随机钱包
      const wallet = ethers.Wallet.createRandom();
      
      // 使用 wallet.address 作为 owner 创建 SimpleAccount
      const accountResponse = await createAccount(wallet.address, i, provider, signer);
      
      // Mint SBT
      await mintSBT(accountResponse.accountAddress, provider, signer);
      
      // Mint 100 PNT
      await mintPNT(accountResponse.accountAddress, provider, signer);
      
      // Mint 10 USDT
      await mintUSDT(accountResponse.accountAddress, provider, signer);
      
      accounts.push({
        index: i,
        accountAddress: accountResponse.accountAddress,
        owner: wallet.address,
        privateKey: wallet.privateKey,
        hasSBT: true,
        pntBalance: "100",
        usdtBalance: "10"
      });
      
      console.log(`Initialized account ${i + 1}/${count}`);
    }
    
    // 保存到配置文件
    const configPath = path.join(process.cwd(), "test-accounts-pool.json");
    fs.writeFileSync(configPath, JSON.stringify(accounts, null, 2));
    
    return res.status(200).json({
      success: true,
      count: accounts.length,
      accounts
    });
  } catch (error) {
    console.error("Init pool error:", error);
    return res.status(500).json({ error: error.message });
  }
}

// 辅助函数
async function createAccount(owner, salt, provider, signer) {
  const factory = new ethers.Contract(
    process.env.SIMPLE_ACCOUNT_FACTORY,
    ["function createAccount(address owner, uint256 salt) external returns (address)"],
    signer
  );
  const tx = await factory.createAccount(owner, salt);
  const receipt = await tx.wait();
  // 从事件中获取 accountAddress (需要根据实际合约调整)
  const accountAddress = receipt.logs[0].address; // 简化处理
  return { accountAddress };
}

async function mintSBT(address, provider, signer) {
  const sbt = new ethers.Contract(
    process.env.SBT_CONTRACT_ADDRESS,
    ["function safeMint(address to) external"],
    signer
  );
  const tx = await sbt.safeMint(address);
  await tx.wait();
}

async function mintPNT(address, provider, signer) {
  const pnt = new ethers.Contract(
    process.env.PNT_TOKEN_ADDRESS,
    ["function mint(address to, uint256 amount) external"],
    signer
  );
  const tx = await pnt.mint(address, ethers.parseUnits("100", 18));
  await tx.wait();
}

async function mintUSDT(address, provider, signer) {
  const usdt = new ethers.Contract(
    process.env.USDT_CONTRACT_ADDRESS,
    ["function mint(address to, uint256 amount) external"],
    signer
  );
  const tx = await usdt.mint(address, ethers.parseUnits("10", 6));
  await tx.wait();
}
```

#### 2.2 更新 Faucet 环境变量

`.env` 新增:
```bash
SIMPLE_ACCOUNT_FACTORY=0x...
USDT_CONTRACT_ADDRESS=0x...
ADMIN_SECRET=your-secret-key
```

#### 2.3 测试账户池生成

**执行初始化** (管理员操作):
```bash
curl -X POST https://faucet-api.vercel.app/api/init-pool \
  -H "Content-Type: application/json" \
  -d '{"adminKey": "your-secret-key", "count": 20}'
```

**输出**: `test-accounts-pool.json`

**复制到 shared-config**:
```bash
cp faucet-app/test-accounts-pool.json aastar-shared-config/src/testAccounts.json
```

**在 shared-config 中导出**:
```typescript
// src/testAccounts.ts
import accounts from './testAccounts.json';

export const TEST_ACCOUNTS = accounts;

export function getRandomTestAccount() {
  return TEST_ACCOUNTS[Math.floor(Math.random() * TEST_ACCOUNTS.length)];
}
```

---

### Phase 3: Demo Playground 开发 (Day 3-8)

#### 3.1 项目初始化

```bash
cd demo

# Vite + React + TypeScript
pnpm create vite . --template react-ts

# 安装依赖
pnpm add ethers@6
pnpm add @tanstack/react-router
pnpm add zustand
pnpm add @aastar/shared-config  # 共享配置包
pnpm add -D tailwindcss postcss autoprefixer
pnpm add framer-motion
pnpm add react-syntax-highlighter @types/react-syntax-highlighter
pnpm add xterm xterm-addon-fit

# Tailwind 初始化
pnpm dlx tailwindcss init -p
```

#### 3.2 项目结构

```
demo/
├── src/
│   ├── main.tsx
│   ├── App.tsx
│   ├── pages/
│   │   ├── RoleSelector.tsx
│   │   ├── EndUserDemo.tsx
│   │   ├── OperatorDemo.tsx
│   │   └── DeveloperDemo.tsx
│   ├── components/
│   │   ├── layout/
│   │   │   ├── Header.tsx
│   │   │   └── Footer.tsx
│   │   ├── common/
│   │   │   ├── Button.tsx
│   │   │   ├── Card.tsx
│   │   │   ├── Input.tsx
│   │   │   └── Spinner.tsx
│   │   ├── WalletConnect.tsx
│   │   ├── TransactionStatus.tsx
│   │   ├── StepIndicator.tsx
│   │   ├── ReportViewer.tsx
│   │   └── TerminalSimulator.tsx
│   ├── hooks/
│   │   ├── useMetaMask.ts
│   │   ├── useContract.ts
│   │   ├── useFaucet.ts
│   │   ├── useUserOp.ts
│   │   └── useTestAccount.ts
│   ├── stores/
│   │   └── playgroundStore.ts
│   ├── utils/
│   │   ├── userOpBuilder.ts
│   │   ├── formatters.ts
│   │   └── api.ts
│   ├── assets/
│   │   ├── gas_station_animation.svg
│   │   └── triangle.svg
│   └── styles/
│       └── globals.css
├── public/
├── index.html
├── vite.config.ts
├── tailwind.config.js
├── tsconfig.json
└── package.json
```

#### 3.3 核心功能实现

##### 3.3.1 Playground Store (Zustand)

`stores/playgroundStore.ts`:
```typescript
import { create } from 'zustand';
import { persist } from 'zustand/middleware';

export type Role = 'end-user' | 'operator' | 'developer' | null;

interface Transaction {
  hash: string;
  from: string;
  to: string;
  amount: string;
  gasToken: string;
  timestamp: number;
}

interface PlaygroundState {
  // Role
  role: Role;
  setRole: (role: Role) => void;
  
  // Network
  network: string;
  setNetwork: (network: string) => void;
  
  // Progress
  currentStep: number;
  stepData: Record<number, any>;
  setStep: (step: number) => void;
  saveStepData: (step: number, data: any) => void;
  
  // Operator specific
  paymasterAddress?: string;
  sbtAddress?: string;
  gasTokenAddress?: string;
  setPaymasterAddress: (address: string) => void;
  setSbtAddress: (address: string) => void;
  setGasTokenAddress: (address: string) => void;
  
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
          stepData: { ...state.stepData, [step]: data }
        })),
      setPaymasterAddress: (paymasterAddress) => set({ paymasterAddress }),
      setSbtAddress: (sbtAddress) => set({ sbtAddress }),
      setGasTokenAddress: (gasTokenAddress) => set({ gasTokenAddress }),
      addTransaction: (tx) =>
        set((state) => ({
          transactions: [...state.transactions, tx]
        })),
      reset: () =>
        set({
          role: null,
          currentStep: 0,
          stepData: {},
          transactions: []
        })
    }),
    {
      name: 'playground-storage'
    }
  )
);
```

##### 3.3.2 MetaMask Hook

`hooks/useMetaMask.ts`:
```typescript
import { useState, useEffect } from 'react';
import { ethers } from 'ethers';

export function useMetaMask() {
  const [account, setAccount] = useState<string | null>(null);
  const [provider, setProvider] = useState<ethers.BrowserProvider | null>(null);
  const [network, setNetwork] = useState<string | null>(null);
  const [isConnecting, setIsConnecting] = useState(false);
  
  useEffect(() => {
    if (typeof window.ethereum !== 'undefined') {
      const provider = new ethers.BrowserProvider(window.ethereum);
      setProvider(provider);
      
      // Listen for account changes
      window.ethereum.on('accountsChanged', (accounts: string[]) => {
        setAccount(accounts[0] || null);
      });
      
      // Listen for network changes
      window.ethereum.on('chainChanged', () => {
        window.location.reload();
      });
    }
    
    return () => {
      if (window.ethereum) {
        window.ethereum.removeAllListeners('accountsChanged');
        window.ethereum.removeAllListeners('chainChanged');
      }
    };
  }, []);
  
  const connect = async () => {
    if (!provider) {
      alert('Please install MetaMask!');
      window.open('https://metamask.io/download/', '_blank');
      return;
    }
    
    try {
      setIsConnecting(true);
      const accounts = await provider.send('eth_requestAccounts', []);
      setAccount(accounts[0]);
      
      const network = await provider.getNetwork();
      setNetwork(network.name);
      
      // Switch to Sepolia if not already
      if (network.chainId !== 11155111n) {
        await window.ethereum.request({
          method: 'wallet_switchEthereumChain',
          params: [{ chainId: '0xaa36a7' }] // Sepolia
        });
      }
    } catch (error: any) {
      console.error('Failed to connect:', error);
      if (error.code === 4902) {
        // Chain not added, add it
        await window.ethereum.request({
          method: 'wallet_addEthereumChain',
          params: [{
            chainId: '0xaa36a7',
            chainName: 'Sepolia',
            rpcUrls: ['https://rpc.sepolia.org'],
            nativeCurrency: { name: 'ETH', symbol: 'ETH', decimals: 18 }
          }]
        });
      }
    } finally {
      setIsConnecting(false);
    }
  };
  
  const disconnect = () => {
    setAccount(null);
  };
  
  return { account, provider, network, connect, disconnect, isConnecting };
}
```

##### 3.3.3 Faucet Hook

`hooks/useFaucet.ts`:
```typescript
import { useState } from 'react';

const FAUCET_API = import.meta.env.VITE_FAUCET_API || 'https://faucet-api.vercel.app';

export function useFaucet() {
  const [loading, setLoading] = useState(false);
  
  const requestSBT = async (address: string) => {
    setLoading(true);
    try {
      const res = await fetch(`${FAUCET_API}/api/mint`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ address, type: 'sbt' })
      });
      const data = await res.json();
      if (!data.success) throw new Error(data.error);
      return data;
    } finally {
      setLoading(false);
    }
  };
  
  const requestPNT = async (address: string) => {
    setLoading(true);
    try {
      const res = await fetch(`${FAUCET_API}/api/mint`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ address, type: 'pnt' })
      });
      const data = await res.json();
      if (!data.success) throw new Error(data.error);
      return data;
    } finally {
      setLoading(false);
    }
  };
  
  const requestUSDT = async (address: string) => {
    setLoading(true);
    try {
      const res = await fetch(`${FAUCET_API}/api/mint-usdt`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ address })
      });
      const data = await res.json();
      if (!data.success) throw new Error(data.error);
      return data;
    } finally {
      setLoading(false);
    }
  };
  
  const createAccount = async (owner: string, salt = 0) => {
    setLoading(true);
    try {
      const res = await fetch(`${FAUCET_API}/api/create-account`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ owner, salt })
      });
      const data = await res.json();
      if (!data.success) throw new Error(data.error);
      return data;
    } finally {
      setLoading(false);
    }
  };
  
  return { requestSBT, requestPNT, requestUSDT, createAccount, loading };
}
```

##### 3.3.4 End User Demo 页面

`pages/EndUserDemo.tsx`:
```typescript
import { useState } from 'react';
import { usePlaygroundStore } from '../stores/playgroundStore';
import { useFaucet } from '../hooks/useFaucet';
import { TEST_ACCOUNTS } from '@aastar/shared-config';
import { ethers } from 'ethers';

export default function EndUserDemo() {
  const [account, setAccount] = useState<any>(null);
  const [txStatus, setTxStatus] = useState<'idle' | 'loading' | 'success' | 'error'>('idle');
  const { requestSBT, requestPNT, requestUSDT, loading } = useFaucet();
  
  const handleCreateAccount = async () => {
    // 使用预生成的测试账户
    const testAccount = TEST_ACCOUNTS[Math.floor(Math.random() * TEST_ACCOUNTS.length)];
    setAccount(testAccount);
  };
  
  const handleSendTransaction = async () => {
    if (!account) return;
    
    setTxStatus('loading');
    try {
      // TODO: 构造 UserOp 并发送
      // 使用 account.privateKey 签名
      // 调用 SuperPaymaster
      
      setTxStatus('success');
    } catch (error) {
      console.error(error);
      setTxStatus('error');
    }
  };
  
  return (
    <div className="max-w-4xl mx-auto p-8">
      <h1 className="text-3xl font-bold mb-8">👤 End User Demo</h1>
      
      {/* Step 1: Create Account */}
      <div className="mb-8">
        <h2 className="text-xl font-semibold mb-4">Step 1: Create Account</h2>
        <button
          onClick={handleCreateAccount}
          className="bg-blue-500 text-white px-6 py-2 rounded"
        >
          Create Test Account
        </button>
        
        {account && (
          <div className="mt-4 bg-gray-100 p-4 rounded">
            <p>Account: {account.accountAddress}</p>
            <p>Owner: {account.owner}</p>
          </div>
        )}
      </div>
      
      {/* Step 2: Get Tokens */}
      {account && (
        <div className="mb-8">
          <h2 className="text-xl font-semibold mb-4">Step 2: Get Test Tokens</h2>
          <div className="space-y-2">
            <p>✅ SBT: AAStar Member (auto-assigned)</p>
            <p>✅ PNTs: 100 (auto-assigned)</p>
            <p>✅ USDT: 10 (auto-assigned)</p>
          </div>
        </div>
      )}
      
      {/* Step 3: Send Transaction */}
      {account && (
        <div className="mb-8">
          <h2 className="text-xl font-semibold mb-4">Step 3: Send USDT (No Gas!)</h2>
          <button
            onClick={handleSendTransaction}
            disabled={txStatus === 'loading'}
            className="bg-green-500 text-white px-6 py-2 rounded"
          >
            {txStatus === 'loading' ? 'Sending...' : 'Send 5 USDT'}
          </button>
          
          {txStatus === 'success' && (
            <div className="mt-4 bg-green-100 p-4 rounded">
              <p>✅ Transaction Successful!</p>
              <p>Gas paid with PNTs (no ETH needed)</p>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
```

##### 3.3.5 Operator Demo 页面 (5步流程)

`pages/OperatorDemo.tsx`:
```typescript
// 类似结构,实现 5 步流程
// Step 1: Preparation (说明)
// Step 2: Deploy Paymaster (MetaMask)
// Step 3: Create Tokens (SBT + PNT)
// Step 4: Stake & Register
// Step 5: Test
```

##### 3.3.6 Developer Demo 页面

`pages/DeveloperDemo.tsx`:
```typescript
// Terminal 模拟器
// 代码示例
// 交易报告
```

#### 3.4 路由配置

`App.tsx`:
```typescript
import { RouterProvider, createRouter, createRoute, createRootRoute } from '@tanstack/react-router';
import RoleSelector from './pages/RoleSelector';
import EndUserDemo from './pages/EndUserDemo';
import OperatorDemo from './pages/OperatorDemo';
import DeveloperDemo from './pages/DeveloperDemo';

const rootRoute = createRootRoute();

const routes = [
  createRoute({
    getParentRoute: () => rootRoute,
    path: '/',
    component: RoleSelector
  }),
  createRoute({
    getParentRoute: () => rootRoute,
    path: '/end-user',
    component: EndUserDemo
  }),
  createRoute({
    getParentRoute: () => rootRoute,
    path: '/operator',
    component: OperatorDemo
  }),
  createRoute({
    getParentRoute: () => rootRoute,
    path: '/developer',
    component: DeveloperDemo
  })
];

const routeTree = rootRoute.addChildren(routes);
const router = createRouter({ routeTree });

export default function App() {
  return <RouterProvider router={router} />;
}
```

---

### Phase 4: Registry App 开发 (Day 9-14)

#### 4.1 项目初始化

```bash
cd registry

# Vite + React + TypeScript
pnpm create vite . --template react-ts

# 安装依赖
pnpm add ethers@6
pnpm add @tanstack/react-router
pnpm add zustand
pnpm add @aastar/shared-config
pnpm add -D tailwindcss postcss autoprefixer
pnpm add framer-motion
pnpm add recharts
pnpm add react-markdown remark-gfm
pnpm add react-syntax-highlighter @types/react-syntax-highlighter

pnpm dlx tailwindcss init -p
```

#### 4.2 项目结构

```
registry/
├── src/
│   ├── pages/
│   │   ├── Landing.tsx
│   │   ├── DeveloperPortal.tsx
│   │   ├── OperatorsPortal.tsx
│   │   ├── LaunchGuide.tsx
│   │   └── RegistryExplorer.tsx
│   ├── components/
│   │   ├── layout/
│   │   │   ├── Header.tsx
│   │   │   └── Footer.tsx
│   │   ├── StatsDashboard.tsx
│   │   ├── NetworkSelector.tsx
│   │   ├── CodeSnippet.tsx
│   │   ├── PaymasterCard.tsx
│   │   └── GuideContent.tsx
│   ├── hooks/
│   │   ├── useRegistry.ts
│   │   └── useStatistics.ts
│   └── assets/
│       ├── gas_station_animation.svg
│       └── triangle.svg
└── ...
```

#### 4.3 核心页面

##### 4.3.1 Landing Page

**特性**:
- Hero Section (SVG Animation)
- Features Cards (3个)
- Live Statistics (从链上读取)
- Role Selection CTAs

##### 4.3.2 Developer Portal

**内容**:
- What is SuperPaymaster?
- Integration Guide (SDK, ENS, UserOp)
- UserOperation v0.6/v0.7 TypeScript 接口
- Code Examples (可复制)
- CTA: Try Demo

##### 4.3.3 Operators Portal

**内容**:
- Why Community Paymaster?
- Quick Launch Overview
- **Launch Guide 入口** (大按钮跳转)
- Revenue Model
- Protocol Benefits

##### 4.3.4 Launch Guide Page (详细教程)

**特性**:
- GitBook 风格
- TOC 侧边栏
- 5 步详细教程:
  1. Preparation
  2. Deploy Paymaster
  3. Create Tokens
  4. Stake & Register
  5. Test & Monitor
- 每步包含:
  - 详细说明
  - 配置示例
  - 截图 (待制作)
  - "Try in Playground" CTA
- FAQ 和常见问题

**实现**:
```typescript
// pages/LaunchGuide.tsx
import ReactMarkdown from 'react-markdown';
import remarkGfm from 'remark-gfm';

const guideContent = `
# Community Paymaster Launch Guide

## Step 1: Preparation
...
`;

export default function LaunchGuide() {
  return (
    <div className="flex">
      {/* TOC Sidebar */}
      <aside className="w-64 p-4 border-r">
        <nav>
          <a href="#step-1">Step 1: Preparation</a>
          <a href="#step-2">Step 2: Deploy</a>
          ...
        </nav>
      </aside>
      
      {/* Content */}
      <main className="flex-1 p-8">
        <ReactMarkdown remarkPlugins={[remarkGfm]}>
          {guideContent}
        </ReactMarkdown>
      </main>
    </div>
  );
}
```

##### 4.3.5 Registry Explorer

**特性**:
- Paymaster 列表 (从 SuperPaymaster Registry 读取)
- 搜索和过滤
- Paymaster 详情 (统计、交易历史)

---

### Phase 5: 部署配置 (Day 15)

#### 5.1 Demo Playground 部署

**Vercel 配置**:

`demo/vercel.json`:
```json
{
  "buildCommand": "pnpm build",
  "outputDirectory": "dist",
  "installCommand": "pnpm install",
  "framework": null,
  "rewrites": [
    { "source": "/(.*)", "destination": "/index.html" }
  ],
  "env": {
    "VITE_FAUCET_API": "@faucet-api-url",
    "VITE_NETWORK": "sepolia"
  }
}
```

**主站 Nginx 反向代理** (需要你配置):
```nginx
# aastar.io nginx config
location /demo {
  proxy_pass https://demo-aastar.vercel.app;
  proxy_set_header Host $host;
  proxy_set_header X-Real-IP $remote_addr;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Proto $scheme;
}
```

**部署命令**:
```bash
cd demo
pnpm build
vercel --prod
```

#### 5.2 Registry 部署

**Vercel 配置**:

`registry/vercel.json`:
```json
{
  "buildCommand": "pnpm build",
  "outputDirectory": "dist",
  "installCommand": "pnpm install",
  "framework": null,
  "rewrites": [
    { "source": "/(.*)", "destination": "/index.html" }
  ],
  "env": {
    "VITE_SEPOLIA_RPC": "@sepolia-rpc-url"
  }
}
```

**域名配置**:
- 域名: `superpaymaster.aastar.io`
- DNS: CNAME 指向 `cname.vercel-dns.com`

**部署命令**:
```bash
cd registry
pnpm build
vercel --prod
```

---

## 📝 需要你配合的事项

### 1. 合约地址确认 (优先级: 高) ⚠️

**待提供**:
- [ ] SimpleAccountFactory 合约地址
- [ ] SuperPaymaster Registry 合约地址 (如果已部署)
- [ ] GasTokenFactory 合约地址
- [ ] USDT 测试代币合约地址 (或我部署一个 Mock USDT)

### 2. Faucet API 扩展 (优先级: 高) ⚠️

**方案**: 我来扩展 (新增 3 个端点)

**需要你提供**:
- [ ] Faucet 仓库 push 权限
- [ ] 管理员私钥 (用于批量初始化账户池)
- [ ] 确认 USDT 合约地址

### 3. 测试账户池 (优先级: 中)

**方案**: 预生成 20 个测试账户

**执行**:
- 我调用 `/api/init-pool` 生成配置文件
- 复制到 `shared-config` 并提交

### 4. 部署配置 (优先级: 中)

**需要确认**:
- [ ] 主站 (aastar.io) 是否支持 Nginx 反向代理配置?
- [ ] 如果不支持,是否接受 Vercel 子域名重定向? (用户看到的 URL 会变)
- [ ] `superpaymaster.aastar.io` DNS 配置权限

### 5. 设计资源 (优先级: 低)

**Launch Guide 需要**:
- [ ] MetaMask 连接截图
- [ ] 交易确认 GIF
- [ ] 部署流程演示

**处理方案**:
- 我提供文字描述
- 你用 Figma/Midjourney 生成
- 或先用占位图,后续替换

### 6. Registry-App 目录清理

**确认**:
- [ ] 资源复制到新 repo 后,删除 `registry-app/` 目录

---

## ⏱️ 时间估算

### MVP 路径 (4 周)

**Week 1**: Shared Config + Faucet + Demo 基础
- Day 1-2: Repos 初始化 + Shared Config
- Day 3-4: Faucet API 扩展 + 测试账户池
- Day 5-7: Demo 项目初始化 + 基础组件

**Week 2**: Demo 完整功能
- Day 8-10: End User Demo
- Day 11-12: Operator Demo (5 步)
- Day 13-14: Developer Demo

**Week 3**: Registry 核心页面
- Day 15-16: Landing + Developer Portal
- Day 17-18: Operators Portal + Launch Guide
- Day 19-21: Registry Explorer

**Week 4**: 优化和部署
- Day 22-24: 优化、测试、Bug 修复
- Day 25-26: 部署配置和上线
- Day 27-28: 文档和交接

---

## 🚀 立即开始的步骤

请确认以下事项后我立即执行:

### 必须确认 ✅
- [ ] **仓库权限**: 我有 push 权限到三个仓库
- [ ] **Faucet 扩展**: 确认我来扩展 (需要仓库权限)
- [ ] **技术栈**: Vite + React + TypeScript 确认
- [ ] **时间预期**: 4 周 MVP 可接受

### 待补充信息 ⏳
- [ ] SimpleAccountFactory 地址 (或我先用 mock)
- [ ] USDT 合约地址 (或我部署 mock)
- [ ] SuperPaymaster Registry 地址 (如果未部署,我可以等)
- [ ] Faucet 管理员私钥 (用于初始化账户池)

### 可延后处理 💡
- [ ] Nginx 反向代理配置 (可先用 Vercel 子域名)
- [ ] 设计资源 (可先用占位图)
- [ ] Registry Explorer (可 Phase 2 实现)

---

## 📌 第一天执行清单

一旦你确认,我将立即开始:

**上午** (2-3 小时):
1. Clone 三个仓库到 `projects/`
2. 创建 `aastar-shared-config` 包结构
3. 从 `contracts/out/` 提取 ABI
4. 发布 `@aastar/shared-config` v0.1.0

**下午** (3-4 小时):
5. 复制 SVG 资源到新 repos
6. 在 `faucet-app/api/` 创建 3 个新端点
7. 测试新 API 端点
8. 生成测试账户池配置文件

**晚上** (可选):
9. Demo 项目初始化
10. 基础组件开发

---

## 📊 进度汇报

我会每天在这里汇报进度:

- **Day 1**: ✅ Repos 初始化 + Shared Config + Faucet 扩展
- **Day 2**: ⏳ 测试账户池 + Demo 基础框架
- ...

---

## ❓ 你的确认

请回复以下内容:

1. ✅ **技术栈确认**: Vite + React + TypeScript
2. ✅ **Faucet 扩展**: 我来做 (需要 push 权限)
3. ⏳ **缺失合约地址**: 先用 mock 还是等你提供?
4. ⏳ **部署方案**: Nginx 反向代理可行吗?
5. ⏳ **时间预期**: 4 周 MVP 可以吗?

**准备好后回复**: "开始执行!" 🚀
