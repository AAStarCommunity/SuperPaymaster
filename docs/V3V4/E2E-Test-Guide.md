# SuperPaymaster V3 E2E 测试指南

## 测试概述

本文档记录了 SuperPaymaster V3 的完整 E2E 测试流程,包括所有配置、步骤和遇到的问题。

## 合约部署地址 (Sepolia)

### 核心合约
- **EntryPoint v0.7**: `0x0000000071727De22E5E9d8BAf0edAc6f37da032` (官方)
- **SimpleAccountFactory v0.7**: `0x70F0DBca273a836CbA609B10673A52EED2D15625` (自部署)
- **PaymasterV3**: `0x1568da4ea1E2C34255218b6DaBb2458b57B35805`
- **Settlement**: `0x6Bbf0C72805ECd4305EfCCF579c32d6F6d3041d5`
- **PNT Token**: `0xf2996D81b264d071f99FD13d76D15A9258f4cFa9`
- **SBT (实际部署)**: `0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f` (PaymasterV3 当前配置)
- **SBT (测试使用)**: `0x6fC0a5d8bED193595abCbda5112a1cFd44a08F99`

### 测试账户
- **Owner**: `0x411BD567E46C0781248dbB6a9211891C032885e5`
- **SimpleAccount**: `0x94FC9B8B7cAb56C01f20A24E37C2433FCe88A10D` (salt: 0)
- **Recipient**: `0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA`

## 合约配置检查

### PaymasterV3 配置
```bash
# 检查配置
cast call 0x1568da4ea1E2C34255218b6DaBb2458b57B35805 "sbtContract()" --rpc-url $SEPOLIA_RPC_URL
# 应该返回: 0x6Fc0A5D8BeD193595aBCBDa5112a1cfD44a08f99

cast call 0x1568da4ea1E2C34255218b6DaBb2458b57B35805 "gasToken()" --rpc-url $SEPOLIA_RPC_URL
# 应该返回: 0xf2996D81b264d071f99FD13d76D15A9258f4cFa9

cast call 0x1568da4ea1E2C34255218b6DaBb2458b57B35805 "settlementContract()" --rpc-url $SEPOLIA_RPC_URL
# 应该返回: 0x6Bbf0C72805ECd4305EfCCF579c32d6F6d3041d5

cast call 0x1568da4ea1E2C34255218b6DaBb2458b57B35805 "minTokenBalance()" --rpc-url $SEPOLIA_RPC_URL
# 应该返回: 100 PNT (0x56bc75e2d63100000)
```

### EntryPoint Deposit/Stake 状态
```bash
cast call 0x0000000071727De22E5E9d8BAf0edAc6f37da032 "getDepositInfo(address)" 0x1568da4ea1E2C34255218b6DaBb2458b57B35805 --rpc-url $SEPOLIA_RPC_URL
# 返回: (deposit, staked, stake, unstakeDelaySec, withdrawTime)
# 当前: deposit=0.02 ETH, staked=true, stake=0.1 ETH, unstakeDelay=86400s
```

**注意**: 
- **Deposit**: 用于支付 gas 费用的余额
- **Stake**: 质押金额,用于满足 bundler 的安全要求
- 直接通过 bundler 提交需要 stake,直接调用 EntryPoint 不需要 stake

## 遇到的问题和解决方案

### 问题 1: EntryPoint v0.6 vs v0.7 不兼容
**错误**: 使用了 v0.6 的 SimpleAccountFactory
**解决**: 部署新的 SimpleAccountFactoryV07NoSenderCreator
- 去掉了 `senderCreator()` 函数(Sepolia EntryPoint 会 revert)
- 使用 CREATE2 确保地址确定性

### 问题 2: 签名验证失败
**错误**: 使用 `wallet.signMessage()` 导致签名包含 EIP-191 前缀
**解决**: 直接对 userOpHash 签名,不添加前缀
```javascript
// ❌ 错误方式
const signature = await wallet.signMessage(ethers.getBytes(userOpHash));

// ✅ 正确方式
const signingKey = new ethers.SigningKey(OWNER_PRIVATE_KEY);
const signature = signingKey.sign(userOpHash).serialized;
```

**原理**: SimpleAccount 的 `_validateSignature` 期望:
```solidity
ECDSA.recover(userOpHash, signature) == owner
```
如果使用 `signMessage()`,实际签名的是 `keccak256("\x19Ethereum Signed Message:\n32" + userOpHash)`,导致恢复的地址不匹配。

### 问题 3: PaymasterV3 配置错误
**错误**: PaymasterV3 的 `gasToken` 指向旧的 PNT 地址
**解决**: 更新 gasToken 配置
```bash
cast send 0x1568da4ea1E2C34255218b6DaBb2458b57B35805 \
  "setGasToken(address)" 0xf2996D81b264d071f99FD13d76D15A9258f4cFa9 \
  --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL
```

### 问题 4: Alchemy Bundler Gas 效率限制
**错误**: `Verification gas limit efficiency too low. Required: 0.4, Actual: 0.16671`
**原因**: Alchemy bundler 要求 `actualVerificationGas / totalActualGas >= 0.4`
**解决**: 绕过 bundler,直接调用 EntryPoint.handleOps()

## 完整测试步骤

### 前置准备

1. **部署 SimpleAccountFactory v0.7**
```bash
cd /Users/jason/Dev/mycelium/my-exploration/projects/gemini-minter/contracts
forge script script/DeploySimpleAccountFactoryV07.s.sol:DeploySimpleAccountFactoryV07 \
  --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
```
部署地址: `0x70F0DBca273a836CbA609B10673A52EED2D15625`

2. **计算 SimpleAccount 地址**
```javascript
const factoryInterface = new ethers.Interface(SimpleAccountFactoryABI);
const getAddressData = factoryInterface.encodeFunctionData('getAddress', [OWNER_ADDRESS, 0]);
const result = await provider.call({
  to: SIMPLE_ACCOUNT_FACTORY,
  data: getAddressData
});
const address = factoryInterface.decodeFunctionResult('getAddress', result)[0];
// 地址: 0x94FC9B8B7cAb56C01f20A24E37C2433FCe88A10D
```

3. **手动部署 SimpleAccount** (账户还未部署时)
```bash
cast send 0x70F0DBca273a836CbA609B10673A52EED2D15625 \
  "createAccount(address,uint256)" \
  0x411BD567E46C0781248dbB6a9211891C032885e5 0 \
  --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL
```

4. **准备测试资产**
```bash
# 转入 PNT
cast send 0xf2996D81b264d071f99FD13d76D15A9258f4cFa9 \
  "transfer(address,uint256)" \
  0x94FC9B8B7cAb56C01f20A24E37C2433FCe88A10D \
  400000000000000000000 \
  --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL

# Mint SBT
cast send 0x6Fc0A5D8BeD193595aBCBDa5112a1cfD44a08f99 \
  "mint(address,uint256)" \
  0x94FC9B8B7cAb56C01f20A24E37C2433FCe88A10D 1 \
  --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL

# 转入测试 ETH
cast send 0x94FC9B8B7cAb56C01f20A24E37C2433FCe88A10D \
  --value 0.1ether \
  --private-key $PRIVATE_KEY --rpc-url $SEPOLIA_RPC_URL
```

5. **添加 PaymasterV3 Stake** (可选,直接调用 EntryPoint 不需要)
```bash
node scripts/add-stake.js
# Stake: 0.1 ETH, Unstake Delay: 86400 seconds
```

### 执行测试

**方式 1: 直接通过 EntryPoint 提交** (推荐)
```bash
node scripts/submit-via-entrypoint.js
```

**方式 2: 通过 Alchemy Bundler 提交** (会遇到 gas 效率限制)
```bash
node scripts/e2e-test-v3.js
```

### 验证结果

```bash
node scripts/verify-e2e-result.js
```

预期结果:
- ✅ 交易成功执行
- ✅ SimpleAccount PNT 余额减少 0.5 PNT
- ✅ Recipient 收到 0.5 PNT
- ✅ PaymasterV3 赞助了 gas 费用
- ✅ Settlement 记录了 gas 消耗

## 成功案例

### 交易信息
- **交易哈希**: `0x5bcea0df573e1f1c02c60af5ed69404649b5039b17a3d3db61028193d607ad83`
- **区块**: 9354676
- **Gas Used**: 165,573
- **状态**: Success
- **浏览器**: https://sepolia.etherscan.io/tx/0x5bcea0df573e1f1c02c60af5ed69404649b5039b17a3d3db61028193d607ad83

### UserOperation 参数
```javascript
{
  sender: "0x94FC9B8B7cAb56C01f20A24E37C2433FCe88A10D",
  nonce: 0,
  initCode: "0x", // 账户已部署
  callData: "0xb61d27f6...", // execute(PNT, 0, transfer(recipient, 0.5 PNT))
  callGasLimit: 100000,
  verificationGasLimit: 300000,
  preVerificationGas: 100000,
  maxFeePerGas: "0.101 gwei",
  maxPriorityFeePerGas: "0.1 gwei",
  paymaster: "0x1568da4ea1E2C34255218b6DaBb2458b57B35805",
  paymasterVerificationGasLimit: 200000,
  paymasterPostOpGasLimit: 150000,
  paymasterData: "0x",
  signature: "0x7e5dbb4f..." // ECDSA signature of userOpHash
}
```

### 签名生成流程
```javascript
// 1. 构建 packed UserOp (用于计算 hash)
const packedUserOp = {
  sender: userOp.sender,
  nonce: userOp.nonce,
  initCode: "0x", // 已部署
  callData: userOp.callData,
  accountGasLimits: concat([verificationGasLimit(16bytes), callGasLimit(16bytes)]),
  preVerificationGas: userOp.preVerificationGas,
  gasFees: concat([maxPriorityFeePerGas(16bytes), maxFeePerGas(16bytes)]),
  paymasterAndData: concat([
    paymaster(20bytes),
    paymasterVerificationGasLimit(16bytes),
    paymasterPostOpGasLimit(16bytes),
    paymasterData
  ]),
  signature: "0x"
};

// 2. 通过 EntryPoint 计算 userOpHash
const userOpHash = await entryPoint.getUserOpHash(packedUserOp);

// 3. 直接对 userOpHash 签名 (不添加前缀)
const signingKey = new ethers.SigningKey(OWNER_PRIVATE_KEY);
const signature = signingKey.sign(userOpHash).serialized;

// 4. 更新 UserOp 签名
userOp.signature = signature;
```

## 重现测试步骤

### 1. 确保环境配置正确
```bash
cd /Users/jason/Dev/mycelium/my-exploration/projects/SuperPaymaster-Contract
source .env.v3
```

### 2. 检查合约配置
```bash
# 运行配置检查脚本
node scripts/check-config.js
```

### 3. 检查测试账户余额
```bash
# 检查 SimpleAccount 余额
cast call 0xf2996D81b264d071f99FD13d76D15A9258f4cFa9 \
  "balanceOf(address)" 0x94FC9B8B7cAb56C01f20A24E37C2433FCe88A10D \
  --rpc-url $SEPOLIA_RPC_URL | xargs cast to-dec
# 应该 >= 100 PNT (100000000000000000000)

# 检查 SBT
cast call 0x6Fc0A5D8BeD193595aBCBDa5112a1cfD44a08f99 \
  "balanceOf(address)" 0x94FC9B8B7cAb56C01f20A24E37C2433FCe88A10D \
  --rpc-url $SEPOLIA_RPC_URL | xargs cast to-dec
# 应该 >= 1
```

### 4. 执行测试
```bash
# 直接通过 EntryPoint 提交 (推荐)
node scripts/submit-via-entrypoint.js
```

### 5. 验证结果
```bash
# 手动检查余额变化
cast call 0xf2996D81b264d071f99FD13d76D15A9258f4cFa9 \
  "balanceOf(address)" 0x94FC9B8B7cAb56C01f20A24E37C2433FCe88A10D \
  --rpc-url $SEPOLIA_RPC_URL

cast call 0xf2996D81b264d071f99FD13d76D15A9258f4cFa9 \
  "balanceOf(address)" 0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA \
  --rpc-url $SEPOLIA_RPC_URL
```

## Alchemy Gas 效率问题

### 问题描述
Alchemy bundler 拒绝 UserOperation,报错:
```
Verification gas limit efficiency too low. Required: 0.4, Actual: 0.16671
```

### 根本原因分析

**问题本质**: Alchemy bundler 检测到 UserOp 的**实际 verification gas 使用量**与**总实际 gas 使用量**的比例过低。

**效率计算公式** (推测基于错误信息):
```
efficiency = actualVerificationGasUsed / totalActualGasUsed
```

其中 `totalActualGasUsed` 可能包括:
- actualVerificationGasUsed (账户验证 + paymaster 验证)
- actualCallGasUsed (实际调用执行)
- actualPaymasterPostOpGasUsed (paymaster 后置处理)

**为什么要求 >= 0.4**:
这是 Alchemy bundler 的安全策略,防止:
1. **Gas 估算滥用**: 防止攻击者设置极高的 verificationGasLimit 但实际使用很少,浪费 bundler 的 gas 预估资源
2. **DoS 攻击**: 防止恶意 UserOp 消耗 bundler 的计算资源
3. **经济效率**: 确保 bundler 处理的 UserOp 具有合理的 gas 使用效率

**我们的案例分析**:
- verificationGasLimit 设置: 300,000
- callGasLimit 设置: 100,000
- 实际效率: 0.16671

这意味着实际的 verification 阶段 gas 使用量远低于我们设置的限制,导致效率比例过低。

### 官方文档研究结果

查询了以下 Alchemy 官方资源:
- ✅ [How ERC-4337 Gas Estimation Works](https://www.alchemy.com/blog/erc-4337-gas-estimation)
- ✅ [Open Sourcing Rundler](https://www.alchemy.com/blog/open-sourcing-rundler)
- ✅ [Rundler GitHub](https://github.com/alchemyplatform/rundler)

**发现**:
- Rundler 使用二分查找优化 gas 估算,误差范围设为 1K gas
- 对于 verificationGasLimit,Rundler 调用 `simulateValidation` 并传递给 `eth_estimateGas`
- Rundler 会静态添加 10K gas 到 verificationGasLimit 以考虑 ETH deposit 转账
- **但没有找到关于 0.4 效率要求的公开文档**

这个 0.4 限制可能是:
1. Rundler 内部的未公开策略
2. Alchemy bundler 服务层面的限制
3. 针对特定网络或版本的动态调整

### 解决方案

#### 方案 1: 直接调用 EntryPoint (当前采用)
```javascript
// 绕过 bundler,直接提交到 EntryPoint
const tx = await entryPoint.handleOps([packedUserOp], beneficiary, {
  gasLimit: 1000000n
});
```

**优点**:
- ✅ 完全绕过 bundler 限制
- ✅ 测试灵活,可控性强
- ✅ 不受 bundler 策略变化影响

**缺点**:
- ⚠️  需要自己支付 gas 费用
- ⚠️  无法测试真实 bundler 环境
- ⚠️  生产环境仍需解决此问题

#### 方案 2: 使用 Alchemy Gas 估算 API
```javascript
const gasEstimate = await bundlerProvider.send("eth_estimateUserOperationGas", [
  userOpForRPC,
  ENTRYPOINT
]);

// 使用 bundler 返回的 gas 估算值
userOp.callGasLimit = BigInt(gasEstimate.callGasLimit);
userOp.verificationGasLimit = BigInt(gasEstimate.verificationGasLimit);
userOp.preVerificationGas = BigInt(gasEstimate.preVerificationGas);
```

**问题**: 即使使用 bundler 的估算值,仍然可能因为实际执行时的 gas 使用量与估算不符而失败。

#### 方案 3: 优化合约逻辑减少 callGas
如果 verification 阶段本身的 gas 消耗是合理的,可以通过减少 call 阶段的 gas 消耗来提高效率比:
- 简化 execute 调用逻辑
- 减少不必要的存储操作
- 优化 Paymaster 的 postOp 逻辑

#### 方案 4: 使用其他 Bundler 服务
考虑使用其他 bundler 服务(如 Pimlico, Stackup)进行测试,它们可能有不同的验证策略。

### 生产环境建议

**短期**:
- 使用直接调用 EntryPoint 的方式进行测试和验证
- 记录实际的 gas 使用情况
- 与 Alchemy 技术支持联系,询问具体的效率要求和优化建议

**长期**:
- 优化 SimpleAccount 和 PaymasterV3 的 gas 消耗
- 实现自己的 bundler 服务(基于 Rundler)
- 或适配多个 bundler 服务,避免单点依赖

## 下一步: Keeper 结算脚本

待实现功能:
1. 监听 Settlement 合约的 GasConsumed 事件
2. 批量处理用户 gas 债务
3. 从用户 PNT 余额中扣除相应费用
4. 转账给 Paymaster owner

脚本位置: `scripts/keeper-settlement.js`
