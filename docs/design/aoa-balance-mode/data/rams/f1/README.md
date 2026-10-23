# R2-F1 修复：三个量具的严格响应校验（DSR CC-125 b31ada57 / 报告 AOA_RAMS_522_523 §3 R2-F1）

全部操作只读：不签名，不广播。提交的文件里没有私钥，也没有带凭据的 RPC URL。

## 改了什么

`script/evidence/rams-engine-probe.py`、`script/evidence/rams-capture.py`、`script/b-layer/ams-calibrate.mjs` 现在统一按下面的规则处理 RPC 响应：

- **信封校验**：`jsonrpc` 必须是 `"2.0"`；`id` 必须是整数且等于本次请求的 id（每次请求 id 递增）；`result` 和 `error` 必须恰好出现一个。
- **成功结果的类型**：`eth_call` 的结果必须是合法的偶数长度十六进制串；`chainId`、`estimateGas` 必须是合法的 quantity；块哈希必须是 32 字节；块号必须等于请求的块号。
- **预期链**：probe 要求链 ID 为 11155111，capture 由调用方核对，calibrate 要求本地 anvil 的 31337。任何一个都可以用 `EXPECTED_CHAIN_ID` 覆盖。
- **区分真实的 EVM 失败和 RPC 故障**：
  - 只有错误信息属于 EVM 在该 gas 下确定性失败的那几类，才计为「这个 gas 不够」。这几类是：`out of gas`、`*OOG`（revm 的 `OutOfGas`/`MemoryOOG`/`ReentrancySentryOOG` 等）、`gas required exceeds`、`gas exhausted`、`intrinsic gas too low/high`、`CallGasCostMoreThanGasLimit`、`GasFloorMoreThanGasLimit`、`execution reverted`。
  - 其他错误一律视为 RPC 故障，直接中止，例如限流 `-32005`、内部错误、传输失败、未知错误码。这些错误永远不会被当作 gas 边界。
  - capture 遇到 `eth_config` 返回 `-32601`（method not found）时，记为 `unsupported`，不算故障。
- **阈值两侧存档**：二分得到 min 之后，重新调用一次 min−1 和 min，并把两侧的结果写入 `thresholdSides`。如果 min−1 成功，或者 min 失败，就判为「阈值不可复现」并中止。

上面这份 EVM 失败信息的白名单，是从真实运行里收集的：nightly anvil 与两个 reth 端点在低 gas 下的报错原文（见本次提交过程）。最初的版本漏掉了 `ReentrancySentryOOG`、`MemoryOOG` 和 `GasFloorMoreThanGasLimit`，导致真实运行被误判为 RPC 故障而中止。这说明这个白名单需要在新引擎或新节点上重新核对。

## DSR 负控（原样纳入）

`script/evidence/dsr-gate/` 下的两个文件是从 DSR 仓库逐字节复制过来的，没有做任何修改：`rams_probe_review.py`、`rams_calibration_review.py`（DSR commit 353b5c40）。sha256 见 `dsr-gate-sha256.txt`，与源文件一致。

| 负控工具 | 修复前（origin/main 版本） | 修复后 |
|---|---|---|
| `rams_probe_review.py` → `rams-engine-probe.py` | **exit 1**：6/6 类非法响应被接受（`dsr-probe-review-before.json`） | **exit 0**：7/7 正确，6 类全部拒绝，正对照通过（`dsr-probe-review-after.json`） |
| `rams_calibration_review.py` → `ams-calibrate.mjs` | **exit 1**：6/6 被接受（`dsr-calibration-review-before.json`） | **exit 0**：7/7 正确（`dsr-calibration-review-after.json`） |

`rams-capture.py` 没有现成的 DSR 工具，于是新增了 `script/evidence/test_rams_capture.py`，写法仿照 DSR 的工具：mock `urlopen`，正对照之外再加 6 个负对照。修复后 7/7 通过；用同一个测试跑修复前的版本，有 4 项错误通过（null chainId、null 块哈希、result 与 error 并存、`eth_call` 被限流）。

## 真实运行的正对照（块 11974274）

| 量具 | 结果 | 文件 |
|---|---|---|
| `rams-engine-probe.py`，nightly `926eb1d` | exit 0，**14/14** 与两个真实端点一致 | `engine-probe-nightly-926eb1d-11974274.{json,log}` |
| `rams-engine-probe.py`，v1.8.6（负对照） | exit 1，**6/14**（CREATE 一类偏低，和以前一致） | `engine-probe-v1.8.6-11974274.{json,log}` |
| `rams-capture.py`，三个真实端点 | exit 0 | `capture-11974274.json` |
| `ams-calibrate.mjs`，全新的 nightly anvil `--hardfork amsterdam` | exit 0，5/5 `CALIBRATION PASS` | `calibration-nightly.{json,log}` |

每条 probe 和 calibrate 的记录现在都带有 `thresholdSides`，即阈值两侧的原始结果。

## 不在本次范围

- `rams-deploy-and-txcap.py`：#520 第 3 轮挑战已经补过信封校验和脱敏，本次没有改，也没有重跑。
- R2-F2（G/B 统一参数矩阵、B6 的 v=175k 重跑）、R2-F3（RR 证据）、R2-F4（受测字节码身份）：另做。
