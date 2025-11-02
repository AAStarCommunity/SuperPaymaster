# 修复总结 - 2025年11月

## 已完成的修复和改进

### 1. ✅ Registry前端修复

**问题**: `getSuperPaymasterAddress`函数返回错误地址
```typescript
// 修复前（错误）
return networkConfig.contracts.paymasterV4;

// 修复后（正确）
return networkConfig.contracts.superPaymasterV2;
```

**文件**: `registry/src/pages/operator/DeployWizard.tsx`

### 2. ✅ 移除硬编码地址

**修复**: Registry中Step4_DeployResources.tsx不再硬编码合约地址
```typescript
// 现在从shared-config动态获取
const networkConfig = getCurrentNetworkConfig();
const MYSBT_ADDRESS = networkConfig.contracts.mySBT;
const XPNTS_FACTORY_ADDRESS = networkConfig.contracts.xPNTsFactory;
const GTOKEN_ADDRESS = networkConfig.contracts.gToken;
const GTOKEN_STAKING_ADDRESS = networkConfig.contracts.gTokenStaking;
```

### 3. ✅ 私钥安全修复

**问题**: 私钥被硬编码在文档和脚本中

**修复**:
- 从测试文档中移除所有私钥
- 脚本现在从`env/.env`文件读取私钥
- 添加私钥缺失检查

### 4. ✅ 更新合约地址引用

所有脚本现在使用`@aastar/shared-config`动态获取地址：

```javascript
const { getCoreContracts, getTokenContracts, getTestTokenContracts } = require("@aastar/shared-config");
const core = getCoreContracts('sepolia');
const tokens = getTokenContracts('sepolia');
const testTokens = getTestTokenContracts('sepolia');
```

## 新创建的脚本

### 测试准备脚本

1. **scripts/test-prepare-assets.js**
   - 验证所有配置
   - 检查token所有权
   - 验证汇率设置
   - 检查预授权状态

2. **scripts/mint-tokens.js**
   - Mint GToken, aPNTs, bPNTs
   - 支持owner转账fallback

3. **scripts/test-aoa-transaction.js**
   - 测试PaymasterV4_1 (AOA模式)
   - 使用bPNTs作为gas token
   - 完整的验证和状态检查

4. **scripts/test-aoa-plus-transaction.js**
   - 测试SuperPaymasterV2 (AOA+模式)
   - 使用aPNTs作为gas token
   - 验证operator状态

## 关键地址更新 (v0.2.10)

| 合约 | 旧地址 | 新地址 (shared-config) |
|------|--------|---------------------|
| SuperPaymasterV2 | 0x50c4Daf685... | 0x95B20d8FdF1... |
| MySBT | 0xc1085841307... | 0x73E635Fc9eD3... |
| GToken | 多个不一致 | 0x99cCb70646Be7... |
| aPNTs | 未定义 | 0xBD0710596010... |
| bPNTs | 未定义 | 0xF223660d24c4... |

## 测试流程

### 准备阶段
```bash
# 1. 验证配置
node scripts/test-prepare-assets.js

# 2. Mint所需tokens
node scripts/mint-tokens.js

# 3. Stake GToken (如需要)
node scripts/stake-gtoken.js

# 4. Mint SBT (如需要)
node scripts/mint-sbt.js
```

### 测试执行
```bash
# AOA模式测试 (PaymasterV4_1 + bPNTs)
node scripts/test-aoa-transaction.js

# AOA+模式测试 (SuperPaymasterV2 + aPNTs)
node scripts/test-aoa-plus-transaction.js
```

## 重要说明

### xPNTs架构理解
- **xPNTsFactory**: 工厂合约，用于部署社区gas token
- **aPNTs**: AAStar社区的gas token实例
- **bPNTs**: BuilderDAO社区的gas token实例
- 每个社区可以通过xPNTsFactory部署自己的token

### 私钥管理
- 所有私钥必须存储在`env/.env`文件中
- 永远不要在代码或文档中硬编码私钥
- 使用环境变量：
  - `DEPLOYER_PRIVATE_KEY`: 部署者私钥
  - `OWNER2_PRIVATE_KEY`: 测试账户owner私钥

### 依赖版本
- `@aastar/shared-config`: ^0.2.9 (建议升级到0.2.10)
- `ethers`: ^6.15.0

## 待办事项

- [ ] 升级SuperPaymaster的shared-config到v0.2.10
- [ ] 创建stake-gtoken.js脚本
- [ ] 创建mint-sbt.js脚本
- [ ] 添加operator注册脚本
- [ ] 添加自动化测试套件

## 注意事项

1. **合约版本一致性**: 确保所有项目使用相同版本的shared-config
2. **私钥安全**: 永远不要提交私钥到git
3. **地址验证**: 运行测试前先执行test-prepare-assets.js验证
4. **Token所有权**: 确保有正确的私钥来mint tokens

---
*更新时间: 2025年11月*
*作者: Claude Code Assistant*