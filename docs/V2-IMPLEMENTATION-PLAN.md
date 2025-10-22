# SuperPaymaster v2.0 实施计划

## 项目概览

**目标**: 实现 SuperPaymaster v2.0 完整架构，包括核心合约、Token系统、监控机制

**开发周期**: 14周 (~3.5个月)

**当前状态**: ✅ 架构设计完成 → 开始实施

**Git分支**: `v2`

**Tag**: `v2.0.0-alpha.1` (Architecture Design Complete)

---

## Phase 1: 核心基础设施 (2周)

### Week 1: Registry增强 + PaymasterFactory

#### 1.1 Registry.sol 增强 (3天)

**文件**: `contracts/core/Registry.sol`

**任务清单**:
- [ ] 添加 CommunityProfile struct
  ```solidity
  struct CommunityProfile {
      string name;
      string ensName;
      string description;
      string website;
      string logoURI;
      string twitterHandle;
      string githubOrg;
      string telegramGroup;
      address xPNTsToken;
      address[] supportedSBTs;
      PaymasterMode mode;
      address paymasterAddress;
      address community;
      uint256 registeredAt;
      uint256 lastUpdatedAt;
      bool isActive;
      uint256 memberCount;
  }
  ```
- [ ] 实现多索引映射
  - `mapping(address => CommunityProfile) public communities`
  - `mapping(string => address) public communityByName`
  - `mapping(string => address) public communityByENS`
  - `mapping(address => address) public communityBySBT`
- [ ] 实现 `registerCommunity()` 函数
- [ ] 实现 `updateCommunityProfile()` 函数
- [ ] 实现 `getCommunityProfile()` 查询函数
- [ ] 添加事件: `CommunityRegistered`, `CommunityUpdated`
- [ ] 编写单元测试 (Foundry)

**验收标准**:
- ✅ 所有函数测试通过
- ✅ Gas优化 (< 200k gas for registration)
- ✅ 多索引查询正常工作

---

#### 1.2 PaymasterFactory.sol 实现 (2天)

**文件**: `contracts/core/PaymasterFactory.sol`

**任务清单**:
- [ ] 实现 EIP-1167 Minimal Proxy 模式
- [ ] 版本管理系统
  ```solidity
  mapping(string => address) public implementations; // version => implementation
  ```
- [ ] `deployPaymaster()` 函数
  - 参数: `version`, `config`
  - 返回: 新 Paymaster 地址
- [ ] `upgradeImplementation()` 管理函数
- [ ] `getPaymasterByOperator()` 查询函数
- [ ] 事件: `PaymasterDeployed`, `ImplementationUpgraded`
- [ ] 编写单元测试

**验收标准**:
- ✅ EIP-1167 正确实现
- ✅ 部署 Gas < 100k
- ✅ 版本切换正常

---

#### 1.3 GTokenStaking.sol 实现 (2天)

**文件**: `contracts/core/GTokenStaking.sol`

**参考**: `docs/V2-CONTRACT-SPECIFICATIONS.md` (已有完整代码)

**任务清单**:
- [ ] 复制文档中的完整代码
- [ ] 实现 `stake()` 函数
- [ ] 实现 `balanceOf()` Slash感知计算
  ```solidity
  return shares * (totalStaked - totalSlashed) / totalShares;
  ```
- [ ] 实现 `slash()` 函数 (仅SuperPaymaster可调用)
- [ ] 实现 `requestUnstake()` + `unstake()` (7天锁定)
- [ ] 集成 GToken ERC20
- [ ] 编写测试（包括Slash场景）

**验收标准**:
- ✅ Slash感知份额计算正确
- ✅ 7天解质押锁定生效
- ✅ 30 GT最低质押限制

---

### Week 2: SuperPaymasterV2.sol 核心

#### 2.1 SuperPaymasterV2.sol 基础结构 (3天)

**文件**: `contracts/core/SuperPaymasterV2.sol`

**参考**: `docs/V2-CONTRACT-SPECIFICATIONS.md` (已有完整代码)

**任务清单**:
- [ ] 复制文档中的完整代码
- [ ] 实现 IPaymaster 接口
  - `validatePaymasterUserOp()`
  - `_postOp()`
- [ ] 实现 OperatorAccount 管理
  - `registerOperator()`
  - `depositAPNTs()`
  - `accounts` mapping
- [ ] 集成 GTokenStaking
- [ ] 实现 `_hasSBT()` 验证逻辑
- [ ] 实现 `_extractOperator()` 解析逻辑
- [ ] 基础测试

**验收标准**:
- ✅ IPaymaster 接口正确实现
- ✅ 多账户管理正常
- ✅ SBT验证逻辑正确

---

#### 2.2 SuperPaymasterV2.sol 声誉系统 (2天)

**任务清单**:
- [ ] 实现 `_updateReputation()` 函数
- [ ] Fibonacci等级数组
  ```solidity
  uint256[12] public REPUTATION_LEVELS = [
      1 ether, 1 ether, 2 ether, 3 ether, 5 ether, 8 ether,
      13 ether, 21 ether, 34 ether, 55 ether, 89 ether, 144 ether
  ];
  ```
- [ ] 升级条件检查:
  - 连续30天无Slash
  - 至少1000笔交易
  - aPNTs充足率 > 150%
- [ ] `consecutiveDays` 追踪逻辑
- [ ] 测试声誉升级场景

**验收标准**:
- ✅ Fibonacci等级正确
- ✅ 升级条件验证正确
- ✅ 声誉降级逻辑正确

---

## Phase 2: Token系统与身份 (6周)

### Week 3-4: xPNTs系统

#### 3.1 xPNTsToken.sol 实现 (3天)

**文件**: `contracts/tokens/xPNTsToken.sol`

**参考**: `docs/V2-XPNTS-AND-MYSBT-DESIGN.md`

**任务清单**:
- [ ] 继承 ERC20 + ERC20Permit
- [ ] Override `allowance()` 实现预授权
  ```solidity
  function allowance(address owner, address spender) public view override returns (uint256) {
      if (autoApprovedSpenders[spender]) return type(uint256).max;
      return super.allowance(owner, spender);
  }
  ```
- [ ] `addAutoApprovedSpender()` / `removeAutoApprovedSpender()`
- [ ] `mint()` / `burn()` 函数
- [ ] 社区信息字段 (name, ENS)
- [ ] 测试预授权机制

**验收标准**:
- ✅ 预授权正常工作
- ✅ EIP-2612 Permit 支持
- ✅ burn() 正确检查授权

---

#### 3.2 xPNTsFactory.sol 实现 (3天)

**文件**: `contracts/tokens/xPNTsFactory.sol`

**参考**: `docs/V2-XPNTS-AND-MYSBT-DESIGN.md`

**任务清单**:
- [ ] `deployxPNTsToken()` 函数
- [ ] 自动配置预授权 (SuperPaymaster)
- [ ] `predictDepositAmount()` AI预测
  ```solidity
  suggestedAmount = dailyTx * avgGasCost * 30 * industryMultiplier * safetyFactor / 1e18;
  ```
- [ ] `updatePrediction()` 参数更新
- [ ] 行业系数配置 (DeFi=2.0, Gaming=1.5, Social=1.0)
- [ ] 测试部署流程

**验收标准**:
- ✅ 标准化部署成功
- ✅ AI预测算法正确
- ✅ 预授权自动配置

---

#### 3.3 xPNTs集成测试 (1天)

**任务清单**:
- [ ] 用户充值 xPNTs
- [ ] 兑换 aPNTs (无需approve)
- [ ] SuperPaymaster 扣除 aPNTs
- [ ] 完整流程E2E测试

---

### Week 5-6: MySBT系统

#### 4.1 MySBT.sol 实现 (4天)

**文件**: `contracts/tokens/MySBT.sol`

**参考**: `docs/V2-XPNTS-AND-MYSBT-DESIGN.md`

**任务清单**:
- [ ] 继承 ERC721
- [ ] Override `_transfer()` 实现非转让
  ```solidity
  require(from == address(0) || to == address(0), "SBT: Soul Bound Token cannot be transferred");
  ```
- [ ] UserProfile struct
- [ ] CommunityData struct (注意: `community` 字段!)
- [ ] `mintSBT()` 函数
  - 质押 0.2 GT
  - 销毁 0.1 GT
- [ ] `updateActivity()` 函数 (仅SuperPaymaster)
- [ ] 多社区支持 (mapping)
- [ ] 测试非转让逻辑

**验收标准**:
- ✅ 不可转让生效
- ✅ 质押+burn正确
- ✅ 活跃度追踪正常

---

#### 4.2 MySBT集成 (2天)

**任务清单**:
- [ ] SuperPaymaster 验证 SBT
- [ ] 交易后更新活跃度
- [ ] 多社区数据隔离
- [ ] E2E测试

---

### Week 7-8: AI预测与优化

#### 5.1 AI预测服务 (链下)

**文件**: `services/ai-prediction-service.ts`

**任务清单**:
- [ ] 实现预测算法
- [ ] 历史数据分析
- [ ] 行业系数调整
- [ ] 定期更新链上参数

---

#### 5.2 Gas优化

**任务清单**:
- [ ] 合约代码优化
- [ ] Storage layout优化
- [ ] Batch操作实现
- [ ] Gas benchmarking

---

## Phase 3: 监控与惩罚 (4周)

### Week 9-10: DVT验证节点

#### 6.1 DVTValidator.sol 实现 (3天)

**文件**: `contracts/validators/DVTValidator.sol`

**参考**: `docs/V2-DVT-BLS-SLASH-MECHANISM.md`

**任务清单**:
- [ ] 13个节点白名单
- [ ] `submitCheck()` 函数
- [ ] ValidationRecord 存储
- [ ] hourIndex 索引
- [ ] 通知 BLS Aggregator
- [ ] 测试验证流程

**验收标准**:
- ✅ 13节点授权正确
- ✅ 每小时检查生效
- ✅ 记录正确存储

---

#### 6.2 链下DVT节点服务 (4天)

**文件**: `services/dvt-node/`

**任务清单**:
- [ ] 节点服务框架
- [ ] 每小时定时检查
- [ ] aPNTs余额读取
- [ ] BLS签名生成
- [ ] 提交到链上
- [ ] 13个节点部署脚本
- [ ] 监控Dashboard

**验收标准**:
- ✅ 自动化检查运行
- ✅ BLS签名正确
- ✅ 节点健康监控

---

### Week 11-12: BLS签名聚合

#### 7.1 BLSAggregator.sol 实现 (4天)

**文件**: `contracts/validators/BLSAggregator.sol`

**参考**: `docs/V2-DVT-BLS-SLASH-MECHANISM.md`

**任务清单**:
- [ ] `collectSignature()` 收集函数
- [ ] 7/13 阈值验证
- [ ] SlashProposal 管理
- [ ] `_executeSlash()` 执行函数
- [ ] 三级Slash逻辑:
  - Hour 1: WARNING (-10声誉)
  - Hour 2: MINOR (5% slash, -20声誉)
  - Hour 3: MAJOR (10% slash + pause, -50声誉)
- [ ] BLS签名聚合库集成
- [ ] 测试阈值签名

**验收标准**:
- ✅ 7/13阈值正确
- ✅ 三级Slash生效
- ✅ BLS验证通过

---

#### 7.2 BLS签名库集成 (3天)

**任务清单**:
- [ ] 选择BLS库 (@noble/curves 或 solidity-bls)
- [ ] 签名聚合实现
- [ ] 验证函数实现
- [ ] Gas优化
- [ ] 测试覆盖

---

## Phase 4: 集成与测试 (2周)

### Week 13: 完整集成测试

#### 8.1 E2E测试场景

**任务清单**:
- [ ] Traditional模式完整流程
- [ ] Super模式完整流程
- [ ] Hybrid模式完整流程
- [ ] Slash触发测试
- [ ] 声誉升级测试
- [ ] 多社区并行测试
- [ ] 边界条件测试

---

#### 8.2 安全审计准备

**任务清单**:
- [ ] 代码审查
- [ ] Slither静态分析
- [ ] Mythril符号执行
- [ ] 修复发现的问题
- [ ] 审计文档准备

---

### Week 14: 部署与文档

#### 9.1 测试网部署

**任务清单**:
- [ ] Sepolia部署脚本
- [ ] 合约验证 (Etherscan)
- [ ] 初始化配置
- [ ] DVT节点部署
- [ ] 监控系统上线

---

#### 9.2 文档完善

**任务清单**:
- [ ] 用户使用指南
- [ ] Operator操作手册
- [ ] API文档
- [ ] 安全最佳实践
- [ ] 常见问题FAQ

---

## Registry前端修改 (并行任务)

### Frontend Changes

**文件**: `registry/src/pages/operator/DeployWizard.tsx`

**任务清单**:
- [ ] 修改文档链接
  ```tsx
  // 修改前: "📚 Read the Deployment Guide"
  // 修改后: href="/launch-tutorial"
  ```
- [ ] 删除 Demo 链接
  ```tsx
  // 删除: "🎮 Try the Interactive Demo"
  ```

**文件**: `registry/src/pages/operator/deploy-v2/steps/Step2_WalletCheck.tsx`

**任务清单**:
- [ ] 修改文本
  ```tsx
  // 修改前: "Paymaster Deployed"
  // 修改后: "Paymaster Configuration"
  ```

**验收标准**:
- ✅ 链接跳转正确
- ✅ 文本显示正确

---

## 开发检查清单

### 每个合约完成时必须:

- [ ] ✅ Solidity代码编译通过
- [ ] ✅ 单元测试覆盖率 > 80%
- [ ] ✅ Gas优化完成
- [ ] ✅ NatSpec注释完整
- [ ] ✅ 事件正确触发
- [ ] ✅ 访问控制正确
- [ ] ✅ 重入保护
- [ ] ✅ 错误处理完善

### 每个阶段完成时必须:

- [ ] ✅ 集成测试通过
- [ ] ✅ 文档更新
- [ ] ✅ Git commit with message
- [ ] ✅ Tag (alpha.2, alpha.3, ...)
- [ ] ✅ 更新 Changes.md

---

## Git管理策略

### 分支命名

- `v2` - 主开发分支
- `v2-feature/registry-enhancement` - 功能分支
- `v2-feature/xpnts-system` - 功能分支

### Tag命名

- `v2.0.0-alpha.1` - 架构设计完成 ✅
- `v2.0.0-alpha.2` - Registry + Factory完成
- `v2.0.0-alpha.3` - SuperPaymaster核心完成
- `v2.0.0-beta.1` - Token系统完成
- `v2.0.0-beta.2` - DVT + BLS完成
- `v2.0.0-rc.1` - 集成测试完成
- `v2.0.0` - 正式发布

### Commit Message格式

```
feat: 功能描述

- 详细变更1
- 详细变更2

🤖 Generated with [Claude Code](https://claude.com/claude-code)

Co-Authored-By: Claude <noreply@anthropic.com>
```

---

## 资源链接

### 技术文档
- [V2-ARCHITECTURE-OVERVIEW.md](./V2-ARCHITECTURE-OVERVIEW.md)
- [V2-CONTRACT-SPECIFICATIONS.md](./V2-CONTRACT-SPECIFICATIONS.md)
- [V2-XPNTS-AND-MYSBT-DESIGN.md](./V2-XPNTS-AND-MYSBT-DESIGN.md)
- [V2-DVT-BLS-SLASH-MECHANISM.md](./V2-DVT-BLS-SLASH-MECHANISM.md)

### 外部依赖
- [ERC-4337 Account Abstraction](https://eips.ethereum.org/EIPS/eip-4337)
- [EIP-1167 Minimal Proxy](https://eips.ethereum.org/EIPS/eip-1167)
- [EIP-2612 Permit](https://eips.ethereum.org/EIPS/eip-2612)
- [BLS Signatures](https://github.com/paulmillr/noble-curves)
- [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts)

---

## 当前状态

**✅ 已完成**:
- 架构设计文档 (4个)
- v2 分支创建
- Tag v2.0.0-alpha.1
- Git push to remote

**🔄 进行中**:
- 准备开始 Phase 1: Registry增强

**📅 下一步**:
- 实现 Registry.sol CommunityProfile 存储
- 修改 registry 前端链接

---

**文档版本**: v2.0.0
**创建日期**: 2025-10-22
**最后更新**: 2025-10-22
**状态**: 实施中
