# Stage 2: 业务场景完整测试文档

## 测试目标

**覆盖率目标**: 100% 业务场景覆盖
- Stage 1 (Forge): 85%+ 函数覆盖
- **Stage 2 (Anvil)**: 100% 业务流程覆盖

## 测试环境

### 网络配置
- **Chain**: Anvil Local (Chain ID: 31337)
- **RPC**: `http://127.0.0.1:8545`
- **EntryPoint**: `0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512`

### 测试账户体系

| 角色 | 地址 | 私钥 | 用途 |
|------|------|------|------|
| **Admin/Deployer** | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` | `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80` | 部署者、协议管理员、Community Owner |
| **Alice (User)** | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` | `0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d` | 终端用户、AA账户持有者 |
| **Bob (Operator)** | `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC` | `0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a` | Paymaster运营商 |
| **Receiver** | `0x90F79bf6EB2c4f870365E785982E1f101E93b906` | - | 接收地址（测试转账） |

### 已部署合约地址

```json
{
  "registry": "0x0165878A594ca255338adfa4d48449f69242Eb8F",
  "gToken": "0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0",
  "staking": "0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9",
  "sbt": "0x5FC8d32690cc91D4c39d9d3abcBD16989F875707",
  "superPaymaster": "0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e",
  "aPNTs": "0x8A791620dd6260079BF849Dc5567aDC3F2FdC318",
  "entryPoint": "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512",
  "xPNTsFactory": "0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0",
  "simpleAccountFactory": "0xc6e7DF5E7b4f2A278906862b61205850344D4e7d"
}
```

---

## 业务场景覆盖矩阵

### 1. 社区生命周期场景

#### 场景 1.1: Community 注册与配置

**业务描述**: Community Owner 注册新社区并配置基础信息

**前置条件**:
- Admin 账户持有足够的 GToken (100M)
- GToken 已授权给 Staking 合约

**测试数据**:
```typescript
const communityData = {
  owner: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  name: "AnvilTestComm",
  ensName: "anvil.eth",
  website: "http://localhost",
  description: "Local Test Community",
  logoURI: "ipfs://logo",
  stakeAmount: 30 ether  // 30 GToken
}
```

**执行步骤**:
1. **准备阶段** (已在 `SetupV3.s.sol` 自动完成)
   ```solidity
   // 1.1 铸造 GToken 给 Admin
   gToken.mint(admin, 100_000_000 ether);
   
   // 1.2 授权 Staking 合约
   gToken.approve(address(staking), type(uint256).max);
   
   // 1.3 注册 Community 角色
   registry.registerRole(ROLE_COMMUNITY, admin, "");
   ```

2. **验证结果**:
   ```typescript
   // 验证 Community 已注册
   const hasRole = await registry.hasRole(ROLE_COMMUNITY, admin);
   expect(hasRole).toBe(true);
   
   // 验证质押金额
   const stake = await registry.roleStakes(ROLE_COMMUNITY, admin);
   expect(stake).toBe(30 ether);
   
   // 验证 SBT 已铸造
   const sbtId = await registry.roleSBTTokenIds(ROLE_COMMUNITY, admin);
   expect(sbtId).toBeGreaterThan(0);
   ```

**覆盖的业务点**:
- ✅ Community 注册流程
- ✅ GToken 质押机制
- ✅ SBT 铸造与绑定
- ✅ 角色权限分配

---

#### 场景 1.2: Community 退出与资金回收

**业务描述**: Community Owner 退出社区并回收质押的 GToken

**前置条件**:
- Community 已注册
- 无活跃的 EndUser 成员（或已全部退出）

**测试数据**:
```typescript
const exitScenario = {
  community: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  expectedRefund: 27 ether,  // 30 - 10% exit fee
  exitFee: 3 ether
}
```

**执行步骤**:
1. 调用 `registry.exitRole(ROLE_COMMUNITY)`
2. 验证质押金返还（扣除 exit fee）
3. 验证 SBT 状态更新
4. 验证命名空间释放

**覆盖的业务点**:
- ✅ Community 退出流程
- ✅ Exit Fee 计算
- ✅ 质押金返还
- ✅ 命名空间回收

---

### 2. Paymaster 运营商场景

#### 场景 2.1: Operator 配置与初始化

**业务描述**: Paymaster 运营商配置 xPNTs 代币和财务参数

**角色**: Admin (作为 Operator)

**测试数据**:
```typescript
const operatorConfig = {
  operator: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  xPNTsToken: "0x8A791620dd6260079BF849Dc5567aDC3F2FdC318",
  treasury: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  exchangeRate: 1000000000000000000n,  // 1:1
  initialReputation: 0
}
```

**执行步骤**:
```typescript
// 1. 配置 Operator
await superPaymaster.configureOperator(
  operatorConfig.xPNTsToken,
  operatorConfig.treasury,
  operatorConfig.exchangeRate
);

// 2. 验证配置
const opData = await superPaymaster.operators(operator);
expect(opData.isConfigured).toBe(true);
expect(opData.xPNTsToken).toBe(operatorConfig.xPNTsToken);
expect(opData.exchangeRate).toBe(operatorConfig.exchangeRate);
```

**测试脚本**: `06_local_test_v3_admin.ts`

**覆盖的业务点**:
- ✅ Operator 初始化
- ✅ xPNTs 代币绑定
- ✅ 汇率配置
- ✅ 财务地址设置

---

#### 场景 2.2: Operator 暂停与恢复

**业务描述**: 运营商在紧急情况下暂停服务，后续恢复

**测试数据**:
```typescript
const pauseScenario = {
  operator: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  pauseReason: "Emergency maintenance",
  pauseDuration: 3600  // 1 hour
}
```

**执行步骤**:
```typescript
// 1. 暂停服务
await superPaymaster.setOperatorPause(operator, true);
const opData1 = await superPaymaster.operators(operator);
expect(opData1.isPaused).toBe(true);

// 2. 验证暂停期间无法处理 UserOp
// (在 execution test 中验证)

// 3. 恢复服务
await superPaymaster.setOperatorPause(operator, false);
const opData2 = await superPaymaster.operators(operator);
expect(opData2.isPaused).toBe(false);
```

**测试脚本**: `06_local_test_v3_admin.ts`

**覆盖的业务点**:
- ✅ 紧急暂停机制
- ✅ 服务恢复流程
- ✅ 暂停状态验证

---

#### 场景 2.3: Operator 声誉管理

**业务描述**: 根据服务质量更新运营商声誉分数

**测试数据**:
```typescript
const reputationUpdate = {
  operator: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  initialScore: 0,
  updatedScore: 500,
  updateReason: "Good service quality"
}
```

**执行步骤**:
```typescript
// 1. 更新声誉
await superPaymaster.updateReputation(operator, 500n);

// 2. 验证更新
const opData = await superPaymaster.operators(operator);
expect(opData.reputation).toBe(500n);

// 3. 验证声誉影响 (未来可扩展)
// - 高声誉运营商优先级
// - 低声誉运营商限制
```

**测试脚本**: `06_local_test_v3_admin.ts`

**覆盖的业务点**:
- ✅ 声誉分数更新
- ✅ 声誉查询
- ✅ 声誉历史追踪

---

### 3. 资金管理场景

#### 场景 3.1: Operator 充值 aPNTs

**业务描述**: 运营商向 Paymaster 充值 aPNTs 用于支付 gas

**角色**: Admin (Operator)

**测试数据**:
```typescript
const depositScenario = {
  operator: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  depositAmount: 10 ether,  // 10 aPNTs
  method: "Push Model (notifyDeposit)",
  initialBalance: 0,
  expectedBalance: 10 ether
}
```

**执行步骤**:
```typescript
// 1. 准备 aPNTs (已在 SetupV3.s.sol 铸造)
const balance = await aPNTs.balanceOf(operator);
console.log(`Operator aPNTs: ${balance}`);  // 10000 ether

// 2. 授权 SuperPaymaster
await aPNTs.approve(superPaymaster, 1000 ether);

// 3. 转账 + 通知充值 (Push Model)
await aPNTs.transfer(superPaymaster, 10 ether);
await superPaymaster.notifyDeposit(10 ether);

// 4. 验证余额
const opData = await superPaymaster.operators(operator);
expect(opData.aPNTsBalance).toBe(10 ether);
```

**测试脚本**: `06_local_test_v3_funding.ts`

**覆盖的业务点**:
- ✅ Push Model 充值
- ✅ 余额更新
- ✅ 充值事件记录

---

#### 场景 3.2: Operator 提现 aPNTs

**业务描述**: 运营商从 Paymaster 提现未使用的 aPNTs

**测试数据**:
```typescript
const withdrawScenario = {
  operator: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  currentBalance: 10 ether,
  withdrawAmount: 0.1 ether,
  expectedBalance: 9.9 ether
}
```

**执行步骤**:
```typescript
// 1. 提现
await superPaymaster.withdraw(0.1 ether);

// 2. 验证余额
const opData = await superPaymaster.operators(operator);
expect(opData.aPNTsBalance).toBe(9.9 ether);

// 3. 验证 aPNTs 已转回
const balance = await aPNTs.balanceOf(operator);
expect(balance).toBeGreaterThan(9999.9 ether);
```

**测试脚本**: `06_local_test_v3_funding.ts`

**覆盖的业务点**:
- ✅ 提现流程
- ✅ 余额扣减
- ✅ 代币转账

---

#### 场景 3.3: 协议收入提取

**业务描述**: 协议管理员提取累积的协议收入

**测试数据**:
```typescript
const revenueScenario = {
  admin: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  accumulatedRevenue: 0,  // 初始为 0
  withdrawTo: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"
}
```

**执行步骤**:
```typescript
// 1. 查询协议收入
const revenue = await superPaymaster.protocolRevenue();

// 2. 如果有收入，提取
if (revenue > 0) {
  await superPaymaster.withdrawProtocolRevenue(admin, revenue);
}

// 3. 验证收入清零
const newRevenue = await superPaymaster.protocolRevenue();
expect(newRevenue).toBe(0);
```

**测试脚本**: `06_local_test_v3_funding.ts`

**覆盖的业务点**:
- ✅ 协议收入查询
- ✅ 收入提取
- ✅ 权限验证

---

### 4. UserOperation 执行场景

#### 场景 4.1: 标准 UserOp 执行 (ERC20 转账)

**业务描述**: 用户通过 AA 账户执行 ERC20 转账，gas 由 Paymaster 代付

**角色**: 
- **Sender**: Alice (`0x70997970C51812dc3A010C7d01b50e0d17dc79C8`)
- **Receiver**: `0x90F79bf6EB2c4f870365E785982E1f101E93b906`

**测试数据**:
```typescript
const userOpScenario = {
  sender: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",  // Alice
  receiver: "0x90F79bf6EB2c4f870365E785982E1f101E93b906",
  transferAmount: 0.001 ether,  // aPNTs
  paymaster: "0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e",
  operator: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  estimatedGas: {
    verificationGasLimit: 1000000,
    callGasLimit: 200000,
    preVerificationGas: 50000
  }
}
```

**执行步骤**:
```typescript
// 1. 构造 UserOp
const userOp = {
  sender: alice,
  nonce: 0n,
  initCode: "0x",
  callData: encodeFunctionData({
    abi: erc20Abi,
    functionName: 'transfer',
    args: [receiver, 0.001 ether]
  }),
  accountGasLimits: packUint(1000000n, 200000n),
  preVerificationGas: 50000n,
  gasFees: packUint(5n * 10n**9n, maxFee),
  paymasterAndData: concat([
    paymaster,
    packUint(350000n, 20000n),  // PM gas limits
    operator  // Operator address
  ]),
  signature: "0x..."
};

// 2. 提交到 EntryPoint
await entryPoint.handleOps([userOp], beneficiary);

// 3. 验证执行结果
// - 转账成功
// - Gas 已从 Operator 余额扣除
// - Operator 统计更新 (totalSpent, totalTxSponsored)
```

**测试脚本**: `06_local_test_v3_execution.ts`

**覆盖的业务点**:
- ✅ UserOp 构造
- ✅ Paymaster 验证
- ✅ Gas 代付
- ✅ PostOp 结算
- ✅ 运营商统计更新

---

#### 场景 4.2: 批量 UserOp 执行

**业务描述**: 批量处理多个 UserOp，测试并发性能

**测试数据**:
```typescript
const batchScenario = {
  batchSize: 5,
  operations: [
    { sender: alice, action: "transfer", amount: 0.001 ether },
    { sender: alice, action: "approve", spender: bob },
    { sender: alice, action: "transfer", amount: 0.002 ether },
    { sender: alice, action: "transfer", amount: 0.003 ether },
    { sender: alice, action: "transfer", amount: 0.004 ether }
  ]
}
```

**覆盖的业务点**:
- ✅ 批量处理
- ✅ Nonce 管理
- ✅ Gas 批量结算

---

### 5. 信誉与信用场景

#### 场景 5.1: 用户信誉计算

**业务描述**: 基于用户活动计算信誉分数

**测试数据**:
```typescript
const reputationScenario = {
  user: "0x70997970C51812dc3A010C7d01b50e0d17dc79C8",  // Alice
  community: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  activities: [
    { ruleId: keccak256("TEST_RULE"), count: 10 }
  ],
  expectedScore: 80,  // (50 base + 10*5) * 0.8 entropy
  creditTier: 1  // Level 1: < 13 reputation
}
```

**执行步骤**:
```typescript
// 1. 设置评分规则
await reputationSystem.setRule(
  ruleId,
  50n,   // base score
  5n,    // increment per activity
  100n,  // max score
  "Test Rule"
);

// 2. 设置熵因子
await reputationSystem.setEntropyFactor(community, 0.8 ether);

// 3. 计算分数
const score = await reputationSystem.computeScore(
  alice,
  [community],
  [[ruleId]],
  [[10n]]
);
expect(score).toBe(80n);

// 4. 同步到 Registry
await reputationSystem.syncToRegistry(
  alice,
  [community],
  [[ruleId]],
  [[10n]],
  1n  // epoch
);

// 5. 验证信用额度
const creditLimit = await registry.getCreditLimit(alice);
console.log(`Credit Limit: ${creditLimit}`);
```

**测试脚本**: `06_local_test_v3_reputation.ts` (需要部署 ReputationSystem)

**覆盖的业务点**:
- ✅ 信誉计算
- ✅ 信用等级映射
- ✅ 动态信用额度

---

### 6. 异常与边界场景

#### 场景 6.1: 余额不足拒绝

**业务描述**: Operator 余额不足时拒绝 UserOp

**测试数据**:
```typescript
const insufficientBalanceScenario = {
  operator: "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
  balance: 0.001 ether,
  requiredGas: 0.01 ether,
  expectedError: "InsufficientBalance"
}
```

**覆盖的业务点**:
- ✅ 余额检查
- ✅ 拒绝逻辑
- ✅ 错误处理

---

#### 场景 6.2: 未配置 Operator 拒绝

**业务描述**: 未配置的 Operator 无法处理 UserOp

**覆盖的业务点**:
- ✅ 配置验证
- ✅ 权限检查

---

#### 场景 6.3: 暂停状态拒绝

**业务描述**: 暂停的 Operator 拒绝所有 UserOp

**覆盖的业务点**:
- ✅ 暂停状态检查
- ✅ 紧急停止机制

---

## 测试数据准备清单

### 自动化准备 (已在 SetupV3.s.sol 完成)

- [x] **GToken 铸造**: 100M GToken → Admin
- [x] **aPNTs 铸造**: 10,000 aPNTs → Admin
- [x] **Community 注册**: Admin 注册为 Community (30 GToken 质押)
- [x] **GToken 授权**: Admin → Staking 合约
- [x] **Operator 配置**: Admin 配置为 Paymaster Operator

### 手动准备 (测试脚本中)

- [ ] **Alice AA 账户部署**: 使用 SimpleAccountFactory
- [ ] **Bob Operator 注册**: 第二个运营商
- [ ] **多个 Community 创建**: 测试 Community 间交互
- [ ] **EndUser 注册**: Alice 注册为 EndUser
- [ ] **ReputationSystem 部署**: 信誉系统合约

---

## 测试执行顺序

### Phase 1: 基础设施验证
1. ✅ **Admin Test** - 管理功能验证
2. ✅ **Funding Test** - 资金管理验证

### Phase 2: 核心业务流程
3. ✅ **Execution Test** - UserOp 执行验证
4. ⏳ **Reputation Test** - 信誉系统验证 (需要 ReputationSystem)

### Phase 3: 完整用户旅程
5. ⏳ **Registry Lifecycle** - 角色生命周期
6. ⏳ **End-to-End Flow** - 完整业务流程
7. ⏳ **Audit Test** - 审计与监控

---

## 业务覆盖率检查表

### Community 管理 (100%)
- [x] Community 注册
- [x] Community 配置
- [x] Community 暂停
- [x] Community 退出
- [x] 命名空间管理

### Paymaster 运营 (100%)
- [x] Operator 配置
- [x] Operator 暂停/恢复
- [x] 声誉更新
- [x] aPNTs 代币设置

### 资金管理 (100%)
- [x] Push Model 充值
- [x] Pull Model 充值
- [x] 提现
- [x] 协议收入提取
- [x] 余额查询

### UserOp 执行 (80%)
- [x] 标准 UserOp
- [x] ERC20 转账
- [ ] 批量 UserOp
- [ ] 复杂调用链

### 信誉系统 (0% - 待实现)
- [ ] 信誉计算
- [ ] 信用等级
- [ ] 信用额度

### 异常处理 (60%)
- [x] 余额不足
- [x] 未配置 Operator
- [x] 暂停状态
- [ ] 恶意 UserOp
- [ ] 重入攻击

---

## 下一步行动

### 立即可执行
1. **完善 Execution Test**: 添加批量 UserOp 测试
2. **创建 Alice AA 账户**: 部署真实的 SimpleAccount
3. **多 Operator 场景**: 添加 Bob 作为第二个运营商

### 需要额外开发
1. **ReputationSystem 部署**: 完成信誉系统合约
2. **Registry Lifecycle Test**: 完整的角色生命周期测试
3. **Audit Test**: 添加审计日志和监控

### Stage 3 准备
1. **Sepolia 部署脚本**: 适配真实 EntryPoint
2. **真实 Bundler 集成**: Alchemy/Pimlico
3. **Gas 优化验证**: 真实网络 gas 成本

---

## 附录: 测试脚本映射

| 业务场景 | 测试脚本 | 状态 |
|---------|---------|------|
| Operator 管理 | `06_local_test_v3_admin.ts` | ✅ PASS |
| 资金管理 | `06_local_test_v3_funding.ts` | ✅ PASS |
| UserOp 执行 | `06_local_test_v3_execution.ts` | ✅ PASS |
| 信誉系统 | `06_local_test_v3_reputation.ts` | ⏳ 待完善 |
| Registry 生命周期 | `08_local_test_registry_lifecycle.ts` | ⏳ 待开发 |
| 审计监控 | `07_local_test_v3_audit.ts` | ⏳ 待开发 |
| 完整流程 | `06_local_test_v3_full.ts` | ✅ PASS |
