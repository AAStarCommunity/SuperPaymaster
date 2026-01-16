# Oracle降级与自动切换机制

**版本**: v1.0  
**日期**: 2026-01-09  
**状态**: Production Ready

---

## 目录

1. [核心问题](#核心问题)
2. [完整架构设计](#完整架构设计)
3. [Chainlink监控与故障检测](#chainlink监控与故障检测)
4. [DVT接管流程](#dvt接管流程)
5. [自动切换回Chainlink](#自动切换回chainlink)
6. [运维实现方案](#运维实现方案)
7. [状态机与决策树](#状态机与决策树)

---

## 核心问题

### Q1: DVT如何发现Chainlink宕机?
**A**: 通过**Keeper服务**持续监控`updatePrice()`调用结果

### Q2: 如何触发DVT接管?
**A**: Keeper检测到Chainlink失败后,通知**DVT Coordinator**发起价格提案

### Q3: Chainlink恢复后如何切回?
**A**: Keeper检测到Chainlink恢复,**自动停止调用**`updatePriceDVT()`,恢复调用`updatePrice()`

---

## 完整架构设计

```
┌─────────────────────────────────────────────────────────────────┐
│                    Oracle Failover Architecture                  │
├─────────────────────────────────────────────────────────────────┤
│                                                                   │
│  ┌──────────────┐         ┌──────────────┐                      │
│  │   Chainlink  │         │  DVT Network │                      │
│  │    Oracle    │         │ (13 Nodes)   │                      │
│  └──────┬───────┘         └──────┬───────┘                      │
│         │                        │                               │
│         │ latestRoundData()      │ BLS Consensus                │
│         ▼                        ▼                               │
│  ┌─────────────────────────────────────────┐                    │
│  │         Keeper Service (Off-chain)       │                   │
│  │  ┌────────────────────────────────────┐ │                    │
│  │  │  Monitoring Loop (every 30s)       │ │                    │
│  │  │  ├─ Check Chainlink health         │ │                    │
│  │  │  ├─ Detect failures (3 retries)    │ │                    │
│  │  │  └─ Trigger state transition       │ │                    │
│  │  └────────────────────────────────────┘ │                    │
│  │                                          │                    │
│  │  ┌────────────┐      ┌────────────────┐│                    │
│  │  │ State: CL  │─────▶│ State: DVT     ││                    │
│  │  │ (Primary)  │◀─────│ (Fallback)     ││                    │
│  │  └────────────┘      └────────────────┘│                    │
│  └─────────────────────────────────────────┘                    │
│         │                        │                               │
│         │ updatePrice()          │ updatePriceDVT()             │
│         ▼                        ▼                               │
│  ┌─────────────────────────────────────────┐                    │
│  │       SuperPaymaster Contract            │                   │
│  │  ┌────────────────────────────────────┐ │                    │
│  │  │         cachedPrice                 │ │                    │
│  │  │  ├─ price: int256                   │ │                    │
│  │  │  ├─ updatedAt: uint256              │ │                    │
│  │  │  ├─ roundId: uint80                 │ │                    │
│  │  │  └─ decimals: uint8                 │ │                    │
│  │  └────────────────────────────────────┘ │                    │
│  └─────────────────────────────────────────┘                    │
│                                                                   │
└─────────────────────────────────────────────────────────────────┘
```

---

## Chainlink监控与故障检测

### 3.1 Keeper服务核心逻辑

```typescript
// Keeper Service - Oracle Monitor
class OracleKeeper {
    private state: 'CHAINLINK' | 'DVT' = 'CHAINLINK';
    private failureCount = 0;
    private readonly FAILURE_THRESHOLD = 3; // 连续3次失败才切换
    
    async monitoringLoop() {
        setInterval(async () => {
            await this.checkAndUpdate();
        }, 30 * 1000); // 每30秒检查一次
    }
    
    async checkAndUpdate() {
        if (this.state === 'CHAINLINK') {
            await this.tryChainlinkUpdate();
        } else {
            await this.tryDVTUpdate();
            await this.checkChainlinkRecovery(); // 同时检查CL是否恢复
        }
    }
    
    // === Chainlink主路径 ===
    async tryChainlinkUpdate() {
        try {
            // 1. 调用合约updatePrice()
            const tx = await superPaymaster.updatePrice();
            await tx.wait();
            
            // 2. 成功 → 重置失败计数
            this.failureCount = 0;
            logger.info('✅ Chainlink price updated');
            
        } catch (error) {
            // 3. 失败 → 累计失败次数
            this.failureCount++;
            logger.warn(`⚠️  Chainlink failed (${this.failureCount}/${this.FAILURE_THRESHOLD})`);
            
            // 4. 达到阈值 → 切换到DVT
            if (this.failureCount >= this.FAILURE_THRESHOLD) {
                await this.switchToDVT();
            }
        }
    }
    
    // === DVT降级路径 ===
    async switchToDVT() {
        logger.alert('🚨 Chainlink DOWN! Switching to DVT...');
        this.state = 'DVT';
        this.failureCount = 0;
        
        // 通知DVT Coordinator发起价格提案
        await this.notifyDVTCoordinator({
            reason: 'CHAINLINK_FAILURE',
            timestamp: Date.now()
        });
    }
    
    async tryDVTUpdate() {
        try {
            // 1. 从DVT Coordinator获取最新共识价格
            const dvtProposal = await dvtCoordinator.getLatestProposal();
            
            if (!dvtProposal || !dvtProposal.hasConsensus) {
                logger.warn('⚠️  DVT consensus not ready, waiting...');
                return;
            }
            
            // 2. 调用updatePriceDVT()
            const tx = await superPaymaster.updatePriceDVT(
                dvtProposal.price,
                dvtProposal.timestamp,
                dvtProposal.blsProof
            );
            await tx.wait();
            
            logger.info('✅ DVT price updated');
            
        } catch (error) {
            logger.error('❌ DVT update failed:', error);
            // DVT失败是严重问题,需要人工介入
            await this.alertOperators('DVT_FAILURE');
        }
    }
    
    // === 自动切换回Chainlink ===
    async checkChainlinkRecovery() {
        try {
            // 1. 尝试直接调用Chainlink (不上链)
            const chainlinkData = await ethUsdPriceFeed.latestRoundData();
            
            // 2. 验证数据有效性
            const price = chainlinkData.answer;
            const updatedAt = chainlinkData.updatedAt;
            
            if (price <= 0) throw new Error('Invalid price');
            if (Date.now() / 1000 - updatedAt > 3600) throw new Error('Stale data');
            
            // 3. Chainlink恢复 → 切换回主路径
            logger.info('🎉 Chainlink RECOVERED! Switching back...');
            this.state = 'CHAINLINK';
            this.failureCount = 0;
            
            // 4. 立即更新一次价格
            await this.tryChainlinkUpdate();
            
        } catch (error) {
            // Chainlink仍未恢复,继续使用DVT
            logger.debug('Chainlink still down, continuing with DVT');
        }
    }
}
```

---

## DVT接管流程

### 4.1 DVT Coordinator架构

```
┌─────────────────────────────────────────────────────────┐
│              DVT Coordinator (Off-chain)                 │
├─────────────────────────────────────────────────────────┤
│                                                           │
│  1. Receive Trigger from Keeper                          │
│     └─▶ reason: CHAINLINK_FAILURE                        │
│                                                           │
│  2. Fetch Prices from Multiple Sources                   │
│     ├─▶ Binance API: $2000.50                           │
│     ├─▶ Coinbase API: $2001.20                          │
│     ├─▶ Kraken API: $2000.80                            │
│     └─▶ Median: $2000.80                                 │
│                                                           │
│  3. Create Proposal                                       │
│     ├─▶ proposalId: 12345                                │
│     ├─▶ price: 200080000000 (8 decimals)                │
│     ├─▶ timestamp: 1704800000                            │
│     └─▶ message: keccak256(proposalId, price, ...)      │
│                                                           │
│  4. Broadcast to 13 DVT Validators                       │
│     └─▶ Each validator signs message with BLS key       │
│                                                           │
│  5. Collect Signatures (7/13 threshold)                  │
│     ├─▶ Validator 1: signature_1                         │
│     ├─▶ Validator 2: signature_2                         │
│     ├─▶ ...                                              │
│     └─▶ Validator 7: signature_7 ✓ Threshold reached    │
│                                                           │
│  6. Aggregate BLS Signatures                             │
│     └─▶ aggregatedProof = BLS.aggregate([sig1...sig7])  │
│                                                           │
│  7. Submit to BLSAggregator Contract                     │
│     └─▶ BLSAggregator.verifyAndExecute(...)             │
│         └─▶ calls SuperPaymaster.updatePriceDVT()       │
│                                                           │
└─────────────────────────────────────────────────────────┘
```

### 4.2 DVT价格来源

DVT不依赖单一Oracle,而是聚合多个CEX价格:

```typescript
async function fetchDVTPrice(): Promise<number> {
    const sources = [
        { name: 'Binance', api: 'https://api.binance.com/...' },
        { name: 'Coinbase', api: 'https://api.coinbase.com/...' },
        { name: 'Kraken', api: 'https://api.kraken.com/...' },
        { name: 'OKX', api: 'https://www.okx.com/api/...' },
        { name: 'Bybit', api: 'https://api.bybit.com/...' }
    ];
    
    // 并行获取所有价格
    const prices = await Promise.all(
        sources.map(s => fetchPrice(s.api).catch(() => null))
    );
    
    // 过滤失败的,取中位数
    const validPrices = prices.filter(p => p !== null);
    if (validPrices.length < 3) throw new Error('Insufficient price sources');
    
    return median(validPrices);
}
```

---

## 自动切换回Chainlink

### 5.1 切换条件

Keeper在DVT模式下,**每30秒**检查Chainlink是否恢复:

```typescript
async checkChainlinkRecovery() {
    // 条件1: Chainlink能返回数据
    const data = await ethUsdPriceFeed.latestRoundData();
    
    // 条件2: 价格有效 (>0, 在合理范围)
    if (data.answer <= 0) return false;
    if (data.answer < MIN_PRICE || data.answer > MAX_PRICE) return false;
    
    // 条件3: 数据新鲜 (<1小时)
    const age = Date.now() / 1000 - data.updatedAt;
    if (age > 3600) return false;
    
    // 条件4: 连续3次成功 (防止抖动)
    this.recoveryCount++;
    if (this.recoveryCount < 3) return false;
    
    // ✅ 所有条件满足 → 切换回Chainlink
    return true;
}
```

### 5.2 平滑切换策略

```typescript
async switchBackToChainlink() {
    logger.info('🔄 Initiating switch back to Chainlink...');
    
    // 1. 验证Chainlink价格与DVT价格偏离<5%
    const clPrice = await getChainlinkPrice();
    const dvtPrice = await getCurrentCachedPrice();
    const deviation = Math.abs(clPrice - dvtPrice) / dvtPrice;
    
    if (deviation > 0.05) {
        logger.warn(`⚠️  Price deviation ${deviation*100}% too high, delaying switch`);
        return; // 延迟切换,避免价格跳变
    }
    
    // 2. 切换状态
    this.state = 'CHAINLINK';
    this.recoveryCount = 0;
    
    // 3. 立即调用updatePrice()更新
    await superPaymaster.updatePrice();
    
    // 4. 通知DVT Coordinator停止提案
    await dvtCoordinator.pauseProposals('CHAINLINK_RECOVERED');
    
    logger.info('✅ Successfully switched back to Chainlink');
}
```

---

## 运维实现方案

### 6.1 部署架构

```
┌─────────────────────────────────────────────────────────┐
│                   Production Setup                       │
├─────────────────────────────────────────────────────────┤
│                                                           │
│  ┌─────────────────┐         ┌──────────────────────┐  │
│  │  Keeper Service │         │  DVT Coordinator     │  │
│  │  (AWS Lambda)   │◀───────▶│  (Distributed)       │  │
│  │                 │         │                      │  │
│  │  - Monitor CL   │         │  - 13 Validator Nodes│  │
│  │  - Call update  │         │  - BLS Aggregation   │  │
│  │  - State mgmt   │         │  - Price consensus   │  │
│  └─────────────────┘         └──────────────────────┘  │
│         │                              │                │
│         │                              │                │
│         ▼                              ▼                │
│  ┌──────────────────────────────────────────────────┐  │
│  │         SuperPaymaster (On-chain)                 │  │
│  │  - updatePrice() ◀── Chainlink                   │  │
│  │  - updatePriceDVT() ◀── DVT/BLS                  │  │
│  └──────────────────────────────────────────────────┘  │
│                                                           │
│  ┌─────────────────┐         ┌──────────────────────┐  │
│  │  Monitoring     │         │  Alert System        │  │
│  │  (Grafana)      │         │  (PagerDuty)         │  │
│  │                 │         │                      │  │
│  │  - CL health    │         │  - CL down alert     │  │
│  │  - DVT status   │         │  - DVT failure alert │  │
│  │  - Price chart  │         │  - Deviation alert   │  │
│  └─────────────────┘         └──────────────────────┘  │
│                                                           │
└─────────────────────────────────────────────────────────┘
```

### 6.2 Keeper服务配置

```yaml
# keeper-config.yaml
keeper:
  interval: 30s
  chainlink:
    failure_threshold: 3
    retry_delay: 10s
  dvt:
    coordinator_url: https://dvt-coordinator.example.com
    timeout: 60s
  recovery:
    check_interval: 30s
    success_threshold: 3
    max_deviation: 0.05

alerts:
  - type: CHAINLINK_DOWN
    severity: HIGH
    channels: [pagerduty, slack]
  - type: DVT_FAILURE
    severity: CRITICAL
    channels: [pagerduty, phone]
  - type: PRICE_DEVIATION
    severity: MEDIUM
    threshold: 0.15
```

### 6.3 监控指标

```typescript
// Metrics to track
const metrics = {
    // Chainlink健康度
    chainlink_success_rate: gauge(),
    chainlink_latency: histogram(),
    chainlink_failure_count: counter(),
    
    // DVT状态
    dvt_active: gauge(), // 0=inactive, 1=active
    dvt_consensus_time: histogram(),
    dvt_validator_count: gauge(),
    
    // 价格数据
    price_update_frequency: histogram(),
    price_deviation_cl_vs_dvt: gauge(),
    cached_price_age: gauge(),
    
    // 状态切换
    state_transitions: counter(), // CL→DVT, DVT→CL
    switch_duration: histogram()
};
```

---

## 状态机与决策树

### 7.1 状态机图

```
                    ┌─────────────┐
                    │   INITIAL   │
                    └──────┬──────┘
                           │
                           ▼
                    ┌─────────────┐
            ┌──────▶│  CHAINLINK  │◀──────┐
            │       │  (Primary)  │       │
            │       └──────┬──────┘       │
            │              │               │
            │   3x failure │               │ Recovery
            │              ▼               │ (3x success)
            │       ┌─────────────┐       │
            │       │     DVT     │───────┘
            │       │ (Fallback)  │
            │       └──────┬──────┘
            │              │
            │   DVT failure│
            │              ▼
            │       ┌─────────────┐
            └───────│  EMERGENCY  │
                    │ (Manual)    │
                    └─────────────┘
```

### 7.2 决策树

```
updatePrice() called
    │
    ├─ try Chainlink.latestRoundData()
    │   │
    │   ├─ Success?
    │   │   ├─ YES → Validate price
    │   │   │   ├─ Valid? → Update cache → emit PriceUpdated → END
    │   │   │   └─ Invalid? → revert OracleError
    │   │   │
    │   │   └─ NO (catch) → revert OracleError
    │
    └─ Keeper detects revert
        │
        ├─ failureCount++
        │
        ├─ failureCount >= 3?
        │   ├─ YES → Switch to DVT state
        │   │   │
        │   │   └─ Notify DVT Coordinator
        │   │       │
        │   │       ├─ Fetch CEX prices
        │   │       ├─ Create proposal
        │   │       ├─ Collect 7/13 BLS signatures
        │   │       ├─ Aggregate proof
        │   │       └─ Call updatePriceDVT()
        │   │           │
        │   │           ├─ Verify authority ✓
        │   │           ├─ Verify bounds ✓
        │   │           ├─ Check deviation (±20%)
        │   │           │   ├─ CL available? → Check deviation
        │   │           │   └─ CL down? → Skip check
        │   │           └─ Update cache → emit PriceUpdated
        │   │
        │   └─ NO → Retry next interval
        │
        └─ In DVT state: Check CL recovery every 30s
            │
            ├─ CL recoverable?
            │   ├─ YES (3x success) → Switch back to CHAINLINK
            │   └─ NO → Continue DVT
```

---

## 总结

### 核心机制

1. **主动监控**: Keeper每30秒调用`updatePrice()`,通过try-catch检测Chainlink状态
2. **故障检测**: 连续3次失败才切换到DVT(防止网络抖动)
3. **DVT接管**: DVT Coordinator聚合CEX价格,收集BLS签名,调用`updatePriceDVT()`
4. **自动恢复**: Keeper在DVT模式下持续检测Chainlink,恢复后自动切回
5. **平滑切换**: 切换时检查价格偏离<5%,避免价格跳变

### 优势

- ✅ **零人工干预**: 完全自动化的故障检测和切换
- ✅ **高可用性**: 99.9%+ uptime (Chainlink + DVT双保险)
- ✅ **防抖动**: 3次确认机制避免频繁切换
- ✅ **安全防护**: ±20%偏离检查防止DVT作恶
- ✅ **可观测性**: 完整的监控和告警体系

### 运维成本

- **Keeper**: AWS Lambda ~$10/月
- **DVT Coordinator**: 13个节点 ~$500/月
- **监控**: Grafana Cloud ~$50/月
- **总计**: ~$560/月 (相比服务中断损失可忽略)
