# SuperPaymaster V2 测试脚本

## 快速开始

### 1. 自动化测试（推荐）

```bash
# 执行所有6个测试步骤
./run-v2-test.sh
```

脚本会自动：
- 按顺序执行所有步骤
- 在需要时暂停并提示更新环境变量
- 保存所有日志到 `logs/v2-test-TIMESTAMP/`
- 显示彩色进度和结果

### 2. 手动测试单个步骤

```bash
# Step 1: 初始配置
forge script script/v2/Step1_Setup.s.sol:Step1_Setup \
  --rpc-url $SEPOLIA_RPC_URL --broadcast --slow -vvv

# Step 2: Operator注册
forge script script/v2/Step2_OperatorRegister.s.sol:Step2_OperatorRegister \
  --rpc-url $SEPOLIA_RPC_URL --broadcast --slow -vvv

# Step 3: Operator充值
forge script script/v2/Step3_OperatorDeposit.s.sol:Step3_OperatorDeposit \
  --rpc-url $SEPOLIA_RPC_URL --broadcast --slow -vvv

# Step 4: 用户准备
forge script script/v2/Step4_UserPrep.s.sol:Step4_UserPrep \
  --rpc-url $SEPOLIA_RPC_URL --broadcast --slow -vvv

# Step 5: 用户交易模拟
forge script script/v2/Step5_UserTransaction.s.sol:Step5_UserTransaction \
  --rpc-url $SEPOLIA_RPC_URL --broadcast --slow -vvv

# Step 6: 最终验证（只读，无需broadcast）
forge script script/v2/Step6_Verification.s.sol:Step6_Verification \
  --rpc-url $SEPOLIA_RPC_URL -vvv
```

## 测试流程

```
Step 1: Setup
    ↓ (输出 APNTS_TOKEN_ADDRESS)
Step 2: Operator Register
    ↓ (输出 OPERATOR_XPNTS_TOKEN_ADDRESS)
Step 3: Operator Deposit
    ↓
Step 4: User Preparation
    ↓
Step 5: User Transaction
    ↓
Step 6: Verification
```

## 环境变量

### 必需的环境变量（.env文件）

```bash
# 部署者账户
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
```

### 测试过程中添加的变量

```bash
# Step 1后添加
APNTS_TOKEN_ADDRESS=0x...

# Step 2后添加
OPERATOR_XPNTS_TOKEN_ADDRESS=0x...
```

## 测试脚本说明

| 脚本 | 功能 | 需要broadcast | 输出变量 |
|------|------|--------------|---------|
| Step1_Setup | 部署aPNTs token，配置SuperPaymaster | ✅ | APNTS_TOKEN_ADDRESS |
| Step2_OperatorRegister | Operator质押并注册 | ✅ | OPERATOR_XPNTS_TOKEN_ADDRESS |
| Step3_OperatorDeposit | Operator充值aPNTs | ✅ | - |
| Step4_UserPrep | 用户mint SBT和xPNTs | ✅ | - |
| Step5_UserTransaction | 模拟用户支付 | ✅ | - |
| Step6_Verification | 验证所有状态 | ❌ | - |

## 注意事项

1. **按顺序执行**: 步骤之间有依赖关系，必须按顺序执行
2. **更新环境变量**: Step 1和Step 2后需要更新.env文件
3. **账户余额**: 确保deployer和operator账户有足够的Sepolia ETH
4. **Step 6是只读**: 不需要--broadcast参数

## 完整文档

详细信息请参考：`docs/V2-TEST-GUIDE.md`

## 测试内容

### ✅ 当前验证

- aPNTs token部署和配置
- Operator注册流程
- aPNTs充值和内部记账
- 用户SBT和xPNTs准备
- xPNTs支付流程
- 余额和状态验证

### ⚠️ 需要EntryPoint集成

- 真实UserOp构造
- validatePaymasterUserOp调用
- 完整的双重支付（xPNTs + aPNTs）
- Gas计算验证
- postOp处理

## 故障排除

### 编译错误

```bash
# 清理并重新编译
forge clean
forge build
```

### 交易失败

```bash
# 检查账户余额
cast balance $DEPLOYER_ADDRESS --rpc-url $SEPOLIA_RPC_URL
cast balance $OWNER2_ADDRESS --rpc-url $SEPOLIA_RPC_URL

# 检查合约状态
cast call $SUPER_PAYMASTER_V2_ADDRESS "owner()" --rpc-url $SEPOLIA_RPC_URL
```

### 重新开始测试

如果需要从头开始：
1. 重新部署所有合约
2. 更新.env中的合约地址
3. 重新运行测试脚本
