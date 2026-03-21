# SuperPaymaster 快速部署指南

## 🚀 Forge 部署（推荐）

### 1. 配置环境变量
在项目根目录创建 `.env` 文件：

```env
SEPOLIA_PRIVATE_KEY=你的私钥
SEPOLIA_RPC_URL=https://sepolia.infura.io/v3/YOUR_INFURA_KEY
```

### 2. 执行部署脚本
运行 Forge 部署脚本：

```bash
forge script script/DeploySuperpaymaster.s.sol:DeploySuperpaymaster --rpc-url $SEPOLIA_RPC_URL --private-key $SEPOLIA_PRIVATE_KEY --broadcast --verify
```

### 3. 更新前端配置
部署完成后，将输出的合约地址添加到前端项目的 `.env.local` 文件中：

```env
NEXT_PUBLIC_SUPER_PAYMASTER_V6="SuperPaymasterV6合约地址"
NEXT_PUBLIC_SUPER_PAYMASTER_V7="SuperPaymasterV7合约地址"  
NEXT_PUBLIC_SUPER_PAYMASTER_V8="SuperPaymasterV8合约地址"
```

## ✅ 验证部署

访问前端应用，检查：
1. SuperPaymaster 部署状态不再显示警告
2. 可以看到合约版本信息
3. 统计数据正常显示

## 🔄 下一步

现在 paymaster 运营者可以：
1. 访问 `/admin` 输入他们的 paymaster 地址
2. 访问 `/deploy` 部署个人 paymaster  
3. 访问 `/register` 注册到 SuperPaymaster 路由系统

## 🛠 可选：本地开发部署

如果需要在本地测试网部署，可以使用 Anvil：

```bash
# 启动本地测试网
anvil

# 在新终端部署到本地网络
forge script script/DeploySuperpaymaster.s.sol:DeploySuperpaymaster --rpc-url http://127.0.0.1:8545 --private-key $PRIVATE_KEY --broadcast
```

## 🆘 问题排除

- **编译错误**: 确保使用 Solidity 0.8.28 且运行了 `forge build`
- **部署失败**: 检查私钥和 RPC URL 配置
- **前端显示问题**: 确认 .env.local 配置正确并重启应用

## 📞 获取帮助

如有问题，请检查：
1. [DEPLOYMENT.md](./DEPLOYMENT.md) - 完整部署文档
2. [README.md](./README.md) - 项目说明