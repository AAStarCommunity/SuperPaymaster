# D1 交付：xPNTs v2 模板 + v2 工厂 + GlobalTierSource

> 分支 `feat/aoa-balance-mode-5.5.0`。规范：[03-final-spec.md](03-final-spec.md) v3.7-rc（Codex 第 10 轮的修订并入 v3.8，见文末）。
> 本表列的是 D1 自带的基础单测；完整的测试矩阵（I 不变量、A 对抗、M 变异、D 一致性、G gas）属于 D3。
> **"D3"表示这条规则已经实现，但要到 D3 才有专门的测试。**

## 1. 文件与体积（`[profile.default]`，实测）

| 文件 | 作用 | runtime | 余量 |
|---|---|---|---|
| `contracts/src/tokens/v2/xPNTsV2Base.sol` | 共享存储、常量、事件、错误、内部逻辑（抽象） | — | — |
| `contracts/src/tokens/v2/xPNTsTokenV2.sol` | **核心**：ERC20，以及全部验证期和结算期入口 | **19,509 B** | 5,067 B |
| `contracts/src/tokens/v2/xPNTsTokenV2Ext.sol` | **扩展**：管理、用户设置、签名动作、SP 状态机、CC-28 视图，经核心的 fallback 以 DELEGATECALL 调用 | **21,922 B** | 2,654 B |
| `contracts/src/tokens/v2/xPNTsFactoryV2.sol` | v2 工厂（initcode 8,003 B） | 6,899 B | 17,677 B |
| `contracts/src/tokens/v2/AOAProtocolRegistry.sol` | SP / spender / 分档源三类白名单 | 2,554 B | 22,022 B |
| `contracts/src/tokens/v2/GlobalTierSource.sol` | 5.5.0 唯一的分档源 | 542 B | 24,034 B |
| `contracts/src/tokens/v2/IxPNTsTokenV2.sol`、`ICreditTierSource.sol` | 接口 | — | — |
| `scripts/check-xpnts-v2-layout.py` | 核心与扩展的存储布局一致性检查（带 `--self-test` 正对照） | — | — |

**实现期发现（要写进 03 v3.8）**：

1. **单体 token 实测 30,388 B，超出 EIP-170 5,812 B。** 03 §5 估算的"15.3 KB + 5–7 KB"严重偏低。所以拆成核心和扩展两个合约，两者走同一条继承链
   （`Initializable, ERC20, ERC20Permit, xPNTsV2Base`），存储布局由构造保证一致；
   `scripts/check-xpnts-v2-layout.py` 在编译产物上复核：57 项逐一相同，self-test 证明错开一个槽会被发现。
   **验证期入口（`tryLockForGas`、`tryReserveCredit`、`renewForSelf`）全部在核心合约里，不经过 DELEGATECALL**，03 §2.3 的 ERC-7562 分析不变。
2. **工厂不再在构造函数里 `new` 模板**：如果照 3.x 那样做，initcode 要装下核心和扩展两份创建码，会超过 EIP-3860 的 49,152 B。
   所以模板单独部署，地址传给工厂。部署顺序：`AOAProtocolRegistry` → 批准 SP、分档源和 spender → `seal()` →
   `xPNTsTokenV2Ext` → `xPNTsTokenV2`（参数为 registry 和 ext）→ `GlobalTierSource` → `xPNTsFactoryV2`（参数为 SP、Registry、impl、分档源）。
3. **`AOAProtocolRegistry` 有部署期的 bootstrap**：`seal()` 之前 owner 可以即时批准；`seal()` 之后，新增批准要走 48 h，撤销即时生效。
   runbook 第 4 步要写明"部署 → bootstrap → seal"。
4. **CC-28 的 `backingValueUSD` 改读 `community`**：3.x 读的是可以被转让的 `communityOwner`（`xPNTsToken.sol:843`）。

## 2. 规则 → 代码 → 测试

测试文件：`contracts/test/v2/xPNTsTokenV2.t.sol`（35 个测试，Cancun 和 Prague 都全部通过）。

| 规则 | 代码 | 测试 |
|---|---|---|
| A-1 锁定余额不能转出（含 burn） | Base `_update` :229 | `test_A1_locked_balance_cannot_move` |
| A-2 显式 approve 优先，自动额度兜底；防火墙 | Core `_spendV2` :143 | `test_other_spender_default_zero_and_user_opt_in` |
| A-3 SP（当前的和历史的）不能 transferFrom 或 burn(from)，显式 approve 也不行 | Core `_spendV2` :144，`allowance` :114 | `test_A3_sp_cannot_pull_even_with_explicit_approve` |
| A-4 退款记到原 locker 的格子 | Base `_refund` :287；Core `settleLocked` :228 | `test_lock_settle_happy_path` |
| A-5 SP 转述续期：K=1，只在 `SP_K` 模式下，先在内存里算、成功才写入 | Core `tryLockForGas` :187 | `test_sp_renew_K1`、`test_account_only_mode_blocks_sp_renew`、`test_renew_insufficient_after_commit_writes_nothing` |
| A-6 `renewForSelf` / R2：有未结算项时禁止 | Base `_renew` :297；Core `renewForSelf` :334 | `test_renewForSelf_resets_and_is_blocked_by_outstanding_lock`、`test_executeBySig_renew_by_relayer` |
| A-7 同一 bundle 里续期的顺序 | 由 A-6 的"有未结算项时禁止"推出 | D3 |
| A-8 SP 下限 250，上限 50,000 | Ext `_setAllowance` :109、`_setTotal` :119 | `test_A8_floor_and_ceiling` |
| A-9 工厂不是 spender | Core `initialize` :72（不写名单） | `test_A9_factory_cannot_pull`、`test_version_and_genesis` |
| A-10 创世 SP 不进名单；创世 spender 默认额度 0；`propagate` 只能提议 | Core `initialize` :72；Factory `deployxPNTsToken` :244、`propagateSuperPaymaster` :406 | `test_version_and_genesis`；propagate 留到 D3 |
| B-6 超过单笔上限直接拒绝，不截顶 | Core `tryLockForGas` | `test_lock_results_typed_and_write_free_on_failure` |
| B-7 饱和加法；spender 重新加入不清零 | Core `allowance`；Ext `activateSpender` :340 | `test_B7_saturating_allowance_with_explicit_max`、`test_B7_readd_spender_keeps_counters` |
| B-5 SP 只按地址登记，不走 codehash | Registry `isApprovedSP` :97、`isApprovedImpl` :102 | `test_registry_resolves_minimal_proxy_to_impl` |
| §9 EIP-1167 最小代理按实现合约判定 | Registry `implCodehash` :110 | `test_registry_resolves_minimal_proxy_to_impl` |
| C3-1 删除 `burnFromWithOpHash` / `recordDebt*` | 模板里没有这些函数 | `test_deleted_selectors_do_not_exist` |
| E-1 停用后 SP 的新锁、续期、预留全部拒绝 | Core `tryLockForGas` / `tryReserveCredit` | `test_lock_results_typed_and_write_free_on_failure`（锁）；预留留到 D3 |
| E-2 急停期间已有的锁照常结算 | Core `settleLocked`（不检查急停） | `test_emergency_blocks_new_locks_but_settles_existing` |
| E-3、E-4 恢复与 `releaseAndDisable` | Ext :73 | D3 |
| L-1 失败路径不写状态（类型化结果） | Core `tryLockForGas` / `tryReserveCredit` | `test_lock_results_typed_and_write_free_on_failure` |
| L-2、L-3 活标记；只有 locker、只在原交易内能结算 | Base `_setLive`/`_isLive` :334/:340；Core `settleLocked` | `test_L3_settle_only_within_original_tx_and_L4_release`（isolate）、`test_old_locker_settles_only_in_original_tx_after_rotation` |
| L-4 交易结束后可以 release，同一交易内不行 | Base `_releaseLock` :308 | `test_L3_…`（isolate，正向）、`test_L4_release_refused_while_live`（同一交易，反向）。**这两条互为对照**：前者证明 isolate 确实清空了标记，后者证明同一交易内标记确实存在 |
| L-5 `historicalSP` | Core `initialize`；Ext `_setCurrentSP` :318 | `test_S1_S3_rotation_after_timelock` |
| D-12 结算按锁定时的比例 | Core `settleLocked` | `test_settle_rate_uses_lock_time_ratio` |
| C-0 唯一的额度计算：min(申请, 上限, 分档)，MANUAL 再加批准额 | Core `effectiveCreditCap` :301 | `test_credit_auto_requires_current_epoch_request`、`test_manual_approval_is_a_ceiling` |
| C-1 预留时检查 `debts + reserved + a ≤ cap`（修掉 N-C1） | Core `tryReserveCredit` :256 | `test_credit_reserve_settle_and_cap` |
| C-2 结算只消费本笔预留 | Core `settleCredit` :277 | `test_credit_reserve_settle_and_cap` |
| C-3 切换策略后 epoch +1，旧申请作废；不允许切换成当前值 | Ext `executeCreditPolicy` :169、`queueCreditPolicy` :161 | `test_credit_auto_requires_current_epoch_request`、`test_policy_noop_switch_rejected` |
| C-4 撤销只影响新预留 | Core `settleCredit`（不重新读取） | D3 |
| C-5 切换分档源要 queue/execute，同样让 epoch +1 | Ext `queueTierSource` :184、`executeTierSource` :192 | D3 |
| §9 `tierOf` 用 STATICCALL 并限 gas；失败或返回格式不对按 0 处理 | Core `_tierOf` :317 | D3（要构造一个会 revert 和一个返回格式不对的分档源） |
| 信用默认关闭 | Base `creditPolicy` 初值 0 | `test_credit_off_by_default` |
| S-0 创世 SP | Core `initialize` | `test_version_and_genesis` |
| S-1、S-3 提议后 48 h 才能激活 | Ext `proposeSP` :223、`activateSP` :257 | `test_S1_S3_rotation_after_timelock` |
| S-1、S-4 社区的提议优先；急停取消工厂的提议，并禁止工厂在急停期间提议 | Ext `proposeSP`、`emergencyRevokePaymaster` :268 | `test_factory_proposal_cannot_override_community_and_is_cancelled_by_emergency` |
| S-5、S-6、S-7 备用 SP；恢复后才能解除急停 | Ext :280、:289、:301、:311 | `test_S6_S7_standby_recovery` |
| S-2 取消；S-3 急停期间激活社区发起的提议 | Ext `cancelSP` :245、`activateSP` | D3 |
| X4 spender 提议后 48 h 才能激活，移除即时生效 | Ext :330、:340、:352 | `test_other_spender_default_zero_and_user_opt_in`、`test_B7_readd_spender_keeps_counters` |
| X5 spender 与分档源按 codehash 白名单 | Ext `proposeSpender` / `activateSpender`；Core `initialize` | 正向用例已覆盖（`DummySpender`）；拒绝用例留到 D3 |
| X7、R-12 用户申请时写明上限 | Ext `_requestCredit` :142 | `test_credit_*` |
| R2 签名动作（ECDSA；1271 通过 SignatureChecker） | Ext `executeBySig` :81 | `test_executeBySig_renew_by_relayer`（含重放）；1271 留到 D3 |

## 3. 复现

```bash
git switch feat/aoa-balance-mode-5.5.0
forge test --match-path contracts/test/v2/xPNTsTokenV2.t.sol      # 35 passed
forge test --match-path contracts/test/v2/xPNTsTokenV2.t.sol --evm-version prague
python3 scripts/check-xpnts-v2-layout.py --self-test               # layout identical + control
python3 scripts/check-xpnts-v2-selectors.py --self-test            # selector routing + control
forge test                                                           # full suite: 1421 passed / 0 failed / 49 skipped (before this addition)
forge build && python3 - <<'EOF'
import json
for c in ['xPNTsTokenV2','xPNTsTokenV2Ext','xPNTsFactoryV2','AOAProtocolRegistry','GlobalTierSource']:
    d=json.load(open(f'out/{c}.sol/{c}.json')); print(c, len(d['deployedBytecode']['object'])//2-1)
EOF
```

## 4. DSR 对拆分提出的 5 点验收

| # | 要求 | 证据 |
|---|---|---|
| a | 直接调用扩展合约不影响任何克隆，也拿不到权限；扩展的 initializer 锁死；扩展里凡是读 SP 地址的判断都读扩展自己的空存储，不会因此被绕过 | 扩展的构造函数调用了 `_disableInitializers()`，而且扩展**根本没有** `initialize` 函数（它在核心里）。测试 `test_extension_direct_calls_are_inert`：直接调扩展的 `initialize` 失败；`mint`、`proposeSP`、`emergencyRevokePaymaster` 都以 `Unauthorized` revert（扩展存储里的 owner、factory、SP 全为 0，而 `proposeSP` 的工厂分支还要求 `FACTORY != 0`）；用户直接调扩展的 `setAutoAllowance` 只写扩展自己的存储，克隆里的额度不变。**SP 的特权入口全部在核心里，扩展没有任何 `msg.sender == SP` 判断**。另有 `test_core_template_is_inert`：核心模板从未初始化，SP 地址为 0，调 `tryLockForGas` 被拒 |
| b | 两边的 selector 不冲突 | `scripts/check-xpnts-v2-selectors.py --self-test`：基类的 69 个 selector 核心全有（fallback 不会把基类函数送进扩展）；只属于扩展的 59 个 selector 与核心的交集为空。两边都有的 selector 都来自共同的基类，经克隆调用时总是由核心回答。self-test 把一个只属于扩展的 selector 注入核心，确认会被报出来 |
| c | 扩展地址不可改 | `EXTENSION` 是核心模板的 `immutable`（`xPNTsTokenV2.sol:26`），克隆通过 DELEGATECALL 共享模板代码，所以共享同一个值；没有任何 setter。测试断言 `t.EXTENSION() == ext` |
| d | `renewForSelf` 在核心里 | 在核心里（`xPNTsTokenV2.sol:334`），账户帧不经过 DELEGATECALL；它只访问与 `msg.sender` 关联的槽（`_renew`，Base :297）。B 层仍要单独测它的 trace（D3） |
| e | bootstrap 与 seal 写进 runbook 和信任矩阵 | **runbook 第 4 步**：部署 `AOAProtocolRegistry` → bootstrap 批准（SP、分档源、spender）→ **`seal()`，并读回 `sealed_() == true`**，之后才能部署工厂、才能有任何社区发币。**信任矩阵**：`seal()` 之前，owner 可以即时加入任何 SP、spender 或分档源（这是部署窗口内的完全信任）；`seal()` 之后，新增要走 48 h 公示，撤销即时生效；`seal()` 不可逆。已同步写进 03 §11.2 第 3 条 |

## 5. 给 D2 的接口约定

- SP 只通过 `IxPNTsTokenV2`（`contracts/src/tokens/v2/IxPNTsTokenV2.sol`）调用 v2 token：`tryLockForGas`、`settleLocked`、`tryReserveCredit`、`settleCredit`，
  外加只读的 `BALANCE_MODE_VERSION`、`exchangeRate`、`maxSingleTxLimit`、`debts`、`creditReservedOf`、`effectiveCreditCap`。
  这些全部在核心合约里（D2 调用时不经过 fallback）。
- 用户和钱包使用的接口有一半在扩展合约里，**SDK 需要把核心和扩展两份 ABI 合并**，因为调用都发往同一个地址。
