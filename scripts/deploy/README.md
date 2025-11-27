# SuperPaymaster V2.3 部署和测试脚本

完整的自动化部署和测试工具集

---

## 📁 脚本列表

| 脚本 | 功能 | 状态 |
|------|------|------|
| `deploy-v2.3.sh` | 部署SuperPaymasterV2_3到Sepolia | ✅ 就绪 |
| `configure-v2.3.sh` | 配置EntryPoint、aPNTs、Treasury | ✅ 就绪 |
| `register-operator-v2.3.sh` | 注册Operator (使用bPNT) | ✅ 就绪 |
| `test-update-xpnt.sh` | 测试updateOperatorXPNTsToken功能 | ✅ 就绪 |

---

## 🚀 快速开始

### 方式1: 一键执行全流程

```bash
# 赋予执行权限
chmod +x scripts/deploy/*.sh

# 执行完整流程
bash scripts/deploy/deploy-v2.3.sh && \
bash scripts/deploy/configure-v2.3.sh && \
bash scripts/deploy/register-operator-v2.3.sh && \
bash scripts/deploy/test-update-xpnt.sh
```

### 方式2: 分步执行

#### 步骤1: 部署合约

```bash
bash scripts/deploy/deploy-v2.3.sh
```

**输出**:
- SuperPaymasterV2_3合约地址
- VERSION验证
- DEFAULT_SBT验证

#### 步骤2: 配置合约

```bash
bash scripts/deploy/configure-v2.3.sh
```

**配置项**:
- ✅ setEntryPoint
- ✅ setAPNTsToken
- ✅ setSuperPaymasterTreasury

#### 步骤3: 注册Operator

```bash
bash scripts/deploy/register-operator-v2.3.sh
```

**参数**:
- Stake: 30 GT
- xPNTsToken: bPNT (0x70Da2c1B7Fcf471247Bc3B09f8927a4ab1751Ba3)
- Treasury: 0x411BD567E46C0781248dbB6a9211891C032885e5

#### 步骤4: 测试新功能

```bash
bash scripts/deploy/test-update-xpnt.sh
```

**测试内容**:
- ⚡ updateOperatorXPNTsToken (V2.3新功能)
- 切换: bPNT → xPNT
- 验证事件emit

#### 步骤5: Gas节省测试

```bash
cd scripts/gasless-test
node test-v2.3-gas-savings.js
```

**测试结果**:
- V2.2 vs V2.3对比
- 预期节省: ~10.8k gas
- 费用节省分析

---

## 📋 前置条件

### 1. 环境变量

确保 `/Volumes/UltraDisk/Dev2/aastar/env/.env` 包含:

```bash
SEPOLIA_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY"
PRIVATE_KEY="0x..."
OPERATOR_PRIVATE_KEY="0x..."  # 可选，默认使用PRIVATE_KEY
```

### 2. Operator资产

| 资产 | 数量 | 用途 |
|------|------|------|
| GT Token | ≥ 30 | Operator staking |
| ETH | ≥ 0.1 | Gas费用 |
| bPNT | 可选 | 测试gasless交易 |

### 3. 工具依赖

```bash
# Foundry
forge --version

# Node.js (gasless测试)
node --version
npm install ethers dotenv
```

---

## 🔍 验证清单

### 部署验证

- [ ] SuperPaymasterV2_3地址已保存
- [ ] VERSION = "2.3.0"
- [ ] DEFAULT_SBT = 0xD1e6BDfb907EacD26FF69a40BBFF9278b1E7Cf5C

### 配置验证

- [ ] ENTRY_POINT = 0x0000000071727De22E5E9d8BAf0edAc6f37da032
- [ ] aPNTsToken = 0xBD0710596010a157B88cd141d797E8Ad4bb2306b
- [ ] superPaymasterTreasury = 0x411BD567E46C0781248dbB6a9211891C032885e5

### Operator验证

- [ ] Operator已注册
- [ ] xPNTsToken = bPNT (0x70Da2...)
- [ ] Stake = 30 GT

### 功能验证

- [ ] updateOperatorXPNTsToken成功执行
- [ ] OperatorXPNTsTokenUpdated事件emit
- [ ] Gas节省测试通过

---

## 📊 预期结果

### Gas优化效果

| 版本 | Gas消耗 | vs Baseline | 说明 |
|------|---------|-------------|------|
| Baseline v1.0 | 312,008 | - | 原始版本 |
| V2.2 当前 | 181,679 | -41.8% | Pre-permit优化 |
| **V2.3 新版** | **~170,879** | **-45.2%** | ✨ **SBT优化** |

### 优化来源

```
SBT检查优化: ~10,800 gas
  - V2.2: supportedSBTs[] 数组读取
  - V2.3: DEFAULT_SBT immutable

SafeTransferFrom: +200 gas
  - 安全性提升

净节省: ~10,600 gas
```

### 费用节省

假设: ETH=$3000, gas=2 gwei, aPNT=$0.02

- V2.2: 56.69 xPNT/笔
- V2.3: 53.31 xPNT/笔
- **节省: 3.38 xPNT/笔**

---

## 🔧 故障排查

### 问题1: 部署失败 - Socket error

**解决**:
```bash
# 检查RPC URL
echo $SEPOLIA_RPC_URL

# 尝试不同的RPC
export SEPOLIA_RPC_URL="https://rpc.sepolia.org"
```

### 问题2: Operator注册失败 - InsufficientStake

**解决**:
```bash
# 检查GT余额
cast call 0x36b699a921fc792119D84f1429e2c00a38c09f7f \
  "balanceOf(address)" \
  0x411BD567E46C0781248dbB6a9211891C032885e5 \
  --rpc-url $SEPOLIA_RPC_URL
```

### 问题3: updateOperatorXPNTsToken失败 - NotRegistered

**原因**: Operator未注册

**解决**: 先执行步骤3注册operator

---

## 📝 日志记录

### 部署记录

```bash
# 部署后自动保存到 .env.v2.3
cat .env.v2.3

# 示例输出:
# export PAYMASTER_V2_3=0x...
```

### 交易记录

所有交易hash会输出到终端，建议保存：

```bash
bash scripts/deploy/deploy-v2.3.sh | tee deploy-$(date +%Y%m%d).log
```

---

## 🎯 成功指标

### ✅ 部署成功

- SuperPaymasterV2_3部署地址已验证
- VERSION = "2.3.0"
- DEFAULT_SBT配置正确

### ✅ 功能成功

- Operator注册成功 (使用bPNT)
- updateOperatorXPNTsToken执行成功
- 事件正确emit

### ✅ Gas优化成功

- 实际gas < 175k
- vs V2.2 节省 > 5%
- vs Baseline 节省 > 44%

---

## 📚 相关文档

- [V2.3_DEPLOYMENT_GUIDE.md](../../V2.3_DEPLOYMENT_GUIDE.md) - 完整部署指南
- [V2.3_IMPLEMENTATION_SUMMARY.md](../../V2.3_IMPLEMENTATION_SUMMARY.md) - 实现总结
- [SLITHER_FIXES_SUMMARY.md](../../SLITHER_FIXES_SUMMARY.md) - 安全修复报告
- [OPTIMIZATION_PROPOSAL_V2.3.md](../../OPTIMIZATION_PROPOSAL_V2.3.md) - 优化提案

---

## 🤝 支持

遇到问题？
1. 检查日志输出
2. 参考故障排查部分
3. 查看完整部署指南

---

**版本**: V2.3.0
**最后更新**: 2025-11-19
**状态**: ✅ 就绪可用
