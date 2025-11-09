# 链上测试报告

**日期**: 2025-11-08
**网络**: Sepolia Testnet
**RPC**: Private Alchemy RPC

## 部署地址

| 合约 | 版本 | 地址 |
|------|------|------|
| Registry | v2.2.0 | `0x028aB52B4E0EF26820043ca4F1B5Fe14FfC1EF75` |
| SuperPaymasterV2 | v2.0.1 | `0xfaB5B2A129DF8308a70DA2fE77c61001e4Df58BC` |
| GTokenStaking | v2.0.1 | `0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0` |
| GToken | - | `0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc` |
| EntryPoint | v0.7 | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` |

## 1. 版本验证 ✅

### Registry v2.2.0
```
VERSION: "2.2.0"
VERSION_CODE: 20200
```

### SuperPaymasterV2 v2.0.1
```
VERSION: "2.0.1"
VERSION_CODE: 20001
```

## 2. 依赖关系验证 ✅

### SuperPaymasterV2 依赖配置

| 参数 | 实际值 | 预期值 | 状态 |
|------|--------|--------|------|
| REGISTRY | `0x028aB52B4E0EF26820043ca4F1B5Fe14FfC1EF75` | `0x028aB52B4E0EF26820043ca4F1B5Fe14FfC1EF75` | ✅ |
| GTOKEN_STAKING | `0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0` | `0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0` | ✅ |
| ENTRY_POINT | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | `0x0000000071727De22E5E9d8BAf0edAc6f37da032` | ✅ |

**结论**: SuperPaymasterV2 正确引用了新部署的 Registry v2.2.0

### Registry v2.2.0 依赖配置

| 参数 | 实际值 | 预期值 | 状态 |
|------|--------|--------|------|
| GTOKEN | `0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc` | `0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc` | ✅ |
| GTOKEN_STAKING | `0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0` | `0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0` | ✅ |
| owner | `0x411BD567E46C0781248dbB6a9211891C032885e5` | `0x411BD567E46C0781248dbB6a9211891C032885e5` | ✅ |

## 3. Oracle 安全配置验证 ✅

### SuperPaymasterV2 Oracle 配置

| 参数 | 值 | 说明 |
|------|-----|------|
| ethUsdPriceFeed | `0x694AA1769357215DE4FAC081bf1f309aDC325306` | Chainlink Sepolia ETH/USD |
| MIN_ETH_USD_PRICE | `10000000000` (8 decimals) | $100 最低价格 |
| MAX_ETH_USD_PRICE | `10000000000000` (8 decimals) | $100,000 最高价格 |

### Chainlink 实时数据测试

从 Chainlink ETH/USD Price Feed 读取的最新数据:
```
roundId: 18446744073709579449
answer: 342895624600 ($3,428.96 with 8 decimals)
startedAt: 1762581660 (2025-11-08)
updatedAt: 1762581660 (2025-11-08)
answeredInRound: 18446744073709579449
```

**验证结果**:
- ✅ answeredInRound == roundId (共识验证通过)
- ✅ 价格在合理范围内 ($100 < $3,428 < $100,000)
- ✅ 数据新鲜度正常 (updatedAt 为当前时间)

## 4. SuperPaymasterV2 参数验证 ✅

| 参数 | 值 | 说明 |
|------|-----|------|
| minOperatorStake | `30000000000000000000` | 30 ether |
| minAPNTsBalance | `100000000000000000000` | 100 ether |
| serviceFeeRate | `200` | 2% (200 basis points) |
| owner | `0x411BD567E46C0781248dbB6a9211891C032885e5` | 部署者地址 |

所有参数符合预期配置。

## 5. Registry v2.2.0 状态验证 ✅

### 初始状态

| 参数 | 值 | 说明 |
|------|-----|------|
| getCommunityCount() | `0` | 新部署的合约，暂无社区 |
| oracle | `0x0000000000000000000000000000000000000000` | 待配置 |
| superPaymasterV2 | `0x0000000000000000000000000000000000000000` | 待配置 |

### 读取功能测试
- ✅ `getCommunityCount()` - 正常返回 0
- ✅ `isRegisteredCommunity()` - 正常返回 false
- ✅ `oracle()` - 正常返回零地址
- ✅ `superPaymasterV2()` - 正常返回零地址

## 6. 测试总结

### ✅ 通过的测试
1. 合约版本验证 - 两个合约版本号正确
2. 依赖关系验证 - SuperPaymasterV2 正确引用 Registry v2.2.0
3. Oracle 配置验证 - Chainlink price feed 工作正常
4. 安全边界验证 - 价格边界和共识验证配置正确
5. 参数配置验证 - 所有参数符合预期
6. 读取功能验证 - Registry 读取函数正常工作

### ⚠️ 待完成的配置
1. **Registry.oracle** - 需要设置 Oracle 地址
2. **Registry.superPaymasterV2** - 需要设置 SuperPaymasterV2 地址
3. **Locker 配置** - 需要将两个合约添加到 GTokenStaking 的授权 locker 列表

### 📋 下一步操作
1. ✅ 链上测试完成
2. ⏭️ 配置并验证 Locker
3. ⏭️ 更新 shared-config
4. ⏭️ 更新 registry 前端

## 7. 部署顺序验证

本次部署严格遵循了正确的部署顺序：

```
1. Registry v2.2.0 部署 → 0x028aB52B4E0EF26820043ca4F1B5Fe14FfC1EF75
2. SuperPaymasterV2 v2.0.1 部署（使用新 Registry 地址）→ 0xfaB5B2A129DF8308a70DA2fE77c61001e4Df58BC
```

与之前错误部署（先部署 SuperPaymasterV2）相比，本次部署：
- ✅ SuperPaymasterV2.REGISTRY 指向正确的 Registry v2.2.0
- ✅ 可以使用 Registry v2.2.0 的新特性（auto-stake registration）
- ✅ 架构依赖关系清晰正确

## 8. Gas 消耗统计

| 操作 | Gas Used | ETH Cost (估算) |
|------|----------|-----------------|
| Registry v2.2.0 部署 | 6,956,417 | ~0.000765 ETH |
| SuperPaymasterV2 v2.0.1 部署 | 4,722,462 | ~0.000590 ETH |
| **总计** | **11,678,879** | **~0.001355 ETH** |

---

**测试完成时间**: 2025-11-08
**测试者**: Claude Code
**测试结果**: ✅ 所有核心功能正常，可以继续配置 Locker
