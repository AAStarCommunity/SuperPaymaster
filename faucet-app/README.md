# GasToken Faucet

一个简单的单页面应用，允许任何人免费领取 SBT 和 PNT tokens 用于测试 SuperPaymaster。

## 功能

- 🎁 **无需认证**: 不需要连接钱包
- 💧 **免费领取**: 
  - 每个地址可领取 1 个 SBT
  - 每次可领取 100 PNT
- 🔒 **限流保护**: 每个地址每小时最多 2 次请求
- ⛽ **Gas 由我们支付**: 使用 backend 私钥支付所有 gas 费用

## 部署的合约

- **SBT**: `0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f` (MySBT)
- **PNT**: `0xD14E87d8D8B69016Fcc08728c33799bD3F66F180` (PNTv2 - GasTokenV2)
- **Network**: Sepolia Testnet

## 本地开发

### 1. 安装依赖

```bash
cd faucet-app
npm install
```

### 2. 配置环境变量

复制 `.env.example` 到 `.env` 并填入：

```bash
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_API_KEY
SEPOLIA_PRIVATE_KEY=0x...  # Owner 私钥（必须有 ETH 用于 gas）
SBT_CONTRACT_ADDRESS=0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f
PNT_TOKEN_ADDRESS=0xD14E87d8D8B69016Fcc08728c33799bD3F66F180
```

### 3. 本地运行

```bash
npm run dev
```

访问: http://localhost:3000

### 4. 测试 API

```bash
# 测试 mint SBT
curl -X POST http://localhost:3000/api/mint \
  -H "Content-Type: application/json" \
  -d '{"address": "0xYourAddress", "type": "sbt"}'

# 测试 mint PNT
curl -X POST http://localhost:3000/api/mint \
  -H "Content-Type: application/json" \
  -d '{"address": "0xYourAddress", "type": "pnt"}'
```

## 部署到 Vercel

### 1. 安装 Vercel CLI

```bash
npm i -g vercel
```

### 2. 登录 Vercel

```bash
vercel login
```

### 3. 配置环境变量

在 Vercel 项目设置中添加：

- `SEPOLIA_RPC_URL`
- `SEPOLIA_PRIVATE_KEY`
- `SBT_CONTRACT_ADDRESS`
- `PNT_TOKEN_ADDRESS`

或使用 Vercel CLI：

```bash
vercel env add SEPOLIA_RPC_URL
vercel env add SEPOLIA_PRIVATE_KEY
```

### 4. 部署

```bash
# 部署到生产环境
npm run deploy

# 或使用 vercel CLI
vercel --prod
```

## API 文档

### POST /api/mint

领取 tokens

**Request Body:**
```json
{
  "address": "0x...",
  "type": "sbt" | "pnt"
}
```

**Success Response (200):**
```json
{
  "success": true,
  "txHash": "0x...",
  "blockNumber": 12345,
  "amount": "1 SBT" | "100 PNT",
  "recipient": "0x...",
  "type": "sbt" | "pnt",
  "network": "Sepolia"
}
```

**Error Response:**
```json
{
  "success": false,
  "error": "Error message"
}
```

### 错误码

- `400`: 参数错误或地址已领取
- `429`: 超过请求限制
- `500`: 服务器错误

## 限制

- 每个地址只能领取 1 个 SBT
- 每个地址每小时最多 2 次请求（SBT 和 PNT 分别计数）
- Owner 私钥必须有足够的 ETH 用于支付 gas

## 安全注意事项

⚠️ **重要**: 
- 不要在公共代码中暴露私钥
- 使用 Vercel 环境变量管理敏感信息
- Owner 账户应该只用于 faucet，不要存放大量资金
- 定期检查 owner 账户的 ETH 余额

## 架构

```
faucet-app/
├── public/
│   └── index.html      # 单页面前端
├── api/
│   └── mint.js         # Vercel Serverless Function
├── package.json
├── vercel.json         # Vercel 配置
└── .env                # 环境变量（不提交到 git）
```

## 技术栈

- **前端**: 纯 HTML/CSS/JavaScript
- **后端**: Vercel Serverless Functions
- **智能合约**: Solidity + ethers.js
- **部署**: Vercel

## 相关链接

- [SuperPaymaster](https://github.com/AAStarCommunity/SuperPaymaster)
- [PaymasterV4 文档](../docs/STANDARD_4337_TRANSACTION_CONFIG.md)
- [Sepolia Etherscan](https://sepolia.etherscan.io/)

## License

MIT
