# Two-Tier Slashing Mechanism

## 架构设计

### 两层惩罚体系

```
┌─────────────────────────────────────────────────────┐
│           DVT Validator Network (13 nodes)          │
│              链下监控 + 7/13 共识                     │
└──────────────┬──────────────────┬───────────────────┘
               │                  │
               │                  │
      ┌────────▼────────┐  ┌──────▼──────────┐
      │  Tier 1 Slash   │  │  Tier 2 Slash   │
      │  (轻微违规)      │  │  (严重违规)      │
      └────────┬────────┘  └──────┬──────────┘
               │                  │
               │                  │
    ┌──────────▼──────────┐ ┌─────▼──────────────┐
    │ SuperPaymasterV3    │ │ GTokenStaking      │
    │ executeSlashWithBLS │ │ slashByDVT         │
    └──────────┬──────────┘ └─────┬──────────────┘
               │                  │
               │                  │
    ┌──────────▼──────────┐ ┌─────▼──────────────┐
    │ aPNTs Balance       │ │ GToken Stake       │
    │ (运营资金)           │ │ (质押资产)          │
    │ - 交易失败          │ │ - 恶意行为          │
    │ - 短期离线          │ │ - 长期不在线        │
    │ - 服务质量差        │ │ - 重大违规          │
    └─────────────────────┘ └────────────────────┘
```

## Tier 1: SuperPaymaster Slash (aPNTs)

### 触发条件
- 交易失败率高
- 短期离线 (< 1小时)
- 响应速度慢
- 服务质量问题

### 惩罚级别
```solidity
enum SlashLevel {
    WARNING,  // 0: 警告,不扣款,降 reputation 10
    MINOR,    // 1: 轻微,扣 10% aPNTs,降 reputation 20
    MAJOR     // 2: 严重,扣 100% aPNTs + 暂停,降 reputation 50
}
```

### 惩罚对象
- **aPNTs Balance**: Operator 的运营资金
- **Reputation**: 影响服务排名

### 执行流程
```
DVT Validator 监控
  → 创建提案 (轻微级别)
  → 7/13 签名
  → BLSAggregator 验证
  → SuperPaymaster.executeSlashWithBLS()
  → 扣除 aPNTs + 降低 reputation
```

## Tier 2: GTokenStaking Slash (GToken)

### 触发条件
- 恶意行为 (双花、作弊)
- 长期不在线 (> 24小时)
- 重大安全事故
- 多次 Tier 1 惩罚后仍不改进

### 惩罚对象
- **GToken Stake**: 质押的治理代币
- **角色资格**: 可能被踢出网络

### 执行流程
```
DVT Validator 监控
  → 创建提案 (严重级别)
  → 7/13 签名
  → BLSAggregator 验证
  → GTokenStaking.slashByDVT()
  → 扣除质押 GToken → treasury
```

### 接口定义
```solidity
function slashByDVT(
    address operator,
    bytes32 roleId,
    uint256 penaltyAmount,
    string calldata reason
) external;
```

## 使用场景

### 场景 1: 服务质量问题
```
Operator 交易失败率 > 10%
  → DVT 监控发现
  → 创建 MINOR 提案
  → Tier 1 Slash
  → 扣除 10% aPNTs
  → Operator 改进服务或补充 aPNTs
```

### 场景 2: 短期离线
```
Operator 离线 30 分钟
  → DVT 监控发现
  → 创建 WARNING 提案
  → Tier 1 Slash
  → 只降低 reputation,不扣款
  → Operator 恢复在线
```

### 场景 3: 长期不在线
```
Operator 离线 > 24 小时
  → DVT 监控发现
  → 创建严重提案
  → Tier 2 Slash
  → 扣除部分 GToken 质押
  → Operator 可能失去角色资格
```

### 场景 4: 恶意行为
```
Operator 尝试双花攻击
  → DVT 监控发现
  → 创建严重提案
  → Tier 2 Slash
  → 扣除全部 GToken 质押
  → 永久踢出网络
```

## 未来 DVT 监控增强

### 自动化监控流程
```javascript
// DVT Validator 监控程序 (链下)
class DVTMonitor {
  async monitorOperator(operator) {
    // 每小时 4 次探测
    for (let i = 0; i < 4; i++) {
      const result = await this.probeOperator(operator);
      
      if (!result.success) {
        this.recordFailure(operator);
      }
      
      await sleep(15 * 60 * 1000); // 15分钟
    }
    
    // 检查失败次数
    const failures = this.getFailureCount(operator);
    
    if (failures >= 3) {
      // 创建提案并签名
      const proposal = await this.createSlashProposal(
        operator,
        failures >= 4 ? SlashLevel.MAJOR : SlashLevel.MINOR,
        `Failed ${failures}/4 probes in last hour`
      );
      
      // 广播给其他验证者
      await this.broadcastProposal(proposal);
    }
  }
  
  async probeOperator(operator) {
    // 主动探测: 发送测试交易
    // 或被动监控: 检查链上活动
    return {
      success: true/false,
      latency: ms,
      errorRate: percentage
    };
  }
}
```

## 权限管理

### GTokenStaking 授权
```solidity
// 部署时设置
gTokenStaking.setAuthorizedSlasher(blsAggregator, true);
```

### SuperPaymaster 授权
```solidity
// 部署时设置
superPaymaster.setBLSAggregator(blsAggregator);
```

## 事件追踪

### Tier 1 事件
```solidity
event OperatorSlashed(
    address indexed operator,
    uint256 penaltyAmount,
    SlashLevel level
);
```

### Tier 2 事件
```solidity
event StakeSlashed(
    address indexed operator,
    bytes32 indexed roleId,
    uint256 amount,
    string reason,
    uint256 timestamp
);
```

## 查询接口

### SuperPaymaster 查询
```solidity
// 获取 slash 历史
function getSlashHistory(address operator) external view returns (SlashRecord[] memory);

// 获取 slash 次数
function getSlashCount(address operator) external view returns (uint256);

// 获取最近一次 slash
function getLatestSlash(address operator) external view returns (SlashRecord memory);
```

### GTokenStaking 查询
```solidity
// 获取质押信息
function getStakeInfo(address operator, bytes32 roleId) external view returns (StakeInfo memory);

// 获取锁定余额
function getLockedStake(address user, bytes32 roleId) external view returns (uint256);
```

## 优势

1. **分层管理**: 轻重分离,精准打击
2. **灵活响应**: 快速处理轻微问题,严格处理重大违规
3. **资产隔离**: 运营资金和质押资产分开管理
4. **可扩展性**: DVT 监控逻辑可以链下升级
5. **去中心化**: 7/13 共识机制,防止单点作恶

## 部署清单

- [x] SuperPaymasterV3.executeSlashWithBLS() - Tier 1
- [x] SuperPaymasterV3 查询接口
- [x] GTokenStaking.slashByDVT() - Tier 2
- [x] GTokenStaking.getStakeInfo() 查询接口
- [ ] BLSAggregator 支持两层 slash 路由
- [ ] DVTValidator 提案类型扩展
- [ ] 完整测试套件
- [ ] 部署脚本更新
