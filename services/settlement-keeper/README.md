# SuperPaymaster V3 Settlement Keeper

链下结算服务,自动处理Gas费用的PNT扣款。

## 功能

1. **事件监听**: 每小时查询FeeRecorded事件
2. **价格获取**: 从CoinGecko获取历史ETH/USD价格(带缓存)
3. **费用计算**: 根据gasGwei和ETH价格计算应扣PNT数量
4. **自动结算**: 执行transferFrom扣款并标记为Settled

## 架构

```
┌─────────────────────────────────────────────┐
│  Settlement合约 (链上)                      │
│  - 记录: gasGwei + timestamp                │
│  - 事件: FeeRecorded                        │
└──────────────┬──────────────────────────────┘
               │ 监听事件
               ▼
┌─────────────────────────────────────────────┐
│  Keeper服务 (链下)                          │
│  1. 查询FeeRecorded事件                     │
│  2. 获取历史ETH价格 (CoinGecko)             │
│  3. 计算PNT数量                             │
│  4. 执行transferFrom                        │
│  5. 调用settleFees()                        │
└─────────────────────────────────────────────┘
```

## 安装

```bash
cd keeper
npm install
```

## 配置

复制`.env.example`为`.env`并填写:

```bash
cp .env.example .env
nano .env
```

必填项:
- `OPTIMISM_RPC_URL`: Optimism RPC URL
- `SETTLEMENT_ADDRESS`: Settlement合约地址
- `TREASURY_ADDRESS`: 财库地址
- `KEEPER_PRIVATE_KEY`: Keeper钱包私钥

## 运行

### 手动运行(测试)

```bash
npm start
```

### 定时运行(Cron)

每小时运行一次:

```bash
# 编辑crontab
crontab -e

# 添加以下行 (每小时第0分钟执行)
0 * * * * cd /path/to/keeper && /usr/bin/node settlement-keeper.js >> keeper.log 2>&1
```

### 使用PM2 (推荐生产环境)

```bash
# 安装PM2
npm install -g pm2

# 启动Keeper (每小时执行一次)
pm2 start settlement-keeper.js --cron "0 * * * *" --name superpaymaster-keeper

# 查看日志
pm2 logs superpaymaster-keeper

# 查看状态
pm2 status

# 设置开机自启
pm2 startup
pm2 save
```

## 工作流程

### 1. 监听事件

Keeper每小时查询Settlement合约的FeeRecorded事件:

```javascript
const events = await settlement.queryFilter(
  settlement.filters.FeeRecorded(),
  fromBlock,
  toBlock
);
```

### 2. 获取价格

从CoinGecko API获取记录时的ETH/USD价格:

```javascript
const ethPrice = await priceOracle.getHistoricalETHPrice(timestamp);
// 例: $2500
```

价格会永久缓存到`price-cache.json`,避免重复请求。

### 3. 计算PNT

```javascript
// 1. 转换Gwei为ETH
gasETH = gasGwei * 1e9 / 1e18

// 2. 计算USD成本
gasCostUSD = gasETH * ethPrice

// 3. 转换为PNT
pntAmount = gasCostUSD / 0.02  // PNT价格固定$0.02

// 4. 添加手续费
pntAmount = pntAmount * (10000 + feeRate) / 10000
```

### 4. 执行转账

```javascript
// 从用户转账PNT到财库
await gasToken.transferFrom(user, treasury, pntAmount);
```

### 5. 标记已结算

```javascript
await settlement.settleFees([recordKey], settlementHash);
```

## 价格缓存

### 缓存结构

```json
{
  "2025-10-06": {
    "ethPrice": 2500,
    "timestamp": 1728226200000,
    "source": "coingecko"
  },
  "2025-10-07": {
    "ethPrice": 2520,
    "timestamp": 1728312600000,
    "source": "coingecko"
  }
}
```

### 缓存策略

- **永久缓存**: 历史日期的价格不会改变
- **当天更新**: 当天价格每次查询都会更新
- **Fallback**: API失败时使用$2500作为备用价格

## 错误处理

### 余额不足

```
⚠️  Insufficient balance! Skipping...
```

用户PNT余额不足,跳过该记录。

### 授权不足

```
⚠️  Insufficient allowance! Skipping...
```

用户未授权或授权额度不足,跳过该记录。

### 转账失败

```
❌ Failed to process record: ...
```

转账交易失败,记录错误并继续处理下一条。

## 监控

### 日志

Keeper输出详细日志:

```
================================================================================
SuperPaymaster V3 Settlement Keeper
Time: 2025-10-06T14:00:00.000Z
================================================================================

Querying events from block 125000 to 125500...
Found 5 FeeRecorded events

--- Processing Record 0x1234... ---
User: 0x411BD567E46C0781248dbB6a9211891C032885e5
Token: 0x3e7B771d4541eC85c8137e950598Ac97553a337a
Amount: 38000 Gwei
Calculated PNT: 4.82125 PNT
User balance: 100.0 PNT
Allowance: 500.0 PNT
Transferring 4.82125 PNT from user to treasury...
Transfer TX: 0xabc...
✅ Transfer confirmed

================================================================================
Settling 5 records...
Settlement TX: 0xdef...
✅ Settlement confirmed!
Settlement Hash: 0x...
================================================================================
```

### 告警

建议设置告警监控:

- **连续失败**: 3次运行全部失败
- **价格异常**: ETH价格突变>50%
- **余额低**: Keeper钱包gas不足

## 成本分析

### API调用成本

CoinGecko免费额度: 50次/分钟

- 每小时最多处理100条记录
- 假设每天有50条新记录
- 每条记录1次API调用(有缓存)
- **月度API调用**: 50 * 30 = 1500次
- **成本**: 免费 ✅

### Gas成本

每次结算消耗:
- transferFrom: ~50,000 gas/笔
- settleFees: ~30,000 gas/批次

Optimism gas成本:
- Gas Price: 0.001 Gwei
- 100笔记录: (50k * 100 + 30k) * 0.001 Gwei = 0.0000053 ETH
- **月度Gas**: 0.0000053 * 30 = 0.000159 ETH ≈ $0.40
- **成本**: 极低 ✅

## 安全建议

### 1. 私钥管理

- ✅ 使用专用Keeper钱包
- ✅ 只存储少量gas费用
- ✅ 定期轮换私钥
- ❌ 不要使用主钱包

### 2. 权限控制

Keeper钱包不需要任何特殊权限:
- 不是Settlement Owner
- 只需要gas执行transferFrom
- 可以被任何人调用

### 3. 多方计算(未来)

计划升级为去中心化Keeper:
1. 多个Keeper独立计算
2. 链上验证计算结果
3. 达成共识后执行结算
4. 防止单点作恶

## 故障排查

### Keeper无法启动

检查环境变量:
```bash
node -e "console.log(process.env.SETTLEMENT_ADDRESS)"
```

### API请求失败

检查网络和API:
```bash
curl https://api.coingecko.com/api/v3/ping
```

### 交易失败

检查Keeper余额:
```bash
cast balance $KEEPER_ADDRESS --rpc-url $OPTIMISM_RPC_URL
```

## 开发

### 测试

```bash
npm test
```

### 调试模式

添加debug日志:
```bash
DEBUG=* npm start
```

## 许可证

MIT
