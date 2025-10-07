# SuperPaymaster V3 端到端测试指南

完整测试 ERC-4337 UserOperation 流程,包括 gas 赞助、记账和结算。

## 测试目标

验证完整的 Gas 赞助流程:
1. ✅ User1 有 SBT 和足够的 PNT 余额
2. ✅ PaymasterV3 在 EntryPoint 有足够的 deposit
3. 🔄 构造并提交 UserOperation (通过 Alchemy Bundler)
4. 🔄 EntryPoint 调用 PaymasterV3.validatePaymasterUserOp()
5. 🔄 验证通过,执行 UserOp (转账到 User2)
6. 🔄 EntryPoint 调用 PaymasterV3.postOp() 进行记账
7. 🔄 Settlement 记录 pending fees
8. 🔄 Owner 执行批量结算
9. 🔄 验证最终状态

## 前置条件检查

### ✅ 已完成
- [x] Settlement 已部署: `0x6Bbf0C72805ECd4305EfCCF579c32d6F6d3041d5`
- [x] PaymasterV3 已部署: `0x1568da4ea1E2C34255218b6DaBb2458b57B35805`
- [x] PaymasterV3 已注册到 Registry (Active: true, Fee: 1%)
- [x] PaymasterV3 已充值 0.1 ETH (用于 gas)
- [x] PaymasterV3 已向 EntryPoint deposit 0.02 ETH
  - TX: `0xe22371f23de3c6131a3b971344c64a4f0be9225e1eb360d1b866d1cbceb6a2c5`
  - Deposit: 0.02 ETH

### 📋 待检查
- [ ] User1 (`TEST_USER_ADDRESS`) 持有 SBT
- [ ] User1 持有至少 10 PNT
- [ ] User1 是否已部署为 SimpleAccount (ERC-4337 账户)
- [ ] 获取 User1 的私钥 (`TEST_USER_PRIVATE_KEY`)

## 环境配置

### 1. 环境变量设置

在 `.env.v3` 中确认以下配置:

```bash
# 网络配置
SEPOLIA_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/YOUR_API_KEY"

# 已部署的合约
SETTLEMENT_ADDRESS="0x6Bbf0C72805ECd4305EfCCF579c32d6F6d3041d5"
PAYMASTER_V3_ADDRESS="0x1568da4ea1E2C34255218b6DaBb2458b57B35805"
SBT_CONTRACT_ADDRESS="0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f"
GAS_TOKEN_ADDRESS="0x3e7B771d4541eC85c8137e950598Ac97553a337a"

# 测试账户
TEST_USER_ADDRESS="0x411BD567E46C0781248dbB6a9211891C032885e5"  # User1
TEST_USER_ADDRESS2="0xE3D28Aa77c95d5C098170698e5ba68824BFC008d"  # User2
TEST_USER_PRIVATE_KEY="0x..."  # ⚠️ 需要用户提供
```

### 2. 依赖安装

```bash
# Node.js 依赖
npm install ethers@6 axios

# 或使用 pnpm
pnpm add ethers@6 axios
```

## 测试执行步骤

### Step 1: 检查 User1 资格 ✅

```bash
cd ~/Dev/mycelium/my-exploration/projects/SuperPaymaster-Contract
source .env.v3

# 检查 SBT
cast call $SBT_CONTRACT_ADDRESS \
  "balanceOf(address)(uint256)" \
  $TEST_USER_ADDRESS \
  --rpc-url "$SEPOLIA_RPC_URL"

# 检查 PNT 余额
cast call $GAS_TOKEN_ADDRESS \
  "balanceOf(address)(uint256)" \
  $TEST_USER_ADDRESS \
  --rpc-url "$SEPOLIA_RPC_URL"
```

**预期结果:**
- SBT Balance > 0
- PNT Balance >= 10 PNT (10000000000000000000 wei)

---

### Step 2: 设置 User1 私钥 🔑

```bash
# 导出 User1 的私钥
export TEST_USER_PRIVATE_KEY="0x..."
```

⚠️ **重要**: 
- 这个私钥用于签名 UserOperation
- 不要泄露或提交到 Git
- 确保对应的地址是 `TEST_USER_ADDRESS`

---

### Step 3: 提交 UserOperation 🚀

#### 方法 A: 使用 TypeScript 脚本 (推荐)

```bash
# 1. 编译 TypeScript
npx ts-node scripts/submit-userop.ts

# 或使用 node (如果已编译)
node scripts/submit-userop.js
```

#### 方法 B: 使用简化的 Bash 脚本

```bash
./scripts/e2e-test.sh
```

**脚本会执行:**
1. 获取 nonce from EntryPoint
2. 构造 UserOperation
3. 用 User1 私钥签名
4. 通过 Alchemy Bundler 提交
5. 等待执行完成

**预期输出:**
```
✅ UserOperation submitted!
UserOp Hash: 0x...
✅ UserOperation executed!
Transaction Hash: 0x...
Gas Used: ...
```

---

### Step 4: 检查 Settlement 记账 📊

UserOperation 执行后,PaymasterV3 会在 `postOp()` 中调用 `Settlement.recordGasFee()`。

```bash
# 使用辅助脚本检查
./check-settlement.sh

# 或手动检查
cast call $SETTLEMENT_ADDRESS \
  "pendingAmounts(address,address)(uint256)" \
  $TEST_USER_ADDRESS \
  $GAS_TOKEN_ADDRESS \
  --rpc-url "$SEPOLIA_RPC_URL"
```

**预期结果:**
```
Pending amount: XXX wei
✅ Fee recorded successfully!
```

#### 查看详细记录

```bash
# 获取所有 pending 记录
cast call $SETTLEMENT_ADDRESS \
  "getUserPendingRecords(address,address)(bytes32[])" \
  $TEST_USER_ADDRESS \
  $GAS_TOKEN_ADDRESS \
  --rpc-url "$SEPOLIA_RPC_URL"
```

---

### Step 5: 执行批量结算 💰

由 Owner 调用 Settlement 合约进行批量结算。

```bash
# 使用辅助脚本
./settle-fees.sh

# 或手动执行
source .env.v3

# 获取 pending 记录
RECORDS=$(cast call $SETTLEMENT_ADDRESS \
  "getUserPendingRecords(address,address)(bytes32[])" \
  $TEST_USER_ADDRESS \
  $GAS_TOKEN_ADDRESS \
  --rpc-url "$SEPOLIA_RPC_URL")

# 生成 settlement hash
SETTLEMENT_HASH="0x$(date +%s | sha256sum | head -c 64)"

# 执行结算
cast send $SETTLEMENT_ADDRESS \
  "settleFees(bytes32[],bytes32)" \
  "$RECORDS" \
  "$SETTLEMENT_HASH" \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --private-key "$PRIVATE_KEY" \
  --legacy
```

**预期输出:**
```
✅ Settlement completed!
Transaction Hash: 0x...
```

---

### Step 6: 验证最终状态 ✅

```bash
# 检查 pending balance (应该为 0)
cast call $SETTLEMENT_ADDRESS \
  "pendingAmounts(address,address)(uint256)" \
  $TEST_USER_ADDRESS \
  $GAS_TOKEN_ADDRESS \
  --rpc-url "$SEPOLIA_RPC_URL"

# 检查 User2 是否收到转账
cast balance $TEST_USER_ADDRESS2 --rpc-url "$SEPOLIA_RPC_URL"
```

**预期结果:**
- Pending balance: 0
- User2 余额增加 0.001 ETH

---

## 辅助脚本说明

### e2e-test.sh
完整的端到端测试脚本,会自动创建以下辅助脚本:

- `check-settlement.sh`: 检查 pending 余额和记录
- `settle-fees.sh`: 执行批量结算
- `test-userop.js`: Node.js 版本的 UserOp 提交脚本

### submit-userop.ts
TypeScript 版本的 UserOperation 提交脚本,参考 Alchemy 官方文档实现。

**功能:**
- 自动获取 nonce
- 构造标准的 UserOperation
- 签名 UserOp hash
- 通过 Bundler API 提交
- 等待执行并返回 receipt

## 常见问题

### Q1: UserOperation 提交失败

**可能原因:**
1. User1 没有部署为 SimpleAccount
2. callData 格式不正确
3. gas limit 设置过低
4. Paymaster deposit 不足

**解决方案:**
- 确认 User1 是否已部署账户抽象合约
- 检查 EntryPoint deposit: 至少 0.02 ETH
- 增加 gas limits

### Q2: validatePaymasterUserOp 失败

**可能原因:**
1. User 没有 SBT
2. User PNT 余额不足 (< 10 PNT)
3. PaymasterV3 未注册到 Registry

**解决方案:**
```bash
# 检查注册状态
cast call 0x4e67678AF714f6B5A8882C2e5a78B15B08a79575 \
  "getPaymasterInfo(address)(uint256,bool)" \
  $PAYMASTER_V3_ADDRESS \
  --rpc-url "$SEPOLIA_RPC_URL"
```

### Q3: postOp 没有调用 Settlement

**可能原因:**
- UserOp 执行失败
- PaymasterV3 代码逻辑错误

**解决方案:**
- 查看 EntryPoint events
- 检查 Transaction logs

### Q4: Settlement 记账失败

**可能原因:**
- 调用者不是已注册的 Paymaster
- Settlement 合约被暂停

**解决方案:**
```bash
# 检查 Settlement 状态
cast call $SETTLEMENT_ADDRESS "paused()(bool)" --rpc-url "$SEPOLIA_RPC_URL"
```

## 关键合约地址

| 合约 | 地址 | 说明 |
|------|------|------|
| EntryPoint v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | ERC-4337 入口点 |
| Settlement | `0x6Bbf0C72805ECd4305EfCCF579c32d6F6d3041d5` | Gas 费记账合约 |
| PaymasterV3 | `0x1568da4ea1E2C34255218b6DaBb2458b57B35805` | Gas 赞助合约 |
| Registry | `0x4e67678AF714f6B5A8882C2e5a78B15B08a79575` | Paymaster 注册表 |
| SBT | `0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f` | 用户资格凭证 |
| PNT Token | `0x3e7B771d4541eC85c8137e950598Ac97553a337a` | Gas 费用代币 |

## 测试检查清单

- [ ] User1 有 SBT
- [ ] User1 有至少 10 PNT
- [ ] PaymasterV3 在 EntryPoint 有 deposit (0.02 ETH)
- [ ] PaymasterV3 已注册且 active
- [ ] 设置 TEST_USER_PRIVATE_KEY
- [ ] 安装 Node.js 依赖 (ethers, axios)
- [ ] 提交 UserOperation
- [ ] 验证 UserOp 执行成功
- [ ] 检查 Settlement pending 记录
- [ ] 执行批量结算
- [ ] 验证 pending 余额清零
- [ ] 验证 User2 收到转账

## 参考文档

- [ERC-4337 Specification](https://eips.ethereum.org/EIPS/eip-4337)
- [Alchemy Bundler Docs](https://www.alchemy.com/docs/wallets/low-level-infra/quickstart)
- [EntryPoint v0.7 Interface](https://github.com/eth-infinitism/account-abstraction)
- [V3-DEPLOYMENT-SUMMARY.md](./V3-DEPLOYMENT-SUMMARY.md)

## 下一步

测试通过后:
1. 验证合约在 Etherscan
2. 编写自动化测试脚本
3. 部署到主网前进行压力测试
4. 准备生产环境监控
