# SuperPaymaster V2 测试指南

## 概述

本指南说明如何使用分段脚本测试SuperPaymaster V2的完整主流程。

测试分为6个独立步骤，每个步骤都有专门的脚本：

1. **Step 1**: 初始配置（部署aPNTs token，配置SuperPaymaster）
2. **Step 2**: Operator注册（stake、部署xPNTs、注册）
3. **Step 3**: Operator充值（deposit aPNTs）
4. **Step 4**: 用户准备（mint SBT、获取xPNTs）
5. **Step 5**: 用户交易模拟（支付流程测试）
6. **Step 6**: 最终验证（检查所有状态和余额）

## 前置条件

### 1. 已部署的合约

确保以下合约已部署到Sepolia测试网：

- ✅ GToken (MockERC20)
- ✅ GTokenStaking
- ✅ SuperPaymasterV2
- ✅ xPNTsFactory
- ✅ MySBT

### 2. 环境变量配置

创建 `.env` 文件，包含以下变量：

```bash
# RPC
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY

# Deployer账户
PRIVATE_KEY=0x...
DEPLOYER_ADDRESS=0x...

# Operator账户
OWNER2_PRIVATE_KEY=0x...
OWNER2_ADDRESS=0x...

# 已部署合约
GTOKEN_ADDRESS=0x54Afca294BA9824E6858E9b2d0B9a19C440f6D35
GTOKEN_STAKING_ADDRESS=0xD8235F8920815175BD46f76a2cb99e15E02cED68
SUPER_PAYMASTER_V2_ADDRESS=0xeC3f8d895dcD9f9055e140b4B97AF523527755cF
XPNTS_FACTORY_ADDRESS=0x40B4E57b1b21F41783EfD937aAcE26157Fb957aD
MYSBT_ADDRESS=0x82737D063182bb8A98966ab152b6BAE627a23b11

# 这些变量会在测试过程中添加
# APNTS_TOKEN_ADDRESS=  (Step 1后添加)
# OPERATOR_XPNTS_TOKEN_ADDRESS=  (Step 2后添加)
```

### 3. 测试账户余额

确保以下账户有足够的Sepolia ETH：

- **Deployer**: ~0.5 ETH (用于部署和配置)
- **Operator**: ~0.3 ETH (用于注册和交易)

## 快速开始

### 方法1: 使用自动化脚本（推荐）

```bash
# 1. 赋予执行权限
chmod +x script/v2/run-v2-test.sh

# 2. 运行测试
./script/v2/run-v2-test.sh
```

脚本会：
- 自动按顺序执行所有6个步骤
- 在Step 1和Step 2后暂停，提示更新环境变量
- 保存所有日志到 `logs/v2-test-TIMESTAMP/` 目录
- 显示彩色进度和结果

### 方法2: 手动执行每个步骤

如果需要更精细的控制，可以手动执行每个步骤：

#### Step 1: 初始配置

```bash
forge script script/v2/Step1_Setup.s.sol:Step1_Setup \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --slow \
  -vvv
```

**输出示例**：
```
=== Step 1: Setup & Configuration ===

1.1 Deploying aPNTs token...
    aPNTs token deployed at: 0xABC...

1.2 Configuring SuperPaymaster...
    aPNTs token configured
    SuperPaymaster treasury: 0x888

1.3 Verifying configuration...
    [SUCCESS] Step 1 completed!

Environment variables to save:
APNTS_TOKEN_ADDRESS= 0xABC...
```

**重要**: 复制 `APNTS_TOKEN_ADDRESS` 并添加到 `.env` 文件。

#### Step 2: Operator注册

```bash
forge script script/v2/Step2_OperatorRegister.s.sol:Step2_OperatorRegister \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --slow \
  -vvv
```

**输出示例**：
```
=== Step 2: Operator Registration ===

2.1 Minting GToken to operator...
2.2 Operator staking GToken...
2.3 Deploying operator's xPNTs token...
    xPNTs token deployed: 0xDEF...
2.4 Registering to SuperPaymaster...
    [SUCCESS] Step 2 completed!

Environment variables to save:
OPERATOR_XPNTS_TOKEN_ADDRESS= 0xDEF...
```

**重要**: 复制 `OPERATOR_XPNTS_TOKEN_ADDRESS` 并添加到 `.env` 文件。

#### Step 3: Operator充值

```bash
forge script script/v2/Step3_OperatorDeposit.s.sol:Step3_OperatorDeposit \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --slow \
  -vvv
```

**验证点**：
- Operator的aPNTs余额 = 1000 aPNTs
- SuperPaymaster合约持有 >= 1000 aPNTs

#### Step 4: 用户准备

```bash
forge script script/v2/Step4_UserPrep.s.sol:Step4_UserPrep \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --slow \
  -vvv
```

**验证点**：
- 用户拥有 >= 1 个SBT
- 用户拥有 500 xTEST

#### Step 5: 用户交易模拟

```bash
forge script script/v2/Step5_UserTransaction.s.sol:Step5_UserTransaction \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --slow \
  -vvv
```

**注意**：
- 这是简化版本，手动模拟了用户支付xPNTs
- 完整的双重支付需要EntryPoint集成
- 主要验证用户xPNTs的转账是否正确

#### Step 6: 最终验证

```bash
forge script script/v2/Step6_Verification.s.sol:Step6_Verification \
  --rpc-url $SEPOLIA_RPC_URL \
  -vvv
```

**不需要 `--broadcast`**，这是只读操作。

**输出报告**：
```
========================================
V2 Main Flow Test Results
========================================
[SETUP]
  aPNTs token deployed: YES
  SuperPaymaster configured: YES
[OPERATOR]
  Registered: YES
  aPNTs deposited: 1000 aPNTs
  Treasury configured: true
[USER]
  Has SBT: true
  Has xPNTs: 347 xTEST
[PAYMENT FLOW]
  User -> Operator treasury: 153 xTEST
  Operator -> SuperPaymaster: 0 aPNTs (internal)
[INTERNAL ACCOUNTING]
  Balance integrity: true
========================================
```

## 测试流程图

```
┌─────────────────────────────────────────────────┐
│ Step 1: Setup                                   │
│ - Deploy aPNTs token                            │
│ - Configure SuperPaymaster                      │
└─────────────────┬───────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────┐
│ Step 2: Operator Register                       │
│ - Mint & stake GToken                           │
│ - Deploy xPNTs token                            │
│ - Register to SuperPaymaster                    │
└─────────────────┬───────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────┐
│ Step 3: Operator Deposit                        │
│ - Mint aPNTs (simulate purchase)                │
│ - Deposit aPNTs to SuperPaymaster               │
└─────────────────┬───────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────┐
│ Step 4: User Preparation                        │
│ - User mint SBT                                 │
│ - Operator mint xPNTs to user                   │
└─────────────────┬───────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────┐
│ Step 5: User Transaction                        │
│ - User approve xPNTs                            │
│ - Simulate dual payment                         │
└─────────────────┬───────────────────────────────┘
                  │
                  ▼
┌─────────────────────────────────────────────────┐
│ Step 6: Verification                            │
│ - Check all balances                            │
│ - Verify internal accounting                    │
│ - Generate test report                          │
└─────────────────────────────────────────────────┘
```

## 经济模型验证

测试验证了以下经济流程：

### Operator充值
```
Operator购买aPNTs
      ↓
  depositAPNTs()
      ↓
aPNTs → SuperPaymaster合约
      ↓
 内部余额记录+
```

### 用户交易（简化版）
```
用户持有xPNTs + SBT
      ↓
 approve & transfer
      ↓
xPNTs → Operator treasury
```

### 完整版（需要EntryPoint）
```
EntryPoint.handleOps()
      ↓
validatePaymasterUserOp()
      ↓
1. User xPNTs → Operator treasury
2. Operator aPNTs余额 -
3. SuperPaymaster treasury余额 +
```

## 常见问题

### Q1: Step 1执行失败，提示 "InvalidConfiguration"

**原因**: SuperPaymaster合约未正确配置owner

**解决**:
```bash
# 检查合约owner
cast call $SUPER_PAYMASTER_V2_ADDRESS "owner()" --rpc-url $SEPOLIA_RPC_URL

# 确保PRIVATE_KEY对应的地址是owner
```

### Q2: Step 2执行失败，提示 "InsufficientStake"

**原因**: Operator的sGToken余额不足

**解决**:
- 检查 `STAKE_AMOUNT` 和 `LOCK_AMOUNT` 配置
- 确保 `LOCK_AMOUNT <= STAKE_AMOUNT`
- 默认配置: stake 100, lock 50

### Q3: Step 3执行失败，提示 "ERC20: insufficient allowance"

**原因**: aPNTs的approve没有成功

**解决**:
- 检查脚本中的 `apntsToken.approve()` 调用
- 确保使用正确的私钥（OWNER2_PRIVATE_KEY）

### Q4: Step 5只转账了xPNTs，没有扣除aPNTs？

**这是预期行为**。Step 5是简化版本，只模拟了用户支付xPNTs的部分。完整的双重支付需要：

1. 部署真实的EntryPoint v0.7合约
2. 构造PackedUserOperation
3. 调用 `EntryPoint.handleOps()`
4. 在 `validatePaymasterUserOp` 中完成双重支付

当前测试主要验证：
- 合约配置正确
- 用户能够转账xPNTs
- 内部记账机制正常

### Q5: 如何清理测试环境重新开始？

由于合约状态已经改变，最简单的方法是：

1. 重新部署所有合约
2. 更新 `.env` 中的合约地址
3. 重新运行测试

或者使用新的Operator账户：
```bash
# 生成新账户
cast wallet new

# 更新.env中的OWNER2相关变量
```

## 下一步计划

完成V2主流程测试后，可以进行：

### 1. EntryPoint集成测试

创建真实的UserOp并通过EntryPoint执行：

```solidity
// 需要实现
- 构造PackedUserOperation
- 签名UserOp
- 调用EntryPoint.handleOps()
- 验证完整的双重支付
```

### 2. PaymasterV4兼容性测试

使用相同的资产和账户测试V4：

```bash
# 基于当前部署的：
# - GToken
# - GTokenStaking
# - Operator账户
# - User账户

# 测试V4的：
# - Operator注册
# - 用户交易
# - 对比V2和V4的差异
```

### 3. 压力测试

```bash
# 批量交易测试
# 多operator测试
# 并发测试
```

## 日志分析

测试日志保存在 `logs/v2-test-TIMESTAMP/` 目录：

```
logs/v2-test-20251023-140000/
├── step1.log  # Setup日志
├── step2.log  # Operator注册日志
├── step3.log  # Operator充值日志
├── step4.log  # 用户准备日志
├── step5.log  # 交易模拟日志
└── step6.log  # 验证报告
```

**关键检查点**：

- `step1.log`: 查找 "APNTS_TOKEN_ADDRESS"
- `step2.log`: 查找 "OPERATOR_XPNTS_TOKEN_ADDRESS"
- `step3.log`: 验证 aPNTs余额
- `step4.log`: 验证 SBT和xPNTs
- `step5.log`: 验证 xPNTs转账
- `step6.log`: 完整的测试报告

## 总结

分段测试的优势：

1. **易于调试**: 每个步骤独立，出错时只需重跑失败的步骤
2. **灵活性**: 可以跳过某些步骤或重复执行
3. **可维护性**: 每个脚本功能单一，易于理解和修改
4. **可扩展性**: 容易添加新的测试步骤

完成这6个步骤后，V2的核心经济模型和配置机制都得到了验证。

---

**最后更新**: 2025-10-23
**测试网络**: Sepolia
**合约版本**: SuperPaymaster v2.0-beta
