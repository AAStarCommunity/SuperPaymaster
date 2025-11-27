# Gasless Test Scripts

SuperPaymaster V2 gasless交易测试工具集

## 📁 脚本列表

### 核心测试
- `test-gasless-viem.js` - ⭐️ 主测试脚本，执行完整gasless交易

### 检查工具
- `check-all-keys.js` - 验证所有私钥对应的地址
- `check-entrypoint-deposit.js` - 检查SuperPaymaster在EntryPoint的存款
- `check-operator-apnts.js` - 检查operator的aPNTs余额
- `check-xpnts-allowance.js` - 检查AA账户的xPNTs余额和授权
- `check-apnts-token.js` - 检查aPNTs token配置
- `check-tx-status.js` - 查看交易状态（使用公共RPC）

### 配置工具
- `register-operator.js` - 注册operator到SuperPaymaster
- `mint-apnts-for-operator.js` - 给operator mint aPNTs token
- `deposit-apnts-for-operator.js` - operator存入aPNTs到SuperPaymaster
- `mint-sbt-for-aa.js` - 给AA账户mint MySBT

## 🚀 快速开始

### 1. 环境检查
```bash
node check-all-keys.js
node check-entrypoint-deposit.js
node check-apnts-token.js
```

### 2. Operator配置
```bash
# 检查余额
node check-operator-apnts.js

# 如果不足，充值
node mint-apnts-for-operator.js
node deposit-apnts-for-operator.js
```

### 3. AA账户配置
```bash
# 检查余额和授权
node check-xpnts-allowance.js

# 如果需要MySBT
node mint-sbt-for-aa.js
```

### 4. 执行测试
```bash
node test-gasless-viem.js
```

## 📋 环境要求

### .env文件配置
在项目根目录的 `env/.env`:
```bash
SEPOLIA_RPC_URL=<your_rpc>
DEPLOYER_PRIVATE_KEY=<0x...>
OWNER2_PRIVATE_KEY=<0x...>  # AA账户owner
```

在 `registry/.env`:
```bash
pk3=<operator_private_key>  # 不带0x前缀
```

## 📖 详细文档

完整测试指南: [docs/GASLESS_TEST_GUIDE.md](../../docs/GASLESS_TEST_GUIDE.md)

## ✅ 成功示例

交易链接: https://sepolia.etherscan.io/tx/0xa86887ccef1905f9ab323c923d75f3f996e04b2d8187f70a1f0bb7bb6435af09

```
✅ GASLESS TRANSFER SUCCESSFUL!
📊 Final Balances:
  Sender: 137.35 AAA (支付162.65 xPNTs)
  Recipient: 1 AAA
💰 Gas paid by: 0xe24b6f321b0140716a2b671ed0d983bb64e7dafa
   Gas used: 312008
```
