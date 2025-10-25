# UI Improvements Task List - 2025-10-24

## Overview
用户反馈的 UI 改进和 bug 修复任务列表。

---

## ✅ 已完成
1. **Community Registry 地址说明** - 确认 0x6806...是旧版 Registry

---

## 📝 待处理任务

### 高优先级

#### 1. Step1 到 Step2 点击两次问题 ⚠️
**描述**: step1到step2为何要点两次才进去？
**优先级**: 🔴 HIGH
**位置**: DeployWizard 导航逻辑
**预期**: 点击一次应该直接进入下一步

#### 2. 已有 Paymaster 检测 ⚠️
**描述**: 如果某个钱包已经部署过paymaster了，应该在新部署之前先查询和提示
**优先级**: 🔴 HIGH  
**功能**: 
- 查询钱包是否已有部署的 paymaster
- 提供选项：使用已部署的、开始管理、或部署新的
**实现**: 在 Step1 组件中添加查询逻辑

#### 3. AOA 模式 SBT 和 xPNTs 部署流程 ⚠️
**描述**: 选择AOA模式后没有显示部署 SBT 和 xPNTs 的页面流程
**优先级**: 🔴 HIGH
**需要确认**: AOA 模式是否应该包含这个流程？

#### 4. AOA 模式 stGToken Staking 流程 ⚠️
**描述**: Step 6 AOA 模式没有让用户 stake GToken 获得 stGToken
**优先级**: 🔴 HIGH
**需要调查**: 
- AOA 模式的完整 staking 流程
- 是否需要在 Step 6 之前添加 staking 步骤

### 中优先级

#### 5. Step1 AOA 模式警告注释
**描述**: Enhanced ERC-4337 Flow: AOA 区域应添加警告
**优先级**: 🟡 MEDIUM
**内容**:
```
⚠️ Important Notes
- Relies on PaymasterV4.1 enhanced contract  
- Requires ETH and stGToken resources
```

#### 6. EntryPoint Stake 要求确认
**描述**: 确认官方 EntryPoint 对新注册的 paymaster 是否要求必须 stake，还是只需要 deposit？
**优先级**: 🟡 MEDIUM
**行动**: 查阅 ERC-4337 规范和 EntryPoint 合约代码

#### 7. 管理页面链接改进
**描述**: Adjust Parameters 和 Monitor Treasury 添加指向 manage paymaster 的链接
**优先级**: 🟡 MEDIUM
**位置**: 完成页面 (Final step)

#### 8. Registry 链接修复
**描述**: Quick Actions 中的 "View in Registry" 链接错误
**优先级**: 🟡 MEDIUM
**错误**: `http://localhost:5173/paymaster/0x...`
**正确**: `http://localhost:5173/explorer/0x...`
**位置**: DeployWizardSummary.tsx

### 低优先级

#### 9. 输入框历史记忆
**描述**: operator 页面的管理 paymaster 输入框应该记住历史输入
**优先级**: 🟢 LOW
**实现**: 使用 localStorage 存储历史地址，显示下拉列表

#### 10. Revenue Calculator 改进
**描述**: 
- 添加重新计算按钮
- 默认 gas cost 从 $2.5 改为 0.0001 ETH
**优先级**: 🟢 LOW
**位置**: OperatorsPortal.tsx

---

## 📋 技术问题需确认

### Q1: Paymaster 部署方式
**问题**: 现在paymaster部署是从工厂还是直接用合约代码？
**需要确认**: 查看 Step3_DeployPaymaster.tsx 的实现

### Q2: AOA 模式完整流程
**问题**: AOA (Account Owned Address) 模式的完整技术规范是什么？
**需要确认**: 
- 与 Super Mode 的区别
- 需要哪些额外步骤（SBT部署、xPNTs部署、stGToken staking）
- EntryPoint 的 stake 要求

### Q3: EntryPoint Stake vs Deposit
**问题**: 官方 EntryPoint 对新注册的 paymaster 有什么要求？
**需要确认**:
- stake() 是否必需？
- deposit() 是否足够？
- 两者的区别和用途

---

## 🔧 实现计划

### Phase 1: 紧急修复 (今天)
1. 修复 Step1 到 Step2 点击两次问题
2. 修复 Registry 链接错误  
3. 添加 Step1 AOA 警告注释

### Phase 2: 功能增强 (明天)
4. 实现已有 Paymaster 检测
5. 确认并实现 AOA 模式完整流程
6. 添加管理页面链接

### Phase 3: 优化改进 (后续)
7. 输入框历史记忆
8. Revenue Calculator 改进
9. 文档和测试完善

---

## 📚 相关文档
- [CLAUDE.md - SuperPaymaster Architecture](/Volumes/UltraDisk/Dev2/aastar/SuperPaymaster/CLAUDE.md)
- [V2-Registry-Flow-Analysis.md](/Volumes/UltraDisk/Dev2/aastar/registry/docs/V2-Registry-Flow-Analysis.md)
- [ERC-4337 Specification](https://eips.ethereum.org/EIPS/eip-4337)

