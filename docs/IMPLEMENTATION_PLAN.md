# SuperPaymaster V3 链下结算实施计划

## 确认的设计决策

基于讨论确认:
- ✅ Settlement独立管理feeRate (1.5%)
- ✅ 汇率基于UniswapV4池实时获取 (aPNT/PNT等)
- ✅ 链下结算,Settlement只记录gasGwei和timestamp
- ✅ minTokenBalance = 50 PNT
- ✅ 目标L2: Optimism
- ✅ Keeper频率: 每小时一次
- ✅ 价格API: CoinGecko (缓存历史数据)
- ✅ Keeper: 自建服务器 (未来多方计算验证)

## 实施任务清单

### Phase 1: Settlement合约修改 (今天完成)

**1.1 修改FeeRecord结构**
```solidity
struct FeeRecord {
    address paymaster;
    address user;
    address token;
    uint64 gasGwei;        // 新增: 改用Gwei (原amount字段)
    uint64 timestamp;      // 新增: block.timestamp
    FeeStatus status;
    bytes32 userOpHash;
    bytes32 settlementHash;
}
```

**1.2 添加feeRate管理**
```solidity
uint256 public feeRate = 150; // 1.5%

function setFeeRate(uint256 _feeRate) external onlyOwner {
    require(_feeRate <= 1000, "Max 10%");
    feeRate = _feeRate;
    emit FeeRateUpdated(oldRate, _feeRate);
}
```

**1.3 修改recordGasFee()**
```solidity
// PaymasterV3调用时传入Gwei
function recordGasFee(
    address user,
    address token,
    uint256 gasGwei,      // 改为Gwei (除以1e9)
    bytes32 userOpHash
) external {
    // 存储gasGwei和timestamp
}
```

### Phase 2: PaymasterV3修改

**2.1 修改postOp转换为Gwei**
```solidity
function _postOp(..., uint256 actualGasCost, ...) internal {
    // 转换为Gwei
    uint256 gasGwei = actualGasCost / 1e9;
    
    ISettlement(settlementContract).recordGasFee(
        user,
        gasToken,
        gasGwei,      // 传入Gwei而非wei
        userOpHash
    );
}
```

### Phase 3: GasToken合约 (带预授权)

**3.1 GasTokenFactory.sol**
- 基于OpenZeppelin ERC20
- 支持批量发行不同PNT
- 内置预授权逻辑

**3.2 GasToken.sol**
- 自动授权Settlement (500 PNT额度)
- 验证转账合法性
- 支持UniswapV4汇率查询

### Phase 4: Keeper服务 (JavaScript)

**4.1 核心功能**
- 监听FeeRecorded事件
- 获取历史ETH/USD价格 (CoinGecko + 缓存)
- 计算PNT数量
- 执行transferFrom + settleFees

**4.2 运行方式**
- Cron: 每小时执行
- 批量处理pending记录
- 错误重试机制

### Phase 5: 配置更新

**5.1 合约配置**
```bash
Settlement.setFeeRate(150)
Settlement.setTreasury(0xF7Bf79AcB7F3702b9DbD397d8140ac9DE6Ce642C)
PaymasterV3.setMinTokenBalance(50e18)
```

**5.2 部署到Optimism**
- 重新部署修改后的Settlement
- 更新PaymasterV3配置
- 注册到Registry

## 详细实施步骤

### Step 1: 修改Settlement合约 ⏳

文件: `src/v3/Settlement.sol`

关键修改:
1. FeeRecord结构体
2. recordGasFee()参数
3. 添加feeRate
4. 添加treasury
5. 更新事件

### Step 2: 修改PaymasterV3 ⏳

文件: `src/v3/PaymasterV3.sol`

关键修改:
1. _postOp()中转换为Gwei
2. 更新minTokenBalance默认值

### Step 3: 创建GasToken合约 ⏳

新文件: `src/v3/GasToken.sol`, `src/v3/GasTokenFactory.sol`

功能:
1. ERC20基础功能
2. 预授权Settlement
3. 验证转账
4. 支持exchangeRate

### Step 4: 开发Keeper服务 ⏳

新文件: `keeper/settlement-keeper.js`

功能:
1. 事件监听
2. 价格API集成
3. 自动结算
4. 错误处理

### Step 5: 测试和部署 ⏳

- 单元测试
- 集成测试
- Optimism Sepolia测试
- 主网部署

## 关于"revoke"的说明

您提到的revoke问题:

**澄清: "可撤销"指的是用户撤销ERC20授权,不是撤销Settlement记录**

```solidity
// 用户可以撤销授权Settlement的权限
PNT.approve(Settlement, 0); // 撤销授权

// 但Settlement的Pending记录不可撤销
// 一旦记录,必须结算或由Owner处理
```

**安全机制:**
- Pending记录不可删除
- 用户无法"逃避"付费
- 如果用户撤销授权,结算会失败
- Keeper会记录失败,可能将用户加入黑名单

## 价格API成本对比

### Chainlink历史数据
```
免费: 读取链上历史round
成本: 需要调用链上合约,消耗gas
优势: 去中心化,可验证
劣势: 需要gas费,可能较贵
```

### CoinGecko API
```
免费额度: 50次/分钟
Pro计划: $129/月 (无限调用)
成本: 如果缓存,几乎免费
优势: 免费,历史数据完整
劣势: 中心化,需要缓存
```

**推荐方案: CoinGecko + 本地缓存**

缓存策略:
```javascript
// 缓存结构
cache[date] = {
  ethPrice: 2500,
  pntPrice: 0.02,
  timestamp: 1728226200,
  source: 'coingecko'
}

// 每个日期只请求一次
// 永久缓存历史数据
// 每天更新一次当天价格
```

安全性:
- 缓存数据持久化到数据库
- 多数据源验证 (CoinGecko + CoinMarketCap)
- 异常检测 (价格突变>50%则告警)
- 用户可查询结算依据

## 下一步行动

请确认:
1. ✅ 是否开始修改Settlement和PaymasterV3?
2. ✅ GasToken合约是重新创建还是基于gemini-minter的PNTs改造?
3. ✅ Keeper服务的详细需求 (日志、监控、告警等)?

我现在开始实施吗?
