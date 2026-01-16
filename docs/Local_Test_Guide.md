# SuperPaymaster V3 本地测试与自动化部署指南

本指南记录了如何在本地 Anvil 环境中快速部署 SuperPaymaster V3.1.1 完整栈并进行端到端验证。

# SuperPaymaster V3 本地测试：新手快速上手指南 🚀

欢迎加入 SuperPaymaster 的开发！本指南将帮助你在本地环境从零开始运行完整的协议栈测试。

---

## 🏁 第一步：启动本地私有链 (Anvil)

打开一个独立的终端窗口，启动 Anvil 并模拟真实出块时间：

```bash
anvil --block-time 1
```

> [!TIP]
> 保持这个窗口开启。如果测试过程中出现逻辑混乱，可以随时 `Ctrl+C` 重启它。

---

## 🛠️ 第二步：自动化部署与初始化

在 `projects/SuperPaymaster/contracts/` 目录下运行部署脚本。它会自动完成合约部署、测试账户创建、角色注册及初始资金准备。

```bash
# 进入合约目录
cd projects/SuperPaymaster/contracts/

# 执行一键部署逻辑
forge script script/DeployV3FullLocal.s.sol:DeployV3FullLocal --rpc-url http://localhost:8545 --broadcast
```

**该脚本完成后，你会得到：**
1. 完整的协议组件地址（打印在终端）。
2. 一个预注册的运营商（Deployer）。
3. 一个带有初始资金的测试账户（Alice）。

---

## 🧪 第三步：运行 SDK 模块化测试 (Aastar SDK)

进入 `projects/aastar-sdk/` 目录。我们已将测试拆分为四个模块，建议按顺序运行以确保逻辑完整。

### 1. 基础配置测试 (Admin)
检查运营商是否已正确配置及暂停逻辑是否正常。
```bash
pnpm exec ts-node scripts/06_local_test_v3_admin.ts
```

### 2. 声誉与信用评分 (Reputation)
验证计算引擎是否能根据活跃度正确给出分数及 ETH 信用额度。
```bash
pnpm exec ts-node scripts/06_local_test_v3_reputation.ts
```

### 3. 资金充提测试 (Funding)
测试运营商的储备金加注和协议收益提取流程。
```bash
pnpm exec ts-node scripts/06_local_test_v3_funding.ts
```

### 4. 交易赞助测试 (Execution)
模拟真实的 UserOperation 在 Paymaster 的赞助下执行。
```bash
pnpm exec ts-node scripts/06_local_test_v3_execution.ts
```

---

## 🛡️ 第四步：CI/CD 与质量保证

为了确保每次代码变动不会破坏核心逻辑，我们建议：
- **Pre-commit**: 本地提交代码前，`lint-staged` 或 Git Hook 会自动触发基础编译检查。
- **GitHub Actions**: 每次 Push 到远端仓库后，云端会自动启动 Anvil 并运行上述所有 `06_local_*.ts` 脚本进行回归测试。

---

## 💡 故障排查与维护
- **Nonce 不对？** 如果你重启了 Anvil 但没有重新部署，请确保重新运行第二步。
- **索引映射**: 关注 `06_local_test_v3_admin.ts` 中的索引注释，V3.1.1 的数据结构索引与早期版本有所不同。
