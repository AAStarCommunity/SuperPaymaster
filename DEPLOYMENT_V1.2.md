# SuperPaymaster Registry v1.2 部署和前端更新指南

## 🚀 快速部署流程

### 1. 部署智能合约到 Sepolia

```bash
# 进入合约目录
cd /Users/jason/Dev/mycelium/my-exploration/projects/SuperPaymaster-Contract

# 确保已安装依赖
forge install

# 创建 .env 文件
cp .env.example .env

# 编辑 .env,填入以下信息:
# SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
# PRIVATE_KEY=your_private_key_here
# ETHERSCAN_API_KEY=your_etherscan_key
# OWNER_ADDRESS=your_wallet_address
# TREASURY_ADDRESS=your_treasury_address (可以和 OWNER 相同)
# MIN_STAKE_AMOUNT=10000000000000000  # 0.01 ETH for Sepolia
# ROUTER_FEE_RATE=50  # 0.5% (50 basis points)
# SLASH_PERCENTAGE=500  # 5% (500 basis points)

# 部署合约
forge script script/DeployRegistry_v1_2.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY

# 记录输出的合约地址,例如:
# SuperPaymasterRegistry v1.2 deployed at: 0x1234567890123456789012345678901234567890
```

### 2. 更新前端配置

#### 2.1 更新合约地址

编辑 `frontend/src/lib/contracts.ts`:

```typescript
export const CONTRACTS = {
  // ... 其他配置 ...
  
  // 将这里的地址替换为你部署的合约地址
  SUPER_PAYMASTER_REGISTRY_V1_2: '0x1234567890123456789012345678901234567890',
  
  // ... 其他配置 ...
};
```

#### 2.2 验证 ABI 已更新

确认 `frontend/src/lib/SuperPaymasterRegistry_v1_2.json` 文件存在且是最新的。

如果需要重新生成:

```bash
cd /Users/jason/Dev/mycelium/my-exploration/projects/SuperPaymaster/SuperPaymaster-Contract

# 编译合约
forge build

# 提取 ABI
jq '.abi' out/SuperPaymasterRegistry_v1_2.sol/SuperPaymasterRegistry.json > \
  ../../../SuperPaymaster-Contract/frontend/src/lib/SuperPaymasterRegistry_v1_2.json
```

### 3. 本地测试前端

```bash
# 进入前端目录
cd /Users/jason/Dev/mycelium/my-exploration/projects/SuperPaymaster-Contract/frontend

# 安装依赖 (如果还没安装)
pnpm install

# 启动开发服务器
pnpm dev

# 访问 http://localhost:3000
```

### 4. 功能测试清单

在浏览器中测试以下功能:

#### 4.1 连接钱包
- [ ] 点击 "Connect Wallet" 按钮
- [ ] 能够成功连接 MetaMask
- [ ] 切换到 Sepolia 网络

#### 4.2 查看统计信息
- [ ] Dashboard 显示正确的统计数据
- [ ] Total Paymasters: 0 (初始状态)
- [ ] Active Paymasters: 0
- [ ] 其他统计数据正常显示

#### 4.3 注册 Paymaster (Register 页面)
- [ ] 导航到 Register 页面
- [ ] 填写表单:
  - Paymaster Address: (你的地址或测试地址)
  - Fee Rate: 150 (1.5%)
  - Name: "Test Paymaster"
- [ ] 点击 "Register Paymaster"
- [ ] MetaMask 弹出交易确认
- [ ] 交易成功后页面显示成功消息

#### 4.4 查看 Paymaster 列表
- [ ] 能看到刚注册的 Paymaster
- [ ] 显示正确的 Name, Fee Rate, Status
- [ ] Success Count 和 Total Attempts 正常显示

#### 4.5 管理功能 (Manage 页面)
- [ ] 能更新 Fee Rate
- [ ] 能查看自己的 Paymaster 信息
- [ ] 所有按钮正常工作

### 5. 部署到 Vercel

#### 5.1 配置环境变量

在 Vercel Dashboard 中设置:
- `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID` (从 https://cloud.walletconnect.com/ 获取)

#### 5.2 通过 Git 部署

```bash
cd /Users/jason/Dev/mycelium/my-exploration/projects/SuperPaymaster-Contract

# 提交更改
git add frontend/src/lib/contracts.ts
git add frontend/src/lib/SuperPaymasterRegistry_v1_2.json
git commit -m "feat: add SuperPaymasterRegistry v1.2 support"
git push origin main
```

#### 5.3 Vercel 配置

在 Vercel Dashboard:
1. 选择项目
2. Settings → General → Root Directory: `frontend`
3. Settings → Environment Variables:
   - Add: `NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID`
4. Deployments → Redeploy

### 6. 验证部署

访问 Vercel URL (例如: `https://your-project.vercel.app`):

- [ ] 页面正常加载
- [ ] 能连接钱包
- [ ] 所有功能正常工作
- [ ] 合约交互正常

## 📋 部署记录模板

完成部署后,记录以下信息:

```markdown
## SuperPaymasterRegistry v1.2 部署记录

**部署时间**: 2025-XX-XX XX:XX

### Sepolia Testnet
- **合约地址**: 0x...
- **Etherscan**: https://sepolia.etherscan.io/address/0x...
- **部署参数**:
  - Owner: 0x...
  - Treasury: 0x...
  - Min Stake: 0.01 ETH
  - Router Fee: 0.5%
  - Slash: 5%

### 前端
- **Vercel URL**: https://your-project.vercel.app
- **部署状态**: ✅ Success
- **功能测试**: ✅ All Passed

### 测试账户
- Paymaster #1: 0x... (Test Paymaster, Fee: 1.5%)
```

## 🔧 常见问题

### Q1: 合约部署失败 - "insufficient funds"

**A**: 确保你的账户有足够的 Sepolia ETH。从 faucet 获取: https://sepoliafaucet.com/

### Q2: 前端无法连接合约

**A**: 检查以下内容:
1. 确认已切换到 Sepolia 网络
2. 验证 `contracts.ts` 中的合约地址正确
3. 检查浏览器控制台错误信息

### Q3: "Contract not deployed" 错误

**A**: 
1. 确认合约已成功部署到 Sepolia
2. 在 Etherscan 上验证合约地址
3. 确认前端配置的地址正确

### Q4: Vercel 构建失败

**A**:
```bash
# 本地测试构建
cd frontend
pnpm build

# 查看错误信息并修复
```

## 📞 需要帮助?

- GitHub Issues: [报告问题](https://github.com/AAStarCommunity/SuperPaymaster/issues)
- Discord: [加入社区](https://discord.gg/aastar)

---

**⚠️ 重要提醒**:
- 这是测试网部署,使用测试 ETH
- 主网部署前务必充分测试
- 保管好私钥,不要提交到 Git
