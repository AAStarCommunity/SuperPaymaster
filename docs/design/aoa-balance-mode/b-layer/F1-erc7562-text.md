# F1 调查 2：ERC-7562 条文核查（2026-09-13）

> **证据状态**：本文只包含**条文核查**（原文引用有来源和行号）和**据条文推导出的定性判断**。其中"联合验证时 SP 不会被立即封禁""Rundler 的第二次验证是逐笔进行的"两点**尚未实测或查证源码**，由调查 1（TokenPaymaster 对照）和 Rundler 源码核查来确认，结果将写进 `F1-investigation.md`（**目前还不存在**）。在那之前，下文第 2、3 节的结论都只能视为待验证的推论。

来源：两个版本的原文，内容一致，只是版本和行号不同，论文引用时审稿人按其中任何一个都能复核：

| 版本 | 位置 | sha256 | 行数 | "MUST first validate them together" | GREP-040 |
|---|---|---|---|---|---|
| A：`ethereum/ERCs` master `84b46e7d`（2026-09-13 从 GitHub raw 取得） | `ERCS/erc-7562.md` | `c272039c7b74…62ac4c` | 426 | **L384**：`- A bundler MAY include multiple \`UserOperation\`s of the same account in a bundle, but MUST first validate them together.` | L248 |
| B：本仓库子模块 `standards/ercs`（本机 `git submodule status` 显示 `c6d2d5e3ac26…`；DSR 转述为 `5cbe19bd`，**两者提交号不一致，但文件 sha256 相同**） | `standards/ercs/ERCS/erc-7562.md` | `dd12ceaf8c0e…9c4d16` | 442 | **L387**：`- (A bundler MAY include multiple UserOperations of the same account in a bundle, but MUST first validate them together)` | L248（措辞略有不同："fails the bundle creation after passing second validation"） |

**注意这句话的形式**：在两个版本里，它都位于 **§Rationale for limiting storage access**，是这一节第二个要点里的一句话；版本 B 原文**用括号括起来，是一条括号注释**，版本 A 去掉了括号。两个版本都不在 Specification 的编号规则清单里。下表的行号按版本 A 标注。

## 1. 与 F1 直接相关的条文

| 条文 | 位置 | 原文 | 性质 |
|---|---|---|---|
| **同一账户多笔 op** | §Rationale for limiting storage access，L383–384 | "Validation processes must not overlap, ensuring a single storage modification cannot invalidate a large number of mempool `UserOperation`s. By restricting storage access to the account's associated storage, bundlers can guarantee the inclusion of at least one `UserOperation` per account in a bundle." / "**A bundler MAY include multiple `UserOperation`s of the same account in a bundle, but MUST first validate them together.**" | 使用了 RFC 关键字 MUST，但位于 **Rationale** 一节，而不在 Specification 的规则清单里（见 §3 的保留意见） |
| 第二次验证与整 bundle 验证 | §Running the Validation Rules，L138–144 | "1. … perform a full validation once before accepting a `UserOperation` into its mempool, and again before including it in a bundle/block." / "3. A bundler should also perform a full validation of the entire bundle before submission." / "5. Any failed `UserOperation` must be dropped from the bundle." / "6. The bundler should update the reputation of the staked entity **that violated the rules** …" | 规范性 |
| **GREP-040**（原 SREP-050） | L248 | "If an entity fails bundle creation **after passing the second validation**, its `opsSeen` is set to `BAN_OPS_SEEN_PENALTY` and its `opsIncluded` to zero, causing it to become `BANNED`." | 规范性：Rundler 就是按这条封禁了 SP |
| EREP-015 | L266–267 | "A `paymaster` should not have its opsSeen incremented because of a failure of the factory or account." | 规范性；本案里失败是 paymaster 的 AA34，这条不适用 |
| UREP-010 | L294 | "An unstaked sender that is not throttled or banned is only allowed to have `SAME_SENDER_MEMPOOL_COUNT` `UserOperation`s in the mempool."（常量为 4） | 规范性：同一 sender 在 mempool 里有多笔 op 是被允许的 |
| 大规模失效攻击的定义 | L396–406 | 其中第 2 种是 "Submitting `UserOperation`s that are valid in isolation but become invalid when bundled together." | 说明"单独有效、合在一起无效"正是规范要防的情形，防法是隔离与联合验证 |
| 声誉计算 | L108–134 | opsSeen / opsIncluded 按小时衰减（`value * 23 // 24`）；`max_seen = opsSeen // MIN_INCLUSION_RATE_DENOMINATOR` 超过 `opsIncluded + BAN_SLACK` 才会 BANNED | 规范性：常规失败只会**逐步**影响比例，不会立即封禁 |

## 2. 结论（定性）

1. **SP 5.5.0 的存储访问符合 ERC-7562**：验证期只读写与 sender 关联的槽（STO-021），以及已质押实体自己的存储和只读（STO-031/033）。B 层 106 次模拟逐行对照，清单外访问为 0。
2. **规范预见了"同一账户的多笔 op 在验证期相互依赖"这一情形，并要求 bundler 先把它们放在一起验证**（L384）。按这个要求，B2b 的第 3 笔会在（联合的）第二次验证时失败，按 §Running 第 5 条从 bundle 里丢掉即可。按条文推导：此时 GREP-040 **不适用**（它的前提是"通过了第二次验证、却在 bundle 创建时失败"），SP 只会按常规比例记一次 opsSeen，不会被立即封禁。**这是推论，尚未在做联合验证的 bundler 上实测**（Alto v1.2.5 的 B2b 结果——提交时就拒绝第 3 笔、SP 信誉不受影响——与这个推论一致，但 Alto 走的是提交时联合模拟，不是第二次验证）。
3. 已观测到的事实（B 层 B2b，`B1-B10.md`）：Rundler v0.11.0 把同一 sender 的 3 笔 op 放进同一个 bundle，在整 bundle 模拟时第 3 笔以 AA34 失败，于是按 GREP-040 立即封禁 paymaster。**"其第二次验证是逐笔各自进行的"这一机制解释尚待源码核查。**如果核查成立，**它与 L384 的"MUST first validate them together"不一致**。所以 F1 更准确的定性是：**Rundler 在同一 sender 多笔 op 上没有实现联合验证 × SP 验证期托管设计的交互**，而不是 SP 违反了 ERC-7562。（"Rundler 的第二次验证是否逐笔进行"由对照实验和代码核实，见 `F1-investigation.md`。）
4. **保留意见**：L384 这条 MUST 写在 Rationale 一节，而 Specification 的规则清单里没有对应的编号条目（例如没有 STO-xxx 或 GREP-xxx 与之对应），所以各家 bundler 的实现可能不一致（Alto 在提交时就把同 sender 的待处理 op 排在前面一起模拟，符合这条；Rundler 不符合）。论文里不应该写成"Rundler 违反规范"，而应写成：**"ERC-7562 在其 Rationale 中要求 bundler 对同一账户的多笔 UserOperation 做联合验证；在不做联合验证的 bundler 上，任何验证期托管型 paymaster 都会触发 GREP-040 的连带封禁。"** 这句话是否成立，取决于 TokenPaymaster 对照实验的结果（调查 1）。

## 3. 对缓解方案的含义

- 方案①（自托管 Rundler 设 `same_sender_mempool_count = 1`，或在提交时做联合模拟）等于在我们自己的 bundler 上把 L384 落实，有规范依据；**但这个配置能否真的避免封禁，还没有实测**（B 层 agent 正在重跑 B2b）。
- 方案④（推荐 bundler 名单只收做联合验证的实现）可以直接引用 L384 作为选择标准。
- 可以考虑向 Rundler 上游反馈（外部仓库，由作者决定）：同一 sender 多笔 op 的第二次验证应当联合进行。
