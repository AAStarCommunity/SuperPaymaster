# PostOp Mode Fix - 基于实际 Gas 收费

## 修复日期
2025-10-23

## 问题描述

### 原始问题

1. **使用 maxCost 而非 actualGas 收费**
   - 当前在 validatePaymasterUserOp 中使用 maxCost 计算费用
   - maxCost = 所有 gas limits 总和 = 1,000,000 gas
   - 导致严重过度收费（153 aPNTs vs 实际应该 ~26 aPNTs）

2. **postOp 是空的**
   - postOp 函数什么都不做
   - actualGasCost 参数未被使用
   - 无法获取实际 gas 消耗

3. **gas limits 设置不合理**
   - paymasterVerificationGasLimit: 300k（过高）
   - paymasterPostOpGasLimit: 50k（对空函数浪费）

## 修复方案

### 采用 PostOp 模式

#### 修改 1: validatePaymasterUserOp - 只验证，不收费

**修改文件**: `src/v2/core/SuperPaymasterV2.sol:392-438`

**修改前**（PaymasterV4 模式）：
```solidity
function validatePaymasterUserOp(...) {
    // 1. 验证 SBT
    // 2. 计算费用（基于 maxCost）
    uint256 aPNTsAmount = _calculateAPNTsAmount(maxCost);

    // 3. 直接转账
    IERC20(xPNTsToken).transferFrom(user, treasury, xPNTsAmount);

    // 4. 返回空 context
    return ("", 0);
}
```

**修改后**（PostOp 模式）：
```solidity
function validatePaymasterUserOp(...) {
    // 1. 验证 SBT
    // 2. 检查余额是否足够支付 maxCost（预留检查）
    uint256 maxAPNTs = _calculateAPNTsAmount(maxCost);
    if (accounts[operator].aPNTsBalance < maxAPNTs) revert;
    if (IERC20(xPNTsToken).balanceOf(user) < maxXPNTs) revert;

    // 3. 返回 context 给 postOp 使用
    context = abi.encode(operator, user, xPNTsToken, treasury);
    return (context, 0);
}
```

**关键变化**：
- ✅ 不再直接转账
- ✅ 只做预留检查（确保余额足够）
- ✅ 返回 context（包含 operator, user, xPNTsToken, treasury）

#### 修改 2: postOp - 基于 actualGasCost 收费

**修改文件**: `src/v2/core/SuperPaymasterV2.sol:448-497`

**修改前**（空函数）：
```solidity
function postOp(...) {
    require(msg.sender == ENTRY_POINT, "Only EntryPoint");
    // 空实现
}
```

**修改后**（实际收费）：
```solidity
function postOp(
    PostOpMode mode,
    bytes calldata context,
    uint256 actualGasCost,
    uint256 actualUserOpFeePerGas
) external nonReentrant {
    require(msg.sender == ENTRY_POINT, "Only EntryPoint");

    // 如果 postOp 本身 revert，不收费
    if (mode == PostOpMode.postOpReverted) return;

    // 1. 解码 context
    (address operator, address user, address xPNTsToken, address treasury) =
        abi.decode(context, (address, address, address, address));

    // 2. 基于 actualGasCost 计算实际费用
    uint256 aPNTsAmount = _calculateAPNTsAmount(actualGasCost);

    // 3. 转账 xPNTs
    IERC20(xPNTsToken).transferFrom(user, treasury, xPNTsAmount);

    // 4. 更新记账和统计
    accounts[operator].aPNTsBalance -= aPNTsAmount;
    treasuryAPNTsBalance += aPNTsAmount;
    accounts[operator].totalSpent += aPNTsAmount;
    accounts[operator].totalTxSponsored += 1;

    // 5. Emit event
    emit TransactionSponsored(operator, user, aPNTsAmount, xPNTsAmount, block.timestamp);

    // 6. Update reputation
    _updateReputation(operator);
}
```

**关键变化**：
- ✅ 使用 actualGasCost 而非 maxCost
- ✅ 在 postOp 中执行转账
- ✅ 精确收费（实际消耗 + 2%）

#### 修改 3: 调整 Gas Limits

**修改文件**: `scripts/submit-via-entrypoint-v2.js:169-170`

**修改前**：
```javascript
paymasterVerificationGasLimit: 300000,  // 验证 + 转账
paymasterPostOpGasLimit: 50000,         // 空函数
```

**修改后**：
```javascript
paymasterVerificationGasLimit: 150000,  // 只验证（降低）
paymasterPostOpGasLimit: 150000,        // 转账 + 记账（提高）
```

**总 paymaster gas**：
- 修改前：350k
- 修改后：300k（总量降低，分配更合理）

## 预期效果

### Gas 费用对比

| 项目 | 修改前 | 修改后 | 变化 |
|------|--------|--------|------|
| 收费基础 | maxCost = 1M gas | actualGas ≈ 170k | -83% |
| 收费金额 | 153 aPNTs | ~26 aPNTs | -82% |
| Paymaster gas | 350k | 300k | -14% |

### 收费计算示例

**假设实际 gas 消耗**：167,001 gas

```
actualGasCost = 167,001 * 1 gwei = 0.000167001 ETH

Step 1: 转换为 USD
gasCostUSD = 0.000167001 ETH * $3000/ETH = $0.501

Step 2: 加上 2% 服务费
totalCostUSD = $0.501 * 1.02 = $0.511

Step 3: 转换为 aPNTs
aPNTsAmount = $0.511 / $0.02 = 25.55 ≈ 26 aPNTs
```

**用户支付**：26 + 0.5（转账）= 26.5 xPNTs

## 修改文件清单

1. ✅ `src/v2/core/SuperPaymasterV2.sol`
   - validatePaymasterUserOp: 只验证，返回 context
   - postOp: 实现实际收费逻辑

2. ✅ `scripts/submit-via-entrypoint-v2.js`
   - 调整 paymasterVerificationGasLimit: 150k
   - 调整 paymasterPostOpGasLimit: 150k

3. ✅ `docs/GAS-CHARGE-ISSUE-ANALYSIS.md`
   - 问题分析文档

4. ✅ `docs/POSTOP-MODE-FIX.md`
   - 修复方案文档（本文件）

## 测试步骤

### 1. 重新部署合约

由于合约逻辑变更，需要重新部署 SuperPaymasterV2：

```bash
forge script script/DeploySuperPaymasterV2.s.sol:DeploySuperPaymasterV2 \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY
```

### 2. 重复 Operator 注册流程

```bash
# Step1: 部署 aPNTs
forge script script/v2/Step1_Setup.s.sol:Step1_Setup \
  --rpc-url $SEPOLIA_RPC_URL --private-key $PRIVATE_KEY --broadcast

# Step2: Operator 注册
forge script script/v2/Step2_OperatorRegister.s.sol:Step2_OperatorRegister \
  --rpc-url $SEPOLIA_RPC_URL --private-key $OWNER2_PRIVATE_KEY --broadcast

# Step3: Operator 充值 aPNTs
forge script script/v2/Step3_OperatorDeposit.s.sol:Step3_OperatorDeposit \
  --rpc-url $SEPOLIA_RPC_URL --private-key $OWNER2_PRIVATE_KEY --broadcast
```

### 3. 用户准备（如需要）

如果 SimpleAccount 已有 SBT 和 xPNTs，只需要补充 xPNTs：

```bash
# Mint 200 xPNTs to SimpleAccount
cast send $OPERATOR_XPNTS_TOKEN_ADDRESS "mint(address,uint256)" \
  $SIMPLE_ACCOUNT_B "200000000000000000000" \
  --rpc-url $SEPOLIA_RPC_URL --private-key $OWNER2_PRIVATE_KEY
```

### 4. 运行测试

```bash
node scripts/submit-via-entrypoint-v2.js
```

### 5. 验证结果

**预期**：
- ✅ 交易成功
- ✅ 用户 xPNTs 减少 ~26.5（实际 gas + 0.5 转账）
- ✅ Operator treasury 增加 ~26.5
- ✅ Operator aPNTs 减少 ~26

**对比修复前**：
- ❌ 用户 xPNTs 减少 153.5
- ❌ 过度收费 5.9倍

## 技术要点

### 1. 为什么必须用 postOp？

**ERC-4337 执行顺序**：
```
1. validatePaymasterUserOp() 调用
   ↓
2. 用户交易执行
   ↓
3. actualGasCost 计算
   ↓
4. postOp() 调用（传入 actualGasCost）
```

**结论**：只有在 postOp 中才能获取 actualGasCost

### 2. PaymasterV4 也有同样问题

PaymasterV4 也使用 maxCost 收费：

```solidity
// PaymasterV4.sol:234-237
uint256 cappedMaxCost = maxCost > maxGasCostCap ? maxGasCostCap : maxCost;
uint256 pntAmount = _calculatePNTAmount(cappedMaxCost);
```

**建议**：后续也修复 V4

### 3. Gas Limits 分配原则

- **Verification**: 简单检查（SBT、余额）→ 150k 足够
- **PostOp**: 转账 + 更新状态 → 150k 合理

## 安全考虑

### 1. Reentrancy 保护

postOp 添加了 `nonReentrant` 修饰符：

```solidity
function postOp(...) external nonReentrant {
    // ...
}
```

### 2. 余额检查

validatePaymasterUserOp 中预先检查余额：

```solidity
if (accounts[operator].aPNTsBalance < maxAPNTs) revert;
if (IERC20(xPNTsToken).balanceOf(user) < maxXPNTs) revert;
```

### 3. PostOp 失败处理

```solidity
if (mode == PostOpMode.postOpReverted) return;
```

如果 postOp 本身失败，不收费。

## 总结

### ✅ 问题解决

1. ✅ postOp 不再是空的
2. ✅ 使用 actualGasCost 而非 maxCost
3. ✅ 精确收费（实际消耗 + 2%）
4. ✅ Gas limits 合理分配

### 📊 效果

- **成本降低**：82%（153 → 26 aPNTs）
- **公平性**：只收取实际消耗
- **透明度**：准确反映真实 gas 成本

### 🔄 下一步

1. 重新部署并测试
2. 验证实际收费金额
3. 更新所有文档
4. 考虑修复 PaymasterV4
