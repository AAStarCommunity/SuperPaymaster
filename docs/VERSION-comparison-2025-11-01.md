# VERSION对比报告

**生成时间**: 2025-11-01
**检查网络**: Sepolia Testnet (Chain ID: 11155111)

## 📊 总体状态

| 状态 | 合约数量 | 说明 |
|------|---------|------|
| ✅ 已部署且有VERSION | 2 | MySBT (2.3.3), PaymasterV4_1 (1.1.0) |
| ❌ 已部署但无VERSION | 7 | 需要重新部署 |
| 🔄 VERSION不匹配 | 1 | MySBT (链上2.3.3 vs 本地2.4.0) |
| **总计** | **10** | **8个合约需要重新部署** |

---

## 🔍 详细对比

### 1. 核心系统 (Core System)

| 合约 | 地址 | 链上VERSION | 本地VERSION | 状态 | 操作 |
|------|------|------------|------------|------|------|
| **GTokenStaking** | `0xDAD0EC96335f88A5A38aAd838daD4FE541744C2a` | ❌ 无VERSION | ✅ 2.0.0 | 🔄 需重新部署 | 部署新版本 |
| **SuperPaymasterV2** | `0x50c4Daf685170aa29513BA6dd89B8417b5b0FE4a` | ❌ 无VERSION | ✅ 2.0.0 | 🔄 需重新部署 | 部署新版本 |
| **Registry** | `0xd8f50dcF723Fb6d0Ec555691c3a19E446a3bb765` | ❌ 无VERSION | ✅ 2.1.3 | 🔄 需重新部署 | 部署新版本 |
| **GToken** | `0x868F843723a98c6EECC4BF0aF3352C53d5004147` | ❌ 无VERSION | ⚠️ Mock合约 | ⏭️ 跳过 | 测试用Mock，不需要VERSION |

**核心系统变更说明：**
- **GTokenStaking v2.0.0**: User-level slash + 1:1 shares model
- **SuperPaymasterV2 v2.0.0**: AOA+ mode shared paymaster
- **Registry v2.1.3**: 新增 `transferCommunityOwnership` 功能

---

### 2. Token系统 (Token System)

| 合约 | 地址 | 链上VERSION | 本地VERSION | 状态 | 操作 |
|------|------|------------|------------|------|------|
| **xPNTsFactory** | `0xC2AFEA0F736403E7e61D3F7C7c6b4E5E63B5cab6` | ❌ 无VERSION | ✅ 2.0.0 | 🔄 需重新部署 | 部署新版本 |
| **MySBT** | `0x3cE0AB2a85Dc4b2B1976AA924CF8047F7afA9324` | ✅ 2.3.3 | ✅ 2.4.0 | ⚠️ VERSION不匹配 | 升级到v2.4.0 |
| **aPNTs (xPNTsToken)** | `0xD11527ae56B6543a679e50408BE4aeE0f418ef9f` | ❌ 无VERSION | ✅ 2.0.0 | 🔄 需重新部署 | 通过新Factory部署 |

**Token系统变更说明：**
- **xPNTsFactory v2.0.0**: 添加VERSION接口
- **MySBT v2.4.0**: 链上是v2.3.3，本地更新到v2.4.0 (新增burnSBT功能)
- **xPNTsToken v2.0.0**: aPNTs通过新Factory重新部署

**注意**: aPNTs作为AAStar社区的底层gas token，重新部署后需要：
1. 迁移用户余额（如有）
2. 更新SuperPaymaster的aPNTs地址配置
3. 更新所有operator的aPNTs授权

---

### 3. Paymaster系统 (AOA Mode)

| 合约 | 地址 | 链上VERSION | 本地VERSION | 状态 | 操作 |
|------|------|------------|------------|------|------|
| **PaymasterV4_1** | `0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38` | ✅ "PaymasterV4.1-Registry-v1.1.0" | ✅ v1.1.0 | ✅ 已同步 | 无需操作 |

**PaymasterV4_1功能说明：**
- 相比V4新增: `deactivateFromRegistry()` 支持从Registry注销
- VERSION方法使用小写 `version()` 而非 `VERSION()`
- 独立Paymaster，用于AOA模式（非AOA+）

---

### 4. DVT/BLS监控系统 (Monitoring)

| 合约 | 地址 | 链上VERSION | 本地VERSION | 状态 | 操作 |
|------|------|------------|------------|------|------|
| **DVTValidator** | `0x8E03495A45291084A73Cee65B986f34565321fb1` | ❌ 无VERSION | ✅ 2.0.0 | 🔄 需重新部署 | 部署新版本 |
| **BLSAggregator** | `0xA7df6789218C5a270D6DF033979698CAB7D7b728` | ❌ 无VERSION | ✅ 2.0.0 | 🔄 需重新部署 | 部署新版本 |

**DVT系统变更说明：**
- **DVTValidator v2.0.0**: 添加VERSION接口，13个独立验证节点监控
- **BLSAggregator v2.0.0**: 添加VERSION接口，7/13 BLS签名聚合

---

## 📋 重新部署计划

### 阶段1: 基础层 (Foundation)
```bash
# 1. 重新部署 GTokenStaking v2.0.0
# 依赖: GToken (已存在)
# 后续依赖: MySBT, SuperPaymaster

# 2. 配置 GTokenStaking 的 lockers
# - MySBT: 平滑exit fee 0.1 sGT
# - SuperPaymaster: 分层exit fee (5-15 sGT)
```

### 阶段2: Token系统 (Token System)
```bash
# 3. 升级 MySBT 到 v2.4.0
# 依赖: GTokenStaking (新部署)
# 变更: 新增 burnSBT 退出机制

# 4. 重新部署 xPNTsFactory v2.0.0
# 依赖: SuperPaymaster (待部署), Registry (待部署)
```

### 阶段3: 核心系统 (Core System)
```bash
# 5. 重新部署 Registry v2.1.3
# 依赖: 无
# 变更: transferCommunityOwnership 功能

# 6. 重新部署 SuperPaymasterV2 v2.0.0
# 依赖: GTokenStaking (新部署), Registry (新部署)
# 配置: 设置DVT aggregator, EntryPoint
```

### 阶段4: 监控系统 (Monitoring)
```bash
# 7. 重新部署 DVTValidator v2.0.0
# 依赖: SuperPaymaster (新部署), BLSAggregator (待部署)

# 8. 重新部署 BLSAggregator v2.0.0
# 依赖: SuperPaymaster (新部署), DVTValidator (新部署)
```

### 阶段5: 社区Token (Community Tokens)
```bash
# 9. 通过新 xPNTsFactory 重新部署 aPNTs
# 名称: "AAStar Points"
# 符号: "aPNT"
# 汇率: 1:1 with system aPNTs
# 依赖: xPNTsFactory (新部署), SuperPaymaster (新部署)
```

---

## 🔧 部署后配置

### 1. GTokenStaking 配置
```solidity
// 配置 lockers
gTokenStaking.configureLocker(mySBT, 0.1 ether, [0,0,0,0,0], address(0));
gTokenStaking.configureLocker(superPaymaster, 5 ether, [5,8,10,12,15], address(0));
gTokenStaking.setTreasury(treasuryAddress);
gTokenStaking.setSuperPaymaster(superPaymasterAddress);
```

### 2. SuperPaymaster 配置
```solidity
// 设置依赖
superPaymaster.setDVTAggregator(blsAggregatorAddress);
superPaymaster.setEntryPoint(entryPointV07);
```

### 3. DVT/BLS 配置
```solidity
// 互相设置
dvtValidator.setBLSAggregator(blsAggregatorAddress);

// 注册验证节点 (7-13个)
dvtValidator.registerValidator(validatorAddr, blsPublicKey, nodeURI);
blsAggregator.registerBLSPublicKey(validatorAddr, blsPublicKey);
```

### 4. MySBT 配置
```solidity
// 设置 SuperPaymaster 关联
mySBT.setSuperPaymaster(superPaymasterAddress);
```

---

## 📦 Shared-Config 更新

部署完成后，需要更新 `@aastar/shared-config` 中的合约地址：

```typescript
// src/contracts.ts
export const SEPOLIA_CONTRACTS = {
  core: {
    superPaymasterV2: '0x[新地址]',  // v2.0.0
    registry: '0x[新地址]',          // v2.1.3
    gToken: '0x868F843723a98c6EECC4BF0aF3352C53d5004147', // 保持不变
    gTokenStaking: '0x[新地址]',     // v2.0.0
  },
  tokens: {
    xPNTsFactory: '0x[新地址]',      // v2.0.0
    mySBT: '0x[新地址]',             // v2.4.0
    aPNTs: '0x[新地址]',             // v2.0.0 (新增)
  },
  monitoring: {
    dvtValidator: '0x[新地址]',      // v2.0.0
    blsAggregator: '0x[新地址]',     // v2.0.0
  },
  paymaster: {
    paymasterV4: '0x4D6A367aA183903968833Ec4AE361CFc8dDDBA38', // 保持不变
  },
};

// CONTRACT_METADATA 添加 aPNTs
export const CONTRACT_METADATA = {
  sepolia: {
    deploymentDates: {
      // ... existing ...
      aPNTs: '2025-11-01',  // 新增
    },
  },
};
```

---

## ⚠️ 风险与注意事项

### 高风险项
1. **GTokenStaking 重新部署**
   - 影响范围: 所有stake用户的数据迁移
   - 建议: 先在测试环境完整验证迁移脚本

2. **SuperPaymaster 重新部署**
   - 影响范围: 所有已注册operator需重新注册
   - 影响范围: 所有用户的aPNTs余额需迁移
   - 建议: 提前通知所有operator

3. **aPNTs 重新部署**
   - 影响范围: 所有持有aPNTs的用户
   - 建议: 实现代币迁移合约或快照空投

### 中风险项
4. **MySBT 升级**
   - v2.3.3 → v2.4.0 新增burnSBT功能
   - 影响范围: 所有持有SBT的用户
   - 建议: 向后兼容，旧SBT仍然有效

5. **DVT/BLS 重新部署**
   - 影响范围: 需要重新注册13个验证节点
   - 建议: 准备好所有validator的BLS密钥对

### 低风险项
6. **Registry 重新部署**
   - 新增 `transferCommunityOwnership` 功能
   - 影响范围: 已注册社区需重新注册
   - 建议: 批量迁移脚本

---

## 📝 VERSION管理规范

### 版本号格式
- **格式**: `major.medium.minor` (e.g., 2.1.3)
- **范围**:
  - major: 1-∞
  - medium: 1-10
  - minor: 1-100

### 升级规则
```solidity
// 小更新: 修复bug、优化gas、添加view函数
minor += 1  // 2.1.3 → 2.1.4

// 中等更新: 添加新功能、修改存储结构
medium += 1, minor = 0  // 2.1.3 → 2.2.0

// 大更新: 重大架构变更、不兼容升级
major += 1, medium = 0, minor = 0  // 2.1.3 → 3.0.0
```

### VERSION接口标准
```solidity
/// @notice Contract version string
string public constant VERSION = "2.0.0";

/// @notice Contract version code (major * 10000 + medium * 100 + minor)
uint256 public constant VERSION_CODE = 20000;
```

**注意**: PaymasterV4_1使用小写 `version()` 方法，其他合约使用大写 `VERSION` 常量。

---

## ✅ 验证清单

部署完成后，逐项验证：

### 合约部署验证
- [ ] GTokenStaking v2.0.0 部署成功，VERSION可查询
- [ ] SuperPaymasterV2 v2.0.0 部署成功，VERSION可查询
- [ ] Registry v2.1.3 部署成功，VERSION可查询
- [ ] xPNTsFactory v2.0.0 部署成功，VERSION可查询
- [ ] MySBT v2.4.0 部署成功，VERSION可查询
- [ ] DVTValidator v2.0.0 部署成功，VERSION可查询
- [ ] BLSAggregator v2.0.0 部署成功，VERSION可查询
- [ ] aPNTs v2.0.0 部署成功，VERSION可查询

### 配置验证
- [ ] GTokenStaking.lockers[MySBT] 配置正确
- [ ] GTokenStaking.lockers[SuperPaymaster] 配置正确
- [ ] SuperPaymaster.dvtAggregator 设置正确
- [ ] SuperPaymaster.entryPoint 设置正确
- [ ] DVTValidator.BLS_AGGREGATOR 设置正确
- [ ] BLSAggregator.DVT_VALIDATOR 设置正确
- [ ] MySBT.SUPERPAYMASTER 设置正确

### 功能验证
- [ ] GTokenStaking stake/unstake 功能正常
- [ ] SuperPaymaster operator注册功能正常
- [ ] Registry community注册功能正常
- [ ] xPNTsFactory deployxPNTsToken 功能正常
- [ ] MySBT mint/burn 功能正常
- [ ] DVTValidator registerValidator 功能正常
- [ ] BLSAggregator registerBLSPublicKey 功能正常

### 集成测试
- [ ] AOA模式交易测试（PaymasterV4_1 + xPNTs）
- [ ] AOA+模式交易测试（SuperPaymaster + aPNTs）
- [ ] DVT slash提案 + BLS聚合签名测试
- [ ] Community注册 + SBT mint + xPNTs部署 完整流程

---

## 🎯 下一步

1. **创建部署脚本**: 基于上述阶段1-5创建Forge脚本
2. **准备测试数据**: GToken余额、Stake数据、Operator列表
3. **执行部署**: 按阶段顺序部署并配置
4. **更新shared-config**: 更新所有新合约地址
5. **发布npm包**: `npm publish` 新版本@aastar/shared-config
6. **运行集成测试**: 执行AOA/AOA+完整流程测试

---

**报告生成者**: Claude Code
**最后更新**: 2025-11-01
