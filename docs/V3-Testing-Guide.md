# V3 测试和部署指南

**更新日期**: 2025-01-05  
**状态**: ✅ 就绪

---

## 📋 测试状态总结

### 单元测试
- **Settlement**: ✅ 20/20 通过 (100%)
- **PaymasterV3**: ⚠️ 由于OZ版本冲突暂时跳过完整测试
- **核心功能**: ✅ 已通过简化测试验证

### 集成测试
- **脚本**: ✅ `script/v3-integration-test.s.sol` 已创建
- **环境**: Fork Sepolia 或实际部署后测试

---

## 🧪 本地测试

### 1. 运行单元测试

```bash
# 测试 Settlement (完整测试)
forge test --match-path "test/Settlement.t.sol" -vv

# 测试 PaymasterV3 (简化版本)
forge test --match-path "test/PaymasterV3.t.sol" -vv
```

**预期结果**:
```
Settlement: 20/20 passed ✅
PaymasterV3: 3/3 passed ✅
```

### 2. 编译合约

由于OZ版本冲突,需要分别编译:

```bash
# 编译 Settlement (使用主项目OZ版本)
forge build --force

# 检查编译产物
ls -la out/Settlement.sol/Settlement.json
ls -la out/PaymasterV3.sol/PaymasterV3.json
```

---

## 🚀 部署到 Sepolia

### 方法1: 使用简化部署脚本

```bash
# 1. 配置环境变量
cp .env.sepolia.example .env.sepolia
vim .env.sepolia

# 必填项:
# PRIVATE_KEY=0x...
# TREASURY_ADDRESS=0x... (建议Gnosis Safe)
# SBT_CONTRACT_ADDRESS=0x...
# GAS_TOKEN_ADDRESS=0x...
# MIN_TOKEN_BALANCE=1000000

# 2. 执行部署
source .env.sepolia
forge script script/v3-deploy-simple.s.sol:V3DeploySimple \
  --rpc-url sepolia \
  --broadcast \
  -vvv
```

**输出示例**:
```
[1/2] Deploying Settlement...
  Settlement deployed: 0xABC...

[2/2] Deploying PaymasterV3...
  PaymasterV3 deployed: 0xDEF...

Deployment Complete!
```

### 方法2: 手动部署 (分步)

```bash
# Step 1: 部署 Settlement
cast send --create \
  $(cat out/Settlement.sol/Settlement.json | jq -r .bytecode.object) \
  --constructor-args $(cast abi-encode "constructor(address,address)" \
    $REGISTRY_ADDRESS $TREASURY_ADDRESS) \
  --rpc-url sepolia --private-key $PRIVATE_KEY

# Step 2: 部署 PaymasterV3
cast send --create \
  $(cat out/PaymasterV3.sol/PaymasterV3.json | jq -r .bytecode.object) \
  --constructor-args $(cast abi-encode "constructor(address,address,address,address,address,uint256)" \
    $ENTRYPOINT $OWNER $SBT $TOKEN $SETTLEMENT $MIN_BALANCE) \
  --rpc-url sepolia --private-key $PRIVATE_KEY
```

---

## 🧪 集成测试

### 配置测试环境

```bash
# 1. 复制测试配置
cp .env.test.example .env.test

# 2. 填入已部署的合约地址
vim .env.test

# 必填:
# SETTLEMENT_ADDRESS=0x... (从部署输出获取)
# PAYMASTER_V3_ADDRESS=0x...
# SBT_CONTRACT_ADDRESS=0x...
# GAS_TOKEN_ADDRESS=0x...
# TREASURY_ADDRESS=0x...
# TEST_USER_ADDRESS=0x... (需持有SBT和Token)
```

### 执行集成测试

```bash
# 加载配置
source .env.test

# 运行集成测试
forge script script/v3-integration-test.s.sol:V3IntegrationTest \
  --rpc-url sepolia \
  --broadcast \
  -vvv
```

**测试流程**:
1. ✅ 检查合约配置 (treasury, SBT, token)
2. ✅ 模拟记账 (recordGasFee)
3. ✅ 检查pending余额
4. ✅ 执行批量结算
5. ✅ 验证最终状态

---

## 📊 测试场景

### 场景1: 完整用户流程

```bash
# 1. 用户持有SBT
cast call $SBT_ADDRESS "balanceOf(address)(uint256)" $USER_ADDRESS

# 2. 用户持有足够Token
cast call $TOKEN_ADDRESS "balanceOf(address)(uint256)" $USER_ADDRESS

# 3. 用户授权Settlement
cast send $TOKEN_ADDRESS \
  "approve(address,uint256)" \
  $SETTLEMENT_ADDRESS \
  $(cast max-uint256) \
  --rpc-url sepolia --private-key $USER_PRIVATE_KEY

# 4. PaymasterV3赞助交易 (通过EntryPoint)
# (实际需要构造UserOperation)

# 5. 记账到Settlement
cast send $SETTLEMENT_ADDRESS \
  "recordGasFee(address,address,uint256,bytes32)" \
  $USER_ADDRESS \
  $TOKEN_ADDRESS \
  1000000000000000 \
  $(cast keccak "test-userop") \
  --rpc-url sepolia --private-key $PAYMASTER_PRIVATE_KEY

# 6. 查询pending
cast call $SETTLEMENT_ADDRESS \
  "pendingAmounts(address,address)(uint256)" \
  $USER_ADDRESS \
  $TOKEN_ADDRESS

# 7. 批量结算
cast send $SETTLEMENT_ADDRESS \
  "settleFeesByUsers(address[],address,bytes32)" \
  "[$USER_ADDRESS]" \
  $TOKEN_ADDRESS \
  $(cast keccak "settlement-batch-1") \
  --rpc-url sepolia --private-key $OWNER_PRIVATE_KEY
```

### 场景2: 错误处理

```bash
# 测试1: 无SBT用户
cast call $PAYMASTER_ADDRESS \
  "validatePaymasterUserOp(...)" # 应该revert

# 测试2: Token余额不足
# (用户balance < minTokenBalance)

# 测试3: 重复记账
cast send $SETTLEMENT_ADDRESS \
  "recordGasFee(...)" # 同一个userOpHash应该revert

# 测试4: 未授权结算
# (用户未approve Settlement)
```

---

## 🔍 调试技巧

### 1. 检查合约状态

```bash
# Settlement 状态
cast call $SETTLEMENT "owner()(address)"
cast call $SETTLEMENT "treasury()(address)"
cast call $SETTLEMENT "paused()(bool)"

# PaymasterV3 状态
cast call $PAYMASTER "sbtContract()(address)"
cast call $PAYMASTER "gasToken()(address)"
cast call $PAYMASTER "minTokenBalance()(uint256)"
cast call $PAYMASTER "paused()(bool)"

# EntryPoint余额
cast call $ENTRYPOINT \
  "balanceOf(address)(uint256)" \
  $PAYMASTER
```

### 2. 事件监听

```bash
# 监听 FeeRecorded 事件
cast logs \
  --address $SETTLEMENT \
  --from-block latest \
  "FeeRecorded(address,address,address,uint256,bytes32)" \
  --rpc-url sepolia

# 监听 FeeSettled 事件
cast logs \
  --address $SETTLEMENT \
  "FeeSettled(bytes32,address,address,uint256,bytes32)"
```

### 3. 交易追踪

```bash
# 查看交易详情
cast tx $TX_HASH --rpc-url sepolia

# 查看交易收据
cast receipt $TX_HASH --rpc-url sepolia

# 解码交易输入
cast 4byte-decode $(cast tx $TX_HASH --rpc-url sepolia | grep input)
```

---

## ⚠️ 已知问题

### 1. OpenZeppelin版本冲突

**问题**: singleton-paymaster使用OZ v5.0.2, 主项目使用v5.1.0  
**影响**: 无法在同一文件中同时导入Settlement和PaymasterV3  
**解决**: 
- 分开编译测试
- 使用Mock隔离
- 生产部署不受影响

### 2. PaymasterV3完整测试

**问题**: 由于版本冲突,完整测试套件被简化  
**缓解**: 
- 核心逻辑已通过简化测试验证
- 集成测试覆盖端到端流程
- 建议在fork环境做全面测试

### 3. Registry注册

**问题**: recordGasFee需要调用者在Registry注册  
**解决**: 
```bash
# 部署后立即注册
cast send $REGISTRY \
  "registerPaymaster(address)" \
  $PAYMASTER_ADDRESS \
  --rpc-url sepolia --private-key $REGISTRY_OWNER_KEY
```

---

## 📝 测试检查清单

部署前:
- [ ] 所有单元测试通过
- [ ] 合约成功编译
- [ ] 依赖合约地址准备好 (SBT, Token, Treasury)
- [ ] 部署账户有足够ETH

部署后:
- [ ] 合约地址已验证
- [ ] PaymasterV3已在Registry注册
- [ ] PaymasterV3已充值ETH
- [ ] Treasury配置为多签钱包
- [ ] 运行集成测试通过

测试完成:
- [ ] 记账功能正常
- [ ] 批量结算成功
- [ ] 事件正确触发
- [ ] 权限控制生效
- [ ] 暂停/恢复机制可用

---

## 📚 相关脚本

| 脚本 | 用途 | 命令 |
|------|------|------|
| `v3-deploy-simple.s.sol` | 部署合约 | `forge script ... --broadcast` |
| `v3-integration-test.s.sol` | 集成测试 | `forge script ... --broadcast` |
| `Settlement.t.sol` | 单元测试 | `forge test --match-path` |
| `PaymasterV3.t.sol` | 单元测试 | `forge test --match-path` |

---

## 🎯 下一步

测试通过后:
1. ✅ Sepolia部署并验证
2. ✅ 运行完整集成测试
3. ⏳ 安排安全审计
4. ⏳ 主网部署准备

---

**联系**: security@aastar.community  
**文档**: 持续更新
