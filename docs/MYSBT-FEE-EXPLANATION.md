# MySBT 费用机制详解

## 💰 费用总览

MySBT (My Soul Bound Token) 使用两种费用机制来确保协议可持续性和防止滥用：

| 费用类型 | 金额 | 支付方式 | 去向 | 目的 |
|---------|------|---------|------|------|
| **Mint Lock** | 0.3 stGToken | 锁定（可退回） | GTokenStaking 合约 | 确保用户承诺 |
| **Mint Burn Fee** | 0.1 GToken | 支付并销毁 | **永久销毁** | GT 通缩机制 |
| **Exit Fee** | 0.1 stGToken | unlock 时扣除 | Treasury | 协议收入 |

## 🔐 Mint 费用详解

### 1. Lock 费用（0.3 stGToken）

**性质**：锁定，不转走

**操作流程**：
```solidity
// MySBT.mintSBT() 调用：
IGTokenStaking(GTOKEN_STAKING).lockStake(
    msg.sender,        // 用户地址
    0.3 ether,         // 锁定 0.3 stGToken
    "MySBT membership" // 锁定原因
);
```

**说明**：
- stGToken 留在 GTokenStaking 合约，归用户所有
- 用户可以随时查看自己的 locked balance
- 只有通过 `burnSBT()` 才能 unlock
- Lock 是承诺机制，防止随意 mint/burn

### 2. Burn 费用（0.1 GToken）

**性质**：支付并销毁（通缩）

**操作流程**：
```solidity
// MySBT.mintSBT() 调用：
if (mintFee > 0) {
    // Step 1: 从用户钱包转移 0.1 GT 到 MySBT 合约
    IERC20(GTOKEN).safeTransferFrom(msg.sender, address(this), 0.1 ether);

    // Step 2: MySBT 合约立即 burn 这 0.1 GT
    IGToken(GTOKEN).burn(0.1 ether);
}
```

**说明**：
- 0.1 GT 直接从总供应量中销毁
- **没有人收取**，完全通缩
- 减少 GT 总供应量，增加稀缺性
- 0.1 GT 来自用户钱包（用户支付）

**为什么是 0.1 `ether`？**
- Solidity 中 `ether` 是单位后缀，表示 `10^18`
- `0.1 ether` = `0.1 * 10^18` = **0.1 GToken**（GToken 是 18 decimals ERC20）
- 不是指 ETH，只是借用 `ether` 关键字表示 18 位小数

## 🔓 Burn 费用详解

### Exit Fee（0.1 stGToken）

**性质**：从 unlock 金额中扣除

**操作流程**：
```solidity
// MySBT.burnSBT() 调用：
uint256 netAmount = IGTokenStaking(GTOKEN_STAKING).unlockStake(
    msg.sender,
    0.3 ether  // 要求 unlock 0.3 stGToken
);

// GTokenStaking 内部计算：
// exitFee = 0.1 stGToken (配置的 baseExitFee)
// netAmount = 0.3 - 0.1 = 0.2 stGToken
// 返回给用户: 0.2 stGToken
// 发送到 treasury: 0.1 stGToken
```

**说明**：
- Exit fee 由 GTokenStaking 合约在 `_initializeConnections()` 中配置
- Exit fee 发送到 treasury 地址（协议收入）
- 用户实际收回：0.2 stGToken

## 📊 完整示例：用户余额变化

### 初始状态
```
用户资产：
├─ GToken: 2.0 GT
├─ stGToken: 0 sGT
└─ MySBT: 0
```

### Step 1: Stake GT 换 stGToken

```solidity
GTokenStaking.stake(1.0 GT)

用户资产：
├─ GToken: 1.0 GT (2.0 - 1.0)
├─ stGToken: 1.0 sGT (1:1 兑换)
└─ MySBT: 0
```

### Step 2: Mint SBT

```solidity
MySBT.mintSBT(community)

执行：
1. Lock 0.3 sGT → GTokenStaking (锁定，不转走)
2. Transfer 0.1 GT → MySBT 合约
3. Burn 0.1 GT (总供应量 -0.1)
4. Mint SBT token

用户资产：
├─ GToken: 0.9 GT (1.0 - 0.1 burn)
├─ stGToken: 1.0 sGT
│   ├─ 可用: 0.7 sGT (1.0 - 0.3 locked)
│   └─ 锁定: 0.3 sGT (locked by MySBT)
└─ MySBT: 1 (tokenId #42)
```

### Step 3: Burn SBT

```solidity
MySBT.burnSBT(tokenId)

执行：
1. Burn SBT token
2. Unlock 0.3 sGT from GTokenStaking
3. 扣除 Exit Fee: 0.1 sGT → treasury
4. 退回净额: 0.2 sGT

用户资产：
├─ GToken: 0.9 GT (不变)
├─ stGToken: 0.9 sGT (0.7可用 + 0.2退回)
│   ├─ 可用: 0.9 sGT
│   └─ 锁定: 0 sGT
└─ MySBT: 0
```

### Step 4: Unstake 回到 GT（可选）

```solidity
GTokenStaking.unstake(0.9 sGT)

用户最终资产：
├─ GToken: 1.8 GT (0.9 + 0.9 unstake)
├─ stGToken: 0 sGT
└─ MySBT: 0

总损失：
- Mint burn: 0.1 GT (永久销毁)
- Exit fee: 0.1 sGT ≈ 0.1 GT (给 treasury)
- 净剩余: 1.8 GT (初始 2.0 - 0.2 费用)
```

## 🔧 费用可配置性

### Mint Lock Amount

```solidity
/// @notice 默认 0.3 sGT，可由 creator 修改
uint256 public minLockAmount = 0.3 ether;

function setMinLockAmount(uint256 newAmount) external {
    require(msg.sender == creator);
    require(newAmount >= 0.01 ether && newAmount <= 10 ether);
    minLockAmount = newAmount;
}
```

### Mint Burn Fee

```solidity
/// @notice 默认 0.1 GT，可由 creator 修改
uint256 public mintFee = 0.1 ether;

function setMintFee(uint256 newFee) external {
    require(msg.sender == creator);
    require(newFee <= 1 ether);
    mintFee = newFee;
}
```

### Exit Fee

```solidity
// 由 GTokenStaking owner 配置（在部署脚本中）
gtokenStaking.configureLocker(
    address(mysbt),
    true,                    // authorized
    0.1 ether,              // baseExitFee: 0.1 sGT
    emptyTiers,             // no time tiers
    emptyFees,              // no tiered fees
    address(0)              // use default treasury
);
```

## 📋 费用用途说明

### Mint Burn Fee (0.1 GT)

**为什么要 burn？**

1. **通缩机制**：减少 GT 总供应量
2. **价值提升**：GT 变得更稀缺，价格上涨
3. **防止滥用**：有成本才会珍惜 SBT
4. **公平性**：所有人都需要支付相同费用

**为什么不是 0.01 或 1 GT？**

- 0.1 GT 是经过平衡的金额：
  - 不会太高（阻止用户参与）
  - 不会太低（无法防止滥用）
  - 可以通过 `setMintFee()` 调整

### Exit Fee (0.1 sGT)

**为什么要收取 exit fee？**

1. **协议可持续性**：为开发、运营提供资金
2. **防止频繁进出**：鼓励长期承诺
3. **惩罚投机行为**：短期炒作者需支付成本
4. **补偿社区**：exit 用户减少了社区价值

**为什么是 0.1 sGT？**

- 相当于 locked amount 的 33%（0.1 / 0.3）
- 用户仍能收回大部分（66%）
- 足以防止频繁 mint/burn
- Treasury 获得稳定收入

## 🎯 用户前端展示建议

在 mint SBT 页面，应该清晰展示：

```
┌─────────────────────────────────────────┐
│  铸造 MySBT 所需资源                     │
├─────────────────────────────────────────┤
│  ✓ 锁定: 0.3 stGToken                   │
│    └─ 说明: 销毁 SBT 时可退回 0.2 sGT   │
│                                          │
│  ✓ 燃烧: 0.1 GToken                     │
│    └─ 说明: 永久销毁，减少 GT 总供应量  │
│                                          │
│  退出时                                  │
│  • 退还: 0.2 stGToken                   │
│  • 费用: 0.1 stGToken → 协议金库        │
└─────────────────────────────────────────┘

[✓] 我理解费用机制
[铸造 SBT]
```

## ❓ 常见问题

### Q1: 为什么要先 stake GT 才能 mint SBT？

**A**: MySBT 需要锁定 **stGToken**（不是 GToken）。stGToken 是 stake GT 后获得的份额凭证。

流程：
1. Stake GT → 获得 stGToken
2. Lock stGToken → Mint SBT
3. Unlock stGToken → Burn SBT

### Q2: Burn 的 0.1 GT 去哪了？

**A**: 永久销毁，从总供应量中移除。任何人都无法再使用这 0.1 GT。

### Q3: Exit fee 能退回吗？

**A**: 不能。0.1 sGT 是协议收入，用于：
- 开发团队激励
- 协议运营成本
- 社区治理资金
- 未来升级储备

### Q4: 我可以不 burn SBT，一直持有吗？

**A**: 可以！只要不 burn，0.3 sGT 就一直 locked。但你无法使用这部分 sGT 进行其他操作。

### Q5: 如果 GT 价格上涨，我的费用会变吗？

**A**:
- **Mint burn fee**: 仍是 0.1 GT（数量不变，但美元价值上涨）
- **Exit fee**: 仍是 0.1 sGT（stGToken 价值随 GT 上涨而上涨）

建议：GT 价格低时 mint，可以节省美元成本。

### Q6: Treasury 的钱会用来做什么？

**A**:
- DAO 治理决定
- 协议升级开发
- 安全审计
- 社区激励
- Bug bounty

## 📚 相关文档

- [GTokenStaking 架构](./v2-staking-slash-architecture.md)
- [MySBT 合约代码](../src/paymasters/v2/tokens/MySBT.sol)
- [部署脚本](../script/DeploySuperPaymasterV2.s.sol)
- [NFT 绑定设计](./SBT-NFT-BINDING-DESIGN.md)

---

**最后更新**: 2025-10-25
**版本**: v2.1-beta
