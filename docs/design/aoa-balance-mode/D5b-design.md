# D5b 设计：GOV-2（guardian + 两步所有权）+ GOV-5（gas 参数治理化）+ SP 核心/扩展拆分

状态：**设计骨架**。等实验 Part B 定稿（上下文保持 11 个字 + 旧 context 回退 + 中途升级测试，并通过 Codex）之后，先完成 §1 的实测，再动手实现。验收方：DSR。规范依据：03 §10.7b（GOV-1…5，"GOV-2 规范（第 3 版）"，C2"OpCtx 是升级兼容面"）。

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
| 6 | **D5b 拆分后的核心**（`SuperPaymaster`，含完整 GOV-2 与 GOV-5） | **13,504** | **11,072** | 满足"拆分后 ≥ 2,000" |
| 7 | D5b 扩展 `SuperPaymasterAdmin` | 17,897 | 6,679 | 只经 fallback 到达 |
| 8 | Registry（runs 200）：`c30854f9` → D5b（两步所有权 + 零 owner 拒绝） | 23,038 → 23,258 | 1,538 → **1,318** | +220 |

- **拆分省下的字节**：与"不拆分的完整 GOV-2"（第 5 行）相比，核心少了 24,270 − 13,504 = **10,766 B**；扩展本身 17,897 B；扩展里也带着共享基类的函数（UUPS、EntryPoint 押金 / 质押、所有权、公开 getter），这些 selector 在代理上永远由核心应答，是"两边继承同一条链"的代价（没有单独测它们占多少字节）。
- 核心的 initcode（包含在构造函数里创建扩展）= 32,994 B < EIP-3860 的 49,152 B。
- **移到扩展的函数（43 个 selector，`scripts/check-sp-selectors.py` 输出里的 extension-only 列表）**：GOV-2 新增的 `setGuardian`、`setOperatorPaused`、`setGlobalPaused`；operator 管理 `configureOperator`、`setOperatorLimits`；Registry 回调 `updateBlockedStatus`、`updateSBTStatus`；aPNTs 切换 `setAPNTsToken`、`cancelAPNTsTokenChange`、`executeAPNTsTokenChange`、`APNTS_TOKEN_TIMELOCK()`；owner 参数 `setAPNTSPrice`、`setProtocolFee`、`setTreasury`、`setXPNTsFactory`、`setAgentRegistries`、`withdrawProtocolRevenue`；GOV-5 `queueGasParams`、`executeGasParams`、`cancelGasParams`、`gasParams()`；价格 `updatePrice`、`updatePriceDVT`、`emergencySetPrice`、`cancelEmergencyPrice`、`executeEmergencyPrice`、`isChainlinkStale`、`priceValidUntil`、`EMERGENCY_TIMELOCK()`；信用视图 `getAvailableCredit`；slash / 声誉 / BLS `queueSlash`、`cancelSlash`、`isSlashPending`、`primeBlsSlashCooldown`、`slashOperator`、`executeSlashWithBLS`、`updateReputation`、`initBLSAggregator`、`queueBLSAggregator`、`applyBLSAggregator`、`getSlashHistory`、`getSlashCount`、`getLatestSlash`。
- **留在核心**：`validatePaymasterUserOp`、`postOp`、`_reserveForOp`、`_tokenWord`、`releaseStaleSponsorship`、`inflightOf`、`isEligibleForSponsorship` / `isRegisteredAgent`（验证期调用）、operator 存取 `deposit(uint256)`、`depositFor`、`onTransferReceived`、`withdraw`、EntryPoint 押金 / 质押（基类）、UUPS（`upgradeToAndCall`、`proxiableUUID`、`_authorizeUpgrade`）、`initialize`、`version()`、`EXTENSION()`、GOV-2 的 4 个所有权 selector（共享基类里 override），以及全部公开状态 getter（共享基类，两边都有，代理上由核心应答）。
- 公开 getter 没有再移到扩展：核心余量已是 11,072 B，把它们移走只会让 Solidity 侧的类型 `SuperPaymaster` 失去这些成员，收益不需要。

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

以实验分支的最终提交为准：参数存在打包的存储槽里，经 48h timelock 调整，硬上下界满足 15% 规则，验证时把参数快照放进 context 已有字的空闲位，旧 context 走安全回退。

## §5 验收清单（逐项附证据）

存储布局（只含写明的新增项）；核心与扩展布局一致（脚本 + self-test）；selector 路由（交集为空；GOV-2 的 4 个 selector 在核心）；§2.1 的负对照和变异；扩展直接调用无作用；immutable 绑定读回；lens 经 fallback；G 层规则（W_postop 重测，包括核心和扩展拆分之后的 postOp）；G2 fuzz 零补贴；C2 中途升级测试；B 层重跑；体积门槛；Cancun 和 Prague 全量（Prague 最后跑，然后重新 `forge build`）；Codex 审阅。
