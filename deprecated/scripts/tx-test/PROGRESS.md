# 测试脚本开发进度

## ✅ 已完成

### 工具模块
- [x] `utils/config.js` - 配置和合约地址管理
- [x] `utils/logger.js` - 彩色日志输出工具
- [x] `utils/contract-checker.js` - 合约状态检查工具

### 准备脚本
- [x] `0-check-deployed-contracts.js` - 前置检查脚本
  - 检查核心合约部署状态
  - 检查 GToken 和 GTokenStaking 绑定
  - 检查 Locker 配置
  - 检查 SuperPaymasterV2 参数
  - 检查 xPNTs autoApprovedSpenders
  - 检查测试账户和资产余额
  - 检查运营方注册状态

- [x] `1-create-simple-accounts.js` - 创建 Simple Account
  - 使用 SimpleAccountFactory 创建 Account A/B/C
  - 智能检查：如果已存在则跳过
  - 验证 owner 配置

- [x] `2-setup-communities-and-xpnts.js` - 设置社区和 xPNTs
  - 注册 AAStar 社区到 Registry
  - 注册 BuilderDAO 社区到 Registry
  - 使用 xPNTsFactory 部署 aPNTs
  - 使用 xPNTsFactory 部署 bPNTs
  - 配置 autoApprovedSpenders
  - 自动更新 .env 文件

- [x] `3-mint-assets-to-accounts.js` - Mint 资产
  - Mint 1000 GToken 给 OWNER2 和 Account A/B/C
  - Mint 1 个 SBT 给 OWNER2
  - Mint 1000 aPNTs 给所有测试账户
  - Mint 1000 bPNTs 给所有测试账户
  - 智能检查：如果余额充足则跳过
  - 注意：Simple Account 的 SBT 需要特殊处理（UserOp）

### 测试脚本

- [x] `4-test-aoa-paymaster.js` - AOA 模式测试
  - 构建 UserOperation（Account A 向 B 转账 0.5 bPNTs）
  - 使用 PaymasterV4.1 支付 gas
  - OWNER2 签名 UserOp
  - 通过 EntryPoint.handleOps 执行
  - 验证结果：
    - Account A bPNTs 余额减少（转账 + gas fee）
    - Account B bPNTs 余额增加（转账金额）
    - PaymasterV4 treasury 收到 gas fee
    - Account A ETH 余额不变（gasless）
  - 解析事件和日志

- [x] `5-test-aoa-plus-paymaster.js` - AOA+ 模式测试
  - 构建 UserOperation（Account A 向 B 转账 0.5 aPNTs）
  - 使用 SuperPaymasterV2 支付 gas
  - OWNER2 签名 UserOp
  - 通过 EntryPoint.handleOps 执行
  - 验证结果：
    - Account A aPNTs 余额减少（转账 + gas fee）
    - Account B aPNTs 余额增加（转账金额）
    - Operator aPNTs 余额减少
    - SuperPaymaster treasury aPNTs 增加
    - Operator totalSpent 增加
    - Account A ETH 余额不变（gasless）
  - 解析事件和日志

### 辅助工具

- [x] `utils/userOp.js` - UserOperation 构建工具
  - 构建标准 UserOperation
  - 计算 userOpHash
  - EIP-191 签名
  - paymasterAndData 编码
  - 执行 UserOperation
  - 解析 UserOperationEvent

## 📝 关键技术要点

### UserOperation 结构（EntryPoint v0.7）
```javascript
{
  sender: address,           // Simple Account 地址
  nonce: uint256,           // 从 EntryPoint 获取
  initCode: bytes,          // 已部署为 "0x"
  callData: bytes,          // execute(dest, value, func)
  callGasLimit: uint256,
  verificationGasLimit: uint256,
  preVerificationGas: uint256,
  maxFeePerGas: uint256,
  maxPriorityFeePerGas: uint256,
  paymasterAndData: bytes,  // [paymaster(20)][xPNTs(20)][validUntil(6)][validAfter(6)]
  signature: bytes          // OWNER2 签名
}
```

### paymasterAndData 编码
```javascript
const paymasterAndData = ethers.concat([
  paymasterAddress,         // 20 bytes
  xPNTsAddress,            // 20 bytes
  ethers.zeroPadValue("0x", 6), // validUntil (6 bytes)
  ethers.zeroPadValue("0x", 6), // validAfter (6 bytes)
]);
```

### EIP-712 签名（Simple Account）
```javascript
const domain = {
  name: "SimpleAccount",
  version: "1",
  chainId: chainId,
  verifyingContract: accountAddress
};

const types = {
  UserOperation: [
    { name: "sender", type: "address" },
    { name: "nonce", type: "uint256" },
    // ... 其他字段
  ]
};

const signature = await signer.signTypedData(domain, types, userOp);
```

## 🔧 测试步骤（最终流程）

### 一次性设置（首次运行）
```bash
# 1. 检查合约部署状态
node scripts/tx-test/0-check-deployed-contracts.js

# 2. 创建 Simple Accounts（如需要）
node scripts/tx-test/1-create-simple-accounts.js

# 3. 设置社区和 xPNTs（如需要）
node scripts/tx-test/2-setup-communities-and-xpnts.js

# 4. Mint 测试资产
node scripts/tx-test/3-mint-assets-to-accounts.js

# 5. 再次检查确认
node scripts/tx-test/0-check-deployed-contracts.js
```

### 重复测试（已设置完成后）
```bash
# 测试 AOA 模式
node scripts/tx-test/4-test-aoa-paymaster.js

# 测试 AOA+ 模式
node scripts/tx-test/5-test-aoa-plus-paymaster.js
```

## 📊 当前状态

- **完成度**: 100% (10/10 文件) ✅
- **核心功能**: 准备阶段 ✅ | 测试阶段 ✅
- **状态**: 所有脚本开发完成，可以开始测试

---

**最后更新**: 2025-11-02
**负责人**: Claude Code
**版本**: v0.1-alpha
