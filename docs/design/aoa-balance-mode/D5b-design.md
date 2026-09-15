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
| Cancun / Prague 全量 | Cancun：136 个套件，**1,686 passed / 0 failed / 49 skipped**；Prague（最后跑）：**1,595 / 0 / 21**（passed / failed / skipped）；之后重新 `forge build` 恢复 default 产物 | `unit-test/forge-test-cancun.log`、`unit-test/forge-test-prague.log` 末行 |
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
| (l) `schedule-call` 不再拒绝 `upgradeToAndCall`（绕开升级读回） | `test_governed_call_refuses_upgrade` | 解除暂停经闸门 |
| (m) `scheduleCallWith`（M2 解除暂停路径）跳过 `governedGate` | `test_governed_call_unpause_goes_through_gate`（不带证明也调度成功） | 拒绝升级、证明缺失 |

(j)–(m) 在同一个脚本里跑（`gates/mutation-matrix-recheck2.log`，第 0 列 61 个测试全绿，四个变异 RESULT 全部 OK）；脚本的 scratch 树现在也复制 `contracts/script` 与示例清单。

### §6.2 C2（spec §10.7b C2，覆盖扩展函数）

- **前向**（`c30854f9` 的 5.5.0 rc → D5b，`test_d5b_forward_mid_bundle_upgrade_with_extension_calls`；Codex 收尾审阅后补上与回滚方向相同的守恒断言：operator 支出、protocolRevenue 增量、token 供应减少、LockSettled 烧毁量四者相等，且无残留锁）：owner = 开放 executor 的 TimelockController。bundle = [攻击者 op 执行已到期的 batch：`upgradeToAndCall(D5b)` → `executeGasParams()`（D5b 核心 fallback 到扩展）→ `setGuardian(guardian 账户)`；guardian 账户的 op 执行全局暂停 + 暂停受害者的 operator；受害者 1、2（由 rc 验证）]。结果：0 个 postOp 失败，两笔都结算、执行保留、在途清零；按**验证时快照**（C_POSTOP 175k + C_WRAP 5k）计费，而不是 bundle 中途生效的参数（400k + 50k）。
- **回滚**（D5b → `c30854f9`，`test_d5b_rollback_mid_bundle_with_extension_calls`）：bundle = [guardian 账户经扩展全局暂停；攻击者 op 执行 batch：`executeGasParams()`（扩展）→ `upgradeToAndCall(c30854f9)`；受害者 1、2（由 D5b 验证，context 384 B）]。结果：0 个 postOp 失败，按快照计费；守恒：operator 支出 = 两笔 charge = revenue 增量 = 烧毁量；slot 40 保留 guardian|paused，rc 忽略它。
- "上一个发布版本"用 `contracts/test/fixtures/superpaymaster-5.5.0-c30854f9-impl.creation.hex`（creation 码，runtime 含部署相关的 immutable，所以不用 runtime fixture）；来源与全部源码 keccak 见 `d5b-previous-release.provenance.json`。按 spec §6 A2 第 5 条，rc1 上 Sepolia 之后要用链上 runtime codehash 核对这份 fixture。

### §6.3 升级流程与演练

- `contracts/script/v3/UpgradeViaTimelock.s.sol`：`UpgradeRegistryD5b`（runbook 第 5c 步，EOA）；`UpgradeViaTimelock` 的 `deploy-impl` / `direct-upgrade`（M1 之前）/ `schedule-upgrade` / `execute-upgrade`（§10.7b C）/ `schedule-accept` / `execute-accept`（M1 的单个 `scheduleBatch` + M2 的 `setGuardian`）/ `schedule-call` / `execute-call`（其余经 timelock 的 SP / Registry 调用，如 M2 的解除暂停；拒绝 `upgradeToAndCall`，升级必须走带读回的 upgrade 模式）。广播者没有 proposer / executor 角色时只打印给 Safe 的 calldata。`UpgradeLive` 遇到 timelock 持有的代理直接拒绝并指向本脚本。
- 本机 anvil 演练（`scripts/d5b-anvil-rehearsal.sh`，`--unlocked`，不传私钥）：c30854f9 的 SP / Registry 上链 → 5c → SP rc→D5b（EOA）→ M1（两步转移、单个 scheduleBatch、48h 前执行失败、48h 后执行、原 EOA 升级失败）→ SP 与 Registry 各一次 schedule → 48h → execute（提前执行失败）→ M2 演练（guardian 暂停；guardian 解除失败；解除暂停经 `schedule-call` / `execute-call` 走同一闸门，48h 后执行）。全部读回通过：`REHEARSAL OK` → `data/d5b/rehearsal/`。这是本机演练，不是 fork 演练；rc1 门槛要求的 Sepolia fork 演练（spec §6 A2）没有做。
- Registry 版本 `Registry-5.8.0` → **`Registry-5.9.0`**；SP 仍为 `SuperPaymaster-5.5.0`；lens 因为新增 `DRYRUN_SPONSORSHIP_PAUSED`（ABI 变化）改为 **`SuperPaymasterLens-1.2.0`**（`SPReleaseVersion.LENS` 同步）。
- SDK：`abis/SuperPaymaster.json` 只剩核心函数，**必须改用 `abis/SuperPaymaster.full.json`**（核心 + 扩展独有 46 项，同一个代理地址）；需要通知 repo:sdk、repo:dvt。Solidity 调用方用 `SuperPaymasterAdminCalls`（`using … for SuperPaymaster`）。

### §6.3b M1 配置预检：forge 侧是**有界的已知账户检查**，排他性由事件历史检查建立（Codex 收尾审阅与复核，两条 Medium）

**forge 侧 `UpgradeViaTimelock.m1Preflight`（有界的已知账户检查）**。在 schedule 之前、以及每一次 execute / acceptance 广播之前都运行（六个受治理的广播：schedule-upgrade、execute-upgrade、schedule-accept、execute-accept、schedule-call、execute-call）。它读取**提交在仓库里的逐网络清单** `deployments/timelock-roles.<ENV>.json`（格式见 `deployments/timelock-roles.example.json`；示例里全是标明为 FAKE 的占位地址并带 `_placeholder`，两侧检查都拒绝它），不满足下列任一条就 revert：清单**每个字段都在**（`parseManifest`：缺任何一个字段是具名 revert，不会读成空集合）；`validateManifest`：`chainId == block.chainid`、timelock 与部署块非零、四个角色集合非空、`mustHoldNothing` 非空且无零地址无重复、每项恰好一个非空标签（Codex 复核 `ed2a4762` 的 M1 / M3）；清单存在且 `timelock` 与配置的 timelock 相同；`getMinDelay() == 172800`（原来只要求 ≥ 48h，而且精确值只在 accept 广播**之后**才读回）；清单写的就是 M1 策略（DEFAULT_ADMIN = [timelock]；PROPOSER = CANCELLER = EXECUTOR = [Safe]，线上 Safe 是 Mycelium 多签 `0x51eD…E114`）；清单列出的持有者都确实持有对应角色；`address(0)` 没有 EXECUTOR；Safe 没有 DEFAULT_ADMIN；清单 `mustHoldNothing` 里的每个账户四种角色都没有。`mustHoldNothing` 是**持久记录在清单里的历史账户**（部署者、SP 与 Registry 的旧 owner 等），不再像上一版那样从代理当前的 `owner()` 推出——那种推法在 M1 执行之后就把旧 owner 丢掉了。执行路径：只有调用者就是 Safe 时才广播，其他调用者只拿到给 Safe 的 calldata。

**局限（必须如实写）**：OZ `TimelockController` 用的是不可枚举的 `AccessControl`，链上没有办法列出某个角色的全部持有者。forge 预检只能对它被告知的账户（timelock、Safe、清单里的账户）调用 `hasRole`；**清单没列出的持有者，forge 预检看不到**。本文此前"DEFAULT_ADMIN_ROLE 只在 timelock 自己手里"的说法是过度声称，已撤回。测试 `test_preflight_is_bounded_unlisted_admin_passes` 正面展示了这一点：一个清单没列出的外部 admin 能通过 forge 预检。

**排他性由事件历史检查建立**：`script/governance/check-timelock-roles.mjs`（viem，版本 `check-timelock-roles/1.2.0`）先校验清单（与 forge 侧同一套完整性规则，另外要求就是 M1 策略、Safe 不是 timelock、`mustHoldNothing` 不含 Safe / timelock；清单不合格退出 1，不扫描），再要求 `--rpc`（以及 `--rpc2`）的 chainId 等于清单 `chainId`（不等退出 1，两个 chainId 都写入报告与证明），然后**钉住一个头块（块号与块哈希）**，从清单的 `deploymentBlock` 到该头块分块（`--chunk` 必须是严格正整数，0、负数、小数、非数字或缺值都以用法错误退出 2——此前 0 或负数会让扫描死循环）拉取该 timelock 的全部 `RoleGranted` / `RoleRevoked`，按（块号，logIndex）重放出每个角色的**完整**持有者集合，与清单**逐项相等**才退出 0；`mustHoldNothing` 账户持有任何角色都失败。完整性：日志扫描无法仅凭返回的数据证明没有漏掉区间（缺失区间与空区间逐字节相同），脚本实际检查并在报告里写明的是：① 深度探针——`deploymentBlock` 有代码、前一块没有，说明端点提供该深度的状态；② 正对照——构造函数自己的授予（timelock 自身的 DEFAULT_ADMIN，以及清单里的 proposer / canceller / executor）必须出现在**部署块内**（此前任何块里出现都算，后来补授的同一角色也能满足它，证明不了扫描到达了构造函数）；③ 状态交叉核对——对每个重放出的持有者、清单持有者和 `mustHoldNothing` 账户，在钉住的头块读 `hasRole`，必须与重放结果一致；④ 可选第二个独立端点 `--rpc2`：必须提供**同一个头块（块号与哈希都相同；落后的端点或另一条链 / 分叉都失败）**，自己也要通过深度探针，并在同一区间返回按规范解码字段（事件、role、account、sender、blockNumber、blockHash、logIndex、transactionHash）逐条相同的日志列表（此前只比 `blockNumber:logIndex:txHash`，而且取两个头的交集——落后的端点照样"一致"）；扫描结束后在两个端点重读头块哈希，发生重组就失败。没有 ④ 时，报告写"completeness NOT independently verified"。带 `--attest` 时，只要通过了参数解析，**每一次运行都写证明文件**，只有退出 0 时 `result` 才是 PASS（同一路径上旧的 PASS 会被 FAIL 覆盖）。

**自测**（`scripts/d5b-timelock-roles-selftest.sh`，本机 anvil，40 步；每个失败步骤都要求出现指定的 problem 文本，失败原因不对不算）：A 角色历史——正确的 M1 timelock → 通过；清单外 DEFAULT_ADMIN → 失败，撤销 → 通过；PROPOSER 授给清单外地址 → 失败，撤销 → 通过；EXECUTOR 授给 `mustHoldNothing` 账户 → 失败，撤销 → 通过；`deploymentBlock` 写错 → 深度探针失败。B 链——清单 chainId 与主端点不同 → 失败；`--rpc2` 是另一条链（第二个 anvil，chainId 31338）→ 失败。C 第二端点——`--rpc2` 为主链在头块处的 anvil fork → 通过（正对照）；在头块前一块处的 fork（落后）→ 失败；忠实转发的代理 → 通过（正对照：代理本身不破坏检查）；丢掉一条日志的代理、改写 indexed `sender` 的代理（旧的比对键里没有 sender）→ 都失败（`scripts/d5b-rpc-tamper-proxy.mjs`，只用于自测）。D 部署块正对照——一个构造时不授予 P/C/E、之后才授给 Safe 的 timelock：持有者集合 == 清单、深度探针与 `hasRole` 都干净，只有部署块正对照失败（自测同时断言其他检查没有触发）。E 清单——十个必需字段逐个删除、空角色集合、空 / 重复 / 零地址 `mustHoldNothing`、标签数量不符、空白标签、提交的示例（`_placeholder`）→ 都失败；示例去掉 `_placeholder` 后**只**因 chainId 失败（证明示例本身是完整的格式）。F `--chunk` 为 0、-5、1.5、abc、缺值 → 退出 2 且不写证明；`--chunk 1` → 通过。输出在 `data/d5b/timelock-roles/`。**修复前一栏**：同一个自测在 `KEEP_GOING=1` 下对 `5ce18296` 的检查脚本跑，40 步里 31 步不符合要求（B、C、D、E、F 全部；`--chunk 0` 被 40 秒闹钟杀掉，退出 142）；C 里两个正对照在旧脚本上也"失败"，只是因为输出里没有新的说明文字（旧脚本退出 0），不算旧脚本的缺陷——`selftest-prefix-5ce18296.log`。forge 侧与事件侧的对照：同一个"清单外 admin"，forge 预检**通过**（`test_preflight_is_bounded_unlisted_admin_passes`），事件检查**失败**（自测第 2 步）。

**forge 测试** `contracts/test/v2/D5bTimelockPreflight.t.sol`（预检部分；全部 27 个见 §6.3c）：正例（完整走完 M1）；非 Safe 调用者不调度；五个负对照——72h 延迟、开放 executor、部署者仍是 admin、Safe 缺 canceller、多一个 EOA proposer——每个都在预检里 revert，批次没有被调度，两个代理的 owner 与提名都没变；调度之后再授予角色，execute 前的第二次预检拦下；清单指向另一个 timelock、清单不是 M1 策略、清单文件缺失，三者都 revert；以及上面的"有界"正面展示。

### §6.3c 排他性闸门在代码里强制执行（Codex 在 `ed2a4762` 上的收尾发现："只写在 runbook 里，生产流程可以绕过"）

**闸门在代码里，不只在 runbook 里。** `UpgradeViaTimelock` 的六个受治理广播（schedule-upgrade、execute-upgrade，对 SP 和 Registry 都适用；M1 的 schedule-accept、execute-accept；其余经 timelock 的调用 schedule-call、execute-call，例如 M2 的解除暂停）都先调用 `governedGate` = 有界预检 `m1Preflight` + `requireRolesAttestation`。后者要求事件历史检查脚本写出的证明文件（环境变量 `TL_ROLES_ATTESTATION`，路径必须在仓库目录内，forge 只能读项目内文件；建议 `deployments/attestations/timelock-roles.<env>.<head>.json`），在任何 schedule / execute 之前逐项核对，不满足就 revert：

- `result == "PASS"`；`chainId == block.chainid`；`timelock` 等于配置的 timelock；
- `manifestKeccak256` 等于**此刻读到的清单文件字节**的 keccak256（证明之后清单被改过就拒绝；证明文件同时记录 sha256 供人核对）；
- 扫描头块不晚于当前块，且不早于当前块 `TL_ATTEST_MAX_AGE` 个块（默认 300；可配置）；
- 四个角色的证明持有者集合与清单**完全相等**，并且每个证明里的持有者此刻在链上仍 `hasRole`。

证明文件由 `check-timelock-roles.mjs --attest <path|auto>` 写出（schema `d5b-timelock-roles-attestation/2`），字段：`result`、`chainId`（主端点）、`rpc2ChainId`、`manifestChainId`、`timelock`、`manifestPath`、`manifestSha256`、`manifestKeccak256`、`deploymentBlock`、`headBlock`、`headBlockHash`（钉住的头块）、四个角色重建出的持有者集合、`mustHoldNothing` 及标签、日志条数、两个端点的深度探针结果、部署块正对照结果、完整性说明（是否用了 `--rpc2`，两个端点均脱敏）、`problems`，以及脚本版本与 git commit（含脚本目录是否有未提交改动）。清单的 chainId 由 forge 侧再核一次（`validateManifest`：`chainId == block.chainid`）。**它不是密码学签名**：文件由检查脚本生成，forge 侧重新核对 chainId、timelock、清单哈希、新鲜度和每个持有者的链上状态，伪造一个 PASS 也骗不过"证明集合 == 清单"加链上 `hasRole` 这两条（见 `test_bounded_preflight_passes_unlisted_admin_but_attestation_gate_blocks`：清单外 admin 的 FAIL 证明被拒，手工改成 PASS 的证明也因集合不等被拒）。

**逃生开关**：`TL_ALLOW_NO_ATTESTATION=true` 只在本地链（chainId 31337 / 1337）上接受，并打印醒目警告；在其他任何 chainId 上 revert（`test_attestation_opt_out_rejected_on_live_chain`，`vm.chainId(10)`）。

**runbook（M1 与之后每一次经 timelock 的升级或参数修改）**：
1. M1 之前提交 `deployments/timelock-roles.<env>.json`（`network`、`chainId`、timelock 地址、部署块、M1 策略的四个角色集合、`mustHoldNothing` 历史账户及标签；不带 `_placeholder`），走评审。
2. 每一次 schedule **和** execute 之前运行 `node script/governance/check-timelock-roles.mjs --rpc <归档端点> --rpc2 <第二个独立归档端点> --manifest deployments/timelock-roles.<env>.json --out <报告> --attest auto`；把生成的证明文件路径设为 `TL_ROLES_ATTESTATION` 再运行对应模式——没有它，脚本直接拒绝。报告、证明文件与命令行（RPC 已脱敏）按 03 §6.1 归档。只有一个端点时，证明里的"completeness NOT independently verified"要原样保留。
3. anvil 演练已按"检查 → 证明 → schedule / execute"端到端执行：**每一个** timelock schedule 与 execute 之前各一次（M1 的 accept、SP 与 Registry 的升级、M2 的解除暂停——此前 M2 的解除暂停是直接用 `cast` 调 timelock 的 `schedule`，绕过了检查，Codex 复核 L1），外加每种受治理调度各一个"不带证明被拒"的负对照（schedule-accept、SP 与 Registry 的 schedule-upgrade、schedule-call）：`data/d5b/rehearsal/roles-*.log`、`attestation-*.json`。

**测试**（`contracts/test/v2/D5bTimelockPreflight.t.sol`，27 个）：有效证明通过（完整走完 M1）；证明缺失、chainId 错、timelock 错、扫描头过旧（`vm.roll` +301）、证明之后清单被改、结果为 FAIL、持有者集合与清单不等，各自 revert，批次未调度、owner 与提名不变；逃生开关在 live chainId 上被拒、在本地链上放行；以及上面那条"清单外 admin：有界预检放行，证明闸门拦下"。Codex 复核 `ed2a4762` 之后新增：清单 chainId 与本链不同被拒；十二种空洞清单（chainId 0、timelock 0、部署块 0、四个角色各自为空、`mustHoldNothing` 为空、缺标签、空标签、零地址、重复）逐项以具名原因被拒；清单文件缺任何一个字段（十个）逐项以具名原因被拒，完整清单能解析通过（正对照）；提交的示例清单被拒；M2 解除暂停经 `scheduleCallWith` / `executeCallWith` 走闸门（不带证明被拒、带证明调度并在 48h 后执行）；`schedule-call` 拒绝 `upgradeToAndCall`。

**不受 M1 闸门保护的路径（明确说明）**：Registry 第 5c 步（`UpgradeRegistryD5b`）、`deploy-impl`、`direct-upgrade` 是 **M1 之前的 EOA 路径**，不涉及 timelock，也不运行预检和证明核对；它们只依赖"owner == 广播者"与各自的读回。M1 之后这三条路径不能再用于代理升级（`direct-upgrade` 与 5c 会因 owner 不是广播者而拒绝；`deploy-impl` 只部署 impl，不改代理）。

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

**Codex 停止前发现（`ed2a4762`）**：事件历史检查只写在 runbook 里，生产流程可以绕过。已处理（§6.3c）：证明文件在代码里强制执行（`governedGate`），本地链之外没有逃生开关。

**Codex 复核（`ed2a4762`）**：无 Critical / High；3 Medium + 2 Low，全部在本轮修复：

| 级别 | 发现 | 处理 | 证据 |
|---|---|---|---|
| Medium M1 | 清单的 `chainId` 从未被核对 | 检查脚本要求 `--rpc` 与 `--rpc2` 的 chainId 都等于清单 chainId（两者都记录）；forge `validateManifest` 要求等于 `block.chainid` | 自测 B（两步）；`test_manifest_chainid_mismatch_reverts`；变异 (j) |
| Medium M2 | `--rpc2` 夸大了完整性：取两个头的交集（落后端点也"一致"）、只比 `blockNumber:logIndex:txHash`、没有自己的深度探针；构造正对照接受任何块里的授予 | 两个扫描钉在同一头块（块号与哈希）、要求 rpc2 深度探针、比对规范解码字段（含 role / account / sender / blockHash）、扫描后重读头块哈希；构造正对照只认部署块 | 自测 C（五步，含两个正对照）、D |
| Medium M3 | 空洞清单：缺字段读成空集合，空 `mustHoldNothing` 让"历史账户不持有角色"恒真 | 两侧都要求完整格式与非空、唯一、非零、带标签的 `mustHoldNothing`；示例改为标明 FAKE 的占位地址并加 `_placeholder`（两侧拒绝） | 自测 E（18 步）；`test_manifest_vacuous_fields_each_rejected`、`test_manifest_file_missing_field_each_rejected`、`test_manifest_example_placeholder_refused`；变异 (j)、(k) |
| Low L1 | 演练在 M2 解除暂停的 schedule 前没有跑检查（直接 `cast` 调 timelock） | 新增受闸门保护的 `schedule-call` / `execute-call`（拒绝 `upgradeToAndCall`）；演练里每一次 schedule / execute 都走"检查 → 证明 → 闸门"，并有"不带证明被拒"的负对照 | `data/d5b/rehearsal/`；`test_governed_call_*`；变异 (l)、(m) |
| Low L2 | `--chunk 0` 或负数使扫描死循环 | 必须是严格正整数，否则用法错误退出 2（不写证明） | 自测 F（五个非法值 + `--chunk 1` 正对照） |

修复前一栏：自测对 `5ce18296` 的检查脚本 40 步里 31 步不符合要求（`--chunk 0` 被闹钟杀掉）；forge 侧新测试无法对旧脚本编译（旧 `RoleManifest` 没有 `chainId` / 标签字段），改用变异 (j)–(m) 证明新断言各自有效。
