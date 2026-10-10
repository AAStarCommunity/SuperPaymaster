# D5c-1 在 v5.5.0-rc.2 上的完整重跑 + A-3 两个具名负对照（CC-125 d030f6e8 ①）

> **结论先行**：**判定器 `verify-d5c1.py` 给出 `VERDICT: 8 MISMATCH(ES) (267 rows)`，退出码 1 —— 这次重跑没有通过。**
> 8 处不一致里 **6 处是本机负载导致的墙钟 TIMEOUT**（rc.2 的原始证据里这些分区 94–285 s 内 PASS 或按预期 FAIL；本次在 600 s 墙钟上限处被杀），**1 处是判定器自检 P3 因为同样这 6 处而失败**，**1 处是文档引用的 CAP-1 计时与新日志逐字不符**（任何重跑都必然出现）。**没有任何分区给出新的反例，没有任何 FAIL 出现在要求 PASS 的地方；8 个 Halmos 变异与 6 个 fuzz 变异全部按预期被杀。** 但按规则 TIMEOUT 从不算 PASS，所以本目录**不能**作为"rc.2 上 D5c-1 全部满足"的证据；见 §4 的缺口与重跑建议。
>
> A-3 两个负对照（§1）：**4/4 PASS**，且 3 个源码变异各自让指定的断言变红（活性已验证）。

## 0. 被测对象与环境

| 项 | 值 |
|---|---|
| 被测提交 | `1ac0e1c595dc84e684b540ca6a936168e922194f`（= `v5.5.0-rc.2^{commit}`，`run/env.txt` 里 `git rev-parse` 两次核对） |
| 树 | 该提交的**干净 git worktree** + **只加** `contracts/test/halmos/D5c1A3Negatives.t.sol`（sha256 `88eed3f8…15ee5a`）；子模块 solady `90db92ce`、chainlink `6e324d8a` 按 gitlink 检出。运行前后 `git status` 在 `contracts/`、`script/` 下只有这一个新文件（外加 Python 自动生成的 `script/halmos/__pycache__/`），`contracts/src` 零改动；所有日志的绑定行都是 `dirty_src 0`、`head 1ac0e1c595dc` |
| 工具 | halmos 0.3.3（z3 4.12.6、yices 2.6.4）；forge 1.7.1 `4072e487`；solc 0.8.33；Python 3.11.9；macOS arm64，10 核 |
| 参数 | 只用 `d5c1_binding.PROFILES` 的固定档（判定器逐条核对 `# meta:` 里的 argv）；每分区 600 s 墙钟上限；不重跑；`run-all-d5c1.sh all 4`（4 并发，比文档默认的 6 少，为了减少争用） |
| **主机负载** | 全程 load average **28–262**（10 核）：8 个孤儿 `yes > /dev/null` 进程（父进程 launchd，已运行 5 天，各占约 60–75% CPU，**不是本任务启动的，本任务没有动它们**）以及其他会话的 Halmos / forge 进程。见 `run/env.txt`、`aborted-run-1/env.txt` |

## 1. A-3 具名负对照（规范 03 §2.3 A-3、A-10 ①②）

文件：`contracts/test/halmos/D5c1A3Negatives.t.sol`（`D5c1A3NegativesTest`）。原始输出 `a3-negatives/a3-negatives.log`（同一 rc.2 干净树，exit 0）；在完整套件里也跑了一次（`forge-halmos-suite.log`，32/32 绿）。

| 测试 | 断言 | 结果 |
|---|---|---|
| `test_D5c1_A3_NEG1_initializeRejectsGenesisSpenderEqualToSP` | 地址 x **同时**是已批准 SP 和已批准 spender 实现；`initialize(superPaymaster = x, genesisSpender = x)` → **`InvalidAddress(x)`**（`xPNTsTokenV2.sol` `initialize`：`if (c.genesisSpender == c.superPaymaster) revert InvalidAddress(c.genesisSpender)`）；clone 未写入 SP / spender / historicalSP | PASS |
| `test_D5c1_A3_NEG1_control_distinctGenesisSpenderAccepted`（正对照） | 同样配置但 genesisSpender ≠ SP → 成功，spender 被加入、SP 不是 spender | PASS |
| `test_D5c1_A3_NEG2_genesisSpenderBecomingSPIsRemoved` | x 作为**创世 spender** 自动批准（未来的 SP）；用户给 x 设自动额度 + 无限显式 approve，轮换前 x 能拉走 1 枚（证明后面的拒绝是轮换造成的）；`proposeSP(x)` → 48 h → `activateSP()`：token **只**发出两条日志，顺序为 `AutoApprovedSpenderRemoved(x)`、`SuperPaymasterAddressUpdated(sp, x)`；之后 `autoApprovedSpenders(x) == false`、`historicalSP(x) == true`、`allowance(user, x) == 0`（尽管显式 approve 仍在存储里），`transferFrom`（经 spender 合约与直接调用）和 `burn(user, ·)` 都 revert `SPCannotTransfer`，用户余额与 totalSupply 不变；再把 SP 轮换到 y 之后（x 成为**历史** SP）以上全部仍成立；`proposeSpender(x)` revert `InvalidAddress(x)`；原创世 SP 仍被禁止 | PASS |
| `test_D5c1_A3_NEG2_activatedSpenderBecomingSPIsRemoved` | 同上，但 x 经 `proposeSpender` + 48 h + `activateSpender` 成为 spender | PASS |

**活性（变异，在同一干净树上原地改、`git checkout` 恢复并核对 sha256，`a3-negatives/M-*.log`，脚本 `scripts/cc125-a3mut.sh`）**：

| 变异 | 改动 | 变红的测试与断言 |
|---|---|---|
| M-A3G | 删掉 `initialize` 的 `genesisSpender == superPaymaster` 检查 | 只有 NEG1：`next call did not revert as expected`（正对照与 NEG2 仍绿） |
| M-A3R | `_setCurrentSP` 去掉"移出 spender + 事件" | 两个 NEG2：`SuperPaymasterAddressUpdated != expected AutoApprovedSpenderRemoved` |
| M-A3S | 只去掉 `autoApprovedSpenders[sp] = false`，事件保留 | 两个 NEG2：`removed from autoApprovedSpenders as current SP`（单独证明状态断言是活的，不是只靠事件断言） |

**观察（不是缺陷）**：M-A3R / M-A3S 下 `transferFrom` / `burn(from)` 的禁令**仍然成立**——因为 `_spendV2` 先检查 `historicalSP`，而 `_setCurrentSP` 总会写 `historicalSP[sp] = true`。即"移出 spender"是第二道防线，第一道是 historicalSP 门；测试同时断言两者。源码**确实执行**了 A-3 这两条，没有发现与规范不符之处。

## 2. 完整 D5c-1 套件（D5c-1-halmos.md §9）

命令（`scripts/cc125-full.sh`，每步原始 stdout 在 `run/<step>.stdout`，退出码与秒数在 `run/steps.tsv`）：

| 步 | 命令 | 退出码 | 秒 |
|---|---|---|---|
| 0 | `forge build --ast --extra-output storageLayout metadata`（§9 要求的预构建） | 0 | 1139 |
| 1 | `script/halmos/run-all-d5c1.sh all 4` | 1 | 16467 |
| 2 | 树的 rsync 副本里 `script/halmos/run-mutations-all.sh <干净树>/…/data/halmos/mutations` | 0 | 5039 |
| 3 | `script/halmos/run-fuzz-liveness.sh …/fuzz-liveness` | 0 | 1454 |
| 4 | `script/halmos/archive-d5c1.sh all` | 1 | 344 |
| 5 | `python3 script/halmos/verify-d5c1.py --markdown …/verify-final.md` | **1** | 8 |

判定输出：`verify-final.txt`（sha256 `04b7f6cf…eb05a1`）/ `verify-final.md`；强制套件 sha256 `d61dd46e…c2e0eb`（builtin，非 OVERRIDE）。

### 2.1 逐项统计（来自 `verify-final.txt`）

| 项 | 本次结果 | 判定 |
|---|---|---|
| CAP-1 `cap1.log` | 3/3 PASS（108/107/105 路径） | OK |
| CAP-1 witness | FAIL+cex（预期） | OK |
| R 基础情形 `rate-base.log` | `check_RATE_base_initialize` PASS（4 路径）、`check_RATE_base_realFactory` PASS（5 路径） | OK |
| R 归纳步 core | 14/15 PASS，**`burn-9dc29fac` TIMEOUT-WALL**（rc.2 原始：PASS，94 s） | **MISMATCH** |
| R 归纳步 ext | 44/44 PASS | OK |
| A-3 core（字面口径） | 14/15 PASS + `burn` DISCREPANCY-FAIL（预期，D-A3-2） | OK |
| A-3 ext | 43/44 PASS + `mint` BOUNDED（允许） | OK |
| A-3 NoSelfBurn / Bit0 / Bit1 / selfBurnDiscrepancy / MintNoDebt | PASS / PASS / PASS / FAIL+cex（预期）/ PASS | OK |
| A3x | BOUNDED `settleLocked`（允许） | OK |
| I2 core / ext | 11/15、42/44 PASS，其余 BOUNDED（都在允许上限内） | OK |
| I2 MintNoDebt | PASS | OK |
| I4-B base / core / ext / MintNoDebt | PASS / 11/15 + BOUNDED（允许）/ 43/44 + BOUNDED（允许）/ PASS | OK |
| I6 core | 13/15，**`burn`、`transferFrom` TIMEOUT-WALL**（原始：PASS 252 s、260 s） | **MISMATCH** |
| I6 ext | 43/44，**`transferFrom` TIMEOUT-WALL**（原始：PASS 250 s） | **MISMATCH** |
| I6-J core | 13/15，**`burn`、`transferFrom` TIMEOUT-WALL**（原始：PASS 271 s、285 s） | **MISMATCH** |
| I6-J ext | 43/44，**`transferFrom` TIMEOUT-WALL**（原始：PASS 254 s） | **MISMATCH** |
| I6 / I6-J MintNoDebt | PASS / PASS | OK |
| I2NoR 负对照 | **`tryLockForGas` TIMEOUT-WALL**，预期 FAIL+cex 没有出现（原始：FAIL+cex，178 s） | **MISMATCH** |
| 7 个 xPNTs witness | 全部 FAIL+cex（预期） | OK |
| 引理 M、M1–M3 | BOUNDED（允许，预期） | OK |
| 8 个 Halmos 变异 M-CAP1 / M-A3 / M-A3TF / M-A3BF / M-I2 / M-I4B / M-I6 / M-F1 | 全部在指名的 check / 分区上 FAIL+cex，独立性对照仍 PASS，场景测试变红，源码 sha256 恢复 | OK（47 行） |
| fuzz 替代活性 | 未变异 6 个 fuzz ≥ 10,000 次全绿；M-I2 / M-PULL / M-EXPL / M-BURNALL / M-REPAY / M-REPAYLOCK 全部按预期变红并恢复 | OK（35 行） |
| artifact parity | 两遍都 `RESULT: OK` | OK |
| forge halmos 套件 | 32/32 绿（含本次 4 个 A-3 负对照），11 个指名测试都在 | OK |
| 判定器自检 | 56/57，**P3_real_evidence 失败**——它对真实证据跑判定，失败原因就是上面同样的 6 处 TIMEOUT | **MISMATCH**（派生） |
| 文档引用的 CAP-1 数字 | 文档写的是 rc.2 当时的路径数 / 计时，新日志是 108/107/105 路径、8.33/9.22/14.46 s | **MISMATCH**（任何重跑都会出现；不是行为差异） |

### 2.2 为什么判定这 6 处是负载造成的，而不是代码问题

- rc.2 的被测源码与原始证据所用源码相同（判定器的绑定行：源码集合 / 字节码哈希与当前树一致），原始证据里这些分区在 94–285 s 内完成；本次同一分区、同一参数在 600 s 墙钟上限处被杀，**没有给出任何反例**（日志里没有结果行，只有 `# WALL-CAP: killed after 600 s`）。
- 同期负载 28–262。连 2 秒级的分区墙钟也到了 ~200 s（Halmos 每次自己的 `forge build --ast` 在高负载下变慢）。
- **但这只是解释，不是证据**：TIMEOUT 不等于 PASS，本次对这 6 个分区**什么也没证明**。

## 3. 文件与校验

- `halmos-raw.tar.gz`：本次运行在干净树 `docs/design/aoa-balance-mode/data/halmos/` 下改写或新建的**全部 583 个文件的原始字节**（未经 `trim-logs.py` 裁剪），路径相对于树根。**不要在仓库根目录解压**（会覆盖已提交的 rc.2 原始证据）：
  ```bash
  mkdir /tmp/x && tar -xzf halmos-raw.tar.gz -C /tmp/x && (cd /tmp/x && shasum -a 256 -c "$OLDPWD/RAW-SHA256.txt")   # 583/583 OK
  ```
- `RAW-SHA256.txt`：上述 583 个原始文件各自的 sha256（打包前计算）。
- `run/`：本次运行的 `env.txt`（工具版本、提交、子模块、负载、前后 git status）、`steps.tsv` / `steps.log`、每一步的原始 stdout。
- `aborted-run-1/`：第一次尝试。没有预构建，Halmos 自己的冷编译（467 s+）在高负载下吃掉了 600 s 墙钟，`rate-base` 与 `cap1` 都在编译阶段被杀；判断出原因后中止，按 §9 先做 AST 预构建再从头重跑（即 `run/`）。那次的 Halmos 日志随干净树复位被删除，只保留 stdout 与 env。它**不计入**任何结论。
- `a3-negatives/`：§1 的原始输出与 3 个变异日志。
- `verify-final.txt` / `.md`、`verify-selftest.log`、`forge-halmos-suite.log`：判定与存档项的原始输出（与 tar 内同名文件逐字节相同）。
- `scripts/`：本次使用的两个编排脚本。
- `EVIDENCE.sha256`：本目录所有文件（除自身）的 sha256；`cd` 到本目录后 `shasum -a 256 -c EVIDENCE.sha256`。

## 4. 缺口与建议

1. **D5c-1 在 rc.2 上的完整判定没有通过**（8 MISMATCH）。要拿到可用的"rc.2 全量 PASS"，需要在**空闲主机**上重跑（建议先结束那 8 个孤儿 `yes` 进程——需要机主确认，本任务没有动它们），或在负载可控的机器上跑；按规则不能只补跑这 6 个分区然后拼进来（"每个分区恰好一份日志"）。
2. CAP-1 的计时引用是文档对**某一次**运行的逐字引用，任何重跑都会让这一行不一致；若 DSR 接受重跑证据，需要决定是改判定规则（只比路径数）还是每次同步文档。
3. 本次只加了测试文件，`contracts/src` 未改，tag 未动，没有任何链上写操作。
