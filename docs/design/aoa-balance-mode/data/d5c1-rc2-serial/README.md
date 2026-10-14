# D5c-1 在 v5.5.0-rc.2 上的完整串行重跑（新一代证据，CC-125 b18bb719 / 62fbcac1）

> **结论先行**：
> - **BEHAVIOUR（行为判定）通过**：除 archives 以外的全部 260 行，用合并后的新版判定器（#470，`origin/feat@94e940c5`）判为 `ALL SELECTED EXPECTATIONS MET`，exit 0（`verify-new-behaviour.txt`）。archives 的 4 行用本代自带判定器（rc.2 树里的 `verify-d5c1.py`）判，其中 3 行 OK（自检 57/57、forge halmos 套件 32/32、artifact parity）。
> - 本代自带判定器给出 `VERDICT: 1 MISMATCH(ES) (264 rows)`。唯一不一致的一行是「`cap1.log` 的路径数和计时须与**历史** `D5c-1-halmos.md` 的原文一致」。按 DSR b18bb719 的口径，这是**文档同步**问题，不是行为断言：历史文档的计时保留不改，本代数字由本 README 承担（见 §2）。
> - **本代没有任何意外 TIMEOUT**。本次运行写出的日志里共有 9 处 `# WALL-CAP`（树里另有 6 个早已提交的 `superseded/under-load/` 文件，不属于本代）：
>   - 8 处落在规范预先登记为 `BOUNDED (allowed)` 的非线性分区上（mulDiv / 引理 M），每处都有 10,000 次 fuzz 替代证据，判定器逐行判为 OK；
>   - 1 处是 `XPNTsV2I4BHalmosTest.check_I4B_coreAbi:transferFrom`：halmos 在 **588.1 s** 打出 `[PASS]`，随后在退出清理阶段被 600 s 上限杀掉。判定器按「结果在上限内」判为 OK。**余量只有 12 s**，负载更高的机器上可能变成 TIMEOUT，复跑时请注意。
> - #465 那次出现的 6 个「要求 PASS 却 TIMEOUT」分区，本次都在上限内得到终局：R 归纳步 core 15/15 PASS、I6 core 15/15、I6 ext 44/44、I6-J core 15/15、I6-J ext 44/44 都是 PASS；I2NoR 负对照按预期在 `tryLockForGas` 上给出 FAIL+cex。
> - 这**不是**链上证据，也**不是**独立审计；结论只覆盖 rc.2 源码在本机有界符号执行下的情况。

## 0. 被测对象与环境

| 项 | 值 |
|---|---|
| 被测提交 | `1ac0e1c595dc84e684b540ca6a936168e922194f`（= `v5.5.0-rc.2^{commit}`），干净 detached worktree，只加了 `contracts/test/halmos/D5c1A3Negatives.t.sol`（sha256 `88eed3f8…15ee5a`）；`contracts/` 下没有其他改动 |
| 子模块 | solady `90db92ce`、chainlink `6e324d8a`，以及 4 个 standards，均按 rc.2 的 gitlink 拷贝 |
| 工具 | halmos 0.3.3、forge 1.7.1 `4072e487`、solc 0.8.33（详见 `run/env.txt`；主机名已脱敏） |
| 参数 | `run-all-d5c1.sh all 1`：**单路串行**。每个分区 600 s 墙钟上限，argv 取自 `d5c1_binding.PROFILES` 的固定档，每个分区只出一份日志 |
| 负载 | `run/load.log` 每 60 s 记录一次；1 分钟 load 中位数约 12（10 核），开头一段受上一次中止残留的影响较高（见 §3） |

## 1. 步骤与退出码（`run/steps.tsv`）

| 步 | 命令 | 退出码 | 秒 |
|---|---|---|---|
| 0 | `forge build --ast --extra-output storageLayout metadata` | 0 | 2（缓存命中） |
| 1 | `script/halmos/run-all-d5c1.sh all 1` | 0 | 17080 |
| 2 | 在树的副本里跑 `script/halmos/run-mutations-all.sh` | 0 | 3396 |
| 3 | `script/halmos/run-fuzz-liveness.sh` | 0 | 1074 |
| 4 | `script/halmos/archive-d5c1.sh all` | 0 | 176 |
| 5 | 本代判定器 `verify-d5c1.py --markdown …` | 1（仅历史文档计时那一行） | 5 |
| 5' | 新版判定器 `--only suite,logs,partitioned,mutations,fuzz` | **0** | — |

## 2. 本代数字（DOCUMENT-SYNC 以此为准，不改历史文档）

逐字引自本代 `cap1.log` 与 `verify-selftest.log`：

D5C1 CAP-1 (a): PASS, paths=108, time=2.41s
D5C1 CAP-1 (b): PASS, paths=106, time=1.36s
D5C1 CAP-1 (c): PASS, paths=107, time=1.32s
D5C1 self-test controls: 57

## 3. 中止的一次（`aborted-run-2/`，不计入任何结论）

同一棵树先用 `run-all all 4` 跑过一次。没有任何外部负载，但这次运行自身的 4 个 halmos 进程组各开多个 yices，把负载推到 150–500，≥10 个分区触发 600 s 上限，于是中止。中止时只终止了本次运行自己的进程组。该目录保存部分产物、负载记录和中止原因。由此推断，#465 归档里的 8 个 MISMATCH 主要也是 4 路并发自身造成的，详见 CC-125 905d370a 的更正。那份归档本身仍保持 INCONCLUSIVE，不改。

## 4. 文件

- `halmos-raw.tar.gz`：本次运行在干净树 `docs/design/aoa-balance-mode/data/halmos/` 下新建或改写的 **全部 581 个文件** 的原始字节，路径相对树根。**不要在仓库根目录解压**，会覆盖已提交的 rc.2 原始证据：
  ```bash
  mkdir /tmp/x && tar -xzf halmos-raw.tar.gz -C /tmp/x && (cd /tmp/x && shasum -a 256 -c "$OLDPWD/RAW-SHA256.txt")
  ```
- `RAW-SHA256.txt`：上述 581 个文件逐个的 sha256。
- `run/`：`env.txt`（主机名已替换为 `<host>`）、`steps.tsv` / `steps.log`、每一步的原始 stdout、`load.log`。
- `verify-generation.txt` / `.md`：本代自带判定器的原始输出。`verify-new-behaviour.txt`：新版判定器的行为判定。
- `scripts/`：本次使用的编排脚本，草稿目录路径已替换为 `$SCRATCH`。
- `EVIDENCE.sha256`：覆盖本目录所有文件（不含它自身）。

## 5. 复核方式

```bash
# 1) 完整性
cd docs/design/aoa-balance-mode/data/d5c1-rc2-serial && shasum -a 256 -c EVIDENCE.sha256
# 2) 行为判定：在 rc.2 干净树 + 解出的 halmos 数据上，用 feat 上的新版判定器
python3 <feat>/script/halmos/verify-d5c1.py --tree . --only suite,logs,partitioned,mutations,fuzz
# 3) 文档同步：--report 指向本 README
```

文档同步的实测结果见 `verify-new-docsync.txt`（`--only archives --report README.md`）：`DOCUMENT-SYNC VERDICT: ALL QUOTES MATCH (4 rows)`，CAP-1 a/b/c 的路径数和计时、自检条数 57，都与本代日志逐字一致。同一次运行中，archives 的行为行 `verify-selftest.log` 判为 MISMATCH（`tested scripts differ from currently executing`）。这是 #470 的设计：自检日志必须与正在执行的判定器脚本一致，而本代自检是用 rc.2 树自带的判定器生成的。因此 archives 这一项以本代自带判定器的结论为准（`verify-generation.txt`：自检 57/57、套件 32/32、parity 均为 OK）。

不变：A2/A2a 由 DSR 判定；A3a 仍为 NO-GO，没有写链。
