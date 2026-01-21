# xPNTsToken Security Monitor

生产级的 xPNTsToken 安全监控脚本，支持 Email 告警。

## 功能特性

✅ **多网络支持**: Optimism Mainnet + Ethereum Mainnet  
✅ **Email 告警**: 支持 Gmail / SendGrid / 自定义 SMTP  
✅ **关键事件监控**:
- SuperPaymaster 地址变更
- 权限撤销事件
- 异常高频债务记录

✅ **可扩展**: 易于添加新的监控规则

## 快速开始

### 1. 安装依赖

```bash
cd scripts
npm install viem nodemailer dotenv
```

### 2. 配置环境变量

```bash
cp .env.example .env
# 编辑 .env，填入你的配置
```

**Gmail配置示例**：
1. 开启 2FA: https://myaccount.google.com/security
2. 生成 App Password: https://myaccount.google.com/apppasswords
3. 将生成的16位密码填入 `SMTP_PASS`

### 3. 运行监控

```bash
node monitor.js
```

**推荐**: 使用 PM2 保持后台运行

```bash
npm install -g pm2
pm2 start monitor.js --name xpnts-monitor
pm2 save
pm2 startup  # 开机自启
```

## 监控事件

| 事件 | 严重级别 | 告警条件 |
|:---|:---|:---|
| `SuperPaymasterAddressUpdated` | 🔴 Critical | 任何调用立即告警 |
| `AutoApprovedSpenderRemoved` | 🟡 Warning | 任何调用立即告警 |
| `DebtRecorded` | 🟡 Warning | 单用户1小时>20次 |

## 扩展到高级监控

### 添加新的监控指标

编辑 `monitor-xpnts.js`，在 `processEvent` 函数中添加：

```javascript
case 'YourNewEvent':
  // 自定义逻辑
  if (yourCondition) {
    await sendEmailAlert('Alert Title', 'Alert Body');
  }
  break;
```

### 添加Telegram告警

```bash
npm install node-telegram-bot-api
```

```javascript
import TelegramBot from 'node-telegram-bot-api';

const bot = new TelegramBot(process.env.TELEGRAM_BOT_TOKEN, {polling: false});

async function sendTelegramAlert(message) {
  await bot.sendMessage(process.env.TELEGRAM_CHAT_ID, message, {
    parse_mode: 'HTML'
  });
}
```

### 添加数据库记录

```javascript
// 在 processEvent 中
await db.insert('alerts', {
  network,
  event: eventName,
  txHash,
  timestamp: new Date(),
  data: JSON.stringify(args),
});
```

## 故障排查

**邮件发送失败**：
- 检查 Gmail App Password 是否正确
- 确认SMTP端口（Gmail: 587, SendGrid: 587）
- 检查防火墙设置

**RPC连接失败**：
- 使用备用RPC（Alchemy/Infura）
- 增加 `POLL_INTERVAL` 降低请求频率

## 生产部署建议

1. **使用专业SMTP服务** (SendGrid/AWS SES) 而非Gmail
2. **设置多个告警接收者**
3. **配合 PM2 监控**：`pm2 logs xpnts-monitor`
4. **定期检查日志**：`pm2 logs --lines 100`

## License

MIT
