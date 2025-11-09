# PaymasterV4_1i 部署指南

## 📋 前置条件

### 1. 环境准备
```bash
# 确保已安装 Foundry
forge --version

# 确保在 SuperPaymaster 目录
cd /Volumes/UltraDisk/Dev2/aastar/SuperPaymaster
```

### 2. 配置环境变量
```bash
# 复制配置模板
cp .env.sepolia.v4.1i .env

# 编辑 .env 填入：
# - PRIVATE_KEY: 你的部署私钥
# - ETHERSCAN_API_KEY: Etherscan API Key
# - OWNER_ADDRESS: Paymaster owner (可以是 Safe 多签地址)
# - TREASURY_ADDRESS: 收费地址
```

### 3. 确认配置
```bash
# 查看当前配置
source .env
echo "Deployer: $(cast wallet address $PRIVATE_KEY)"
echo "Owner: $OWNER_ADDRESS"
echo "Factory: $PAYMASTER_FACTORY"
echo "Registry: $REGISTRY_ADDRESS"
```

---

## 🚀 步骤 1: 部署 PaymasterV4_1i 实现合约

### 部署命令
```bash
forge script script/DeployPaymasterV4_1i.s.sol:DeployPaymasterV4_1i \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv
```

### 预期输出
```
=== PaymasterV4_1i Implementation Deployment ===
Deployer: 0x411BD567E46C0781248dbB6a9211891C032885e5
Chain ID: 11155111

=== Deployment Successful ===
Implementation: 0x... (NEW ADDRESS - SAVE THIS)
Version: PaymasterV4.1i-v1.0.0

=== Next Steps ===
1. Register implementation in PaymasterFactory:
   factory.addImplementation("v4.1i", 0x...)
```

### ⚠️ 重要：保存实现合约地址
```bash
# 保存到环境变量
export V4_1i_IMPLEMENTATION="0x..."
echo "V4_1i_IMPLEMENTATION=$V4_1i_IMPLEMENTATION" >> .env
```

---

## 🏭 步骤 2: 注册实现到 PaymasterFactory

### 选项 A: 如果你是 Factory Owner

```bash
# 调用 addImplementation
cast send $PAYMASTER_FACTORY \
  "addImplementation(string,address)" \
  "v4.1i" \
  $V4_1i_IMPLEMENTATION \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

### 选项 B: 如果 Factory Owner 是 Safe 多签

1. **创建 Safe 交易提案**：
   ```javascript
   // 在 Safe UI 中创建交易
   To: 0x65Cf6C4ab3d40f3C919b6F3CADC09Efb72817920  // PaymasterFactory
   Value: 0
   Data: addImplementation(string,address)

   // 参数
   version: "v4.1i"
   implementation: 0x...  // 你的实现合约地址
   ```

2. **多签确认和执行**

### 验证注册成功
```bash
# 检查实现地址
cast call $PAYMASTER_FACTORY \
  "implementations(string)(address)" \
  "v4.1i" \
  --rpc-url $SEPOLIA_RPC_URL

# 应返回：0x... (你的实现合约地址)
```

---

## 🧪 步骤 3: 测试工厂部署

### 运行测试脚本
```bash
forge script script/TestPaymasterV4_1i_Factory.s.sol:TestPaymasterV4_1i_Factory \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  -vvvv
```

### 预期输出
```
=== PaymasterV4_1i Factory Deployment Test ===
Factory: 0x65Cf6C4ab3d40f3C919b6F3CADC09Efb72817920
Implementation (v4.1i): 0x...
Deploying paymaster through factory...

=== Deployment Successful ===
Paymaster Address: 0x... (NEW PROXY)
Version: PaymasterV4.1i-v1.0.0
Owner: 0x411BD567E46C0781248dbB6a9211891C032885e5
EntryPoint: 0x0000000071727De22E5E9d8BAf0edAc6f37da032
Treasury: 0x411BD567E46C0781248dbB6a9211891C032885e5
Service Fee Rate: 500 bps
Registry Set: true
Paused: false

=== All Verifications Passed ===
```

### 保存代理地址
```bash
export PAYMASTER_PROXY="0x..."
echo "PAYMASTER_PROXY=$PAYMASTER_PROXY" >> .env
```

---

## ✅ 步骤 4: 配置和测试 Paymaster

### 4.1 充值 ETH
```bash
# Paymaster 需要 ETH 来支付 gas
cast send $PAYMASTER_PROXY \
  --value 0.1ether \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

### 4.2 Deposit 到 EntryPoint
```bash
# EntryPoint v0.7 需要 deposit
cast send $PAYMASTER_PROXY \
  "depositToEntryPoint()()" \
  --value 0.05ether \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

### 4.3 检查 Paymaster 状态
```bash
# 检查 EntryPoint deposit
cast call $PAYMASTER_PROXY \
  "getDeposit()(uint256)" \
  --rpc-url $SEPOLIA_RPC_URL

# 检查 owner
cast call $PAYMASTER_PROXY \
  "owner()(address)" \
  --rpc-url $SEPOLIA_RPC_URL

# 检查 paused
cast call $PAYMASTER_PROXY \
  "paused()(bool)" \
  --rpc-url $SEPOLIA_RPC_URL
```

---

## 🔐 步骤 5: (可选) 转让 Ownership 到 Safe

### 如果需要多签管理

```bash
# 1. 准备 Safe 多签地址
export SAFE_ADDRESS="0x..."

# 2. 转让 Paymaster ownership
cast send $PAYMASTER_PROXY \
  "transferOwnership(address)" \
  $SAFE_ADDRESS \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY

# 3. 验证新 owner
cast call $PAYMASTER_PROXY \
  "owner()(address)" \
  --rpc-url $SEPOLIA_RPC_URL
# 应返回：Safe 地址
```

### 转让 Factory Ownership (如需要)

```bash
# 只有当前 Factory owner 可以执行
cast send $PAYMASTER_FACTORY \
  "transferOwnership(address)" \
  $SAFE_ADDRESS \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

---

## 📊 Gas 消耗对比

| 操作 | Gas 消耗 | 成本 (20 Gwei) |
|------|---------|---------------|
| 部署实现合约 (一次性) | ~3-5M | ~0.06-0.1 ETH |
| 注册到 Factory (一次性) | ~50k | ~0.001 ETH |
| 通过 Factory 创建代理 | ~100k | ~0.002 ETH |
| **直接部署 v4.1 (对比)** | **~3-5M** | **~0.06-0.1 ETH** |

**节省比例：~95%** (每个新实例)

---

## 🔍 验证清单

- [ ] ✅ 实现合约部署成功
- [ ] ✅ 实现合约在 Etherscan 验证
- [ ] ✅ 实现合约注册到 Factory
- [ ] ✅ 通过 Factory 创建代理成功
- [ ] ✅ 代理合约初始化正确
- [ ] ✅ Owner 设置正确
- [ ] ✅ EntryPoint 配置正确
- [ ] ✅ Registry 集成正常
- [ ] ✅ 充值和 deposit 成功
- [ ] ✅ (可选) Ownership 转给 Safe

---

## 🚨 常见问题

### Q1: `ImplementationNotFound("v4.1i")`
**原因**: 实现合约未注册到 Factory
**解决**: 执行步骤 2 注册实现

### Q2: `OperatorAlreadyHasPaymaster`
**原因**: 该地址已通过 Factory 部署过 Paymaster
**解决**: 使用不同地址或使用已部署的实例

### Q3: `Initialization failed`
**原因**: initialize 参数错误或已初始化
**解决**: 检查参数，确保实现合约正确部署

### Q4: 如何升级到新版本？
**答案**:
1. 部署新实现合约 (如 v4.1i-v1.0.1)
2. 注册到 Factory: `addImplementation("v4.1i-v1.0.1", newAddress)`
3. 新用户自动使用新版本
4. 旧代理继续运行旧版本（EIP-1167 不可升级）

---

## 📚 相关文档

- [v4.1i 架构设计](./v4.1i-architecture.md)
- [v4.1i 部署计划](./v4.1i-deployment-plan.md)
- [EIP-1167 规范](https://eips.ethereum.org/EIPS/eip-1167)
- [Foundry 部署指南](https://book.getfoundry.sh/forge/deploying)

---

## 📝 部署记录模板

### 部署信息
```
日期: 2025-11-02
网络: Sepolia (Chain ID: 11155111)
部署者: 0x411BD567E46C0781248dbB6a9211891C032885e5

实现合约: 0x...
Factory: 0x65Cf6C4ab3d40f3C919b6F3CADC09Efb72817920
测试代理: 0x...

版本: PaymasterV4.1i-v1.0.0
Gas 使用:
  - 实现部署: ... gas
  - 注册: ... gas
  - 代理创建: ... gas
```

---

## 🎯 下一步

完成部署后：
1. 更新 shared-config 包含新实现地址
2. 更新 registry 前端使用 Factory 部署
3. 编写前端集成文档
4. 进行完整端到端测试
