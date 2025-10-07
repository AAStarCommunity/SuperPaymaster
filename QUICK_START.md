# SuperPaymaster 快速开始指南

## 📁 项目结构

```
SuperPaymaster/
├── registry-app/           # Registry DApp
├── minter-app/             # Minter DApp
├── src/                    # 所有合约 (12个)
├── test/                   # 所有测试 (4个)
├── script/                 # 部署脚本 (11个)
└── docs/
```

## 🚀 快速命令

### 编译合约
```bash
cd /Users/jason/Dev/mycelium/my-exploration/projects/SuperPaymaster
forge build
```

### 运行测试
```bash
# 所有测试
forge test

# 带详细输出
forge test -vv

# 特定测试
forge test --match-contract GasTokenTest
forge test --match-contract SettlementTest
forge test --match-contract PaymasterV3Test
forge test --match-contract PaymasterV4Test  # V4新增
```

### 部署合约

#### 1. 部署SuperPaymasterRegistry v1.2
```bash
# 配置.env
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_API_KEY
PRIVATE_KEY=your_private_key
OWNER_ADDRESS=0x...
TREASURY_ADDRESS=0x...
MIN_STAKE_AMOUNT=10000000000000000
ROUTER_FEE_RATE=50
SLASH_PERCENTAGE=500

# 部署
forge script script/DeployRegistry_v1_2.s.sol:DeployRegistry \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify
```

#### 2. 部署GasToken生态
```bash
# 部署Factory
forge script script/DeployGasTokenFactory.s.sol:DeployGasTokenFactory \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify

# 部署GasToken
forge script script/DeployGasToken.s.sol:DeployGasToken \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify
```

#### 3. 部署PaymasterV4 (最新版本 🆕)
```bash
# 配置环境变量
ENTRY_POINT=0x0000000071727De22E5E9d8BAf0edAc6f37da032  # v0.7 EntryPoint
OWNER_ADDRESS=0x...
TREASURY_ADDRESS=0x...
GAS_TO_USD_RATE=4500000000000000000000  # 4500e18 = $4500/ETH
PNT_PRICE_USD=20000000000000000         # 0.02e18 = $0.02/PNT
SERVICE_FEE_RATE=200                     # 2%
MAX_GAS_COST_CAP=1000000000000000000    # 1e18 = 1 ETH
MIN_TOKEN_BALANCE=1000000000000000000000 # 1000e18

# 部署
forge script script/deploy-paymaster-v4.s.sol:DeployPaymasterV4 \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify

# 配置SBT和GasToken
export PAYMASTER_V4_ADDRESS=0x...  # 部署后的地址
forge script script/configure-paymaster-v4.s.sol \
  --sig "addSBT(address)" 0x... \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast

forge script script/configure-paymaster-v4.s.sol \
  --sig "addGasToken(address)" 0x... \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast

# 查看配置
forge script script/configure-paymaster-v4.s.sol \
  --sig "showConfig()" \
  --rpc-url $SEPOLIA_RPC_URL
```

## 🎯 两个DApp

### Registry-App

**启动开发服务器**:
```bash
cd registry-app
pnpm install
pnpm dev
```

**构建生产版本**:
```bash
pnpm build
pnpm start
```

**部署到Vercel**:
```bash
vercel deploy --prod
```

### Minter-App

**启动前端**:
```bash
cd minter-app/frontend
pnpm install
pnpm dev
```

**启动API**:
```bash
cd minter-app/api
pnpm install
pnpm start
```

**启动Backend**:
```bash
cd minter-app/backend
pnpm install
pnpm start
```

**完整服务管理**:
```bash
cd minter-app
./manage-services.sh start  # 启动所有服务
./manage-services.sh stop   # 停止所有服务
./manage-services.sh status # 查看状态
```

## 📊 测试状态

```
✅ 78/78 tests passed

- GasTokenTest: 9/9
- SettlementTest: 17/17
- PaymasterV3Test: 34/34
- PaymasterV4Test: 14/14 🆕
- CounterTest: 2/2
- TestEip7702: 2/2
```

## 🔧 核心合约

### Registry生态
- `SuperPaymasterRegistry_v1_2.sol` - Multi-tenancy Registry
- `Settlement.sol` - Gas费用结算
- `PaymasterV3_1.sol` - Ethereum优化版
- `PaymasterV3_2.sol` - OP优化版
- `PaymasterV4.sol` - Direct模式 (无Settlement, ~79% gas节省) 🆕

### Minter生态
- `GasToken.sol` - ERC20 gas token
- `GasTokenFactory.sol` - Token工厂
- `MySBT.sol` - Soul-Bound Token
- `SimpleAccount.sol` - AA账户
- `PNTs.sol` - Points Token

## 🆕 PaymasterV4 核心特性

### 1. 双参数定价系统
```solidity
uint256 public gasToUSDRate;  // 固定汇率 (e.g., 4500e18 = $4500/ETH)
uint256 public pntPriceUSD;   // 浮动PNT价格 (e.g., 0.02e18 = $0.02/PNT)
```

**计算公式**:
```
Step 1: gasCostUSD = gasCostWei * gasToUSDRate / 1e18
Step 2: totalCostUSD = gasCostUSD * (1 + serviceFeeRate/10000)
Step 3: pntAmount = totalCostUSD * 1e18 / pntPriceUSD
```

### 2. 支持未部署账户
- 使用 `extcodesize` 检测账户部署状态
- 未部署账户跳过SBT验证
- 支持 ERC-4337 账户部署 gas 赞助

### 3. 用户指定GasToken (v0.7)
**paymasterAndData 结构** (72 bytes):
```
Bytes  0-19:  Paymaster address
Bytes 20-35:  validUntil
Bytes 36-51:  validAfter
Bytes 52-71:  GasToken address (用户指定)
```

### 4. 多付不退策略
- 移除所有退款逻辑
- 节约 ~245k gas
- 仅发出事件供链下分析

### 5. 配置上限
```solidity
uint256 public constant MAX_SBTS = 5;
uint256 public constant MAX_GAS_TOKENS = 10;
```

### 6. Owner可修改参数
- `gasToUSDRate` - Gas到USD汇率
- `pntPriceUSD` - PNT价格
- `serviceFeeRate` - 服务费率 (最高10%)
- `maxGasCostCap` - Gas上限
- `treasury` - 服务商地址
- SBT/GasToken 数组管理

## 📝 重要文件

### 文档
- `MINTER_INTEGRATION_COMPLETE.md` - 完整集成说明
- `CONTRACTS_INTEGRATION_SUMMARY.md` - 合约集成总结
- `Directory-Reorganization-Summary.md` - 目录重组说明
- `/design/SuperPaymasterV3/PaymasterV4-Final-Design.md` - V4最终设计 🆕
- `/design/SuperPaymasterV3/PaymasterV4-Implementation-Complete.md` - V4实现总结 🆕

### 配置
- `foundry.toml` - Foundry配置
- `.env` - 环境变量
- `registry-app/.env.production` - Registry配置
- `minter-app/.env.production` - Minter配置

## 🎯 isActive接口

**用户之前询问的关键功能**:

```solidity
// 在SuperPaymasterRegistry_v1_2.sol中
function isPaymasterActive(address paymaster) 
    external view returns (bool) 
{
    return paymasters[paymaster].isActive;
}

// Settlement的postOp中使用
(uint256 feeRate, bool isActive, , , ) = 
    registry.getPaymasterInfo(msg.sender);
require(isActive, "Paymaster not active");
```

## 📞 支持

查看详细文档:
- Registry功能: `registry-app/README.md`
- Minter功能: `minter-app/docs/`
- 合约API: `docs/`

GitHub Issues: https://github.com/AAStarCommunity/SuperPaymaster-Contract/issues
