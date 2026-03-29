# SuperPaymaster V2.3.3 开发者集成指南

> 最后更新: 2025-11-25
> 适用版本: SuperPaymasterV2 v2.3.3 / MySBT v2.4.5 / EntryPoint v0.7

本指南详细说明如何集成SuperPaymaster实现gasless交易。

---

## 前置知识

在开始之前，建议了解以下概念:

- **ERC-4337**: 账户抽象标准 ([EIP-4337](https://eips.ethereum.org/EIPS/eip-4337))
- **EntryPoint**: ERC-4337 的核心合约，处理 UserOperation
- **Paymaster**: 代付 gas 费用的合约
- **Bundler**: 将 UserOperation 打包上链的服务
- **AA Account**: 智能合约钱包 (如 SimpleAccount)

### 参考资料

- [EIP-4337 规范](https://eips.ethereum.org/EIPS/eip-4337)
- [Alchemy Bundler 文档](https://www.alchemy.com/docs/wallets/transactions/low-level-infra/bundler/overview)
- [data-relation.md](./data-relation.md) - 合约数据关系

---

## 目录

1. [快速开始](#一快速开始)
2. [合约检查](#二合约检查)
3. [依赖初始化检查](#三依赖初始化检查)
4. [获取测试资产](#四获取测试资产)
5. [交易前资产检查](#五交易前资产检查)
6. [PaymasterAndData构建](#六paymasteranddata构建)
7. [UserOperation组装](#七useroperation组装)
8. [签名](#八签名)
9. [交易提交](#九交易提交)
10. [交易验证](#十交易验证)
11. [错误处理](#十一错误处理)

---

## 一、快速开始

### 安装依赖

```bash
npm install @aastar/shared-config viem
```

### 最小示例

```typescript
import { createPublicClient, http } from 'viem';
import { sepolia } from 'viem/chains';

const SUPER_PAYMASTER = '0x7c3c355d9aa4723402bec2a35b61137b8a10d5db';

const client = createPublicClient({
  chain: sepolia,
  transport: http('YOUR_RPC_URL')
});

// 检查Paymaster是否就绪
const deposit = await client.readContract({
  address: SUPER_PAYMASTER,
  abi: [{ type: 'function', name: 'getDeposit', outputs: [{type: 'uint256'}] }],
  functionName: 'getDeposit'
});
console.log('Paymaster ETH deposit:', Number(deposit) / 1e18, 'ETH');
```

---

## 二、合约检查

### 2.1 使用 @aastar/shared-config 获取合约地址

```typescript
import { getContracts, getV2ContractByName } from '@aastar/shared-config';

const contracts = getContracts('sepolia');
console.log('SuperPaymaster:', contracts.core.superPaymasterV2);
console.log('Registry:', contracts.core.registry);
console.log('aPNTs:', contracts.tokens.aPNTs);

// 获取版本信息
const pmInfo = getV2ContractByName('SuperPaymasterV2');
console.log(`Version: ${pmInfo.version} (${pmInfo.versionCode})`);
```

### 2.2 验证链上版本一致性

```bash
# 使用 cast 验证链上版本
cast call 0x7c3c355d9aa4723402bec2a35b61137b8a10d5db \
  "VERSION()(string)" --rpc-url $SEPOLIA_RPC_URL
# Expected: "2.3.3"

cast call 0x7c3c355d9aa4723402bec2a35b61137b8a10d5db \
  "VERSION_CODE()(uint256)" --rpc-url $SEPOLIA_RPC_URL
# Expected: 20303
```

### 2.3 合约地址表 (Sepolia)

| 合约 | 地址 | 版本 |
|------|------|------|
| SuperPaymasterV2 | `0x7c3c355d9aa4723402bec2a35b61137b8a10d5db` | 2.3.3 |
| MySBT | `0xa4eda5d023ea94a60b1d4b5695f022e1972858e7` | 2.4.5 |
| Registry | `0x49245E1f3c2dD99b3884ffeD410d0605Cf4dC696` | 2.2.1 |
| GTokenStaking | `0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0` | 2.0.1 |
| GToken | `0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc` | 2.0.0 |
| aPNTs | `0xBD0710596010a157B88cd141d797E8Ad4bb2306b` | - |
| EntryPoint v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | 0.7 |

### 2.4 导入 ABI

```typescript
import SuperPaymasterV2ABI from '@aastar/shared-config/src/abis/SuperPaymasterV2.json';
import MySBTABI from '@aastar/shared-config/src/abis/MySBT.json';
import RegistryABI from '@aastar/shared-config/src/abis/Registry.json';
```

---

## 三、依赖初始化检查

在执行 gasless 交易前，需确认以下依赖已正确初始化:

### 3.1 xPNTsFactory Pre-Approve

xPNTsFactory 部署的代币内置了 pre-approve 机制:

```typescript
// 检查 SuperPaymaster 是否有无限授权
const allowance = await client.readContract({
  address: XPNTS_TOKEN,
  abi: [{ type: 'function', name: 'allowance', inputs: [{type: 'address'}, {type: 'address'}], outputs: [{type: 'uint256'}] }],
  functionName: 'allowance',
  args: [userAddress, SUPER_PAYMASTER]
});
// xPNTsFactory 部署的代币应返回 MaxUint256
```

### 3.2 SuperPaymaster 首绑 aPNTs Token

```typescript
const aPNTsToken = await client.readContract({
  address: SUPER_PAYMASTER,
  abi: [{ type: 'function', name: 'aPNTsToken', outputs: [{type: 'address'}] }],
  functionName: 'aPNTsToken'
});
// Expected: 0xBD0710596010a157B88cd141d797E8Ad4bb2306b
```

### 3.3 GTokenStaking Locker 配置

GToken Staking 需要配置 SuperPaymaster 和 Registry 为 locker:

```typescript
// 检查 locker 配置
const lockerConfig = await client.readContract({
  address: GTOKEN_STAKING,
  abi: [{ type: 'function', name: 'lockerConfigs', inputs: [{type: 'address'}], outputs: [{type: 'bool'}] }],
  functionName: 'lockerConfigs',
  args: [SUPER_PAYMASTER]
});
console.log('SuperPaymaster is locker:', lockerConfig);
```

### 3.4 合约依赖写入关系

| 操作 | 涉及合约 | 数据写入 |
|------|---------|---------|
| 用户铸造SBT | MySBT, GTokenStaking, SuperPaymaster | SBTData, lockStake, sbtHolders (callback) |
| 注册社区 | Registry, GTokenStaking | CommunityProfile, lockStake |
| 注册Operator | SuperPaymaster, GTokenStaking | OperatorAccount, lockStake |

---

## 四、获取测试资产

### 4.1 使用 Faucet (推荐)

访问 https://faucet.aastar.io 获取:
- GToken (治理代币)
- aPNTs (gas token)
- Sepolia ETH

### 4.2 API 路由

```bash
# 获取 GToken
curl "https://api.aastar.io/get-gtoken?address=YOUR_ADDRESS"

# 获取 SBT
curl "https://api.aastar.io/get-sbt?address=YOUR_ADDRESS"

# 获取 xPNTs
curl "https://api.aastar.io/get-xpnts?address=YOUR_ADDRESS&community=COMMUNITY"

# 注册社区
curl "https://api.aastar.io/register-community?address=YOUR_ADDRESS"
```

### 4.3 创建 AA 账户

```typescript
const SIMPLE_ACCOUNT_FACTORY = '0x9406Cc6185a346906296840746125a0E44976454';

// 计算 AA 账户地址 (无需实际部署)
const aaAddress = await client.readContract({
  address: SIMPLE_ACCOUNT_FACTORY,
  abi: [{ type: 'function', name: 'getAddress', inputs: [{type: 'address'}, {type: 'uint256'}], outputs: [{type: 'address'}] }],
  functionName: 'getAddress',
  args: [ownerEOA, 0n]  // salt = 0
});
```

### 4.4 铸造 SBT

```typescript
// 方式1: 社区调用 safeMint
await mysbt.safeMint(userAddress, communityAddress, 'metadata');

// 方式2: 用户自主铸造 (需社区开启 permissionlessMint)
await mysbt.userMint(communityAddress, 'metadata');
```

---

## 五、交易前资产检查

### 5.1 检查 Paymaster ETH 存款

**AOA模式 (PaymasterV4.1)**:
```typescript
// 自运营 Paymaster 需要自己在 EntryPoint 存款
const deposit = await client.readContract({
  address: MY_PAYMASTER,
  abi: [{ type: 'function', name: 'getDeposit', outputs: [{type: 'uint256'}] }],
  functionName: 'getDeposit'
});
if (deposit < 10000000000000000n) throw new Error('Deposit too low');
```

**AOA+模式 (SuperPaymasterV2)**:
```typescript
// SuperPaymaster 统一管理 EntryPoint 存款
const deposit = await client.readContract({
  address: SUPER_PAYMASTER,
  abi: [{ type: 'function', name: 'getDeposit', outputs: [{type: 'uint256'}] }],
  functionName: 'getDeposit'
});

// 还需检查 Operator 的 aPNTs 余额
const operatorAccount = await client.readContract({
  address: SUPER_PAYMASTER,
  abi: [{ type: 'function', name: 'accounts', inputs: [{type: 'address'}], outputs: [{type: 'uint256', name: 'aPNTsBalance'}] }],
  functionName: 'accounts',
  args: [OPERATOR]
});
```

### 5.2 检查用户 SBT

```typescript
// V2.3.3: 使用 SuperPaymaster 内部 SBT 注册表
const sbtHolder = await client.readContract({
  address: SUPER_PAYMASTER,
  abi: [{ type: 'function', name: 'sbtHolders', inputs: [{type: 'address'}], outputs: [{type: 'address'}, {type: 'uint256'}] }],
  functionName: 'sbtHolders',
  args: [AA_ACCOUNT]
});
if (sbtHolder[0] === '0x0000000000000000000000000000000000000000') {
  throw new Error('User does not have SBT');
}
```

### 5.3 检查用户 xPNTs 余额和授权

```typescript
const balance = await client.readContract({
  address: XPNTS_TOKEN,
  abi: [{ type: 'function', name: 'balanceOf', inputs: [{type: 'address'}], outputs: [{type: 'uint256'}] }],
  functionName: 'balanceOf',
  args: [AA_ACCOUNT]
});

const allowance = await client.readContract({
  address: XPNTS_TOKEN,
  abi: [{ type: 'function', name: 'allowance', inputs: [{type: 'address'}, {type: 'address'}], outputs: [{type: 'uint256'}] }],
  functionName: 'allowance',
  args: [AA_ACCOUNT, SUPER_PAYMASTER]
});
```

### 5.4 检查用户债务 (V2.3.3)

```typescript
const debt = await client.readContract({
  address: SUPER_PAYMASTER,
  abi: [{ type: 'function', name: 'getUserDebtByToken', inputs: [{type: 'address'}, {type: 'address'}], outputs: [{type: 'uint256'}] }],
  functionName: 'getUserDebtByToken',
  args: [AA_ACCOUNT, XPNTS_TOKEN]
});
if (debt > 0n) console.warn('User has outstanding debt:', debt);
```

---

## 六、PaymasterAndData 构建

### ERC-4337 v0.7 格式 (72 bytes)

```
┌──────────────┬──────────────────────┬──────────────────┬──────────────────┐
│  Paymaster   │ paymasterVerification │  paymasterPostOp │    Operator      │
│   (20 bytes) │    GasLimit (16)     │  GasLimit (16)   │    (20 bytes)    │
└──────────────┴──────────────────────┴──────────────────┴──────────────────┘
     [0:20]           [20:36]              [36:52]             [52:72]
```

### 构建代码

```typescript
import { concat, pad } from 'viem';

const SUPER_PAYMASTER = '0x7c3c355d9aa4723402bec2a35b61137b8a10d5db';
const OPERATOR = '0x411BD567E46C0781248dbB6a9211891C032885e5';

// V2.3.3 推荐的 gas 配置
const paymasterVerificationGas = 250000n; // 验证阶段: 只读操作
const paymasterPostOpGas = 50000n;        // postOp: transferFrom + 债务记录

const paymasterAndData = concat([
  SUPER_PAYMASTER,
  pad(`0x${paymasterVerificationGas.toString(16)}`, { dir: 'left', size: 16 }),
  pad(`0x${paymasterPostOpGas.toString(16)}`, { dir: 'left', size: 16 }),
  OPERATOR
]);
// 长度: 72 bytes
```

### Gas 配置说明

| 参数 | 推荐值 | 说明 |
|------|--------|------|
| paymasterVerificationGas | 250,000 | 验证阶段: 只读检查 SBT、余额、授权 |
| paymasterPostOpGas | 50,000 | PostOp: transferFrom + 债务记录 |

---

## 七、UserOperation 组装

### ERC-4337 v0.7 PackedUserOperation 结构

```typescript
interface PackedUserOperation {
  sender: Address;           // AA 账户地址
  nonce: bigint;             // 账户 nonce
  initCode: Hex;             // 初始化代码 (已部署时为 '0x')
  callData: Hex;             // 执行数据
  accountGasLimits: Hex;     // 打包的 gas 限制 (32 bytes)
  preVerificationGas: bigint;
  gasFees: Hex;              // 打包的 gas 价格 (32 bytes)
  paymasterAndData: Hex;     // Paymaster 数据 (72 bytes)
  signature: Hex;
}
```

### 组装代码

```typescript
import { encodeFunctionData, concat, pad, parseUnits } from 'viem';

// 1. 构建 callData
const transferCalldata = encodeFunctionData({
  abi: [{ type: 'function', name: 'transfer', inputs: [{type: 'address'}, {type: 'uint256'}] }],
  functionName: 'transfer',
  args: [RECIPIENT, parseUnits('1', 18)]
});

const executeData = encodeFunctionData({
  abi: [{ type: 'function', name: 'execute', inputs: [{type: 'address'}, {type: 'uint256'}, {type: 'bytes'}] }],
  functionName: 'execute',
  args: [TOKEN_ADDRESS, 0n, transferCalldata]
});

// 2. 获取 nonce
const nonce = await client.readContract({
  address: AA_ACCOUNT,
  abi: [{ type: 'function', name: 'getNonce', outputs: [{type: 'uint256'}] }],
  functionName: 'getNonce'
});

// 3. 打包 accountGasLimits (verificationGasLimit + callGasLimit)
const accountGasLimits = concat([
  pad(`0x${(90000).toString(16)}`, { dir: 'left', size: 16 }),  // 90k verification
  pad(`0x${(80000).toString(16)}`, { dir: 'left', size: 16 })   // 80k call
]);

// 4. 打包 gasFees (maxPriorityFeePerGas + maxFeePerGas)
const gasFees = concat([
  pad(`0x${(2000000000).toString(16)}`, { dir: 'left', size: 16 }),  // 2 gwei
  pad(`0x${(2000000000).toString(16)}`, { dir: 'left', size: 16 })
]);

// 5. 组装 UserOperation
const userOp = {
  sender: AA_ACCOUNT,
  nonce,
  initCode: '0x',
  callData: executeData,
  accountGasLimits,
  preVerificationGas: 21000n,
  gasFees,
  paymasterAndData,
  signature: '0x'
};
```

---

## 八、签名

### 8.1 获取 UserOpHash

```typescript
const userOpHash = await client.readContract({
  address: ENTRYPOINT,
  abi: [{
    type: 'function', name: 'getUserOpHash',
    inputs: [{ type: 'tuple', components: [
      {name: 'sender', type: 'address'},
      {name: 'nonce', type: 'uint256'},
      {name: 'initCode', type: 'bytes'},
      {name: 'callData', type: 'bytes'},
      {name: 'accountGasLimits', type: 'bytes32'},
      {name: 'preVerificationGas', type: 'uint256'},
      {name: 'gasFees', type: 'bytes32'},
      {name: 'paymasterAndData', type: 'bytes'},
      {name: 'signature', type: 'bytes'}
    ]}],
    outputs: [{type: 'bytes32'}]
  }],
  functionName: 'getUserOpHash',
  args: [userOp]
});
```

### 8.2 私钥签名 (测试环境)

```typescript
import { privateKeyToAccount } from 'viem/accounts';

const account = privateKeyToAccount(PRIVATE_KEY);
const signature = await account.signMessage({ message: { raw: userOpHash } });
userOp.signature = signature;
```

### 8.3 KMS 签名 (生产环境)

```typescript
import { KMSClient, SignCommand } from '@aws-sdk/client-kms';

const kms = new KMSClient({ region: 'us-east-1' });
const signCommand = new SignCommand({
  KeyId: 'alias/aa-signer',
  Message: userOpHash,
  MessageType: 'DIGEST',
  SigningAlgorithm: 'ECDSA_SHA_256'
});
const result = await kms.send(signCommand);
const signature = derToCompactSignature(result.Signature);
```

---

## 九、交易提交

### 9.1 直接提交到 EntryPoint

```typescript
const txHash = await walletClient.writeContract({
  address: ENTRYPOINT,
  abi: [{
    type: 'function', name: 'handleOps',
    inputs: [
      { type: 'tuple[]', components: [/* UserOperation fields */] },
      { name: 'beneficiary', type: 'address' }
    ]
  }],
  functionName: 'handleOps',
  args: [[userOp], account.address],
  gas: 2000000n
});
```

### 9.2 通过 Alchemy Bundler 提交 (推荐)

```typescript
// Bundler RPC URL (从 env 获取或使用 Alchemy Dashboard)
const BUNDLER_RPC_URL = process.env.BUNDLER_RPC_URL;

const response = await fetch(BUNDLER_RPC_URL, {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({
    jsonrpc: '2.0',
    id: 1,
    method: 'eth_sendUserOperation',
    params: [
      {
        sender: userOp.sender,
        nonce: `0x${userOp.nonce.toString(16)}`,
        initCode: userOp.initCode,
        callData: userOp.callData,
        accountGasLimits: userOp.accountGasLimits,
        preVerificationGas: `0x${userOp.preVerificationGas.toString(16)}`,
        gasFees: userOp.gasFees,
        paymasterAndData: userOp.paymasterAndData,
        signature: userOp.signature
      },
      ENTRYPOINT
    ]
  })
});

const result = await response.json();
console.log('UserOp hash:', result.result);
```

### Bundler 配置

参考: [Alchemy Bundler API](https://www.alchemy.com/docs/wallets/transactions/low-level-infra/bundler/overview/api-endpoints)

```bash
# .env
BUNDLER_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_API_KEY
```

---

## 十、交易验证

### 10.1 等待确认

```typescript
const receipt = await client.waitForTransactionReceipt({ hash: txHash });
console.log('Block:', receipt.blockNumber, 'Gas used:', receipt.gasUsed);
```

### 10.2 验证余额转账

```typescript
const balanceAfter = await client.readContract({
  address: XPNTS_TOKEN,
  abi: [{ type: 'function', name: 'balanceOf', inputs: [{type: 'address'}], outputs: [{type: 'uint256'}] }],
  functionName: 'balanceOf',
  args: [RECIPIENT]
});
console.log('Recipient balance:', balanceAfter);
```

### 10.3 验证 xPNTs 扣款 (用户)

```typescript
const userBalanceAfter = await client.readContract({
  address: XPNTS_TOKEN,
  abi: [{ type: 'function', name: 'balanceOf', inputs: [{type: 'address'}], outputs: [{type: 'uint256'}] }],
  functionName: 'balanceOf',
  args: [AA_ACCOUNT]
});
console.log('User xPNTs deducted:', userBalanceBefore - userBalanceAfter);
```

### 10.4 验证 aPNTs 扣款 (Operator/SuperPaymaster)

```typescript
const operatorAfter = await client.readContract({
  address: SUPER_PAYMASTER,
  abi: [{ type: 'function', name: 'accounts', inputs: [{type: 'address'}], outputs: [{type: 'uint256'}] }],
  functionName: 'accounts',
  args: [OPERATOR]
});
console.log('Operator aPNTs spent:', operatorBefore.aPNTsBalance - operatorAfter.aPNTsBalance);
```

---

## 十一、错误处理

### 常见错误码

| 错误 | 选择器 | 原因 | 解决方案 |
|------|--------|------|----------|
| `NoSBTFound` | `0x8eff01bd` | 用户没有SBT | 铸造 MySBT |
| `InsufficientAPNTsBalance` | - | Operator aPNTs不足 | Operator 充值 aPNTs |
| `OperatorNotRegistered` | - | Operator未注册 | 调用 registerOperator |
| `OperatorPaused` | - | Operator已暂停 | 选择其他 Operator |
| `InsufficientAllowance` | - | xPNTs授权不足 | approve xPNTs |
| `UserHasDebt` | - | 用户有未清债务 | 清理债务 |
| `AA21` | - | 账户不存在 | initCode 中包含部署数据 |

### 错误处理示例

```typescript
try {
  const txHash = await submitUserOperation(userOp);
} catch (error) {
  if (error.message.includes('0x8eff01bd')) {
    // 引导用户铸造 SBT
  } else if (error.message.includes('InsufficientAPNTsBalance')) {
    // 切换 Operator 或通知充值
  } else if (error.message.includes('AA21')) {
    // 需要在 initCode 中包含账户部署数据
  }
}
```

---

## 附录

### A. 完整配置清单

Gasless 交易前需完成以下配置:

```
✅ GTokenStaking: 配置 Registry 为 locker
✅ GTokenStaking: 配置 SuperPaymaster 为 locker
✅ SuperPaymaster: 设置 aPNTs token 地址
✅ MySBT: 设置 SuperPaymaster 回调地址
✅ 社区: 已在 Registry 注册 (质押 30-50 GT)
✅ Operator: 已在 SuperPaymaster 注册 (质押 30+ GT)
✅ Operator: 已存入 aPNTs 余额
✅ SuperPaymaster: 已在 EntryPoint 存入 ETH
✅ 用户: AA 账户已铸造 MySBT
✅ 用户: AA 账户已 approve xPNTs 给 Paymaster
```

### B. 测试账户

```
AA Account: 0x57b2e6f08399c276b2c1595825219d29990d0921
Operator:   0x411BD567E46C0781248dbB6a9211891C032885e5
```

### C. 成功交易示例

```
TX: 0x9ea5ca33fd7790a422cf27f2999d344f8a8f999beb5a15f03cd441ad07b494bb
Block: 9702293
Gas Used: 301,746
Transfer: 1 aPNTs (gasless)
Gas Fee: ~146.22 aPNTs
```

### D. 相关文档

- [data-relation.md](./data-relation.md) - 合约数据关系
- [@aastar/shared-config](https://www.npmjs.com/package/@aastar/shared-config)
- [ERC-4337 规范](https://eips.ethereum.org/EIPS/eip-4337)
- [Alchemy Bundler](https://www.alchemy.com/docs/wallets/transactions/low-level-infra/bundler/overview)

### E. 支持渠道

- GitHub: https://github.com/AAStar/SuperPaymaster-Contract/issues
- Discord: https://discord.gg/aastar
