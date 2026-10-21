# GOV-4 (b) 设计草稿：强制上限的 aPNTs（2026-09-13，草稿，未实现、未部署）

作者倾向的方向（经 DSR 转达）：**设初始铸币上限；调高要经治理多签并等 48h timelock；由 reputation system 做动态监测**。本稿只给设计、测试清单和读回清单。

> **更新（2026-09-13，作者已定，经 DSR）**：两条链都用 `APNTsCapped`；minter 和 capGuardian 都是治理多签 `0x51eD…E114`；**主网初始上限 300,000e18**，Sepolia 用标明为测试值的上限。§5 的 1–4 已经有答案。实现作为独立小交付物进行（`apnts-capped-deliverable.md`），**仍然不部署**。

## 1. 为什么不直接用 xPNTs 3.5.0

- `mint` 是 `onlyFactoryOrOwner`，**不检查 `issuanceCap`**（`xPNTsToken.sol:1051`）；`issuanceCap` 只是一个观测标志（`:864`），communityOwner 随时能改（`:804`）。
- 它带着社区代币的一整套机制（factory、autoApprovedSpenders、SP 相关权限、汇率），而 aPNTs 在 SP 里的角色只是 **operator 的存款资产**：SP 对它只调用标准的 `transferFrom` / `transfer`（`SuperPaymaster.sol:768`、`:813`、`:837`、`:859`），外加 ERC-1363 风格 `transferAndCall` 的回调 `onTransferReceived`（`:793`）。
- 因此推荐做成一个**独立、不可升级的小合约**（`APNTsCapped`），而不是改社区代币模板。不可升级，是为了让上限规则不能通过升级绕开。

## 2. 合约设计（`APNTsCapped`）

**继承**：OZ v5 的 `ERC20`（+ 可选的 `ERC20Permit`）+ `Ownable2Step`；自己实现 `transferAndCall`，与 SP 的 `onTransferReceived(address operator, address from, uint256 value, bytes data)` 签名一致（和 xPNTs 3.5.0 的调用方式相同，`xPNTsToken.sol:321–328`）。

**角色**：

| 角色 | 持有者（建议） | 权限 |
|---|---|---|
| `owner`（Ownable2Step） | GOV-1 的 48h TimelockController（proposer 是 AAStar 社区治理多签） | `raiseCap(newCap)`（只能调高），也就是说**调高必须经治理多签提案并公示 48h**；更换 `minter` 和 `capGuardian` |
| `minter` | **治理多签 `0x51eD…E114`**（作者已定；以后改用售卖合约时，由多签把 minter 转过去） | `mint(to, amount)`，**必须满足 `totalSupply() + amount ≤ cap`** |
| `capGuardian` | **治理多签 `0x51eD…E114`**（作者已定，不经 timelock） | `lowerCap(newCap)`（只能调低，**即时生效**，属于安全方向） |

**状态与规则**：
- `cap`（uint256）：构造时设初始值（作者给数），并要求 `cap ≥ totalSupply`（初始 supply 为 0，或者等于构造时的初始铸造量）。
- `mint`：`if (totalSupply() + amount > cap) revert CapExceeded(...)`。**这是强制执行的上限。**
- `raiseCap(newCap)`：`onlyOwner`，要求 `newCap > cap`；由于 owner 是 timelock，调高天然要公示 48h。
- `lowerCap(newCap)`：`msg.sender == capGuardian || msg.sender == owner`，要求 `newCap < cap`，即时生效。可以低于当前 `totalSupply`，效果是停止所有新铸造（已发行的不受影响）。
- 持有人可以 `burn` 自己的余额（supply 随之下降，可铸空间随之恢复）；**没有**任何第三方 burn 或 transfer 的特权，没有 factory，没有 autoApprovedSpender，没有 SP 特权。

**与现有观测接口的兼容**（DVT 规则③ 和 reputation 用的是 `IxPNTsToken` 的视图）：
- `issuanceCap()` 返回 `cap`（这回是真正会执行的上限）；
- `isOverIssued()` 返回 `totalSupply() > cap`：正常情况下为 false，只有在 `lowerCap` 调到低于现有供应量之后才会为 true，正好作为信号；
- 事件 `CapRaised(old, new)`、`CapLowered(old, new, by)`、`Minted(to, amount, supplyAfter, cap)`，供 reputation system 做实时展示和动态分析（这属于 reputation system 的范围，不进 SP 5.5.x）。

**上限带来的效果**：aPNTs 的最大可能供应量 = `cap`，于是"铸币者被盗 → 无限铸造 → 耗尽 SP 的 ETH 押金"这条攻击链的最坏损失被锁在 cap 折算成 ETH 的范围内；而且任何调高都会提前 48h 公开，监测系统和社区有时间反应。

## 3. 测试清单（实现时一起写）

- **上限**：mint 到正好等于 cap 成功；超出 1 wei 以 `CapExceeded` revert；burn 之后可铸空间恢复。
- **调高**：非 owner 调用 revert；owner（timelock）的提案在 48h 之前执行会 revert，之后成功；`raiseCap` 用不大于当前 cap 的值会 revert。
- **调低**：capGuardian 即时成功；非 guardian 调用 revert；`lowerCap` 用不小于当前 cap 的值会 revert；调低到 supply 以下之后 mint 全部 revert，`isOverIssued()` 为 true。
- **角色**：minter 以外的地址（包括 owner 和 guardian）调用 mint 都 revert；Ownable2Step 的转移（accept 之前旧 owner 仍然有效）。
- **与 SP 的集成**（SP 5.5.0，规范 EntryPoint）：approve + `deposit`、`transferAndCall` → `onTransferReceived`、`depositFor`、`withdraw`、`withdrawProtocolRevenue` 都正常；一笔 gasless op 端到端通过，operator 的余额变化和 revenue 满足守恒。
- **变异**：去掉 mint 里的上限检查、`raiseCap` 去掉 onlyOwner、`lowerCap` 允许调高，各自都要让指名断言变红。

## 4. 部署与读回（写进 runbook 的主网部署步骤）

部署（主网全新部署时，SP 在 initialize 时直接传入这个 token，不走 SP 的 7 天 aPNTs 切换）→ 读回并断言：
- `cap == 作者给的初始值`；`totalSupply ≤ cap`；
- `owner() == timelock`（Ownable2Step 的 accept 已完成）；`minter`、`capGuardian` 与预期一致；
- `SP.APNTS_TOKEN() == token`；
- 负对照：部署 EOA 调 mint、raiseCap、lowerCap 都 revert。

## 5. 作者的决定（2026-09-13，经 DSR；取代本节原来的待决事项）

1. 初始 `cap`：**主网 300,000e18**（DSR 按作者口径计算，见 03 §10.7b GOV-4）；Sepolia 用标明为测试值的上限（`TEST_CAP_SEPOLIA`）。
2. `minter`：治理多签 `0x51eD…E114`。
3. `capGuardian`：治理多签 `0x51eD…E114`。
4. **Sepolia 也换成 `APNTsCapped`，两条链保持一致**（原来提议"Sepolia 维持 `0xBb46`"的方案作废）；`0xBb46` 弃用，按 7d 交给多签后闲置；runbook 第 1 步已按此改写（03 §6）。
