# SuperPaymaster v2.0 开发进度

## v2.0-beta (2025-10-22)

### Phase 4: Lido-Compliant sGToken Lock Architecture

#### 完成的功能

**Phase 4.1: 实现GTokenStaking完整lock机制**
- ✅ 新增lock管理系统 (`lockStake`, `unlockStake`, `calculateExitFee`)
- ✅ 降低MIN_STAKE从30 ether到0.01 ether (Lido-like低门槛)
- ✅ 新增`LockInfo`和`LockerConfig`结构体
- ✅ 支持多协议lock同一用户的sGToken
- ✅ 新增`availableBalance()`查看可用sGToken余额
- ✅ 新增treasury系统收取exit fees
- ✅ 代码行数：373 → 711 (+338行, +91%)

**Phase 4.2: 重构MySBT使用sGToken**
- ✅ 从直接持有GT改为lock用户的sGToken
- ✅ mintSBT()改为调用`IGTokenStaking.lockStake()`
- ✅ burnSBT()改为调用`IGTokenStaking.unlockStake()`
- ✅ minLockAmount (0.3 sGT) 和 mintFee (0.1 GT) 改为可配置
- ✅ 新增creator治理角色和参数setter函数
- ✅ 新增`transferCreator()`用于转移到多签
- ✅ 代码行数：420 → 519 (+99行, +24%)

**Phase 4.3: SuperPaymasterV2可配置参数**
- ✅ minOperatorStake从常量改为可配置变量
- ✅ minAPNTsBalance从常量改为可配置变量
- ✅ 新增`setMinOperatorStake()`和`setMinAPNTsBalance()`
- ✅ 新增参数范围验证 (10-1000 sGT, 10-10000 aPNTs)
- ✅ 新增对应的事件发射

**Phase 4.4: 配置locker和exit fees**
- ✅ MySBT locker配置：固定0.1 sGT exit fee
- ✅ SuperPaymaster locker配置：分层exit fees
  - < 90天: 15 sGT
  - 90-180天: 10 sGT
  - 180-365天: 7 sGT
  - >= 365天: 5 sGT
- ✅ 部署脚本添加locker配置初始化
- ✅ 设置treasury地址用于接收exit fees

**Phase 4.5: 更新所有测试**
- ✅ 更新MySBT相关测试添加stake步骤
- ✅ 修正`test_RevertWhen_RegistrationInsufficientStake`测试operator最小stake
- ✅ 更新setUp()添加locker配置
- ✅ 所有101个测试全部通过 ✨

#### 架构改进

**遵循Lido stETH最佳实践**
- 统一的stake入口点 (GTokenStaking)
- Share-based token设计 (sGToken)
- 业务合约lock用户的sGToken而非直接持有GT
- 自动计算slash影响 (`balanceOf = shares * (totalStaked - totalSlashed) / totalShares`)

**Exit Fee机制**
- 支持固定费率 (MySBT: 0.1 sGT)
- 支持时间分层费率 (SuperPaymaster: 5-15 sGT梯度)
- Treasury系统统一收取exit fees用于协议发展
- 费率完全可配置via `configureLocker()`

**治理友好**
- MySBT: creator角色可调整minLockAmount和mintFee
- SuperPaymaster: owner可调整minOperatorStake和minAPNTsBalance
- 所有治理角色可转移到多签账户
- Exit fee配置独立管理

#### 接口更新

**IGTokenStaking新增方法**
```solidity
function lockStake(address user, uint256 amount, string memory purpose) external;
function unlockStake(address user, uint256 grossAmount) external returns (uint256 netAmount);
function availableBalance(address user) external view returns (uint256);
function previewExitFee(address user, address locker) external view returns (uint256 fee, uint256 netAmount);
```

#### 测试覆盖率

- ✅ 16/16 SuperPaymasterV2 E2E测试通过
- ✅ 101/101 全部测试通过
- ✅ 覆盖lock/unlock机制
- ✅ 覆盖exit fee计算
- ✅ 覆盖可配置参数
- ✅ 覆盖operator最小stake验证

#### 下一步计划

- [ ] 部署到Sepolia测试网
- [ ] 注册DVT validators
- [ ] 测试完整operator注册流程
- [ ] 社区测试和反馈
- [ ] 准备主网部署

---

## v2.0-alpha (2025-10-22)

### 初始版本
- ✅ 完整的v2.0核心功能
- ✅ 16/16 测试通过
- ⚠️ MySBT直接持有GT (待重构)
- ⚠️ 硬编码参数 (待添加治理)
