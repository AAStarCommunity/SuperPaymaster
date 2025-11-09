# 两个社区注册测试报告

**日期**: 2025-11-08
**网络**: Sepolia Testnet
**Registry**: v2.2.0 (`0x028aB52B4E0EF26820043ca4F1B5Fe14FfC1EF75`)

## 测试目标

使用两个测试账户测试 Registry v2.2.0 的 `registerCommunityWithAutoStake()` 功能。

## 测试账户

| 账户 | 地址 | GToken 余额 | 角色 |
|------|------|-------------|------|
| Account 1 | `0x411BD567E46C0781248dbB6a9211891C032885e5` | 1,050 GT | Deployer (AAstar 社区) |
| Account 2 | `0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA` | 1,240 GT | Owner2 (Bread 社区) |

## 测试步骤

### 1. 检查 GToken 余额 ✅

两个账户都有足够的 GToken，无需额外 mint：
- Account 1: 1,050 GT
- Account 2: 1,240 GT

### 2. 注册 Community 1 (AAstar) ✅

**配置**:
```solidity
{
  name: "AAstar Community",
  ensName: "aastar.eth",
  nodeType: PAYMASTER_SUPER (1),
  allowPermissionlessMint: true,
  stakeAmount: 50 GT
}
```

**执行**:
1. Approve 50 GT 给 Registry 合约
2. 调用 `registerCommunityWithAutoStake()`
3. Registry 自动处理 stake 逻辑

**结果**:
- ✅ 注册成功
- ✅ 50 GT 被 lock 到 GTokenStaking
- ✅ registeredAt: 1762588812 (2025-11-08)
- ✅ isActive: true

### 3. 注册 Community 2 (Bread) ✅

**配置**:
```solidity
{
  name: "Bread Community",
  ensName: "bread.eth",
  nodeType: PAYMASTER_AOA (0),
  allowPermissionlessMint: false,
  stakeAmount: 50 GT
}
```

**执行**:
1. Approve 50 GT 给 Registry 合约
2. 调用 `registerCommunityWithAutoStake()`
3. Registry 自动处理 stake 逻辑

**结果**:
- ✅ 注册成功
- ✅ 50 GT 被 lock 到 GTokenStaking
- ✅ registeredAt: 1762588812 (2025-11-08)
- ✅ isActive: true

## 关键发现

### ⚠️ Approve 地址问题

**初始错误**:
```
ERC20InsufficientAllowance(Registry, 0, 50 GT)
```

**原因**:
- `registerCommunityWithAutoStake()` 内部调用 `_autoStakeForUser()`
- `_autoStakeForUser()` 使用 `GTOKEN.safeTransferFrom(user, address(this), need)`
- 需要用户 approve **Registry 合约**，而不是 GTokenStaking

**解决方案**:
```solidity
// ❌ 错误
gtoken.approve(GTOKEN_STAKING, stakeAmount);

// ✅ 正确
gtoken.approve(REGISTRY, stakeAmount);
```

### 📊 Auto-Stake 逻辑

`_autoStakeForUser()` 函数逻辑：

1. 检查用户在 GTokenStaking 的 `availableBalance`
2. 计算需要从钱包转账的数量: `need = max(0, stakeAmount - availableBalance)`
3. 如果 `need > 0`:
   - 从用户钱包转 GToken 到 Registry
   - Registry approve GTokenStaking
   - Registry 调用 `GTokenStaking.stakeFor(user, need)`
4. 最后调用 `GTokenStaking.lockStake(user, stakeAmount, "Registry registration")`

**Account 1 vs Account 2**:
- Account 1: `availableBalance = 200 GT` → `need = 0` → 无需从钱包转账
- Account 2: `availableBalance = 0 GT` → `need = 50 GT` → 需要从钱包转账

这解释了为什么第一次测试时 Account 1 成功而 Account 2 失败。

## 链上验证

### Registry 状态

```bash
# 总社区数
cast call 0x028aB52B4E0EF26820043ca4F1B5Fe14FfC1EF75 "getCommunityCount()"
# 返回: 2
```

### Community 1 (AAstar)

| 字段 | 值 |
|------|-----|
| name | "AAstar Community" |
| ensName | "aastar.eth" |
| nodeType | 1 (PAYMASTER_SUPER) |
| community | 0x411BD567E46C0781248dbB6a9211891C032885e5 |
| registeredAt | 1762588812 |
| isActive | true |
| allowPermissionlessMint | true |

### Community 2 (Bread)

| 字段 | 值 |
|------|-----|
| name | "Bread Community" |
| ensName | "bread.eth" |
| nodeType | 0 (PAYMASTER_AOA) |
| community | 0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA |
| registeredAt | 1762588812 |
| isActive | true |
| allowPermissionlessMint | false |

## Gas 消耗

| 操作 | Gas Used | 说明 |
|------|----------|------|
| Community 1 注册 | ~476,077 gas | 已有 availableBalance，无需 stakeFor |
| Community 2 注册 | ~34,740 gas | 需要 auto-stake |
| **总计** | ~1,642,426 gas | 包含 approve 和其他操作 |

## 测试脚本

脚本位置: `script/TestTwoCommunities.s.sol`

运行命令:
```bash
forge script script/TestTwoCommunities.s.sol:TestTwoCommunities \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  -vvv
```

## 结论

### ✅ 测试通过

1. **Registry v2.2.0 部署成功** - 合约正常工作
2. **Auto-stake 功能正常** - `registerCommunityWithAutoStake()` 正确处理两种情况：
   - 用户已有 staked balance
   - 用户需要从钱包 stake
3. **两个社区注册成功** - 不同的 nodeType 和配置都能正常注册
4. **数据持久化正确** - 链上数据完整且准确

### 📋 下一步

1. **部署 xPNTs 代币**: 为每个社区部署 ERC20 xPNTs token
2. **更新社区配置**: 将 xPNTs 地址添加到社区 profile
3. **部署 SBT 合约**: 为身份验证部署 SBT
4. **测试完整流程**:
   - 用户 mint SBT
   - 使用 xPNTs 支付 gas
   - 测试 SuperPaymaster 路由

## 合约地址汇总

| 合约 | 版本 | 地址 |
|------|------|------|
| Registry | v2.2.0 | `0x028aB52B4E0EF26820043ca4F1B5Fe14FfC1EF75` |
| GToken | - | `0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc` |
| GTokenStaking | v2.0.1 | `0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0` |
| SuperPaymasterV2 | v2.0.1 | `0xfaB5B2A129DF8308a70DA2fE77c61001e4Df58BC` |

---

**测试完成时间**: 2025-11-08
**测试者**: Claude Code
**测试结果**: ✅ 全部通过
