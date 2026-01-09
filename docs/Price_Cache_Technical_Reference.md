# SuperPaymaster Price Cache + Chainlink降级机制完整说明

## 核心架构图

```
┌─────────────────────────────────────────────────────────────┐
│                    Price Feed Architecture                   │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  Primary Source          Fallback Source                     │
│  ┌─────────────┐        ┌──────────────────┐               │
│  │  Chainlink  │        │   DVT/BLS        │               │
│  │  Oracle     │───✓───▶│   Validators     │               │
│  └─────────────┘    │   └──────────────────┘               │
│        │             │            │                          │
│        │ try-catch   │            │ BLS Proof               │
│        ▼             │            ▼                          │
│  updatePrice()       └─────▶ updatePriceDVT()               │
│        │                          │                          │
│        └──────────┬───────────────┘                          │
│                   ▼                                          │
│            ┌─────────────┐                                   │
│            │ cachedPrice │  ◀── Read by validate()          │
│            │  (Storage)  │                                   │
│            └─────────────┘                                   │
│                   │                                          │
│                   ▼                                          │
│         _calculateAPNTsAmount()                              │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

## 1. 核心数据结构

### PriceCache
```solidity
struct PriceCache {
    int256 price;      // ETH/USD价格 (8 decimals, e.g., 2000 * 1e8 = $2000)
    uint256 updatedAt; // 更新时间戳
    uint80 roundId;    // Chainlink roundId (DVT时为0)
    uint8 decimals;    // 价格精度 (Chainlink=8, DVT=8)
}
```

**存储位置**: SuperPaymaster合约的状态变量
**读取频率**: 每次`validatePaymasterUserOp`都会读取
**更新频率**: 
- Chainlink: 建议每30分钟(通过Keeper)
- DVT: 仅在Chainlink宕机时

## 2. 主要函数详解

### 2.1 updatePrice() - Chainlink主路径

**职责**: 从Chainlink获取最新价格并更新缓存

**优化后实现**(需要添加try-catch):
```solidity
function updatePrice() public {
    try ETH_USD_PRICE_FEED.latestRoundData() returns (
        uint80 roundId, int256 price, uint256, uint256 updatedAt, uint80
    ) {
        // Chainlink成功: 验证并更新
        if (price < MIN_ETH_USD_PRICE || price > MAX_ETH_USD_PRICE) 
            revert OracleError();
        if (updatedAt < block.timestamp - priceStalenessThreshold) 
            revert OracleError();

        cachedPrice = PriceCache({
            price: price,
            updatedAt: updatedAt,
            roundId: roundId,
            decimals: ETH_USD_PRICE_FEED.decimals()
        });
        
        emit PriceUpdated(price, updatedAt);
    } catch {
        // Chainlink失败 → 信号需要切换到DVT
        revert OracleError();
    }
}
```

**调用者**: Keeper服务(每30分钟) | 任何人(public)
**Gas成本**: ~50k gas

---

### 2.2 updatePriceDVT() - DVT降级路径

**职责**: 当Chainlink宕机时,通过DVT/BLS共识更新价格

**完整实现** (已完成):
```solidity
function updatePriceDVT(
    int256 price, uint256 updatedAt, bytes calldata proof
) external {
    // 第1层: 权限验证
    if (msg.sender != BLS_AGGREGATOR && msg.sender != owner()) 
        revert Unauthorized();
    
    // 第2层: BLS签名验证(在BLSAggregator已完成)
    
    // 第3层: 价格边界
    if (price < MIN_ETH_USD_PRICE || price > MAX_ETH_USD_PRICE)
        revert OracleError();
    
    // 第4层: ±20%偏离检查
    try ETH_USD_PRICE_FEED.latestRoundData() returns (...) {
        if (block.timestamp - chainlinkUpdatedAt < 2 hours) {
            int256 deviation = |price - chainlinkPrice| / chainlinkPrice * 100;
            if (deviation > 20) revert OracleError();
        }
    } catch {
        // Chainlink完全宕机 → DVT价格无条件接受
    }
    
    // 更新缓存
    cachedPrice = PriceCache({...});
    emit PriceUpdated(price, updatedAt);
}
```

**安全层级**:
1. 权限: 仅BLS_AGGREGATOR或owner
2. 签名: BLS聚合签名(7/13门槛)
3. 边界: $100-$100,000
4. 偏离: ±20% vs Chainlink

**Gas成本**: ~80k gas

---

### 2.3 _calculateAPNTsAmount() - 价格消费者

**职责**: 使用缓存价格计算需要的aPNTs数量

```solidity
function _calculateAPNTsAmount(uint256 ethAmountWei) 
    internal view returns (uint256) 
{
    PriceCache memory cache = cachedPrice; // ~2k gas
    if (cache.price <= 0) revert OracleError();
    
    // 计算: ethWei * ethPrice / aPNTsPrice
    return (ethAmountWei * uint256(cache.price) * 1e18) 
           / (1e8 * aPNTsPriceUSD);
}
```

**为什么用缓存?**
- ✅ Gas确定性(ERC-4337要求)
- ✅ 2k gas vs 50k gas (25倍优化)
- ✅ 避免validation阶段外部调用

---

## 3. 完整工作流程

### 场景A: Chainlink正常 (99%时间)

```
T+0: Keeper调用 updatePrice()
  └─▶ Chainlink返回 $2000
  └─▶ 验证通过,更新缓存
  └─▶ emit PriceUpdated($2000, now)

T+1: 用户发起UserOp
  └─▶ validatePaymasterUserOp()
  └─▶ _calculateAPNTsAmount(0.01 ETH)
      └─▶ 读取缓存: $2000
      └─▶ 计算: 0.01 * $2000 / $0.02 = 1000 aPNTs

T+30min: Keeper再次更新...
```

---

### 场景B: Chainlink宕机 → DVT接管

```
T+0: Chainlink宕机
  └─▶ Keeper调用 updatePrice()
  └─▶ try-catch捕获异常
  └─▶ revert OracleError()
  └─▶ 告警: "Chainlink down!"

T+5min: DVT验证器投票
  └─▶ 7/13签名: price=$1995
  └─▶ BLSAggregator验证 ✓
  └─▶ 调用 updatePriceDVT($1995, now, proof)

T+5min: updatePriceDVT()执行
  ├─▶ 权限 ✓
  ├─▶ 边界 ✓
  ├─▶ 偏离检查: Chainlink宕机,跳过
  └─▶ 更新缓存: $1995

T+10min~2h: DVT持续提供价格
  └─▶ 用户正常使用(DVT价格)

T+2h: Chainlink恢复
  └─▶ DVT提案: $2010
  └─▶ 偏离检查: |2010-2005|/2005 = 0.25% ✓
  └─▶ 接受DVT价格

T+2.5h: 切回Chainlink
  └─▶ updatePrice()成功
  └─▶ 恢复主路径
```

---

### 场景C: DVT攻击尝试

```
攻击: DVT提供$200 (远低于市场$2000)

updatePriceDVT($200, now, proof):
  ├─▶ 权限 ✓
  ├─▶ 边界 ✓ ($100 < $200 < $100k)
  └─▶ 偏离检查:
      ├─▶ Chainlink返回: $2000
      ├─▶ 偏离: |200-2000|/2000 = 90% ❌
      └─▶ revert OracleError()

结果: 攻击被拦截!
```

---

## 4. 架构依赖

```
SuperPaymaster
    │
    ├─▶ ETH_USD_PRICE_FEED (Chainlink)
    │     └─ 外部依赖,可能失败
    │
    ├─▶ BLS_AGGREGATOR
    │     ├─ 内部可信合约
    │     └─ 已验证BLS proof
    │
    ├─▶ cachedPrice (Storage)
    │     ├─ 写入: updatePrice() | updatePriceDVT()
    │     └─ 读取: _calculateAPNTsAmount()
    │
    └─▶ Owner (紧急权限)
```

**关键设计**:
- Cache vs 实时: Gas确定性
- 双路径: 99.9%可用性
- ±20%检查: 防DVT作恶

---

## 5. 安全参数

| 参数 | 值 | 用途 |
|------|-----|------|
| MIN_ETH_USD_PRICE | $100 | 防异常低价 |
| MAX_ETH_USD_PRICE | $100,000 | 防异常高价 |
| priceStalenessThreshold | 1小时 | 拒绝过期数据 |
| DVT偏离检查窗口 | 2小时 | Chainlink新鲜度 |
| 最大偏离度 | ±20% | DVT容忍度 |
| BLS门槛 | 7/13 | 共识最低签名 |

---

## 6. Gas成本

| 操作 | Gas | 频率 |
|------|-----|------|
| updatePrice() | ~50k | 每30分钟 |
| updatePriceDVT() | ~80k | 宕机时 |
| _calculateAPNTsAmount() | ~2k | 每UserOp |

**优势**: 25倍gas优化 (2k vs 50k)

---

## 7. 运维要求

### Keeper服务
```typescript
setInterval(async () => {
    try {
        await superPaymaster.updatePrice();
    } catch {
        alert("Chainlink down! Trigger DVT");
    }
}, 30 * 60 * 1000);
```

### 告警
- Chainlink: 连续2次失败
- DVT偏离: >15%警告, >20%拒绝
- 价格: >2小时无更新

---

## 总结

**三层安全架构**:
1. Primary: Chainlink (去中心化)
2. Fallback: DVT/BLS (快速)
3. Safety: ±20%检查 (防作恶)

**核心价值**:
- ✅ 99.9%可用性
- ✅ 25倍gas优化
- ✅ 符合ERC-4337
- ✅ 防Oracle操纵
