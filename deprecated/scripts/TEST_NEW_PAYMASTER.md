# Test New PaymasterV4 (0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38)

测试新部署的 PaymasterV4，直接通过 EntryPoint 提交 UserOperation（无需 bundler）。

## 📋 测试配置

### 合约地址
- **PaymasterV4**: `0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38`
- **EntryPoint v0.7**: `0x0000000071727De22E5E9d8BAf0edAc6f37da032`
- **SimpleAccount**: `0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce`
- **PNT Token**: `0xD14E87d8D8B69016Fcc08728c33799bD3F66F180`

### 测试流程
1. SimpleAccount 转账 0.5 PNT 给 recipient
2. 使用 PNT 代币支付 gas 费用
3. PaymasterV4 从 SimpleAccount 扣除 PNT（转账金额 + gas 费用）

## 🚀 快速开始

### 前置条件

确保 `.env` 文件包含：
```bash
OWNER_PRIVATE_KEY="0x..."           # SimpleAccount owner 私钥
SEPOLIA_RPC_URL="https://..."       # Sepolia RPC URL
SIMPLE_ACCOUNT_B="0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce"
PNT_TOKEN_ADDRESS="0xD14E87d8D8B69016Fcc08728c33799bD3F66F180"
OWNER2_ADDRESS="0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA"  # Recipient
```

### Step 1: 准备测试账户

```bash
node scripts/prepare-test-account.js
```

**此脚本会：**
1. ✅ 检查 SimpleAccount 的 PNT 余额（需要 >= 10 PNT）
2. ✅ 检查 PNT allowance
3. ✅ 如果 allowance 不足，自动批准 PaymasterV4 花费 1000 PNT

**预期输出：**
```
╔════════════════════════════════════════════════════════════════╗
║         Prepare SimpleAccount for PaymasterV4 Test            ║
╚════════════════════════════════════════════════════════════════╝

📋 Configuration:
   Signer: 0xc8d1Ae1063176BEBC750D9aD5D057BA4A65daf3d
   SimpleAccount: 0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce
   PaymasterV4: 0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38
   PNT Token: 0xD14E87d8D8B69016Fcc08728c33799bD3F66F180

📊 Step 1: Check PNT Balance
   Current Balance: 50.0 PNT
   ✅ Balance sufficient

📝 Step 2: Check Current Allowance
   Current Allowance: 0.0 PNT

💳 Step 3: Approve PaymasterV4
   Approving: 1000.0 PNT
   To: 0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38

   ✅ Transaction submitted!
   Transaction hash: 0x...
   Sepolia Etherscan: https://sepolia.etherscan.io/tx/0x...

   ⏳ Waiting for confirmation...
   ✅ Approval confirmed!
   Block Number: 9515500
   Gas Used: 150000

   New Allowance: 1000.0 PNT

╔════════════════════════════════════════════════════════════════╗
║              ✅ ACCOUNT PREPARED SUCCESSFULLY                  ║
║                                                                ║
║  You can now run: node scripts/test-new-paymaster-v4.js       ║
╚════════════════════════════════════════════════════════════════╝
```

### Step 2: 运行测试

```bash
node scripts/test-new-paymaster-v4.js
```

**此脚本会：**
1. ✅ 检查 PNT 余额和 allowance
2. ✅ 构造 PackedUserOp（EntryPoint v0.7 格式）
3. ✅ 签名 UserOpHash
4. ✅ 通过 `EntryPoint.handleOps()` 提交
5. ✅ 等待交易确认
6. ✅ 显示最终余额和 gas 消耗

**预期输出：**
```
╔════════════════════════════════════════════════════════════════╗
║     Test New PaymasterV4 via EntryPoint (Direct)              ║
╚════════════════════════════════════════════════════════════════╝

📋 Configuration:
   Signer: 0xc8d1Ae1063176BEBC750D9aD5D057BA4A65daf3d
   SimpleAccount: 0x8135c8c3BbF2EdFa19409650527E02B47233a9Ce
   PaymasterV4: 0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38
   PNT Token: 0xD14E87d8D8B69016Fcc08728c33799bD3F66F180
   EntryPoint: 0x0000000071727De22E5E9d8BAf0edAc6f37da032
   Recipient: 0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA

📊 Step 1: Check PNT Balance & Allowance
   PNT Balance: 50.0 PNT
   PNT Allowance: 1000.0 PNT
   ✅ PNT balance and allowance sufficient

📝 Step 2: Get Nonce
   Nonce: 5

🔧 Step 3: Construct CallData
   Transfer Amount: 0.5 PNT
   Transfer To: 0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA
   CallData Length: 196 bytes

⛽ Step 4: Configure Gas
   callGasLimit: 100000
   verificationGasLimit: 300000
   preVerificationGas: 100000
   maxFeePerGas: 1.501 gwei
   maxPriorityFeePerGas: 0.1 gwei

💳 Step 5: Construct PaymasterAndData
   Format: [paymaster(20) | pmVerifyGas(16) | pmPostOpGas(16) | gasToken(20)]
   Length: 72 bytes (expected 72)
   Paymaster: 0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38
   VerificationGasLimit: 200000
   PostOpGasLimit: 100000
   GasToken: 0xD14E87d8D8B69016Fcc08728c33799bD3F66F180
   Full hex: 0x4d6a367aa183903968833ec4ae361cfc8dddba38...

📦 Step 6: Build PackedUserOp
   ✅ PackedUserOp constructed

✍️  Step 7: Sign UserOp
   UserOpHash: 0x...
   Signature: 0x...
   ✅ UserOp signed

🚀 Step 8: Submit to EntryPoint.handleOps()
   Submitting...

✅ Transaction Submitted!
   Transaction hash: 0x...
   Sepolia Etherscan: https://sepolia.etherscan.io/tx/0x...

⏳ Waiting for confirmation...

🎉 UserOp Executed Successfully!
   Block Number: 9515520
   Gas Used: 350000
   Status: ✅ Success

💰 Step 9: Check Final Balance
   Initial PNT Balance: 50.0 PNT
   Final PNT Balance: 48.5 PNT
   PNT Spent (transfer + gas): 1.5 PNT
   Transfer Amount: 0.5 PNT
   Gas Cost in PNT: 1.0 PNT

╔════════════════════════════════════════════════════════════════╗
║                    ✅ TEST SUCCESSFUL                          ║
╚════════════════════════════════════════════════════════════════╝
```

## 📊 PaymasterAndData 格式

PaymasterV4 使用以下 `paymasterAndData` 格式（EntryPoint v0.7）：

```
Offset | Length | Field
-------|--------|---------------------------------------
0      | 20     | paymaster address
20     | 16     | paymasterVerificationGasLimit
36     | 16     | paymasterPostOpGasLimit
52     | 20     | userSpecifiedGasToken (optional)
-------|--------|---------------------------------------
Total  | 72     | bytes
```

**示例：**
```
0x4d6a367aa183903968833Ec4ae361cfc8dddba38  // paymaster (20 bytes)
  0000000000000000000000000000030d40        // pmVerifyGas = 200000 (16 bytes)
  00000000000000000000000000000186a0        // pmPostOpGas = 100000 (16 bytes)
  d14e87d8d8b69016fcc08728c33799bd3f66f180  // gasToken = PNT (20 bytes)
```

## 🔍 调试技巧

### 检查合约状态

```javascript
const PaymasterV4ABI = [
  "function owner() view returns (address)",
  "function treasury() view returns (address)",
  "function serviceFeeRate() view returns (uint256)",
  "function maxGasCostCap() view returns (uint256)",
  "function paused() view returns (bool)",
  "function getSupportedSBTs() view returns (address[])",
  "function getSupportedGasTokens() view returns (address[])",
];

const paymaster = new ethers.Contract(PAYMASTER_V4, PaymasterV4ABI, provider);

console.log("Owner:", await paymaster.owner());
console.log("Treasury:", await paymaster.treasury());
console.log("Service Fee:", await paymaster.serviceFeeRate());
console.log("Paused:", await paymaster.paused());
console.log("Supported SBTs:", await paymaster.getSupportedSBTs());
console.log("Supported Gas Tokens:", await paymaster.getSupportedGasTokens());
```

### 常见错误

1. **"Insufficient PNT balance"**
   - 确保 SimpleAccount 有 >= 10 PNT
   - 可以从 EOA 转账 PNT 到 SimpleAccount

2. **"Insufficient PNT allowance"**
   - 运行 `prepare-test-account.js` 批准 PaymasterV4

3. **"AA33 reverted: FailedOp"**
   - 检查 `paymasterAndData` 格式是否正确（应该是 72 bytes）
   - 检查 gas token 是否被 PaymasterV4 支持
   - 检查 PaymasterV4 是否有足够的 EntryPoint 存款

4. **"AA21 didn't pay prefund"**
   - PaymasterV4 在 EntryPoint 的存款不足
   - 需要向 EntryPoint 存款：`entryPoint.addDeposit(PAYMASTER_V4, { value: ethers.parseEther('0.1') })`

## 📚 相关文档

- [EntryPoint v0.7 规范](https://github.com/eth-infinitism/account-abstraction/blob/develop/contracts/core/EntryPoint.sol)
- [PackedUserOperation 格式](https://eips.ethereum.org/EIPS/eip-4337#useroperation)
- [PaymasterV4 源码](/src/paymasters/v4/PaymasterV4.sol)

## 🎯 测试检查清单

- [ ] SimpleAccount 有足够的 PNT 余额（>= 10 PNT）
- [ ] SimpleAccount 已批准 PaymasterV4 花费 PNT
- [ ] PaymasterV4 在 EntryPoint 有足够的存款
- [ ] PNT 被 PaymasterV4 列为支持的 gas token
- [ ] SimpleAccount owner 私钥正确配置
- [ ] Sepolia RPC URL 可访问

## 💡 扩展用法

### 1. 使用不同的 gas token

修改 `paymasterAndData` 中的 gas token 地址：

```javascript
const paymasterAndData = ethers.concat([
  PAYMASTER_V4,
  ethers.zeroPadValue(ethers.toBeHex(200000n), 16),
  ethers.zeroPadValue(ethers.toBeHex(100000n), 16),
  YOUR_GAS_TOKEN_ADDRESS, // 替换为其他支持的 token
]);
```

### 2. 让 PaymasterV4 自动选择 gas token

将 gas token 设置为零地址：

```javascript
const paymasterAndData = ethers.concat([
  PAYMASTER_V4,
  ethers.zeroPadValue(ethers.toBeHex(200000n), 16),
  ethers.zeroPadValue(ethers.toBeHex(100000n), 16),
  ethers.ZeroAddress, // PaymasterV4 自动选择最优 token
]);
```

### 3. 修改转账金额

```javascript
const transferAmount = ethers.parseUnits("1.0", 18); // 改为 1.0 PNT
```

---

**Created**: 2025-01-30
**PaymasterV4**: `0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38`
**Network**: Sepolia
