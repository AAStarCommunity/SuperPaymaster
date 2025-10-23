# 测试场景3: 混合模式与用户迁移

## 🎯 测试目标
1. 理解v4和v2的混合运行模式
2. 测试同一用户在两个系统间切换
3. 验证迁移路径和最佳实践

---

## 🔍 混合模式架构解析

### 什么是混合模式？

**混合模式** = v4 (PNT系统) + v2 (xPNTs系统) 同时运行

```
                     EntryPoint v0.7
                           |
                    ┌──────┴──────┐
                    |             |
            PaymasterV4    SuperPaymasterV2
                    |             |
              PNT + SBT    xPNTs + MySBT
                    |             |
                  用户A         用户B

             (也可以是同一个用户!)
```

### 为什么需要混合模式？

1. **向后兼容**: 老用户继续使用v4 (PNT)
2. **平滑迁移**: 新用户/社区使用v2 (xPNTs)
3. **功能测试**: 同时测试两个系统
4. **风险隔离**: v2出问题不影响v4

---

## 📋 系统对比

### v4 (单一代币模式)

| 特性 | 实现方式 |
|------|---------|
| 支付代币 | **统一PNT** |
| SBT | **统一SBT合约** |
| Paymaster | **单一PaymasterV4** |
| 经济模型 | 用户直接支付PNT |
| 去中心化 | ❌ 中心化 |
| 社区自主 | ❌ 受限 |

### v2 (多代币生态模式)

| 特性 | 实现方式 |
|------|---------|
| 支付代币 | **多种xPNTs** (每社区一个) |
| SBT | **MySBT** (支持多社区) |
| Paymaster | **Operator竞争市场** |
| 经济模型 | Operator预充值 + 用户支付(待实现) |
| 去中心化 | ✅ Operator去中心化 |
| 社区自主 | ✅ 发行自己的xPNTs |

### 关键区别

```
v4: 用户 → [PNT] → PaymasterV4 → 赞助gas
           简单，但中心化

v2: 用户 → [xPNTs] → Operator → SuperPaymasterV2 → 赞助gas
           复杂，但去中心化和灵活
```

---

## 🔄 用户迁移路径

### 场景A: v4老用户 → v2新系统

**前提**:
- 用户已有: PNT余额, v1 SBT
- 目标: 使用v2系统

#### 迁移步骤

**步骤1: 加入一个v2社区**

```bash
# 用户选择一个v2社区（有operator）
COMMUNITY_OPERATOR=0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA
XPNTS_TOKEN=0x8a0a19cde240436942d3cdc27edc2b5d6c35f79a

# 检查该社区的operator
cast call $SUPER_PAYMASTER_V2_ADDRESS \
  "getOperatorAccount(address)" \
  $COMMUNITY_OPERATOR \
  --rpc-url $SEPOLIA_RPC_URL
```

**步骤2: 获取GToken并stake**

```bash
USER=$OWNER2_ADDRESS
USER_KEY=$OWNER2_PRIVATE_KEY

# 1. 获取GToken (购买或airdrop)
cast send $GTOKEN_ADDRESS "mint(address,uint256)" $USER 10000000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL --private-key $DEPLOYER_KEY

# 2. Stake GToken
cast send $GTOKEN_ADDRESS "approve(address,uint256)" $GTOKEN_STAKING_ADDRESS 1000000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL --private-key $USER_KEY

cast send $GTOKEN_STAKING_ADDRESS "stake(uint256)" 1000000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL --private-key $USER_KEY
```

**步骤3: Mint MySBT (v2社区身份)**

```bash
# Approve GToken for mint fee
cast send $GTOKEN_ADDRESS "approve(address,uint256)" $MYSBT_ADDRESS 1000000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL --private-key $USER_KEY

# Mint SBT
cast send $MYSBT_ADDRESS \
  "mintSBT(address)" \
  $XPNTS_TOKEN \
  --rpc-url $SEPOLIA_RPC_URL \
  --private-key $USER_KEY \
  --gas-limit 600000
```

**步骤4: 获取xPNTs**

```bash
# 方式1: 从社区购买/获得
# 方式2: 通过活动airdrop
# 方式3: 测试环境直接mint

cast send $XPNTS_TOKEN "mint(address,uint256)" $USER 500000000000000000000 \
  --rpc-url $SEPOLIA_RPC_URL --private-key $COMMUNITY_OPERATOR_KEY
```

**步骤5: 发起v2 UserOp**

现在用户可以使用v2系统了！

```typescript
// UserOp with v2 paymaster
const userOp = {
  // ...
  paymasterAndData: encodePacked(
    ['address', 'address'],
    [SUPER_PAYMASTER_V2_ADDRESS, COMMUNITY_OPERATOR]
  )
};
```

#### 迁移总结

| 步骤 | v4资产 | v2资产 | 状态 |
|------|-------|-------|------|
| 初始 | PNT + v1 SBT | - | v4用户 |
| +GToken | PNT + v1 SBT | GToken | 准备中 |
| +Stake | PNT + v1 SBT | sGToken | 准备中 |
| +MySBT | PNT + v1 SBT | sGToken + MySBT | 可用v2 |
| +xPNTs | PNT + v1 SBT | sGToken + MySBT + xPNTs | ✅ v2用户 |

**关键**: 用户**同时持有两套资产**，可以**自由选择**使用v4或v2！

---

### 场景B: 同一用户，选择性使用两个系统

**用户状态**:
```json
{
  "address": "0xe24b6f321B0140716a2b671ed0D983bb64E7DaFA",
  "v4_assets": {
    "pnt": "1000",
    "sbt_v1": 1
  },
  "v2_assets": {
    "sGToken": "5",
    "mySBT": 1,
    "xPNTs_community_A": "200",
    "xPNTs_community_B": "150"
  }
}
```

#### 使用策略

**策略1: 根据交易类型选择**

```
小额交易 (< $1) → 使用v4 (PNT)
  - 原因: 简单，PNT充足

大额交易 (> $1) → 使用v2 (xPNTs)
  - 原因: 特定社区优惠，xPNTs价值更高
```

**策略2: 根据社区选择**

```
Community A活动 → 使用v2 + xPNTs_A
Community B活动 → 使用v2 + xPNTs_B
通用交易 → 使用v4 + PNT
```

**策略3: 根据可用性选择**

```
if (xPNTs余额 > 需要) {
  使用v2
} else if (PNT余额 > 需要) {
  使用v4
} else {
  交易失败
}
```

---

## 🧪 混合模式测试

### 测试1: 同一账户，切换paymaster

```bash
#!/bin/bash
# test-hybrid-switch.sh

USER=$OWNER2_ADDRESS
USER_KEY=$OWNER2_PRIVATE_KEY

echo "=== 测试1: 使用v4 paymaster ==="
# 构建UserOp with v4
# paymasterAndData = PAYMASTER_V4_ADDRESS + ...

echo "=== 测试2: 使用v2 paymaster ==="
# 构建UserOp with v2
# paymasterAndData = SUPER_PAYMASTER_V2_ADDRESS + OPERATOR

echo "=== 对比结果 ==="
# v4: PNT余额减少
# v2: xPNTs余额不变（因为未实现），operator aPNTs减少
```

### 测试2: 多社区xPNTs场景

```bash
# 用户在两个社区
COMMUNITY_A_XPNTS=0x8a0a19cde240436942d3cdc27edc2b5d6c35f79a
COMMUNITY_B_XPNTS=0x... (需要创建)

# 检查余额
cast call $COMMUNITY_A_XPNTS "balanceOf(address)(uint256)" $USER --rpc-url $SEPOLIA_RPC_URL
cast call $COMMUNITY_B_XPNTS "balanceOf(address)(uint256)" $USER --rpc-url $SEPOLIA_RPC_URL

# 选择使用Community A的xPNTs
# 在UserOp中指定Community A的operator
```

---

## 🔧 迁移工具设计

### 一键迁移脚本

```bash
#!/bin/bash
# migrate-v4-to-v2.sh

set -e

USER_ADDRESS=$1
USER_KEY=$2

if [ -z "$USER_ADDRESS" ] || [ -z "$USER_KEY" ]; then
    echo "用法: ./migrate-v4-to-v2.sh <user_address> <user_private_key>"
    exit 1
fi

source env/.env

echo "=== SuperPaymaster v4 → v2 迁移工具 ==="
echo "用户地址: $USER_ADDRESS"
echo ""

# 1. 检查v4资产
echo "1. 检查v4资产..."
V4_PNT=$(cast call $PNT_TOKEN_ADDRESS "balanceOf(address)(uint256)" $USER_ADDRESS --rpc-url $SEPOLIA_RPC_URL)
V4_SBT=$(cast call $SBT_CONTRACT_ADDRESS "balanceOf(address)(uint256)" $USER_ADDRESS --rpc-url $SEPOLIA_RPC_URL)

echo "   PNT: $V4_PNT"
echo "   SBT: $V4_SBT"

if [ "$V4_SBT" == "0" ]; then
    echo "   ❌ 用户没有v4 SBT"
fi

# 2. 检查v2资产
echo ""
echo "2. 检查v2资产..."
V2_SGTOKEN=$(cast call $GTOKEN_STAKING_ADDRESS "balanceOf(address)(uint256)" $USER_ADDRESS --rpc-url $SEPOLIA_RPC_URL)
V2_SBT=$(cast call $MYSBT_ADDRESS "balanceOf(address)(uint256)" $USER_ADDRESS --rpc-url $SEPOLIA_RPC_URL)

echo "   sGToken: $V2_SGTOKEN"
echo "   MySBT: $V2_SBT"

# 3. 执行迁移步骤
echo ""
echo "3. 开始迁移..."

if [ "$V2_SGTOKEN" == "0" ]; then
    echo "   → 步骤1: 获取并stake GToken"

    # Mint GToken
    cast send $GTOKEN_ADDRESS "mint(address,uint256)" $USER_ADDRESS 10000000000000000000 \
      --rpc-url $SEPOLIA_RPC_URL --private-key $DEPLOYER_KEY

    # Approve
    cast send $GTOKEN_ADDRESS "approve(address,uint256)" $GTOKEN_STAKING_ADDRESS 1000000000000000000 \
      --rpc-url $SEPOLIA_RPC_URL --private-key $USER_KEY

    # Stake
    cast send $GTOKEN_STAKING_ADDRESS "stake(uint256)" 1000000000000000000 \
      --rpc-url $SEPOLIA_RPC_URL --private-key $USER_KEY

    echo "   ✅ 已stake 1 GToken"
fi

if [ "$V2_SBT" == "0" ]; then
    echo "   → 步骤2: Mint MySBT"

    # 选择社区（默认使用第一个operator的xPNTs）
    COMMUNITY_XPNTS=0x8a0a19cde240436942d3cdc27edc2b5d6c35f79a

    # Approve mint fee
    cast send $GTOKEN_ADDRESS "approve(address,uint256)" $MYSBT_ADDRESS 1000000000000000000 \
      --rpc-url $SEPOLIA_RPC_URL --private-key $USER_KEY

    # Mint
    cast send $MYSBT_ADDRESS "mintSBT(address)" $COMMUNITY_XPNTS \
      --rpc-url $SEPOLIA_RPC_URL --private-key $USER_KEY --gas-limit 600000

    echo "   ✅ 已mint MySBT"
fi

echo ""
echo "4. 获取xPNTs..."
# 这里需要用户自己去社区获取xPNTs
echo "   ⚠️ 请联系社区获取xPNTs，或参与社区活动"

echo ""
echo "=== 迁移完成 ==="
echo ""
echo "✅ 你现在可以使用v2系统了！"
echo ""
echo "当前资产:"
echo "- v4: PNT + v1 SBT (仍然可用)"
echo "- v2: sGToken + MySBT + xPNTs (需要获取)"
echo ""
echo "建议:"
echo "1. 继续使用v4处理日常交易"
echo "2. 在特定社区活动时使用v2"
echo "3. 两套系统互不影响，可自由切换"
```

---

## 📊 迁移决策树

```
用户是否需要迁移到v2?
|
├─ YES (社区特定功能/优惠)
|   |
|   ├─ 已有sGToken?
|   |   ├─ YES → 跳过stake
|   |   └─ NO → 获取并stake GToken
|   |
|   ├─ 已有MySBT?
|   |   ├─ YES → 跳过mint
|   |   └─ NO → Mint MySBT
|   |
|   └─ 获取xPNTs → ✅ 可用v2
|
└─ NO (继续使用v4即可)
    └─ 保持现状 → ✅ 继续用v4
```

---

## 🎯 混合模式最佳实践

### For Users

1. **保留v4资产** - 作为fallback
2. **逐步探索v2** - 小额测试
3. **参与社区活动** - 获取xPNTs
4. **理解经济模型** - 选择最优方案

### For Communities

1. **运行v2 operator** - 为社区成员服务
2. **发行xPNTs** - 建立社区经济
3. **激励迁移** - 提供v2独占优惠
4. **保持兼容** - 支持v4老用户

### For Operators

1. **充足aPNTs储备** - 确保服务可用
2. **合理定价** - 吸引用户
3. **监控声誉** - 避免slash
4. **参与DVT** - 去中心化监控

---

## 🚀 未来演进路径

### Phase 1: 混合运行 (当前)
```
v4 ████████████ 80% traffic
v2 ███ 20% traffic
```

### Phase 2: 平滑过渡 (3-6个月)
```
v4 ██████ 50% traffic
v2 ██████ 50% traffic
```

### Phase 3: v2主导 (6-12个月)
```
v4 ███ 20% traffic (legacy)
v2 ████████████ 80% traffic
```

### Phase 4: v4淘汰 (12+个月)
```
v4 (deprecated)
v2 ███████████████ 100% traffic
```

---

## ✅ 测试检查清单

### 混合模式验证
- [ ] v4和v2同时可用
- [ ] 同一用户可持有两套资产
- [ ] 可根据交易类型选择paymaster
- [ ] v4交易不影响v2资产
- [ ] v2交易不影响v4资产

### 迁移流程验证
- [ ] v4用户可获取sGToken
- [ ] v4用户可mint MySBT
- [ ] v4用户可获取xPNTs
- [ ] 迁移后v4功能仍正常
- [ ] 迁移后可使用v2功能

### 边界情况
- [ ] 只有v4资产 → 只能用v4
- [ ] 只有v2资产 → 只能用v2
- [ ] 两者都有 → 可自由选择
- [ ] 两者都没有 → 交易失败

---

## 🔗 相关文档

- [场景1: v2完整流程](./TEST-SCENARIO-1-V2-FULL-FLOW.md)
- [场景2: v4传统流程](./TEST-SCENARIO-2-V4-LEGACY-FLOW.md)
- [部署报告](./Changes.md)
- [安全审计](./SECURITY-AUDIT-REPORT-v2.0-beta.md)

---

**结论**:
1. **混合模式 = v4和v2并存**，互不影响
2. **用户可自由选择**使用v4或v2
3. **迁移是可选的**，不是强制的
4. **两套系统都会长期维护**，直到v2完全成熟
