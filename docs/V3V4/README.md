# SuperPaymaster V3 测试文档

## 快速开始

### 检查配置
```bash
cd /Users/jason/Dev/mycelium/my-exploration/projects/SuperPaymaster-Contract
node scripts/check-config.js
```

### 执行 E2E 测试
```bash
node scripts/submit-via-entrypoint.js
```

## 文档结构

### 1. [E2E-Test-Guide.md](./E2E-Test-Guide.md)
**完整的测试指南**,包括:
- 合约部署地址
- 配置检查方法
- 遇到的问题和解决方案
- 完整测试步骤
- 成功案例分析
- Alchemy Gas 效率问题深度分析

**适合**: 需要完整重现测试或深入理解技术细节

### 2. [Test-Summary.md](./Test-Summary.md)
**测试总结文档**,包括:
- 已完成工作清单
- 关键技术发现
- 问题和解决方案汇总
- 当前合约配置
- 待完成工作
- 学习和收获

**适合**: 快速了解测试状态和技术要点

### 3. [Implementation-Plan.md](./Implementation-Plan.md)
**实现计划**,包括:
- V3 系统架构
- 技术实现细节
- 开发任务分解

**适合**: 了解 V3 设计和实现规划

### 4. [PRD-V3.md](./PRD-V3.md)
**产品需求文档**,包括:
- V3 功能定义
- 业务流程
- 技术要求

**适合**: 了解产品需求和业务逻辑

## 核心脚本

### 配置检查
```bash
scripts/check-config.js
```
检查所有合约配置是否正确。

### 测试执行
```bash
scripts/submit-via-entrypoint.js
```
通过 EntryPoint 直接提交 UserOp (绕过 bundler)。

```bash
scripts/e2e-test-v3.js
```
通过 Alchemy bundler 提交 UserOp (会遇到 gas 效率限制)。

### 辅助脚本
```bash
scripts/add-stake.js            # 添加 PaymasterV3 stake
scripts/approve-settlement.js   # 手动授权 Settlement
scripts/verify-e2e-result.js    # 验证测试结果
```

## 关键地址 (Sepolia)

```
EntryPoint v0.7:    0x0000000071727De22E5E9d8BAf0edAc6f37da032
Factory v0.7:       0x70F0DBca273a836CbA609B10673A52EED2D15625
PaymasterV3:        0x1568da4ea1E2C34255218b6DaBb2458b57B35805
Settlement:         0x6Bbf0C72805ECd4305EfCCF579c32d6F6d3041d5
PNT Token:          0xf2996D81b264d071f99FD13d76D15A9258f4cFa9
SBT:                0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f
SimpleAccount:      0x94FC9B8B7cAb56C01f20A24E37C2433FCe88A10D
```

## 成功案例

**交易**: https://sepolia.etherscan.io/tx/0x5bcea0df573e1f1c02c60af5ed69404649b5039b17a3d3db61028193d607ad83

- ✅ 0.5 PNT 成功转账
- ✅ PaymasterV3 赞助 gas
- ✅ Gas 消耗: 165,573
- ✅ 区块: 9354676

## 常见问题

### Q: 为什么不使用 Alchemy bundler?
**A**: Alchemy bundler 有 gas 效率限制 (要求 >= 0.4),我们的 UserOp 不满足。详见 `E2E-Test-Guide.md` 的"Alchemy Gas 效率问题"章节。

### Q: Deposit 和 Stake 的区别?
**A**: 
- **Deposit**: 用于支付 gas 的余额
- **Stake**: 满足 bundler 要求的质押金,不消耗

直接调用 EntryPoint 不需要 stake。

### Q: 如何重现测试?
**A**: 
1. 检查配置: `node scripts/check-config.js`
2. 确保 SimpleAccount 有 >= 10 PNT 和 >= 1 SBT
3. 执行测试: `node scripts/submit-via-entrypoint.js`

### Q: 签名验证为什么失败?
**A**: 必须使用直接 ECDSA 签名,不能用 `signMessage()`:
```javascript
// ❌ 错误
const sig = await wallet.signMessage(ethers.getBytes(userOpHash));

// ✅ 正确
const signingKey = new ethers.SigningKey(privateKey);
const sig = signingKey.sign(userOpHash).serialized;
```

## 下一步

- [ ] 实现 Keeper 结算脚本
- [ ] 解决 Alchemy bundler 适配问题
- [ ] 主网部署准备

## 联系方式

如有问题,请在项目 GitHub 提 issue 或联系开发团队。
