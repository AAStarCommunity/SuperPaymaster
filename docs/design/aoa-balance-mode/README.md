# AOA 重投：余额支付（balance mode）+ 有界免授权额度：SP 侧技术评估

> **状态：规范 [03-final-spec.md](03-final-spec.md) v3.7-rc，已并入 DSR 的 R1 验收复核；Codex 已审阅 9 轮（第 7、9 轮 APPROVE），v3.7 另做一轮确认。作者的决定全部已定（D-9 由 DSR 经作者授权确定），只剩 CC-121（DVT 打分函数）一项未答复，不阻塞。等作者 review 定稿；确认之前不改合约、不部署。**
> 需求以 DSR 仓库为准，技术方案以本仓库为准。

## 这是什么

AOA（SuperPaymaster 论文，BRA 拒稿 BCRA-D-26-00517）的重投路线已由作者拍板：SP 默认走
**余额支付**，信用（记债）默认关闭、按用户申请并由社区批准后开通；xPNTs 的
auto-approve 改为**有界免授权额度**。DSR 起草了改动清单（X1–X8 / S1–S8 / T-A / T-B /
F1–F4），请本仓库做独立评估，并给出一份双方待确认的技术方案。

需求来源（DSR 仓库，本目录不复制其内容）：

- `writing/paper3-SuperPaymaster-DSR-Rewrite/report/AOA_Decision_1_2_RouteA_BoundedAllowance_2026-09-12.md`
  （§6、§11 为作者决议，§8 链上 TODO，§9 改动清单）
- `…/report/AOA_R1_Line_by_Line_Rootcause_Fix_Prevention_2026-09-11.md`（§3.1.3 路线 A 的结算口径、附录 D）
- `…/report/BRA_Reject_Letter_Structured_2026-09-05.md` 附录 A（审稿信原文）

与本仓库既有提案的关系：[`../credit-switch/`](../credit-switch/)（2026-09-06，**社区级**
信用开关 + A1 只查余额）。本方案改为**用户级**开关 + **A2 验证期锁定**，并且吸收了
credit-switch 已经证明的几条事实（`pendingDebts` 在 if/else 之外、`creditDisabled` 的命名
方向、dryRun 必须同步修改）。

## 文件

| 文件 | 内容 |
|---|---|
| [01-independent-assessment.md](01-independent-assessment.md) | 逐项结论：X1–X8、S1–S8、T-A、T-B、F1–F4，以及 DSR 点名的 a–g 七个问题 |
| [02-proposal-draft.md](02-proposal-draft.md) | 协商记录（v1 → v2.5）：DSR 与 SP 逐条来回、Codex 第 1–3 轮的发现与修订、作者的决定 |
| [03-final-spec.md](03-final-spec.md) | **规范（定稿候选 v3.0-rc）**：决定汇总、结构、token v2 与 SP 5.5.0 的接口/存储/规则、不变量、体积、升级 runbook、信任矩阵、测试矩阵 |

## 分析基线与本次实测

基线：SP `main @ 3b0d4821`；Sepolia SP 代理 `0x09DF0d2e3722EC0e401fE3819E64278a42ae4DE9`
（`SuperPaymaster-5.4.2`）。以下数字全部是 2026-09-12 本次重新测得的，不是抄来的：

| 测量 | 结果 | 方法 |
|---|---|---|
| SP runtime（`[profile.default]`） | **23,569 B，余量 1,007 B** | `forge build --force`，另指定 `FOUNDRY_OUT` 做干净构建，读 `deployedBytecode` |
| xPNTsToken runtime | 15,301 B，余量 9,275 B | 同上 |
| xPNTsFactory runtime / initcode | 6,802 B / 25,182 B | 同上（initcode 内含 token 模板的创建码） |
| **F1 实测**：删掉 `dryRunValidation` 后的 SP | **21,419 B，腾出 2,150 B，余量变为 3,157 B** | 一次性 worktree（已删除）；**对照组**：用同样的命令编译未改动的 SP，复现出 23,569 B，确认 via_ir=true、runs=500 |
| SP 在 EntryPoint 的质押 | `staked=true`，stake = **0.1 ETH**，unstakeDelay = 86,400 s | `EntryPoint.getDepositInfo(SP)` |
| 存量 operator `OperatorConfig` slot 0 的 byte 18–31 | 两个 operator 都是全 0 | `cast storage`（operators 的 base slot 为 5）；byte 16 能读出 `isConfigured=01`，说明解码正确 |
| `SP.xpntsFactory()` | 旧工厂 `0x67422d2e…`（5,221 B，与源码不一致） | `cast call` |
| 三个工厂与本地源码逐字节比对 | `0x9f426568…`（CC28）和 `0x0E54b9e2…`（托管新 aPNTs）：都只有 80 处差异，且全部落在 immutable 区间内；`0x67422d2e…` 长度就不同 | 按 `immutableReferences` 屏蔽后比对 |

## 纪律

- 本目录只做阅读、分析和写文档。合约改动、部署、ABI 变更都等作者 review 之后再做。
- RepCredit 冻结期（等 DSR 发布 "B6 evidence frozen"）内不动产品路径，这一点不变。
- 体积数字只认实测。02 里的估算是估算，实现之后必须按 `[profile.default]` 重新测量。
