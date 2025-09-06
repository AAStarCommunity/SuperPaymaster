# SuperPaymaster 部署和管理指南

## 概述

SuperPaymaster 是一个去中心化的 gas 支付路由系统，由系统管理员一次性部署，然后供所有应用和 paymaster 运营者使用。

## 架构说明

### 部署架构
```
管理员 (Owner) 
    ↓ 
部署 SuperPaymaster 合约 (一次性)
    ↓
Paymaster 运营者注册自己的 paymaster
    ↓
应用和用户使用已部署的 SuperPaymaster
```

### 权限说明
- **SuperPaymaster Owner**: 部署 SuperPaymaster 的账户，拥有合约的完整控制权
- **Paymaster Owner**: 部署个人 paymaster 的账户，只能管理自己的 paymaster
- **应用开发者**: 使用已部署的 SuperPaymaster 进行 gas 路由，无需部署权限

## 管理员部署流程

### 1. 环境准备

```bash
# 安装 Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# 克隆项目
git clone [project-url]
cd SuperPaymaster-Contract

# 设置环境变量
export SEPOLIA_PRIVATE_KEY="your_private_key_here"
export SEPOLIA_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/your_api_key"
export ETHERSCAN_API_KEY="your_etherscan_api_key" # 可选，用于合约验证
```

### 2. 执行部署

```bash
# 运行部署脚本
./deploy-superpaymaster.sh
```

### 3. 更新配置文件

部署成功后，更新前端应用的 `.env.local` 文件：

```env
NEXT_PUBLIC_SUPER_PAYMASTER_V6="0x..."
NEXT_PUBLIC_SUPER_PAYMASTER_V7="0x..."  
NEXT_PUBLIC_SUPER_PAYMASTER_V8="0x..."
```

## Paymaster 运营者使用流程

### 1. 访问管理面板

```
https://your-app.com/admin
```

### 2. 检查 SuperPaymaster 状态

- 如果显示"SuperPaymaster Not Deployed"警告，联系管理员
- 如果正常，进入个人 paymaster 管理流程

### 3. 部署个人 Paymaster

```
https://your-app.com/deploy
```

选择对应的 EntryPoint 版本并部署 Pimlico singleton paymaster

### 4. 注册到 SuperPaymaster

```  
https://your-app.com/register
```

将部署的 paymaster 注册到 SuperPaymaster 路由系统

### 5. 管理 Paymaster

```
https://your-app.com/manage?address=0x...
```

管理资金、费率、查看收益等

## 应用开发者集成

### 1. 使用已部署的 SuperPaymaster

```typescript
import { SUPER_PAYMASTER_ABI } from '@/lib/contracts';

// 读取最佳 paymaster
const { data: bestPaymaster } = useReadContract({
  address: process.env.NEXT_PUBLIC_SUPER_PAYMASTER_V7,
  abi: SUPER_PAYMASTER_ABI,
  functionName: 'getBestPaymaster',
});
```

### 2. 提交 UserOperation

```typescript
// UserOperation 会自动路由到最优 paymaster
const userOp = {
  // ... user operation fields
  paymasterAndData: superPaymasterAddress + "0x", // 使用 SuperPaymaster
};
```

## 运维监控

### 合约状态检查

```bash
# 检查 SuperPaymaster 状态
cast call $SUPER_PAYMASTER_ADDRESS "getRouterStats()" --rpc-url $SEPOLIA_RPC_URL

# 检查注册的 paymaster 数量  
cast call $SUPER_PAYMASTER_ADDRESS "getPaymasterCount()" --rpc-url $SEPOLIA_RPC_URL

# 查看最佳 paymaster
cast call $SUPER_PAYMASTER_ADDRESS "getBestPaymaster()" --rpc-url $SEPOLIA_RPC_URL
```

### 资金管理

```bash
# 查看 SuperPaymaster 在 EntryPoint 的余额
cast call $ENTRY_POINT_ADDRESS "balanceOf(address)" $SUPER_PAYMASTER_ADDRESS --rpc-url $SEPOLIA_RPC_URL

# Owner 充值到 SuperPaymaster (如果需要)
cast send $SUPER_PAYMASTER_ADDRESS "deposit()" --value 0.1ether --private-key $OWNER_PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL
```

## 故障排除

### 常见问题

1. **"SuperPaymaster Not Deployed" 警告**
   - 检查 `.env.local` 中的合约地址是否正确
   - 确认合约在对应网络上已部署

2. **"Missing contract addresses" 错误**
   - 确认环境变量设置正确
   - 检查合约地址格式是否为有效的以太坊地址

3. **Gas 费用过高**
   - 检查 Sepolia 网络拥堵情况
   - 调整 gas price 设置

### 日志查看

```bash
# 查看部署日志
tail -f deployment.log

# 查看应用日志  
pnpm run dev
```

## 安全注意事项

1. **私钥安全**
   - 永远不要在代码中硬编码私钥
   - 使用环境变量或硬件钱包
   - 定期轮换私钥

2. **合约权限**
   - SuperPaymaster owner 拥有最高权限
   - 个人 paymaster 只能管理自己的合约
   - 定期审计权限设置

3. **资金安全**
   - 定期检查合约余额
   - 设置合理的资金上限
   - 监控异常交易

## 支持和联系

如遇到问题，请联系：
- GitHub Issues: [project-issues-url]
- 技术支持: [support-email]
- 文档: [documentation-url]