# SuperPaymaster 脚本目录

本目录包含SuperPaymaster项目的部署和测试脚本。

## 📁 目录结构

### deploy/ - 部署脚本
V2.3版本的部署、配置和测试脚本。

#### 核心脚本
- `configure-v2.3-simple.sh` - 配置合约（EntryPoint/aPNTs/Treasury）
- `check-operator-status.sh` - 检查Operator注册状态
- `gas-savings-report.sh` - Gas优化详细报告

#### 原始脚本（待GTOKEN修复后使用）
- `deploy-v2.3.sh` - 部署SuperPaymasterV2_3
- `configure-v2.3.sh` - 配置合约
- `register-operator-v2.3.sh` - 注册Operator
- `test-update-xpnt.sh` - 测试updateOperatorXPNTsToken功能

### gasless-test/ - Gasless交易测试
使用ERC-4337的gasless交易测试脚本。

#### 测试脚本
- `test-gasless-viem-v2-final.js` - V2最终版本gasless测试
- `test-v2.3-gas-savings.js` - V2.3 Gas节省验证
- `test-gasless-viem-v1-optimized.js` - V1优化版本测试
- `test-gasless-viem-v1.2-reputation-offchain.js` - V1.2离线声誉测试

## 🚀 快速开始

### 1. 部署V2.3合约

```bash
# 已完成 - 合约已部署到Sepolia
# 地址: 0xb89011D7a86E5BBf816A66c9CB30d005D9243b1b
```

### 2. 配置合约

```bash
bash scripts/deploy/configure-v2.3-simple.sh
# ✅ 已完成
```

### 3. 检查Operator状态

```bash
bash scripts/deploy/check-operator-status.sh
```

### 4. 查看Gas优化报告

```bash
bash scripts/deploy/gas-savings-report.sh
```

### 5. 运行Gasless测试（需要operator注册）

```bash
cd scripts/gasless-test
node test-gasless-viem-v2-final.js
```

## ⚙️ 环境要求

### 必需环境变量
在 `/Volumes/UltraDisk/Dev2/aastar/env/.env` 中配置：

```bash
SEPOLIA_RPC_URL="https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY"
PRIVATE_KEY="0x..."
OPERATOR_PRIVATE_KEY="0x..."  # 可选，默认使用PRIVATE_KEY
USER_PRIVATE_KEY="0x..."      # 用于gasless测试
```

### 工具依赖
- Foundry (forge, cast)
- Node.js ≥ 16
- npm packages: ethers, dotenv, viem

## 📋 已知问题

### GTOKEN地址问题
当前使用的GTOKEN地址在Sepolia上无代码，导致：
- ❌ 无法注册operator
- ❌ 无法测试updateOperatorXPNTsToken
- ❌ 无法运行完整gasless测试

**解决方案**: 找到正确的Sepolia GTOKEN地址或部署新的GT系统

## 📊 部署状态

### ✅ 已完成
- 合约编译和测试
- 合约部署 (0xb89011D7a86E5BBf816A66c9CB30d005D9243b1b)
- EntryPoint配置
- aPNTsToken配置
- Treasury配置

### ⏸️  待完成
- Operator注册 (需要GTOKEN)
- updateOperatorXPNTsToken测试
- 完整gasless交易验证

## 🔗 相关文档

- [V2.3部署指南](../docs/v2.3/V2.3_DEPLOYMENT_GUIDE.md)
- [部署总结](../docs/v2.3/DEPLOYMENT_SUMMARY_V2.3.md)
- [Gas优化报告](../docs/gas-optimization/GAS_OPTIMIZATION_REPORT.md)

---

**最后更新**: 2025-11-19
**状态**: 部分完成（75%）
