# DVT 节点 + x402 Facilitator 统一 operator 节点 — 架构计划

> **状态:计划(PLANNED)。** 迁移/合并**等代码稳定后再执行** —— 前置条件:PR #285 merge + v5.4
> redeploy 部署验证通过 + facilitator-node / DVT 节点各自 live E2E 跑通。当前仅落计划,不动代码。
> 记录日期:2026-06-15。

## 0. 背景与动机

operator(社区运营方)需要同时运行两类链下服务:

1. **x402 Facilitator**(`@superpaymaster/x402-facilitator-node`,现在 SuperPaymaster repo `packages/` 内):
   Hono HTTP server,`/verify` `/settle`,处理 x402 支付结算(EIP-3009 / 直接 xPNTs),调
   `X402Facilitator` 合约。viem + TS。
2. **DVT 节点**(现在 YetAnotherAA-Validator / hub #42):BLS 门限签名验证者,layer-1 `PolicyService`
   读链上 `PolicyRegistry` 判 DVT 触发 + BLS 聚合联签 + slash 监控。TS。

两者**同技术栈(TS/viem)、同 operator 运行、都读同一个 `PolicyRegistry`** —— 有强烈的运维 + 基础设施
共享动机。用户决定:稳定后合并到**一个代码库**,统一成一个 operator 节点(**aNode**,用户确定命名),
内部隔离运行,共享部分提取成库。

## 1. 本质对比(为什么不能简单合并业务逻辑)

| 维度 | x402 Facilitator | DVT 节点 |
|---|---|---|
| 职责 | x402 支付结算(verify 签名 → settle) | 高额操作门限授权(BLS 聚合 + slash 监控) |
| 协议层 | HTTP 支付协议(dapp↔user↔facilitator) | AA 账户共识(validateUserOp→checkPolicy→REQUIRE_DVT) |
| 信任模型 | **单 operator** 服务 | **门限多节点**去中心化共识 |
| 状态 | 基本无状态(nonce 在链上) | 有状态(BLS 私钥、验证者集、聚合收集) |
| 高价值资产 | settle 权限 | **BLS 私钥**(伪造共识=灾难) |
| 攻击面 | 面向公网 HTTP(大) | 节点间 P2P / 链上(可控) |
| 迭代节奏 | 频繁(支付逻辑) | 稳定(共识) |

**关键:协议层正交,但技术栈同源,且共享 `PolicyRegistry` 真相源。**

## 2. 三个融合层面的结论

| 层面 | 结论 | 理由 |
|---|---|---|
| **物理同服务器部署** | ✅ **强烈推荐** | operator 一台机器、一个 docker-compose、一起启动。最自然的运维形态 |
| **代码同仓库(monorepo)** | ✅ **推荐**(用户决定) | 共享层只维护一份,不跨仓同步(正好治了"facilitator 跨层不一致"那类坑) |
| **业务逻辑合并** | 🟡 **只共享基础设施层** | x402 结算 vs BLS 聚合是两套独立业务,逻辑合并只增耦合 |
| **同进程启动** | 🔴 **不合并进程** | 安全:攻破 facilitator 公网 HTTP 入口不能触及 DVT 私钥。故障域:一个挂不能拖垮另一个。升级:各自独立 |

## 3. 目标架构(稳定后执行)

```
统一 operator 节点(aNode) — 一个代码库(monorepo)
├── packages/node-shared (共享库,提取的隔离部分)
│     ├── viem provider / chain config
│     ├── 合约 ABI(X402Facilitator / PolicyRegistry / Registry / SuperPaymaster)
│     ├── PolicyRegistry 读取层(checkPolicy / getAssetSpend) ← 两边都要
│     ├── 链上事件索引
│     └── config / env 加载
├── packages/x402-facilitator (独立进程 :3001)  ← import node-shared,只管 x402 结算
└── packages/dvt-node (独立进程 :3002)           ← import node-shared,只管 BLS 共识 + slash
```

- **部署**:同服务器、同 docker-compose、可一起 `up` —— 但**两个独立进程**,各自端口、故障域、密钥隔离。
- **跨 service 解耦**:不做进程间直接耦合;以 **`PolicyRegistry` 链上状态为唯一真相源**(节点策略源 ==
  slash 策略源,已是 DVT 冻结决策)。
- **接口约定**:按 `docs/design/dvt-node-protocol.md`(签名格式)+ `IPolicyRegistry` 接口 +
  `dvt-policy-governance.md`(策略治理)。

## 4. 迁移路线(稳定后,分步)

1. **前置门槛**:PR #285 merge + v5.4 redeploy 部署验证 + 两个 service 各自 live E2E 绿。
2. **建仓**:在 aastar 组织新建统一节点 repo(monorepo,aNode),或选定一个现有仓库作为宿主。
3. **抽 `node-shared`**:把 viem/ABI/config/PolicyRegistry 读取层从 facilitator 现有代码提取成共享 package。
   facilitator-node 当前的 `verify-sig.ts` / `settle-args.ts` / `scheme.ts` 是 x402 专属,留在 facilitator package。
4. **迁 facilitator**:`@superpaymaster/x402-facilitator-node` 从 SuperPaymaster repo `packages/` 移入新 repo,
   依赖 `node-shared`。**SuperPaymaster repo 删除该 package,在 `docs/` 备注新仓库链接**(合约仓库不再维护
   Node.js service)。
5. **迁/接 DVT 节点**:把 hub 的 DVT 节点代码并入,依赖同一个 `node-shared`。
6. **接口契约测试**:用 `bls-golden-vectors.json` + PolicyRegistry 一致性测试做跨 service CI(防回归 —
   facilitator 已有 21 个 vitest 一致性测试,DVT 侧补对应)。

## 5. 现状边界(当前不变)

- `@superpaymaster/x402-facilitator-node` **暂留 SuperPaymaster repo**(紧耦合 `X402Facilitator` 合约,
  v5.4 期间随合约一起改/测最方便)。
- `@aastar/x402`(aastar-sdk)是 **client SDK**(dapp 发请求用),与 facilitator-node 服务**无关**,不在本计划内。
- 迁移**不在 v5.4 范围**,等代码稳定后单独立项。
