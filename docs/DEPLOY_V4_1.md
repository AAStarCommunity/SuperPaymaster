# PaymasterV4_1 部署指南

**日期**: 2025-10-15  
**目标**: 部署 PaymasterV4_1 到 Sepolia 测试网

---

## 📋 前提条件

### 1. 准备钱包和资金

- ✅ 部署者钱包地址
- ✅ Sepolia ETH (至少 0.05 ETH 用于部署和 gas)
- ✅ 私钥 (用于签名交易)

### 2. 准备配置信息

- ✅ Owner 地址 (Paymaster 的所有者)
- ✅ Treasury 地址 (接收服务费,建议使用多签钱包)
- ✅ Registry 地址: `0x838da93c815a6E45Aa50429529da9106C0621eF0` (v1.2)

### 3. 工具和 API

- ✅ Foundry 已安装 (`forge --version`)
- ✅ Alchemy/Infura RPC URL
- ✅ Etherscan API Key (用于验证合约)

---

## 🚀 部署步骤

### Step 1: 配置环境变量

```bash
cd /Users/jason/Dev/mycelium/my-exploration/projects/SuperPaymaster/contracts

# 复制配置模板
cp .env.deploy.example .env

# 编辑 .env 文件
nano .env
```

**必需配置**:
```bash
# Network
NETWORK=sepolia
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY

# Deployer
DEPLOYER_PRIVATE_KEY=0x...  # 你的私钥

# EntryPoint (固定值)
ENTRY_POINT=0x0000000071727De22E5E9d8BAf0edAc6f37da032

# Paymaster 所有者和金库
OWNER_ADDRESS=0x...         # 你的地址或 DAO 地址
TREASURY_ADDRESS=0x...      # 建议使用 Gnosis Safe

# 经济参数 (使用默认值或自定义)
GAS_TO_USD_RATE=4500000000000000000000    # $4500/ETH
PNT_PRICE_USD=20000000000000000           # $0.02/PNT
SERVICE_FEE_RATE=200                      # 2%
MAX_GAS_COST_CAP=100000000000000000       # 0.1 ETH
MIN_TOKEN_BALANCE=100000000000000000000   # 100 PNT

# Registry (可选,部署后设置)
REGISTRY_ADDRESS=0x838da93c815a6E45Aa50429529da9106C0621eF0

# Etherscan 验证
ETHERSCAN_API_KEY=YOUR_ETHERSCAN_API_KEY
```

### Step 2: 编译合约

```bash
cd /Users/jason/Dev/mycelium/my-exploration/projects/SuperPaymaster/contracts

# 编译
forge build

# 检查 PaymasterV4_1
forge build --force
```

**期望输出**:
```
[⠊] Compiling...
[⠒] Compiling 1 files with 0.8.26
[⠢] Solc 0.8.26 finished in 3.21s
Compiler run successful!
```

### Step 3: 本地模拟部署 (可选但推荐)

```bash
# 使用 fork 模式测试
forge script script/DeployPaymasterV4_1.s.sol:DeployPaymasterV4_1 \
  --rpc-url $SEPOLIA_RPC_URL \
  -vvvv
```

**检查输出**:
- ✅ 所有参数正确
- ✅ 没有错误
- ✅ Gas 估算合理 (< 5M gas)

### Step 4: 实际部署 (不带验证)

```bash
# 部署到 Sepolia
forge script script/DeployPaymasterV4_1.s.sol:DeployPaymasterV4_1 \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  -vvvv
```

**等待交易确认** (~15-30 秒)

**记录合约地址**:
```
=== Deployment Successful ===
PaymasterV4_1: 0x...  <-- 记录这个地址!
Version: PaymasterV4.1-Registry-v1.1.0
```

### Step 5: Etherscan 验证

```bash
# 使用相同参数验证
forge script script/DeployPaymasterV4_1.s.sol:DeployPaymasterV4_1 \
  --rpc-url $SEPOLIA_RPC_URL \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

或者手动验证:
```bash
forge verify-contract \
  <PAYMASTER_ADDRESS> \
  src/v3/PaymasterV4_1.sol:PaymasterV4_1 \
  --chain sepolia \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --constructor-args $(cast abi-encode "constructor(address,address,address,uint256,uint256,uint256,uint256,uint256)" \
    $ENTRY_POINT \
    $OWNER_ADDRESS \
    $TREASURY_ADDRESS \
    $GAS_TO_USD_RATE \
    $PNT_PRICE_USD \
    $SERVICE_FEE_RATE \
    $MAX_GAS_COST_CAP \
    $MIN_TOKEN_BALANCE)
```

### Step 6: 验证部署

访问 Etherscan:
```
https://sepolia.etherscan.io/address/<PAYMASTER_ADDRESS>
```

**检查**:
- ✅ 合约已验证 (绿色勾)
- ✅ Read Contract 可以调用 `version()` → 返回 `PaymasterV4.1-Registry-v1.1.0`
- ✅ Owner 是正确地址
- ✅ Treasury 是正确地址

---

## ⚙️ 部署后配置

### 1. 设置 Registry

如果部署时没有设置 Registry:

```bash
# 使用 cast 调用
cast send <PAYMASTER_ADDRESS> \
  "setRegistry(address)" \
  0x838da93c815a6E45Aa50429529da9106C0621eF0 \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY
```

### 2. 添加 SBT 和 GasToken

```bash
# 添加 SBT
cast send <PAYMASTER_ADDRESS> \
  "addSBT(address)" \
  <SBT_ADDRESS> \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY

# 添加 GasToken
cast send <PAYMASTER_ADDRESS> \
  "addGasToken(address)" \
  <GAS_TOKEN_ADDRESS> \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY
```

### 3. Deposit 到 EntryPoint

```bash
# Deposit 0.1 ETH
cast send 0x0000000071727De22E5E9d8BAf0edAc6f37da032 \
  "depositTo(address)" \
  <PAYMASTER_ADDRESS> \
  --value 0.1ether \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY
```

### 4. Stake 到 EntryPoint (可选)

```bash
# Stake 0.05 ETH, unstake delay 1 day
cast send 0x0000000071727De22E5E9d8BAf0edAc6f37da032 \
  "addStake(uint32)" \
  86400 \
  --value 0.05ether \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $DEPLOYER_PRIVATE_KEY
```

---

## 📝 更新文档

部署成功后,更新以下文件中的地址:

### 1. Registry 前端环境变量

```bash
cd /Users/jason/Dev/mycelium/my-exploration/projects/registry

# 编辑 .env.local
nano .env.local
```

添加:
```bash
# PaymasterV4_1 测试地址
VITE_PAYMASTER_V4_1_ADDRESS=0x...  # 新部署的地址
```

### 2. 文档更新

更新以下文档:
- `registry/docs/PHASE2_COMPLETION_SUMMARY.md`
- `registry/docs/PHASE2_QUICK_REFERENCE.md`
- `registry/docs/PHASE2_FINAL_REPORT.md`
- `SuperPaymaster/docs/DEPLOY_V4_1.md` (本文件)

替换所有 `0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445` 为新地址,并标注:
```markdown
**PaymasterV4** (旧版,无 Registry 管理):
```
0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445
```

**PaymasterV4_1** (Phase 2, 带 Registry 管理):
```
0x...  <-- 新部署的地址
```
```

### 3. Git 提交

```bash
# 在 SuperPaymaster 仓库
cd /Users/jason/Dev/mycelium/my-exploration/projects/SuperPaymaster
git add contracts/deployments/
git add docs/DEPLOY_V4_1.md
git commit -m "docs: add PaymasterV4_1 deployment guide and record"

# 在 registry 仓库
cd /Users/jason/Dev/mycelium/my-exploration/projects/registry
git add .env.local docs/
git commit -m "docs: update with PaymasterV4_1 deployment address"
```

---

## 🧪 测试部署

### 使用 Operator Portal 测试

1. 启动开发环境:
   ```bash
   cd /Users/jason/Dev/mycelium/my-exploration/projects/registry
   ./scripts/dev.sh
   ```

2. 访问 Manage 页面:
   ```
   http://localhost:5173/operator/deploy
   ```

3. 选择 "Manage Existing Paymaster"

4. 输入新部署的 PaymasterV4_1 地址

5. 测试功能:
   - ✅ 查看状态
   - ✅ Set Registry (如果还没设置)
   - ✅ 测试 Deactivate 按钮 (不要真的点!)

### 使用 cast 测试

```bash
# 查询 version
cast call <PAYMASTER_ADDRESS> "version()(string)" \
  --rpc-url $SEPOLIA_RPC_URL

# 期望输出: PaymasterV4.1-Registry-v1.1.0

# 查询 owner
cast call <PAYMASTER_ADDRESS> "owner()(address)" \
  --rpc-url $SEPOLIA_RPC_URL

# 查询 registry
cast call <PAYMASTER_ADDRESS> "registry()(address)" \
  --rpc-url $SEPOLIA_RPC_URL

# 查询 isRegistrySet
cast call <PAYMASTER_ADDRESS> "isRegistrySet()(bool)" \
  --rpc-url $SEPOLIA_RPC_URL

# 查询 isActiveInRegistry
cast call <PAYMASTER_ADDRESS> "isActiveInRegistry()(bool)" \
  --rpc-url $SEPOLIA_RPC_URL
```

---

## 🐛 故障排查

### 部署失败: "insufficient funds"

**原因**: 部署者账户 ETH 不足

**解决**:
```bash
# 检查余额
cast balance $OWNER_ADDRESS --rpc-url $SEPOLIA_RPC_URL

# 从 Sepolia Faucet 获取测试 ETH
open https://sepoliafaucet.com/
```

### 验证失败: "already verified"

**原因**: 合约已经验证过

**解决**: 无需处理,这是正常的

### 调用失败: "Ownable: caller is not the owner"

**原因**: 当前账户不是 Paymaster owner

**解决**: 使用 owner 账户的私钥,或请求 owner 执行操作

### Registry 未设置

**症状**: `isRegistrySet()` 返回 `false`

**解决**:
```bash
cast send <PAYMASTER_ADDRESS> \
  "setRegistry(address)" \
  0x838da93c815a6E45Aa50429529da9106C0621eF0 \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $OWNER_PRIVATE_KEY
```

---

## 📊 部署清单

完成部署后,确认以下事项:

- [ ] PaymasterV4_1 部署成功
- [ ] 合约在 Etherscan 上验证
- [ ] `version()` 返回 `PaymasterV4.1-Registry-v1.1.0`
- [ ] Owner 设置正确
- [ ] Treasury 设置正确
- [ ] Registry 已设置 (或计划稍后设置)
- [ ] SBT 已添加 (或计划稍后添加)
- [ ] GasToken 已添加 (或计划稍后添加)
- [ ] EntryPoint Deposit >= 0.1 ETH
- [ ] EntryPoint Stake >= 0.05 ETH (可选)
- [ ] 所有文档已更新新地址
- [ ] Git 提交部署记录
- [ ] Operator Portal 测试通过

---

## 📞 支持

**遇到问题?**

1. 检查 Foundry 版本: `forge --version`
2. 检查网络连接: `curl $SEPOLIA_RPC_URL`
3. 检查 .env 配置
4. 查看部署日志 `-vvvv` 输出
5. 检查 Sepolia Etherscan 交易状态

**有用的命令**:
```bash
# 查看最近的 broadcast
ls -lt broadcast/DeployPaymasterV4_1.s.sol/11155111/

# 查看部署 JSON
cat broadcast/DeployPaymasterV4_1.s.sol/11155111/run-latest.json | jq .

# 清理并重新编译
forge clean && forge build
```

---

**准备好部署了吗?** 🚀

请确保:
1. ✅ `.env` 配置完整
2. ✅ 钱包有足够 ETH (>= 0.05 ETH)
3. ✅ 已备份私钥
4. ✅ 已理解部署流程

然后执行:
```bash
forge script script/DeployPaymasterV4_1.s.sol:DeployPaymasterV4_1 \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

祝部署顺利! 🎉
