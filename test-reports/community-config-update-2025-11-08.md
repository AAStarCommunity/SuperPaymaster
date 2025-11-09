# 社区配置更新报告

**日期**: 2025-11-08
**Registry**: v2.2.0 (`0x028aB52B4E0EF26820043ca4F1B5Fe14FfC1EF75`)

## 更新内容

为两个已注册的社区添加 xPNTs 代币和 MySBT 配置。

## 社区配置详情

### 1. AAstar Community ✅

| 配置项 | 值 |
|--------|-----|
| **地址** | `0x411BD567E46C0781248dbB6a9211891C032885e5` |
| **名称** | AAstar Community |
| **ENS** | aastar.eth |
| **Node Type** | PAYMASTER_SUPER (1) |
| **xPNTs Token** | `0xBD0710596010a157B88cd141d797E8Ad4bb2306b` (aPNTs) |
| **Supported SBTs** | [`0xD1e6BDfb907EacD26FF69a40BBFF9278b1E7Cf5C`] (MySBT) |
| **Stake** | 50 GT |
| **Active** | true |
| **Permissionless Mint** | true |

**特点**:
- 使用 SuperPaymaster v2 共享模式 (AOA+)
- 允许无许可 mint
- 适合大规模社区应用

### 2. Bread Community ✅

| 配置项 | 值 |
|--------|-----|
| **地址** | `0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA` |
| **名称** | Bread Community |
| **ENS** | bread.eth |
| **Node Type** | PAYMASTER_AOA (0) |
| **xPNTs Token** | `0x70Da2c1B7Fcf471247Bc3B09f8927a4ab1751Ba3` (bPNTs) |
| **Supported SBTs** | [`0xD1e6BDfb907EacD26FF69a40BBFF9278b1E7Cf5C`] (MySBT) |
| **Stake** | 50 GT |
| **Active** | true |
| **Permissionless Mint** | false |

**特点**:
- 使用独立 AOA Paymaster 模式
- 需要许可才能 mint
- 适合有管控需求的社区

## 更新前后对比

| 字段 | 更新前 | 更新后 |
|------|--------|--------|
| xPNTsToken | `0x0000...0000` (未设置) | AAstar: aPNTs, Bread: bPNTs |
| supportedSBTs.length | 0 | 1 (MySBT) |

## 执行脚本

**脚本位置**: `script/UpdateCommunityTokens.s.sol`

**执行命令**:
```bash
forge script script/UpdateCommunityTokens.s.sol:UpdateCommunityTokens \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  -vvv
```

**Gas 消耗**: ~347,277 gas (~0.00035 ETH)

## 链上验证

### AAstar Community

```bash
cast call 0x028aB52B4E0EF26820043ca4F1B5Fe14FfC1EF75 \
  "getCommunityProfile(address)" \
  0x411BD567E46C0781248dbB6a9211891C032885e5
```

**结果**:
- ✅ xPNTsToken: `0xBD0710596010a157B88cd141d797E8Ad4bb2306b`
- ✅ supportedSBTs[0]: `0xD1e6BDfb907EacD26FF69a40BBFF9278b1E7Cf5C`

### Bread Community

```bash
cast call 0x028aB52B4E0EF26820043ca4F1B5Fe14FfC1EF75 \
  "getCommunityProfile(address)" \
  0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA
```

**结果**:
- ✅ xPNTsToken: `0x70Da2c1B7Fcf471247Bc3B09f8927a4ab1751Ba3`
- ✅ supportedSBTs[0]: `0xD1e6BDfb907EacD26FF69a40BBFF9278b1E7Cf5C`

## shared-config 更新

### 版本

- **新版本**: v0.3.1
- **发布状态**: ✅ 已提交到 GitHub

### 新增内容

1. **communities.ts 模块**:
```typescript
export const AASTAR_COMMUNITY: CommunityConfig = {
  name: 'AAstar Community',
  ensName: 'aastar.eth',
  address: '0x411BD567E46C0781248dbB6a9211891C032885e5',
  xPNTsToken: '0xBD0710596010a157B88cd141d797E8Ad4bb2306b',
  supportedSBTs: ['0xD1e6BDfb907EacD26FF69a40BBFF9278b1E7Cf5C'],
  nodeType: NodeType.PAYMASTER_SUPER,
  isActive: true,
  allowPermissionlessMint: true,
  stakedAmount: '50',
  registeredAt: 1762588812,
};

export const BREAD_COMMUNITY: CommunityConfig = {
  name: 'Bread Community',
  ensName: 'bread.eth',
  address: '0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA',
  xPNTsToken: '0x70Da2c1B7Fcf471247Bc3B09f8927a4ab1751Ba3',
  supportedSBTs: ['0xD1e6BDfb907EacD26FF69a40BBFF9278b1E7Cf5C'],
  nodeType: NodeType.PAYMASTER_AOA,
  isActive: true,
  allowPermissionlessMint: false,
  stakedAmount: '50',
  registeredAt: 1762588812,
};
```

2. **Helper Functions**:
- `getCommunityConfig(address)` - 根据地址获取社区配置
- `getAllCommunityConfigs()` - 获取所有社区配置
- `isRegisteredCommunity(address)` - 检查是否为注册社区

3. **TEST_COMMUNITIES 更新**:
```typescript
export const TEST_COMMUNITIES = {
  aastar: '0x411BD567E46C0781248dbB6a9211891C032885e5',
  bread: '0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA',
  mycelium: '0x411BD567E46C0781248dbB6a9211891C032885e5', // Legacy alias
} as const;
```

### 使用示例

```typescript
import {
  AASTAR_COMMUNITY,
  BREAD_COMMUNITY,
  getCommunityConfig,
  NodeType
} from '@aastar/shared-config';

// 获取 AAstar 社区配置
const aastar = getCommunityConfig('0x411BD567E46C0781248dbB6a9211891C032885e5');
console.log(aastar?.xPNTsToken); // 0xBD0710596010a157B88cd141d797E8Ad4bb2306b

// 检查 node type
if (aastar?.nodeType === NodeType.PAYMASTER_SUPER) {
  console.log('使用 SuperPaymaster 共享模式');
}
```

## 测试结果

### ✅ 链上更新成功

- [x] AAstar Community xPNTsToken 设置为 aPNTs
- [x] Bread Community xPNTsToken 设置为 bPNTs
- [x] 两个社区都添加了 MySBT 作为 supportedSBTs
- [x] 社区状态保持 active

### ✅ shared-config 更新成功

- [x] 新建 communities.ts 模块
- [x] 导出类型和配置
- [x] 更新 TEST_COMMUNITIES
- [x] 构建成功
- [x] 提交到 GitHub

## 合约地址汇总

| 合约/Token | 地址 | 说明 |
|-----------|------|------|
| **Registry** | `0x028aB52B4E0EF26820043ca4F1B5Fe14FfC1EF75` | v2.2.0 |
| **MySBT** | `0xD1e6BDfb907EacD26FF69a40BBFF9278b1E7Cf5C` | v2.4.3 |
| **aPNTs** | `0xBD0710596010a157B88cd141d797E8Ad4bb2306b` | AAstar xPNTs |
| **bPNTs** | `0x70Da2c1B7Fcf471247Bc3B09f8927a4ab1751Ba3` | Bread xPNTs |
| **AAstar** | `0x411BD567E46C0781248dbB6a9211891C032885e5` | Community 1 |
| **Bread** | `0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA` | Community 2 |

## 下一步

1. **测试 MySBT Minting**:
   - 为 AAstar 社区 mint MySBT
   - 为 Bread 社区 mint MySBT
   - 验证 SBT ownership

2. **测试 xPNTs Operations**:
   - 测试 aPNTs 转账和余额
   - 测试 bPNTs 转账和余额
   - 验证 xPNTs → aPNTs 兑换率

3. **集成测试**:
   - 测试 SuperPaymaster 路由（AAstar 社区）
   - 测试独立 Paymaster（Bread 社区）
   - 验证完整的 gas sponsorship 流程

---

**更新完成时间**: 2025-11-08
**测试状态**: ✅ 全部通过
**shared-config 版本**: v0.3.1
