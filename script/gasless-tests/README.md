# Gasless Transfer Test Cases

这个目录包含三个独立的 gasless transfer 测试脚本，用于测试不同的 paymaster 和 xPNTs token 组合。

## 测试目标

### Test Case 1: PaymasterV4 + xPNTs
- **Paymaster**: `0x0cf072952047bC42F43694631ca60508B3fF7f5e` (PaymasterV4)
- **Token**: `0x31a8c3046864F8aa7ADF0B3D3e16934F122Fe215` (xPNTs)
- **EntryPoint**: `0x0000000071727De22E5E9d8BAf0edAc6f37da032` (v0.7)

### Test Case 2: SuperPaymasterV2 + xPNTs1
- **Paymaster**: `0xD6aa17587737C59cbb82986Afbac88Db75771857` (SuperPaymasterV2)
- **Token**: `0xfb56CB85C9a214328789D3C92a496d6AA185e3d3` (xPNTs1)
- **EntryPoint**: `0x0000000071727De22E5E9d8BAf0edAc6f37da032` (v0.7)

### Test Case 3: SuperPaymasterV2 + xPNTs2
- **Paymaster**: `0xD6aa17587737C59cbb82986Afbac88Db75771857` (SuperPaymasterV2)
- **Token**: `0x311580CC1dF2dE49f9FCebB57f97c5182a57964f` (xPNTs2)
- **EntryPoint**: `0x0000000071727De22E5E9d8BAf0edAc6f37da032` (v0.7)

## 环境配置

所有测试脚本从 `/Volumes/UltraDisk/Dev2/aastar/env/.env` 读取配置：

- `SEPOLIA_RPC_URL`: Sepolia RPC endpoint
- `OWNER_PRIVATE_KEY` / `DEPLOYER_PRIVATE_KEY`: 发送者私钥
- `OWNER2_ADDRESS` / `TEST_EOA_ADDRESS`: 接收者地址
- `TEST_AA_ACCOUNT_ADDRESS_A/B/C`: SimpleAccount (AA) 地址
- `SIMPLE_ACCOUNT_A/B`: 备用 AA 地址

**重要**: 私钥和 RPC URL 不会被写入到 SuperPaymaster repo 中，所有敏感信息都从外部 env 文件读取。

## 运行测试

### 安装依赖

```bash
cd /Volumes/UltraDisk/Dev2/aastar/SuperPaymaster
npm install ethers dotenv
```

### 运行单个测试

```bash
# Test Case 1: PaymasterV4
node script/gasless-tests/test-case-1-paymasterv4.js

# Test Case 2: SuperPaymaster + xPNTs1
node script/gasless-tests/test-case-2-superpaymaster-xpnts1.js

# Test Case 3: SuperPaymaster + xPNTs2
node script/gasless-tests/test-case-3-superpaymaster-xpnts2.js
```

### 运行所有测试

```bash
./script/gasless-tests/run-all-tests.sh
```

## 测试流程

每个测试脚本执行以下步骤：

1. **配置加载**: 从 `/Volumes/UltraDisk/Dev2/aastar/env/.env` 读取配置
2. **余额检查**: 检查 AA 账户的 xPNTs token 余额
3. **构建 CallData**: 创建 ERC20 transfer 的 calldata
4. **构建 UserOperation**: 构建 EIP-4337 UserOperation 结构
5. **签名**: 使用 EOA 私钥签名 UserOperation
6. **提交**: 调用 EntryPoint.handleOps() 提交交易
7. **验证**: 确认交易并检查最终余额

## 注意事项

⚠️ **这是简化版测试脚本**

当前实现是简化版本，用于演示基本流程。生产环境应使用完整的 EIP-4337 库，如：
- `@account-abstraction/sdk`
- `userop`
- `permissionless.js`

这些库提供：
- 正确的 UserOperation 哈希计算（包含 EntryPoint 地址和 chainId）
- 完整的签名格式验证
- Gas 估算优化
- Paymaster 数据编码

## 测试结果

成功的 gasless 交易示例：
- Test TX 1: https://sepolia.etherscan.io/tx/0xc0768c124190199f19f359bd0bf57e84eda991a9b4b8d387e9399c7dc2d9c473
- Test TX 2: https://sepolia.etherscan.io/tx/0xcdc70a5d77ddf012793bfc9f2592e1cd4e983a46389e7e4a10ddb8db0fdfc40d

## 故障排查

### 常见错误

1. **"AA10 sender already constructed"**
   - 原因: SimpleAccount 未部署但 initCode 为空
   - 解决: 检查 AA 账户是否已部署

2. **"AA21 didn't pay prefund"**
   - 原因: Paymaster 余额不足
   - 解决: 向 Paymaster 在 EntryPoint 中充值

3. **"AA24 signature error"**
   - 原因: 签名格式不正确
   - 解决: 使用完整的 EIP-4337 哈希算法

4. **"AA30 paymaster not deployed"**
   - 原因: Paymaster 地址不存在
   - 解决: 验证 Paymaster 地址是否正确

## 目录结构

```
script/gasless-tests/
├── README.md                                   # 本文档
├── test-case-1-paymasterv4.js                 # Test 1: PaymasterV4 + xPNTs
├── test-case-2-superpaymaster-xpnts1.js       # Test 2: SuperPaymaster + xPNTs1
├── test-case-3-superpaymaster-xpnts2.js       # Test 3: SuperPaymaster + xPNTs2
└── run-all-tests.sh                           # 运行所有测试
```

## 参考资料

- [EIP-4337: Account Abstraction](https://eips.ethereum.org/EIPS/eip-4337)
- [EntryPoint v0.7 Documentation](https://docs.stackup.sh/docs/entrypoint-v07)
- [Account Abstraction GitHub](https://github.com/eth-infinitism/account-abstraction)
