# Stage 2: 本地 Anvil 测试完整指南（新手版）

## 📋 目标

- **业务覆盖率**: 85%+
- **测试类型**: 本地 Anvil 区块链集成测试
- **适用场景**: 合约修改后的完整回归测试

---

## 🛠️ 前置准备

### 1. 环境要求

```bash
# 检查工具版本
forge --version  # Foundry 0.2.0+
node --version   # Node.js 16+
pnpm --version   # pnpm 8+
anvil --version  # Anvil (Foundry 自带)
```

### 2. 项目结构

```
SuperPaymaster/          # 合约项目
├── contracts/src/       # 合约源码
├── script/v3/          # 部署脚本
└── foundry.toml        # Foundry 配置

aastar-sdk/             # SDK 测试项目
├── scripts/            # 测试脚本
├── .env.v3            # Anvil 配置
└── package.json
```

---

## 📝 完整测试流程

### Step 1: 编译合约

```bash
cd SuperPaymaster

# 清理旧的编译产物
forge clean

# 编译所有合约
forge build

# 验证编译成功
# 输出应该显示: "Compiler run successful"
```

**预期输出**:
```
Compiling 86 files with Solc 0.8.28
Solc 0.8.28 finished in 347.88s
Compiler run successful
```

**如果失败**: 检查 Solidity 版本和依赖是否正确安装。

---

### Step 2: 启动 Anvil 本地链

```bash
# 在新终端窗口启动 Anvil
anvil --port 8545 --chain-id 31337

# 保持这个终端运行，不要关闭
```

**预期输出**:
```
Available Accounts
==================
(0) 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 (10000.000000000000000000 ETH)
...

Listening on 127.0.0.1:8545
```

**验证**: 在浏览器访问 `http://127.0.0.1:8545` 应该返回 JSON-RPC 响应。

---

### Step 3: 部署合约到 Anvil

```bash
# 在 SuperPaymaster 目录
cd SuperPaymaster

# 设置部署私钥（Anvil 默认账户）
export PRIVATE_KEY_JASON=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

# 执行部署脚本
forge script script/v3/SetupV3.s.sol \
  --tc SetupV3 \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --private-key $PRIVATE_KEY_JASON
```

**预期输出**:
```
Script ran successfully.
ONCHAIN EXECUTION COMPLETE & SUCCESSFUL.
Estimated gas used: 36,161,319
```

**部署的合约** (12个):
- GToken
- GTokenStaking
- Registry
- MySBT
- SuperPaymasterV3
- xPNTsFactory
- PaymasterFactory
- PaymasterV4_1i (Implementation)
- PaymasterV4_1i (Proxy)
- SimpleAccountFactory
- MockEntryPoint
- aPNTs Token

**部署地址保存位置**: `script/v3/config.json`

---

### Step 4: 提取合约 ABI

```bash
# 在 SuperPaymaster 目录
cd SuperPaymaster

# 运行 ABI 提取脚本
./scripts/extract_abis.sh

# 验证 ABI 文件已生成
ls -l abi/*.json | wc -l
# 应该输出: 14
```

**生成的 ABI 文件**:
```
abi/GToken.json
abi/GTokenStaking.json
abi/Registry.json
abi/MySBT.json
abi/SuperPaymasterV3.json
abi/xPNTsFactory.json
abi/PaymasterFactory.json
abi/PaymasterV4_1i.json
abi/SimpleAccountFactory.json
abi/MockEntryPoint.json
abi/aPNTs.json
abi/IEntryPoint.json
abi/IERC20.json
abi/IERC721.json
```

---

### Step 5: 配置 SDK 环境

```bash
# 切换到 SDK 目录
cd ../aastar-sdk

# 检查 .env.v3 配置
cat .env.v3
```

**必需的配置项**:
```bash
# RPC 配置
RPC_URL=http://127.0.0.1:8545

# 合约地址（从 script/v3/config.json 复制）
SUPER_PAYMASTER=0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e
APNTS=0x8A791620dd6260079BF849Dc5567aDC3F2FdC318
MOCK_ENTRY_POINT=0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
REGISTRY_ADDR=0x0165878A594ca255338adfa4d48449f69242Eb8F
SBT_ADDR=0x5FC8d32690cc91D4c39d9d3abcBD16989F875707
PAYMASTERV4_PROXY=0x524F04724632eED237cbA3c37272e018b3A7967e
ENTRY_POINT_ADDR=0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512

# 测试账户
ADMIN_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ALICE_AA_ACCOUNT=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
RECEIVER=0x90F79bf6EB2c4f870365E785982E1f101E93b906
```

**自动同步脚本** (可选):
```bash
# 创建同步脚本
cat > sync_addresses.sh <<'EOF'
#!/bin/bash
cd ../SuperPaymaster
CONFIG=$(cat script/v3/config.json)
cd ../aastar-sdk

# 提取地址并更新 .env.v3
echo "SUPER_PAYMASTER=$(echo $CONFIG | jq -r .superPaymaster)" >> .env.v3
echo "APNTS=$(echo $CONFIG | jq -r .aPNTs)" >> .env.v3
# ... 其他地址
EOF

chmod +x sync_addresses.sh
./sync_addresses.sh
```

---

### Step 6: 运行测试套件

#### 6.1 核心功能测试 (必须全部通过)

```bash
# 在 aastar-sdk 目录

# 1. Admin 模块测试
pnpm ts-node scripts/06_local_test_v3_admin.ts

# 预期输出:
# ✅ Operator configured
# ✅ Operator paused
# ✅ Operator unpaused
# ✅ Reputation updated to 500
# ✅ APNTs token updated

# 2. Funding 模块测试
pnpm ts-node scripts/06_local_test_v3_funding.ts

# 预期输出:
# Initial Operator Balance: 0 aPNTs
# ✅ notifyDeposit Success
# ✅ Withdrawn. New Balance: 9.9 aPNTs

# 3. Execution 模块测试
pnpm ts-node scripts/06_local_test_v3_execution.ts

# 预期输出:
# 🧪 Running SuperPaymaster V3 Execution Modular Test...
# ✅ UserOp Execution finished
```

#### 6.2 高级功能测试 (可选)

```bash
# 4. Reputation 系统测试
pnpm ts-node scripts/06_local_test_v3_reputation.ts

# 5. 完整流程测试
pnpm ts-node scripts/06_local_test_v3_full.ts

# 6. 审计测试
pnpm ts-node scripts/07_local_test_v3_audit.ts

# 7. Registry 生命周期测试
pnpm ts-node scripts/08_local_test_registry_lifecycle.ts
```

---

## 📊 业务覆盖率检查表

### 核心业务流程 (必须 100%)

- [x] **Operator 管理**
  - [x] 配置 Operator (xPNTs, treasury, exchangeRate)
  - [x] 暂停/恢复 Operator
  - [x] 更新 Operator 声誉
  - [x] 设置 aPNTs 代币地址

- [x] **资金管理**
  - [x] Push Model 充值 (notifyDeposit)
  - [x] 提现 (withdraw)
  - [x] 余额查询
  - [x] 协议收入提取

- [x] **UserOp 执行**
  - [x] UserOp 构造
  - [x] Paymaster 验证
  - [x] Gas 代付
  - [x] PostOp 结算

### 扩展业务流程 (目标 85%+)

- [ ] **Community 管理**
  - [ ] Community 注册
  - [ ] Community 配置
  - [ ] Community 退出
  - [ ] 命名空间管理

- [ ] **EndUser 管理**
  - [ ] EndUser 注册
  - [ ] EndUser 退出
  - [ ] AA 账户绑定

- [ ] **信誉系统**
  - [ ] 信誉计算
  - [ ] 信用等级映射
  - [ ] 信用额度查询

- [ ] **SBT 管理**
  - [ ] SBT 铸造
  - [ ] SBT 查询
  - [ ] SBT 停用

---

## 🐛 常见问题排查

### 问题 1: 编译失败

**症状**: `forge build` 报错

**可能原因**:
1. Solidity 版本不匹配
2. 依赖未安装

**解决方案**:
```bash
# 更新依赖
forge install

# 清理并重新编译
forge clean && forge build
```

---

### 问题 2: Anvil 连接失败

**症状**: `Error: error sending request for url (http://127.0.0.1:8545/)`

**可能原因**:
1. Anvil 未启动
2. 端口被占用

**解决方案**:
```bash
# 检查 Anvil 是否运行
lsof -i :8545

# 如果端口被占用，杀掉进程
kill -9 <PID>

# 重新启动 Anvil
anvil --port 8545 --chain-id 31337
```

---

### 问题 3: 部署失败 - ReentrancyGuardReentrantCall

**症状**: `ReentrancyGuardReentrantCall()` 错误

**原因**: PaymasterFactory 的 `deployPaymasterDefault` 函数已删除

**解决方案**:
```solidity
// 使用 deployPaymaster 替代
paymasterFactory.deployPaymaster("v4.1i", "");
```

---

### 问题 4: 测试失败 - ABI 不匹配

**症状**: `Error: incorrect data length`

**原因**: `operators()` 函数返回值数量不匹配

**解决方案**:
```typescript
// 确保使用 9 字段 ABI
'function operators(address) view returns (
  address xPNTsToken,      // 0
  bool isConfigured,       // 1
  bool isPaused,           // 2
  address treasury,        // 3
  uint96 exchangeRate,     // 4
  uint256 aPNTsBalance,    // 5
  uint256 totalSpent,      // 6
  uint256 totalTxSponsored,// 7
  uint256 reputation       // 8
)'
```

---

### 问题 5: 测试失败 - 缺少环境变量

**症状**: `Error: Missing ENTRY_POINT_ADDR`

**解决方案**:
```bash
# 检查 .env.v3 是否包含所有必需变量
cat .env.v3 | grep ENTRY_POINT_ADDR

# 如果缺失，手动添加
echo "ENTRY_POINT_ADDR=0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512" >> .env.v3
```

---

## 🔄 完整测试流程脚本

创建一键测试脚本 `run_full_test.sh`:

```bash
#!/bin/bash
set -e

echo "🚀 Starting Full Stage 2 Test Suite..."

# Step 1: 编译
echo "📦 Step 1: Building contracts..."
cd SuperPaymaster
forge clean
forge build
cd ..

# Step 2: 启动 Anvil (后台)
echo "⛓️ Step 2: Starting Anvil..."
pkill anvil || true
sleep 2
anvil --port 8545 --chain-id 31337 > /tmp/anvil.log 2>&1 &
ANVIL_PID=$!
sleep 3

# Step 3: 部署
echo "🚢 Step 3: Deploying contracts..."
cd SuperPaymaster
export PRIVATE_KEY_JASON=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
forge script script/v3/SetupV3.s.sol \
  --tc SetupV3 \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast \
  --private-key $PRIVATE_KEY_JASON
cd ..

# Step 4: 提取 ABI
echo "📄 Step 4: Extracting ABIs..."
cd SuperPaymaster
./scripts/extract_abis.sh
cd ..

# Step 5: 运行测试
echo "🧪 Step 5: Running tests..."
cd aastar-sdk

echo "  ✅ Admin Test..."
pnpm ts-node scripts/06_local_test_v3_admin.ts

echo "  ✅ Funding Test..."
pnpm ts-node scripts/06_local_test_v3_funding.ts

echo "  ✅ Execution Test..."
pnpm ts-node scripts/06_local_test_v3_execution.ts

cd ..

# 清理
echo "🧹 Cleaning up..."
kill $ANVIL_PID

echo "✅ All tests completed successfully!"
```

**使用方法**:
```bash
chmod +x run_full_test.sh
./run_full_test.sh
```

---

## 📈 测试报告模板

测试完成后，填写以下报告：

```markdown
# Stage 2 测试报告

**测试日期**: 2025-12-22
**测试人员**: [你的名字]
**合约版本**: V3.0.0

## 测试环境
- Anvil Chain ID: 31337
- Forge Version: [版本号]
- Node Version: [版本号]

## 测试结果

### 核心测试 (3/3)
- [x] Admin Module Test - PASS
- [x] Funding Module Test - PASS
- [x] Execution Module Test - PASS

### 扩展测试 (0/4)
- [ ] Reputation Test - NOT RUN
- [ ] Full Flow Test - NOT RUN
- [ ] Audit Test - NOT RUN
- [ ] Registry Lifecycle Test - NOT RUN

## 业务覆盖率
- **核心流程**: 100% (3/3)
- **扩展流程**: 0% (0/4)
- **总体覆盖率**: 42.8% (3/7)

## 发现的问题
1. [问题描述]
2. [问题描述]

## 建议
1. [改进建议]
2. [改进建议]
```

---

## 🎯 下一步

完成 Stage 2 测试后：

1. **达到 85% 覆盖率**: 运行所有 7 个测试脚本
2. **修复发现的问题**: 根据测试结果修改合约
3. **准备 Stage 3**: Sepolia 测试网部署
4. **文档更新**: 更新测试文档和 README

---

## 📚 参考文档

- [Stage 2 Business Scenarios](./stage2_business_scenarios.md) - 业务场景详解
- [Role-Entity Test Matrix](./role_entity_test_matrix.md) - 角色-实体测试矩阵
- [Walkthrough](./walkthrough.md) - 详细的执行记录
- [Implementation Plan](./implementation_plan.md) - 实施计划

---

**最后更新**: 2025-12-22
**维护者**: Gemini AI Agent
