# APNTsCapped 交付记录（GOV-4 (b)，2026-09-13）

> 规范：`apnts-capped-design.md`（设计）、`03-final-spec.md` §6 runbook 第 1 步（改写版）、§10.7b GOV-1..5。
> 本交付是独立的小件，由 DSR 单独验收。**没有改动** `SuperPaymaster` 或 `contracts/src` 中任何已有合约；只新增文件。

## 1. 交付了什么

| 文件 | 内容 |
|---|---|
| `contracts/src/tokens/APNTsCapped.sol` | 新合约，`version() == "APNTsCapped-1.0.0"`，**不可升级** |
| `contracts/test/tokens/APNTsCapped.t.sol` | 单元测试（真 OZ `TimelockController`，48h）。该文件不 import 任何会牵到 `Registry.sol` 的东西，所以按 profile.default（runs 500）编译，测的就是部署脚本发出去的那份字节码 |
| `contracts/test/tokens/APNTsCappedSPIntegration.t.sol` | 与真实 SP 5.5.0 代理的集成测试（规范 EntryPoint v0.7 字节码）。该文件经 `UUPSDeployHelper` import 了 `Registry.sol`，整个闭包按 runs=200 的 `registry-size` 编译，所以 **token 不用 `new`，而是按元数据（runs == 500）选出 profile.default 产物再 `vm.deployCode`** |
| `contracts/script/v3/DeployAPNTsCapped.s.sol` | 部署脚本：按 profile.default 产物路径部署 + 运行时字节码比对、Ownable2Step 交给 timelock、读回和负对照 |
| `abis/APNTsCapped.json`、`abis/abi.config.json` | 只为新合约生成 ABI（`scripts/extract_v3_abis.sh APNTsCapped`），`node scripts/check-abi-bundle.mjs` 通过（"abis/ matches the compiled contracts"） |

### 1.1 合约要点

- 继承 OZ v5.0.2 `ERC20` + `ERC20Permit` + `Ownable2Step`（全新、不可升级的合约，这里用 OZ 的 `Ownable2Step` 没有存储布局问题）。
- **角色**（作者决定）：
  - `owner` = GOV-1 的 48h `TimelockController`（proposer / canceller = 治理多签 `0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114`）：`raiseCap`、`setMinter`、`setCapGuardian`；
  - `minter` = 治理多签：`mint`；
  - `capGuardian` = 治理多签：`lowerCap`（即时生效；owner 也可以调低）。
- **上限**：`mint` 要求 `totalSupply() + amount <= cap`（写成不会溢出的 `amount > cap || supply > cap - amount`），否则 `CapExceeded(supply, amount, cap)`。
- `raiseCap(newCap)`：仅 owner，`newCap > cap`，否则 `CapNotRaised`。
- `lowerCap(newCap)`：capGuardian 或 owner，`newCap < cap`，否则 `CapNotLowered`；可以低于当前 supply（此后所有 mint 都 revert，`isOverIssued() == true`，已有余额不受影响）。
- 持有人 `burn(amount)`；没有任何第三方 burn / transfer 特权，没有 factory，没有 autoApprovedSpender，没有 SP 特权。
- `renounceOwnership()` 恒 revert `RenounceDisabled`。
- `transferAndCall(to, amount[, data])`：先 `_transfer`，再调用 `IERC1363Receiver(to).onTransferReceived(msg.sender, msg.sender, amount, data)`，返回值必须等于 `onTransferReceived.selector` —— 与 `xPNTsToken.sol:321–340` 的调用方式、以及 `SuperPaymaster.onTransferReceived`（`SuperPaymaster.sol:793`，检查 `msg.sender == APNTS_TOKEN`，把 `from` 记为 operator，返回自身 selector）完全一致。**比 xPNTs 3.5.0 更严格的两处（都是 fail-closed）**：接收方没有代码时 revert `ReceiverNotContract`（ERC-1363 语义；xPNTs 对 EOA 直接放行）；接收方的 revert 原样冒泡（xPNTs 用 try/catch 吞掉，只给通用字符串），所以 SP 的 `Unauthorized` 能直接传到调用者。
- 兼容视图：`issuanceCap()`（== `cap`，这里是**会执行**的上限）、`isOverIssued()`（== `totalSupply() > cap`）。
- 事件：`CapRaised(old,new)`、`CapLowered(old,new,by)`、`MinterSet`、`CapGuardianSet`、`Minted(to, amount, supplyAfter, cap)`。构造函数也发出 `CapRaised(0,cap)`、`MinterSet(0,minter)`、`CapGuardianSet(0,guardian)`，方便索引器从创世开始跟踪。
- **运行时体积：5,346 B**（profile.default：cancun、runs 500、via_ir；EIP-170 余量 19,230 B）。

### 1.2 上限数值

| 链 | cap | 说明 |
|---|---|---|
| Sepolia / anvil | `TEST_CAP_SEPOLIA = 10,000,000e18` | **测试值**，脚本和日志都标明 "TEST VALUE"；在测试链上设置 `APNTS_CAP` 会被脚本拒绝，避免混淆 |
| 主网（chainid 1 / 10） | **作者决定：300,000e18**（`MAINNET_DECIDED_CAP`，2026-09-13 经 DSR） | 仍然**必须显式传入** `APNTS_CAP=300000000000000000000000`，不传脚本拒绝运行；传入的值与 300,000e18 不同时，`run()` 和 `verify()` 都会打印醒目的 WARNING（不阻断，以便作者将来改决定时不必改脚本） |

## 2. 测试（设计 §3 → 测试名）

两个文件共 33 个测试（单元 26 个，含 1 个 fuzz；SP 集成 7 个）。单元测试里 minter / capGuardian / owner 用**不同地址**，使每个权限检查都可以单独区分（生产上 minter 和 capGuardian 是同一个多签）。owner 是一个真实的 OZ `TimelockController`（minDelay 48h，proposer/canceller/executor = 多签地址），`setUp` 里按部署脚本同样的方式完成 Ownable2Step 交接。

| 设计 §3 条目 | 测试 |
|---|---|
| mint 到正好等于 cap 成功 | `test_cap_mint_exactly_cap_succeeds`；`test_cap_mint_one_wei_over_reverts`（正对照部分） |
| 超出 1 wei 以 `CapExceeded` revert | `test_cap_mint_one_wei_over_reverts`（**CAP-1**）、`test_cap_single_mint_one_wei_over_reverts`、`test_cap_huge_amount_reverts_without_overflow` |
| burn 之后可铸空间恢复 | `test_cap_burn_frees_room` |
| 供应量永不超过 cap | `testFuzz_supply_never_exceeds_cap` |
| raiseCap 非 owner revert | `test_raiseCap_non_owner_reverts`（**RAISE-1**：deployer、多签直接调用、guardian、minter、其他人；正对照：timelock 可以） |
| timelock 提案 48h 之前执行 revert、之后成功 | `test_raiseCap_timelock_48h`（**RAISE-2**：提前 1 秒执行，断言 revert 数据正是 `TimelockUnexpectedOperationState(id, Ready)`；到期后执行成功并发出 `CapRaised`）；`test_raiseCap_only_multisig_can_propose`（非 proposer 不能排队、延迟 < 48h 不能排队） |
| raiseCap 用 ≤ cap 的值 revert | `test_raiseCap_not_above_reverts`、`test_raiseCap_through_timelock_rejects_lower_value` |
| lowerCap：guardian 即时成功 | `test_lowerCap_guardian_immediate`；owner 经 timelock 也可以：`test_lowerCap_owner_via_timelock` |
| lowerCap：非 guardian revert | `test_lowerCap_non_guardian_reverts` |
| lowerCap 用 ≥ cap 的值 revert | `test_lowerCap_not_below_reverts`（**LOWER-1**：guardian 和 owner 都不能用 lowerCap 调高；**LOWER-2**：等于 cap 也拒绝；正对照：真正调低可以） |
| 调低到 supply 以下 → mint 全部 revert，`isOverIssued()` 为 true | `test_lowerCap_below_supply_blocks_mint_and_flags_overissued`（还验证已有余额照常可转，调到 0 也允许） |
| minter 以外（含 owner、guardian）mint 都 revert | `test_only_minter_mints`（**MINT-1**，逐个角色命名；正对照：minter 可以） |
| Ownable2Step：accept 之前旧 owner 仍有效，pending owner 无权 | `test_ownable2step_pending_owner_has_no_power_before_accept` |
| renounce revert | `test_renounceOwnership_reverts` |
| setMinter / setCapGuardian 仅 owner、拒绝零地址、换人后旧人失权 | `test_setMinter_and_setCapGuardian_owner_only` |
| 构造参数校验 | `test_constructor_rejects_zero_cap_and_zero_roles` |
| 视图与版本 | `test_views_and_version`；事件 `test_mint_emits_Minted` |
| transferAndCall 的回调参数与拒绝路径 | `test_transferAndCall_calls_receiver_with_operator_from`、`test_transferAndCall_rejections`（EOA、错误返回值、接收方 revert 冒泡，且均回滚） |
| ERC20Permit | `test_permit` |
| **SP 集成**：SP 5.5.0 用 APNTsCapped 初始化 | `test_SP_initialised_with_APNTsCapped`（`SP.APNTS_TOKEN() == token`） |
| approve + `deposit` | `test_SP_deposit_approve_pull` |
| `transferAndCall` → `onTransferReceived` | `test_SP_deposit_transferAndCall_push`（另含：非 operator 推送被 SP 以 `Unauthorized` 拒绝且原样冒泡；非 APNTS_TOKEN 直接调 `onTransferReceived` 被拒） |
| `depositFor` | `test_SP_depositFor` |
| `withdraw` | `test_SP_withdraw` |
| `withdrawProtocolRevenue` | `test_SP_withdrawProtocolRevenue_after_ops`（两笔真实 op 产生收入；超出 buffer 1 wei 被拒；取到只剩 0.1 buffer） |
| 一笔 gasless balance-mode op 端到端 + 守恒 | `test_SP_gasless_balance_mode_op_conservation`：经规范 EntryPoint 的 `handleOps`，断言 operator Δ == protocolRevenue Δ == xPNTs 烧毁量（汇率 1:1）== 用户付出；op 期间 aPNTs 不移动、不增发 |

集成测试的每一步都断言 `APNTsCapped.balanceOf(SP) == totalTrackedBalance == operator 余额 + protocolRevenue`，且 `totalSupply <= cap`。集成测试复用 `contracts/test/helpers/V55TestFixtures.sol`、`UUPSDeployHelper.sol`，EntryPoint 用 `contracts/test/fixtures/` 里的规范 v0.7 运行时字节码（codehash `0x8db5ff69…fc58`），与 `SuperPaymasterV55Gas.t.sol` 相同；没有 import 任何其他 `*.t.sol`。

## 3. 变异测试

做法：先 `git add` 合约，逐个应用变异 → `forge test --match-path "contracts/test/tokens/APNTsCapped*"` → `git checkout -- contracts/src/tokens/APNTsCapped.sol` 还原（拆分测试文件之后又完整重跑了一遍，结果与下表一致；最后 `forge build` 重新生成产物，并确认其 creation bytecode 与 `abis/APNTsCapped.json` 相同）。未变异时 33/33 通过。SP 集成的 7 个测试在四个变异下都保持绿色 —— 它们不是这四条规则的判定者，规则由单元测试判定。关键断言都用低层调用 + 命名断言（`_mustRevert`），所以变异存活时报告的是**断言名**，而不是泛泛的 "call did not revert"。

| # | 变异 | 变红的指名断言 | 同时变红的其他测试 |
|---|---|---|---|
| M1 | 删除 `mint` 里的上限检查 | `test_cap_mint_one_wei_over_reverts`：**"CAP-1: mint to cap + 1 wei is rejected with CapExceeded"** | `test_cap_single_mint_one_wei_over_reverts`、`test_cap_huge_amount_reverts_without_overflow`（变成 panic 0x11）、`test_cap_burn_frees_room`、`test_lowerCap_below_supply_blocks_mint_and_flags_overissued`、`testFuzz_supply_never_exceeds_cap` —— 共 6 红 |
| M2 | `raiseCap` 去掉 `onlyOwner` | `test_raiseCap_non_owner_reverts`：**"RAISE-1: raiseCap by a non-owner (deployer/multisig/guardian/minter/other) is rejected"** | `test_ownable2step_pending_owner_has_no_power_before_accept` —— 共 2 红 |
| M3 | `lowerCap` 允许调高（`newCap >= old` → `newCap == old`） | `test_lowerCap_not_below_reverts`：**"LOWER-1: lowerCap cannot RAISE the cap (guardian, newCap > cap)"** | —— 共 1 红 |
| M4 | 允许 owner mint（`msg.sender != minter && msg.sender != owner()`） | `test_only_minter_mints`：**"MINT-1: mint by a non-minter is rejected: owner (timelock)"** | —— 共 1 红 |

## 4. 部署脚本与读回

`contracts/script/v3/DeployAPNTsCapped.s.sol`（继承 `DefaultArtifacts`，未修改该文件）：

1. **模式由 chainid 决定**：31337 → anvil（TEST_CAP_SEPOLIA）；11155111 → Sepolia（TEST_CAP_SEPOLIA）；1 / 10 → mainnet（必须 `APNTS_CAP`）；其他链拒绝。
2. **产物**：只接受元数据满足 compilationTarget == `contracts/src/tokens/APNTsCapped.sol`、optimizer runs == 500、`evmVersion == cancun`、`viaIR == true` 的产物（`out/APNTsCapped.sol/APNTsCapped.json` 或 `.default.json`）。不带后缀的产物会被最后一次编译覆盖（例如 `forge test --evm-version prague` 会在那里留下 Prague 字节码），所以这里显式检查 evmVersion；anvil 模式下部署的 timelock 同样先检查其产物是 cancun。部署后用 `DefaultArtifacts._codeEqArtifact` 比对运行时（屏蔽 immutable 区间）。
3. **timelock 前置检查**（非 anvil 必须提供 `TIMELOCK`）：有代码、`getMinDelay() == 172800`、多签持有 PROPOSER 和 CANCELLER、部署者不持有 `DEFAULT_ADMIN_ROLE`、executor 是多签或开放；非 anvil 还要求多签地址有代码。
4. **广播部分**：`vm.deployCode(产物, (name, symbol, cap, deployer, 多签, 多签))` → `transferOwnership(timelock)`。
5. **阶段 A 读回**：version / name / symbol / decimals / cap / minter / capGuardian / `totalSupply == 0` / `owner == deployer` / `pendingOwner == timelock`；打印多签要提交给 timelock 的 `schedule` 与 `execute` calldata（salt = `keccak256("APNTsCapped-1.0.0/acceptOwnership")`，delay = 172800）以及 operation id。
6. `APNTS_SIMULATE_ACCEPT=true`：在**模拟中**（prank，不广播）完成多签排队 → 提前 1 秒执行必须失败 → 48h 后执行 `acceptOwnership`，然后跑最终读回。
7. `verify(token, deployer)`：timelock 真正执行完之后在链上状态上跑最终读回。
8. **最终读回**：`owner == timelock`、`pendingOwner == 0`、`cap == 期望值`（主网再次打印与 300,000e18 的比较）、`issuanceCap == cap`、`minter == capGuardian == 多签`、`totalSupply <= cap`、`isOverIssued == false`；**负对照**（逐一比对 revert 数据，原因不对也算失败）：部署者 `mint` → `NotMinter`、`raiseCap` → `OwnableUnauthorizedAccount`、`lowerCap` → `NotCapGuardian`、`transferOwnership` → `OwnableUnauthorizedAccount`，timelock `renounceOwnership` → `RenounceDisabled`；**正对照**（快照内执行后回滚）：minter 正好铸到 cap、再多 1 wei 被拒、owner 调高、guardian 调低 —— 证明负对照失败的原因就是它声称的原因。

### 4.1 dry-run 结果（全部只在本地 anvil / anvil fork 上，未向任何公网广播）

| 场景 | 结果 |
|---|---|
| 全新 anvil（chainid 31337，脚本自己部署 GOV-1 形状的 timelock） | 部署 + 模拟 accept + 最终读回全部通过；随后用 `anvil_impersonateAccount` 以多签身份在**真实本地链状态**上排队 → 提前执行 revert → `evm_increaseTime 172800` → 执行，`verify()` 全部通过。token `0xe7f1…0512`，runtime 5,346 B，codehash `0x0087d9da…86a0` |
| Sepolia fork（区块 ≈11,692,6xx） | 拒绝用例：不给 `TIMELOCK` → 拒绝；`TIMELOCK=0x86C86c789EDc099801cc6a5F48334F1D67dC9564`（`config.sepolia.json` 里现有的 48h timelock）→ 拒绝，**因为多签不是它的 PROPOSER**；在测试链上设置 `APNTS_CAP` → 拒绝。在 fork 上部署 GOV-1 形状的 timelock 后：部署 + 模拟 accept + 真实 accept（冒充 Safe）+ `verify()` 全部通过，cap = 10,000,000e18（TEST VALUE） |
| 以太坊主网 fork（chainid 1，区块 ≈25,965,2xx，多签 Safe 在链上有代码） | 不给 `APNTS_CAP` → 拒绝；`APNTS_CAP=1,000,000e18` → 打印醒目 WARNING（仅模拟，未广播）；`APNTS_CAP=300000e18` → "cap matches the decided mainnet cap"，部署 + 模拟 accept + 真实 accept + `verify()` 全部通过；用错误的期望 cap 调 `verify()` → 以 `cap` 失败（读回本身的负对照） |
| 产物 evmVersion 检查的负对照 | 跑完 `forge test --evm-version prague` 之后（`TimelockController.default.json` 变成 prague）：脚本拒绝，"artifact is not a cancun (profile.default) build"；把 `APNTsCapped.json` 元数据里的 evmVersion 改成 prague：脚本拒绝，"no profile.default (cancun/runs 500/via_ir) artifact of APNTsCapped"。之后删除该产物、`forge build` 重新生成并确认回到 cancun |
| 未广播到公网的核对 | 事后用只读 RPC 查询：fork 上部署的 token / timelock 地址在真实 Sepolia 和主网上的 code size 都是 0（正对照：多签地址在两条链上都是 171 B） |

各次运行的 token codehash 不同（anvil `0x0087d9…`、Sepolia fork `0x25235e…`、主网 fork `0x782dc8…`），这是预期的：`ERC20Permit` 的 EIP-712 immutable 里有 chainid 和合约地址；脚本的字节码比对会屏蔽 immutable 区间。

## 5. 全量测试

| EVM | 结果 |
|---|---|
| cancun（`forge test`） | 126 个套件，**1600 通过 / 0 失败 / 49 跳过**（共 1649） |
| prague（`forge test --evm-version prague`） | 126 个套件，**1509 通过 / 0 失败 / 21 跳过**（共 1530） |

（拆分测试文件之前、之后各跑了一遍，两次数字相同。新增的 33 个测试在两种 EVM 下都执行并通过；两种 EVM 总数不同是仓库既有状况，与本交付无关。）

跑完 prague 之后重新执行了 `forge build`，并确认 `out/APNTsCapped.sol/APNTsCapped.json` 的元数据回到 cancun / runs 500 / via_ir。

## 6. 未决 / 需要注意

1. **GOV-1 timelock 尚未就位**：Sepolia 上现有的 `0x86C8…9564`（48h）里治理多签既不是 proposer 也不是 canceller，脚本会拒绝它。两条链都要先按 runbook M1 部署 / 配置"proposer = canceller = 多签、admin 放弃"的 48h timelock，再跑本脚本。
2. **runbook 第 1 步 ③④ 不在本交付范围**：`cancelAPNTsTokenChange` → `setAPNTsToken(APNTsCapped)`（ETA +7 天）→ 窗口内 `executeAPNTsTokenChange` 与 1:1 重新存入（`UpgradeToV5_5_0.executePendingAPNTs`）的 fork 演练仍待完成；本交付只保证 SP 5.5.0 用 APNTsCapped 作为 `APNTS_TOKEN` 时所有 aPNTs 路径正确。
3. `DefaultArtifacts.sol` 的解析器只检查 runs 和 compilationTarget，不检查 evmVersion。本脚本对自己用到的两个产物加了 cancun 检查，但没有改那个共用文件（任务范围只允许新增文件）；建议另开一项把 evmVersion 检查加进 `DefaultArtifacts`。
4. `transferAndCall` 对 EOA 接收方 revert、并冒泡接收方的 revert，这比 xPNTs 3.5.0 严格；SP 的推送存款路径不受影响（SP 是合约），但如果 SDK 有"对 EOA 用 transferAndCall"的用法需要改为普通 `transfer`。
5. 新增的公共 ABI（`abis/APNTsCapped.json`）需要通知 `repo:sdk`（新合约，不是已有接口的变更）。
6. **`docs/abi/*` 没有重新生成**：在本分支的基线（`668a343e`）上，`node scripts/gen-abi-docs.mjs --check` 本来就报 STALE（5.5.0 的 SuperPaymaster / v2 token 等改动一直没有重新生成）。重新生成会带来约 6,900 行与本交付无关的改动，所以没有并进这个提交；CI 的 `gen:abi-docs:check` 需要单独一次重新生成（届时会顺带包含 APNTsCapped）。
7. SP 集成测试里的 SuperPaymaster 仍是 runs=200 的 `registry-size` 编译结果（仓库里所有经 `UUPSDeployHelper` 的 SP 测试都如此，属既有状况），只有 APNTsCapped 按 profile.default 产物部署。
8. 主网 cap 300,000e18 仍须显式传入；如作者改变决定，只改传入值即可（脚本会打印 WARNING 提醒复核）。
