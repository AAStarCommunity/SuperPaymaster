# D5b 设计：GOV-2（guardian + 两步所有权）+ GOV-5（gas 参数治理化）+ SP 核心/扩展拆分

状态：**已实现（分支 `d5b/core-admin-gov2`，记录见 §1.1 与 §6）**。原始状态：设计骨架。等实验 Part B 定稿（上下文保持 11 个字 + 旧 context 回退 + 中途升级测试，并通过 Codex）之后，先完成 §1 的实测，再动手实现。验收方：DSR。规范依据：03 §10.7b（GOV-1…5，"GOV-2 规范（第 3 版）"，C2"OpCtx 是升级兼容面"）。

## §1 体积预算与是否拆分（先实测，再决定）

- 基线：main 上的 SP 5.5.0 为 22,915 B；实验 A+B（`e0cf0dc8`）为 23,497 B，余量 1,079 B；发布门槛是余量 ≥ 1,024 B。
- 需要实测的数字：
  1. GOV-2 在核心里的增量（两步所有权的 4 个 override、guardian 的设置和暂停检查、全局 `paused` 的检查）。
  2. GOV-5（Part B 定稿版）的增量。
  3. 把治理和管理函数（各种 owner setter、参数的 queue/execute/cancel、guardian 设置、BLS 聚合器的 queue/apply、slash 相关、`setAgentRegistries` 等）以及非热路径的 view 移到扩展之后，核心能省下多少字节。
- 决定规则：不拆分时，核心余量低于 1,024 → 拆分；拆分之后，核心余量要回到 ≥ 2,000（给后续特性留空间）。数字写进本节。

### §1.1 实测（D5b，2026-09-13；分支 `d5b/core-admin-gov2`）

测量方法：`forge build`（profile.default：solc 0.8.33、runs 500、Registry 200、via_ir、cancun、`bytecode_hash = none`），读产物 `deployedBytecode` 的长度；只接受产物 metadata 与上述设置一致、且 `sources[<file>].keccak256` 等于当前源码的那一份（`scripts/check-sp-size.py` 同样的判据）。中间变体（只测体积、不提交）在 scratch 工程里单独编译同一份 foundry.toml，变体补丁见 `data/d5b/sizes/`。**via_ir 下体积不能线性相加**（下面第 3、4 行就是反例），所以每个数都是整体编译后的实测值，不是增量求和。

| # | 树 | SuperPaymaster runtime | 余量（24,576 − x） | 说明 |
|---|---|---:|---:|---|
| 1 | `2cb89b61`（Part B 合入前，5.5.0 @ `cbcb7045` 源码） | 22,942 | 1,634 | 与 03 §5 v4.0 的读数一致 |
| 2 | `c30854f9`（= `809896d9` Part B 合入 + 版本字符串修复；D5b 基线） | 23,568 | **1,008** | **< 1,024 → 按本节规则必须拆分** |
| — | ⇒ GOV-5（Part B 定稿）的增量 | **+626** | | 第 2 行 − 第 1 行 |
| 3 | 第 2 行 + 只换两步所有权基类（`Ownable2StepNamespaced`） | 24,987 | −411 | 超过 EIP-170 |
| 4 | 第 2 行 + 只加 guardian / 全局 `paused`（不换基类） | 25,257 | −681 | 超过 EIP-170 |
| 5 | 第 2 行 + 完整 GOV-2（两步所有权 + guardian + 全局暂停检查），**不拆分** | 24,270 | 306 | ⇒ **GOV-2 在单体里的增量 +702**；余量 306 < 1,024 |
| 6 | **D5b 拆分后的核心**（`SuperPaymaster`，含完整 GOV-2、GOV-5 与 Codex 第 1 轮的升级前提名检查） | **13,571** | **11,005** | 满足"拆分后 ≥ 2,000"（修复前 13,504 / 11,072） |
| 7 | D5b 扩展 `SuperPaymasterAdmin` | 19,208 | 5,368 | 只经 fallback 到达（修复前 17,897；`_authorizeUpgrade` 的改动经共享基类也编进扩展，via_ir 下变化 +1,311，不是线性的） |
| 8 | Registry（runs 200）：`c30854f9` → D5b（两步所有权 + 零 owner 拒绝 + 升级前提名检查） | 23,038 → 23,306 | 1,538 → **1,270** | +268（修复前 23,258） |

- **拆分省下的字节**：与"不拆分的完整 GOV-2"（第 5 行）相比，核心少了 24,270 − 13,571 = **10,699 B**；扩展本身 19,208 B；扩展里也带着共享基类的函数（UUPS、EntryPoint 押金 / 质押、所有权、公开 getter），这些 selector 在代理上永远由核心应答，是"两边继承同一条链"的代价（没有单独测它们占多少字节）。
- 核心的 initcode（包含在构造函数里创建扩展）= 34,372 B < EIP-3860 的 49,152 B。
- **移到扩展的函数（43 个 selector，`scripts/check-sp-selectors.py` 输出里的 extension-only 列表）**：GOV-2 新增的 `setGuardian`、`setOperatorPaused`、`setGlobalPaused`；operator 管理 `configureOperator`、`setOperatorLimits`；Registry 回调 `updateBlockedStatus`、`updateSBTStatus`；aPNTs 切换 `setAPNTsToken`、`cancelAPNTsTokenChange`、`executeAPNTsTokenChange`、`APNTS_TOKEN_TIMELOCK()`；owner 参数 `setAPNTSPrice`、`setProtocolFee`、`setTreasury`、`setXPNTsFactory`、`setAgentRegistries`、`withdrawProtocolRevenue`；GOV-5 `queueGasParams`、`executeGasParams`、`cancelGasParams`、`gasParams()`；价格 `updatePrice`、`updatePriceDVT`、`emergencySetPrice`、`cancelEmergencyPrice`、`executeEmergencyPrice`、`isChainlinkStale`、`priceValidUntil`、`EMERGENCY_TIMELOCK()`；信用视图 `getAvailableCredit`；slash / 声誉 / BLS `queueSlash`、`cancelSlash`、`isSlashPending`、`primeBlsSlashCooldown`、`slashOperator`、`executeSlashWithBLS`、`updateReputation`、`initBLSAggregator`、`queueBLSAggregator`、`applyBLSAggregator`、`getSlashHistory`、`getSlashCount`、`getLatestSlash`。
- **留在核心**：`validatePaymasterUserOp`、`postOp`、`_reserveForOp`、`_tokenWord`、`releaseStaleSponsorship`、`inflightOf`、`isEligibleForSponsorship` / `isRegisteredAgent`（验证期调用）、operator 存取 `deposit(uint256)`、`depositFor`、`onTransferReceived`、`withdraw`、EntryPoint 押金 / 质押（基类）、UUPS（`upgradeToAndCall`、`proxiableUUID`、`_authorizeUpgrade`）、`initialize`、`version()`、`EXTENSION()`、GOV-2 的 4 个所有权 selector（共享基类里 override），以及全部公开状态 getter（共享基类，两边都有，代理上由核心应答）。
- 公开 getter 没有再移到扩展：核心余量已是 11,005 B，把它们移走只会让 Solidity 侧的类型 `SuperPaymaster` 失去这些成员，收益不需要。

## §2 结构（核心 + SuperPaymasterAdmin 扩展，复用 token 的做法）

1. **存储**：抽出 abstract `SuperPaymasterStorage`（状态变量 + 共享 internal）。核心和扩展继承同一条链：`BasePaymasterUpgradeable(Ownable, Initializable, UUPSUpgradeable) + ReentrancyGuard + …`。用逐项比对核心与扩展布局的脚本校验（照 `check-xpnts-v2-layout.py` 的做法，带 self-test）；UUPS 代理快照 `storage-layout/SuperPaymaster.json` 只允许出现写明的新增项。
2. **UUPS**：`_authorizeUpgrade`、`upgradeToAndCall`、`proxiableUUID` 留在核心。扩展地址作为 immutable 放在核心的实现里，每次升级跟着实现一起更换。扩展不可升级，没有 initializer，直接调用它不产生任何作用（照搬 `test_extension_direct_calls_are_inert`）。
3. **验证和 postOp 路径不经过 fallback**：`validatePaymasterUserOp`、`postOp`、`_reserveForOp`、`_tokenWord`、`releaseStaleSponsorship`、`inflightOf` 都留在核心。ERC-7562 上的行为不变，B 层重跑一次确认。
4. **fallback**：SP 目前既没有 `receive()` 也没有 `fallback()`（已核实）。新增的 fallback 是 **non-payable** 的，所以普通 ETH 转账仍然会被拒绝。在 delegatecall 链上，`msg.sender`、`msg.value` 和事件的 emitter 都保持为代理地址。
5. **SDK**：发布核心 + 扩展的合并 ABI（像 `xPNTsTokenV2.full.json` 那样）。
6. **C2 同样适用于扩展**：升级时核心和扩展一起更换；bundle 中途升级的测试（从 main 上的 5.5.0 升级到 D5b）要覆盖扩展里的函数（例如攻击者的 op 通过 timelock 在 bundle 中途执行已到期的参数修改或暂停）。
7. **CI**：新增 SP 余量 ≥ 1,024 的门槛（补上"测试全绿，但字节码超过 EIP-170"这个盲区；现有的 `forge build --sizes` 只检查硬上限）。

### §2.1 selector 遮蔽（DSR 2026-09-13 指出，必须遵守）

**核心和扩展共享继承链，基类的 public 函数在两边都有 selector；按 fallback 的路由规则，核心有的 selector 永远由核心响应，扩展里对它的 override 永远不会被调用到。** 因此：
- GOV-2 的 `transferOwnership`（两步，显式 `onlyOwner`，零地址表示取消）、`renounceOwnership`（revert）、`acceptOwnership`、`pendingOwner` **必须在核心或共享基类里 override**。如果只写在扩展里，核心继承的 OZ 单步 `transferOwnership` 会继续生效，GOV-2 等于没做；而且直接调用扩展时它是惰性的，测试未必能发现。
- 一般规则：**凡是修改基类行为的 override，都放在核心或共享基类里；扩展只放核心没有的新 selector。**
- 测试：
  - 负对照：通过**代理**调用 `transferOwnership(x)` → owner 不变，`pendingOwner() == x`。
  - 变异：删掉核心里的 override（让 OZ 版本生效）→ 上面这条必须变红。
  - selector 检查脚本新增一条：GOV-2 的这 4 个 selector 必须出现在核心的 override 表里，不能只出现在扩展里。

### §2.2 immutable 绑定

扩展的构造参数如果用到 `BasePaymasterUpgradeable` 的 immutable（如 entryPoint）或 SP 的 immutable（REGISTRY、ETH_USD_PRICE_FEED），必须与核心取同一个值。部署校验里要读回两边并比对（理由与 T-4 的 immutable 绑定检查相同）。

### §2.3 lens 经 fallback 读取

lens 读取 SP 的 view 时，如果其中一部分移到了扩展，staticcall 经 fallback 走 DELEGATECALL 是可行的。在 D 层一致性测试（`test_lens_agrees_with_validation` 等）里覆盖"lens 经 fallback 读取"这条路径。

## §3 GOV-2 行为（按 03 §10.7b 第 3 版实现）

见 03：两步所有权（ERC-7201 命名空间槽保存 `pendingOwner`，`_transferOwnership` 先清空 pending）；Registry 只加两步所有权，不加 guardian，并在 `initialize` 里拒绝零地址；guardian 只能执行 `setOperatorPaused(op, true)` 和全局暂停，恢复只能由 owner（timelock）执行；全局暂停的检查放在 validate 解析 paymasterAndData 之前；暂停不影响 postOp 和 release。

## §4 GOV-5（Part B 定稿版）

以实验分支的最终提交为准：参数存在打包的存储槽里，经 48h timelock 调整，硬上下界满足 15% 规则。验证时的参数快照作为 context **末尾追加的第 12 个完整 ABI 字**（context 384 B），前 11 个字与 5.5.0 的 `OpCtx` 完全相同、每个字保持 ABI 规范值；postOp 按长度区分：恰好 384 B 才读第 12 个字，352 B（5.5.0 产生的旧格式）走 5.5.0 的规则回退，旧实现解码时忽略末尾多出的字（回滚方向由 C2 测试证明）。**不得**把快照塞进已有字的空闲位——对窄类型字，旧实现的 ABI 解码器会因为高位非零而 revert，这正是 03 §10.7b C2 明令禁止的做法（本分支所含的是 v4.0；协调方所说的 v4.0.1 是同一条规则）。（本节第一版写的"放进已有字的空闲位"是错的，已按实现更正。）

## §5 验收清单（逐项附证据）

存储布局（只含写明的新增项）；核心与扩展布局一致（脚本 + self-test）；selector 路由（交集为空；GOV-2 的 4 个 selector 在核心）；§2.1 的负对照和变异；扩展直接调用无作用；immutable 绑定读回；lens 经 fallback；G 层规则（W_postop 重测，包括核心和扩展拆分之后的 postOp）；G2 fuzz 零补贴；C2 中途升级测试；B 层重跑；体积门槛；Cancun 和 Prague 全量（Prague 最后跑，然后重新 `forge build`）；Codex 审阅。

## §6 实现记录（D5b，2026-09-13；分支 `d5b/core-admin-gov2`，基线 `c30854f9`）

证据文件都在 `data/d5b/`（登记见 `EVIDENCE-INDEX.md` 的 D5B-* 行）。下表按 §5 的顺序逐项列出。

| §5 项 | 结论 | 证据 |
|---|---|---|
| 存储布局只含写明的新增项 | 通过。SP：快照 + `guardian`(slot 40, off 0) + `paused`(slot 40, off 20)，`__gap` 25 → 24，末端 65 不变；结构体只是声明作用域从 `SuperPaymaster` 改到 `SuperPaymasterStorage`（成员逐项比较）。Registry：顺序布局完全不变 | `storage-layout/allowed-changes.json`；`scripts/check_storage_layout.py`（改为"快照 + 允许清单"，`--self-test` 8 个合成变异全部被拒；`--negative-control` 把基类换成 OZ `Ownable2Step` 的 scratch 树，SP 与 Registry 都在 entry 1 报 `_status → _pendingOwner`）→ `data/d5b/gates/check_storage_layout-*.log`；ERC-7201 槽位置和内容：`test_gov2_sp_pendingOwner_erc7201_slot`、`test_gov2_registry_two_step`（`vm.load`，并断言提名不改动 0..64 / 0..73 任何顺序槽） |
| 核心与扩展布局一致 | 通过（42 项，最后 `__gap@41`）；self-test 能发现槽位移动和结构体成员偏移 | `scripts/check-sp-layout.py --self-test` → `gates/check-sp-layout.log` |
| selector 路由 | 通过：base 45 ⊆ core 56；扩展独有 43 个 selector，与核心交集为空；18 个热路径 selector 在核心且不在扩展独有集合；GOV-2 的 4 个 selector 与 `_transferOwnership` 的**有效定义**（按编译器 AST 重算 C3 线性化）在 SP 和 Registry 上都是 `Ownable2StepNamespaced`，`transferOwnership` 带 `onlyOwner`。self-test 覆盖：遮蔽、override 只在扩展、缺 `onlyOwner`、缺 `_transferOwnership` override、GOV-2 selector 由扩展应答 | `scripts/check-sp-selectors.py --self-test` → `gates/check-sp-selectors.log` |
| §2.1 负对照与变异 | 通过（见下方变异表） | `scripts/d5b-mutation-matrix.py` → `gates/mutation-matrix.log`；代理上的负对照 `test_gov2_sp_transferOwnership_via_proxy_is_two_step` |
| 扩展直接调用无作用 | 通过：扩展 `owner()==0`、没有 initializer、`setGuardian`/`setGlobalPaused`/`upgradeToAndCall`/`validatePaymasterUserOp` 直接调用 revert；能通过检查的写入只落在扩展自己的存储（代理的 `sbtHolders`、`paused` 不变）；核心实现的 `initialize` 同样不可调用 | `test_d5b_extension_direct_calls_are_inert` |
| fallback 非 payable | 通过：普通 ETH 转账、带 value 的扩展 selector、未知 selector 都 revert；不带 value 的同一路由调用成功（正对照） | `test_d5b_fallback_is_non_payable` |
| immutable 绑定读回 | 通过。扩展由核心的构造函数用同一组参数创建（结构上相等）；测试读回 entryPoint / REGISTRY / ETH_USD_PRICE_FEED；部署侧：`DefaultArtifacts._requireDefaultArtifact("SuperPaymaster")` 现在额外要求 `EXTENSION` 是 profile.default 的 `SuperPaymasterAdmin` 且三个 immutable 与核心相同（运行时比对会屏蔽 `EXTENSION` 这个 immutable，所以必须单独查）；`CheckDefaultArtifacts`、`UpgradeLive`、`UpgradeToV5_5_0` 第 5 步读回同步 | `test_d5b_immutable_binding`；anvil 演练日志里每次 SP 部署都有 `[artifact] SuperPaymasterAdmin extension OK` |
| lens 经 fallback | 通过：lens 读 `gasParams()`（扩展 selector，经核心的 fallback）与 `paused()`（共享基类的公开 getter，由核心直接应答——Codex 第 2 轮指出此前写成"都是扩展 selector"是错的）；全局暂停时 lens 返回 `SPONSORSHIP_PAUSED`，validate 同样 SIG_FAILURE。对 D5b 之前的 5.5.0 核心（没有 `paused()`，没有 fallback），lens 的 staticcall 失败时按"未暂停"处理，与那个实现的验证一致 | `test_d5b_lens_through_fallback_agrees_with_validation`；原有 `test_lens_agrees_with_validation` 仍绿 |
| G 层规则（W_postop 重测） | 通过但余量变小：拆分后 **W_postop = 147,888**（`c30854f9` 同一测试 146,853，+1,035，+0.70%）；×1.15 = 170,072 ≤ C_POSTOP 175,000（C_POSTOP 高出 W_postop 18.33%；硬下限处的余量从 3.6% 降到 2.9%）；wrap 1,770 ≤ C_WRAP 5,000；全下限参数组同样成立。直接调用 postOp 的测量同样 +1,034（141,007 → 142,041），说明增量在 SP 的 postOp 帧内；postOp 源码未改，**增量来自拆分后核心的代码生成，没有进一步归因到具体指令** | `g-layer/PostOpBound-d5b.log` L35–L40、`g-layer/PostOpBound-c30854f9-baseline.log`（`c30854f9` 源码 + 该 commit 的测试文件） |
| G2 fuzz 零补贴 | 通过：两组固定种子各注入约 1,670 次结算失败，I9 unbacked 0 / 0，SUBSIDY 0 / 0 / 0；三个 fuzz 各 1,000 runs 通过 | `g-layer/V55Fuzz-G2-d5b.log` L39、L61、L83、L105 |
| C2 中途升级测试 | 通过（见下方 C2 小节） | `SuperPaymasterD5bUpgradeRace.t.sol`；原有 `SuperPaymasterV55UpgradeRace`（旧 5.5.0 fixture ↔ 当前）仍绿 |
| B 层重跑 | 通过（结论与已提交的 G1 基线逐项相同）：本机 anvil（Osaka）+ Rundler v0.11.0 + Alto v1.2.5（默认与 86400 s 两组），16 × 3 个用例的 `pass` 判定与 `b-layer/cases/*-results.json` 完全一致（原有的已知 FAIL：Rundler B10、B2b，Alto B2a/B3/B4-lowStake/B9-below，未增未减）；ERC-7562 访问检查 OUTSIDE = 0、FORBIDDEN = 0，正对照 `allFlagged = true`；SP 自有槽读取从 26 到 28（多出 GOV-5 参数槽和 D5b 的 slot 40，均为 SP 自有存储） | `data/d5b/b-layer/`（`verdict-diff-vs-committed.txt`、`access-check.txt/json`、三组 results / cases / traces）；运行方式 `scripts/d5b-blayer-rerun.sh`（`g1-run.sh` 的副本，端口 +200，输出只写 `data/d5b/b-layer/`，没有碰 `b-layer/cases` 与 F1 冻结集） |
| 体积门槛 | 通过：核心 13,571 B（余量 11,005）、扩展 19,208、Registry 23,306（余量 1,270）、lens 5,329、BLSAggregator 24,345（余量 231，未改动） | `scripts/check-sp-size.py --self-test`（余量 1,023 被拒、恰好 1,024 通过）→ `gates/check-sp-size.log`；`sizes/sizes-d5b.json`（`script/evidence/sizes.mjs`）；CI：`.github/workflows/test.yml` 新增 "D5b release gates" 一步 |
| Cancun / Prague 全量 | Cancun：136 个套件，**1,692 passed / 0 failed / 49 skipped**；Prague（最后跑）：**1,601 / 0 / 21**（passed / failed / skipped）；之后重新 `forge build` 恢复 default 产物 | `unit-test/forge-test-cancun.log`、`unit-test/forge-test-prague.log` 末行 |
| Codex 审阅 | 见 §6.4 | — |

### §6.1 变异表（`gates/mutation-matrix.log`；先跑未变异的第 0 列 34 个测试全绿）

| 变异 | 变红的具名断言 | 应当不受影响、实测仍绿的列 |
|---|---|---|
| (a) 基类改成 OZ `Ownable2Step`（scratch 树） | 布局门槛：`entry 1 changed: _status@1/0 -> _pendingOwner@1/0`（SP、Registry） | — |
| (b) `transferOwnership` override 去掉 `onlyOwner` | `test_gov2_sp_transferOwnership_requires_owner`（期望的 `OwnableUnauthorizedAccount` 没有出现，即"non-owner nomination must revert"）；另 `registry_two_step`、`guardian_has_no_other_power` | via_proxy_is_two_step、nomination_replace_and_cancel、accept_only_by_pending、renounce_always_reverts |
| (c) 删除核心链上的两步 override（OZ 单步生效） | `test_gov2_sp_transferOwnership_via_proxy_is_two_step`："owner unchanged after transferOwnership (two-step)"；另 registry_two_step、timelock_scheduleBatch 等 | requires_owner、renounce、guardian_cannot_unpause_operator |
| (d) guardian 可以解除暂停 | `test_gov2_guardian_cannot_unpause_operator`、`test_gov2_guardian_cannot_lift_global_pause`（"guardian cannot unpause" 的 expectRevert） | guardian_pauses_operator、strangers_cannot_pause、guardian_has_no_other_power |
| (e1) 全局暂停检查移到 paymasterAndData / token / rate 解析之后 | `test_gov2_global_pause_sigFails_before_parsing`："paused validation must not call the token"（`exchangeRate` 被调用 1 次，期望 0 次） | postOp、stale release、lens 一致性 |
| (e2) 移到 a0 价格计算之后 | 同一测试：`OracleError()`（"paused validation must not reach the price math"） | postOp、stale release |
| (e3) 移到 `_extractOperator` 之后（任何外部调用之前） | **没有测试能区分——等价变异**：两者之间只有对 SP 自有存储的读取，外部可观察行为相同。如实记为盲区，不声称覆盖 | — |
| (f) postOp 在暂停时也拒绝 | `test_gov2_pause_does_not_block_postOp_settlement`（`Unauthorized()`）；`test_d5b_forward_mid_bundle_upgrade_with_extension_calls`："forward: no victim postOp fails: 2 != 0" | stale release、global_pause_sigFails |
| (h) `_authorizeUpgrade` 不再检查挂起提名（Codex 第 1 轮 High 的修复被撤掉） | `test_gov2_upgrade_refused_while_nomination_pending`、`test_gov2_rollback_cannot_carry_a_stale_nomination`（期望的 `PendingOwnershipTransfer` 没有出现） | 原地升级读回、timelock scheduleBatch |
| (i) postOp 记了 revenue 却没把 a0 − charge 退回 operator（Codex 收尾审阅 Low 所要求的变异） | `test_d5b_forward_mid_bundle_upgrade_with_extension_calls`："forward conservation: operator paid exactly the two charges"（396e18 != 112.68e18）；这条是本轮新加的前向守恒断言，加之前前向测试对它是盲的 | 回滚测试（受害者由 `c30854f9` 结算，与被改的 D5b postOp 无关） |
| (g) 两步 override 只写在扩展里 | `test_gov2_sp_transferOwnership_via_proxy_is_two_step`："owner unchanged…"（扩展里的 override 是死代码） | requires_owner |
| (j) `m1Preflight` 不再调用 `validateManifest`（Codex 复核 `ed2a4762` 的 M1/M3） | `test_manifest_chainid_mismatch_reverts`、`test_manifest_vacuous_fields_each_rejected`（"next call did not revert as expected"：Sepolia 清单、chainId 为 0 的清单都能调度） | 72h 延迟、过旧证明、正例 M1 |
| (k) `parseManifest` 接受带 `_placeholder` 的示例清单 | `test_manifest_example_placeholder_refused` | 缺字段逐项拒绝 |
| (l) `schedule-call` 不再拒绝 `upgradeToAndCall`（绕开升级读回） | `test_governed_call_refuses_upgrade` | 解除暂停运行预检 |
| (m) `scheduleCallWith`（M2 解除暂停路径）跳过 `operatorPreflight` | `test_governed_call_unpause_runs_operator_preflight`（不带证明也调度成功） | 拒绝升级、证明缺失 |
| (n) 不再核对证明文件的 `schema`（Codex 复核 `626b6ea8` 的 Medium） | `test_attestation_wrong_schema_reverts` | 结果为 FAIL、正例 M1 |
| (o) 标签不再去空白（只含空白的标签被接受） | `test_manifest_whitespace_only_label_rejected` | 十二种空洞清单 |
| (p) `.roles` 下多出的键不再被拒 | `test_manifest_extra_role_key_rejected` | 缺字段逐项拒绝 |
| (q) 不再用 `blockhash` 核对 `headBlockHash` | `test_attestation_head_block_hash_checked_when_available` | 过旧证明、chainId 错 |
| (r) 线上链也能调大 `TL_ATTEST_MAX_AGE` | `test_attest_max_age_raise_is_local_only` | 过旧证明 |

(j)–(r) 在同一个脚本里跑（`gates/mutation-matrix-recheck3.log`，第 0 列 67 个测试全绿，九个变异 RESULT 全部 OK；(j)–(m) 因测试改名重跑，上一轮的 `mutation-matrix-recheck2.log` 保留作历史）；脚本的 scratch 树也复制 `contracts/script` 与示例清单。这些变异证明的是**预检的各条核对各自有效**，不代表预检是安全边界（§6.3b）。

### §6.2 C2（spec §10.7b C2，覆盖扩展函数）

- **前向**（`c30854f9` 的 5.5.0 rc → D5b，`test_d5b_forward_mid_bundle_upgrade_with_extension_calls`；Codex 收尾审阅后补上与回滚方向相同的守恒断言：operator 支出、protocolRevenue 增量、token 供应减少、LockSettled 烧毁量四者相等，且无残留锁）：owner = 开放 executor 的 TimelockController。bundle = [攻击者 op 执行已到期的 batch：`upgradeToAndCall(D5b)` → `executeGasParams()`（D5b 核心 fallback 到扩展）→ `setGuardian(guardian 账户)`；guardian 账户的 op 执行全局暂停 + 暂停受害者的 operator；受害者 1、2（由 rc 验证）]。结果：0 个 postOp 失败，两笔都结算、执行保留、在途清零；按**验证时快照**（C_POSTOP 175k + C_WRAP 5k）计费，而不是 bundle 中途生效的参数（400k + 50k）。
- **回滚**（D5b → `c30854f9`，`test_d5b_rollback_mid_bundle_with_extension_calls`）：bundle = [guardian 账户经扩展全局暂停；攻击者 op 执行 batch：`executeGasParams()`（扩展）→ `upgradeToAndCall(c30854f9)`；受害者 1、2（由 D5b 验证，context 384 B）]。结果：0 个 postOp 失败，按快照计费；守恒：operator 支出 = 两笔 charge = revenue 增量 = 烧毁量；slot 40 保留 guardian|paused，rc 忽略它。
- "上一个发布版本"用 `contracts/test/fixtures/superpaymaster-5.5.0-c30854f9-impl.creation.hex`（creation 码，runtime 含部署相关的 immutable，所以不用 runtime fixture）；来源与全部源码 keccak 见 `d5b-previous-release.provenance.json`。按 spec §6 A2 第 5 条，rc1 上 Sepolia 之后要用链上 runtime codehash 核对这份 fixture。

### §6.3 升级流程与演练

- `contracts/script/v3/UpgradeViaTimelock.s.sol`：`UpgradeRegistryD5b`（runbook 第 5c 步，EOA）；`UpgradeViaTimelock` 的 `deploy-impl` / `direct-upgrade`（M1 之前）/ `schedule-upgrade` / `execute-upgrade`（§10.7b C）/ `schedule-accept` / `execute-accept`（M1 的单个 `scheduleBatch` + M2 的 `setGuardian`）/ `schedule-call` / `execute-call`（其余经 timelock 的 SP / Registry 调用，如 M2 的解除暂停；拒绝 `upgradeToAndCall`，升级必须走带读回的 upgrade 模式）。广播者没有 proposer / executor 角色时只打印给 Safe 的 calldata。`UpgradeLive` 遇到 timelock 持有的代理直接拒绝并指向本脚本。
- 本机 anvil 演练（`scripts/d5b-anvil-rehearsal.sh`，`--unlocked`，不传私钥）：c30854f9 的 SP / Registry 上链 → 5c → SP rc→D5b（EOA）→ M1（两步转移、单个 scheduleBatch、48h 前执行失败、48h 后执行、原 EOA 升级失败）→ SP 与 Registry 各一次 schedule → 48h → execute（提前执行失败）→ M2 演练（guardian 暂停；guardian 解除失败；解除暂停经 `schedule-call` / `execute-call` 运行同一运维预检，48h 后执行）。全部读回通过：`REHEARSAL OK` → `data/d5b/rehearsal/`。这是本机演练，不是 fork 演练；rc1 门槛要求的 Sepolia fork 演练（spec §6 A2）没有做。
- Registry 版本 `Registry-5.8.0` → **`Registry-5.9.0`**；SP 仍为 `SuperPaymaster-5.5.0`；lens 因为新增 `DRYRUN_SPONSORSHIP_PAUSED`（ABI 变化）改为 **`SuperPaymasterLens-1.2.0`**（`SPReleaseVersion.LENS` 同步）。
- SDK：`abis/SuperPaymaster.json` 只剩核心函数，**必须改用 `abis/SuperPaymaster.full.json`**（核心 + 扩展独有 46 项，同一个代理地址）；需要通知 repo:sdk、repo:dvt。Solidity 调用方用 `SuperPaymasterAdminCalls`（`using … for SuperPaymaster`）。

### §6.3b M1 配置预检：forge 侧是**有界的已知账户检查**；事件历史检查是**运维检查**（Codex 收尾审阅与历次复核）

**先说定位（Codex 复核 `626b6ea8` 之后的结论，SP 决定）**：本节与 §6.3c 描述的全部脚本检查——forge 侧预检、事件历史检查脚本、它写出的证明文件——都是**给运维人员用的预检（operator preflight）**，**不是安全边界**。理由有两条，都无法在脚本层面修补：① 线上的 Safe 是合约，脚本打印出来交给 Safe 的 schedule / execute calldata **本身就是生产路径**，这份 calldata 不带任何证明，Safe 可以晚些提交它，也可以自己另行构造，脚本管不到 Safe 签什么；② 证明文件**没有签名**：手工写一个 PASS 就能漏掉一个清单外的持有者（测试 `test_hand_made_pass_attestation_omitting_a_holder_is_accepted` 如实展示了这一点）；真实的 PASS 在一次新的清单外授权之后，最多仍可用 300 个块。本文此前"机器强制执行""没有证明就不能调度""生产闸门"一类说法都是过度声称，**全部撤回**。角色排他性在链上的真正依据见 §6.3d。

**forge 侧 `UpgradeViaTimelock.m1Preflight`（有界的已知账户检查）**。六个模式（schedule-upgrade、execute-upgrade、schedule-accept、execute-accept、schedule-call、execute-call）在广播或打印 calldata 之前都运行 `operatorPreflight` = `m1Preflight` + `requireRolesAttestation`；它只约束**这一次脚本运行**。`m1Preflight` 读取**提交在仓库里的逐网络清单** `deployments/timelock-roles.<ENV>.json`（格式见 `deployments/timelock-roles.example.json`；示例里全是标明为 FAKE 的占位地址并带 `_placeholder`，两侧检查都拒绝它），不满足下列任一条就 revert：清单**每个字段都在**（`parseManifest`：缺任何一个字段是具名 revert，不会读成空集合；`.roles` 下除四个角色外不能有别的键）；`validateManifest`：`chainId == block.chainid`、timelock 与部署块非零、四个角色集合非空、`mustHoldNothing` 非空且无零地址无重复、每项恰好一个标签且标签去掉空白后非空（与检查脚本的 `String.trim()` 一致：ASCII 空白以及 U+00A0、U+1680、U+2000–U+200A、U+2028/2029、U+202F、U+205F、U+3000、U+FEFF）；清单 `timelock` 与配置的 timelock 相同；`getMinDelay() == 172800`；清单写的就是 M1 策略（DEFAULT_ADMIN = [timelock]；PROPOSER = CANCELLER = EXECUTOR = [Safe]，线上 Safe 是 Mycelium 多签 `0x51eD…E114`）；清单列出的持有者都确实持有对应角色；`address(0)` 没有 EXECUTOR；Safe 没有 DEFAULT_ADMIN；清单 `mustHoldNothing` 里的每个账户四种角色都没有。`mustHoldNothing` 是**持久记录在清单里的历史账户**（部署者、SP 与 Registry 的旧 owner 等），不从代理当前的 `owner()` 推出。执行路径：只有调用者就是 Safe 时才广播（本机 anvil 上是解锁 / prank 的 Safe），其他调用者只拿到给 Safe 的 calldata，并同时打印一段提示：这次预检只约束本次脚本运行，Safe 签名人签名前要在当前头块重跑事件检查并审阅操作内容。

**局限**：OZ `TimelockController` 用的是不可枚举的 `AccessControl`，链上没有办法列出某个角色的全部持有者。forge 预检只能对它被告知的账户调用 `hasRole`；**清单没列出的持有者，forge 预检看不到**（`test_bounded_preflight_passes_unlisted_admin_genuine_attestation_stops_the_operator` 的前半段）。

**事件历史检查（运维检查）**：`script/governance/check-timelock-roles.mjs`（viem，版本 `check-timelock-roles/1.3.0`）先校验清单（与 forge 侧同一套完整性规则，另外要求就是 M1 策略、Safe 不是 timelock、`mustHoldNothing` 不含 Safe / timelock；清单不合格退出 1，不扫描），再要求 `--rpc`（以及 `--rpc2`）的 chainId 等于清单 `chainId`（两个 chainId 都写入报告与证明），然后**钉住一个头块（块号与块哈希）**，从清单的 `deploymentBlock` 到该头块分块（`--chunk` 必须是严格正整数）拉取该 timelock 的全部 `RoleGranted` / `RoleRevoked`，按（块号，logIndex）重放出每个角色的**完整**持有者集合，与清单**逐项相等**才退出 0；`mustHoldNothing` 账户持有任何角色都失败。完整性：日志扫描无法仅凭返回的数据证明没有漏掉区间（缺失区间与空区间逐字节相同），脚本实际检查并在报告里写明的是：① 深度探针——`deploymentBlock` 有代码、前一块没有；② 正对照——构造函数自己的授予必须出现在**部署块内**；③ 状态交叉核对——在钉住的头块读 `hasRole`，必须与重放结果一致；④ 可选第二个独立端点 `--rpc2`：必须提供同一个头块（块号与哈希都相同），自己也要通过深度探针，并在同一区间返回按规范解码字段逐条相同的日志列表；扫描结束后在两个端点重读头块哈希，发生重组就失败。没有 ④ 时，报告写"completeness NOT independently verified"。带 `--attest <path>` 时**每一次运行都在该路径写证明文件**——用法错误、清单不合格、基础设施错误（退出 2）也不例外，只有退出 0 时 `result` 才是 PASS，所以同一路径上较早的 PASS 一定会被后来的失败覆盖（Codex 复核 `626b6ea8` 的 Low；只有 `--attest` 本身缺值时无处可写）。

**自测**（`scripts/d5b-timelock-roles-selftest.sh`，本机 anvil，43 步；每个失败步骤都要求出现指定的 problem 文本，失败原因不对不算）：A 角色历史 8 步；B 链——清单 chainId 与主端点不同、`--rpc2` 是另一条链（第二个 anvil，chainId 31338）；C 第二端点——头块处的 anvil fork 与原样转发的代理两个正对照通过，落后一块的 fork、丢一条日志的代理、改写 indexed `sender` 的代理失败（`scripts/d5b-rpc-tamper-proxy.mjs`，只用于自测）；D 部署块正对照——构造时不授予 P/C/E、之后才授给 Safe 的 timelock，只有部署块正对照失败；E 清单——十个必需字段逐个删除、空角色集合、空 / 重复 / 零地址 `mustHoldNothing`、标签数量不符、空白标签、提交的示例（`_placeholder`）失败，示例去掉 `_placeholder` 后**只**因 chainId 失败；F 退出 2 的路径——`--chunk` 为 0、-5、1.5、abc、缺值，清单文件读不到，缺 `--rpc`，端点不可达，八种情况下事先放在 `--attest` 路径上的**真实 PASS 都被替换成写明原因的 FAIL**；`--chunk 1` 正对照通过。输出在 `data/d5b/timelock-roles/`。**修复前两栏**：对 `5ce18296` 的检查脚本 40 步里 31 步不符合要求（`selftest-prefix-5ce18296.log`，那时 F 段还是旧写法）；对 `626b6ea8` 的检查脚本 43 步里 7 步不符合要求——正是 F 段的七个用法错误，旧的 PASS 原样留在路径上（`selftest-prefix-626b6ea8.log`）；"端点不可达"那一步在 `626b6ea8` 上本来就写 FAIL，两栏都绿，不算这次修复覆盖的缺陷。

**forge 测试** `contracts/test/v2/D5bTimelockPreflight.t.sol`（33 个，全部是预检测试，名字里不再有"gate"或强制执行的说法）：正例（完整走完 M1）；非 Safe 调用者不调度；五个配置负对照（72h 延迟、开放 executor、部署者仍是 admin、Safe 缺 canceller、多一个 EOA proposer）——每个都在预检里 revert，批次没有被调度，两个代理的 owner 与提名都没变；调度之后再授予角色，execute 前的第二次预检拦下；清单指向另一个 timelock、清单不是 M1 策略、清单文件缺失；两条"界限"测试（见 §6.3c）。

### §6.3c 证明文件核对：运维预检，不是强制执行（Codex 在 `ed2a4762` 上的停止前发现、对 `626b6ea8` 的复核）

`requireRolesAttestation` 读取环境变量 `TL_ROLES_ATTESTATION` 指向的证明文件（路径必须在仓库目录内，forge 只能读项目内文件；建议 `deployments/attestations/timelock-roles.<env>.<head>.json`），不满足下列任一条就让**本次脚本运行**停下（revert）：

- `schema == "d5b-timelock-roles-attestation/2"`（Codex 复核 `626b6ea8` 的 Medium）；`result == "PASS"`；`chainId == block.chainid`；`timelock` 等于配置的 timelock；
- `manifestKeccak256` 等于**此刻读到的清单文件字节**的 keccak256；
- 扫描头块不晚于当前块，且不早于当前块 `TL_ATTEST_MAX_AGE` 个块——默认 300；**只能在本地链（31337 / 1337）上调大**，线上链只能调小（`attestMaxAge`）；
- `headBlockHash` 必须存在；当 EVM 还能给出该块的 `blockhash`（头块早于当前块且不超过 256 块）时，两者必须相等，用来发现同 chainId 的分叉 / 重组；给不出时打印"NOT verifiable"。演练里 9 次核对中有 1 次真正比对了哈希（证明头块比当前块早一块的那次），其余 8 次头块就是当前块，只打印了不可核对——`data/d5b/rehearsal/neg-last-execute-call-before-48h.log`；
- 四个角色的证明持有者集合与清单**完全相等**，并且每个证明里的持有者此刻在链上仍 `hasRole`。

证明文件由 `check-timelock-roles.mjs --attest <path|auto>` 写出，字段：`schema`、`result`、`chainId`、`rpc2ChainId`、`manifestChainId`、`timelock`、`manifestPath`、`manifestSha256`、`manifestKeccak256`、`deploymentBlock`、`headBlock`、`headBlockHash`、四个角色重建出的持有者集合、`mustHoldNothing` 及标签、日志条数、两个端点的深度探针、部署块正对照、完整性说明、`problems`、脚本版本与 git commit。

**这些核对能做到的与做不到的（如实写）**：能做到——让运维人员在调度 / 执行前发现"当前角色历史与清单不符"、"证明是别的链 / 别的 timelock / 旧清单的"、"证明过旧"、"证明格式不对"。做不到——① 约束 Safe：线上 Safe 提交的 calldata 不经过这里；② 证明真实性：证明没有签名，一个漏掉持有者的手工 PASS 能通过全部核对（`test_hand_made_pass_attestation_omitting_a_holder_is_accepted`）；③ 实时性：头块之后新增的清单外授权，在 `TL_ATTEST_MAX_AGE` 以内看不到。

**逃生开关**：`TL_ALLOW_NO_ATTESTATION=true` 只在本地链上接受，并打印醒目警告；在其他任何 chainId 上 revert。

**runbook（M1 与之后每一次经 timelock 的升级或参数修改）**：
1. M1 之前提交 `deployments/timelock-roles.<env>.json`（`network`、`chainId`、timelock 地址、部署块、M1 策略的四个角色集合、`mustHoldNothing` 历史账户及标签；不带 `_placeholder`），走评审。
2. **A5s / A6（timelock 部署之后、M1 之前）一次性建立初始角色集合**：运行 `node script/governance/check-timelock-roles.mjs --rpc <归档端点> --rpc2 <第二个独立归档端点> --manifest deployments/timelock-roles.<env>.json --out <报告> --attest auto`，报告、证明文件与命令行（RPC 已脱敏）按 03 §6.1 归档。这一次是 §6.3d 依据 (a) 的证据。
3. 之后每次 schedule / execute 之前，运维人员照样运行它并把证明路径设为 `TL_ROLES_ATTESTATION`（运维预检）；**Safe 签名人签名前自己在当前头块重跑一次**，并审阅被调度操作的内容（尤其是目标为 timelock 自身的 `grantRole` / `revokeRole` / `updateDelay`）。
4. anvil 演练已按"检查 → 证明 → 预检 → schedule / execute"端到端执行：每一个 timelock schedule 与 execute 之前各一次（M1 的 accept、SP 与 Registry 的升级、M2 的解除暂停），外加每种调度各一个"不带证明时脚本停下"的负对照：`data/d5b/rehearsal/roles-*.log`、`attestation-*.json`。

**测试**（`D5bTimelockPreflight.t.sol` 中与证明文件有关的部分）：有效证明通过（完整走完 M1）；证明缺失、schema 不对（旧格式 `/1`）、chainId 错、timelock 错、扫描头过旧（`vm.roll` +301）、证明之后清单被改、结果为 FAIL、持有者集合与清单不等、`headBlockHash` 缺失、`headBlockHash` 与 `blockhash` 不符（`vm.setBlockhash`，并以相等的哈希作正对照）各自让脚本停下，批次未调度、owner 与提名不变；`TL_ATTEST_MAX_AGE` 在 live chainId 上只能调小；逃生开关在 live chainId 上被拒、在本地链上放行；清单 chainId 与本链不同；十二种空洞清单；只含空白的标签（六种，另有一个带内容的正对照）；`.roles` 下多一个键；清单文件缺任何一个字段（十个）；示例清单；M2 解除暂停经 `scheduleCallWith` / `executeCallWith` 运行预检；`schedule-call` 拒绝 `upgradeToAndCall`；以及两条**界限测试**——清单外 admin 能通过有界的 forge 预检、真实证明（FAIL，或列出该 admin 的 PASS）让运维人员停下；**手工 PASS 漏掉该 admin 时能通过全部核对并调度成功**。

**不运行预检的路径**：Registry 第 5c 步（`UpgradeRegistryD5b`）、`deploy-impl`、`direct-upgrade` 是 **M1 之前的 EOA 路径**，不涉及 timelock；它们只依赖"owner == 广播者"与各自的读回。M1 之后这三条路径不能再用于代理升级（`direct-upgrade` 与 5c 会因 owner 不是广播者而拒绝；`deploy-impl` 只部署 impl，不改代理）。

### §6.3d 角色排他性在链上的真正依据（Codex 复核 `626b6ea8` 之后，SP 决定；已按 OZ 5.0.2 源码核对）

源码：`singleton-paymaster/lib/openzeppelin-contracts-v5.0.2/contracts/`（`package.json` 版本 5.0.2）。

**(a) 部署时的初始角色集合，由构造参数决定，事件检查一次性建立。** `governance/TimelockController.sol` L115–L137 的构造函数：L117 `_grantRole(DEFAULT_ADMIN_ROLE, address(this))`（timelock 自己管理自己）；L120–L122 只有 `admin != address(0)` 时才额外授予一个 admin——GOV-1 要求 `admin = address(0)`（若部署时给了临时 admin，必须由它自己 `renounceRole`，`access/AccessControl.sol` L157–L163，只有持有者本人能放弃）；L125–L128 每个 proposer 同时得到 PROPOSER 与 CANCELLER；L131–L133 每个 executor 得到 EXECUTOR；这些授予都在部署交易里发出 `RoleGranted`。所以初始集合完全由部署交易决定，A5s / A6 用事件检查（部署块正对照 + 深度探针 + 第二端点）**一次性**核对并归档（runbook 第 2 步）。

**(b) 此后唯一的 DEFAULT_ADMIN 是 timelock 自己，所以任何角色变更本身都必须是一次公开调度、至少延迟 48h 的 timelock 操作。** `TimelockController.sol` 里没有调用 `_setRoleAdmin`（全文 0 处），所以四个角色的 admin 都是默认值 `DEFAULT_ADMIN_ROLE = 0x00`（`AccessControl.sol` L57，`getRoleAdmin` L106–L108 返回 `_roles[role].adminRole`，未设置即 0x00）；`grantRole` L122 与 `revokeRole` L137 都带 `onlyRole(getRoleAdmin(role))`，即调用者必须持有 DEFAULT_ADMIN。当 DEFAULT_ADMIN 只有 timelock 自己时，唯一能调用它们的是 timelock，而 timelock 发起外部调用只能经 `execute` / `executeBatch`（L364、L391，`onlyRoleOrOpenRole(EXECUTOR_ROLE)`），被执行的操作必须先 `schedule` / `scheduleBatch`（L273、L298，`onlyRole(PROPOSER_ROLE)`），调度时 `_schedule` 要求 `delay >= getMinDelay()`（L316–L323，否则 `TimelockInsufficientDelay`），并发出带目标与 calldata 的 `CallScheduled`（L72–L80）。延迟本身也只能由 timelock 自己改（`updateDelay` L449–L456，`sender != address(this)` 就 revert），同样要经过调度。**唯一不经 timelock 的角色变化是 `renounceRole`**（L157–L163）：持有者可以立即放弃**自己的**角色，这只会缩小集合（例如 Safe 放弃 EXECUTOR 会让 timelock 无法执行），不会增加持有者。

**(c) 所以持续的保障 = 监控 + Safe 签名人审阅，不是脚本。** 任何新增持有者都会先以 `CallScheduled(target = timelock, data = grantRole(...))` 公开至少 48h，然后才有 `RoleGranted`。**TODO（交给 reputation / 监控系统，本轮不写代码）**：监控这把 timelock 的 `CallScheduled`（目标为 timelock 自身、selector 为 `grantRole` / `revokeRole` / `updateDelay` 的调用报警）、`RoleGranted`、`RoleRevoked`、`Cancelled`、`MinDelayChange`；并由 Safe 签名人审阅任何被调度的角色变更。事件检查脚本在这里的角色是：(a) 的一次性证据，以及运维人员 / 签名人随时可以重跑的核对工具。

**可选的后续加固（登记为 O 项，不进 5.5.0）**：**O-D5b-1**——在 Safe 上加一个 Guard / 模块，在链上检查被提交到 timelock 的操作（例如拒绝目标为 timelock 的 `grantRole`，或要求链上可验证的条件），这样约束才真正落在 Safe 签名的路径上。需要单独设计与审计，不在 5.5.0 范围内。

**待并入 03 规范的说明**（建议放在 §10.7b GOV-1 / M1 行之后；D5b 不直接改规范正文）：
> GOV-1 的角色排他性依据：timelock 以 `admin = address(0)` 部署（或部署后临时 admin 已 `renounceRole`），A5s / A6 用事件历史检查一次性核对初始角色集合并归档；此后 DEFAULT_ADMIN 只有 timelock 自己，OZ 5.0.2 `TimelockController` 中任何 `grantRole` / `revokeRole` 都必须是一次公开调度、延迟 ≥ minDelay（172800 s）的 timelock 操作（`TimelockController.sol` L115–L137、L316–L323；`AccessControl.sol` L57、L106、L122、L137）；唯一例外 `renounceRole` 只能缩小集合。持续保障 = 监控 timelock 的 `CallScheduled` / `RoleGranted` / `RoleRevoked`（TODO：reputation / 监控系统）+ Safe 签名人审阅被调度的角色变更。`UpgradeViaTimelock` 的预检与 `check-timelock-roles.mjs` 的证明文件是运维工具，不是安全边界（不能约束 Safe 签什么，证明未签名）。可选加固 O-D5b-1：Safe Guard / 模块在链上执行该检查，不进 5.5.0。

### §6.4 Codex 审阅（第 1 轮，2026-09-13，只读，范围 = `c30854f9..HEAD` 的 src、升级脚本、布局 / selector 门槛）

MCP 形式的 Codex 连接失败，改用 codex 插件的后台任务（`task-mtzmz049-cfhco4`）。**第 1 轮没有给出 APPROVE**；结论与处理：

| 级别 | 发现 | 处理 |
|---|---|---|
| High | 挂起的提名能跨过回滚：回滚到 `c30854f9`（单步 OZ `Ownable`，不读也不清 ERC-7201 槽）后在旧实现下换 owner，再升级回 D5b 时旧提名人可以 `acceptOwnership()` 接管 | **已修**：`Ownable2StepNamespaced._requireNoPendingOwner()`，SP（`BasePaymasterUpgradeable`）与 Registry 的 `_authorizeUpgrade` 都调用它——有挂起提名时拒绝任何实现切换（先 `transferOwnership(0)` 取消）。测试 `test_gov2_upgrade_refused_while_nomination_pending`、`test_gov2_rollback_cannot_carry_a_stale_nomination`（提名 → 回滚被拒 → 取消 → 回滚 → 旧实现下单步换 owner → 再升级 → 旧提名人无法接受）；变异 (h) 去掉这一检查，两条都变红。升级脚本在 schedule / execute / direct 前先读该槽，非零就停 |
| Medium | `DefaultArtifacts` 只核对编译目标本身的源码哈希；只改了被 import 的基类（如 `SuperPaymasterStorage.sol`）时，陈旧的核心 / 扩展产物仍能通过 | **已修**：`_isDefaultBuild` 追加 `_localImportsFresh`，产物 metadata 里每一个 `contracts/src/**` 源文件都要与磁盘一致（lib/ 依赖由子模块 commit 固定） |
| Medium | `check_storage_layout.py update` 仍会覆盖基线，覆盖后任何漂移都显示"未变" | **已修**：`allowed-changes.json` 为每个快照记录 `baseline_sha256`；快照文件哈希与之不符即失败，替换基线必须在同一个评审改动里同时改 pin |
| Low | `_resolve_type` 不记录 `encoding` / `numberOfBytes`，mapping 的 key 只记 label；UDVT 换底层类型但保留 label 时可能漏检（当前布局没有这种情况） | **未修，登记**：加字段会改变快照格式、需要同步重建并重新 pin 基线，留作后续 |
| Low | selector 脚本接受直接定义在 `SuperPaymaster` / `Registry` 里的 GOV-2 函数，而不检查函数体 | **已修**：GOV-2 四个函数与 `_transferOwnership` 的有效定义必须**恰好**是 `Ownable2StepNamespaced` 的 |

**Codex 第 2 轮（只读，复核上述修复与整个 `contracts/src` 差异）：没有 Critical / High / Medium**；确认 High、两条 Medium、selector 那条 Low 已修；认为挂起提名检查无法经 `upgradeToAndCall` 的 calldata 绕过（授权先于实现切换与 setup 调用），也不会把紧急升级卡死（owner 可先 `transferOwnership(0)`，timelock 可把取消与升级放进同一个 batch）；剩下两条 Low：① `_resolve_type` 仍未记录 `encoding` / `numberOfBytes`（登记为后续项，同上）；② lens 注释、测试注释和本文把 `paused()` 写成了扩展 selector，实际它是共享基类的公开 getter、由核心直接应答——**已更正**（只有 `gasParams()` 经 fallback）。第 2 轮没有写出"APPROVE"字样，结论是"无 Critical/High/Medium，两条 Low"。

**Codex 收尾审阅（`072863b2`）**：无 Critical / High，其余全部审过无问题；1 Medium + 2 Low 未批准，均已修：Medium = M1 配置预检（§6.3b）；Low = 前向 C2 缺守恒断言（已补，变异 (i) 证明新断言有效）；Low = 本文 §4 把快照写成"放进已有字的空闲位"（已按实现改成追加第 12 个字）。

**Codex 复核（`036a2921`）**：此前各项修复全部确认；新提 1 条 Medium——forge 预检无法证明角色排他（`AccessControl` 不可枚举），而注释与本文把它写成了排他性保证；旧 owner 只在仍是 owner 时才被列入禁用名单，M1 之后就掉出去。已处理（§6.3b、§6.3c）：措辞改为"有界的已知账户检查"；强制使用提交在仓库里的逐网络清单（历史账户持久记录，不再从 `owner()` 推）；新增事件历史检查脚本 `check-timelock-roles.mjs` 与 anvil 自测；runbook 要求每次 schedule 前运行并归档；明确 5c、`deploy-impl`、`direct-upgrade` 是不受 M1 预检保护的 M1 前 EOA 路径；测试里同时展示"清单外 admin：forge 预检通过、事件检查失败"。

**Codex 停止前发现（`ed2a4762`）**：事件历史检查只写在 runbook 里，生产流程可以绕过。当时的处理是让脚本在每次调度 / 执行前核对证明文件，并称之为"强制执行"；**这一说法已被 `626b6ea8` 的复核推翻并撤回**（见下），现在的定位是运维预检（§6.3b、§6.3c）。

**Codex 复核（`ed2a4762`）**：无 Critical / High；3 Medium + 2 Low，全部在本轮修复：

| 级别 | 发现 | 处理 | 证据 |
|---|---|---|---|
| Medium M1 | 清单的 `chainId` 从未被核对 | 检查脚本要求 `--rpc` 与 `--rpc2` 的 chainId 都等于清单 chainId（两者都记录）；forge `validateManifest` 要求等于 `block.chainid` | 自测 B（两步）；`test_manifest_chainid_mismatch_reverts`；变异 (j) |
| Medium M2 | `--rpc2` 夸大了完整性：取两个头的交集（落后端点也"一致"）、只比 `blockNumber:logIndex:txHash`、没有自己的深度探针；构造正对照接受任何块里的授予 | 两个扫描钉在同一头块（块号与哈希）、要求 rpc2 深度探针、比对规范解码字段（含 role / account / sender / blockHash）、扫描后重读头块哈希；构造正对照只认部署块 | 自测 C（五步，含两个正对照）、D |
| Medium M3 | 空洞清单：缺字段读成空集合，空 `mustHoldNothing` 让"历史账户不持有角色"恒真 | 两侧都要求完整格式与非空、唯一、非零、带标签的 `mustHoldNothing`；示例改为标明 FAKE 的占位地址并加 `_placeholder`（两侧拒绝） | 自测 E（18 步）；`test_manifest_vacuous_fields_each_rejected`、`test_manifest_file_missing_field_each_rejected`、`test_manifest_example_placeholder_refused`；变异 (j)、(k) |
| Low L1 | 演练在 M2 解除暂停的 schedule 前没有跑检查（直接 `cast` 调 timelock） | 新增运行同一预检的 `schedule-call` / `execute-call`（拒绝 `upgradeToAndCall`）；演练里每一次 schedule / execute 都走"检查 → 证明 → 预检"，并有"不带证明时脚本停下"的负对照 | `data/d5b/rehearsal/`；`test_governed_call_*`；变异 (l)、(m) |
| Low L2 | `--chunk 0` 或负数使扫描死循环 | 必须是严格正整数，否则用法错误退出 2（`626b6ea8` 之后还会把 FAIL 写到 `--attest` 路径） | 自测 F |

修复前一栏：自测对 `5ce18296` 的检查脚本 40 步里 31 步不符合要求（`--chunk 0` 被闹钟杀掉）；forge 侧新测试无法对旧脚本编译（旧 `RoleManifest` 没有 `chainId` / 标签字段），改用变异 (j)–(m) 证明新断言各自有效。

**Codex 复核（`626b6ea8`）：CHANGES REQUIRED，2 High + 1 Medium + 1 Low**；其余全部确认无误（六个 schedule / execute 函数都先运行预检；清单哈希绑定到确切的文件字节；链 / timelock 不符被拒；逃生开关只限本地链；rpc2 钉头块与解码比对正确；示例清单被拒；自测与变异 (j)–(m) 真实有效；各退出路径都按失败处理；`contracts/src` 自 `036a2921` 以来未变）。

| 级别 | 发现 | 处理 |
|---|---|---|
| High H1 | 线上 Safe 是合约，脚本打印的 schedule / execute calldata 就是生产路径，不带证明；Safe 可以晚些提交或自己构造 | **不在脚本层修补（做不到）**，按 SP 决定改为如实定位：脚本检查是运维预检、不是安全边界（NatSpec、本文 §6.3b–§6.3c、runbook、报告全部改写，"机器强制执行 / 生产闸门 / 没有证明不能调度"的说法全部撤回；`governedGate` 改名 `operatorPreflight`）；链上依据写进 §6.3d（按 OZ 5.0.2 源码行号核对）；持续保障 = 监控 + Safe 签名人审阅（TODO，交给 reputation / 监控系统）；打印给 Safe 的 calldata 旁边加提示；可选加固登记为 **O-D5b-1**（Safe Guard / 模块），不进 5.5.0 |
| High H2 | 证明未签名：手工 PASS 可漏掉清单外持有者；真实 PASS 在新授权后最多仍可用 300 块；`TL_ATTEST_MAX_AGE` 可任意调大；forge 不核对 `headBlockHash`（同 chainId 分叉重放） | 同上，定位改为运维预检，并新增界限测试 `test_hand_made_pass_attestation_omitting_a_holder_is_accepted` 如实展示；作为低成本的运维安全改进（不是安全声明）：`TL_ATTEST_MAX_AGE` 只能在本地链调大（`attestMaxAge`，`test_attest_max_age_raise_is_local_only`，变异 (r)）；EVM 能给出 `blockhash` 时核对 `headBlockHash`（`test_attestation_head_block_hash_checked_when_available`，变异 (q)） |
| Medium | forge 不核对证明 `schema`；标签不去空白；不拒绝多出的角色键（与检查脚本不一致） | 三项都已补并各有测试与变异：(n)、(o)、(p) |
| Low | 退出 2（用法 / 基础设施错误）时不覆盖 `--attest` 路径上已有的证明 | 已修：先定位 `--attest`，任何退出 2 都在该路径写带原因的 FAIL；自测 F 段八种情况都先放一个真实 PASS 再验证被替换；修复前一栏（`626b6ea8` 的检查脚本）F 段七个用法错误全红，旧 PASS 原样留下 |
