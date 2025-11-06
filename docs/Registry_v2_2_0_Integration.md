# Registry v2.2.0 集成文档

**版本**: v2.2.0
**日期**: 2025-11-06
**变更类型**: 功能增强（向后兼容）

## 概述

Registry v2.2.0 添加了 MySBT 风格的自动 stake 功能，允许用户在单个交易中完成 stake + lock + register 操作。

## 新增功能

### `registerCommunityWithAutoStake` 函数

```solidity
function registerCommunityWithAutoStake(
    CommunityProfile memory profile,
    uint256 stakeAmount
) external nonReentrant returns (bool success)
```

**功能**：
- 自动检查用户的 `availableBalance`
- 如果不足，从用户钱包拉取差额并自动 stake
- 锁定 stake 并完成社区注册
- **原子操作**：所有步骤在同一交易中完成

**参数**：
- `profile`: 社区资料（11个字段的结构体）
- `stakeAmount`: 需要 stake 和 lock 的 GToken 数量

**返回值**：
- `success`: 注册是否成功

**事件**：
```solidity
event CommunityRegisteredWithAutoStake(
    address indexed community,
    string name,
    uint256 stakeAmount,
    uint256 autoStaked
);
```

**自定义错误**：
```solidity
error AutoStakeFailed(string reason);
error InsufficientGTokenBalance(uint256 available, uint256 required);
```

## 用户流程对比

### 传统流程（3个交易）

1. **Approve GToken** → GTokenStaking
   ```js
   await gtoken.approve(GTOKEN_STAKING_ADDRESS, amount);
   ```

2. **Stake GToken**
   ```js
   await gtokenStaking.stake(amount);
   ```

3. **等待状态同步** ⚠️ 存在状态不一致风险

4. **Register Community**
   ```js
   await registry.registerCommunity(profile, stakeAmount);
   ```

### 新流程（2个交易）✨

1. **Approve GToken** → Registry
   ```js
   const needAmount = await calculateNeedAmount(user, stakeAmount);
   if (needAmount > 0) {
     await gtoken.approve(REGISTRY_ADDRESS, needAmount);
   }
   ```

2. **Auto-Stake & Register**（原子操作）
   ```js
   await registry.registerCommunityWithAutoStake(profile, stakeAmount);
   ```

## 前端集成

### TypeScript 示例

```typescript
import { ethers } from 'ethers';

const REGISTRY_V2_2_0_ADDRESS = "0x..."; // 部署后填入
const GTOKEN_ADDRESS = "0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc";
const GTOKEN_STAKING_ADDRESS = "0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0";

async function registerWithAutoStake(
  signer: ethers.Signer,
  profile: CommunityProfile,
  stakeAmount: bigint
) {
  const registry = new ethers.Contract(
    REGISTRY_V2_2_0_ADDRESS,
    RegistryABI,
    signer
  );

  const gtoken = new ethers.Contract(GTOKEN_ADDRESS, GTokenABI, signer);
  const staking = new ethers.Contract(
    GTOKEN_STAKING_ADDRESS,
    GTokenStakingABI,
    signer
  );

  const userAddress = await signer.getAddress();

  // Step 1: 检查用户当前可用余额
  const availableBalance = await staking.availableBalance(userAddress);
  console.log('Available balance:', ethers.formatEther(availableBalance), 'GT');

  // Step 2: 计算需要补充的 stake 金额
  const needToStake = availableBalance < stakeAmount
    ? stakeAmount - availableBalance
    : 0n;

  console.log('Need to stake:', ethers.formatEther(needToStake), 'GT');

  // Step 3: 如果需要补充，approve GToken 给 Registry
  if (needToStake > 0n) {
    const walletBalance = await gtoken.balanceOf(userAddress);

    if (walletBalance < needToStake) {
      throw new Error(
        `Insufficient GToken balance. Need ${ethers.formatEther(needToStake)} GT, ` +
        `but only have ${ethers.formatEther(walletBalance)} GT`
      );
    }

    console.log('Approving', ethers.formatEther(needToStake), 'GT to Registry...');
    const approveTx = await gtoken.approve(REGISTRY_V2_2_0_ADDRESS, needToStake);
    await approveTx.wait();
    console.log('✅ Approved');
  } else {
    console.log('✅ Available balance sufficient, no need to stake more');
  }

  // Step 4: 一键注册（自动 stake + register）
  console.log('Registering community with auto-stake...');
  const tx = await registry.registerCommunityWithAutoStake(profile, stakeAmount);
  const receipt = await tx.wait();

  // 查找事件
  const event = receipt.logs
    .map(log => registry.interface.parseLog(log))
    .find(parsed => parsed?.name === 'CommunityRegisteredWithAutoStake');

  if (event) {
    console.log('✅ Community registered successfully!');
    console.log('   Community:', event.args.community);
    console.log('   Name:', event.args.name);
    console.log('   Stake Amount:', ethers.formatEther(event.args.stakeAmount), 'GT');
    console.log('   Auto-Staked:', ethers.formatEther(event.args.autoStaked), 'GT');
  }

  return receipt;
}

// 使用示例
const profile = {
  name: "MyCommunity",
  ensName: "mycommunity.eth",
  xPNTsToken: ethers.ZeroAddress,
  supportedSBTs: ["0x73E635Fc9eD362b7061495372B6eDFF511D9E18F"],
  nodeType: 0, // A_NODE
  paymasterAddress: ethers.ZeroAddress,
  community: await signer.getAddress(),
  registeredAt: 0,
  lastUpdatedAt: 0,
  isActive: true,
  allowPermissionlessMint: false
};

const stakeAmount = ethers.parseEther("30"); // 30 GT

await registerWithAutoStake(signer, profile, stakeAmount);
```

## 优势总结

| 特性 | 传统流程 | Auto-Stake 流程 |
|-----|---------|----------------|
| **交易数量** | 3个 | 2个 |
| **状态同步问题** | ❌ 存在 | ✅ 无 |
| **Gas费用** | 较高 | 较低（-33%）|
| **用户体验** | 😕 复杂 | 😊 简单 |
| **错误率** | 较高 | 极低 |

## 安全考虑

1. **重入攻击防护**：使用 `nonReentrant` 修饰符
2. **余额验证**：
   - 检查用户钱包 GToken 余额是否充足
   - 检查 stakeAmount ≥ minStake requirement
3. **权限控制**：
   - Registry 必须已注册为 GTokenStaking 的 locker
   - 用户必须 approve 足够的 GToken 给 Registry
4. **失败处理**：
   - 使用 try-catch 捕获 `stakeFor` 的错误
   - 自定义错误提供详细信息

## 部署清单

### Phase 1: 测试网部署
- [ ] 部署 Registry v2.2.0 到 Sepolia
- [ ] 配置 node type configs
- [ ] 设置 oracle 地址
- [ ] 运行集成测试
- [ ] 前端集成测试

### Phase 2: 主网部署
- [ ] 审计报告通过
- [ ] DAO 投票批准
- [ ] 主网部署
- [ ] 文档更新
- [ ] 社区公告

## 向后兼容性

Registry v2.2.0 **完全向后兼容** v2.1.4：

- 保留了原有的 `registerCommunity` 函数
- 新增的 `registerCommunityWithAutoStake` 为可选功能
- 前端可以逐步迁移，不需要强制切换

## 相关文件

- **合约**: `src/paymasters/v2/core/Registry_v2_2_0.sol`
- **测试**: `test/Registry_v2_2_0.t.sol`
- **部署脚本**: `script/DeployRegistry_v2_2_0.s.sol`
- **ABI**: `/tmp/Registry_v2_2_0_abi.json`
- **设计文档**: `docs/auto-register-design-2025-11-06.md`

## 支持

如有问题，请联系开发团队或在 GitHub 提交 issue。

---

**更新历史**：
- 2025-11-06: 初始版本，添加 auto-stake 功能
