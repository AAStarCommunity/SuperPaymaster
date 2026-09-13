# F1 调查 2：ERC-7562 条文核查（2026-09-13）

来源：`ethereum/ERCs` master `84b46e7d`，`ERCS/erc-7562.md`（sha256 `c272039c…ac4c`，共 426 行）。下面引用的都是原文，行号指该文件。

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
2. **规范预见了"同一账户的多笔 op 在验证期相互依赖"这一情形，并要求 bundler 先把它们放在一起验证**（L384）。按这个要求，B2b 的第 3 笔会在（联合的）第二次验证时失败，按 §Running 第 5 条从 bundle 里丢掉即可。此时 GREP-040 **不适用**（它的前提是"通过了第二次验证、却在 bundle 创建时失败"），SP 只会按常规比例记一次 opsSeen，**不会被立即封禁**。
3. Rundler v0.11.0 的行为是：把同一 sender 的多笔 op 放进同一个 bundle，而第二次验证是逐笔各自进行的，在整 bundle 模拟时才发现失败，于是按 GREP-040 立即封禁 paymaster。**它与 L384 的"MUST first validate them together"不一致**。所以 F1 更准确的定性是：**Rundler 在同一 sender 多笔 op 上没有实现联合验证 × SP 验证期托管设计的交互**，而不是 SP 违反了 ERC-7562。（"Rundler 的第二次验证是否逐笔进行"由对照实验和代码核实，见 `F1-investigation.md`。）
4. **保留意见**：L384 这条 MUST 写在 Rationale 一节，而 Specification 的规则清单里没有对应的编号条目（例如没有 STO-xxx 或 GREP-xxx 与之对应），所以各家 bundler 的实现可能不一致（Alto 在提交时就把同 sender 的待处理 op 排在前面一起模拟，符合这条；Rundler 不符合）。论文里不应该写成"Rundler 违反规范"，而应写成：**"ERC-7562 在其 Rationale 中要求 bundler 对同一账户的多笔 UserOperation 做联合验证；在不做联合验证的 bundler 上，任何验证期托管型 paymaster 都会触发 GREP-040 的连带封禁。"** 这句话是否成立，取决于 TokenPaymaster 对照实验的结果（调查 1）。

## 3. 对缓解方案的含义

- 方案①（自托管 Rundler 设 `same_sender_mempool_count = 1`，或在提交时做联合模拟）等于在我们自己的 bundler 上把 L384 落实，**有规范依据**。
- 方案④（推荐 bundler 名单只收做联合验证的实现）可以直接引用 L384 作为选择标准。
- 可以考虑向 Rundler 上游反馈（外部仓库，由作者决定）：同一 sender 多笔 op 的第二次验证应当联合进行。
