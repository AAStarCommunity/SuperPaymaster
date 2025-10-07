# 标准 ERC-4337 交易配置指南

本文档提供标准的 ERC-4337 UserOperation 配置,允许任何人使用 PaymasterV4 重现测试交易。

## 📋 目录

- [前置要求](#前置要求)
- [合约地址](#合约地址)
- [UserOperation 结构](#useroperation-结构)
- [PaymasterAndData 格式](#paymasteranddata-格式)
- [完整配置示例](#完整配置示例)
- [代码示例](#代码示例)
- [验证步骤](#验证步骤)

## 前置要求

### 1. 测试账户准备

⚠️ **重要**: 在提交 UserOperation 之前，必须完成以下所有步骤！

你需要一个 SimpleAccount (ERC-4337 账户) 或任何兼容的 AA 账户:

✅ **必需步骤**:
1. **PNT Token 余额 ≥ 20 PNT** (PaymasterV4 最低要求)
2. **🔴 PNT 必须授权给 PaymasterV4!** (这是最容易被忽略的步骤)
   - 使用 `approve(address,uint256)` 授权
   - 建议授权 `MaxUint256` (无限额度)
3. **SBT Token 余额 ≥ 1** (如果账户已部署)
4. **账户 owner 的私钥** 用于签名

> 💡 **快速获取测试 tokens**: 访问 [Faucet](https://gastoken-faucet.vercel.app) 免费领取 SBT 和 PNT

### 2. 环境配置

```bash
# Sepolia 测试网 RPC
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_API_KEY

# 账户 owner 私钥
OWNER_PRIVATE_KEY=0x...

# 你的 SimpleAccount 地址
SIMPLE_ACCOUNT=0x...
```

### 3. 依赖安装

```bash
npm install ethers@6
```

## 合约地址

### Sepolia 测试网部署地址

```javascript
const CONTRACTS = {
  // ERC-4337 v0.7
  ENTRYPOINT: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
  
  // PaymasterV4
  PAYMASTER_V4: "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445",
  
  // Registry
  SUPER_PAYMASTER_REGISTRY: "0x838da93c815a6E45Aa50429529da9106C0621eF0",
  
  // Tokens
  PNT_TOKEN: "0xD14E87d8D8B69016Fcc08728c33799bD3F66F180",
  SBT_TOKEN: "0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f",
  
  // Account Factory
  SIMPLE_ACCOUNT_FACTORY: "0x70F0DBca273a836CbA609B10673A52EED2D15625",
};
```

## UserOperation 结构

ERC-4337 v0.7 的 PackedUserOperation 结构:

```solidity
struct PackedUserOperation {
    address sender;                  // [0:20] 账户地址
    uint256 nonce;                   // [20:52] 账户 nonce
    bytes initCode;                  // [52:?] 账户初始化代码 (已部署账户为 "0x")
    bytes callData;                  // [?:?] 要执行的调用数据
    bytes32 accountGasLimits;        // [?:?+32] 打包的 gas 限制
    uint256 preVerificationGas;      // [?+32:?+64] 预验证 gas
    bytes32 gasFees;                 // [?+64:?+96] 打包的 gas 费用
    bytes paymasterAndData;          // [?+96:?] Paymaster 相关数据
    bytes signature;                 // [?:?] 账户签名
}
```

### accountGasLimits 打包格式
```javascript
// 32 bytes total
accountGasLimits = concat(
  verificationGasLimit,  // 16 bytes (128 bits)
  callGasLimit           // 16 bytes (128 bits)
)
```

### gasFees 打包格式
```javascript
// 32 bytes total
gasFees = concat(
  maxPriorityFeePerGas,  // 16 bytes (128 bits)
  maxFeePerGas           // 16 bytes (128 bits)
)
```

## PaymasterAndData 格式

PaymasterV4 的 `paymasterAndData` 结构 (72 bytes total):

```javascript
paymasterAndData = concat(
  paymaster,                      // [0:20]  Paymaster 地址 (20 bytes)
  paymasterVerificationGasLimit,  // [20:36] 验证 gas 限制 (16 bytes, uint128)
  paymasterPostOpGasLimit,        // [36:52] postOp gas 限制 (16 bytes, uint128)
  userSpecifiedGasToken           // [52:72] 用户指定的 GasToken (20 bytes, address)
)
```

### 字段说明

1. **paymaster** (20 bytes): PaymasterV4 合约地址
   - Sepolia: `0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445`

2. **paymasterVerificationGasLimit** (16 bytes): Paymaster 验证阶段 gas 限制
   - 推荐值: `200000` (0x30d40)
   - 用于 `_validatePaymasterUserOp` 函数执行

3. **paymasterPostOpGasLimit** (16 bytes): Paymaster postOp 阶段 gas 限制
   - 推荐值: `100000` (0x186a0)
   - 用于 `_postOp` 函数执行 (扣除 token)

4. **userSpecifiedGasToken** (20 bytes): 用户指定的 GasToken 地址
   - 使用 PNT: `0xD14E87d8D8B69016Fcc08728c33799bD3F66F180`
   - 自动选择: `0x0000000000000000000000000000000000000000` (零地址)

### 编码示例

```javascript
const { ethers } = require("ethers");

// PaymasterV4 配置
const PAYMASTER_V4 = "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445";
const PNT_TOKEN = "0xD14E87d8D8B69016Fcc08728c33799bD3F66F180";

// 构造 paymasterAndData
const paymasterAndData = ethers.concat([
  PAYMASTER_V4,                                       // 20 bytes
  ethers.zeroPadValue(ethers.toBeHex(200000n), 16),  // 16 bytes (verification gas)
  ethers.zeroPadValue(ethers.toBeHex(100000n), 16),  // 16 bytes (postOp gas)
  PNT_TOKEN,                                          // 20 bytes (user specified token)
]);

console.log("paymasterAndData:", paymasterAndData);
console.log("Length:", paymasterAndData.length, "bytes");
// Output: 146 characters (0x + 72 bytes × 2)
```

## 完整配置示例

### 配置参数

```javascript
// Gas 限制
const gasLimits = {
  verificationGasLimit: 300000n,  // 账户验证 gas
  callGasLimit: 100000n,          // 调用执行 gas
  preVerificationGas: 100000n,    // 预验证 gas
  
  paymasterVerificationGasLimit: 200000n,  // Paymaster 验证 gas
  paymasterPostOpGasLimit: 100000n,        // Paymaster postOp gas
};

// Gas 价格 (动态获取)
async function getGasFees(provider) {
  const latestBlock = await provider.getBlock("latest");
  const baseFeePerGas = latestBlock.baseFeePerGas || ethers.parseUnits("0.001", "gwei");
  const maxPriorityFeePerGas = ethers.parseUnits("0.1", "gwei");
  const maxFeePerGas = baseFeePerGas + maxPriorityFeePerGas + ethers.parseUnits("0.001", "gwei");
  
  return { maxPriorityFeePerGas, maxFeePerGas };
}
```

### 构造 UserOperation

```javascript
async function buildUserOp(provider, signer, simpleAccount, recipient, amount) {
  // 1. 获取 nonce
  const accountABI = ["function getNonce() public view returns (uint256)"];
  const account = new ethers.Contract(simpleAccount, accountABI, provider);
  const nonce = await account.getNonce();

  // 2. 构造 callData (例如: 转账 PNT)
  const pntABI = ["function transfer(address to, uint256 amount) external returns (bool)"];
  const pnt = new ethers.Contract(PNT_TOKEN, pntABI, provider);
  const transferCalldata = pnt.interface.encodeFunctionData("transfer", [recipient, amount]);
  
  const executeCalldata = account.interface.encodeFunctionData("execute", [
    PNT_TOKEN,
    0,
    transferCalldata,
  ]);

  // 3. 获取 gas 费用
  const { maxPriorityFeePerGas, maxFeePerGas } = await getGasFees(provider);

  // 4. 打包 gas 限制
  const accountGasLimits = ethers.concat([
    ethers.zeroPadValue(ethers.toBeHex(gasLimits.verificationGasLimit), 16),
    ethers.zeroPadValue(ethers.toBeHex(gasLimits.callGasLimit), 16),
  ]);

  const gasFees = ethers.concat([
    ethers.zeroPadValue(ethers.toBeHex(maxPriorityFeePerGas), 16),
    ethers.zeroPadValue(ethers.toBeHex(maxFeePerGas), 16),
  ]);

  // 5. 构造 paymasterAndData
  const paymasterAndData = ethers.concat([
    PAYMASTER_V4,
    ethers.zeroPadValue(ethers.toBeHex(gasLimits.paymasterVerificationGasLimit), 16),
    ethers.zeroPadValue(ethers.toBeHex(gasLimits.paymasterPostOpGasLimit), 16),
    PNT_TOKEN,  // 指定使用 PNT 支付
  ]);

  // 6. 构造 UserOperation
  const userOp = {
    sender: simpleAccount,
    nonce: nonce,
    initCode: "0x",  // 账户已部署
    callData: executeCalldata,
    accountGasLimits: accountGasLimits,
    preVerificationGas: gasLimits.preVerificationGas,
    gasFees: gasFees,
    paymasterAndData: paymasterAndData,
    signature: "0x",  // 稍后填充
  };

  return userOp;
}
```

### 签名 UserOperation

```javascript
async function signUserOp(entryPoint, userOp, signerPrivateKey) {
  // 1. 获取 userOpHash
  const entryPointABI = [
    "function getUserOpHash((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature) userOp) external view returns (bytes32)",
  ];
  const entryPointContract = new ethers.Contract(entryPoint, entryPointABI, provider);
  const userOpHash = await entryPointContract.getUserOpHash(userOp);

  // 2. 签名 userOpHash
  const signingKey = new ethers.SigningKey(signerPrivateKey);
  const signature = signingKey.sign(userOpHash).serialized;

  // 3. 更新 UserOperation
  userOp.signature = signature;
  
  return userOp;
}
```

### 提交 UserOperation

```javascript
async function submitUserOp(entryPoint, userOp, beneficiary, signer) {
  const entryPointABI = [
    "function handleOps((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature)[] ops, address payable beneficiary) external",
  ];
  
  const entryPointContract = new ethers.Contract(entryPoint, entryPointABI, signer);
  
  // 提交 UserOperation
  const tx = await entryPointContract.handleOps([userOp], beneficiary, {
    gasLimit: 1000000n,
  });
  
  console.log("Transaction hash:", tx.hash);
  console.log("Sepolia Etherscan:", `https://sepolia.etherscan.io/tx/${tx.hash}`);
  
  const receipt = await tx.wait();
  console.log("Status:", receipt.status === 1 ? "Success" : "Failed");
  console.log("Block:", receipt.blockNumber);
  console.log("Gas used:", receipt.gasUsed.toString());
  
  return receipt;
}
```

## 代码示例

### 完整示例脚本

创建文件 `test-paymaster-v4.js`:

```javascript
require("dotenv").config();
const { ethers } = require("ethers");

// 配置
const SEPOLIA_RPC_URL = process.env.SEPOLIA_RPC_URL;
const OWNER_PRIVATE_KEY = process.env.PRIVATE_KEY;
const SIMPLE_ACCOUNT = process.env.SIMPLE_ACCOUNT || "0x94FC9B8B7cAb56C01f20A24E37C2433FCe88A10D";

const CONTRACTS = {
  ENTRYPOINT: "0x0000000071727De22E5E9d8BAf0edAc6f37da032",
  PAYMASTER_V4: "0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445",
  PNT_TOKEN: "0xD14E87d8D8B69016Fcc08728c33799bD3F66F180",
};

const RECIPIENT = "0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA";

async function main() {
  // 初始化
  const provider = new ethers.JsonRpcProvider(SEPOLIA_RPC_URL);
  const signer = new ethers.Wallet(OWNER_PRIVATE_KEY, provider);

  console.log("=== PaymasterV4 测试交易 ===");
  console.log("Signer:", signer.address);
  console.log("SimpleAccount:", SIMPLE_ACCOUNT);
  console.log("PaymasterV4:", CONTRACTS.PAYMASTER_V4);

  // 1. 检查余额和授权
  const pntABI = [
    "function balanceOf(address) external view returns (uint256)",
    "function allowance(address owner, address spender) external view returns (uint256)",
    "function transfer(address to, uint256 amount) external returns (bool)",
  ];
  const pnt = new ethers.Contract(CONTRACTS.PNT_TOKEN, pntABI, provider);
  
  const balance = await pnt.balanceOf(SIMPLE_ACCOUNT);
  const allowance = await pnt.allowance(SIMPLE_ACCOUNT, CONTRACTS.PAYMASTER_V4);
  
  console.log("\n余额检查:");
  console.log("- PNT Balance:", ethers.formatUnits(balance, 18), "PNT");
  console.log("- PNT Allowance:", ethers.formatUnits(allowance, 18), "PNT");
  
  if (balance < ethers.parseUnits("10", 18)) {
    throw new Error("PNT 余额不足 (需要 >= 10 PNT)");
  }
  
  if (allowance < ethers.parseUnits("10", 18)) {
    throw new Error("PNT 授权不足 (需要先授权给 PaymasterV4)");
  }

  // 2. 构造 UserOperation
  const accountABI = [
    "function execute(address dest, uint256 value, bytes calldata func) external",
    "function getNonce() public view returns (uint256)",
  ];
  const account = new ethers.Contract(SIMPLE_ACCOUNT, accountABI, provider);
  
  const nonce = await account.getNonce();
  const transferAmount = ethers.parseUnits("0.5", 18);
  const transferCalldata = pnt.interface.encodeFunctionData("transfer", [
    RECIPIENT,
    transferAmount,
  ]);
  const executeCalldata = account.interface.encodeFunctionData("execute", [
    CONTRACTS.PNT_TOKEN,
    0,
    transferCalldata,
  ]);

  // Gas 配置
  const latestBlock = await provider.getBlock("latest");
  const baseFeePerGas = latestBlock.baseFeePerGas || ethers.parseUnits("0.001", "gwei");
  const maxPriorityFeePerGas = ethers.parseUnits("0.1", "gwei");
  const maxFeePerGas = baseFeePerGas + maxPriorityFeePerGas + ethers.parseUnits("0.001", "gwei");

  const accountGasLimits = ethers.concat([
    ethers.zeroPadValue(ethers.toBeHex(300000n), 16),
    ethers.zeroPadValue(ethers.toBeHex(100000n), 16),
  ]);

  const gasFees = ethers.concat([
    ethers.zeroPadValue(ethers.toBeHex(maxPriorityFeePerGas), 16),
    ethers.zeroPadValue(ethers.toBeHex(maxFeePerGas), 16),
  ]);

  const paymasterAndData = ethers.concat([
    CONTRACTS.PAYMASTER_V4,
    ethers.zeroPadValue(ethers.toBeHex(200000n), 16),
    ethers.zeroPadValue(ethers.toBeHex(100000n), 16),
    CONTRACTS.PNT_TOKEN,
  ]);

  const userOp = {
    sender: SIMPLE_ACCOUNT,
    nonce: nonce,
    initCode: "0x",
    callData: executeCalldata,
    accountGasLimits: accountGasLimits,
    preVerificationGas: 100000n,
    gasFees: gasFees,
    paymasterAndData: paymasterAndData,
    signature: "0x",
  };

  console.log("\nUserOperation 配置:");
  console.log("- Nonce:", nonce.toString());
  console.log("- PaymasterAndData 长度:", paymasterAndData.length, "bytes");

  // 3. 签名
  const entryPointABI = [
    "function handleOps((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature)[] ops, address payable beneficiary) external",
    "function getUserOpHash((address sender, uint256 nonce, bytes initCode, bytes callData, bytes32 accountGasLimits, uint256 preVerificationGas, bytes32 gasFees, bytes paymasterAndData, bytes signature) userOp) external view returns (bytes32)",
  ];
  const entryPoint = new ethers.Contract(CONTRACTS.ENTRYPOINT, entryPointABI, signer);
  
  const userOpHash = await entryPoint.getUserOpHash(userOp);
  const signingKey = new ethers.SigningKey(OWNER_PRIVATE_KEY);
  const signature = signingKey.sign(userOpHash).serialized;
  userOp.signature = signature;

  console.log("- UserOpHash:", userOpHash);

  // 4. 提交
  console.log("\n提交 UserOperation...");
  const tx = await entryPoint.handleOps([userOp], signer.address, {
    gasLimit: 1000000n,
  });
  
  console.log("✅ 交易已提交!");
  console.log("Transaction hash:", tx.hash);
  console.log("Etherscan:", `https://sepolia.etherscan.io/tx/${tx.hash}`);

  const receipt = await tx.wait();
  console.log("\n✅ 交易确认!");
  console.log("Block:", receipt.blockNumber);
  console.log("Gas used:", receipt.gasUsed.toString());
  console.log("Status:", receipt.status === 1 ? "Success" : "Failed");

  // 5. 检查最终余额
  const finalBalance = await pnt.balanceOf(SIMPLE_ACCOUNT);
  console.log("\n最终余额:", ethers.formatUnits(finalBalance, 18), "PNT");
  console.log("PNT 消耗:", ethers.formatUnits(balance - finalBalance, 18), "PNT");
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
```

### 环境配置

创建 `.env` 文件:

```bash
SEPOLIA_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_API_KEY
PRIVATE_KEY=0xyour_private_key_here
SIMPLE_ACCOUNT=0xyour_simple_account_address
```

### 运行测试

```bash
node test-paymaster-v4.js
```

## 验证步骤

### 1. 前置检查

```bash
# 检查 PNT 余额
cast call $PNT_TOKEN "balanceOf(address)(uint256)" $SIMPLE_ACCOUNT --rpc-url $SEPOLIA_RPC_URL

# 检查 PNT 授权
cast call $PNT_TOKEN "allowance(address,address)(uint256)" $SIMPLE_ACCOUNT $PAYMASTER_V4 --rpc-url $SEPOLIA_RPC_URL

# 检查 SBT 余额 (如账户已部署)
cast call $SBT_TOKEN "balanceOf(address)(uint256)" $SIMPLE_ACCOUNT --rpc-url $SEPOLIA_RPC_URL
```

### 2. 授权 PNT (🔴 必需步骤!)

⚠️ **这是最容易被忽略的步骤！如果不授权，会得到 `AA33 reverted 0x8a7638fa` 错误**

#### 方法 1: 通过 SimpleAccount 授权 (推荐)

```bash
# 设置变量
SIMPLE_ACCOUNT="0x你的SimpleAccount地址"
PNT_TOKEN="0xD14E87d8D8B69016Fcc08728c33799bD3F66F180"
PAYMASTER_V4="0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445"
PRIVATE_KEY="0x你的私钥"
SEPOLIA_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY"

# 通过 SimpleAccount 授权 PNT (授权无限额度)
cast send $SIMPLE_ACCOUNT \
  "execute(address,uint256,bytes)" \
  $PNT_TOKEN \
  0 \
  $(cast calldata "approve(address,uint256)" $PAYMASTER_V4 $(cast max-uint)) \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

#### 方法 2: 如果是 EOA (普通地址)

```bash
# 直接授权
cast send $PNT_TOKEN \
  "approve(address,uint256)" \
  $PAYMASTER_V4 \
  $(cast max-uint) \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

#### 验证授权成功

```bash
# 检查授权额度
cast call $PNT_TOKEN \
  "allowance(address,address)(uint256)" \
  $SIMPLE_ACCOUNT \
  $PAYMASTER_V4 \
  --rpc-url $SEPOLIA_RPC_URL

# 应该返回一个很大的数字，而不是 0
# 例如: 115792089237316195423570985008687907853269984665640564039457584007913129639935
```

### 3. 验证 PaymasterV4 配置

```bash
# 检查 PaymasterV4 参数
cast call $PAYMASTER_V4 "gasToUSDRate()(uint256)" --rpc-url $SEPOLIA_RPC_URL
cast call $PAYMASTER_V4 "pntPriceUSD()(uint256)" --rpc-url $SEPOLIA_RPC_URL
cast call $PAYMASTER_V4 "serviceFeeRate()(uint256)" --rpc-url $SEPOLIA_RPC_URL

# 检查 token 支持
cast call $PAYMASTER_V4 "isGasTokenSupported(address)(bool)" $PNT_TOKEN --rpc-url $SEPOLIA_RPC_URL
cast call $PAYMASTER_V4 "isSBTSupported(address)(bool)" $SBT_TOKEN --rpc-url $SEPOLIA_RPC_URL
```

### 4. 提交交易并验证

```bash
# 运行测试脚本
node test-paymaster-v4.js

# 在 Etherscan 查看交易
# https://sepolia.etherscan.io/tx/<transaction_hash>

# 验证事件日志
# 查找 UserOperationEvent
# 查找 Transfer 事件 (PNT token 转账)
```

## 常见问题

### Q1: 交易失败 "AA33 reverted 0x8a7638fa" (最常见 ⚠️)

**错误含义**: `PaymasterV4__InsufficientPNT()` - PNT 不足或未授权

**原因**: 
1. SimpleAccount 未授权 PNT 给 PaymasterV4 (最常见!)
2. PNT 余额 < 20 PNT

**诊断**:
```bash
# 检查授权 (重要!)
cast call 0xD14E87d8D8B69016Fcc08728c33799bD3F66F180 \
  "allowance(address,address)(uint256)" \
  YOUR_ACCOUNT \
  0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445 \
  --rpc-url $SEPOLIA_RPC_URL

# 如果返回 0，说明没有授权！
```

**解决**: 
- 方案 1: 按照上面的 "2. 授权 PNT" 步骤授权
- 方案 2: 访问 https://gastoken-faucet.vercel.app 领取 PNT (会自动处理)
- 详细修复指南: [PAYMASTER_V4_QUICK_FIX.md](./PAYMASTER_V4_QUICK_FIX.md)

### Q2: 交易失败 "AA31 paymaster deposit too low"
**原因**: PaymasterV4 在 EntryPoint 中的 deposit 不足  
**解决**: 联系 Paymaster 运营者增加 deposit

### Q3: 交易失败 "Insufficient balance"
**原因**: SimpleAccount 的 PNT 余额不足  
**解决**: 访问 https://gastoken-faucet.vercel.app 领取 100 PNT

### Q4: 交易失败 "SBT required"
**原因**: 已部署账户没有 SBT  
**解决**: Mint 一个 SBT 给 SimpleAccount

### Q5: Gas 估算不准确
**原因**: Gas 市场波动  
**解决**: 增加 gas 限制或等待 gas 价格降低

## 参考资料

- [ERC-4337 规范](https://eips.ethereum.org/EIPS/eip-4337)
- [EntryPoint v0.7 实现](https://github.com/eth-infinitism/account-abstraction/tree/v0.7.0)
- [PaymasterV4 设计文档](/design/SuperPaymasterV3/PaymasterV4-Final-Design.md)
- [PaymasterV4 实现总结](/design/SuperPaymasterV3/PaymasterV4-Implementation-Complete.md)
- [测试总结](../deployments/paymaster-v4-test-summary.md)

## 已部署测试交易

### 参考交易

- **Approval**: https://sepolia.etherscan.io/tx/0x32939e656dc96bfd27e488e106941298137bffc31905fd591b7ebe984a25109d
- **UserOp**: https://sepolia.etherscan.io/tx/0xe269a765e682669ff23829598f5a32642ecbf6e13825d912c1c968454de42302

### 交易参数

```javascript
// 实际使用的参数
const actualParams = {
  sender: "0x94FC9B8B7cAb56C01f20A24E37C2433FCe88A10D",
  nonce: 15n,
  verificationGasLimit: 300000n,
  callGasLimit: 100000n,
  preVerificationGas: 100000n,
  paymasterVerificationGasLimit: 200000n,
  paymasterPostOpGasLimit: 100000n,
  maxFeePerGas: "0.10100005 gwei",
  maxPriorityFeePerGas: "0.1 gwei",
  paymasterAndData: "0xbc56d82374c3cdf1234fa67e28af9d3e31a9d44500000000000000000000000000030d40000000000000000000000000000186a0090e34709a592210158aa49a969e4a04e3a29ebd",
  gasUsed: 193356n,
  pntSpent: "19.04360918 PNT",
};
```

---

**文档版本**: 1.0  
**最后更新**: 2025-10-07  
**网络**: Sepolia Testnet  
**PaymasterV4**: 0xBC56D82374c3CdF1234fa67E28AF9d3E31a9D445
