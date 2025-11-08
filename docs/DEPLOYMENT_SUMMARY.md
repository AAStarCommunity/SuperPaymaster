# SuperPaymaster v2 部署总结

**部署日期**: 2025-11-08
**网络**: Sepolia Testnet
**部署者**: 0x411BD567E46C0781248dbB6a9211891C032885e5

---

## ✅ 部署完成

### 1. Registry v2.2.0
- **地址**: `0x028aB52B4E0EF26820043ca4F1B5Fe14FfC1EF75`
- **版本**: 2.2.0 (VERSION_CODE: 20200)
- **Gas Used**: 6,956,417
- **新特性**:
  - MySBT-style auto-stake registration
  - `registerCommunityWithAutoStake()` 一键注册+质押
  - Node type configuration (AOA/Super/ANode/KMS)

### 2. SuperPaymasterV2 v2.0.1
- **地址**: `0xfaB5B2A129DF8308a70DA2fE77c61001e4Df58BC`
- **版本**: 2.0.1 (VERSION_CODE: 20001)
- **Gas Used**: 4,722,462
- **安全更新**:
  - Chainlink oracle answeredInRound 验证
  - 价格数据 staleness check (1 hour)
  - 价格边界验证 ($100 - $100,000)

### 3. Locker 配置 ✅
- **GTokenStaking**: `0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0`
- **配置的 Lockers**:
  1. **MySBT** (`0xD1e6BDfb907EacD26FF69a40BBFF9278b1E7Cf5C`) - 1% 费率
  2. **SuperPaymasterV2** (`0xfaB5B2A129DF8308a70DA2fE77c61001e4Df58BC`) - 1-5% 时间阶梯费率
  3. **Registry** (`0x028aB52B4E0EF26820043ca4F1B5Fe14FfC1EF75`) - 2% 费率

---

## 📊 依赖关系图

```
GToken (0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc)
  ↓
GTokenStaking v2.0.1 (0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0)
  ↓
Registry v2.2.0 (0x028aB52B4E0EF26820043ca4F1B5Fe14FfC1EF75)
  ↓
SuperPaymasterV2 v2.0.1 (0xfaB5B2A129DF8308a70DA2fE77c61001e4Df58BC)
  ↓
EntryPoint v0.7 (0x0000000071727De22E5E9d8BAf0edAc6f37da032)
```

**关键依赖验证**:
- ✅ SuperPaymasterV2.REGISTRY → Registry v2.2.0 ✓
- ✅ SuperPaymasterV2.GTOKEN_STAKING → GTokenStaking v2.0.1 ✓
- ✅ Registry.GTOKEN_STAKING → GTokenStaking v2.0.1 ✓

---

## 🧪 测试结果

### 链上测试 ✅
详细报告: `test-reports/onchain-test-2025-11-08.md`

| 测试项 | 状态 |
|--------|------|
| 合约版本验证 | ✅ |
| 依赖关系验证 | ✅ |
| Oracle 配置验证 | ✅ |
| Chainlink 实时数据 | ✅ ($3,428.96) |
| 参数配置验证 | ✅ |
| Registry 读取功能 | ✅ |
| Locker 配置验证 | ✅ |

### Gas 消耗统计

| 操作 | Gas Used | 估算成本 |
|------|----------|----------|
| Registry 部署 | 6,956,417 | ~0.000765 ETH |
| SuperPaymasterV2 部署 | 4,722,462 | ~0.000590 ETH |
| Locker 配置 | 777,255 | ~0.000085 ETH |
| **总计** | **12,456,134** | **~0.001440 ETH** |

---

## 📝 部署顺序验证

### ✅ 正确顺序
```
1. Registry v2.2.0 部署
   ↓
2. SuperPaymasterV2 v2.0.1 部署（使用新 Registry 地址）
   ↓
3. Locker 配置
```

### ❌ 废弃的错误部署
由于未遵循正确顺序，以下地址已废弃：
- `0x33A31d52db2ef2497e93226e0ed1B5d587D7D5e8` (第一次错误部署)
- `0x5675062cA5D98c791972eAC24eFa3BC3EBc096f3` (第二次错误部署)

**教训**: SuperPaymasterV2 的 `REGISTRY` 是 immutable，必须先部署 Registry。

详细文档: `docs/deployment-order.md`

---

## 📦 导出文件

### ABI 文件
- `docs/abis/Registry_v2_2_0.json` (161 KB)
- `docs/abis/SuperPaymasterV2_v2_0_1.json` (142 KB)

### 部署记录
- `contracts/deployments/superpaymaster-v2.0.1-sepolia.json`

### Broadcast 记录
- `broadcast/DeployRegistry_v2_2_0.s.sol/11155111/run-latest.json`
- `broadcast/DeploySuperPaymasterV2_0_1.s.sol/11155111/run-latest.json`
- `broadcast/ConfigureLockers_v2.s.sol/11155111/run-latest.json`

---

## 📋 下一步任务

### 1. ✅ 已完成
- [x] 部署 Registry v2.2.0
- [x] 部署 SuperPaymasterV2 v2.0.1
- [x] 链上测试
- [x] 配置 Locker

### 2. 🔄 进行中
- [ ] 更新 @aastar/shared-config
  - 添加新合约地址
  - 添加 ABI 文件
  - 更新常量配置
  - 发布 v0.3.0

### 3. ⏭️ 待完成
- [ ] 更新 registry 前端
  - 升级 @aastar/shared-config 依赖
  - 测试 auto-stake 注册功能
  - 部署到 Vercel

---

## 🔧 配置参数

### SuperPaymasterV2 v2.0.1
```javascript
{
  minOperatorStake: "30 ether",
  minAPNTsBalance: "100 ether",
  serviceFeeRate: 200,  // 2%
  oracle: {
    feed: "0x694AA1769357215DE4FAC081bf1f309aDC325306",
    minPrice: 10000000000,  // $100 (8 decimals)
    maxPrice: 10000000000000,  // $100,000 (8 decimals)
    stalenessThreshold: 3600  // 1 hour
  }
}
```

### Locker 费率配置
```javascript
{
  mySBT: {
    feeRate: 100,  // 1%
    minExitFee: "0.01 ether",
    maxFeePercent: 500  // 5%
  },
  superPaymasterV2: {
    baseFeeRate: 100,  // 1%
    minExitFee: "0.01 ether",
    maxFeePercent: 500,  // 5%
    timeTiers: [
      { duration: "< 7d", fee: "5%" },
      { duration: "7-30d", fee: "4%" },
      { duration: "30-90d", fee: "3%" },
      { duration: "90-180d", fee: "2%" },
      { duration: "> 180d", fee: "1%" }
    ]
  },
  registry: {
    feeRate: 200,  // 2%
    minExitFee: "0.05 ether",
    maxFeePercent: 1000  // 10%
  }
}
```

---

## 🔗 相关链接

### Etherscan (Sepolia)
- [Registry v2.2.0](https://sepolia.etherscan.io/address/0x028aB52B4E0EF26820043ca4F1B5Fe14FfC1EF75)
- [SuperPaymasterV2 v2.0.1](https://sepolia.etherscan.io/address/0xfaB5B2A129DF8308a70DA2fE77c61001e4Df58BC)
- [GTokenStaking v2.0.1](https://sepolia.etherscan.io/address/0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0)

### Documentation
- [部署顺序规范](docs/deployment-order.md)
- [链上测试报告](test-reports/onchain-test-2025-11-08.md)
- [shared-config 更新清单](docs/shared-config-update.md)

---

**部署状态**: ✅ 成功
**最后更新**: 2025-11-08
**下次更新**: shared-config v0.3.0 发布
