# Operator注册指南

**目标**: 为SuperPaymasterV2_3注册Operator

---

## 📋 Operator信息

### Operator账号
```
地址: 0x411BD567E46C0781248dbB6a9211891C032885e5
```

**请给此地址打50 GT（GToken）**

### 注册参数

| 参数 | 值 | 说明 |
|------|-----|------|
| Registry | 0xfc1d62e41a86b11cF19Ce2C0B610bE8D58A5aa4F | Registry v2.2.1 |
| SuperPaymasterV2_3 | 0xb89011D7a86E5BBf816A66c9CB30d005D9243b1b | 已部署 |
| NodeType | 1 (PAYMASTER_SUPER) | 需要50 GT stake |
| xPNTsToken | 0x70Da2c1B7Fcf471247Bc3B09f8927a4ab1751Ba3 | bPNT (Bread Points) |
| SBT | 0xD1e6BDfb907EacD26FF69a40BBFF9278b1E7Cf5C | MySBT |

---

## 🔄 注册流程

### 方式1: 通过Registry自动注册（推荐）

**步骤1**: 给Operator地址打GT
```
接收地址: 0x411BD567E46C0781248dbB6a9211891C032885e5
需要数量: 50 GT
```

**步骤2**: 运行自动注册脚本
```bash
bash scripts/deploy/register-operator-via-registry.sh
```

此脚本会：
1. ✅ 检查GT余额
2. ✅ Approve Registry合约
3. ✅ 调用`registerCommunityWithAutoStake`
4. ✅ 自动stake + lock + register

**步骤3**: 验证注册
```bash
# 检查Registry注册状态
cast call 0xfc1d62e41a86b11cF19Ce2C0B610bE8D58A5aa4F \
  "isRegistered(address)(bool)" \
  0x411BD567E46C0781248dbB6a9211891C032885e5 \
  --rpc-url $SEPOLIA_RPC_URL
```

---

### 方式2: 手动分步注册

如果自动脚本失败，可以手动执行：

#### 2.1 检查GT余额
```bash
cast call 0x36b699a921fc792119D84f1429e2c00a38c09f7f \
  "balanceOf(address)(uint256)" \
  0x411BD567E46C0781248dbB6a9211891C032885e5 \
  --rpc-url $SEPOLIA_RPC_URL
```

#### 2.2 Approve Registry
```bash
cast send 0x36b699a921fc792119D84f1429e2c00a38c09f7f \
  "approve(address,uint256)" \
  0xfc1d62e41a86b11cF19Ce2C0B610bE8D58A5aa4F \
  50000000000000000000 \
  --private-key $PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL \
  --legacy
```

#### 2.3 调用registerCommunityWithAutoStake
```bash
# 构造CommunityProfile:
# (name, ensName, xPNTsToken, supportedSBTs[], nodeType, paymasterAddress, ...)

cast send 0xfc1d62e41a86b11cF19Ce2C0B610bE8D58A5aa4F \
  'registerCommunityWithAutoStake((string,string,address,address[],uint8,address,address,uint256,uint256,bool,bool),uint256)' \
  "(SuperPaymaster V2.3 Operator,,0x70Da2c1B7Fcf471247Bc3B09f8927a4ab1751Ba3,[0xD1e6BDfb907EacD26FF69a40BBFF9278b1E7Cf5C],1,0xb89011D7a86E5BBf816A66c9CB30d005D9243b1b,0x0000000000000000000000000000000000000000,0,0,false,false)" \
  50000000000000000000 \
  --private-key $PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL \
  --legacy
```

---

## 🔍 Registry合约接口

### registerCommunityWithAutoStake

```solidity
function registerCommunityWithAutoStake(
    CommunityProfile memory profile,
    uint256 stakeAmount
) external nonReentrant
```

**CommunityProfile结构**:
```solidity
struct CommunityProfile {
    string name;                    // "SuperPaymaster V2.3 Operator"
    string ensName;                 // "" (可选)
    address xPNTsToken;            // 0x70Da2c1B7Fcf471247Bc3B09f8927a4ab1751Ba3 (bPNT)
    address[] supportedSBTs;       // [0xD1e6BDfb907EacD26FF69a40BBFF9278b1E7Cf5C]
    NodeType nodeType;             // 1 (PAYMASTER_SUPER)
    address paymasterAddress;      // 0xb89011D7a86E5BBf816A66c9CB30d005D9243b1b
    address community;             // 0x0 (会被设为msg.sender)
    uint256 registeredAt;          // 0 (会被设为block.timestamp)
    uint256 lastUpdatedAt;         // 0 (会被设为block.timestamp)
    bool isActive;                 // false (会被设为true)
    bool allowPermissionlessMint;  // false (会被设为true)
}
```

**功能**:
1. 检查用户是否已注册
2. 验证stake数量 ≥ minStake
3. 自动stake（如果需要）: `_autoStakeForUser()`
4. Lock stake: `GTOKEN_STAKING.lockStake()`
5. 注册community
6. 更新索引和mapping

---

## ✅ 验证清单

注册完成后，验证以下内容：

### Registry验证
```bash
# 1. 检查isRegistered
cast call 0xfc1d62e41a86b11cF19Ce2C0B610bE8D58A5aa4F \
  "isRegistered(address)(bool)" \
  0x411BD567E46C0781248dbB6a9211891C032885e5 \
  --rpc-url $SEPOLIA_RPC_URL

# 2. 检查community profile
cast call 0xfc1d62e41a86b11cF19Ce2C0B610bE8D58A5aa4F \
  "communities(address)" \
  0x411BD567E46C0781248dbB6a9211891C032885e5 \
  --rpc-url $SEPOLIA_RPC_URL

# 3. 检查stake状态
cast call 0xfc1d62e41a86b11cF19Ce2C0B610bE8D58A5aa4F \
  "communityStakes(address)" \
  0x411BD567E46C0781248dbB6a9211891C032885e5 \
  --rpc-url $SEPOLIA_RPC_URL
```

### 预期结果
- ✅ `isRegistered` = true
- ✅ `communities[operator].name` = "SuperPaymaster V2.3 Operator"
- ✅ `communities[operator].isActive` = true
- ✅ `communityStakes[operator].stGTokenLocked` = 50000000000000000000 (50 GT)
- ✅ `communityStakes[operator].isActive` = true

---

## 🔗 下一步

### 1. 在SuperPaymasterV2_3中注册operator

Registry注册完成后，还需要在SuperPaymasterV2_3合约中注册：

```bash
bash scripts/deploy/register-operator-in-paymaster.sh
```

或手动执行：
```bash
# registerOperator(stGTokenAmount, xPNTsToken, treasury)
cast send 0xb89011D7a86E5BBf816A66c9CB30d005D9243b1b \
  "registerOperator(uint256,address,address)" \
  50000000000000000000 \
  0x70Da2c1B7Fcf471247Bc3B09f8927a4ab1751Ba3 \
  0x411BD567E46C0781248dbB6a9211891C032885e5 \
  --private-key $PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL \
  --legacy
```

### 2. 测试updateOperatorXPNTsToken

```bash
bash scripts/deploy/test-update-xpnt.sh
```

### 3. 运行Gasless交易测试

```bash
cd scripts/gasless-test
node test-gasless-viem-v2-final.js
```

---

## 📊 NodeType配置

| NodeType | 名称 | minStake | slashThreshold | slashBase | slashMax |
|----------|------|----------|----------------|-----------|----------|
| 0 | PAYMASTER_AOA | 30 GT | 10 | 2% | 10% |
| **1** | **PAYMASTER_SUPER** | **50 GT** | **10** | **2%** | **10%** |
| 2 | ANODE | 20 GT | 15 | 1% | 5% |
| 3 | KMS | 100 GT | 5 | 5% | 20% |

我们使用 **PAYMASTER_SUPER** (NodeType=1)

---

## ⚠️  注意事项

1. **GT余额**: 确保operator地址有≥50 GT
2. **Approve**: 必须先approve Registry合约才能stake
3. **重复注册**: Registry会检查`isRegistered`防止重复
4. **Stake要求**: PAYMASTER_SUPER类型需要最少50 GT
5. **Auto-stake**: Registry会自动处理stake和lock逻辑

---

## 🛠️  故障排查

### 问题1: GT余额不足
**错误**: `InsufficientGTokenBalance`
**解决**: 给operator地址打至少50 GT

### 问题2: 已注册
**错误**: `CommunityAlreadyRegistered`
**解决**: 该地址已在Registry注册，无需重复注册

### 问题3: Stake不足
**错误**: `InsufficientStake`
**解决**: PAYMASTER_SUPER需要至少50 GT

### 问题4: Approve失败
**错误**: Transfer amount exceeds allowance
**解决**:
```bash
# 重新approve
cast send 0x36b699a921fc792119D84f1429e2c00a38c09f7f \
  "approve(address,uint256)" \
  0xfc1d62e41a86b11cF19Ce2C0B610bE8D58A5aa4F \
  50000000000000000000 \
  --private-key $PRIVATE_KEY \
  --rpc-url $SEPOLIA_RPC_URL
```

---

## 📝 总结

**Operator地址**: `0x411BD567E46C0781248dbB6a9211891C032885e5`

**需要准备**:
- ✅ 50 GT （打到operator地址）
- ✅ Operator私钥（approve和注册）

**执行命令**:
```bash
# 一键注册
bash scripts/deploy/register-operator-via-registry.sh
```

**验证**:
```bash
# 检查注册状态
cast call 0xfc1d62e41a86b11cF19Ce2C0B610bE8D58A5aa4F \
  "isRegistered(address)(bool)" \
  0x411BD567E46C0781248dbB6a9211891C032885e5 \
  --rpc-url $SEPOLIA_RPC_URL
```

---

**文档版本**: v1.0
**创建日期**: 2025-11-19
**更新日期**: 2025-11-19
