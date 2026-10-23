# R2-F1 修复：三个量具的严格响应校验（DSR CC-125 b31ada57 / 报告 AOA_RAMS_522_523 §3 R2-F1）

全部操作只读：不签名，不广播。提交的文件里没有私钥，也没有带凭据的 RPC URL。

## 改了什么（两轮；第 2 轮按 Codex 挑战修正）

`script/evidence/rams-engine-probe.py`、`script/evidence/rams-capture.py`、`script/b-layer/ams-calibrate.mjs` 三个脚本统一按以下规则处理 RPC 响应。分类规则写在 `script/evidence/lib/rpc_strict.py`，JS 端逐条照搬。

- **信封**：`jsonrpc` 必须是 `"2.0"`；`id` 必须是整数，并且等于本次请求的 id（每次请求递增）；`result` 和 `error` 必须恰好出现一个。calibrate 还会检查 HTTP 状态：不是 200 就中止。
- **结果类型**：
  - `eth_call` 的结果必须是偶数长度的十六进制串；
  - `chainId`、`estimateGas`、nonce、时间戳必须是合法的 quantity；
  - 块哈希必须是 `0x` 加 64 位十六进制；
  - 块号必须等于请求的块号；
  - Safe nonce 必须是 32 字节。
- **预期链**：probe 和 capture 要求 11155111，calibrate 要求 31337；都可以用 `EXPECTED_CHAIN_ID` 覆盖。链不对就判为故障。
- **EVM 失败与 RPC 故障**：
  - 只有「错误码 + 完整消息」都落在精确白名单内，才算 EVM 在这个 gas 下确定性失败，即「gas 不够」。白名单如下：
    - reth：`-32003/-32015` + `out of gas: gas required exceeds: N`、`out of gas: gas exhausted during …: N`；`-32000` + `intrinsic gas too low`；
    - reth / anvil：`3/-32003/-32015` + `execution reverted[: …]`；
    - anvil：`-32003` + `EVM error (OutOfGas|MemoryOOG|MemoryLimitOOG|PrecompileOOG|InvalidOperandOOG|ReentrancySentryOOG)`；`-32000` + `intrinsic gas too high -- (CallGasCostMoreThanGasLimit|GasFloorMoreThanGasLimit)`。
  - 已知的 RPC 故障码一律优先判为故障，即使消息里含有 EVM 措辞也不例外：`-32700/-32600/-32601/-32602/-32603/-32004/-32005/-32006/-32016/-32099/429`。
  - 其余任何错误都判为故障，并中止运行。
  - 例外：capture 收到 `eth_config` 返回的 `-32601`，记为 `unsupported`。
- **阈值稳定性**：
  - 每个阈值做**两次独立的二分**，两次结果必须相同；
  - 然后在 min−1 和 min 两点各复查一次，结果写入 `thresholdSides`；
  - 任一不一致即中止。

  这能抓住「一次搜索中途出现瞬时故障」的情形，但不能证明端点在所有时刻都稳定：两次搜索里出现相同的瞬时故障时，抓不住。

白名单来自真实运行中收集到的报错原文（nightly anvil 和两个 reth 端点在低 gas 下的报错）。第 1 轮漏掉了 `ReentrancySentryOOG`、`MemoryOOG` 和 `GasFloorMoreThanGasLimit`，导致真实运行被误判为故障。第 1 轮用的是子串匹配，Codex 用「`-32005` + 消息里含 `execution reverted`」和「消息以 `droog` 结尾」两个构造样例绕过了它；第 2 轮改为精确匹配。

**换了引擎或节点，必须重新核对这份白名单。**

## DSR 负控（原样纳入）

`script/evidence/dsr-gate/` 下的两个文件是从 DSR 仓库逐字节复制过来的，没有做任何修改：`rams_probe_review.py`、`rams_calibration_review.py`（DSR commit 353b5c40）。sha256 见 `dsr-gate-sha256.txt`，与源文件一致。

| 负控工具 | 修复前（origin/main 版本） | 修复后 |
|---|---|---|
| `rams_probe_review.py` → `rams-engine-probe.py` | **exit 1**：6/6 类非法响应被接受（`dsr-probe-review-before.json`） | **exit 0**：7/7 正确，6 类全部拒绝，正对照通过（`dsr-probe-review-after.json`） |
| `rams_calibration_review.py` → `ams-calibrate.mjs` | **exit 1**：6/6 被接受（`dsr-calibration-review-before.json`） | **exit 0**：7/7 正确（`dsr-calibration-review-after.json`） |

`rams-capture.py` 没有现成的 DSR 工具，于是新增了两个离线测试：

- `script/evidence/test_rams_capture.py`：正对照加 6 个负对照。修复后 7/7 通过。修复前的版本有 4 项被错误通过：null chainId、null 块哈希、result 与 error 同时出现、eth_call 被限流。
- `script/evidence/test_rams_gauges.py`：第 2 轮新增，三个量具共 21 个用例，覆盖 DSR 工具没有覆盖的对抗情形：
  - 错误消息里夹带 EVM 措辞的故障；
  - 以 `oog` 结尾的普通单词；
  - 故障码配合 EVM 文本；
  - 二分过程中出现瞬时故障；
  - capture 的错误链、非法哈希、`0X` 前缀、整数块号、null 的 eth_call、布尔类型的估算、乱码 nonce；
  - calibrate 返回 HTTP 429。

  结果 21/21 通过，输出见 `test_rams_gauges.out`。

## 真实运行的正对照（块 11974357，第 2 轮量具）

| 量具 | 结果 | 文件 |
|---|---|---|
| `rams-engine-probe.py`，nightly `926eb1d` | exit 0，**14/14** 与两个真实端点一致 | `engine-probe-nightly-926eb1d-11974357.{json,log}` |
| `rams-engine-probe.py`，v1.8.6（负对照） | exit 1，**6/14**（CREATE 一类偏低，和以前一致） | `engine-probe-v1.8.6-11974357.{json,log}` |
| `rams-capture.py`，三个真实端点 | exit 0 | `capture-11974357.json` |
| `ams-calibrate.mjs`，全新的 nightly anvil `--hardfork amsterdam` | exit 0，5/5 `CALIBRATION PASS` | `calibration-nightly.{json,log}` |

每条 probe 和 calibrate 的记录现在都带有 `thresholdSides`，即阈值两侧的原始结果。

## 不在本次范围

- `rams-deploy-and-txcap.py`：#520 第 3 轮挑战已经补过信封校验和脱敏，本次没有改，也没有重跑。
- R2-F2（G/B 统一参数矩阵、B6 的 v=175k 重跑）、R2-F3（RR 证据）、R2-F4（受测字节码身份）：另做。
