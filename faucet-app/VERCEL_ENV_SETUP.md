# Vercel 环境变量设置指南

## 前提条件

1. 已安装 Vercel CLI: `npm i -g vercel`
2. 已登录: `vercel login`
3. 已创建 `.env` 文件并填入实际值

## 设置步骤

### 1. 填写 .env 文件

复制 `.env.example` 到 `.env` 并填入实际值:

```bash
cp .env.example .env
# 然后编辑 .env 文件,填入真实的私钥、RPC URL 等
```

### 2. 使用 Vercel CLI 设置环境变量

在 `faucet-app` 目录下执行以下命令:

```bash
cd /path/to/SuperPaymaster/faucet-app

# 加载 .env 文件并设置各个环境变量到 Vercel 生产环境

# 1. SEPOLIA_RPC_URL (已设置,如需更新)
source .env && echo "$SEPOLIA_RPC_URL" | vercel env add SEPOLIA_RPC_URL production

# 2. SEPOLIA_PRIVATE_KEY
source .env && echo "$SEPOLIA_PRIVATE_KEY" | vercel env add SEPOLIA_PRIVATE_KEY production

# 3. PNT_TOKEN_ADDRESS
source .env && echo "$PNT_TOKEN_ADDRESS" | vercel env add PNT_TOKEN_ADDRESS production

# 4. SBT_CONTRACT_ADDRESS
source .env && echo "$SBT_CONTRACT_ADDRESS" | vercel env add SBT_CONTRACT_ADDRESS production

# 5. USDT_CONTRACT_ADDRESS
source .env && echo "$USDT_CONTRACT_ADDRESS" | vercel env add USDT_CONTRACT_ADDRESS production

# 6. SIMPLE_ACCOUNT_FACTORY_ADDRESS
source .env && echo "$SIMPLE_ACCOUNT_FACTORY_ADDRESS" | vercel env add SIMPLE_ACCOUNT_FACTORY_ADDRESS production

# 7. PAYMASTER_V4_ADDRESS
source .env && echo "$PAYMASTER_V4_ADDRESS" | vercel env add PAYMASTER_V4_ADDRESS production

# 8. ADMIN_KEY
source .env && echo "$ADMIN_KEY" | vercel env add ADMIN_KEY production
```

### 3. 验证环境变量

```bash
vercel env ls
```

### 4. 重新部署

设置完环境变量后,需要重新部署以使其生效:

```bash
vercel --prod
```

## 注意事项

- ⚠️ **绝对不要**将 `.env` 文件提交到 Git
- ⚠️ `.env` 文件已添加到 `.gitignore`
- ⚠️ 确保 `SEPOLIA_PRIVATE_KEY` 对应的账户有足够的 ETH 用于 gas
- 🔐 `ADMIN_KEY` 用于保护 `init-pool` 等敏感操作

## 环境变量说明

| 变量名 | 说明 | 示例值 |
|--------|------|--------|
| SEPOLIA_RPC_URL | Sepolia 测试网 RPC 地址 | https://eth-sepolia.g.alchemy.com/v2/xxx |
| SEPOLIA_PRIVATE_KEY | 部署者私钥(需有 ETH) | 0xabcd... |
| PNT_TOKEN_ADDRESS | PNT Token 合约地址 | 0xD14E...F180 |
| SBT_CONTRACT_ADDRESS | SBT Token 合约地址 | 0xBfde...bD7f |
| USDT_CONTRACT_ADDRESS | Mock USDT 合约地址 | 0x14Ea...bCfDc |
| SIMPLE_ACCOUNT_FACTORY_ADDRESS | SimpleAccountFactory 地址 | 0x9bD6...7881 |
| PAYMASTER_V4_ADDRESS | PaymasterV4 合约地址 | 0xBC56...9D445 |
| ADMIN_KEY | 管理员密钥(自定义字符串) | your-secret-key |

## 快速批量设置(可选)

如果想一次性设置所有变量,可以使用以下循环:

```bash
source .env

for var in SEPOLIA_RPC_URL SEPOLIA_PRIVATE_KEY PNT_TOKEN_ADDRESS SBT_CONTRACT_ADDRESS USDT_CONTRACT_ADDRESS SIMPLE_ACCOUNT_FACTORY_ADDRESS PAYMASTER_V4_ADDRESS ADMIN_KEY; do
  echo "${!var}" | vercel env add "$var" production
done
```

注意: 循环方式会对每个变量弹出确认提示,建议逐个执行以便检查。
