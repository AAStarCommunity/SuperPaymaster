# F1 调查：同一 sender 的第 k 笔在 bundle 内失败 → Rundler 封禁 paymaster

F1 的原始发现见 [B1-B10.md](B1-B10.md) §4。本文件是 DSR 要求的三项实验（只调查，**不改 SP / token 的 src**），加上对 Rundler
二次验证方式的源码核对。ERC-7562 条文的分析在主分支的 `docs/design/aoa-balance-mode/b-layer/F1-erc7562-text.md`（DSR 撰写，本文不改它，只引用）。

基线 `c33c28b9`；Rundler v0.11.0（`2a3db237`，主用，配置同 G1）；Alto v1.2.5（`45bbf341`，与 G1 的 `altoMulti` 同配置：
`--min-entity-stake 1e18 --min-entity-unstake-delay 86400 --enforce-unique-senders-per-bundle false`）；一条 anvil 1.7.1
`--hardfork osaka --chain-id 31337`，只在本机。**每组场景都用一个全新的 bundler 进程、从同一个 setup 之后的快照开始**（bundler 的信誉在内存里，
一组里的封禁不会影响下一组）。全部结果连跑三遍：第一遍有一组因启动竞态作废（Rundler 在代理起来之前启动、读到签名账户余额 0，已在脚本里修掉），
后两遍逐项一致，存档的是第三遍。

## 0. 结论

| 实验 | Rundler v0.11.0 | Alto v1.2.5 |
|---|---|---|
| **① 对照：eth-infinitism v0.7 `TokenPaymaster`**，同一 sender 3 笔、代币只够 2 笔 | **同样被封禁**：出块时联合检查 `FailedOpWithRevert(2, "AA33 reverted", ERC20InsufficientBalance(sender, 1.5e15, 3e15))` → 日志 `Rejected op … with a paymaster 0xe8d2… error AA33` → `Empty bundle with 3 rejected ops and 1 rejected entities` → `Removed entity from pool: paymaster`；信誉 `opsSeen 0x1→0x2710, status 2 (BANNED)`；随后新用户的 op `-32504 paymaster … throttled or banned`；三笔都没上链 | 第 3 笔提交时被拒 `-32500 AA33 reverted - 0xe450d38c…`，前两笔上链，paymaster 信誉正常 |
| **② 账户侧守卫**（`validateUserOp` 读 `token.lockedOf(this)` / `creditReservedOf(this)`，非零即拒） | **SP 不再被封禁**。签名失败模式：联合检查 `FailedOp(1, "AA24 signature error")`；revert 模式：`FailedOpWithRevert(1, "AA23 reverted", EscrowPending(345.6e18, 0))`。两种都只把**该笔 op** 移出（`Rejected op … with message AA24/AA23` → `Op rejected from bundle and removed from pool`），不处罚任何实体；SP `opsSeen 1 / included 1 / status 0`，随后新用户经 SP 的 op 正常上链。代价：第 1 笔上链，**第 2、3 笔都被丢**（第 2 笔本来放得下） | 第 2、3 笔提交时就被拒：`-32507 AA24 signature error` / `-32500 AA23 reverted - 0xb3c7b25f…`，第 1 笔上链 |
| **③ `--pool.same_sender_mempool_count 1`**（自托管 Rundler） | 第 1 笔上链；**第 2、3 笔提交时被拒** `-32505 Max operations (1) reached for account:"0x740B…" due to being unstaked`；SP 未封禁（`status 0`），随后正常 op 上链。对 TokenPaymaster 同样有效 | — |
| **§2.3 合规**（守卫账户帧的读） | 账户帧（未质押）对 token 只有 `lockedOf[u]`、`creditReservedOf[u]` 两次 SLOAD（STATICCALL，经 EIP-1167 DELEGATECALL），都以 sender 为键（STO-021），归入 §2.3 账户行；清单外 0、禁止项 0（Rundler 16 次、Alto 12 次模拟） | 同左 |

**要点**：F1 **不是 SP 特有的**。标准的 ERC-20 TokenPaymaster 在同样的条件下同样被 Rundler 封禁；SP 用 sigFail（AA34）还是改成 revert（AA33）
都一样，因为 Rundler 把 `AA30/AA31/AA33/AA34` 一律算作 paymaster 的责任。根源是 Rundler 做「二次验证」的方式（§1）：
带 tracer 的二次验证是**逐笔、各自对着同一个区块状态**做的，同一 sender 的几笔只在之后一次**不带 tracer 的 `handleOps` 联合调用**里才
依次执行；在那里失败就被当成「通过二次验证之后在组 bundle 时失败」，按 SREP-050 处罚已质押的 paymaster。
这与 DSR 在 `F1-erc7562-text.md` 中对 ERC-7562 的解读一致（Rationale L384「可以把同一账户的多笔放进一个 bundle，但必须先把它们放在一起验证」；
GREP-040 L248 只封禁「通过二次验证之后在组 bundle 时失败」的实体）——条文本身本文未重新核对，只提供 Rundler 一侧的事实。

## 1. Rundler v0.11.0 的二次验证是怎么做的（源码 + 日志）

出块路径 `make_bundle`（`crates/builder/src/bundle_proposer.rs`）：

| 步骤 | 位置 | 做什么 |
|---|---|---|
| (3) 模拟 | `bundle_proposer.rs:257-263`：`simulate_op` 对每笔 op 生成一个 future，`future::join_all(simulation_futures)` 并行执行 | **逐笔**二次验证 |
| `simulate_op` | `bundle_proposer.rs:538-558`：`simulator().simulate_validation(op, trusted, block_hash, …)` | 每笔都对着**同一个 `block_hash`**，带 ERC-7562 tracer；彼此看不到对方的写入 |
| (4) 联合检查 | `bundle_proposer.rs:963-1013` `estimate_gas_rejecting_failed_ops` → `entry_point().call_handle_ops(…, validation_only)`（`:990-1004`）；**只有 1 笔时跳过**（`:979-986`） | 整个候选 bundle 做一次 `handleOps` eth_call，**不带 tracer**、不查 ERC-7562 规则 |
| validation_only | `crates/provider/src/alloy/entry_point/v0_7.rs:282-312`：在末尾追加一笔 sender = EntryPoint 的哨兵 op（「Trigger an AA10 error」，`:295`） | EntryPoint 先依次验证所有 op（前面 op 的写入对后面可见），到哨兵处以 AA10 失败，从而不执行 |
| 失败归属 | `bundle_proposer.rs:1123-1180` `process_failed_op`：`AA13/14/15` → 工厂；**`AA30/AA31/AA33/AA34` → `reject_entity(paymaster, is_staked)`**（`:1151-1170`）；其余（含 AA23/AA24）→ `reject_index`，只移出该笔（`:1171-1176`） | |
| 处罚 | `bundle_proposer.rs:1563-1564` 已质押 → `StakedInvalidation`；`crates/pool/src/mempool/uo_pool.rs:865-866` → `handle_srep_050_penalty`；`reputation.rs:239-242` 把 `ops_seen` 直接设为 10,000（BANNED） | |
| 提交时（首次验证） | `uo_pool.rs:581-636`：取最新区块，`simulate_validation(op, …, block_hash)` 单笔验证 | 同样不看同 sender 的待处理 op |

**日志与原始证据**（`cases/f1/`）：
- 我们的代理记录到 Rundler 在 sp3 场景里的 6 次带 tracer 的验证模拟：每次都**只含 1 笔 op**，都在同一个 `blockHash 0x0b8ed9bf…`；
  前 3 次是提交时的首次验证，后 3 次在 65 ms 内先后发出（出块时并行的逐笔二次验证），8 ms 之后才是那次联合的 `handleOps` eth_call
  （`rundler-sp3-traces.jsonl.gz`，行内 `at` 时间戳）。
- 同一场景里 Rundler 的联合检查（代理记下的 `handleOps` eth_call，`joint-handleops.{json,txt}`）：
  `4 ops [sender:k0, sender:k1, sender:k2, EntryPoint:k0(哨兵)] → FailedOp(2, "AA34 signature error")`；TokenPaymaster：
  `→ FailedOpWithRevert(2, "AA33 reverted", …)`；守卫账户：`[k0,k1,k2,哨兵] → FailedOp(1, AA24)`，移出 k1 后重试
  `[k0,k2,哨兵] → FailedOp(1, AA24)`，再移出 k2，只剩 1 笔、跳过联合检查、上链。
- 事件日志：`rundler-sp3-events.log`、`rundler-tpm-events.log`、`rundler-gSig-events.log`、`rundler-gRev-events.log`。

所以回答 DSR 的问题：**Rundler 对同一 sender 的多笔 op 的二次验证是逐笔、各自对着同一个区块状态做的，不是联合的，也不是在同一 bundle
前面几笔的基础上依次做的。** 依次执行只发生在之后那次不带 tracer 的 `handleOps` 调用里，而那一步的失败走「组 bundle 失败」的归属与处罚。
Alto v1.2.5 相反：它在**提交时**就把同 sender（及同 paymaster）的待处理 op 排在前面一起模拟（`simulateValidationLast`），所以第 k 笔在
提交时被拒，不进入 bundle，也就不处罚 paymaster。

## 2. 实验 ①：TokenPaymaster 对照

- **合约**：未修改的 `singleton-paymaster/lib/account-abstraction-v7/contracts/samples/TokenPaymaster.sol`（sha256 `6a1bc069…`）。
  它依赖 `@uniswap/v3-periphery`，本仓库没有，也不能改 foundry.toml，所以由 `script/b-layer/f1-build-tpm.sh` 在临时 foundry 工程里编译
  （OZ 用仓库自带的 v5.0.2，uniswap 接口取本机已有的 `@uniswap/v3-periphery 1.4.4 / v3-core 1.0.1`），产物（abi + bytecode + 源码哈希）
  存为 `cases/f1/TokenPaymaster.json`。**用的是 TokenPaymaster 本身，不是替代品。**
- **最小配置**：代币 `F1TestToken`（普通 OZ ERC-20）；预言机 `F1Oracle`（1 代币 = 1 ETH，8 位小数，`tokenToNativeOracle = true`）；
  `priceMarkup = 1e26`（不加价），`refundPostopCost = 40,000`，`priceMaxAge = 10 天`，`minEntryPointBalance = 0`（不触发 swap）；
  wrappedNative / uniswap 填占位地址（只在 swap 时用到）。`updateCachedPrice(true)`，EntryPoint 押金 10 ETH，**质押 1 ETH / 86400 s**（与 SP 相同）。
- **op**：与 G1 相同的 gas 字段；`paymasterAndData = [TPM][300,000][250,000]`（无客户端报价）；每笔预扣
  `requiredPreFund + 40,000 × maxFee = 3.0e15` 代币；sender（MockAirAccount）余额 **7.5e15 = 2.5 笔**，事先 `approve` 给 TPM。
- **单笔对照**（tpm1）：两个 bundler 都接受并上链，说明 TokenPaymaster 本身工作正常、质押被认可。

| | Rundler | Alto |
|---|---|---|
| 提交 | 3 笔都被接受 | 第 1、2 笔接受；第 3 笔 `-32500 AA33 reverted - 0xe450d38c…`（即 `ERC20InsufficientBalance`） |
| 出块 | 联合检查 `FailedOpWithRevert(2, "AA33 reverted", ERC20InsufficientBalance(sender, 1,500,000,000,000,000, 3,000,000,000,000,000))`；`Rejected op because it failed during gas estimation with a paymaster 0xe8d2… error AA33 reverted:0xe450d38c…` → `Empty bundle with 3 rejected ops and 1 rejected entities. Removing them from pool.` → `Removed entity from pool. Entity: paymaster:"0xe8D2…"` | 前两笔上链 |
| 信誉 | TPM：`opsSeen 0x1 / included 0x1 / status 0` → **`0x2710 / 0x1 / status 2`**；sender：`0x3 / 0x0 / status 0` | TPM `0x3 / 0x3 / 0` |
| 之后新用户经该 paymaster 的 op | **`-32504 paymaster 0xe8d2… throttled or banned`** | 上链 |

**与 SP 的差别以及 SP 能不能照做**：
- 失败方式：TokenPaymaster 在验证期 `safeTransferFrom(sender → paymaster)`，余额不足时 **revert**（AA33）；SP 在验证期 `tryLockForGas`，
  余额不足时返回 **sigFail**（AA34）。都发生在出块时的联合检查（第 3 笔），首次验证和逐笔二次验证都能通过。
- 存储访问（`cases/f1/tpm-access.txt`，按 ERC-7562 关联判据「最终原像的第一个字 = 最后一个 mapping 键」）：
  读写 `_balances[sender]`（与 sender 关联）、`_balances[TPM]` 与 `_allowances[sender][TPM]`（与 TPM 自己关联，已质押才允许），
  TPM 自有槽（`tokenPaymasterConfig`、`cachedPrice` 等）；账户帧只读自己的 slot 0。与 SP 一样，都是「验证期消耗了 sender 的一份有限余额」。
- 结论：**被封禁与否与 revert / sigFail 无关**，改成 revert 不会有帮助。paymaster 能避免被封，只有两类办法：让验证结果不依赖同一 sender
  前面几笔的验证写入（例如验证期只检查、不扣减，把扣款放到 postOp——代价是余额不足时由 paymaster 垫付 gas，与 SP 的 I9「无后盾赞助 = 0」直接冲突），
  或者让失败在账户一侧发生（实验 ②）、或者在 bundler 一侧不让同 sender 多笔同处一个 bundle（实验 ③）。

## 3. 实验 ②：账户侧守卫

**夹具**：`contracts/test/bundler/F1Fixtures.sol` 的 `MockAirAccountGuarded`（新文件，SP / token 的 src 未动）：`validateUserOp` 先
STATICCALL `token.lockedOf(address(this))` 和 `token.creditReservedOf(address(this))`，任一非零时：mode 1 返回
`SIG_VALIDATION_FAILED`（EntryPoint 报 **AA24**），mode 2 `revert EscrowPending(locked, reserved)`（EntryPoint 报 **AA23**）；否则照常验签。
账户余额 2.5·a0 = 864 xPNTs（与 B2b 相同，**第 2 笔本来放得下**），同一 sender 3 笔、经 SP。

| | Rundler | Alto |
|---|---|---|
| 提交（首次验证） | 3 笔都被接受：此时链上 `lockedOf == 0`，守卫不触发 | 第 1 笔接受；第 2、3 笔**提交时被拒**：mode 1 `-32507 AA24 signature error`，mode 2 `-32500 AA23 reverted - 0xb3c7b25f…`（Alto 把第 1 笔排在前面一起模拟，守卫看到了锁） |
| 出块时的逐笔二次验证 | 仍然各自看到 `lockedOf == 0`，守卫不触发（trace 里账户帧读到的就是这两个槽） | — |
| 出块时的联合检查 | **守卫在这里触发**：`[k0,k1,k2,哨兵]` → `FailedOp(1, "AA24 signature error")` / `FailedOpWithRevert(1, "AA23 reverted", EscrowPending(345,600,000,000,000,000,000, 0))`；日志 `Rejected op because it failed during gas estimation with message AA24 signature error.` → `Op rejected from bundle and removed from pool`；重试 `[k0,k2,哨兵]` 同样在索引 1 失败，再移出；最后只剩 k0，单笔跳过联合检查，上链（`Num rejected ops: 2. Num updated entities: 1`） | — |
| 归属 | `process_failed_op` 的默认分支（`bundle_proposer.rs:1171-1176`）：只移出该笔 op（`reject_index`），**不处罚任何实体**；唯一的实体更新是 EREP-015 对 paymaster 的 `opsSeen` 回减（`Num updated entities: 1`） | 提交时拒绝，不涉及信誉 |
| 信誉（之后） | SP `0x1 / 0x1 / status 0`（**未封禁**）；sender `opsSeen 0x3 / included 0x1 / status 0`（这一次还没到限流） | SP、sender 都正常 |
| 之后新用户经 SP 的 op | 上链 | 上链 |

两种模式在 Rundler 上的处理完全相同（AA23 与 AA24 都不在 paymaster / 工厂的名单里）。严格说，Rundler 并没有「处罚账户」，而是只丢弃这笔 op；
被计入的只是该 sender 的 `opsSeen`（反复被丢，最终会按比例被限流），SP 不受影响。

**守卫在哪一步起作用**：在 Rundler 上只在「出块时的联合 `handleOps` 调用」里起作用——提交时和出块时的逐笔二次验证都各自看到链上的
`lockedOf == 0`（B2b 里第 2 笔的首次验证同样看到 0）。守卫把「第 k 笔 paymaster 失败（AA34，封 SP）」变成「第 k 笔账户失败（AA24/AA23，只丢这笔）」。
代价：同一 sender 每个 bundle 只能有**一笔**经 SP 的 op——第 2 笔即使余额够也被丢，诚实用户要等上一笔上链后重发。

**合规**（`cases/f1/access-check-guard.{json,txt}`，用 G1 的 `access-check.mjs` 按 §2.3 归类）：账户帧（未质押）对 token 的访问只有
`lockedOf[u]`、`creditReservedOf[u]` 两次 SLOAD，二者都在 §2.3「账户（未质押）」一行的变量里，且以 sender 为最内层键（STO-021）；
没有全局槽，没有禁用 opcode。Rundler 16 次、Alto 12 次模拟：清单外 0，禁止项 0。

**局限**：守卫只对**实现了它的账户**（AirAccount 方案 A 的扩展）有效。任何不带守卫的账户（其他钱包、恶意用户自建的账户）都仍然可以用
B2b 的方式在 Rundler 上让 SP 被封；所以守卫只能减少诚实用户的误触发，不能防攻击。

## 4. 实验 ③：`--pool.same_sender_mempool_count 1`

自托管 Rundler 加这个参数后（其余配置不变），B2b 同样的三笔：

- 第 1 笔：`0x63f6ea0f…` 接受并上链；
- 第 2、3 笔：**提交时**返回 `{"code":-32505,"message":"Max operations (1) reached for account:\"0x740Be5d5c1d56ff61a7839A212947e36Fe2d5722\" due to being unstaked"}`
  （`uo_pool.rs:703-718`）。与 DSR 预期的「第 3 笔被拒」不同，**被拒的是第 2 笔起**：内存池里同一 sender 只能有 1 笔；
- SP 信誉 `opsSeen 0x1 / included 0x1 / status 0`，**未封禁**；随后新用户经 SP 的 op 上链。
- TokenPaymaster 同样：第 2、3 笔 `-32505`，TPM 未封禁。

限制：只对**未质押**账户生效（`uo_pool.rs:711` `!pool_op.account_is_staked`）；只保护配置了它的节点（第三方 Rundler 默认是 4）；
同一 sender 只能串行发送（上一笔上链后下一笔才能进池）。已写入 [README.md](README.md) §5，作为论文实验的自托管配置。

## 5. 对作者决策的含义（仅供参考）

1. F1 是 Rundler 对「验证期消耗 sender 余额的 paymaster」的通用行为，标准 TokenPaymaster 同样被封；SP 的实现本身没有 ERC-7562 违规。
2. 按 DSR 引用的 ERC-7562 条文，出问题的是 Rundler 没有把同一 sender 的多笔一起做二次验证；Alto 在提交时就一起模拟，所以不封。
   这可以作为向 Rundler 上游报告的依据（是否提交由作者决定，那是外部仓库）。
3. 可用的缓解：自托管节点用 `same_sender_mempool_count = 1`（③，对自有节点完全有效）；AirAccount 加守卫（②，让诚实用户的误触发只丢 op、
   不封 SP，但挡不住不带守卫的账户）；合约层要根治只能放弃「验证期扣减」，与 I9 冲突。第三方 Rundler 节点上的风险仍在。

## 6. 文件

| 路径 | 内容 |
|---|---|
| `contracts/test/bundler/F1Fixtures.sol` | `MockAirAccountGuarded`（守卫账户，mode 1 / 2）、`F1TestToken`、`F1Oracle` |
| `script/b-layer/f1-build-tpm.sh` | 在临时工程里编译未修改的 TokenPaymaster，写出 `cases/f1/TokenPaymaster.json` |
| `script/b-layer/f1-setup.mjs`、`f1-cases.mjs`、`f1-run.sh`、`f1-collect.sh` | setup、场景（tpm1/tpm3/gSig/gRev/sp3）、一键运行（每组全新 bundler + 同一快照）、收集 |
| `script/b-layer/f1-joint.mjs`、`f1-analyze.mjs` | 解出 bundler 的联合 `handleOps` 调用；TokenPaymaster 的存储访问 |
| `script/b-layer/g1-proxy.mjs`（扩展） | 另外记录 `handleOps` 的 eth_call / eth_estimateGas 及原始应答 |
| `cases/f1/` | `setup.json`、`*-results.json`（bundler 原始响应、信誉读回、联合检查结果）、`*-traces.jsonl.gz`、`rundler*-events.log`、`alto-*-errors.log`、`joint-handleops.*`、`access-check-guard.*`、`tpm-access.*`、`TokenPaymaster.json` |

复现：`script/b-layer/f1-build-tpm.sh <tmp> <@uniswap node_modules>`，然后 `script/b-layer/f1-run.sh <workDir> <rundler 目录> <alto125 目录>`，
再 `script/b-layer/f1-collect.sh <workDir>`。
