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
✅ 64/64 tests passed

- GasTokenTest: 9/9
- SettlementTest: 17/17
- PaymasterV3Test: 34/34
- CounterTest: 2/2
- TestEip7702: 2/2
```

## 🔧 核心合约

### Registry生态
- `SuperPaymasterRegistry_v1_2.sol` - Multi-tenancy Registry
- `Settlement.sol` - Gas费用结算
- `PaymasterV3_1.sol` - Ethereum优化版
- `PaymasterV3_2.sol` - OP优化版

### Minter生态
- `GasToken.sol` - ERC20 gas token
- `GasTokenFactory.sol` - Token工厂
- `MySBT.sol` - Soul-Bound Token
- `SimpleAccount.sol` - AA账户
- `PNTs.sol` - Points Token

## 📝 重要文件

### 文档
- `MINTER_INTEGRATION_COMPLETE.md` - 完整集成说明
- `CONTRACTS_INTEGRATION_SUMMARY.md` - 合约集成总结
- `Directory-Reorganization-Summary.md` - 目录重组说明

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
