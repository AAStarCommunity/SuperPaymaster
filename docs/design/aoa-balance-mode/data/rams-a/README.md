# R-AMS-3 / 方案 A：受保护升级的离线演练（DSR CC-125 b31ada57，报告 AOA_RAMS_522_523 §4）

本演练全部在本地 fork 上运行：fork 源是 Sepolia 块 **11,974,561**，引擎为 foundry nightly `926eb1d`，加 `--hardfork amsterdam`、`--no-isolate`、`FOUNDRY_ISOLATE=false`。**没有签名，没有广播，没有改动 `contracts/src`、`contracts/script`、`foundry.toml`。**

测试代码在 `contracts/test/rams/`，说明见那里的 `README.md`。运行脚本：`script/evidence/rams-a-rehearsal.sh`。变异运行器：`script/evidence/rams-a-mutations-inplace.sh`。

## 结果

| 项 | 结果 | 文件 |
|---|---|---|
| fork 实跑（最终夹具） | **15/15 PASS**：9 个路线测试，外加 6 个预算 / 代币回归测试 | `fork-run2-11974561.log` |
| 首次 fork 实跑（夹具缺陷） | 2/9 PASS。7 个失败都是 `SingleTxLimitExceeded()`：夹具一笔存入 1e23 aPNTs，超过了线上 xPNTs v1 的 `maxSingleTxLimit`。修复办法是按线上限额分块存入，op 的 maxCost 按 token / 余额 / 信用 / 授权的限额定尺寸，断言没有放宽 | `fork-run1-11974465.log`、`fork-A1-trace-11974465.log` |
| operator 清单 | 两个独立端点（Alchemy、Tenderly）各自扫描 SP 代理从创建块 11,151,016 到 11,974,561 的全部 `OperatorConfigured`，**结果完全一致**：都是 4 条日志、2 个 operator（OWNER `0xb560…df0e`、ANNI `0xecaa…33c9`）；创建块前一块 `eth_getCode` 为 `0x` | `operator-inventory-11974561.json` |
| 变异（判别力） | **CONTROL GREEN；M1–M10 全部被指定的那条断言抓住** | `mutations-run2/summary.tsv`、`MUTATIONS.md` |

## 对照 DSR §4 的五项要求

1. **暂停按真实旧实现执行**
   - A1：在 5.4.2 上对两个 operator 分别调用 `setOperatorPaused`，逐一读回确认。同一个已签名的 op，暂停前能通过验证，暂停后返回 SIG_FAILURE。
   - A2：暂停窗口内仍可新注册 operator，它默认不处于暂停状态，能拿到赞助。升级时同时打开全局暂停才能堵住；A2 用「只解除全局暂停」作对照，确认问题出在这里。
   - 升级以单个顶层调用完成：A3 用 `upgradeToAndCall(newImpl, setGlobalPaused(true))`，在同一笔交易里升级并开启全局暂停。随后读回 implementation、runtime、版本、owner、全局暂停位、零值 GasParams 槽，以及字节码中的默认值。
   - 负对照 A3_empty：升级时不带 data，则全局暂停为 false，postOp limit 为 300k 的 op 会被接受。
2. **旧 context 与恶意入口**
   - A4：升级前打包的 op 在 5.4.2 上正常结算；暂停前已签名、暂停后才提交的 op，直接调用和经 EntryPoint 都被拒绝。
   - A4_hypothetical：同一个 bundle 内触发升级，只有 owner 是 4337 智能账户时才可能发生。复现结果为 `PostOpReverted(InvalidContextLength())`，用户执行回滚、不扣费。EOA owner 和 Safe-only timelock 都不是 4337 账户；但被授权的 Safe 交易仍有可能经某个 UserOp 被中继，这条限定已写入说明。
3. **治理时间不偷换**
   - A5（EOA owner）：执行 `queueGasParams` 后，立即执行和在 ETA−1 执行都得到 `GasParamsTimelock()`，到 ETA 才生效。随后读回完整 GasParams，恢复赞助；用 postOp=440k、pmV=1.15M 做真实 V2 `handleOps` 结算，300k 被拒。
   - A6（Safe-only timelock）：PROPOSER / EXECUTOR 只有 Safe，非 Safe 调用者被拒。升级与 queue 合成一个批次执行，`executeGasParams` 依赖前一批次。演示了两种时序：升级后重叠为 **48h**，顺序执行为 **96h**；两者在升级前都另有 48h。
4. **恢复前读回，失败即停**
   - A7 读回门检查 gasParams、owner / guardian、implementation 槽与 runtime、全局暂停位、各 operator 暂停位、timelock 操作状态。对每个字段分别做篡改，都被拒绝；缺少输入时同样拒绝。
5. **新执行器与新包**：不在本次范围内，后续单独交付。

## 变异（每项都改动演练流程，不只是改断言）

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
