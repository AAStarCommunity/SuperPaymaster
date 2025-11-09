# SuperPaymaster V3 部署脚本

本目录包含 SuperPaymaster V3 的自动化部署和管理脚本。

## 快速开始

### 1. 配置环境变量

确保 `.env.v3` 文件已正确配置:

```bash
# 必需的环境变量
PRIVATE_KEY=0x...
SEPOLIA_RPC_URL=https://...
ETHERSCAN_API_KEY=...
SBT_CONTRACT_ADDRESS=0x...
GAS_TOKEN_ADDRESS=0x...
SETTLEMENT_THRESHOLD=100000000000000000000
MIN_TOKEN_BALANCE=10000000000000000000
```

### 2. 完整部署流程

```bash
# Step 1: 部署合约
./scripts/deploy-v3.sh

# Step 2: 充值 ETH
./scripts/deposit-eth.sh 0x<paymaster_address> 0.1ether

# Step 3: 注册到 Registry
./scripts/register-paymaster.sh 0x<paymaster_address> 100 "PaymasterV3"

# Step 4: 运行集成测试
./scripts/integration-test.sh

# Step 5: 验证合约 (可选)
./scripts/verify-contracts.sh
```

## 脚本说明

### deploy-v3.sh

**功能**: 使用 cast 部署 Settlement 和 PaymasterV3 合约

**用法**:
```bash
./scripts/deploy-v3.sh
```

**输出**:
- Settlement 合约地址和交易哈希
- PaymasterV3 合约地址和交易哈希
- 部署信息 JSON 文件 (`deployments/v3-sepolia-<timestamp>.json`)

**示例**:
```bash
$ ./scripts/deploy-v3.sh
========================================
SuperPaymaster V3 Deployment Script
========================================

[1/3] Compiling contracts...
[2/3] Deploying Settlement contract...
✅ Settlement deployed!
   Address: 0x6Bbf0C72805ECd4305EfCCF579c32d6F6d3041d5
   TX: 0x3fc149030d0f63fbbf27803d83c63187c72327ef20b5033b62c339a30f224749

[3/3] Deploying PaymasterV3 contract...
✅ PaymasterV3 deployed!
   Address: 0x1568da4ea1E2C34255218b6DaBb2458b57B35805
   TX: 0x5eb5354dd89a134698151be4e0ec0e525e4d3e7fda0d2b703d93eda98a6a8167
```

---

### deposit-eth.sh

**功能**: 给 PaymasterV3 充值 ETH

**用法**:
```bash
./scripts/deposit-eth.sh <paymaster_address> [amount]
```

**参数**:
- `paymaster_address`: PaymasterV3 合约地址 (必需)
- `amount`: 充值金额 (可选,默认 0.1ether)

**示例**:
```bash
$ ./scripts/deposit-eth.sh 0x1568da4ea1E2C34255218b6DaBb2458b57B35805
Depositing 0.1ether to PaymasterV3...
Address: 0x1568da4ea1E2C34255218b6DaBb2458b57B35805
✅ Deposit successful!
Transaction: https://sepolia.etherscan.io/tx/0x493bc1e5f567be7c006f8c6210456f13b50616c5f1fd7c0b2c7ec585b35de571
Current balance: 100000000000000000 wei (0.1 ETH)
```

---

### register-paymaster.sh

**功能**: 注册 PaymasterV3 到 SuperPaymaster Registry

**用法**:
```bash
./scripts/register-paymaster.sh <paymaster_address> [feeRate] [name]
```

**参数**:
- `paymaster_address`: PaymasterV3 合约地址 (必需)
- `feeRate`: 费率,单位 basis points (可选,默认 100 = 1%)
- `name`: Paymaster 名称 (可选,默认 "PaymasterV3")

**说明**:
- 如果已注册,脚本会跳过并显示当前状态
- Registry 地址: `0x4e67678AF714f6B5A8882C2e5a78B15B08a79575`

**示例**:
```bash
$ ./scripts/register-paymaster.sh 0x1568da4ea1E2C34255218b6DaBb2458b57B35805
========================================
Register PaymasterV3 to Registry
========================================

Registry: 0x4e67678AF714f6B5A8882C2e5a78B15B08a79575
Paymaster: 0x1568da4ea1E2C34255218b6DaBb2458b57B35805

Checking registration status...

Registering PaymasterV3 to Registry...
Fee Rate: 100 (1.00%)
Name: PaymasterV3
✅ Registration successful!
Transaction: https://sepolia.etherscan.io/tx/0xee1ed51593f5ca79de9192dbac27a9b6ae883158dbe8eb205e9957f960451ec1
Active status: true
Fee Rate: 100 (1.00%)
```

---

### integration-test.sh

**功能**: 运行 V3 集成测试脚本

**用法**:
```bash
./scripts/integration-test.sh
```

**测试内容**:
1. 检查合约配置 (Registry, Threshold, EntryPoint)
2. 模拟 fee recording (需要 Paymaster 已注册)
3. 检查 pending balance
4. 执行批量结算
5. 验证最终状态

**示例**:
```bash
$ ./scripts/integration-test.sh
========================================
SuperPaymaster V3 Integration Test
========================================

Contract Addresses:
Settlement:  0x6Bbf0C72805ECd4305EfCCF579c32d6F6d3041d5
PaymasterV3: 0x1568da4ea1E2C34255218b6DaBb2458b57B35805

Running integration test script...
[Test 1] Checking contract configuration...
  Settlement Registry: 0x4e6748C62d8EBE8a8b71736EAABBB79575A79575
  Settlement Threshold: 100000000000000000000
  PaymasterV3 EntryPoint: 0x0000000071727De22E5E9d8BAf0edAc6f37da032
  [OK] Configuration verified
```

---

### verify-contracts.sh

**功能**: 在 Etherscan 上验证 Settlement 和 PaymasterV3 合约

**用法**:
```bash
./scripts/verify-contracts.sh
```

**要求**:
- `ETHERSCAN_API_KEY` 必须在 `.env.v3` 中配置
- 合约地址必须在 `.env.v3` 中配置

**示例**:
```bash
$ ./scripts/verify-contracts.sh
========================================
Verify Contracts on Etherscan
========================================

[1/2] Verifying Settlement contract...
Address: 0x6Bbf0C72805ECd4305EfCCF579c32d6F6d3041d5
Start verifying contract...
✅ Contract successfully verified

[2/2] Verifying PaymasterV3 contract...
Address: 0x1568da4ea1E2C34255218b6DaBb2458b57B35805
Start verifying contract...
✅ Contract successfully verified
```

## 常见问题

### Q: 脚本执行权限错误

**A**: 确保脚本有执行权限:
```bash
chmod +x scripts/*.sh
```

### Q: 环境变量未找到

**A**: 确保在项目根目录执行脚本,并且 `.env.v3` 文件存在:
```bash
cd /path/to/SuperPaymaster-Contract
ls .env.v3  # 确认文件存在
./scripts/deploy-v3.sh
```

### Q: Registry 注册失败

**A**: 检查 Registry 合约函数签名。V3 的 Registry 需要3个参数:
```solidity
function registerPaymaster(
    address _paymaster,
    uint256 _feeRate,      // basis points (100 = 1%)
    string memory _name
) external;
```

### Q: 集成测试中 fee recording 失败

**A**: 这是正常的。Settlement 合约只允许**已注册的 Paymaster 合约**调用 `recordGasFee()`。测试脚本从 deployer 账户调用,所以会被拒绝。实际使用时,PaymasterV3 合约会在 `postOp()` 中调用。

## 部署检查清单

- [ ] 编译合约 `forge build`
- [ ] 部署 Settlement 和 PaymasterV3
- [ ] 给 PaymasterV3 充值 ETH (至少 0.1 ETH)
- [ ] 注册 PaymasterV3 到 Registry
- [ ] 验证注册状态 (isActive = true)
- [ ] 运行集成测试
- [ ] (可选) 在 Etherscan 验证合约
- [ ] 更新 .env.v3 中的合约地址
- [ ] 提交部署信息到 Git

## 参考文档

- [V3-DEPLOYMENT-SUMMARY.md](../V3-DEPLOYMENT-SUMMARY.md) - 完整部署文档
- [PRD-V3.md](../PRD-V3.md) - V3 产品需求文档
- [.env.v3](../.env.v3) - 环境变量配置模板
