# R-AMS-3 / 方案 A：受保护升级的离线演练（DSR CC-125 b31ada57，报告 AOA_RAMS_522_523 §4）

下列证据在本地 fork 上运行：fork 源是 Sepolia 块 **11,974,561**，引擎为 foundry nightly `926eb1d`，加 `--hardfork amsterdam`、`--no-isolate`、`FOUNDRY_ISOLATE=false`。**没有签名，没有广播，没有改动 `contracts/src`、`contracts/script`、`foundry.toml`。**

测试代码在 `contracts/test/rams/`，说明见那里的 `README.md`。运行脚本：`script/evidence/rams-a-rehearsal.sh`。变异运行器：`script/evidence/rams-a-mutations-inplace.sh`。

## 结果（干净树 e704f1f5，2026-10-23）

| 项 | 结果 | 文件 |
|---|---|---|
| fork 实跑 | **10/10 PASS**（A1–A7、A3_empty、A4_hypothetical、A5b）。header 中 `Dirty paths: 1`，是该日志文件本身（tee 先建文件后写 header） | `rehearsal-20261023T064207Z-94221.log` |
| 变异（判别力） | CONTROL 10/10 GREEN；**M1–M13 全部 KILLED**，且每个变异都在 `targets.tsv` 第 3 列指定的断言上失败（否则会记为 WRONG-ASSERTION） | `mutations-run3/summary.tsv`、`MUTATIONS.md` |
| 同一组测试在未提交树上的先前运行 | fork 10/10、变异 13/13，与上面一致。但 header 的 Commit 行写的是 5b60c80b，实际跑的是未提交的修改，所以只作历史记录 | `rehearsal-20261023T063226Z-67134.log`、`mutations-run2/` |
| 更早的 fork 实跑（修订前夹具） | 15/15、2/9（`SingleTxLimitExceeded`，夹具缺陷，已修） | `fork-run2-11974561.log`、`fork-run1-11974465.log` |
| operator 清单 | 两个独立端点（Alchemy、Tenderly）对区块 11,151,016–11,974,561 的 `OperatorConfigured` 扫描结果一致，都是 4 条日志、2 个 operator（OWNER `0xb560…df0e`、ANNI `0xecaa…33c9`） | `operator-inventory-11974561.json` |
| `mutations-run1-INVALID/` | 无效：临时 worktree 中缺少未提交的测试，子模块克隆也失败 | — |

关键数值：A4_hypothetical 中滞留 **306 aPNTs**（operator 预扣 = protocolRevenue 增量 = reservation）；从第一次暂停起算，Safe 路线的停服时长为 **96h（并行）/ 144h（顺序）**；升级前存在缺口（新注册的 operator 在 5.4.2 上仍可获得赞助），需要在升级交易前立即重新枚举 operator。

## 对照 DSR §4 的五项要求

1. **暂停按真实旧实现执行**
   - A1：在 5.4.2 上对两个 operator 分别调用 `setOperatorPaused`，逐一读回确认。同一个已签名的 op，暂停前能通过验证，暂停后返回 SIG_FAILURE。
   - A2：暂停窗口内仍可新注册 operator，它默认不处于暂停状态，能拿到赞助。升级时同时打开全局暂停才能堵住；A2 用「只解除全局暂停」作对照，确认问题出在这里。
   - 升级以单个顶层调用完成：A3 用 `upgradeToAndCall(newImpl, setGlobalPaused(true))`，在同一笔交易里升级并开启全局暂停。随后读回 implementation、runtime、版本、owner、全局暂停位、零值 GasParams 槽，以及字节码中的默认值。
   - 负对照 A3_empty：升级时不带 data，则全局暂停为 false，postOp limit 为 300k 的 op 会被接受。
2. **旧 context 与恶意入口**
   - A4：升级前打包的 op 在 5.4.2 上正常结算；暂停前已签名、暂停后才提交的 op，直接调用和经 EntryPoint 都被拒绝。
   - A4_hypothetical：同一个 bundle 内触发升级，只有 owner 是 4337 智能账户时才可能发生。复现结果为 `PostOpReverted(InvalidContextLength())`，用户执行回滚、用户代币不扣费；但旧实现 validation 的 operator 预扣及 protocolRevenue 增记不会随 postOp 回滚（见下文）。EOA owner 和 Safe-only timelock 都不是 4337 账户；但被授权的 Safe 交易仍有可能经某个 UserOp 被中继，这条限定已写入说明。
3. **治理时间不偷换**
   - A5（EOA owner）：执行 `queueGasParams` 后，立即执行和在 ETA−1 执行都得到 `GasParamsTimelock()`，到 ETA 才生效。随后读回完整 GasParams，恢复赞助；用 postOp=440k、pmV=1.15M 做真实 V2 `handleOps` 结算，300k 被拒。
   - A6（Safe-only timelock）：PROPOSER / EXECUTOR 只有 Safe，非 Safe 调用者被拒。升级与 queue 合成一个批次执行，`executeGasParams` 依赖前一批次。演示了两种时序：升级后重叠为 **48h**，顺序执行为 **96h**；两者在升级前都另有 48h。
4. **恢复前读回，失败即停**
   - A7 读回门检查 gasParams、owner / guardian、implementation 槽与 runtime、全局暂停位、各 operator 暂停位、timelock 操作状态。对每个字段分别做篡改，都被拒绝；缺少输入时同样拒绝。
5. **新执行器与新包**：不在本次范围内，后续单独交付。

## M1–M10 变异（M11–M13 及完整定义见 MUTATIONS.md）

| ID | 改动 | 被哪条断言抓到 |
|---|---|---|
| M1 | 升级时不带 `setGlobalPaused(true)` | A3 `RAMS: atomic global pause: false != true` |
| M2 | 漏暂停一个 operator | A1 `RAMS: operator pause read-back: false != true` |
| M3 | 在 eta−1 执行 | A5 `GasParamsTimelock()` |
| M4 | 在 `executeGasParams` 之前恢复赞助 | A5 `RAMS: exact SIG_FAILURE required`（300k 的 op 被接受） |
| M5 | queue 时 SETTLE 仍为 160k | A5 `RAMS: SETTLE read-back: 160000 != 420000` |
| M6 | 非 Safe 地址持有 EXECUTOR | A6 `RAMS: extra executor` |
| M7 | `executeGasParams` 没有前置依赖，并先于批次执行 | A6 `FailedInnerCall()`。此时代理仍是 5.4.2，没有该 selector，所以这条只能说明「这种顺序无法完成」 |
| M8 | 读回门少检查 guardian | A7 `next call did not revert as expected` |
| M9 | A2 不开全局暂停 | A2 `RAMS: exact SIG_FAILURE required`（新 operator 的 op 被接受） |
| M10 | 暂停前就提交预签名 op | A4 `next call did not revert as expected` |

## 局限

- operator 清单的完整性，只能保证「两个端点、同一事件签名、覆盖完整区间」三者一致。如果存在其他配置 operator 的路径，这个扫描看不到。5.4.2 的 `configureOperator` 只会发出这一个事件。
- 本演练运行在 R0 机制下（cap 关闭，交易起始 reservoir 为 0）。状态 gas 的 reservoir 不为 0 的 RR 场景属于 R2-F3，单独处理。
- 「自家 mempool 已清空」不能代表全网都清空了。本演练证明的是：在合约层面，从升级那一刻起，到 `executeGasParams` 执行、再到解除暂停之前，没有任何赞助能通过验证。

## Review corrections / evidence scope

**M5 is killed only by the read-back gate.** Settlement does not discriminate SETTLE=420000 versus 160000 at MIN=440000; SETTLE is defense in depth there. The previous claim that every mutant was killed at its named settlement assertion is withdrawn. `test_A5b_settleBindingAnalysis` activates each tuple through queue/execute, measures callback success thresholds for the same real V2 fixture, logs whether any admissible limit intersects the no-OOG band, and asserts that none does. This fixed-path measurement is not a universal bound for arbitrary tokens/states. Fork rerun on clean tree e704f1f5 (`rehearsal-20261023T064207Z-94221.log`): callback success threshold **438,786** at SETTLE 420000 and **174,659** at SETTLE 160000; no admissible no-OOG band at MIN 440000 for either tuple. Note the margin at the proposed tuple: MIN 440000 exceeds the measured 438,786 by only **1,214 gas (0.28%)** on this fixture — a different token/state path needing more than 440k would OOG for an op that sets exactly MIN; this is an input to the R-AMS-3 parameter choice, not settled here.

**Pre-upgrade gap:** after pausing all listed operators and before the upgrade, a newly registered operator can still be sponsored on 5.4.2 (A2 proves it). The sponsorship-stop guarantee starts at the atomic upgrade, not at the first operator pause. Minimize and monitor this window; **re-enumerate operators immediately before the upgrade transaction**, pause any additions, and continue monitoring registrations until upgrade inclusion.

**Total downtime from the first pause:** for the modeled Safe route, **96h parallel / 144h sequential** (48h external wait before upgrade, then 48h / 96h after upgrade). Transaction/inventory work adds operational time. These totals assume the first pause coincides with scheduling the upgrade batch; any earlier pause adds its elapsed time.

**A4_hypothetical stranded accounting:** 5.4.2 validation debits operator `aPNTsBalance` and immediately increases `protocolRevenue` by the reservation. A reverted postOp does not undo those validation writes. For the pinned fixture the stranded amount is **306 aPNTs = 306000000000000000000 token wei** (maxCost 0.00255 ETH, $2000/ETH, $0.02/aPNTs, 10% fee plus 10% validation buffer). The test asserts and logs operator debit = reservation and protocolRevenue increase = the same reservation, while the user's token balance and target execution remain unchanged. It computes the expected amount from live fixture parameters so a different pinned state must use its logged amount. This is a known consequence of the mid-bundle upgrade path, unreachable with EOA owners or the modeled Safe-only owner/executor path; Safe AA modules, delegation or relaying an authorized Safe transaction via a UserOp must remain excluded operationally.

**Assertion coverage:** A6 now proves the exact `TimelockUnexecutedPredecessor(bytes32)` negative on 5.5.0 with a mature activation but an unexecuted batch; M11 removes that dependency. Early-delay negatives use exact `TimelockUnexpectedOperationState` payloads. A3 counts completed rejection probes across every listed operator/limit; M12 skips ANNI's loop body and fails that coverage assertion. M13 grants a non-Safe executor after the constructor audit and must fail the actual execution negative. The duplicate A4 post-upgrade target-hits/EOA-code checks, duplicate A5 ETA check and tautological A6 predecessor-done check are removed; actual settlement and ownership checks remain.

**Evidence headers and verdicts:** both runners share `rams-a-header.sh` and log Forge version, commit, exact args including hardfork/isolation flags, FORK_BLOCK and OPERATORS, with RPC host only `<redacted>`. They unset FOUNDRY_OFFLINE when RPC is configured. The mutation runner requires the target's first failure to contain column 3 of `targets.tsv`; otherwise it reports WRONG-ASSERTION. See `MUTATIONS.md` for all thirteen mutations and the fresh-output rerun command.

Local review verification: `review-offline-verification.log` records successful `forge build --offline`, six budget tests passing, ten RPC-unset route tests skipping, script/format/patch checks, and isolated runner/header diagnostics. The new timestamped rehearsal log is offline skip evidence only.
