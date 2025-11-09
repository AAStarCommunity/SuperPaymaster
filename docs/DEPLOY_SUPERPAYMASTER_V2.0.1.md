# SuperPaymasterV2 v2.0.1 部署指南

**版本**: v2.0.1 (Oracle Security Fix)
**发布日期**: 2025-11-08
**安全等级**: 🔒 Medium → High (Oracle 安全修复)

---

## 🔐 版本更新内容

### 安全修复

**Chainlink Oracle 验证增强** (contracts/src/paymasters/v2/core/SuperPaymasterV2.sol:611-623)

添加了 Chainlink 行业标准的三层 Oracle 验证：

```solidity
(
    uint80 roundId,
    int256 ethUsdPrice,
    ,
    uint256 updatedAt,
    uint80 answeredInRound
) = ethUsdPriceFeed.latestRoundData();

// ✅ 第1层: 验证 Oracle 共识轮次（防止失败共识的价格数据）
if (answeredInRound < roundId) {
    revert InvalidConfiguration();
}

// ✅ 第2层: 价格时效性检查（1小时超时）
if (block.timestamp - updatedAt > 3600) {
    revert InvalidConfiguration();
}

// ✅ 第3层: 价格合理性边界（$100 - $100,000）
if (ethUsdPrice <= 0 || ethUsdPrice < MIN_ETH_USD_PRICE || ethUsdPrice > MAX_ETH_USD_PRICE) {
    revert InvalidConfiguration();
}
```

**参考实现**：
- Aave V3
- Compound V3
- MakerDAO
- Chainlink 官方文档

**Gas 开销**: +3 gas (可忽略)

---

## 📋 部署前准备

### 1. 环境变量配置

创建或更新 `.env` 文件：

```bash
# Network RPC
SEPOLIA_RPC_URL="https://sepolia.infura.io/v3/YOUR_KEY"
MAINNET_RPC_URL="https://mainnet.infura.io/v3/YOUR_KEY"

# Deployer
PRIVATE_KEY="0x..."

# Contract Dependencies
GTOKEN_STAKING="0x..."      # GTokenStaking 合约地址
REGISTRY="0x..."            # Registry 合约地址
ETH_USD_PRICE_FEED="0x..."  # Chainlink ETH/USD Price Feed
ENTRYPOINT_V07="0x..."      # EntryPoint v0.7 地址

# Verification
ETHERSCAN_API_KEY="YOUR_ETHERSCAN_API_KEY"
```

### 2. Chainlink Price Feed 地址

| 网络 | ETH/USD Price Feed | 更新频率 | 偏差阈值 |
|------|-------------------|---------|---------|
| Ethereum Mainnet | `0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419` | 1小时 | 0.5% |
| Sepolia Testnet | `0x694AA1769357215DE4FAC081bf1f309aDC325306` | 24小时 | 0.5% |
| Polygon | `0xAB594600376Ec9fD91F8e885dADF0CE036862dE0` | 27秒 | 0.5% |
| Arbitrum | `0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612` | 24小时 | 0.5% |

### 3. 验证现有合约

```bash
# 验证 GTokenStaking
cast call $GTOKEN_STAKING "VERSION()" --rpc-url $SEPOLIA_RPC_URL

# 验证 Registry
cast call $REGISTRY "VERSION()" --rpc-url $SEPOLIA_RPC_URL

# 验证 Chainlink Price Feed
cast call $ETH_USD_PRICE_FEED "latestRoundData()" --rpc-url $SEPOLIA_RPC_URL
```

---

## 🚀 部署步骤

### 方式 1: 使用部署脚本（推荐）

```bash
# 1. 确保环境变量已配置
source .env

# 2. 运行部署脚本
forge script script/DeploySuperPaymasterV2_0_1.s.sol:DeploySuperPaymasterV2_0_1 \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast \
  --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  -vvvv

# 3. 查看部署信息
cat contracts/deployments/superpaymaster-v2.0.1-sepolia.json
```

### 方式 2: 手动部署

```bash
# 1. 编译合约
forge build

# 2. 部署 SuperPaymasterV2
cast send --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --create $(cat out/SuperPaymasterV2.sol/SuperPaymasterV2.json | jq -r '.bytecode.object') \
  --constructor-args $(cast abi-encode "constructor(address,address,address)" $GTOKEN_STAKING $REGISTRY $ETH_USD_PRICE_FEED)

# 3. 配置 EntryPoint
cast send $SUPERPAYMASTER_ADDRESS "setEntryPoint(address)" $ENTRYPOINT_V07 \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY

# 4. 验证合约
forge verify-contract $SUPERPAYMASTER_ADDRESS \
  src/paymasters/v2/core/SuperPaymasterV2.sol:SuperPaymasterV2 \
  --constructor-args $(cast abi-encode "constructor(address,address,address)" $GTOKEN_STAKING $REGISTRY $ETH_USD_PRICE_FEED) \
  --etherscan-api-key $ETHERSCAN_API_KEY \
  --chain sepolia
```

---

## ✅ 部署后验证

### 1. 验证版本号

```bash
# 检查版本
cast call $SUPERPAYMASTER_ADDRESS "VERSION()(string)" --rpc-url $SEPOLIA_RPC_URL
# 预期: "2.0.1"

# 检查版本代码
cast call $SUPERPAYMASTER_ADDRESS "VERSION_CODE()(uint256)" --rpc-url $SEPOLIA_RPC_URL
# 预期: 20001
```

### 2. 验证依赖关系

```bash
# 检查 GTokenStaking
cast call $SUPERPAYMASTER_ADDRESS "GTOKEN_STAKING()(address)" --rpc-url $SEPOLIA_RPC_URL

# 检查 Registry
cast call $SUPERPAYMASTER_ADDRESS "REGISTRY()(address)" --rpc-url $SEPOLIA_RPC_URL

# 检查 EntryPoint
cast call $SUPERPAYMASTER_ADDRESS "ENTRY_POINT()(address)" --rpc-url $SEPOLIA_RPC_URL

# 检查 Price Feed
cast call $SUPERPAYMASTER_ADDRESS "ethUsdPriceFeed()(address)" --rpc-url $SEPOLIA_RPC_URL
```

### 3. 测试 Oracle 验证

```bash
# 获取当前 ETH 价格（应该成功）
cast call $ETH_USD_PRICE_FEED "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url $SEPOLIA_RPC_URL

# 验证价格在合理范围内 ($100 - $100,000)
```

### 4. 测试完整流程

```bash
# 运行集成测试
forge test --match-contract SuperPaymasterV2 -vv

# 运行特定测试
forge test --match-test test_PaymasterExecution -vvv
```

---

## 🔧 部署后配置

### 1. 设置基本参数

```bash
# 设置 aPNTs 代币地址
cast send $SUPERPAYMASTER_ADDRESS "setAPNTsToken(address)" $APNTS_TOKEN \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY

# 设置 SuperPaymaster Treasury
cast send $SUPERPAYMASTER_ADDRESS "setSuperPaymasterTreasury(address)" $TREASURY \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY

# 设置服务费率 (200 = 2%)
cast send $SUPERPAYMASTER_ADDRESS "setServiceFeeRate(uint256)" 200 \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

### 2. 配置 DVT Aggregator（可选）

```bash
# 设置 DVT Aggregator
cast send $SUPERPAYMASTER_ADDRESS "setDVTAggregator(address)" $DVT_AGGREGATOR \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY
```

### 3. EntryPoint 存款（必需）

```bash
# 为 SuperPaymaster 在 EntryPoint 中存入 ETH
cast send $ENTRYPOINT_V07 "depositTo(address)" $SUPERPAYMASTER_ADDRESS \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $PRIVATE_KEY \
  --value 1ether
```

---

## 📊 监控和测试

### 1. Oracle 健康监控

```bash
# 持续监控 Oracle 数据
while true; do
  echo "=== $(date) ==="
  cast call $ETH_USD_PRICE_FEED "latestRoundData()(uint80,int256,uint256,uint256,uint80)" --rpc-url $SEPOLIA_RPC_URL
  sleep 300  # 每5分钟检查一次
done
```

### 2. 测试用户操作

使用 registry 仓库的测试脚本：

```bash
cd ../registry
npm run test:sepolia:paymaster-v2
```

### 3. 性能基准测试

```bash
# Gas 快照
forge snapshot --match-contract SuperPaymasterV2

# 比较 v2.0.0 vs v2.0.1
forge snapshot --diff .gas-snapshot
```

---

## 🚨 安全检查清单

- [ ] ✅ 版本号正确 (2.0.1)
- [ ] ✅ 所有依赖合约地址正确
- [ ] ✅ Chainlink Price Feed 地址正确
- [ ] ✅ EntryPoint 配置正确
- [ ] ✅ Oracle 数据可以正常获取
- [ ] ✅ answeredInRound 验证生效
- [ ] ✅ 价格时效性检查生效
- [ ] ✅ 价格边界检查生效
- [ ] ✅ EntryPoint 有足够存款
- [ ] ✅ 合约 owner 正确
- [ ] ✅ 在区块浏览器上验证合约
- [ ] ✅ 48小时监控期无异常

---

## 📝 部署记录

### Sepolia Testnet

```json
{
  "network": "sepolia",
  "deployedAt": "2025-11-08",
  "deployer": "0x...",
  "contracts": {
    "SuperPaymasterV2": {
      "address": "0x...",
      "version": "2.0.1",
      "txHash": "0x...",
      "blockNumber": 12345678
    }
  },
  "dependencies": {
    "GTokenStaking": "0x...",
    "Registry": "0x...",
    "EntryPoint": "0x...",
    "PriceFeed": "0x694AA1769357215DE4FAC081bf1f309aDC325306"
  }
}
```

### Mainnet（待部署）

待外部审计完成后部署。

---

## 🔗 相关文档

- [Oracle 安全修复详细文档](./ORACLE_SECURITY_FIX.md)
- [仓库重构总结](./REFACTORING_SUMMARY_2025-11-08.md)
- [Chainlink Price Feeds](https://docs.chain.link/data-feeds/price-feeds/addresses)
- [Aave V3 Oracle Implementation](https://github.com/aave/aave-v3-core)

---

## 📞 支持

- **Issues**: https://github.com/AAStarCommunity/SuperPaymaster/issues
- **Documentation**: https://docs.aastar.community
- **Discord**: https://discord.gg/aastar

---

**部署完成后，请更新 shared-config 仓库中的合约地址配置。**
