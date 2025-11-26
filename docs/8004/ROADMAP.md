# ERC-8004 Integration Roadmap

**[English](#english)** | **[中文](#chinese)**

<a name="english"></a>

---

## Overview

This roadmap outlines the implementation plan for ERC-8004 (Trustless Agents) integration into the SuperPaymaster ecosystem.

**Integration Approach**: Native Integration (no adapter layer)

---

## Phase 1: MySBT v2.5.0 - Identity Registry

**Goal**: Make MySBT natively ERC-8004 Identity Registry compliant

### Tasks

| # | Task | Description | Complexity |
|---|------|-------------|------------|
| 1.1 | Add `IERC8004IdentityRegistry` interface | Create interface file in contracts/interfaces/ | Low |
| 1.2 | Add token URI storage | `mapping(uint256 => string) private _tokenURIs` | Low |
| 1.3 | Add metadata storage | `mapping(uint256 => mapping(string => bytes)) private _agentMetadata` | Low |
| 1.4 | Implement `register()` overloads | Three variants: default, with URI, with URI+metadata | Medium |
| 1.5 | Implement `setTokenURI()` | Owner-only token URI update | Low |
| 1.6 | Implement `getMetadata()` / `setMetadata()` | On-chain metadata read/write | Low |
| 1.7 | Implement `batchSetMetadata()` | Batch metadata updates | Low |
| 1.8 | Implement `buildAgentCard()` | JSON helper for discovery | Medium |
| 1.9 | Add ERC-8004 events | `Registered`, `MetadataSet`, `TokenURIUpdated` | Low |
| 1.10 | Unit tests | Full test coverage for new functions | Medium |
| 1.11 | Deploy to testnet | Sepolia deployment and verification | Low |

### Estimated Contract Size Impact
- New storage: ~1.2 KB
- New functions: ~0.4 KB
- Total increase: ~1.6 KB (within safe limits)

### Migration Strategy
- No data migration needed
- Existing tokens automatically become agents
- Token ID = Agent ID (1:1 mapping)

---

## Phase 2: ReputationAccumulator v2.0 - Reputation Registry

**Goal**: Add ERC-8004 Reputation Registry while keeping dual-layer reputation

### Tasks

| # | Task | Description | Complexity |
|---|------|-------------|------------|
| 2.1 | Add `IERC8004ReputationRegistry` interface | Create interface file | Low |
| 2.2 | Add client feedback storage | Struct and mappings for feedback data | Medium |
| 2.3 | Implement EIP-191 signature verification | `verifyFeedbackAuth()` function | Medium |
| 2.4 | Implement `giveFeedback()` | With signature authorization check | Medium |
| 2.5 | Implement `revokeFeedback()` | Client can revoke own feedback | Low |
| 2.6 | Implement `appendResponse()` | Agent can respond to feedback | Low |
| 2.7 | Implement `getSummary()` | With tag filtering support | Medium |
| 2.8 | Implement `readFeedback()` | Single feedback read | Low |
| 2.9 | Implement `getClients()` / `getLastIndex()` | Client enumeration | Low |
| 2.10 | Implement `getCombinedReputation()` | Aggregate all reputation sources | Medium |
| 2.11 | Implement `getReputationByTag()` | Tag-filtered reputation | Low |
| 2.12 | Add ERC-8004 events | `NewFeedback`, `FeedbackRevoked`, `ResponseAppended` | Low |
| 2.13 | Unit tests | Full test coverage | Medium |
| 2.14 | Integration tests | Test with MySBT v2.5.0 | Medium |
| 2.15 | Deploy to testnet | Sepolia deployment | Low |

### Reputation Architecture
```
                    ┌─────────────────────────────────────┐
                    │     ReputationAccumulator v2.0      │
                    ├─────────────────────────────────────┤
                    │  Source 1: Community Reputation     │
                    │  - Operator/community activities    │
                    │  - Existing dual-layer system       │
                    ├─────────────────────────────────────┤
                    │  Source 2: Global Reputation        │
                    │  - On-chain activity tracking       │
                    │  - Cross-community scoring          │
                    ├─────────────────────────────────────┤
                    │  Source 3: Client Feedback (NEW)    │
                    │  - ERC-8004 giveFeedback()          │
                    │  - Score 0-100, tagged              │
                    │  - EIP-191 authorization required   │
                    └─────────────────────────────────────┘
```

---

## Phase 3: JuryContract - Validation Registry (MyTask Repo)

**Goal**: Implement ERC-8004 Validation Registry with jury-based verification

**Repository**: `/Volumes/UltraDisk/Dev2/aastar/MyTask`

### Tasks

| # | Task | Description | Complexity |
|---|------|-------------|------------|
| 3.1 | Initialize Foundry project | `forge init` with standard structure | Low |
| 3.2 | Add `IERC8004ValidationRegistry` interface | Create interface file | Low |
| 3.3 | Create `JuryContract.sol` | Main contract skeleton | Medium |
| 3.4 | Implement task creation | `createTask()` with params | Medium |
| 3.5 | Implement evidence submission | `submitEvidence()` | Low |
| 3.6 | Implement juror registration | `registerJuror()` / `unregisterJuror()` | Medium |
| 3.7 | Implement voting mechanism | `vote()` with consensus logic | High |
| 3.8 | Implement task finalization | `finalizeTask()` with result calculation | High |
| 3.9 | Implement slashing/rewards | Incentive mechanism for honest voting | High |
| 3.10 | ERC-8004 validation interface | `validationRequest()` / `validationResponse()` | Medium |
| 3.11 | MySBT integration | Verify agent identity via MySBT | Low |
| 3.12 | Unit tests | Full test coverage | High |
| 3.13 | Gas optimization | Reduce storage costs | Medium |
| 3.14 | Security audit prep | Internal review checklist | Medium |
| 3.15 | Deploy to testnet | Sepolia deployment | Low |

### Task Types
```
TaskType.SIMPLE_VERIFICATION    → Single juror vote
TaskType.CONSENSUS_REQUIRED     → Multiple jurors must agree (66%+)
TaskType.CRYPTO_ECONOMIC        → Stake-weighted voting
TaskType.TEE_ATTESTATION        → TEE-based verification (future)
```

---

## Phase 4: Integration & Testing

**Goal**: End-to-end integration of all components

### Tasks

| # | Task | Description | Complexity |
|---|------|-------------|------------|
| 4.1 | Cross-contract integration tests | MySBT + Reputation + Jury | High |
| 4.2 | Gas optimization analysis | Measure and optimize gas costs | Medium |
| 4.3 | Event indexing setup | Subgraph or custom indexer | Medium |
| 4.4 | API documentation | SDK usage examples | Medium |
| 4.5 | Agent discovery flow | Test ENS/API discovery path | Medium |
| 4.6 | Gasless transaction flow | Test agent gas sponsorship | Medium |
| 4.7 | Community sponsorship flow | Test community pool usage | Medium |
| 4.8 | End-to-end demo | Full agent lifecycle demo | High |

---

## Phase 5: Mainnet Deployment

**Goal**: Production deployment with security measures

### Tasks

| # | Task | Description | Complexity |
|---|------|-------------|------------|
| 5.1 | Security audit | External audit engagement | High |
| 5.2 | Bug bounty program | Set up bounty for contracts | Medium |
| 5.3 | Mainnet deployment plan | Gas estimation, deployment order | Medium |
| 5.4 | Deploy MySBT v2.5.0 | Mainnet deployment | Low |
| 5.5 | Deploy ReputationAccumulator v2.0 | Mainnet deployment | Low |
| 5.6 | Deploy JuryContract | Mainnet deployment | Low |
| 5.7 | Contract verification | Etherscan verification | Low |
| 5.8 | Documentation update | Final docs with mainnet addresses | Low |
| 5.9 | Monitoring setup | Event monitoring and alerts | Medium |

---

## Dependencies

```
Phase 1 (MySBT v2.5.0)
    │
    └──► Phase 2 (ReputationAccumulator v2.0)
              │
              ├──► Phase 3 (JuryContract) ─► Parallel
              │
              └──► Phase 4 (Integration)
                        │
                        └──► Phase 5 (Mainnet)
```

---

## Success Metrics

| Metric | Target |
|--------|--------|
| MySBT contract size increase | < 2 KB |
| Gas cost for `register()` | < 100k gas |
| Gas cost for `giveFeedback()` | < 150k gas |
| Gas cost for `vote()` | < 80k gas |
| Test coverage | > 95% |
| Security audit findings | 0 critical, 0 high |

---

<a name="chinese"></a>

# ERC-8004 集成路线图

**[English](#english)** | **[中文](#chinese)**

---

## 概述

本路线图概述了将 ERC-8004（Trustless Agents）集成到 SuperPaymaster 生态系统的实施计划。

**集成方式**: 原生集成（无适配器层）

---

## 第一阶段: MySBT v2.5.0 - 身份注册

**目标**: 使 MySBT 原生支持 ERC-8004 身份注册

### 任务列表

| # | 任务 | 描述 | 复杂度 |
|---|------|------|--------|
| 1.1 | 添加 `IERC8004IdentityRegistry` 接口 | 在 contracts/interfaces/ 创建接口文件 | 低 |
| 1.2 | 添加 token URI 存储 | `mapping(uint256 => string) private _tokenURIs` | 低 |
| 1.3 | 添加元数据存储 | `mapping(uint256 => mapping(string => bytes)) private _agentMetadata` | 低 |
| 1.4 | 实现 `register()` 重载 | 三个变体：默认、带 URI、带 URI+元数据 | 中 |
| 1.5 | 实现 `setTokenURI()` | 仅所有者可更新 token URI | 低 |
| 1.6 | 实现 `getMetadata()` / `setMetadata()` | 链上元数据读写 | 低 |
| 1.7 | 实现 `batchSetMetadata()` | 批量元数据更新 | 低 |
| 1.8 | 实现 `buildAgentCard()` | 用于发现的 JSON 辅助函数 | 中 |
| 1.9 | 添加 ERC-8004 事件 | `Registered`, `MetadataSet`, `TokenURIUpdated` | 低 |
| 1.10 | 单元测试 | 新函数完整测试覆盖 | 中 |
| 1.11 | 部署到测试网 | Sepolia 部署和验证 | 低 |

### 合约大小影响预估
- 新存储: ~1.2 KB
- 新函数: ~0.4 KB
- 总增加: ~1.6 KB（在安全限制内）

### 迁移策略
- 无需数据迁移
- 现有 token 自动成为 agent
- Token ID = Agent ID（1:1 映射）

---

## 第二阶段: ReputationAccumulator v2.0 - 声誉注册

**目标**: 添加 ERC-8004 声誉注册，同时保留双层声誉系统

### 任务列表

| # | 任务 | 描述 | 复杂度 |
|---|------|------|--------|
| 2.1 | 添加 `IERC8004ReputationRegistry` 接口 | 创建接口文件 | 低 |
| 2.2 | 添加客户反馈存储 | 反馈数据的结构体和映射 | 中 |
| 2.3 | 实现 EIP-191 签名验证 | `verifyFeedbackAuth()` 函数 | 中 |
| 2.4 | 实现 `giveFeedback()` | 带签名授权检查 | 中 |
| 2.5 | 实现 `revokeFeedback()` | 客户可撤销自己的反馈 | 低 |
| 2.6 | 实现 `appendResponse()` | Agent 可回复反馈 | 低 |
| 2.7 | 实现 `getSummary()` | 支持标签过滤 | 中 |
| 2.8 | 实现 `readFeedback()` | 单个反馈读取 | 低 |
| 2.9 | 实现 `getClients()` / `getLastIndex()` | 客户枚举 | 低 |
| 2.10 | 实现 `getCombinedReputation()` | 聚合所有声誉来源 | 中 |
| 2.11 | 实现 `getReputationByTag()` | 按标签过滤的声誉 | 低 |
| 2.12 | 添加 ERC-8004 事件 | `NewFeedback`, `FeedbackRevoked`, `ResponseAppended` | 低 |
| 2.13 | 单元测试 | 完整测试覆盖 | 中 |
| 2.14 | 集成测试 | 与 MySBT v2.5.0 测试 | 中 |
| 2.15 | 部署到测试网 | Sepolia 部署 | 低 |

### 声誉架构
```
                    ┌─────────────────────────────────────┐
                    │     ReputationAccumulator v2.0      │
                    ├─────────────────────────────────────┤
                    │  来源 1: 社区声誉                    │
                    │  - Operator/社区活动                 │
                    │  - 现有双层系统                      │
                    ├─────────────────────────────────────┤
                    │  来源 2: 全局声誉                    │
                    │  - 链上活动追踪                      │
                    │  - 跨社区评分                        │
                    ├─────────────────────────────────────┤
                    │  来源 3: 客户反馈 (新增)             │
                    │  - ERC-8004 giveFeedback()          │
                    │  - 分数 0-100，带标签               │
                    │  - 需要 EIP-191 授权                │
                    └─────────────────────────────────────┘
```

---

## 第三阶段: JuryContract - 验证注册 (MyTask 仓库)

**目标**: 实现基于陪审团的 ERC-8004 验证注册

**仓库**: `/Volumes/UltraDisk/Dev2/aastar/MyTask`

### 任务列表

| # | 任务 | 描述 | 复杂度 |
|---|------|------|--------|
| 3.1 | 初始化 Foundry 项目 | `forge init` 标准结构 | 低 |
| 3.2 | 添加 `IERC8004ValidationRegistry` 接口 | 创建接口文件 | 低 |
| 3.3 | 创建 `JuryContract.sol` | 主合约骨架 | 中 |
| 3.4 | 实现任务创建 | `createTask()` 带参数 | 中 |
| 3.5 | 实现证据提交 | `submitEvidence()` | 低 |
| 3.6 | 实现陪审员注册 | `registerJuror()` / `unregisterJuror()` | 中 |
| 3.7 | 实现投票机制 | `vote()` 带共识逻辑 | 高 |
| 3.8 | 实现任务完成 | `finalizeTask()` 带结果计算 | 高 |
| 3.9 | 实现惩罚/奖励 | 诚实投票的激励机制 | 高 |
| 3.10 | ERC-8004 验证接口 | `validationRequest()` / `validationResponse()` | 中 |
| 3.11 | MySBT 集成 | 通过 MySBT 验证 agent 身份 | 低 |
| 3.12 | 单元测试 | 完整测试覆盖 | 高 |
| 3.13 | Gas 优化 | 减少存储成本 | 中 |
| 3.14 | 安全审计准备 | 内部审查清单 | 中 |
| 3.15 | 部署到测试网 | Sepolia 部署 | 低 |

### 任务类型
```
TaskType.SIMPLE_VERIFICATION    → 单个陪审员投票
TaskType.CONSENSUS_REQUIRED     → 多陪审员必须达成一致 (66%+)
TaskType.CRYPTO_ECONOMIC        → 质押加权投票
TaskType.TEE_ATTESTATION        → 基于 TEE 的验证（未来）
```

---

## 第四阶段: 集成与测试

**目标**: 所有组件的端到端集成

### 任务列表

| # | 任务 | 描述 | 复杂度 |
|---|------|------|--------|
| 4.1 | 跨合约集成测试 | MySBT + Reputation + Jury | 高 |
| 4.2 | Gas 优化分析 | 测量和优化 gas 成本 | 中 |
| 4.3 | 事件索引设置 | Subgraph 或自定义索引器 | 中 |
| 4.4 | API 文档 | SDK 使用示例 | 中 |
| 4.5 | Agent 发现流程 | 测试 ENS/API 发现路径 | 中 |
| 4.6 | 无 Gas 交易流程 | 测试 agent gas 赞助 | 中 |
| 4.7 | 社区赞助流程 | 测试社区池使用 | 中 |
| 4.8 | 端到端演示 | 完整 agent 生命周期演示 | 高 |

---

## 第五阶段: 主网部署

**目标**: 带安全措施的生产部署

### 任务列表

| # | 任务 | 描述 | 复杂度 |
|---|------|------|--------|
| 5.1 | 安全审计 | 外部审计 | 高 |
| 5.2 | 漏洞赏金计划 | 为合约设置赏金 | 中 |
| 5.3 | 主网部署计划 | Gas 估算，部署顺序 | 中 |
| 5.4 | 部署 MySBT v2.5.0 | 主网部署 | 低 |
| 5.5 | 部署 ReputationAccumulator v2.0 | 主网部署 | 低 |
| 5.6 | 部署 JuryContract | 主网部署 | 低 |
| 5.7 | 合约验证 | Etherscan 验证 | 低 |
| 5.8 | 文档更新 | 带主网地址的最终文档 | 低 |
| 5.9 | 监控设置 | 事件监控和告警 | 中 |

---

## 依赖关系

```
第一阶段 (MySBT v2.5.0)
    │
    └──► 第二阶段 (ReputationAccumulator v2.0)
              │
              ├──► 第三阶段 (JuryContract) ─► 可并行
              │
              └──► 第四阶段 (集成)
                        │
                        └──► 第五阶段 (主网)
```

---

## 成功指标

| 指标 | 目标 |
|------|------|
| MySBT 合约大小增加 | < 2 KB |
| `register()` Gas 成本 | < 100k gas |
| `giveFeedback()` Gas 成本 | < 150k gas |
| `vote()` Gas 成本 | < 80k gas |
| 测试覆盖率 | > 95% |
| 安全审计发现 | 0 关键，0 高危 |
