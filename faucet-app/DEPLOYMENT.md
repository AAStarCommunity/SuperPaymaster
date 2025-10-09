# Faucet 部署指南

## 快速部署到 Vercel

### 1. 准备工作

确保你有：
- Vercel 账号
- Owner 地址的私钥（需要有 ETH 支付 gas）
- Alchemy 或其他 Sepolia RPC URL

### 2. 部署步骤

```bash
# 进入项目目录
cd /Users/jason/Dev/mycelium/my-exploration/projects/SuperPaymaster/faucet-app

# 安装 Vercel CLI（如果还没有）
npm i -g vercel

# 登录 Vercel
vercel login

# 部署到生产环境
vercel --prod
```

### 3. 配置环境变量

部署后，在 Vercel Dashboard 中添加环境变量：

1. 访问: https://vercel.com/dashboard
2. 选择你的项目
3. Settings → Environment Variables
4. 添加以下变量:

```
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N
SEPOLIA_PRIVATE_KEY=0xYOUR_PRIVATE_KEY_HERE
SBT_CONTRACT_ADDRESS=0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f
PNT_TOKEN_ADDRESS=0xD14E87d8D8B69016Fcc08728c33799bD3F66F180
```

或使用 CLI:

```bash
vercel env add SEPOLIA_RPC_URL production
vercel env add SEPOLIA_PRIVATE_KEY production
vercel env add SBT_CONTRACT_ADDRESS production
vercel env add PNT_TOKEN_ADDRESS production
```

### 4. 重新部署

添加环境变量后，重新部署：

```bash
vercel --prod
```

## 验证部署

部署成功后，访问你的 Vercel URL（例如：`https://gastoken-faucet.vercel.app`）

测试 API:

```bash
# 替换为你的 Vercel URL
FAUCET_URL="https://your-app.vercel.app"

# 测试 mint SBT
curl -X POST $FAUCET_URL/api/mint \
  -H "Content-Type: application/json" \
  -d '{"address": "0x94FC9B8B7cAb56C01f20A24E37C2433FCe88A10D", "type": "sbt"}'

# 测试 mint PNT
curl -X POST $FAUCET_URL/api/mint \
  -H "Content-Type: application/json" \
  -d '{"address": "0x94FC9B8B7cAb56C01f20A24E37C2433FCe88A10D", "type": "pnt"}'
```

## 监控

### 检查 Owner 账户余额

```bash
cast balance 0x411BD567E46C0781248dbB6a9211891C032885e5 --rpc-url https://eth-sepolia.g.alchemy.com/v2/Bx4QRW1-vnwJUePSAAD7N
```

### 查看 Vercel 日志

```bash
vercel logs --follow
```

或在 Dashboard: https://vercel.com/dashboard → 选择项目 → Logs

## 更新部署

修改代码后重新部署：

```bash
# 提交代码
git add -A
git commit -m "Update faucet app"

# 部署
vercel --prod
```

## 故障排查

### API 返回 500 错误

检查 Vercel 日志:
```bash
vercel logs --follow
```

常见原因:
- 环境变量配置错误
- Owner 私钥格式错误
- Owner 账户 ETH 不足
- RPC URL 无效

### Owner ETH 不足

向 owner 地址充值:
```bash
# Owner 地址: 0x411BD567E46C0781248dbB6a9211891C032885e5
# 需要至少 0.1 ETH 用于 gas
```

### Rate Limit 问题

rate limit 使用内存缓存，serverless function 重启后会重置。如需持久化，可以使用 Redis 或数据库。

## 安全建议

1. **定期检查 Owner 余额**: 设置监控，ETH 低于 0.05 时告警
2. **限制 mint 数量**: 当前每次 mint 100 PNT，可根据需要调整
3. **监控使用情况**: 查看 Vercel Analytics 了解使用量
4. **备份私钥**: 确保私钥安全存储
5. **使用专用账户**: Owner 账户仅用于 faucet，不存放大量资金

## 成本估算

- **Vercel**: 免费计划足够（每月 100GB 带宽，100,000 次请求）
- **Gas 费用**: 
  - SBT mint: ~50,000 gas (~$0.0001 on Sepolia)
  - PNT mint: ~45,000 gas (~$0.00009 on Sepolia)
  - 每天 1000 次请求 ≈ 0.1 ETH/月

## 下一步

1. ✅ 部署成功后，测试所有功能
2. ✅ 在 README 中添加 faucet URL
3. ✅ 更新 QUICK_START.md，添加 faucet 链接
4. ✅ 在 Discord/Twitter 分享 faucet 链接
