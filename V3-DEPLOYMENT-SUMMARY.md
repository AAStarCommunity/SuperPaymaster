# SuperPaymaster V3 部署总结

## 部署信息

**部署时间**: 2025-10-06  
**网络**: Sepolia Testnet  
**部署者**: 0x411BD567E46C0781248dbB6a9211891C032885e5

## 合约地址

### ✅ 当前使用的合约 (参数正确 - 使用 cast 部署)

| 合约 | 地址 | Etherscan |
|------|------|-----------|
| **Settlement** | `0x6Bbf0C72805ECd4305EfCCF579c32d6F6d3041d5` | [查看](https://sepolia.etherscan.io/address/0x6Bbf0C72805ECd4305EfCCF579c32d6F6d3041d5) |
| **PaymasterV3** | `0x1568da4ea1E2C34255218b6DaBb2458b57B35805` | [查看](https://sepolia.etherscan.io/address/0x1568da4ea1E2C34255218b6DaBb2458b57B35805) |

**部署交易:**
- Settlement: [0x3fc149030d0f63fbbf27803d83c63187c72327ef20b5033b62c339a30f224749](https://sepolia.etherscan.io/tx/0x3fc149030d0f63fbbf27803d83c63187c72327ef20b5033b62c339a30f224749)
- PaymasterV3: [0x5eb5354dd89a134698151be4e0ec0e525e4d3e7fda0d2b703d93eda98a6a8167](https://sepolia.etherscan.io/tx/0x5eb5354dd89a134698151be4e0ec0e525e4d3e7fda0d2b703d93eda98a6a8167)

### ⚠️  旧部署 (参数错误 - 请勿使用)

| 合约 | 地址 | 问题 |
|------|------|------|
| Settlement (OLD) | `0x5Df95ECe6a35F55CeA2c02Da15c0ef1F6B795B85` | 构造函数参数错误:传入了 (registry, treasury) 而非 (owner, registry, threshold) |
| PaymasterV3 (OLD) | `0xf5E4E989df96d409184f58d9D58B27CEf838dE2a` | 基于错误的 Settlement 地址部署 |

## 部署参数

### Settlement 合约
```solidity
constructor(
    address initialOwner,      // 0x411BD567E46C0781248dbB6a9211891C032885e5
    address registryAddress,   // 0x4e6748C62d8EBE8a8b71736EAABBB79575A79575
    uint256 initialThreshold   // 100000000000000000000 (100 PNT)
)
```

### PaymasterV3 合约
```solidity
constructor(
    address _entryPoint,       // 0x0000000071727De22E5E9d8BAf0edAc6f37da032 (EntryPoint v0.7)
    address _owner,            // 0x411BD567E46C0781248dbB6a9211891C032885e5
    address _sbtContract,      // 0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f
    address _gasToken,         // 0x3e7B771d4541eC85c8137e950598Ac97553a337a (PNT Token)
    address _settlement,       // 0x6E590400121c18642548EE504164eb6B9Dcc3172 (Settlement)
    uint256 _minTokenBalance   // 10000000000000000000 (10 PNT)
)
```

## 依赖合约

| 合约 | 地址 | 用途 |
|------|------|------|
| **SuperPaymaster Registry** | `0x4e6748C62d8EBE8a8b71736EAABBB79575A79575` | Paymaster 注册管理 |
| **EntryPoint v0.7** | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | ERC-4337 EntryPoint |
| **SBT Contract** | `0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f` | 用户资格凭证 (Soul-Bound Token) |
| **PNT Token** | `0x3e7B771d4541eC85c8137e950598Ac97553a337a` | Gas 费用代币 |

## 问题发现与修复

### 问题描述
最初的部署脚本 `v3-deploy-simple.s.sol` 中,Settlement 合约的构造函数调用使用了错误的参数:

```solidity
// ❌ 错误 (v3-deploy-simple.s.sol 第一版)
abi.encode(registry, treasury)  // 只有2个参数

// ✅ 正确 (Settlement.sol 实际构造函数)
constructor(address initialOwner, address registryAddress, uint256 initialThreshold)
```

### 影响
- Settlement 合约的 `owner` 被错误设置为 Registry 地址
- Settlement 合约的 `registry` 被错误设置为 Treasury 地址  
- Settlement 合约缺少 `threshold` 参数初始化

### 修复
1. 修改部署脚本 `_deploySettlement` 函数
2. 使用正确的三个参数: `(owner, registry, threshold)`
3. 重新部署所有合约

## 重要说明

### Settlement 合约设计
Settlement 合约是**纯记账合约**,不处理实际资金转移:

- ✅ 记录 gas 费用 (recordGasFee)
- ✅ 批量标记结算状态 (settleFees, settleFeesByUsers)
- ✅ 查询 pending 余额 (pendingAmounts, getUserPendingRecords)
- ❌ **不执行** token 转账操作
- ❌ **不需要** treasury 地址参数

实际的资金转移需要通过其他机制(如链下处理或额外合约)完成。

## 编译配置

```toml
[profile.default]
solc_version = "0.8.28"
optimizer = true
optimizer_runs = 1000000
```

## 测试覆盖率

运行 `forge coverage` 结果:

| 文件 | Lines | Statements | Branches | Functions |
|------|-------|------------|----------|-----------|
| **Settlement.sol** | 99.07% | 97.65% | 82.86% | 100.00% |
| **PaymasterV3.sol** | 100.00% | 100.00% | 89.47% | 100.00% |
| **总计** | 99.45% | 98.60% | 85.19% | 100.00% |

## 自动化脚本

所有操作已脚本化,位于 `scripts/` 目录:

```bash
# 1. 完整部署 (包括 Settlement 和 PaymasterV3)
./scripts/deploy-v3.sh

# 2. 充值 ETH 到 PaymasterV3
./scripts/deposit-eth.sh <paymaster_address> [amount]

# 3. 注册 Paymaster 到 Registry
./scripts/register-paymaster.sh <paymaster_address> [feeRate] [name]

# 4. 运行集成测试
./scripts/integration-test.sh

# 5. 验证合约 (Etherscan)
./scripts/verify-contracts.sh
```

所有脚本会自动从 `.env.v3` 加载配置。

## 下一步操作

### 1. 验证合约 (Etherscan)

```bash
# 验证 Settlement
forge verify-contract \
  --compiler-version "0.8.28" \
  --optimizer-runs 1000000 \
  --constructor-args $(cast abi-encode "constructor(address,address,uint256)" "0x411BD567E46C0781248dbB6a9211891C032885e5" "0x4e6748C62d8EBE8a8b71736EAABBB79575A79575" "100000000000000000000") \
  0x6Bbf0C72805ECd4305EfCCF579c32d6F6d3041d5 \
  src/v3/Settlement.sol:Settlement \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --rpc-url $SEPOLIA_RPC_URL

# 验证 PaymasterV3
forge verify-contract \
  --compiler-version "0.8.28" \
  --optimizer-runs 1000000 \
  --constructor-args $(cast abi-encode "constructor(address,address,address,address,address,uint256)" "0x0000000071727De22E5E9d8BAf0edAc6f37da032" "0x411BD567E46C0781248dbB6a9211891C032885e5" "0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f" "0x3e7B771d4541eC85c8137e950598Ac97553a337a" "0x6Bbf0C72805ECd4305EfCCF579c32d6F6d3041d5" "10000000000000000000") \
  0x1568da4ea1E2C34255218b6DaBb2458b57B35805 \
  src/v3/PaymasterV3.sol:PaymasterV3 \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --rpc-url $SEPOLIA_RPC_URL
```

### 2. 注册 Paymaster ✅ 已完成

```bash
# 方法1: 使用脚本 (推荐)
./scripts/register-paymaster.sh

# 方法2: 手动执行
# 注意: registerPaymaster 需要3个参数 (address, feeRate, name)
cast send 0x4e67678AF714f6B5A8882C2e5a78B15B08a79575 \
  'registerPaymaster(address,uint256,string)' \
  0x1568da4ea1E2C34255218b6DaBb2458b57B35805 \
  100 \
  "PaymasterV3" \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --legacy

# 已注册
# TX: 0xee1ed51593f5ca79de9192dbac27a9b6ae883158dbe8eb205e9957f960451ec1
# Fee Rate: 100 (1%)
# Status: Active ✅
```

### 3. 充值 ETH 到 Paymaster ✅ 已完成

```bash
# 已充值 0.1 ETH
# TX: 0x493bc1e5f567be7c006f8c6210456f13b50616c5f1fd7c0b2c7ec585b35de571
cast send 0x1568da4ea1E2C34255218b6DaBb2458b57B35805 \
  --value 0.1ether \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --legacy
```

### 4. 运行集成测试

```bash
forge script script/v3-integration-test.s.sol \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast --legacy
```

## Git 操作

```bash
# 提交部署脚本修复
git add script/v3-deploy-simple.s.sol .env.v3 V3-DEPLOYMENT-SUMMARY.md
git commit -m "fix: correct Settlement constructor parameters in deployment script

- Fixed Settlement deployment to use correct 3-parameter constructor
- Settlement constructor: (owner, registry, threshold) not (registry, treasury)
- Redeployed contracts with correct parameters
- Updated .env.v3 with new contract addresses
- Settlement: 0x6E590400121c18642548EE504164eb6B9Dcc3172
- PaymasterV3: 0x24C952168FD0c9433b1723D6E9e3A504B8718172"

# 创建新标签
git tag -a v3.0.0 -m "SuperPaymaster V3 正式部署 (正确参数)"
git push origin main --tags
```

## 参考文档

- [ERC-4337 Account Abstraction](https://eips.ethereum.org/EIPS/eip-4337)
- [EntryPoint v0.7 Specification](https://github.com/eth-infinitism/account-abstraction)
- [Settlement Contract Design](./PRD-V3.md)
- [Integration Test Guide](./script/v3-integration-test.s.sol)
