# 本地代码 vs 链上代码：Sepolia 一致性核对

> 测量日期 2026-09-06，本地树 `main @ d2fe85a7`，链 Sepolia（chainId 11155111，
> 区块高度 11,646,729）。**只测了 Sepolia。OP mainnet 一次都没碰。**

## 0. 方法与量具

对每个合约取链上 runtime bytecode（`cast code`）与本地 `out/**/…json` 的
`deployedBytecode.object` 逐字节比对；代理则先从 EIP-1967 槽
`0x360894…382bbc` 读出 implementation 再比。

**量具的正对照**：`LivenessRegistry` **逐字节完全相同**。这一格证明比对管线是通的
——否则「全都 DIFF」既可能是真差异，也可能是我把两边的编码/裁剪弄错了，单看一栏
分不开。

**一个被推翻的中间推理**（记下来，因为它差点被当成结论）：我一度以为
「metadata 尾部零差异 ⇒ 源码一致」。`foundry.toml:20` 是 `bytecode_hash = "none"`，
尾部只有 12 字节，这个推理**不成立**。真正承重的判据是下面的 immutable 覆盖测试。

## 1. 一致：差异 100% 落在 immutable 区间内

判据不是「差异很少」，而是**每一个不同的字节都落在该合约
`deployedBytecode.immutableReferences` 声明的区间里**——即差异只可能来自构造期
注入的地址，源码本身完全相同。

| 合约 | 链上地址 | 链上 `version()` | 差异 / 落在 immutable 外 |
|---|---|---|---|
| Registry (impl) | `0x9beD0F58…` | Registry-5.8.0 | 36 / **0** |
| SuperPaymaster (impl) | `0xe25f88db…` | SuperPaymaster-5.4.2 | 444 / **0** |
| MySBT | `0x4867B430…` | MySBT-3.2.0 | 200 / **0** |
| GTokenStaking | `0x472297B5…` | Staking-4.2.0 | 320 / **0** |
| LivenessRegistry | `0x02d841F7…` | LivenessRegistry-1.0.0 | 0（逐字节相同） |

两个代理的 EIP-1967 impl 槽与 `deployments/config.sepolia.json` **完全吻合**。

进一步解出 immutable 的实际取值，确认不只是「有个 immutable」而是**接线正确**：

- SuperPaymaster → entryPoint `0x0000000071727De2…`、registry `0xf5Bf37ca…`、
  priceFeed `0x694AA176…`、以及 UUPS 的 `__self`
- MySBT → gToken / staking / registry 全对
- GTokenStaking → gToken / registry 全对

## 2. 链上落后于本地：3 个「同版本号、代码不同」

| 合约 | 链上 / 本地（去 metadata） | selector 集合 | `version()` |
|---|---|---|---|
| DVTValidator | 6314 / 6158 B（−156） | **完全相同** | 两边 0.6.0 |
| PaymasterV4 impl | 10480 / 10429 B（−51） | **完全相同** | 两边 4.5.1 |
| ReputationSystem | 7032 / 6981 B（−51） | **完全相同** | 两边 0.3.2 |

ABI 没变（selector 集合一致），所以 SDK 不会炸。但**版本号说它们一样，字节码说不
一样**——`version()` 在这三个合约上不能用来判断链上跑的是哪一版。源码最后改动分别
在 2026-07-05 / 07-08 / 05-10。

## 3. 最需要处理的一条：`xPNTsFactory` 有两个部署，SP 指向旧的

| config key | 地址 | runtime | selector 数 | `version()` |
|---|---|---|---|---|
| `xPNTsFactory` | `0x67422d2e…` | 5221 B | 46 | `xPNTsFactory-2.3.0-clone-optimized` |
| `xPNTsFactoryCC28` | `0x9f426568…` | 6802 B | **57** | `xPNTsFactory-2.3.0-clone-optimized` |

`0x9f426568…` 与**本地源码一致**（80 处差异全在 immutable 内）。两者
`version()` **字符串完全相同**。

而链上实测：

```
SuperPaymaster.xpntsFactory() = 0x67422d2e44a33c8dA99b3b776841bF316bD209a2   ← 旧的那个
```

也就是说热路径上 `configureOperator`（`SuperPaymaster.sol:292`）用来校验社区代币
的那个工厂，比本地源码**少 11 个函数、少 1581 字节**，而版本号一模一样。CC-28 的
`isOverIssued` 那套在链上的**权威工厂里没有**。

> 这条不是本设计要解决的问题，但它和信用开关落在同一条 `configureOperator` 路径上，
> 所以任何改动这条路径的 PR 都必须先确认自己是对着哪一个工厂在推理。

## 4. 已知且刻意的

BLSAggregator 链上 4.11.0（`0xEaeC2F51…`）/ 本地 4.12.0，本地多 4 个 selector。
这正是 DSR 冻结期的预期状态（不部署 4.12），与
`abis/BLSAggregator-4.11.0.deployed.json` 记录的 4 个函数差额吻合。

## 5. 没查的部分

诚实枚举，避免这份表被当成「全链已核」：

- **OP mainnet 完全没测**
- 实例代币（aPNTs / PNTs / GToken）未比
- `x402Facilitator`、`microPaymentChannel` 未比
- 三个 ERC-8004 registry（identity / reputation / validation）未比
- 只比了 runtime bytecode 与 `version()`，**没有**核对存储变量的实际取值（除了上面
  明确列出的 impl 槽、`xpntsFactory`、`APNTS_TOKEN`、`pendingAPNTsToken`）
