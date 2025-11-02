# AOA+ 模式修复记录

**日期**: 2025-11-02
**修复内容**: EntryPoint v0.7 paymasterAndData 格式错误
**影响范围**: 测试脚本（AOA 和 AOA+ 模式）

---

## 问题描述

测试脚本 `utils/userOp.js` 中使用了**错误的 paymasterAndData 格式**。

### ❌ 错误的格式（EntryPoint v0.6）

```javascript
const paymasterAndData = ethers.concat([
  paymasterAddress,                // 20 bytes
  xPNTsAddress,                   // 20 bytes
  ethers.zeroPadValue("0x", 6),   // validUntil (6 bytes)
  ethers.zeroPadValue("0x", 6),   // validAfter (6 bytes)
]);
// 总长度: 52 bytes
```

### ✅ 正确的格式（EntryPoint v0.7）

#### AOA 模式（PaymasterV4.1）
```javascript
const paymasterAndData = ethers.concat([
  paymasterAddress,                                    // 20 bytes
  ethers.toBeHex(paymasterVerificationGasLimit, 16),   // 16 bytes (uint128)
  ethers.toBeHex(paymasterPostOpGasLimit, 16),         // 16 bytes (uint128)
  xPNTsAddress,                                        // 20 bytes
  ethers.zeroPadValue("0x", 6),                        // validUntil (6 bytes)
  ethers.zeroPadValue("0x", 6),                        // validAfter (6 bytes)
]);
// 总长度: 84 bytes
```

#### AOA+ 模式（SuperPaymasterV2）
```javascript
const paymasterAndData = ethers.concat([
  paymasterAddress,                                    // 20 bytes
  ethers.toBeHex(paymasterVerificationGasLimit, 16),   // 16 bytes (uint128)
  ethers.toBeHex(paymasterPostOpGasLimit, 16),         // 16 bytes (uint128)
  operatorAddress,                                     // 20 bytes
]);
// 总长度: 72 bytes
```

---

## SuperPaymasterV2 AOA+ 计算流程确认

经过代码审查，**SuperPaymasterV2 的 gas 计算流程完全符合预期**：

### 计算公式

```solidity
// 1. 获取 ETH/USD 价格（Chainlink）
(, int256 ethUsdPrice,,,) = ethUsdPriceFeed.latestRoundData();

// 2. 计算 aPNTs 数量（含 2% service fee）
numerator = gasCostWei * ethUsdPrice * (BPS_DENOMINATOR + serviceFeeRate) * 1e18
          = gasCostWei * ethUsdPrice * 10200 * 1e18

denominator = (10^decimals) * BPS_DENOMINATOR * aPNTsPriceUSD
            = (10^decimals) * 10000 * 0.02e18

aPNTsAmount = numerator / denominator

// 3. 计算 xPNTs 数量（根据 operator exchangeRate）
xPNTsAmount = (aPNTsAmount * exchangeRate) / 1e18
```

### 参数配置

| 参数 | 值 | 说明 |
|------|-----|------|
| `aPNTsPriceUSD` | 0.02 ether | aPNTs 固定价格 $0.02 |
| `serviceFeeRate` | 200 | 2% 服务费（200 basis points） |
| `BPS_DENOMINATOR` | 10000 | 基点分母（100% = 10000） |
| `exchangeRate` | 例如 4e18 | xPNTs:aPNTs 兑换率（1:4） |

### 流程步骤

```
1. gasCostWei (EntryPoint maxCost)
   ↓ Chainlink ETH/USD
2. gasCostUSD = gasCostWei * ethPriceUSD / 10^decimals
   ↓ +2% service fee
3. totalCostUSD = gasCostUSD * 1.02
   ↓ aPNTs fixed price $0.02
4. aPNTsAmount = totalCostUSD / 0.02
   ↓ operator exchangeRate (例如 1:4)
5. xPNTsAmount = aPNTsAmount * 4
   ↓ 扣款
6. 从用户 account 扣除 xPNTsAmount 到 operator's treasury
7. 从 operator 的 aPNTs 余额扣除 aPNTsAmount
```

### 代码位置

- **计算逻辑**: `SuperPaymasterV2.sol:609-667`
  - `_calculateAPNTsAmount(gasCostWei)` - line 609-648
  - `_calculateXPNTsAmount(operator, aPNTsAmount)` - line 656-667

- **扣款逻辑**: `SuperPaymasterV2.sol:412-470`
  - `validatePaymasterUserOp()` - line 412-470
  - 用户 xPNTs 转账 - line 452
  - Operator aPNTs 扣除 - line 455-456

---

## 修复内容

### 1. 修复 `utils/userOp.js`

**文件**: `/scripts/tx-test/utils/userOp.js`

**修改**:
- 添加 `operatorAddress` 参数（AOA+ 模式）
- 添加 `paymasterVerificationGasLimit` 和 `paymasterPostOpGasLimit` 参数
- 更新 paymasterAndData 编码逻辑，支持 EntryPoint v0.7 格式
- 区分 AOA 和 AOA+ 两种模式的数据编码

**关键代码**:
```javascript
if (operatorAddress) {
  // AOA+ 模式 (SuperPaymasterV2)
  paymasterAndData = ethers.concat([
    paymasterAddress,
    ethers.toBeHex(paymasterVerificationGasLimit, 16),
    ethers.toBeHex(paymasterPostOpGasLimit, 16),
    operatorAddress,
  ]);
} else if (xPNTsAddress) {
  // AOA 模式 (PaymasterV4.1)
  paymasterAndData = ethers.concat([
    paymasterAddress,
    ethers.toBeHex(paymasterVerificationGasLimit, 16),
    ethers.toBeHex(paymasterPostOpGasLimit, 16),
    xPNTsAddress,
    ethers.zeroPadValue("0x", 6),  // validUntil
    ethers.zeroPadValue("0x", 6),  // validAfter
  ]);
}
```

### 2. 修复 `5-test-aoa-plus-paymaster.js`

**文件**: `/scripts/tx-test/5-test-aoa-plus-paymaster.js`

**修改**:
- 使用 `operatorAddress` 参数替代 `xPNTsAddress`
- 添加 `paymasterVerificationGasLimit` 和 `paymasterPostOpGasLimit` 参数

**修改前**:
```javascript
const userOp = await buildUserOp({
  sender: ACCOUNT_A,
  callData: executeCallData,
  paymasterAddress: CONTRACTS.SUPER_PAYMASTER_V2,
  xPNTsAddress: aPNTsAddress,  // ❌ 错误：AOA+ 不使用 xPNTsAddress
  callGasLimit: 100000n,
  verificationGasLimit: 200000n,
  preVerificationGas: 50000n,
});
```

**修改后**:
```javascript
const userOp = await buildUserOp({
  sender: ACCOUNT_A,
  callData: executeCallData,
  paymasterAddress: CONTRACTS.SUPER_PAYMASTER_V2,
  operatorAddress: DEPLOYER_ADDRESS,  // ✅ 正确：使用 operator address
  callGasLimit: 100000n,
  verificationGasLimit: 200000n,
  preVerificationGas: 50000n,
  paymasterVerificationGasLimit: 150000n,
  paymasterPostOpGasLimit: 50000n,
});
```

---

## 验证步骤

### 1. paymasterAndData 格式验证

```bash
# AOA+ 模式应该生成 72 bytes
# [paymaster(20)][verificationGas(16)][postOpGas(16)][operator(20)]
```

### 2. SuperPaymasterV2 合约验证

合约期望从 paymasterAndData[52:72] 提取 operator address：

```solidity
// SuperPaymasterV2.sol:679-685
function _extractOperator(PackedUserOperation calldata userOp) internal pure returns (address operator) {
    bytes calldata paymasterAndData = userOp.paymasterAndData;
    require(paymasterAndData.length >= 72, "Invalid paymasterAndData");

    // Extract operator address from bytes [52:72]
    return address(bytes20(paymasterAndData[52:72]));
}
```

---

## 影响范围

### 修复的文件
1. `scripts/tx-test/utils/userOp.js` - UserOperation 构建工具
2. `scripts/tx-test/5-test-aoa-plus-paymaster.js` - AOA+ 测试脚本

### 需要更新的文件（如果存在）
- `scripts/tx-test/4-test-aoa-paymaster.js` - AOA 测试脚本（也使用旧格式）

---

## 测试计划

### Phase 1: 格式验证
- [x] 确认 paymasterAndData 长度正确（72 bytes for AOA+, 84 bytes for AOA）
- [x] 确认 operator address 提取正确

### Phase 2: 功能测试
- [ ] 运行 AOA+ 测试脚本
- [ ] 验证 gas 计算逻辑
- [ ] 验证用户 xPNTs 扣款
- [ ] 验证 operator aPNTs 扣款
- [ ] 验证 treasury 增加

### Phase 3: 集成测试
- [ ] 完整的 AOA 模式测试
- [ ] 完整的 AOA+ 模式测试
- [ ] 对比两种模式的 gas 消耗

---

## 相关文档

- [EntryPoint v0.7 Specification](https://github.com/eth-infinitism/account-abstraction/blob/develop/eip/EIPS/eip-4337.md)
- [SuperPaymasterV2 合约](../src/paymasters/v2/core/SuperPaymasterV2.sol)
- [交易测试文档](./transaction-test-with-AOA-v2.md)

---

## 总结

✅ **已确认**: SuperPaymasterV2 的 gas 计算流程完全符合预期
✅ **已修复**: paymasterAndData 格式错误（EntryPoint v0.7）
✅ **已修复**: AOA+ 测试脚本参数错误
⏳ **待测试**: 运行实际测试验证修复效果

**下一步**: 运行测试脚本，验证 AOA 和 AOA+ 两种模式的完整流程。
