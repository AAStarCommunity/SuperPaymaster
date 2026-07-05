# ISSUE / 设计讨论：DVT Slash 机制的业务目标、去中心化违规发现与门槛一致性

**建立日期**: 2026-07-04
**来源**: 2026-07-03 多 Agent 安全审计 H-1
**状态**: OPEN — 设计讨论，非纯代码 bug
**相关代码**: `BLSAggregator.sol`（`verifyAndExecute` L387 / `executeProposal` L450 / 门槛 L97-98 / setter L783-807）；`SuperPaymaster.sol`（`queueSlash` L842 / `executeSlashWithBLS` L889）；`DVTValidator.sol`

---

## 0. 背景与现状（已核实）

- 两条 slash 触发路径的**调用者门禁完全相同**：`msg.sender == owner() || msg.sender == DVT_VALIDATOR`。DVTValidator 合约**不转发**到这两个函数，所以现实中**都只能由 aggregator 的 owner 发起**，再附带 BLS 聚合签名。
- 两条路径的差别只在**门槛**和**消息结构**：
  - `verifyAndExecute`（专用）：`_checkSignatures(proof, hash, defaultThreshold=7)`，消息结构化绑定 `(proposalId, operator, slashLevel, repUsers, newScores, epoch, chainid)`；声誉更新经 Registry **独立复验**。
  - `executeProposal`（通用）：`_checkSignatures(proof, hash, requiredThreshold)`，`requiredThreshold` 由调用方自选、只需 `>= minThreshold=3`（下限可设到 2），随后对**任意 target + 任意 callData** 执行 `target.call`（无 allowlist）。
- SuperPaymaster 侧 `executeSlashWithBLS` / `queueSlash` **只校验 `msg.sender == BLS_AGGREGATOR`，完全不复验 proof/门槛**（`proof` 仅被 `keccak256` 记做审计事件）——即把门槛的信任**全部外包**给 aggregator。
- **当前设计意图**（据团队说明）：7 个 DVT 在启动初期凑不齐，故临时把有效门槛降为 3 个 DVT 签名；未来 DVT 数量上来后再提升到 7 甚至更多。`setMinThreshold` / `setDefaultThreshold` 均 `onlyOwner`，**配置可升级**——这点代码已支持。

---

## 1. 需要先厘清的业务目标（讨论）

Slash 的本质是**惩罚性没资金 + 暂停作恶节点**。设计前要先回答：

1. **要惩罚什么违规？** 目前签名消息里只有 `operator, slashLevel`，**没有 evidence/fault-proof 哈希**，`reason` 字符串未经签名。也就是说链上**无法区分**一次 slash 是"有据可查的作恶惩罚"还是"多数派对竞争对手的定点打击"。→ **违规的定义（rule）目前完全在链下**，链上只承接一个投票结果。

2. **违规如何被"稳定地、去中心化地"发现？** 这是核心问题。两种范式：
   - **(A) 链下检测 + 链上多签背书**（现状）：DVT 节点各自跑检测逻辑，对结果投票，聚合签名上链。去中心化程度 = 签名者集合的独立性 + 门槛。**风险**：检测规则不上链→无法审计"为什么被 slash"；多数派可合谋。
   - **(B) 链上可验证规则**：把可判定的违规（如"未在 N 块内响应"、"提交了冲突签名"、"solvency 跌破阈值"）写成链上可验证的 predicate，任何人可提交证据触发 slash，签名只用于不可链上判定的主观违规。**更去中心化、可审计**，但只覆盖客观可判定的违规。

   建议：**分层**。客观违规（可链上判定）走 (B) 的证据驱动路径，无需多签；主观违规（服务质量、复杂欺诈）走 (A) 的多签路径，但**必须绑定 evidence 哈希**并提高门槛。

3. **门槛应该是多少？** 7/13 是简单多数，非 BFT slashing 惯用的 ≥2/3（9/13）。惩罚性操作的门槛通常应**高于**普通共识，因为误判/合谋的代价是烧掉别人的钱。启动期用 3 是权衡，但应有**明确的升门槛路线图**并在治理层承诺。

---

## 2. 当前"不一致"到底带来什么风险

即便接受"3-of-N 是当前有意门槛"，`executeProposal` 这条通用路径仍引入三个具体风险：

### 风险 1：通用 `.call` 的爆炸半径远大于 slash
`executeProposal` 不是"3 签名能 slash"，而是"3 签名 + owner 能让 aggregator 对**任意合约调任意函数**"。凡是靠 `msg.sender == BLS_AGGREGATOR` 把门的地方全部被这条路径覆盖：`SuperPaymaster.queueSlash/executeSlashWithBLS`、`Registry.markProposalExecuted`、`DVTValidator.markProposalExecuted` 等。所以你**无法用"3 签名只能干 X"来推理系统安全**——它能干的是"aggregator 能干的一切"。这才是 H-1 的真正危害，而非单纯"门槛低"。

### 风险 2：升门槛时的"假提升"陷阱
未来把 `defaultThreshold` 提到 7，**只影响 `verifyAndExecute`**。只要 `executeProposal` 还在、`minThreshold` 还是 3，slash 的**有效门槛仍是 3**。团队可能误以为"我们已经是 7-of-13 了"，实际攻击面还在 3。→ 提升门槛必须**同时**提 `minThreshold`，且最好干脆让 slash 不走通用路径。

### 风险 3：信任外包的不对称
Registry 的声誉更新会**独立复验** BLS 证明（`Registry.sol:414-417`），而 SuperPaymaster 的 slash **不复验**、裸信 aggregator。同一套"aggregator 触发"的动作，一个有二次校验、一个没有——这种不对称让 slash 成为整个系统里**唯一可被通用路径降级**的特权入口。

**综合**：当前 slash 的实际授权 = `owner + 3 DVT 签名，经由一个不受限的通用调用原语`。它既不够去中心（owner 是必需共签方，7-path 形同虚设），又因通用 `.call` 而爆炸半径过大。

---

## 3. 建议的修复方向（分优先级）

**P0（GA 前，纯代码，低成本）——消除不一致，让门槛真正"绑定意图"：**
1. **slash 入口自校验**：`executeSlashWithBLS` / `queueSlash` 不再裸信 `msg.sender == BLS_AGGREGATOR`，而是**自己复验 BLS 证明**并强制 slash 专用门槛（对齐 Registry 的复验模式）。这样即使 aggregator 的通用路径被滥用，也无法以低于 slash 门槛的签名数触发。
2. **`executeProposal` 加 target/selector allowlist**：显式排除 SuperPaymaster/Registry/DVTValidator 的共识/特权函数；或当 target 属特权合约时要求 `requiredThreshold >= defaultThreshold`。通用路径应只服务"确实需要通用性"的场景，绝不覆盖 slash。
3. **单一门槛真源**：让 slash 只认一个配置项（如 `slashThreshold`），`minThreshold` 只作 aggregator 内部安全下限，二者解耦，避免"假提升"。

**P1（治理/审计）——补齐可审计性与门槛路线：**
4. **签名消息绑定 `evidenceHash`** 并 emit，让每次 slash 在链上留下"因何而罚"的可核验指纹。
5. **门槛升级路线图**：文档化"DVT 数达到 X 时门槛提到 Y"的治理承诺，并考虑把惩罚门槛设为 ≥2/3。
6. **配置多签修改**：确认 `setMinThreshold` / `setDefaultThreshold` / 未来的 `setSlashThreshold` 都经多签 owner，且有 timelock（避免 owner 单方在攻击窗口内压低门槛）。

**P2（架构演进）——向证据驱动的去中心化检测迁移：**
7. 把客观可判定的违规（响应超时、冲突签名、solvency 破线）做成**链上可验证 predicate + 无需多签的证据触发**，减少对"诚实多数"的依赖；主观违规保留多签但高门槛 + evidence 绑定。

---

## 4. 待团队决策的问题

- [ ] slash 违规的**权威定义**放链上（规则/predicate）还是留链下（DVT 自行判定）？各覆盖哪些违规类型？
- [ ] 启动期 3-of-N 的**退出条件**是什么（DVT 达到多少个提到多少门槛）？是否写入治理承诺？
- [ ] 惩罚门槛目标值：简单多数(7/13) 还是 BFT(≥9/13)？
- [ ] `executeProposal` 通用路径是否有**除 slash 外的真实用例**？若无，可直接下线该路径，风险 1/2 一并消除。
- [ ] owner 作为 slash 必需共签方是否可接受？若要"节点共识独立 slash、不依赖 owner"，需放开 `verifyAndExecute` 的调用者门禁（允许任意人携带足额证明触发）。

---

*本 issue 由 2026-07-03 审计 H-1 展开。建议与 M-5（弱多数 + 无证据哈希）合并处理。*
