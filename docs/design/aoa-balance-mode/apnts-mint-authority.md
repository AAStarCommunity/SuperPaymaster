# aPNTs 铸币权：核实、fork 演练与主网前方案（2026-09-13）

作者的决定（经 DSR 转达）：**早期继续由部署 EOA 持有铸币权，但必须保证随时能转给 Safe**。本文核实 DSR 对 xPNTs 3.5.0 的源码解读，在 Sepolia fork 上演练"交给 Safe"的操作，评估风险，并列出主网前的几种方案供作者决定。

## 1. 源码与链上核实

对象是新 aPNTs `0xBb46…9883`：xPNTs 3.5.0 的 EIP-1167 克隆，实现合约 `0x9210…2502`，由工厂 `0x0E54…A244`（`xPNTsFactory-2.3.0-clone-optimized`）部署。

| 点 | 核实结果 | 证据 |
|---|---|---|
| mint 的权限 | `onlyFactoryOrOwner`：`msg.sender == FACTORY` 或 `communityOwner` 都能调用 | `contracts/src/tokens/xPNTsToken.sol:1051`、`:278–281` |
| 工厂的 owner | EOA `0xb560…df0E`，和 SP 的 owner、aPNTs 的 communityOwner 是同一个地址 | 链上 `FACTORY.owner()` |
| 工厂合约本身能不能 mint | **不能**。2.3.0 的源码（`27c08c03`）里没有任何调用 `token.mint` 的路径；它不是代理（EIP-1967 实现槽为 0，字节码里没有 upgradeTo 的 selector），也就没法事后加上这条路径。**但工厂仍然有 `onlyFactoryOrOwner` 的权限**：`propagateSuperPaymaster` 会调用 `token.setSuperPaymasterAddress`。在 fork 上验证过，renounce 之前这个调用会成功 | fork 正对照 |
| `issuanceCap` | 这个代币上是 0；`mint` 不检查它，只有 `isOverIssued()`（`:864`）会读；communityOwner 随时可以通过 `setIssuanceCap`（`:804`）修改。**它不构成限制** | 源码、链上读回 |
| `transferCommunityOwnership` | 一步完成，没有 accept 步骤（`:1150`）；地址填错无法挽回 | 源码 |
| `renounceFactory` | 只有 communityOwner 能调用；把 `FACTORY` 置 0，同时撤掉旧工厂的 autoApprovedSpender（`:692`） | 源码 |

## 2. Sepolia fork 演练（块 11692415，anvil fork + impersonate，没有广播）

Safe 用的是 Mycelium 社区的多签 `0x51eD…E114`，已核实它在 Sepolia 上存在，是 2-of-3。步骤的顺序很关键：**renounce 必须由当前的 communityOwner 来做**，所以先 renounce、再转移（反过来也行，但那样就要由 Safe 发起 renounce）。

| 步 | 操作 | 结果 |
|---|---|---|
| 对照 | EOA `mint` | 成功（证明演练开始前 EOA 确实是铸币者） |
| 对照 | 工厂地址调用 `mint` / `setSuperPaymasterAddress` | 都成功（renounce 之前的正对照） |
| A | EOA 调用 `renounceFactory()` | 成功 |
| B | EOA 调用 `transferCommunityOwnership(Safe)` | 成功 |
| 读回 | `communityOwner` = Safe；`FACTORY` = 0 | 通过 |
| 读回 | EOA `mint` → revert；工厂 `mint` → revert；**Safe `mint` → 成功** | 通过 |
| 读回 | 工厂 → `token.setSuperPaymasterAddress` → revert | 通过 |
| 负对照 | EOA 想把 owner 转回给自己 → revert | 通过 |
| 可逆性 | Safe 可以再继续转移（`transferCommunityOwnership` 仍然可用） | 通过 |

**结论：两笔交易就能把铸币权完全交给 Safe，任何时候都可以执行**（只要求 EOA 还是 communityOwner、Safe 已部署）。已作为 runbook 的"主网前"步骤写进 03 §6（第 7d 步）。

## 3. 风险评估（DSR 的判断成立，前提条件如下）

攻击链：铸币者被盗 → 无限铸 aPNTs → 以 operator 身份存入 SP → 赞助任意 op → SP 从 EntryPoint 押金里付 ETH，只收回没有价值的代币。

- **前提**：攻击者要控制一个持有 `PAYMASTER_SUPER` 角色的 operator。`deposit` 和 `onTransferReceived` 都要求存款人或目标地址有这个角色（`SuperPaymaster.sol:263–270`）；`depositFor` 允许**任何人**替已注册的 operator 存款。攻击者可以注册自己的社区，把自己社区的 xPNTs 铸给自己的账户，让这些用户以 BALANCE 模式付"自家币"，SP 则付出真实的 ETH。
- **损失上界**：SP 在 EntryPoint 的 ETH 押金，外加被持续充值的部分。**所以 aPNTs 的发行是 SP 的 ETH 偿付能力的信任根**，而不只是这个代币本身的问题。
- 5.5.0 没有改变这一点：aPNTs 仍是 operator 的存款资产，charge 以 aPNTs 计价。

## 4. 主网前的方案

| 方案 | 做法 | 能防住什么 | 改动量 | 评价 |
|---|---|---|---|---|
| (a) Safe + renounceFactory | 本文 §2 的两笔交易 | 单把私钥被盗；工厂地址的残余权限 | 两笔交易，不改代码 | **必须做**，但它只是治理层面的措施：Safe 的签名人被攻破，或者 Safe 自己误铸，仍然没有上限 |
| (b) 主网用新的 aPNTs，在 mint 里强制上限 | 在代币里加真正会执行的 `mint` 上限检查：`totalSupply + amount ≤ cap`；调高 cap 走 timelock（例如 48 h） | 把最坏情况的铸造量锁死在 cap 以内，从而把最坏损失锁在"cap 折算成 ETH"以内；调高上限要公示 | 小：需要一个新代币合约（或者给 v2 模板加上 cap 检查；但 aPNTs 是存款资产，不是社区代币，最好用独立的简单合约），外加测试。主网本来就要全新部署（CC-30 G1），没有迁移成本 | **推荐**。与 (a) 叠加 |
| (c) 铸币权交给售卖合约 | 只有收到付款（ETH/USDC）才按价格铸造 | 每一枚 aPNTs 都有真实付款对应，没有随意铸造 | 大：售卖合约、定价和预言机、退出路径、合规考虑 | 长期方向。主网首发不建议 |
| (d) SP 侧的上限 | 每个 operator 的存款上限，或者每段时间的存款速率上限，在 `deposit` 里检查（deposit 不在验证期，可以用时间戳）。全局的赞助速率上限**不能**放在验证期，因为 OP-011 禁止验证期使用 TIMESTAMP | 限制被盗铸币进入 SP 的速度，给人工响应（暂停 operator、急停）争取时间 | 中：SP 需要新的存储和参数，体积要重测（余量 1,661 B），还要改规范 | 可选的纵深防御；可以放到 5.5.x |

**推荐**：主网 = **(a) + (b)**。(a) 在 Sepolia 上随时可以执行，主网部署时直接由 Safe 持有；(b) 让新的主网 aPNTs 带上强制执行的上限，调高上限走 timelock。**(d) 作为 5.5.x 的可选项**（先把速率上限做成部署后可调的参数，参见"gas 常数改为治理参数"的评估）。**(c)** 列入长期路线。

**需要作者决定**：是否采用 (b)，以及 cap 的初始值（建议按运营预期与 SP 的 EntryPoint 押金规模来定，比如让 cap 折算成 ETH 不超过押金的若干倍）；(d) 是否进入 5.5.x。
