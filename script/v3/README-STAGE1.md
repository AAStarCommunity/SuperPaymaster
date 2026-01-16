# 阶段 1 - 合约部署

## ✅ 完成的工作

### 1. 目录结构创建
```
script/v3/
├── PLAN.md                    # 完整的 9 阶段测试计划
├── 01-deploy.sh               # 阶段 1 部署脚本
├── helpers/
│   └── verify-deployment.js   # 合约验证辅助脚本
├── config/                    # 将存储部署结果
└── logs/                      # 日志目录
```

### 2. 脚本文件

#### `PLAN.md` - 分阶段测试计划
- 定义了 9 个独立的测试阶段
- 每个阶段有明确的目标、步骤、验证点
- 包含详细的错误处理指导

#### `01-deploy.sh` - 部署脚本 
- 检查 Anvil 运行状态
- 调用 `SetupV3.s.sol` 部署所有合约
- 验证部署结果
- 保存 config.json

#### `helpers/verify-deployment.js` - 验证脚本
- 检查所有合约地址是否有代码
- 输出每个合约的状态

### 3. 核心合约部署修复

修复了 `SetupV3.s.sol` 中的问题：
- 在 Anvil 本地测试时，使用 broadcaster (Account 0) 作为 deployer
- GToken 部署后立即 mint 100M 代币给 deployer  
- 确保所有权限和资产正确分配

## 📋 部署的合约列表

1. **EntryPoint** - ERC-4337 入口点
2. **MockV3Aggregator** - 价格预言机 (本地测试)
3. **GToken** - 治理代币
4. **GTokenStaking** - 质押合约
5. **MySBT** - Soul Bound Token
6. **Registry** - 核心注册表
7. **xPNTsToken** (aPNTs) - 积分代币
8. **SuperPaymaster** - V3 Paymaster
9. **xPNTsFactory** - 积分工厂
10. **PaymasterFactory** - Paymaster 工厂
11. **PaymasterV4_1i** - V4.1i 实现
12. **SimpleAccountFactory** - 智能账户工厂

## 🎯 下一阶段准备

### 阶段 2: 合约初始化 (待实现)
需要创建: `02-initialize.js`

**任务**:
1. `MySBT.setRegistry(registry)` - 已在 SetupV3 中完成
2. `GTokenStaking.setRegistry(registry)` - 已在 SetupV3 中完成
3. 验证 Registry 的默认角色配置
4. 验证 SuperPaymaster 的引用

### 阶段 3: 账户资产准备  (待实现)
需要创建: `03-fund-accounts.js`

**任务**:
1. 检查 Admin 的 GToken 余额 (应该有 100M)
2. 向 User 转账 GToken (100 GT)
3. 向 Admin/User 分配 aPNTs
4. 记录余额快照

### 阶段 4: 角色注册 (待实现)
需要创建: `04-register-roles.js`

**关键点** (根据用户反馈):
- Admin 注册为 COMMUNITY 角色 (Operator/Committee)
- Admin 可以使用 GToken 和 points airdrop 社区成员资格
- Admin 可以直接 mint MySBT 给社区成员
- Admin 可以直接 transfer xPNTs/aPNTs 给社区成员
- 创建两个测试用户:
  - 用户 A: 用于 PaymasterV4.1i 测试
  - 用户 B: 用于 SuperPaymaster 测试

## ⚠️ 当前状态

正在部署合约到本地 Anvil...

## 📝 提交准备

完成阶段 1 后需要提交的文件：
```
git add script/v3/PLAN.md
git add script/v3/01-deploy.sh  
git add script/v3/helpers/verify-deployment.js
git add script/v3/SetupV3.s.sol
git commit -m "feat: 实现 V3 测试阶段 1 - 合约部署脚本

- 创建分阶段测试计划 (PLAN.md)
- 实现阶段 1 部署脚本 (01-deploy.sh)
- 添加合约验证辅助工具
- 修复 SetupV3.s.sol 的资产分配逻辑
- 为 Anvil 本地测试做优化"
```
