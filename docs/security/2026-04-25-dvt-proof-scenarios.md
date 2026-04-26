# DVT 节点 / SDK 使用 BLS Proof 的典型场景

**Date**: 2026-04-25
**Branch**: `security/audit-2026-04-25`
**Status**: 设计参考文档（用于 Phase 5 修复实施 + SDK 同步）

## 文档目的

本文档定义 SuperPaymaster V3+ 中 BLS 聚合签名 proof 的**四个典型业务场景**，以及对应的：
- DVT 节点本地动作
- 链下 P2P 协作流程
- 聚合者节点的链上提交
- SDK 应当封装的 API 边界

本文档配合 [`2026-04-25-review.md`](./2026-04-25-review.md) 中 B6 章节的 BLS 修复方案使用。

## 术语澄清（避免与现有概念混淆）

| 术语 | 定义 | 不要与之混淆的术语 |
|---|---|---|
| **Price Updater / Price Keeper** | aastar-sdk 中现有的 `keeper run keep` 命令对应的角色 — 每小时调用 `SuperPaymaster.updatePrice` / `PaymasterV4.updatePrice` 更新链上 ETH/USD 缓存 | ❌ 不是 DVT 节点 |
| **DVT 节点** | 每个完成 Registry `ROLE_DVT` 注册并锁定 ≥ `RoleConfig.minStake` GToken 的 validator 运行的节点服务，持有 BLS 私钥 | ❌ 不是 keeper |
| **聚合者节点（Aggregator Node）** | DVT 节点中由轮值/共识选出的某一个，负责把 ≥ threshold 个 BLS 签名做 G2 加法聚合并提交一笔链上交易 | 不是独立服务，是 DVT 节点的一个角色 |

## Proof 编码约定（修复后）

**新格式**（无 PK 字段）：
```solidity
proof = abi.encode(
    bytes sigG2Bytes,    // 96 bytes - aggregated signature (G2 point)
    bytes msgG2Bytes,    // 192 bytes - message in G2
    uint256 signerMask   // 32 bytes - bit i set means validators[i] signed
)
```

链上合约 `BLSAggregator.verifyAggregatedSignature(expectedHash, proof, threshold)`：
1. 解码 `(sig, msgG2, signerMask)`
2. 验消息绑定：`hashToG2(expectedHash) == msgG2`
3. 验签名者数量：`popcount(signerMask) >= threshold`
4. 重建聚合 PK：`pkAgg = Σ blsPublicKeys[validators[i]]` for `i` in signerMask
5. 同步检查每个 signer 当前 `getLockedStake(v, ROLE_DVT) >= RoleConfig.minStake`
6. 配对验证：`e(G1_GEN, sig) == e(pkAgg, msgG2)`

## 场景 A：Slash 一个作恶 Operator

### 业务触发
DVT 节点通过链下监控发现 operator 作恶（链上证据：未按约定退款 / 链下证据：违反协议条款 / Operator 自愿声明退出但未配合等）。

### 完整流程

```
┌────────────────────────────────────────────────────────────────┐
│ Step 1: PROPOSAL（任意 DVT 节点 V0）                            │
│ -------------------------------------------------------------- │
│ V0 → DVTValidator.createProposal(operator=X, level=2, reason)  │
│ → 链上记录 proposalId, operator, slashLevel                    │
│ → emit ProposalCreated(id, X, 2)                               │
└────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────┐
│ Step 2: P2P 广播 + 各节点验证（off-chain）                      │
│ -------------------------------------------------------------- │
│ V0 通过 DVT P2P 协议广播 proposal + 链下证据 (IPFS hash)        │
│ V1, V2, V3, V4 各自独立：                                       │
│   - 拉取证据                                                   │
│   - 验证 operator X 的链上行为（重建 user op 历史 / event log）│
│   - 决定是否同意 slash                                         │
└────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────┐
│ Step 3: 各 validator 独立签名（off-chain）                      │
│ -------------------------------------------------------------- │
│ msgHash = keccak256(abi.encode(                                │
│     proposalId, operator, slashLevel,                          │
│     repUsers=[], newScores=[], epoch=0, chainid                │
│ ))                                                             │
│ msgG2 = hashToG2(msgHash)                                      │
│                                                                │
│ V_i 计算: sig_i = sk_i · msgG2  (G2 标量乘)                    │
│ V_i 通过 P2P 把 (validatorIdx_i, sig_i) 发给指定聚合者         │
└────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────┐
│ Step 4: 聚合者收齐签名（off-chain，由 V0 执行）                 │
│ -------------------------------------------------------------- │
│ 收齐 ≥ threshold (如 3) 个签名后：                              │
│   sig_agg = Σ sig_i  (G2 群加法)                               │
│   signerMask = (1<<idx_0) | (1<<idx_1) | ... | (1<<idx_k)      │
│                                                                │
│   proof = abi.encode(                                          │
│     encodeG2(sig_agg),                                         │
│     encodeG2(msgG2),                                           │
│     signerMask                                                 │
│   )                                                            │
└────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌────────────────────────────────────────────────────────────────┐
│ Step 5: 聚合者上链（V0 调）                                     │
│ -------------------------------------------------------------- │
│ V0 → DVTValidator.executeWithProof(                            │
│   proposalId, [], [], 0, proof                                 │
│ )                                                              │
│ DVTValidator 内部：                                            │
│   - require(isValidator[msg.sender])  [修复后新增鉴权]         │
│   - 转发 → BLSAggregator.verifyAndExecute(...)                 │
│ BLSAggregator 内部：                                           │
│   - 重建 expectedHash 与 Step 3 一致                           │
│   - _aggregatePK(signerMask) 重建 pkAgg                        │
│   - 同步检查每个 signer 仍 stake 充足                          │
│   - pairing 验证 → 通过                                        │
│   - _executeSlash(proposalId, X, 2, proof)                     │
│     → SuperPaymaster.executeSlashWithBLS(X, ...) 扣 aPNTs      │
│     → GTokenStaking.slashByDVT(X, ROLE_OPERATOR, ...) 扣 GToken│
└────────────────────────────────────────────────────────────────┘
```

### SDK 应封装的 API
```typescript
// @aastar/dvt-node (建议)
class DVTAggregator {
  // 节点本地：用自己的 sk 签名一个 proposal
  async signSlashProposal(params: {
    proposalId: bigint,
    operator: Address,
    slashLevel: number,
    epoch: bigint,
    chainId: bigint,
    sk: BLSPrivateKey
  }): Promise<{ validatorIdx: number, sig: G2Point }>;
  
  // 聚合者：收齐签名后聚合
  aggregateSignatures(parts: Array<{ validatorIdx: number, sig: G2Point }>): {
    sigAgg: G2Point,
    signerMask: bigint
  };
  
  // 聚合者：编码 + 提交
  async submitSlash(params: {
    proposalId: bigint,
    sigAgg: G2Point,
    msgG2: G2Point,
    signerMask: bigint
  }): Promise<TxHash>;
}
```

### 注意事项
- **createProposal 与 executeWithProof 必须使用同一份 (operator, slashLevel)**：proposal 创建后，operator/slashLevel 锁定在 storage（DVTValidator.proposals[id]），executeWithProof 转发时使用 storage 内的值，不接受调用者传入。这防止 P2P 阶段与上链阶段不一致。
- **Operator slash 走两条路径**：aPNTs（SuperPaymaster.executeSlashWithBLS）+ GToken（GTokenStaking.slashByDVT）— 两条路径都需要 BLSAggregator 在 `authorizedSlashers` 白名单中。
- **签名收齐时机**：聚合者应当设置一个超时窗口（如 P2P 协议内 30 分钟），过期则放弃当前轮次重新发起。

## 场景 B：每 Epoch 更新全局 Reputation

### 业务触发
每个 epoch 周期结束（如每天 UTC 00:00）时，需要把链下计算的 user reputation 更新到链上 `Registry.globalReputation`。

### 完整流程

```
Step 1: 各 DVT 节点本地计算（off-chain，并行无 P2P）
─────────────────────────────────────────────────
每个节点订阅链上 event 与链下行为数据：
  - SP.UserOpSponsored 事件
  - 链下复议 / 投诉 / NFT hold 事件
  - ReputationSystem.computeScore() 查表（链上 view）

每个节点根据共同的算法独立计算：
  newScores[user] for user in active_users[epoch]
  
Step 2: P2P 共识（off-chain）
─────────────────────────────────────────────────
节点之间交换 keccak256(repUsers, newScores) 哈希
  - 取 N-of-M 一致的版本
  - 不一致时进入仲裁流程（链下投票或重新计算）

一致后产生确定性的 (repUsers[], newScores[])

Step 3: 各节点独立签名
─────────────────────────────────────────────────
proposalId = uint256(keccak256(abi.encode("REP", epoch)))
                            // 注意：避免与 slash proposalId 冲突

msgHash = keccak256(abi.encode(
  proposalId,
  address(0),     // operator = 0（无 slash 路径）
  uint8(0),       // slashLevel = 0
  repUsers,
  newScores,
  epoch,
  chainid
))
msgG2 = hashToG2(msgHash)
sig_i = sk_i · msgG2

Step 4: 聚合者收齐签名 + 提交
─────────────────────────────────────────────────
proof = encode(sig_agg, msgG2, signerMask)

聚合者节点 → BLSAggregator.verifyAndExecute(
  proposalId,
  address(0),     // 无 operator slash
  0,              // 无 slashLevel
  repUsers,
  newScores,
  epoch,
  proof
)

BLSAggregator 内部：
  - 校验 BLS proof
  - 因 repUsers.length > 0 → 转发 Registry.batchUpdateGlobalReputation
  - 因 operator == 0 → 不执行 slash

Registry.batchUpdateGlobalReputation 内部：
  - 验 isReputationSource[msg.sender]（msg.sender == BLSAggregator ✓）
  - 调 BLSAggregator.verifyAggregatedSignature(messageHash, proof, threshold)
    [修复后：Registry 不再调用 blsValidator.verifyProof，
     而是调 BLSAggregator 的统一验证接口]
  - 写入 globalReputation[user] = newScore（受 _clampReputation 100 BPS/epoch 限制）
  - emit GlobalReputationUpdated
```

### SDK 应封装的 API
```typescript
class DVTAggregator {
  // 节点本地：基于链下数据 + 算法计算
  async computeEpochScores(epoch: bigint): Promise<Map<Address, bigint>>;
  
  // 节点本地：发起 P2P 共识，返回一致版本
  async consensusEpochScores(
    localScores: Map<Address, bigint>,
    epoch: bigint
  ): Promise<{ repUsers: Address[], newScores: bigint[] } | null>;
  
  // 节点本地：签名一致版本
  async signEpochUpdate(params: {
    proposalId: bigint,
    repUsers: Address[],
    newScores: bigint[],
    epoch: bigint,
    chainId: bigint,
    sk: BLSPrivateKey
  }): Promise<{ validatorIdx: number, sig: G2Point }>;
  
  // 聚合者：提交
  async submitEpochUpdate(params: {
    proposalId: bigint,
    repUsers: Address[],
    newScores: bigint[],
    epoch: bigint,
    sigAgg: G2Point,
    msgG2: G2Point,
    signerMask: bigint
  }): Promise<TxHash>;
}
```

### 注意事项
- **proposalId 命名空间**：建议使用 `keccak256("REP", epoch)` 派生，避免与 slash proposal 冲突。修复后 BLSAggregator 应在 `executedProposals` mapping 中检查唯一性。
- **batch size 限制**：Registry 强制 `users.length <= 200`。每 epoch 若 active user 超过 200，需要拆成多个 proposal（每个 proposalId 不同，msgHash 自然不同）。
- **operator/slashLevel 必须为 0**：否则 BLSAggregator 与 Registry 双重 BLS 验证会因 messageHash 不一致全部失败（详见 review.md B6-M1）。修复后建议两条路径合并到 BLSAggregator 单点验证，问题自动解决。
- **重放保护**：Registry 内 `lastReputationEpoch[user]` 阻止 epoch 倒退；同一 epoch 同一 user 第二次写入会被 skip（不 revert）。

## 场景 C：通用 Governance 决议（参数变更）

### 业务触发
DAO 决议通过参数变更（如 `SuperPaymaster.protocolFeeBPS` 调整、`xPNTsToken` 增加新的 paymaster 自动批准等），需要 DVT 共识批准后执行。

### 完整流程

```
Step 1: 链下治理（off-chain，论坛 + 投票）
─────────────────────────────────────────────────
DAO 通过决议："SP.protocolFeeBPS 改为 80"
编码 callData:
  callData = abi.encodeCall(
    SuperPaymaster.setProtocolFeeBPS,
    (80)
  )

Step 2: 各节点验证 callData 合法性（off-chain）
─────────────────────────────────────────────────
每个 DVT 节点：
  - 检查决议是否有效（链下投票通过）
  - 解码 callData，确认目标函数 + 参数符合决议
  - 检查 target 在 BLSAggregator.allowedTargets 白名单中
    [修复后新增白名单]

Step 3: 各节点签名
─────────────────────────────────────────────────
proposalId = uint256(keccak256(abi.encode("GOV", proposalRef)))
threshold = max(defaultThreshold, customThreshold)
              // 复杂决议可要求更高门槛

msgHash = keccak256(abi.encode(
  proposalId,
  target,            // SP 地址
  keccak256(callData),
  threshold,
  chainid
))
msgG2 = hashToG2(msgHash)
sig_i = sk_i · msgG2

Step 4: 聚合者提交
─────────────────────────────────────────────────
proof = encode(sig_agg, msgG2, signerMask)

聚合者 → BLSAggregator.executeProposal(
  proposalId,
  target,            // SP 地址
  callData,          // setProtocolFeeBPS(80)
  threshold,
  proof
)

BLSAggregator 内部：
  - require(allowedTargets[target])  [修复后新增白名单]
  - 校验 BLS proof
  - target.call(callData) 执行
  - emit ProposalExecuted
```

### SDK 应封装的 API
```typescript
class DVTAggregator {
  // 提议者：编码决议
  encodeGovernanceProposal(params: {
    target: Address,
    abi: Abi,
    functionName: string,
    args: any[]
  }): { callData: Hex, callDataHash: Hex };
  
  // 节点本地：签名
  async signGovernance(params: {
    proposalId: bigint,
    target: Address,
    callDataHash: Hex,
    threshold: bigint,
    chainId: bigint,
    sk: BLSPrivateKey
  }): Promise<{ validatorIdx: number, sig: G2Point }>;
  
  // 聚合者：提交
  async submitGovernance(params: {
    proposalId: bigint,
    target: Address,
    callData: Hex,
    threshold: bigint,
    sigAgg: G2Point,
    msgG2: G2Point,
    signerMask: bigint
  }): Promise<TxHash>;
}
```

### 注意事项
- **target 白名单**：修复后 `BLSAggregator.allowedTargets[]` 必须包含 target，否则 revert。这阻止任意合约任意调用（B6-N2 修复）。建议白名单包括 Registry / SuperPaymaster / GTokenStaking / xPNTsFactory 等核心合约。
- **threshold 自定义**：复杂治理决议可设置 `customThreshold > defaultThreshold`（如 5/5 vs 3/5）。msgHash 必须包含 threshold，防止聚合者擅自降低 threshold。
- **callData 二次验证**：每个节点签名前必须独立解码 callData 并核对参数，防止聚合者夹带恶意调用。
- **不接受 delegatecall**：修复后建议明确 `target.call(callData)`（已是），杜绝 delegatecall 路径。

## 场景 D：Operator 维度的 User Blacklist

### 业务触发
某 Operator 的链下监控发现某些 user 重复套利、违反 ToS、链下投诉等。Operator 申请把这些 user 列入 Operator 自身的 blacklist（不影响其他 operator）。

### 完整流程

```
Step 1: Operator 提交申请（链下）
─────────────────────────────────────────────────
Operator 向 DVT 节点提交：
  - target operator address
  - users[] 与 statuses[]（true=blacklist, false=remove）
  - 链下证据 (IPFS hash)

Step 2: DVT 节点验证 + 签名
─────────────────────────────────────────────────
每个节点：
  - 检查证据
  - 决定是否同意

msgHash = keccak256(abi.encode(operator, users, statuses))
        // 注意：当前实现 message 不含 chainid！可能存在跨链重放
        // 修复后建议加 chainid 与 proposalId

msgG2 = hashToG2(msgHash)
sig_i = sk_i · msgG2

Step 3: 聚合者提交
─────────────────────────────────────────────────
proof = encode(sig_agg, msgG2, signerMask)

聚合者 → Registry.updateOperatorBlacklist(
  operator,
  users,
  statuses,
  proof
)

Registry 内部：
  - require(isReputationSource[msg.sender])
  - require(proof.length > 0)  [修复后强制]
  - 调 BLSAggregator.verifyAggregatedSignature(messageHash, proof, threshold)
    [修复后统一调用]
  - 转发 SuperPaymaster.updateBlockedStatus(operator, users, statuses)
```

### SDK 应封装的 API
```typescript
class DVTAggregator {
  async signBlacklist(params: {
    operator: Address,
    users: Address[],
    statuses: boolean[],
    chainId: bigint,
    sk: BLSPrivateKey
  }): Promise<{ validatorIdx: number, sig: G2Point }>;
  
  async submitBlacklist(params: {
    operator: Address,
    users: Address[],
    statuses: boolean[],
    sigAgg: G2Point,
    msgG2: G2Point,
    signerMask: bigint
  }): Promise<TxHash>;
}
```

### 注意事项
- **跨链重放风险**：当前 message 编码 `abi.encode(operator, users, statuses)` 不含 chainid。在多链部署场景下，同一组签名可在不同链重放。修复时建议加入 `chainid` 与 proposalId，与场景 A/B 保持一致。
- **强制 BLS 验证**：当前实现允许 `proof.length == 0` 跳过 BLS（B6-H2）。修复后必须强制 require。
- **粒度**：blacklist 是 operator 维度（不影响其他 operator），符合用户隐私与多 operator 竞争的设计。

## 跨场景共性

### 1) Validator 集合的动态变化
- DVT 节点退出（exitRole 释放 lock） → BLSAggregator 应实时检测 `getLockedStake < minStake`，自动从 `validators[]` 中标记为 inactive，但保留 historical index 防止 signerMask 位序变化破坏旧 proof
- 新 validator 加入 → 必须先 Registry.register(ROLE_DVT) → 再 BLSAggregator.registerBLSPublicKey → 自动追加到 `validators[]` 末尾

### 2) signerMask 位序的稳定性
- `validators[]` 数组**只追加，不删除**（防止位序变化）
- 退出的 validator 在数组中保留位置，但 `_aggregatePK` 内的 stake 实时校验会使其 PK 不再可用
- 这意味着 signerMask 的位序与 `validators[]` 的索引一一对应，跨时间稳定

### 3) 离线签名的存活窗口
- DVT 节点的离线签名一旦生成，理论上永久有效（msgHash 锁定）
- 但 BLSAggregator 内部 `executedProposals[proposalId]` 防止重放
- 建议链下 P2P 协议内置 TTL（如 30 分钟），超时则节点拒绝再次签名同一 msgHash

### 4) 验证者退出与签名的兼容
- 假设 V2 在签名后、聚合者提交前 exitRole（释放 stake）
- 链上验证时 `_aggregatePK` 检查 `getLockedStake(V2)` 失败 → revert
- 这是**正确行为**：作为安全的"实时 stake 校验"，防止"先签名后取出 stake 套利"

## SDK 包结构建议

```
packages/dvt-node/        ← 新建（建议）
├── package.json          # @aastar/dvt-node, deps: @aastar/core, @noble/bls12-381 (or similar)
├── src/
│   ├── DVTAggregator.ts  # 主入口
│   ├── bls/
│   │   ├── keys.ts       # BLSPrivateKey / publicKey 类型 + 派生
│   │   ├── sign.ts       # signMsgG2()
│   │   ├── aggregate.ts  # G2 加法聚合
│   │   └── encode.ts     # encodeG1/G2() / decodeG1/G2()
│   ├── proof/
│   │   ├── slash.ts      # 场景 A
│   │   ├── reputation.ts # 场景 B
│   │   ├── governance.ts # 场景 C
│   │   └── blacklist.ts  # 场景 D
│   └── p2p/
│       └── consensus.ts  # P2P 协议骨架（gossipsub 或类似）
└── __tests__/
```

依赖：`@noble/bls12-381` 或 `@chainsafe/bls`（成熟的 BLS12-381 库）

## 与 Phase 5 修复方案的关联

| 本文档场景 | Phase 5 修复点 | review.md 引用 |
|---|---|---|
| 场景 A Step 5 鉴权 | DVTValidator.executeWithProof 加 `onlyValidator` | B6-H1 |
| 场景 A/B/C/D Step 5 PK 重建 | BLSAggregator.\_aggregatePK + 删除 caller 提供 pkG1Bytes | B6-C1a |
| 场景 A/B/C 注册 | BLSAggregator.registerBLSPublicKey 加 stake-gate | B6-C1b |
| 场景 B Step 4 双重验证 | Registry 改调 BLSAggregator.verifyAggregatedSignature | B6-M1 |
| 场景 C Step 4 白名单 | BLSAggregator.allowedTargets[] | B6-N2 |
| 场景 D Step 3 跨链 | Registry.updateOperatorBlacklist 强制 BLS + 加 chainid | B6-H2 |

---

**Last Updated**: 2026-04-25
**Owner**: SuperPaymaster Security Audit Track
**Related**: [`2026-04-25-review.md`](./2026-04-25-review.md), [`2026-04-25-governance-slash-design.md`](./2026-04-25-governance-slash-design.md)
