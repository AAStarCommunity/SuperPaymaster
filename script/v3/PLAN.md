# SuperPaymaster V3 测试计划 - 分阶段执行

## 概述

本计划将 V3 端到端测试分解为多个独立、可验证的阶段。每个阶段都必须成功完成后才能进入下一阶段。

---

## 阶段 0: 环境准备 ✓

**目标**: 启动本地 Anvil 测试网

**脚本**: `test-local.sh`

**步骤**:
1. 启动 Anvil (chainId 31337)
2. 确认 RPC 端口 8545 可用
3. 设置测试账户环境变量

**验证**:
- [ ] Anvil 进程运行
- [ ] RPC 可访问：`curl http://127.0.0.1:8545`
- [ ] 默认账户有 10000 ETH

**账户**:
- Admin (Account 0): `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`
- User (Account 1): `0x70997970C51812dc3A010C7d01b50e0d17dc79C8`

---

## 阶段 1: 合约部署

**目标**: 部署所有 V3 核心合约

**脚本**: `01-deploy.js`

**步骤**:
1. 部署 EntryPoint
2. 部署 MockV3Aggregator (ETH/USD Price Feed)
3. 部署 GToken (治理代币)
4. 部署 GTokenStaking
5. 部署 MySBT
6. 部署 Registry
7. 部署 xPNTsToken (作为 aPNTs mock)
8. 部署 SuperPaymaster
9. 部署 xPNTsFactory
10. 部署 PaymasterFactory + V4.1i 实现
11. 部署 SimpleAccountFactory

**验证**:
- [ ] 所有合约有代码 (`getCode != '0x'`)
- [ ] config.json 包含所有合约地址
- [ ] 合约 owner 正确设置
- [ ] 记录所有合约地址和 gas 使用

**输出**: `config/deployed.json`

---

## 阶段 2: 合约初始化与关联

**目标**: 初始化合约并建立正确的依赖关系

**脚本**: `02-initialize.js`

**步骤**:
1. `MySBT.setRegistry(registry)`
2. `GTokenStaking.setRegistry(registry)`
3. 验证 Registry 的角色配置已正确初始化
4. 验证 SuperPaymaster 的 REGISTRY 引用

**验证**:
- [ ] MySBT.registry() == Registry 地址
- [ ] GTokenStaking.registry() == Registry 地址
- [ ] Registry 默认角色配置存在 (COMMUNITY, ENDUSER, PAYMASTER_AOA, etc.)
- [ ] SuperPaymaster.REGISTRY() == Registry 地址

**输出**: `config/initialized.json`

---

## 阶段 3: 账户资产准备

**目标**: 为测试账户准备必要的资产

**脚本**: `03-fund-accounts.js`

**步骤**:

### 3.1 ETH 分配
- [ ] Admin 钱包余额检查 (应有充足 ETH)
- [ ] User 钱包余额检查
- [ ] 预留 gas 费用估算

### 3.2 GToken 分配
- [ ] 验证 Admin 持有 GToken (来自部署时的 mint)
- [ ] 向 User 转账 100 GToken (用于注册测试)
- [ ] 记录余额快照

### 3.3 aPNTs 分配
- [ ] 向 Admin 分配 10000 aPNTs (Operator 质押用)
- [ ] 向 User 分配 1000 aPNTs (支付 gas 用)
- [ ] 记录余额快照

**验证**:
- [ ] Admin GToken >= 1000
- [ ] User GToken >= 100
- [ ] Admin aPNTs >= 10000
- [ ] User aPNTs >= 1000

**输出**: `logs/balances-snapshot.json`

---

## 阶段 4: 角色注册

**目标**: 注册必要的角色到 Registry

**脚本**: `04-register-roles.js`

**步骤**:

### 4.1 准备 - GToken Staking Approval
- [ ] Admin 授权 GTokenStaking 花费 GToken (MaxUint256)
- [ ] 验证 allowance

### 4.2 注册 Community 角色 (Operator)
- [ ] 准备 CommunityRoleData:
  ```json
  {
    "name": "TestCommunity",
    "ensName": "",
    "website": "",
    "description": "Local Test Community",
    "logoURI": "",
    "stakeAmount": 0  // 使用默认 minStake (10 GT)
  }
  ```
- [ ] Admin 调用 `Registry.registerRole(ROLE_COMMUNITY, admin, roleData)`
- [ ] 等待交易确认
- [ ] 验证 `Registry.hasRole(ROLE_COMMUNITY, admin) == true`
- [ ] 验证 GToken 已锁定到 GTokenStaking
- [ ] 验证 MySBT 已铸造给 Admin

### 4.3 部署测试用户的智能账户 (AA)
- [ ] 使用 SimpleAccountFactory 计算 AA 地址: `factory.getAddress(userSigner, salt=0)`
- [ ] 记录 AA 地址 (`senderAA`)

### 4.4 注册 EndUser 角色 (AA)
- [ ] 准备 EndUserRoleData:
  ```json
  {
    "account": "<senderAA>",
    "community": "<Admin地址>",
    "avatarURI": "",
    "ensName": "",
    "stakeAmount": 0  // 使用默认 (0 for EndUser)
  }
  ```
- [ ] Admin 调用 `Registry.registerRole(ROLE_ENDUSER, senderAA, roleData)`
- [ ] 验证 `Registry.hasRole(ROLE_ENDUSER, senderAA) == true`
- [ ] 验证 MySBT 已铸造给 senderAA

**验证**:
- [ ] Admin 拥有 COMMUNITY 角色
- [ ] senderAA 拥有 ENDUSER 角色
- [ ] Admin SBT tokenId 记录
- [ ] User SBT tokenId 记录
- [ ] Staking 合约锁定的 GToken 数量正确

**输出**: `config/roles-registered.json`

---

## 阶段 5: Operator 配置

**目标**: 配置 Admin 作为 SuperPaymaster 的 Operator

**脚本**: `05-configure-operator.js`

**步骤**:

### 5.1 配置 Operator 参数
- [ ] Admin 调用 `SuperPaymaster.configureOperator(xPNTsToken, treasury, exchangeRate)`
  - `xPNTsToken`: aPNTs 地址
  - `treasury`: Admin 地址
  - `exchangeRate`: 1e18 (1:1)
- [ ] 验证 `operators[admin].isConfigured == true`

### 5.2 Operator 充值 aPNTs
- [ ] Admin 授权 SuperPaymaster 花费 aPNTs
- [ ] Admin 调用 `SuperPaymaster.deposit(5000 aPNTs)`
- [ ] 验证 `operators[admin].aPNTsBalance >= 5000`

**验证**:
- [ ] Operator 已配置
- [ ] Operator 余额充足
- [ ] 记录配置参数

**输出**: `config/operator-configured.json`

---

## 阶段 6: 用户智能账户准备

**目标**: 部署并准备用户的智能账户

**脚本**: `06-prepare-user-aa.js`

**步骤**:

### 6.1 部署智能账户
- [ ] 检查 senderAA 是否已部署 (`getCode`)
- [ ] 如未部署，准备 initCode:
  ```
  initCode = factory.address + factory.createAccount(userSigner, 0).data
  ```

### 6.2 资金准备
- [ ] Admin 向 senderAA 转账 0.5 ETH (用于第一笔 approve 交易)
- [ ] Admin 向 senderAA 转账 1000 aPNTs (用于支付 Paymaster 费用)

**验证**:
- [ ] senderAA 地址已计算
- [ ] senderAA 持有 >= 0.5 ETH
- [ ] senderAA 持有 >= 1000 aPNTs

**输出**: `config/user-aa-prepared.json`

---

## 阶段 7: Paymaster 授权 (Bootstrapping)

**目标**: senderAA 授权 SuperPaymaster 扣款

**脚本**: `07-approve-paymaster.js`

**步骤**:

### 7.1 构造 Approve UserOp (使用 ETH 支付 gas)
- [ ] 准备 callData: `aPNTs.approve(superPaymaster, MaxUint256)`
- [ ] 构造 UserOp:
  - `sender`: senderAA
  - `callData`: `senderAA.execute(aPNTs, 0, approveData)`
  - `paymasterAndData`: `0x` (不使用 Paymaster，用 ETH 支付)
  - `initCode`: 如果未部署则包含 initCode，否则 `0x`
- [ ] userSigner 签名 UserOp
- [ ] Admin 调用 `EntryPoint.handleOps([userOp], beneficiary)`

**验证**:
- [ ] senderAA 已部署 (如之前未部署)
- [ ] `aPNTs.allowance(senderAA, superPaymaster) == MaxUint256`
- [ ] 记录交易 hash 和 gas 使用

**输出**: `logs/approve-tx.json`

---

## 阶段 8: 无 Gas 交易测试

**目标**: 使用 SuperPaymaster 执行无 gas 交易

**脚本**: `08-gasless-transaction.js`

**步骤**:

### 8.1 构造 Gasless UserOp
- [ ] 准备测试逻辑 callData (例如: `senderAA.execute(anyContract, 0, anyData)`)
- [ ] 构造 UserOp:
  - `sender`: senderAA
  - `callData`: 上述 callData
  - `paymasterAndData`: `[SuperPaymaster地址(20字节)][Operator地址(20字节)]`
  - `initCode`: `0x` (已部署)
- [ ] userSigner 签名 UserOp
- [ ] Admin 调用 `EntryPoint.handleOps([userOp], beneficiary)`

### 8.2 验证结果
- [ ] 交易成功
- [ ] Operator aPNTs 余额减少 (扣除 gas 费)
- [ ] User aPNTs 余额减少 (支付 xPNTs 费用)
- [ ] Protocol Treasury 收到 2% 手续费
- [ ] Operator Treasury 收到 98% 费用

**验证**:
- [ ] UserOp 成功执行
- [ ] 费用扣除正确
- [ ] 记录 gas 消耗和费用明细

**输出**: `logs/gasless-tx.json`

---

## 阶段 9: PaymasterV4.1i 测试 (可选)

**目标**: 测试 PaymasterFactory 和 V4.1i

**脚本**: `09-test-paymaster-v4.js`

*(详细步骤待定)*

---

## 执行流程

### 方式 1: 逐步执行
```bash
cd script/v3

# 阶段 0
./test-local.sh --stage 0  # 启动 Anvil

# 阶段 1-8
node 01-deploy.js
node 02-initialize.js
node 03-fund-accounts.js
node 04-register-roles.js
node 05-configure-operator.js
node 06-prepare-user-aa.js
node 07-approve-paymaster.js
node 08-gasless-transaction.js
```

### 方式 2: 一键执行所有阶段
```bash
./test-local.sh --all
```

---

## 目录结构

```
script/v3/
├── PLAN.md                    # 本文档
├── test-local.sh              # 主控脚本
├── 01-deploy.js               # 阶段 1
├── 02-initialize.js           # 阶段 2
├── 03-fund-accounts.js        # 阶段 3
├── 04-register-roles.js       # 阶段 4
├── 05-configure-operator.js   # 阶段 5
├── 06-prepare-user-aa.js      # 阶段 6
├── 07-approve-paymaster.js    # 阶段 7
├── 08-gasless-transaction.js  # 阶段 8
├── config/
│   ├── deployed.json          # 阶段 1 输出
│   ├── initialized.json       # 阶段 2 输出
│   ├── roles-registered.json  # 阶段 4 输出
│   ├── operator-configured.json  # 阶段 5 输出
│   └── user-aa-prepared.json  # 阶段 6 输出
└── logs/
    ├── balances-snapshot.json # 阶段 3 输出
    ├── approve-tx.json        # 阶段 7 输出
    └── gasless-tx.json        # 阶段 8 输出
```

---

## 错误处理

每个阶段都应：
1. 检查前置条件 (依赖的之前阶段输出)
2. 执行操作
3. 验证结果
4. 保存状态快照
5. 如果失败，输出清晰的错误信息和恢复建议

---

## 下一步

现在开始实现各个阶段的脚本。
