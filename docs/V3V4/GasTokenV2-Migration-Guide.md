# GasTokenV2 Migration Guide

## 概述

GasTokenV2 是 GasToken 的增强版本,主要改进是将 `settlement/paymaster` 地址从 **immutable** 改为 **可更新**。

## 主要改进

### V1 (GasToken) 的限制
```solidity
address public immutable settlement;  // ❌ 无法修改
```

一旦部署,settlement 地址永久固定,无法切换到新的 Paymaster 合约。

### V2 (GasTokenV2) 的改进
```solidity
address public paymaster;  // ✅ 可以更新

function setPaymaster(address _newPaymaster) external onlyOwner {
    // Owner 可以随时切换 Paymaster
}
```

## 核心功能对比

| 功能 | V1 (GasToken) | V2 (GasTokenV2) |
|------|---------------|-----------------|
| 自动 approve | ✅ | ✅ |
| Mint 时自动 approve | ✅ | ✅ |
| Transfer 时自动 approve | ✅ | ✅ |
| 防止用户撤销 approve | ✅ | ✅ |
| Settlement/Paymaster 地址 | ❌ immutable | ✅ 可更新 |
| 批量重新 approve | ❌ | ✅ |
| Exchange Rate | ✅ | ✅ |

## 使用场景

### 场景 1: 从 V3 Settlement 迁移到 V4 Paymaster

**问题**: 已部署的 GasToken V1 绑定了 V3 Settlement,无法使用 V4 Paymaster

**解决方案**: 使用 GasTokenV2
```bash
# 1. 部署新的 GasTokenV2,初始 paymaster 为 V4
node scripts/deploy-gastokenv2.js

# 2. 用户可以继续使用旧 V1 token (通过 V3 Settlement)
# 3. 新用户使用 V2 token (通过 V4 Paymaster)
```

### 场景 2: Paymaster 升级

**问题**: PaymasterV4 有 bug,需要部署 PaymasterV5

**V1 的做法**:
```bash
# ❌ 必须部署新的 GasToken,所有用户重新迁移
```

**V2 的做法**:
```solidity
// ✅ Owner 直接更新 paymaster 地址
token.setPaymaster(PAYMASTER_V5);

// 现有持币者下次 transfer 时自动 re-approve
// 或者 Owner 主动批量 re-approve
token.batchReapprove([user1, user2, user3, ...]);
```

## 部署步骤

### 1. 部署 GasTokenFactoryV2

```bash
# 使用部署脚本
node scripts/deploy-gastokenv2.js
```

输出示例:
```
🚀 Deploying GasTokenV2 System...

📦 Step 1: Deploying GasTokenFactoryV2...
  ✅ GasTokenFactoryV2: 0x...

📦 Step 2: Creating GasTokenV2...
  ✅ GasTokenV2: 0x...

📦 Step 3: Minting Test Tokens...
  ✅ Minted: 1000 PNTv2
  Balance: 1000 PNTv2
  Auto-Approval: ✅ MAX
```

### 2. 验证自动 approve 功能

```bash
node scripts/test-gastokenv2-approval.js <TOKEN_ADDRESS>
```

测试内容:
- ✅ Mint 时自动 approve
- ✅ Transfer 时自动 approve
- ✅ 用户无法撤销 paymaster approve
- ✅ Owner 可以更新 paymaster

### 3. 注册到 PaymasterV4

```bash
# 使用 cast 或 ethers.js
cast send $PAYMASTER_V4 \
  "addSupportedGasToken(address)" \
  $GASTOKEN_V2 \
  --private-key $PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL
```

## 更新 Paymaster 的完整流程

### 步骤 1: 部署新 Paymaster

```bash
# 假设你部署了 PaymasterV5
PAYMASTER_V5="0x..."
```

### 步骤 2: 更新 GasTokenV2 的 paymaster 地址

```javascript
const token = new ethers.Contract(GASTOKEN_V2, ABI, wallet);

// 更新 paymaster
const tx = await token.setPaymaster(PAYMASTER_V5);
await tx.wait();

console.log("✅ Paymaster updated to:", PAYMASTER_V5);
```

### 步骤 3: 重新 approve (可选)

**方式 A: 自动重新 approve (推荐)**
- 用户下次 transfer token 时,自动 re-approve 到新 paymaster
- 无需 gas 开销,无需用户操作

**方式 B: 批量重新 approve**
```javascript
// Owner 主动批量更新
const holders = [user1, user2, user3, ...];
const tx = await token.batchReapprove(holders);
await tx.wait();

console.log("✅ Batch re-approved for", holders.length, "holders");
```

### 步骤 4: 在新 Paymaster 中注册 GasToken

```bash
cast send $PAYMASTER_V5 \
  "addSupportedGasToken(address)" \
  $GASTOKEN_V2 \
  --private-key $PRIVATE_KEY
```

## 代码示例

### 更新 Paymaster

```javascript
const { ethers } = require("ethers");

async function updatePaymaster(tokenAddress, newPaymasterAddress) {
  const provider = new ethers.JsonRpcProvider(RPC_URL);
  const wallet = new ethers.Wallet(PRIVATE_KEY, provider);
  
  const token = new ethers.Contract(tokenAddress, [
    "function setPaymaster(address) external",
    "function paymaster() external view returns (address)"
  ], wallet);
  
  // 更新前
  const oldPaymaster = await token.paymaster();
  console.log("Old Paymaster:", oldPaymaster);
  
  // 更新
  const tx = await token.setPaymaster(newPaymasterAddress);
  await tx.wait();
  
  // 更新后
  const newPaymaster = await token.paymaster();
  console.log("New Paymaster:", newPaymaster);
}
```

### 批量重新 approve

```javascript
async function batchReapprove(tokenAddress, holders) {
  const token = new ethers.Contract(tokenAddress, [
    "function batchReapprove(address[]) external"
  ], wallet);
  
  // 批量更新
  const tx = await token.batchReapprove(holders);
  await tx.wait();
  
  console.log(`✅ Re-approved ${holders.length} holders`);
}
```

## 安全考虑

### 1. Owner 权限
- ✅ 只有 Owner 可以调用 `setPaymaster()`
- ✅ 只有 Owner 可以调用 `batchReapprove()`
- ⚠️  Owner 需要妥善保管私钥

### 2. Paymaster 验证
```solidity
// 建议在 setPaymaster 中添加验证
function setPaymaster(address _newPaymaster) external onlyOwner {
    require(_newPaymaster != address(0), "Zero address");
    require(_newPaymaster.code.length > 0, "Not a contract");  // 可选
    
    // ... rest of the code
}
```

### 3. 用户保护
- ✅ 用户无法撤销对 paymaster 的 approve
- ✅ Transfer 时自动 re-approve,无需用户操作
- ✅ 即使 paymaster 更新,也不影响用户余额

## 常见问题

### Q1: V1 和 V2 可以共存吗?
**A**: 可以。V1 和 V2 是独立的合约,可以同时使用。

### Q2: 更新 paymaster 后,现有用户的 approve 会失效吗?
**A**: 会失效。但用户下次 transfer 时会自动 re-approve,或者 Owner 可以主动批量 re-approve。

### Q3: 用户可以自己撤销 paymaster 的 approve 吗?
**A**: 不可以。GasTokenV2 的 `approve()` 函数阻止用户减少对 paymaster 的 approve。

### Q4: 如何从 V1 迁移到 V2?
**A**: 
1. 部署新的 GasTokenV2
2. 用户逐步迁移(swap V1 for V2)
3. V1 和 V2 可以共存一段时间

### Q5: PaymasterV4 需要修改代码支持 V2 吗?
**A**: 不需要。V2 完全兼容 V4 的接口,只需注册为支持的 GasToken 即可。

## 部署清单

- [ ] 部署 GasTokenFactoryV2
- [ ] 通过 Factory 创建 GasTokenV2
- [ ] 测试自动 approve 功能
- [ ] 注册到 PaymasterV4
- [ ] Mint 初始代币
- [ ] 更新文档和配置
- [ ] (可选) 设置 multi-sig owner

## 相关文件

- 合约: `src/GasTokenV2.sol`
- 工厂: `src/GasTokenFactoryV2.sol`
- 部署脚本: `scripts/deploy-gastokenv2.js`
- 测试脚本: `scripts/test-gastokenv2-approval.js`
- 原始合约: `src/GasToken.sol` (V1)

## 总结

GasTokenV2 解决了 V1 的最大痛点:**无法更新 settlement/paymaster 地址**。

主要优势:
1. ✅ **灵活性**: Paymaster 可以随时更新
2. ✅ **兼容性**: 完全兼容现有 PaymasterV4
3. ✅ **用户友好**: 自动 approve,无需用户额外操作
4. ✅ **安全性**: 用户无法撤销 approve,保证系统正常运行

建议:
- 新项目直接使用 GasTokenV2
- 现有项目逐步迁移到 V2
- Owner 使用 multi-sig 钱包管理更新权限
