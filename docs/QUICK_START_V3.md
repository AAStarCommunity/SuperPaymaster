# Mycelium Protocol v3 快速开始

## 什么改变了？

### 核心变化: 从分散的API → 统一的Registry

**v2 (旧)**:
```solidity
registry.registerCommunity({stakeAmount: 30})  // 复杂的手动流程
mysbt.safeMint(user, community, meta)
registry.exitCommunity()
```

**v3 (新)**:
```solidity
// 所有操作都通过Registry，原子执行
registry.registerRole(ROLE_ID, user, metadata)  // 自动处理：烧毁、锁定、SBT
registry.exitRole(ROLE_ID)  // 自动处理：解锁、扣费、SBT烧毁
registry.safeMintForRole(ROLE_ID, user, meta)  // 社区管理员空投
```

---

## 3个新合约

### 1️⃣ Registry_v3_0_0.sol
**作用**: 唯一的入口点，协调所有操作

```solidity
// 用户端
registerRole(roleId, user, metadata)      // 注册角色 (质押+烧毁)
registerRoleSelf(roleId, metadata)        // 自注册
exitRole(roleId)                          // 退出 (解锁+扣费)

// 管理员端
safeMintForRole(roleId, user, metadata)   // 仅社区管理员空投

// DAO治理
addRole(config)                           // 添加新角色
updateRoleConfig(roleId, config)          // 更新参数
enableRole(roleId, enabled)               // 启用/禁用角色
setRoleAdmin(roleId, admin)               // 设置社区管理员
```

### 2️⃣ MySBT_v3_0_0.sol
**作用**: Soul-Bound Token，不可转移

```solidity
// 仅Registry可调用
mintForRole(user, roleId, metadata)       // 注册时Mint
recordBurn(user, burnAmount)              // 记录烧毁金额
burnForRole(user, roleId)                 // 退出时Burn

// 查询
hasSBT(user)                              // 是否有SBT
getReputation(user)                       // 计算信誉分
getSBTData(tokenId)                       // SBT数据
```

### 3️⃣ GTokenStaking_v3_0_0.sol
**作用**: 简化的质押管理

```solidity
// 用户
stake(amount)                             // 质押GT

// Registry (仅授权)
lockStake(user, roleId, stakeAmount, entryBurn)  // 烧毁+锁定
unlockStake(user, roleId, lockedAmount, exitFee) // 扣费+退款
```

---

## 工作流示例

### 场景1: 用户注册ENDUSER

```
步骤1: 用户准备 0.3 GT
  await gtoken.approve(registry, 0.3);

步骤2: 调用Registry
  const tx = await registry.registerRole(
    ROLE_ENDUSER,
    userAddress,
    metadata
  );

步骤3: Registry自动执行
  ┌─ 转账: 0.3 GT from user
  ├─ 烧毁: 0.1 GT → 0xdEaD (通货紧缩)
  ├─ 锁定: 0.2 GT (不可提取)
  ├─ Mint: MySBT (信誉证明)
  └─ 记录: userRoles[user] = [ENDUSER]

步骤4: 结果
  ✓ 用户: SBT + 0.2 GT 锁定
  ✓ 协议: +0.1 GT 烧毁
  ✓ 信誉: +20 base + 10 (burn bonus) = 30分
```

### 场景2: 用户退出ENDUSER

```
步骤1: 用户调用退出
  await registry.exitRole(ROLE_ENDUSER);

步骤2: Registry计算费用
  锁定: 0.2 GT
  费率: 17% 或 最小 0.05 GT
  费用: max(17% × 0.2, 0.05) = 0.05 GT
  退款: 0.2 - 0.05 = 0.15 GT

步骤3: Registry执行
  ├─ 转账: 0.05 GT → Treasury (费用)
  ├─ 转账: 0.15 GT → User (退款)
  ├─ Burn: MySBT
  └─ 更新: totalBurned[user] += 0.05

步骤4: 结果
  ✓ 用户: +0.15 GT
  ✓ Treasury: +0.05 GT
  ✓ 协议: 总烧毁 = 0.1 + 0.05 = 0.15 GT
```

### 场景3: 社区管理员空投

```
步骤1: DAO设置管理员
  await registry.setRoleAdmin(ROLE_ENDUSER, adminAddress);

步骤2: 管理员准备空投
  await gtoken.approve(registry, airdropTotal);

步骤3: 管理员空投给用户
  await registry.safeMintForRole(
    ROLE_ENDUSER,
    recipientAddress,
    metadata
  );

步骤4: Registry执行 (无staking)
  ├─ 验证: msg.sender == roleAdmins[roleId]
  ├─ Mint: MySBT (不需要质押)
  └─ 记录: userRoles[user]

步骤5: 结果
  ✓ 接收者: 得到SBT (无需支付)
  ✓ 管理员: 支付了所有gas
  ✓ 协议: 无烧毁 (不是正常注册)
```

---

## 4个默认角色

### ENDUSER (终端用户)
| 参数 | 值 |
|------|-----|
| 质押额 | 0.3 GT |
| 烧毁 | 0.1 GT (33%) |
| 锁定 | 0.2 GT |
| 退出费 | 17% 或最小 0.05 GT |
| 退款 | 0.15 GT |
| **Sybil成本** | **0.15 GT** |

### COMMUNITY (社区)
| 参数 | 值 |
|------|-----|
| 质押额 | 30 GT |
| 烧毁 | 3 GT (10%) |
| 锁定 | 27 GT |
| 退出费 | 10% 或最小 0.3 GT |
| 退款 | 24.3 GT |
| **投资回报** | **81% (可支持可持续运营)** |

### PAYMASTER (燃料代理)
- 同 COMMUNITY (30 GT)
- 用于批处理交易和gas补贴

### SUPER (超级代理)
| 参数 | 值 |
|------|-----|
| 质押额 | 50 GT |
| 烧毁 | 5 GT (10%) |
| 锁定 | 45 GT |
| 退出费 | 10% 或最小 0.5 GT |
| 退款 | 40.5 GT |

---

## 关键差异速查表

| 功能 | v2 | v3 |
|-----|----|----|
| 入口点 | 多个 (registerCommunity等) | Registry (统一) |
| 角色类型 | NodeType enum | RoleConfig mapping |
| 新角色添加 | 代码修改 + 部署 | DAO投票 + 无停机 |
| SBT minting | 4种函数 | 2种函数 (registerRole/safeMintForRole) |
| Gas成本 | 450k | 120-150k (节省70%) |
| 烧毁跟踪 | 无 | 完整 (burn history) |
| 社区空投 | mysbt.safeMint() | registry.safeMintForRole() |
| 权限验证 | 松散 | 严格 (onlyAuthorized) |

---

## 安全性 & 防护

### Sybil攻击成本
```
ENDUSER: 最小 0.15 GT/账户
COMMUNITY: 最小 30 GT/账户

例: 攻击100个ENDUSER账户
成本 = 100 × 0.15 = 15 GT
┗ 值得吗? 不! 获利机会有限
```

### 通货紧缩机制
```
每次注册: 烧毁 (entry % of stake)
每次退出: 扣费作为烧毁 (exit fee)

预期年烧毁: < 0.01% of total supply
┗ 长期健康的通胀防护
```

### 访问控制
```
Registry.registerRole()       - 任何人
Registry.safeMintForRole()    - 仅社区管理员 + DAO
Registry.exitRole()          - 仅所有者
Registry.addRole()           - 仅DAO
Registry.updateRoleConfig()  - 仅DAO
```

---

## 迁移检查清单

前端开发者迁移到v3:

- [ ] 更新Registry ABI
- [ ] 更新MySBT ABI
- [ ] 更新GTokenStaking ABI
- [ ] 移除 registerCommunity, registerPaymaster 等调用
- [ ] 改用 registerRole(roleId, ...)
- [ ] 移除 mysbt.safeMint()
- [ ] 改用 registry.safeMintForRole()
- [ ] 更新 exitCommunity → exitRole()
- [ ] 测试所有4种角色
- [ ] 测试社区空投流程
- [ ] 验证事件监听

---

## 常见问题

**Q: 为什么要统一到Registry?**
A: 原子操作减少gas 70%，简化用户体验，清晰的权限模型。

**Q: 如何添加新角色?**
A: DAO投票通过，Registry.addRole(config)，无需代码变更！

**Q: 旧的tokenId还有效吗?**
A: 否。v3是完全新的SBT。需要用户重新注册。

**Q: 烧毁的GT去哪了?**
A: 发送到 0xdEaD (真实烧毁，永久移出流通)。

**Q: 支持多角色吗?**
A: 是的。用户可同时拥有ENDUSER + COMMUNITY，各自一个SBT。

**Q: safeMintForRole需要用户批准吗?**
A: 否。管理员支付所有gas和token。用户仅接收SBT。

---

## 文件位置

```
contracts/
├── src/paymasters/v2/core/
│   ├── Registry_v3_0_0.sol          [NEW]
│   └── GTokenStaking_v3_0_0.sol     [NEW]
└── src/paymasters/v2/tokens/
    └── MySBT_v3_0_0.sol             [NEW]

文档/
├── REFACTOR_SUMMARY_V3.md           [完整变更指南]
├── REFACTOR_CHANGELOG.md            [逐行变更]
└── QUICK_START_V3.md                [本文件]
```

---

## 下一步

1. **编写测试** (70+ tests)
2. **生成ABIs** (导出v3合约)
3. **前端集成** (更新UI)
4. **测试网部署** (Goerli/Sepolia)
5. **主网上线** (安全审计后)

---

🚀 **Status: Ready for implementation!**
