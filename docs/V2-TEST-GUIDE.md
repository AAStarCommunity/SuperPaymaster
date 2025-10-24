# SuperPaymasterV2 测试指南

## 一次性准备（仅首次执行）

### 1. 部署V2合约
```bash
forge script script/DeploySuperPaymasterV2.s.sol:DeploySuperPaymasterV2 \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

### 2. 执行步骤1-3（Operator注册和充值）
```bash
# Step1: 部署aPNTs
forge script script/v2/Step1_Setup.s.sol:Step1_Setup \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast

# Step2: Operator注册
forge script script/v2/Step2_OperatorRegister.s.sol:Step2_OperatorRegister \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $OWNER2_PRIVATE_KEY \
  --broadcast

# Step3: Operator充值aPNTs
forge script script/v2/Step3_OperatorDeposit.s.sol:Step3_OperatorDeposit \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $OWNER2_PRIVATE_KEY \
  --broadcast
```

### 3. 给SimpleAccount准备资产（首次）
```bash
# 3.1 Mint GT to SimpleAccount
cast send $GTOKEN_ADDRESS "mint(address,uint256)" \
  $SIMPLE_ACCOUNT_B "1000000000000000000" \
  --rpc-url $SEPOLIA_RPC_URL --private-key $DEPLOYER_PRIVATE_KEY

# 3.2 SimpleAccount approve and stake GT
APPROVE_CALLDATA=$(cast calldata "approve(address,uint256)" $GTOKEN_STAKING_ADDRESS "400000000000000000")
EXECUTE_APPROVE=$(cast calldata "execute(address,uint256,bytes)" $GTOKEN_ADDRESS 0 $APPROVE_CALLDATA)
cast send $SIMPLE_ACCOUNT_B "$EXECUTE_APPROVE" \
  --rpc-url $SEPOLIA_RPC_URL --private-key $OWNER_PRIVATE_KEY

STAKE_CALLDATA=$(cast calldata "stake(uint256)" "400000000000000000")
EXECUTE_STAKE=$(cast calldata "execute(address,uint256,bytes)" $GTOKEN_STAKING_ADDRESS 0 $STAKE_CALLDATA)
cast send $SIMPLE_ACCOUNT_B "$EXECUTE_STAKE" \
  --rpc-url $SEPOLIA_RPC_URL --private-key $OWNER_PRIVATE_KEY

# 3.3 SimpleAccount approve GT for MySBT and mint SBT
APPROVE_MYSBT=$(cast calldata "approve(address,uint256)" $MYSBT_ADDRESS "100000000000000000")
EXECUTE_APPROVE_MYSBT=$(cast calldata "execute(address,uint256,bytes)" $GTOKEN_ADDRESS 0 $APPROVE_MYSBT)
cast send $SIMPLE_ACCOUNT_B "$EXECUTE_APPROVE_MYSBT" \
  --rpc-url $SEPOLIA_RPC_URL --private-key $OWNER_PRIVATE_KEY

MINT_SBT=$(cast calldata "mintSBT(address)" $OWNER2_ADDRESS)
EXECUTE_MINT_SBT=$(cast calldata "execute(address,uint256,bytes)" $MYSBT_ADDRESS 0 $MINT_SBT)
cast send $SIMPLE_ACCOUNT_B "$EXECUTE_MINT_SBT" \
  --rpc-url $SEPOLIA_RPC_URL --private-key $OWNER_PRIVATE_KEY
```

## 可重复测试（每次测试前执行）

### 1. 补充SimpleAccount的xPNTs余额
```bash
# Mint 200 xPNTs to SimpleAccount (每次测试消耗~153.5)
cast send $OPERATOR_XPNTS_TOKEN_ADDRESS "mint(address,uint256)" \
  $SIMPLE_ACCOUNT_B "200000000000000000000" \
  --rpc-url $SEPOLIA_RPC_URL --private-key $OWNER2_PRIVATE_KEY
```

### 2. 运行EntryPoint V2集成测试
```bash
node scripts/submit-via-entrypoint-v2.js
```

### 3. 检查结果
- 交易应该成功
- 用户xPNTs减少约153.5
- Operator treasury增加约153.0
- Operator aPNTs减少约153.0

## Gas消耗分析

**每次测试消耗**：
- 用户xPNTs：~153.5 (153 gas费 + 0.5 transfer)
- Operator aPNTs：~153.0
- 实际ETH gas：167k-252k (首次较高，后续较低)

**计算公式**：
```
maxCost = (callGas + verifyGas + preVerifyGas + paymasterVerifyGas + paymasterPostOpGas) * maxFeePerGas
        = (150k + 400k + 100k + 300k + 50k) * 1 gwei
        = 1,000,000 gwei = 0.001 ETH

gasCostUSD = 0.001 ETH * $3000/ETH = $3
totalCostUSD = $3 * 1.02 = $3.06 (含2%服务费)
aPNTsAmount = $3.06 / $0.02 = 153 aPNTs
```

## 测试checklist

- [ ] SimpleAccount有SBT？
- [ ] SimpleAccount有足够xPNTs（≥200）？
- [ ] Operator有足够aPNTs（≥153）？
- [ ] EntryPoint有deposit（≥0.1 ETH）？
- [ ] 测试脚本执行成功？
- [ ] 双重支付验证通过？

## 常见问题

**Q: 测试失败"InsufficientBalance"**
A: SimpleAccount xPNTs不足，需要mint更多

**Q: 测试失败"NoValidSBT"**  
A: SimpleAccount没有SBT，需要先mint SBT

**Q: 为什么gas消耗是153而不是23？**
A: V2使用maxCost预收费，包含所有gas限制和paymaster gas

**Q: 如何降低gas消耗？**
A: 调整gas限制参数或gasToUSDRate/aPNTsPriceUSD配置
