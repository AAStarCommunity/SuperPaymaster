# D2 交付：SuperPaymaster 5.5.0 + 旧测试迁移

> 分支 `feat/aoa-balance-mode-5.5.0`。规范：[03-final-spec.md](03-final-spec.md) v3.8-rc（§1、§3、§10.1、§11）。
> 提交：`e09db389`（合约）→ `b784ed20`（DSR 预审要求补的测试）→ `ffa027ff`、`6bca064d`、`fb06bd9e`、`da11016b`（4 组旧测试迁移）→ 最终 commit（见文末）。

## 1. 合约改动

| 项 | 内容 | 位置 |
|---|---|---|
| validate | paymasterAndData 带 token 字段，并校验它等于 operator 配置的代币（R4-H1）；两个续期位同时置 1 → sigFail；按完整 maxCost 计算 a0；**先查 operator 余额**，再调 `tryLockForGas`；只有返回 INSUFFICIENT 才尝试 `tryReserveCredit`（R-2）；所有 token 调用都包 try/catch，失败 → sigFail（H3-1） | `SuperPaymaster.sol` `validatePaymasterUserOp`、`_reserveForOp` |
| 在途预留（R10-M1b） | a0 从 operator 扣除，写入 `_inflight[opHash]` 并打 transient 标记，**不计入 protocolRevenue**；postOp 时 revenue += charge、operator += a0 − charge，没有截断；`releaseStaleSponsorship(opHash)` 任何人都能调、幂等，同一交易内会被拒绝 | `postOp`、`releaseStaleSponsorship`、`inflightOf` |
| postOp | 入口检查 `gasleft() ≥ SETTLE_GAS_BOUND`（80k）；按**验证时的价格快照**计费（R10-M3）；**结算不包 try/catch**（B-1） | `postOp` |
| configureOperator | 探测 `BALANCE_MODE_VERSION() == 1`，旧代币被拒 | `configureOperator` |
| 删除 | `_creditExceeded`、`_recordDebt`、`retryPendingDebt`、`clearPendingDebt`、`dryRunValidation`；`pendingDebts` 保留为 internal 占位槽 | — |
| `getAvailableCredit` | `max(0, token.effectiveCreditCap − debts − reserved)` | — |
| F1 | `SuperPaymasterLens.dryRunValidation(sp, op, maxCost)`：用户侧判定直接调 token 的 `previewLock` / `previewCredit`（与 `tryLock` / `tryReserve` 共用同一段判定代码）；只认 SP 5.5.0，版本不对返回 `VERSION_MISMATCH` | `SuperPaymasterLens.sol` |
| token 侧 | `_lockDecision` / `_creditDecision` 抽成共用的判定函数，并新增只读的 `previewLock` / `previewCredit` | `xPNTsTokenV2.sol` |

## 2. 体积与存储

| 合约 | runtime | 余量 |
|---|---|---|
| SuperPaymaster 5.5.0 | **23,031 B** | **1,545 B**（门槛 ≥ 1,024 ✅；不做 F1 时是 24,017 B，余量 559 ❌） |
| SuperPaymasterLens | 4,731 B | 19,845 B |

**存储快照**：在编译产物上逐项比对，前 36 项完全相同（到 `_blsSlashCdFloor` @ slot 36 为止）；`_inflight` 在 slot 37；`__gap` 从 `uint256[28]` 缩到 `uint256[27]`，位于 slot 38–64，**末端仍是 slot 64**；Registry 没有变化。`storage-layout/SuperPaymaster.json` 已更新，复跑 `scripts/check_storage_layout.py` 显示 OK。另有 `UUPSUpgrade.t.sol::test_SuperPaymaster_InflightSlot37_SurvivesUpgrade` 在更换实现合约前后读写 slot 37。

## 3. 验收条件 T-R14-09 与 G 层

| 测试 | 断言 |
|---|---|
| `v2/SuperPaymasterV55.t.sol::test_TR1409_settles_at_MIN_POST_OP_GAS_worst_path` | 经过真实的 EntryPoint v0.7，`paymasterPostOpGasLimit == 200,000`，`minTxInterval > 0`（postOp 里要冷写 lastTimestamp）：postOp **没有失败，也确实结算了** |
| `…::test_TR1409_control_below_floor_rejected` | 199,999 在验证阶段被拒（正对照：证明下限检查是有效的） |
| `…::test_G_min_post_op_gas_covers_measured_postOp` | 实测 postOp 为 140,805 gas；140,805 × 64/63 + 20,000 = 163,040 ≤ 200,000（R10-H1 公式） |
| `security/PoC_C04_ForcedPostOpOOG.t.sol::test_fix_minGasFloorIsSufficient` / `test_fix_oneBelowFloorRejected` | 同一性质的第二份独立证据（另一套测试环境） |

## 4. DSR 预审要求补的 4 项（每项都由 SP 亲手做了变异，确认是指名的断言变红）

| # | 测试 | 变异 → 结果 |
|---|---|---|
| 1 R10-M3 | `v2/SuperPaymasterV55.t.sol::test_R10M3_charge_uses_validation_price_snapshot` | postOp 改用实时的 aPNTsPriceUSD → **红**：`charge priced at the validation snapshot: 48000000000000000001 != 52800000000000000000` |
| 2 SETTLE_GAS_BOUND | `…::test_B1_postOp_entry_gas_guard` | 删掉入口检查 → **红**：`call reverted as expected, but without data`（期望的是 PostOpGasTooLow） |
| 3 I8 端到端 | `…::test_I8_settle_failure_rolls_back_user_execution_e2e` | 结算包进 try/catch → **红**：`PostOpRevertReason emitted`。测试内容：op 的执行会让计数器加 1；用 `vm.mockCallRevert` 让 settleLocked 失败；断言计数器没变、用户没被扣费、锁还在、a0 仍在途；下一笔交易里 `releaseStaleLock` 和 `releaseStaleSponsorship` 全额恢复 |
| 4 token 绑定 | `…::test_token_mismatch_rejected` | 删掉绑定检查 → **红，而且是断言本身**：`sigFail bit set on token mismatch: 0 != 1`（错配的代币是另一个社区真实存在、有余额的 v2 代币，并附一个用正确代币的对照） |

原来那个直接调 postOp 的 B-1 测试已改名为 `test_B1_postOp_bubbles_settlement_revert_direct_call`，名字只写它实际测的内容。
`test_configureOperator_rejects_non_v2_token` 也改名为 `test_configureOperator_rejects_non_factory_token`：它其实是在工厂绑定那一步失败，没有走到版本探测。版本探测由 `v3/SecurityFixes_M4_M5_M7.t.sol::test_M4_ConfigureOperatorRejectsNonBalanceModeTokens` 覆盖（满足工厂绑定之后，普通 ERC20、3.x 代币、版本号为 2 的代币都被拒）。

## 5. 旧测试迁移（22 个文件，分 4 组并行，每组都把 worktree 重置到 `e09db389` 之后再开始）

**删除的测试一律写明由哪个新测试覆盖；没有放宽任何断言。** 下表**逐条列出了全部被删除、被替换和"5.5.0 行为不同"的测试**（DSR 要求的格式）；其余测试都是按原意迁移（换成 v2 代币、新的 paymasterAndData 格式、改用 lens），断言没有变弱，这些没有逐条列出。

| 旧测试 | 处理 | 覆盖测试 | 规则 / R1 问题 |
|---|---|---|---|
| BurnRestore `test_PostOp_FallsBack_ToRecordDebt_WhenNoBalance` | 删除（回退路径已不存在） | `test_NoBalance_CreditOff_RejectedAtValidation`、`test_NoBalance_AutoCredit_SettlesAsDebt` | R-2、C-1、C-2、T-R14-06 |
| BurnRestore `test_PostOp_PendingDebts_WhenBothFail` | 删除 | `test_B1_SettleFailure_RevertsPostOp_NoFallback`、v2 `test_I8_…_e2e` | B-1、I8 |
| BurnRestore `test_RetryPendingDebt_Chunked` | 删除 | `test_I10_PostOpOutsideOriginalTx_Reverts_ThenStaleReleaseRestores`、`test_LegacyPendingDebtSelectorsRemoved`、v2 `test_I10_*` | I10、R10-M1b、L-3/L-4 |
| BurnRestore `test_PostOp_OverflowPath_FallsBackToRecordDebt` | 删除 | `test_CreditPath_ChargeCappedAtReservation` | C-2 |
| BurnRestore `test_AuditH1_OverCeilingOp_RejectedInValidation` | **5.5.0 行为不同**：有余额、零信用的用户在 BALANCE 模式下被接纳；中途想转走会以 `BalanceLocked` revert；不产生任何债务 | 同名 | A-1、H-1（审计 H-1 担心的"中途抽干"在结构上已被锁挡住） |
| V3 `test_C01_NoCredit_WithBalance_Rejected` | 同上，**行为不同**，替换为 `test_C01_NoCredit_WithBalance_EscrowedNotDebt` | 新测试 | A-1、I3 |
| V3 `test_V31_DebtRecording_OnBurnFail` | 替换 | `test_V31_DebtRecording_ViaCreditSettlement` | I3、C-2 |
| V3 `test_V31_ReputationEvent` | 替换（原测试没有断言，而且那个事件从未被 emit） | `test_V31_ValidationPasses_NoSPEventInValidation`（带正对照） | — |
| Harden `testReentrancyProtectionPostOp`（原来断言 pendingDebts） | 替换：v2 形态的恶意 token 在 settleLocked 里重入 → postOp 以 ReentrancyGuard revert，a0 仍在途 | 同名 + `testReentrancyProtection_LegacyShapedTokenRejected` | B-1、I10 |
| Coverage_Supplement 的 `MockXPNTs` | 删除（它依赖的 selector 已不存在） | `test_Paymaster_PostOp_Revert` 改为用真实的 context、opReverted 模式结算 | C3-1、T-R14-04 |
| DryRun `MaxRate_DefaultsToMaxUint_WhenDataTooShort` | **行为不同**：token 字段是必需的，所以短的 paymasterAndData 一律返回 TOKEN_MISMATCH，validate 同样 sigFail | `test_DryRun_ShortPaymasterData_RejectedAsTokenMismatch` | R4-H1 |
| Security `…UpdatesOnRevert` | 模式从 postOpReverted 改为 opReverted（EntryPoint v0.7 不会把 postOpReverted 传给 postOp），并断言用户照样为 gas 付费 | 同名 | T-R14-04 |
| PoC_C01 全部 | 迁移到 v2 信用，另新增：同一 bundle 的第 k 笔在验证期被拒；已结算的债务也计入上限，边界值精确到 1 wei；5 笔里恰好准入 3 笔 | `test_C01_sameBundle_*`、`test_C01_settledDebtCountsAgainstCeiling_exactBoundary` | **T-R14-08、C-1、R1-4 / N-C1** |

**迁移过程中新增的主要测试**（守护 5.5.0 的新性质）：`BlacklistSync::test_TR1403_StaleBlacklist_AdmittedOpStillSettles`（T-R14-03）、`PricingV2::test_PostOp_ChargesAtValidationSnapshot`、`PassiveFallback::test_PostOp_UsesValidationSnapshot_NotCurrentCache`、`V3_Pricing::test_PostOp_ConservativeBuffer_R10M3`（charge 精确到 3.96e19）、`APNTs_Integration::test_PostOp_NoCreditPolicy_EmptyUser_NotSponsored`（R-2、I3、T-R14-06）、`Coverage::…_Legacy3xToken` / `…_UnknownBalanceModeVersion`、`Coverage::D12`（旧的 5.4 paymasterAndData 格式被拒）、`DryRunValidation` 新增 9 条（包括拒绝原因码的低字节）。

**迁移组自报的局限，SP 已知悉**：迁移组不能改 `src/`，所以它们新增的断言没有做源码变异（靠精确的算术值和正对照来区分行为）。这些断言的变异检查放到 D3 的 M 层统一做。

## 6. 复现

```bash
git switch feat/aoa-balance-mode-5.5.0
forge test                               # 全量，Cancun（结果见 §7）
forge test --evm-version prague          # 全量，Prague
python3 scripts/check_storage_layout.py  # 需要 forge 在 PATH 里
python3 scripts/check-xpnts-v2-layout.py --self-test
python3 scripts/check-xpnts-v2-selectors.py --self-test
```

## 7. 全量结果

| EVM | 通过 | 失败 | 跳过 | 测试套件 |
|---|---|---|---|---|
| Cancun（默认） | **1477** | **0** | 49 | 119 |
| Prague | **1386** | **0** | 21 | 119 |

对比迁移之前的基线（加入 v2 测试之前，Cancun 为 1421 / 0 / 49）：通过数 +56，跳过数不变。Prague 的总数比 Cancun 少，是因为需要注入预编译的测试套件在 Prague 下会自行跳过（`contracts/test/helpers/MockedPrecompiles.sol`）。
三个检查脚本：`check_storage_layout.py`（SuperPaymaster 38 项、Registry 32 项，均无漂移）、`check-xpnts-v2-layout.py --self-test`、`check-xpnts-v2-selectors.py --self-test` 全部通过。

## 8. 仓库内调用方与 ABI（Codex 收尾审查指出的缺口）

**结论：D2 交付的是合约 + Foundry 测试。仓库内还有链下调用方和部署脚本仍然面向 5.4.x，所以在它们迁移完成之前，这个分支不能交付、不能部署，也不能 push 给下游使用。**

### 8.1 已完成（本次）

| 项 | 内容 |
|---|---|
| `abis/` | 重新生成 `SuperPaymaster.json`（已去掉 dryRunValidation / retryPendingDebt / clearPendingDebt / pendingDebts，新增 releaseStaleSponsorship / inflightOf）；新增 `SuperPaymasterLens.json`、`xPNTsTokenV2.json`、`xPNTsTokenV2Ext.json`、**`xPNTsTokenV2.full.json`**（核心 + 只属于扩展的 59 个条目，共 241 个；两者部署在同一个地址）、`xPNTsFactoryV2.json`、`AOAProtocolRegistry.json`、`GlobalTierSource.json`；manifest 已更新。只提取了这次改动涉及的合约，没有顺带重新生成其他合约（按脚本注释的要求，那会给 SDK 带来一次不相关的破坏性变更）。`node scripts/check-abi-bundle.mjs`：23 个 bundle 与编译产物的完整形状一致 |
| 生成器修正 | `scripts/extract_v3_abis.sh` 原本用 `find \| head -1` 选 artifact，会选到 `out/v2/<C>.sol/<C>.json`（optimizer runs=200），而不是 deploy-core 实际部署的 default profile（runs=500）。现在优先取确切的 `out/<C>.sol/<C>.json`。本次 7 个 ABI 文件里的 bytecode 都已与 default 产物逐字节比对，一致 |
| README | 新增"5.5.0 破坏性接口变更"一节：删除了什么、用什么替代、paymasterAndData 的新格式，并写明哪些调用方尚未迁移 |

### 8.2 尚未迁移（逐个列出，并指定归属的交付物）

| 调用方 | 受影响的原因 | 归属 |
|---|---|---|
| `contracts/script/v3/DeployAnvil.s.sol`、`DeployLive.s.sol`、`TestAccountPrepare.s.sol`、`InitializeAAStar.s.sol`、`InitializeTestCommunities.s.sol`、`DeployRepCreditSepolia.s.sol` | 部署 3.x 工厂和 3.x 代币，并用 3.x 代币调用 `configureOperator`（在 5.5.0 上会以 InvalidXPNTsToken revert） | **D5**：按 runbook 部署 v2 栈（registry → bootstrap → seal → ext → impl → 分档源 → factoryV2），再在 fork 上演练 |
| `contracts/script/deployment/08b_WireUpToken.s.sol`、`11_ConfigureOperator.s.sol`、`11_1_ConfigureBreadOperator.s.sol` | 同上（08b 接的是 3.x 代币；11 / 11_1 用的是已经废弃的三参数签名，本来就编不过） | D5 |
| `contracts/script/v3/L4GaslessTest.s.sol` | 用旧格式拼 paymasterAndData（没有 token 字段） | D5 |
| `script/gasless-tests/test-helpers.js` 以及 `test-case-2/3/4`、`test-group-B1/B3/B4/B5/C1/E3/E4/I1`、`run-all-e2e-tests.sh`、`README.md`；`script/v3/test-e2e.js` | 旧格式的 paymasterAndData；调用 SP 的 `dryRunValidation`；断言 `pendingDebts` / `burnFromWithOpHash` 这条回退路径 | **新交付物 D7：链下 E2E 迁移**（依赖 D5 的部署）。旧回退路径相关的用例改为 5.5.0 的对应语义，dryRun 改调 lens |
| `scripts/gasless-test/*.js`（6 个旧版本的 viem 脚本） | 旧格式的 paymasterAndData | D7。先判断它们是否还在用，不再用的就归档，不改 |
| 下游：aastar-sdk、DVT、YAAA | ABI、paymasterAndData、合并后的 token ABI、lens | 按 CLAUDE.md 约定，在对应仓库**开 issue**（不向别人的仓库提 PR）；在 D5 / D7 完成、SP 这边分支可以部署之后再开 |
