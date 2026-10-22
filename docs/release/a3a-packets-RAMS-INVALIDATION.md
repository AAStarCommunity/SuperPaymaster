# A3a 预检包 v1–v4：R-AMS 执行失效声明（2026-10-22）

> 本文件单独存放，**不修改**任何已封存的包目录（各包的 `EVIDENCE.sha256` 校验的是目录内的全部文件，改动包内文件会让 manifest 失效）。

## 结论

| 包 | 目录 | 快照块 | 状态 |
|---|---|---|---|
| v1 | `a3a-precheck/` | 11,794,003 | 早已被取代；同样不可执行 |
| v2 | `a3a-precheck-v2/` | 11,877,799 | **EXECUTION-INVALID（R-AMS）** |
| v3 | `a3a-precheck-v3/` | 11,960,489 | **EXECUTION-INVALID（R-AMS）** |
| v4 | `a3a-precheck-v4/` | 11,961,849 | **EXECUTION-INVALID（R-AMS）**（DSR CC-125 d13dd9eb） |

**哪些仍然成立**：身份字段，包括地址、calldata、salt、operation id、safeTxHash、nonce 计划。它们只依赖 nonce 和源码。

**哪些不成立**：
- 所有 gas 数字，包括 `gasUsedInFork` 和 `suggestedGasLimit`；
- 「fork 演练 OK」这一结论；
- 资金估算；
- 负对照的 gas 行为。

其中 S2/S3 按包内的 gasLimit 在链上会耗尽 gas（out of gas）。S1 也不够：41,108 < 48,641（实测最小可行值）。

## 原因

Sepolia 于 **2026-10-06 13:53:36 UTC** 启用了 Amsterdam（Glamsterdam 执行层），早于所有快照块。各包的 fork 演练用的是 forge 1.7.1 的 anvil，它不实现 Amsterdam：显式传 `--hardfork amsterdam` 会直接崩溃，默认规则是旧规则。runbook 第 0 步要求用 `eth_config` 检查 fork 层级，这一步在 v2/v3/v4 中**都没有执行**。

## 证据

- `../design/aoa-balance-mode/data/rams/capture-11969744.json`：在同一块上，三个端点（reth v2.7.0 / reth v2.8.0 / Tenderly）读回的内容一致，包括：
  - chainId、块哈希；
  - `eth_config`：`current.activationTime = 1791294816`，`forkId 0x6c1d9423`，`next = null`；
  - S1/S2/S3 的 `eth_estimateGas`：48,938 / 9,307,838 / 9,257,602；
  - 按包内 gasLimit 执行 `eth_call` 的结果：revert / OOG / OOG。
- **未广播的事实**：同一份文件里，部署者 nonce 在该块与 `pending` 均为 12131，Safe nonce 为 1，三个端点一致。
- **引擎对照**：见 `../design/aoa-balance-mode/data/rams/README.md`。

## 授权记录

- 作者在 2026-10-22 对 v4 包回答了三个选项（1=A，2=A，3=A），并给出 go。SP 在 CC-125 `cfa29193` 记录了这次 go，并在执行器闸门拦下 S1 后报告了 R-AMS。
- 按 DSR d13dd9eb：这次 go **只针对 v4 包**，不延伸到任何新包、任何参数调整或升级。三个选项的答案保留，不需要重新询问。新包需要 DSR 复核，作者也要对新包单独给 go。
