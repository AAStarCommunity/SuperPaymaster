# SuperPaymaster V3 部署指南

**版本**: v3.0.0  
**网络**: Sepolia Testnet  
**更新日期**: 2025-01-05

---

## 📋 前置要求

### 1. 准备工作
- [ ] Foundry 安装 (`curl -L https://foundry.paradigm.xyz | bash`)
- [ ] Sepolia ETH (用于 gas, 至少 0.1 ETH)
- [ ] Etherscan API Key (用于合约验证)
- [ ] Alchemy/Infura RPC URL

### 2. 依赖合约准备
- [ ] **SBT 合约** - 用户资格验证 (Soul-Bound Token)
- [ ] **Gas Token** - 支付 gas 的 ERC20 (如 USDC/PNT)
- [ ] **Treasury** - 资金接收地址 (推荐 Gnosis Safe 3/5 多签)

### 3. 已有基础设施
- ✅ **EntryPoint v0.7**: `0x0000000071727De22E5E9d8BAf0edAc6f37da032`
- ✅ **SuperPaymaster Registry**: `0x4e6748c62D8ebe8A8b71736eaAbbB79575a79575`

---

## 🚀 部署步骤

### Step 1: 配置环境变量

```bash
# 复制环境变量模板
cp .env.sepolia.example .env.sepolia

# 编辑配置文件
vim .env.sepolia
```

**必填配置**:
```bash
PRIVATE_KEY=0x...                          # 部署者私钥
SEPOLIA_RPC_URL=https://...               # Sepolia RPC
ETHERSCAN_API_KEY=...                     # Etherscan 验证
TREASURY_ADDRESS=0x...                    # Treasury 地址 (多签钱包)
SBT_CONTRACT_ADDRESS=0x...                # SBT 合约地址
GAS_TOKEN_ADDRESS=0x...                   # Gas Token 地址
MIN_TOKEN_BALANCE=1000000                 # 最小余额 (wei)
```

---

### Step 2: 执行部署

```bash
# 加载环境变量
source .env.sepolia

# 部署到 Sepolia
forge script script/DeployV3.s.sol:DeployV3 \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvv
```

**预期输出**:
```
========================================
SuperPaymaster V3 Deployment
========================================
Deployer: 0x...
Network: Sepolia

[1/2] Deploying Settlement...
Settlement deployed at: 0xABC...

[2/2] Deploying PaymasterV3...
PaymasterV3 deployed at: 0xDEF...

Deployment Complete!
========================================
```

**部署信息保存**: `deployments/v3-sepolia.json`

---

### Step 3: 在 SuperPaymaster Registry 注册

```bash
# 使用 cast 调用 Registry
cast send $REGISTRY_ADDRESS \
  "registerPaymaster(address)" \
  $PAYMASTER_V3_ADDRESS \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

**验证注册**:
```bash
cast call $REGISTRY_ADDRESS \
  "isPaymasterActive(address)(bool)" \
  $PAYMASTER_V3_ADDRESS \
  --rpc-url $SEPOLIA_RPC_URL
```

预期返回: `true`

---

### Step 4: 为 PaymasterV3 充值 ETH

PaymasterV3 需要 ETH 余额来支付 gas:

```bash
# 方法1: 直接转账
cast send $PAYMASTER_V3_ADDRESS \
  --value 0.1ether \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY

# 方法2: 通过 EntryPoint deposit
cast send $PAYMASTER_V3_ADDRESS \
  "deposit()" \
  --value 0.1ether \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

**检查余额**:
```bash
cast call $ENTRYPOINT_ADDRESS \
  "balanceOf(address)(uint256)" \
  $PAYMASTER_V3_ADDRESS \
  --rpc-url $SEPOLIA_RPC_URL
```

---

### Step 5: (可选) 添加 EntryPoint Stake

为了防止 DoS 攻击，EntryPoint 要求 Paymaster 质押:

```bash
cast send $PAYMASTER_V3_ADDRESS \
  "addStake(uint32)" \
  86400 \  # unstakeDelay = 1 day
  --value 0.05ether \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

---

## ✅ 部署后验证

### 1. 合约验证清单

| 检查项 | 命令 | 预期结果 |
|--------|------|---------|
| Settlement 部署 | `cast code $SETTLEMENT_ADDRESS` | 返回字节码 |
| PaymasterV3 部署 | `cast code $PAYMASTER_V3_ADDRESS` | 返回字节码 |
| Registry 注册 | `cast call registry "isPaymasterActive(address)"` | `true` |
| PaymasterV3 余额 | `cast balance $PAYMASTER_V3_ADDRESS` | > 0 |
| Settlement owner | `cast call settlement "owner()"` | 部署者地址 |
| PaymasterV3 owner | `cast call paymaster "owner()"` | 部署者地址 |

### 2. 功能测试

#### 测试 1: SBT 和 Token 检查
```bash
# 检查配置
cast call $PAYMASTER_V3_ADDRESS "sbtContract()(address)"
cast call $PAYMASTER_V3_ADDRESS "gasToken()(address)"
cast call $PAYMASTER_V3_ADDRESS "minTokenBalance()(uint256)"
```

#### 测试 2: Settlement 配置
```bash
cast call $SETTLEMENT_ADDRESS "registry()(address)"
cast call $SETTLEMENT_ADDRESS "treasury()(address)"
cast call $SETTLEMENT_ADDRESS "settlementThreshold()(uint256)"
```

---

## 🔧 常见问题排查

### 问题 1: 部署失败 - Insufficient funds
**原因**: 部署者账户 ETH 不足  
**解决**: 从水龙头获取 Sepolia ETH
```bash
# Sepolia 水龙头
https://sepoliafaucet.com/
https://www.alchemy.com/faucets/ethereum-sepolia
```

### 问题 2: 验证失败 - Already Verified
**原因**: 合约已被验证  
**解决**: 移除 `--verify` 标志重新部署，或手动验证
```bash
forge verify-contract $CONTRACT_ADDRESS \
  src/v3/Settlement.sol:Settlement \
  --chain sepolia \
  --constructor-args $(cast abi-encode "constructor(address,address)" $REGISTRY $TREASURY)
```

### 问题 3: Registry 注册失败
**原因**: 调用者不是 Registry owner  
**解决**: 联系 Registry owner 进行注册

### 问题 4: PaymasterV3 无法赞助交易
**排查步骤**:
1. 检查 PaymasterV3 ETH 余额 > 0
2. 检查 Registry 注册状态 = active
3. 检查用户 SBT 持有状态
4. 检查用户 Token 余额 >= minTokenBalance

---

## 📊 Gas 消耗估算

| 操作 | Gas 消耗 | 成本 (@10 gwei) |
|------|---------|----------------|
| 部署 Settlement | ~800,000 | 0.008 ETH |
| 部署 PaymasterV3 | ~1,200,000 | 0.012 ETH |
| Registry 注册 | ~50,000 | 0.0005 ETH |
| 充值 deposit | ~50,000 | 0.0005 ETH |
| 添加 stake | ~80,000 | 0.0008 ETH |
| **总计** | **~2,180,000** | **~0.022 ETH** |

**建议准备**: 0.05 ETH (包含缓冲)

---

## 🔐 安全检查清单

部署后必须完成:

- [ ] **合约所有权**
  - [ ] Settlement owner = 部署者 (或转移到多签)
  - [ ] PaymasterV3 owner = 部署者 (或转移到多签)
  
- [ ] **Treasury 配置**
  - [ ] Treasury 地址 = Gnosis Safe 3/5 多签
  - [ ] 多签成员已确认
  
- [ ] **访问控制**
  - [ ] Registry 正确配置
  - [ ] PaymasterV3 已注册且 active
  
- [ ] **资金安全**
  - [ ] PaymasterV3 充值适量 ETH
  - [ ] Settlement 无 ETH 余额 (只负责记账)
  
- [ ] **监控设置**
  - [ ] Settlement pending balance 监控
  - [ ] PaymasterV3 ETH 余额告警
  - [ ] 异常交易告警

---

## 📝 部署后配置

### 1. 转移所有权 (可选)

如果需要多签管理:

```bash
# Settlement 转移到多签
cast send $SETTLEMENT_ADDRESS \
  "transferOwnership(address)" \
  $MULTISIG_ADDRESS \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY

# PaymasterV3 转移到多签
cast send $PAYMASTER_V3_ADDRESS \
  "transferOwnership(address)" \
  $MULTISIG_ADDRESS \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

### 2. 配置 Keeper (自动结算)

参考 `scripts/keeper/auto-settle.js`:

```javascript
// 监听 pending 金额
const pending = await settlement.pendingAmounts(user, token);
if (pending > threshold) {
  // 触发批量结算
  await settlement.settleFeesByUsers([user], token, settlementHash);
}
```

### 3. 设置结算阈值

```bash
cast send $SETTLEMENT_ADDRESS \
  "setSettlementThreshold(uint256)" \
  10000000000000000000 \  # 10 tokens
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

---

## 🚨 紧急操作

### 暂停合约

```bash
# 暂停 Settlement (停止记账和结算)
cast send $SETTLEMENT_ADDRESS "pause()" \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $OWNER_PRIVATE_KEY

# 暂停 PaymasterV3 (停止赞助)
cast send $PAYMASTER_V3_ADDRESS "pause()" \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $OWNER_PRIVATE_KEY
```

### 恢复合约

```bash
cast send $SETTLEMENT_ADDRESS "unpause()" \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $OWNER_PRIVATE_KEY
```

### 提取 PaymasterV3 资金

```bash
# 提取到指定地址
cast send $PAYMASTER_V3_ADDRESS \
  "withdrawTo(address,uint256)" \
  $RECIPIENT \
  $AMOUNT \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $OWNER_PRIVATE_KEY
```

---

## 📚 相关文档

- [Settlement-Design.md](./Settlement-Design.md) - 结算合约设计
- [V3-Configuration.md](./V3-Configuration.md) - 配置说明
- [Code-Quality-Checklist.md](./Code-Quality-Checklist.md) - 代码质量检查
- [V3-Final-Summary.md](./V3-Final-Summary.md) - 项目总结

---

## 📞 支持

- **技术支持**: security@aastar.community
- **文档**: https://docs.aastar.community
- **GitHub**: https://github.com/AAStarCommunity/SuperPaymaster-Contract

---

**部署完成后请保存**: `deployments/v3-sepolia.json`
