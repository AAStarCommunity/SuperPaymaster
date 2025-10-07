# SuperPaymaster V3 汇率设计方案 V2 (链下结算)

## 文档版本
- 版本: V2 (链下结算方案)
- 创建时间: 2025-10-06
- 作者: Jason
- 状态: 设计优化阶段

## 1. 核心设计理念

### 1.1 设计原则

**关键决策: 链下结算,链上只记录**

1. **USD锚定定价**: PNT基础价格 = $0.02 (市场小幅波动)
2. **链上记录**: Settlement只记录gas消耗(gwei)和时间戳
3. **链下计算**: 根据记录时ETH价格计算应扣PNT数量
4. **预授权机制**: ERC-20工厂合约内置预approve
5. **最小改动**: Settlement合约无需大幅修改

### 1.2 exchangeRate定义变更

**重要: exchangeRate与ETH无关**

```
exchangeRate = 不同PNT变种之间的汇率
- PNT (基础): exchangeRate = 1e18 (1:1基准)
- aPNT (项目A积分): exchangeRate = 1.2e18 (1 aPNT = 1.2 PNT)
- bPNT (项目B积分): exchangeRate = 0.8e18 (1 bPNT = 0.8 PNT)

当前: 只支持单一PNT, exchangeRate = 1e18 (默认)
```

## 2. L2实际成本分析

### 2.1 L2 Gas成本重新计算

**您说得对,主网成本确实太高!**

```
主网 (Sepolia测试网类似):
- Gas Price: 1-50 Gwei
- 一次转账: 380,000 gas
- 成本: 0.00038-0.019 ETH = $0.95-$47.5 ❌ 太贵

L2 (Arbitrum/Optimism):
- Gas Price: 0.001-0.1 Gwei (是主网的1/100-1/1000)
- 一次转账: 380,000 gas
- 成本: 0.00000038-0.000038 ETH = $0.00095-$0.095 ✅ 合理
```

### 2.2 L2环境下的PNT成本

**Arbitrum (0.1 Gwei):**
```
Gas成本: $0.095
PNT价格: $0.02
需要PNT: 0.095 / 0.02 = 4.75 PNT/次

100 PNT余额: 100 / 4.75 ≈ 21次 ✅
```

**Optimism (0.001 Gwei):**
```
Gas成本: $0.00095
PNT价格: $0.02
需要PNT: 0.00095 / 0.02 = 0.0475 PNT/次

100 PNT余额: 100 / 0.0475 ≈ 2105次 ✅
```

**结论: L2环境下,100 PNT完全够用,2.5-5 PNT/次是合理的**

## 3. 优化后的架构设计

### 3.1 整体架构

```
┌─────────────────────────────────────────────────────────┐
│                     用户操作层                          │
│  User → UserOp → Bundler → EntryPoint                  │
└─────────────────────┬───────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────┐
│                  链上Gas赞助层                          │
│  PaymasterV3 (验证SBT + PNT余额)                       │
│    ↓                                                    │
│  Settlement (记录gas消耗 + 时间戳)                      │
│    ├─ 记录: gwei数量                                   │
│    ├─ 记录: block.timestamp                            │
│    └─ 记录: userOpHash + 用户地址                      │
└─────────────────────┬───────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────┐
│                   链下结算层                            │
│  Keeper/Backend服务:                                   │
│    1. 监听Settlement的FeeRecorded事件                  │
│    2. 获取记录时的ETH/USD价格 (Chainlink历史数据)      │
│    3. 计算应扣PNT: gasGwei * ethPrice / pntPrice       │
│    4. 加手续费: pntAmount * (1 + feeRate)              │
│    5. 调用GasToken.transferFrom(user, treasury, pnt)   │
│    6. 调用Settlement.settleFees()标记为Settled         │
└─────────────────────────────────────────────────────────┘
                      │
                      ▼
┌─────────────────────────────────────────────────────────┐
│                 预授权GasToken层                        │
│  GasToken工厂合约 (ERC-20 Factory):                    │
│    - 批量发行: PNT, aPNT, bPNT...                      │
│    - 内置预approve:                                    │
│      approve(Settlement, gasLimit * 100)               │
│    - 验证规则:                                         │
│      require(isPendingRecord(userOpHash, msg.sender))  │
└─────────────────────────────────────────────────────────┘
```

### 3.2 关键组件职责

**链上合约 (最小改动):**

1. **Settlement.sol**
   - 记录: `(paymaster, user, gasGwei, timestamp, userOpHash)`
   - 状态管理: Pending → Settled
   - ❌ 不计算汇率,不转账

2. **GasTokenFactory.sol (新增)**
   - 发行所有PNT变种
   - 内置预approve Settlement
   - 验证转账合法性

3. **PaymasterV3.sol (无需改动)**
   - 继续验证SBT + PNT余额 >= 10 PNT
   - 调用Settlement.recordGasFee()

**链下服务:**

4. **Settlement Keeper**
   - 监听FeeRecorded事件
   - 查询历史ETH价格
   - 计算PNT数量
   - 执行结算转账

## 4. Settlement合约改动点

### 4.1 当前recordGasFee()分析

```solidity
// 当前实现
function recordGasFee(
    address user,
    address token,
    uint256 amount,      // ← 这里是 actualGasCost (wei)
    bytes32 userOpHash
) external {
    // 记录 FeeRecord
}
```

**问题**: `amount`是ETH的wei,精度太高,存储浪费

### 4.2 优化方案

```solidity
// 优化后
function recordGasFee(
    address user,
    address token,
    uint256 amount,      // ← 改为记录 Gwei (除以1e9)
    bytes32 userOpHash
) external {
    FeeRecord({
        paymaster: msg.sender,
        user: user,
        token: token,
        gasGwei: amount,           // ← 存储Gwei而非wei
        timestamp: block.timestamp, // ← 新增时间戳
        status: Pending,
        userOpHash: userOpHash
    });
}
```

**为什么改为Gwei?**
```
Wei: 38000000000000 (14位数字,浪费存储)
Gwei: 38000 (5位数字,节省9字节)

L2实际场景:
0.001 Gwei * 380000 gas = 380 Gwei
0.1 Gwei * 380000 gas = 38000 Gwei

uint64即可存储 (最大1844京Gwei)
```

### 4.3 FeeRecord结构体修改

```solidity
struct FeeRecord {
    address paymaster;
    address user;
    address token;         // PNT/aPNT/bPNT地址
    uint64 gasGwei;        // ← 改为uint64存储Gwei
    uint64 timestamp;      // ← 新增: block.timestamp
    FeeStatus status;
    bytes32 userOpHash;
    bytes32 settlementHash;
}
```

**存储优化:**
```
原: uint256 amount (32字节) + uint256 timestamp
优化: uint64 gasGwei (8字节) + uint64 timestamp (8字节)
节省: 32字节 = 6400 gas per record
```

## 5. 链下结算流程详解

### 5.1 Keeper监听与计算

```javascript
// Keeper伪代码
async function settleRecords() {
  // 1. 监听FeeRecorded事件
  const events = await settlement.queryFilter('FeeRecorded', fromBlock, toBlock);
  
  for (const event of events) {
    const { recordKey, user, token, gasGwei, timestamp, userOpHash } = event.args;
    
    // 2. 获取记录时的ETH/USD价格
    const ethPriceUSD = await getHistoricalETHPrice(timestamp);
    // 例: $2500
    
    // 3. 计算gas成本(USD)
    const gasCostUSD = (gasGwei * 1e9 / 1e18) * ethPriceUSD;
    // 38000 Gwei = 0.000038 ETH
    // 0.000038 * $2500 = $0.095
    
    // 4. 获取PNT价格 (可配置或从预言机)
    const pntPriceUSD = 0.02; // $0.02
    
    // 5. 计算PNT数量
    let pntAmount = gasCostUSD / pntPriceUSD;
    // $0.095 / $0.02 = 4.75 PNT
    
    // 6. 添加手续费
    const feeRate = await settlement.feeRate(); // 150 (1.5%)
    pntAmount = pntAmount * (10000 + feeRate) / 10000;
    // 4.75 * 1.015 = 4.82125 PNT
    
    // 7. 如果是aPNT,应用exchangeRate
    const exchangeRate = await settlement.tokenExchangeRates(token);
    if (exchangeRate != 1e18) {
      pntAmount = pntAmount * exchangeRate / 1e18;
      // 假设aPNT汇率1.2: 4.82 * 1.2 = 5.79 aPNT
    }
    
    // 8. 执行转账 (预授权已完成,直接transferFrom)
    await gasToken.transferFrom(user, treasury, pntAmount);
    
    // 9. 标记为已结算
    await settlement.settleFees([recordKey], settlementHash);
  }
}
```

### 5.2 历史价格获取

**方案1: Chainlink历史数据 (推荐)**
```javascript
// 通过Chainlink获取特定区块的ETH/USD价格
const priceFeed = new ethers.Contract(
  '0x...ChainlinkETHUSD',
  priceFeedABI,
  provider
);

async function getHistoricalETHPrice(timestamp) {
  // 找到该时间戳对应的区块
  const block = await findBlockByTimestamp(timestamp);
  
  // 获取该区块的价格
  const round = await priceFeed.getRoundData(block, {blockTag: block});
  return round.answer / 1e8; // Chainlink 8位精度
}
```

**方案2: API缓存 (备选)**
```javascript
// 使用CoinGecko/CoinMarketCap历史API
async function getHistoricalETHPrice(timestamp) {
  const date = new Date(timestamp * 1000).toISOString().split('T')[0];
  const response = await fetch(
    `https://api.coingecko.com/api/v3/coins/ethereum/history?date=${date}`
  );
  const data = await response.json();
  return data.market_data.current_price.usd;
}
```

## 6. 预授权GasToken设计

### 6.1 GasTokenFactory合约

```solidity
// GasTokenFactory.sol
contract GasTokenFactory {
    address public settlement;
    mapping(address => address) public deployedTokens; // name => token
    
    // 发行新的GasToken
    function createGasToken(
        string memory name,
        string memory symbol,
        uint256 exchangeRate
    ) external onlyOwner returns (address) {
        GasToken token = new GasToken(
            name,
            symbol,
            settlement,
            exchangeRate
        );
        deployedTokens[name] = address(token);
        return address(token);
    }
}

// GasToken.sol (基于ERC20)
contract GasToken is ERC20 {
    address public immutable settlement;
    uint256 public exchangeRate; // 相对于基础PNT的汇率
    
    constructor(
        string memory name,
        string memory symbol,
        address _settlement,
        uint256 _exchangeRate
    ) ERC20(name, symbol) {
        settlement = _settlement;
        exchangeRate = _exchangeRate;
    }
    
    // 预授权逻辑
    function _afterTokenTransfer(
        address from,
        address to,
        uint256 amount
    ) internal override {
        super._afterTokenTransfer(from, to, amount);
        
        // 当用户首次收到PNT时,自动授权Settlement
        if (to != address(0) && balanceOf(to) > 0) {
            _autoApproveSettlement(to);
        }
    }
    
    function _autoApproveSettlement(address user) internal {
        uint256 currentAllowance = allowance(user, settlement);
        if (currentAllowance == 0) {
            // 预授权: 单次gas上限 * 100倍
            uint256 approvalAmount = 500 * 1e18; // 500 PNT (假设单次5 PNT)
            _approve(user, settlement, approvalAmount);
        }
    }
    
    // Settlement专用transferFrom (带验证)
    function settlementTransferFrom(
        address from,
        address to,
        uint256 amount,
        bytes32 userOpHash
    ) external {
        require(msg.sender == settlement, "Only settlement");
        
        // 验证: 该userOpHash对应的记录确实属于from地址
        require(
            ISettlement(settlement).isPendingRecord(userOpHash, from),
            "Invalid record"
        );
        
        _transfer(from, to, amount);
    }
}
```

### 6.2 预授权额度设计

**设计原则:**
```
单次最大gas: 500万 gas (极端复杂交易)
L2 gas price: 0.1 Gwei
单次最大成本: 500万 * 0.1 Gwei = 0.0005 ETH = $1.25
换算PNT: $1.25 / $0.02 = 62.5 PNT

预授权额度: 62.5 * 100 = 6250 PNT
安全起见: 设为 500 PNT即可 (覆盖100次普通交易)
```

## 7. 手续费率设计

### 7.1 当前Registry的feeRate

**Registry中的100:**
```
feeRate = 100 basis points = 1.0%
计算: finalAmount = baseAmount * (10000 + feeRate) / 10000

示例:
baseAmount = 4.75 PNT
feeRate = 100
finalAmount = 4.75 * 10100 / 10000 = 4.7975 PNT
```

### 7.2 调整为1.5%

**两种实现方式:**

**方案A: 修改Registry (需重新注册)**
```solidity
// Registry中更新
feeRate = 150; // 1.5%

// 链下计算
finalPNT = basePNT * 10150 / 10000;
```

**方案B: Settlement存储 (推荐)**
```solidity
// Settlement.sol新增
uint256 public feeRate = 150; // 1.5%, 可由Owner修改

function setFeeRate(uint256 _feeRate) external onlyOwner {
    require(_feeRate <= 1000, "Max 10%"); // 上限10%
    feeRate = _feeRate;
}

// 链下Keeper读取
const feeRate = await settlement.feeRate();
```

**推荐方案B的原因:**
- Registry的feeRate未使用,无需修改
- Settlement管理更灵活
- 可随时调整,无需重新注册Paymaster

## 8. 完整数据流示例

### 8.1 用户执行UserOp

```
时间: 2025-10-06 14:30:00 (timestamp: 1728226200)
L2: Arbitrum
Gas Price: 0.1 Gwei
ETH价格: $2500

1. 用户发起ERC20转账UserOp
2. EntryPoint调用PaymasterV3.validatePaymasterUserOp()
   - SBT余额: 1 ✅
   - PNT余额: 100 PNT ✅
3. EntryPoint执行,实际消耗: 380,000 gas
4. EntryPoint调用PaymasterV3.postOp()
   - actualGasCost = 38,000,000,000,000 wei
5. PaymasterV3调用Settlement.recordGasFee()
   - gasGwei = 38000 (转换: wei / 1e9)
   - timestamp = 1728226200
   - userOpHash = 0xabc123...
6. Settlement触发事件:
   emit FeeRecorded(recordKey, paymaster, user, 38000, 1728226200, 0xabc123)
```

### 8.2 Keeper链下结算

```
7. Keeper监听到FeeRecorded事件
8. 获取历史ETH价格:
   - getHistoricalETHPrice(1728226200) → $2500
9. 计算gas成本:
   - gasETH = 38000 * 1e9 / 1e18 = 0.000038 ETH
   - gasCostUSD = 0.000038 * 2500 = $0.095
10. 计算PNT数量:
    - basePNT = 0.095 / 0.02 = 4.75 PNT
11. 添加1.5%手续费:
    - finalPNT = 4.75 * 1.015 = 4.82125 PNT
12. 执行转账:
    - GasToken.transferFrom(user, treasury, 4.82125e18)
    - 成功 (预授权已完成)
13. 标记已结算:
    - Settlement.settleFees([recordKey], settlementHash)
14. 用户PNT余额:
    - 100 - 4.82 = 95.18 PNT
```

## 9. 多PNT支持扩展

### 9.1 当前: 单一PNT

```solidity
// Settlement配置
paymasterGasTokens[paymaster] = 0x3e7B771d4541eC85c8137e950598Ac97553a337a; // PNT
tokenExchangeRates[PNT] = 1e18; // 1:1基准
```

### 9.2 未来: 多PNT扩展

```solidity
// 发行aPNT (项目A积分)
factory.createGasToken("aPNT", "aPNT", 1.2e18); // 1 aPNT = 1.2 PNT

// 发行bPNT (项目B积分)
factory.createGasToken("bPNT", "bPNT", 0.8e18); // 1 bPNT = 0.8 PNT

// 用户可选择用哪种PNT支付
// paymasterAndData中包含token地址
```

**链下结算时:**
```javascript
// 基础PNT成本: 4.75 PNT

// 如果用户选择aPNT支付:
const exchangeRate = 1.2e18;
const aPNTAmount = 4.75 * 1.2 = 5.7 aPNT

// 如果用户选择bPNT支付:
const exchangeRate = 0.8e18;
const bPNTAmount = 4.75 * 0.8 = 3.8 bPNT
```

### 9.3 UniswapV4实时汇率

**未来扩展: 从Uniswap获取aPNT/PNT实时汇率**

```javascript
// 链下Keeper查询Uniswap池
const pool = new ethers.Contract(uniswapPoolAddress, poolABI, provider);

async function getExchangeRateFromUniswap(tokenA, tokenB) {
  const slot0 = await pool.slot0();
  const sqrtPriceX96 = slot0.sqrtPriceX96;
  
  // 计算价格: (sqrtPriceX96 / 2^96)^2
  const price = (sqrtPriceX96 / 2**96) ** 2;
  
  return price * 1e18; // 转换为1e18精度
}

// 使用:
const realTimeRate = await getExchangeRateFromUniswap(aPNT, PNT);
// 例: 1.18e18 (市场价: 1 aPNT = 1.18 PNT)

const aPNTAmount = basePNT * realTimeRate / 1e18;
```

**Gas消耗:**
```
Uniswap V4 slot0()读取: ~2000 gas (链下调用,不消耗用户gas)
Keeper批量处理100条记录: 2000 gas (分摊后可忽略)
```

## 10. 实施步骤

### Phase 1: 最小改动 (当前Sprint)

**合约改动:**
```solidity
// 1. Settlement.sol
struct FeeRecord {
    // ...现有字段
    uint64 gasGwei;     // 新增: 替代原uint256 amount
    uint64 timestamp;   // 新增: block.timestamp
}

uint256 public feeRate = 150; // 新增: 1.5%手续费

function setFeeRate(uint256 _feeRate) external onlyOwner;
```

**链下服务:**
```
1. 部署Keeper服务 (Node.js)
2. 监听FeeRecorded事件
3. 集成Chainlink历史价格API
4. 实现自动结算逻辑
```

**配置:**
```bash
# Settlement配置
Settlement.setFeeRate(150) # 1.5%
Settlement.setTreasury(0xF7Bf79AcB7F3702b9DbD397d8140ac9DE6Ce642C)
```

### Phase 2: GasToken工厂 (2-3周)

```
1. 开发GasTokenFactory合约
2. 开发GasToken基础合约 (预授权)
3. 迁移现有PNT到新GasToken
4. 测试预授权流程
```

### Phase 3: 多PNT支持 (1-2个月)

```
1. 支持用户在paymasterAndData中指定token
2. PaymasterV3读取用户选择的token
3. Keeper支持多token结算
4. 集成UniswapV4汇率查询
```

## 11. 需要确认的设计决策

### 11.1 关键参数

**请确认以下配置:**

1. **PNT基础价格**: $0.02 ✅
2. **手续费率**: 1.5% (150 basis points) ✅
3. **预授权额度**: 500 PNT (100次交易) ✅
4. **minTokenBalance**: 
   - 当前: 10 PNT
   - 建议: 50 PNT (≈10次L2交易余量)
   - **您的意见?**

5. **部署环境**:
   - 测试: Sepolia (高gas,仅测试)
   - 生产: Arbitrum/Optimism/Base?
   - **目标L2是哪个?**

6. **Keeper运行频率**:
   - 实时结算 (每个区块)
   - 批量结算 (每小时/每天)
   - **您的倾向?**

### 11.2 技术选型

**历史价格数据源:**
- [ ] Chainlink历史数据 (推荐,去中心化)
- [ ] CoinGecko API (备选,中心化)
- [ ] 其他?

**Keeper部署方式:**
- [ ] 自建服务器
- [ ] Gelato Network (去中心化keeper)
- [ ] Chainlink Automation
- [ ] 其他?

## 12. 优势总结

**相比链上汇率转换:**

1. **Gas节省**: 
   - 链上计算汇率: ~5000 gas/次
   - 链下计算: 0 gas
   - 批量100条: 节省500,000 gas

2. **灵活性**:
   - 无需合约升级即可调整汇率算法
   - 支持复杂定价策略(阶梯定价、VIP折扣等)

3. **准确性**:
   - 使用记录时的历史价格,公平透明
   - 避免MEV攻击(价格预言机操纵)

4. **扩展性**:
   - 轻松支持多种PNT
   - 轻松集成UniswapV4等DeFi协议

## 13. 风险与缓解

### 13.1 中心化风险

**问题**: Keeper是中心化服务,可能作恶或宕机

**缓解:**
- 多个Keeper竞争结算(谁先执行谁获得手续费分成)
- 用户可自行调用结算函数
- 设置最大延迟时间(如7天),超时用户可申诉

### 13.2 价格操纵风险

**问题**: 历史价格数据可能被篡改

**缓解:**
- 使用Chainlink去中心化预言机
- 多数据源交叉验证
- 价格波动保护(单次最大±20%)

### 13.3 预授权安全风险

**问题**: 预授权可能被恶意合约利用

**缓解:**
- 验证规则: 只能转账Pending状态的记录
- 额度限制: 单次最大500 PNT
- 可撤销: 用户随时可调用revoke()

## 14. 下一步行动

### 14.1 立即任务

- [ ] 确认设计方案
- [ ] 确认关键参数(手续费率、预授权额度等)
- [ ] 修改Settlement.sol (添加gasGwei和timestamp)
- [ ] 开发Keeper基础框架
- [ ] 编写单元测试

### 14.2 本周任务

- [ ] 部署修改后的Settlement到测试网
- [ ] 实现Keeper监听逻辑
- [ ] 集成Chainlink价格API
- [ ] 完整E2E测试

### 14.3 下周任务

- [ ] 开发GasTokenFactory
- [ ] 实现预授权逻辑
- [ ] 压力测试
- [ ] 准备主网部署

---

**设计状态**: 等待您确认关键参数和技术选型
**优先级**: 高 - 直接影响V3上线时间
