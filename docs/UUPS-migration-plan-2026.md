# SuperPaymaster UUPS 升级改造方案 (2026版)

**分支**: `feature/uups-migration`
**状态**: 设计阶段
**前置**: V4.3 Token Management 已合并 (PR #46)

---

## 设计原则与前提

基于当前的工程与业务反馈，我们确立本次架构升级的 6 大核心刚性原则：
1. **零历史包袱部署**：无需考虑老版本的线上存量用户数据迁移，即全新部署上线。
2. **面向未来（EIP-8141 / Native AA）兼容**：未来的 Native AA 将原生地把普通 EOA 升级为具备 AA 能力的账户，我们在保留目前 Gas 赞助服务（基于 EIP-4337）的同时，需要支持这层新底座带来的**跨环境微支付支持**。
3. **接口零感替换**：最高优先级保障原有的主要智能合约接口（如 `deposit`, `postOp`, `configureOperator` 等）签名不变。如果确有不可抗力的入口变动，必须被详细记录以便 SDK 同步。
4. **Gas 效率只增不降**：核心代付逻辑的单用户总 Gas 开销必须 **不超过** 现有版本的耗费。
5. **原有依赖图谱稳定性**：不破坏多个合约间的依赖关系与角色流转，所有现存业务逻辑内核保持 100% 相同。
6. **核心与边缘剥离**：非"强资产/状态托管"的纯工具性质合约（如只执行密码学计算的 `BLSValidator`）无需采取沉重的 UUPS 的模式，仅通过 Registry/SuperPaymaster 的指针管理进行插拔。

---

## 1. 核心与工具模块的隔离与 UUPS 支持

**A. 需升级为 UUPS 的"核心引擎"**：
- **`SuperPaymaster`**: 作为资金的进出枢纽与所有第三方前端、SDK 交互的"不动点"（Immutable Endpoint）。如果该地址改变，前端与 EntryPoint 的配置将全部作废。因此，此组件**必须**挂载在唯一代理之后，并通过 UUPS 自身实现逻辑的无缝插拔。
- **`Registry`**: 作为全系统的身份名册、声誉评分以及参数中枢，它的挂载可以保证整个系统的长期身份溯源和配置连续性，必须做 UUPS。

**B. 无需 UUPS，依赖指针更迭的"工具合约"**：
- **`BLSValidator` / `BLSAggregator`**：纯密码验证或数据归集逻辑，无链上状态包袱。当有了新的验证算法（比如更高效的 BLS12-381 实现），仅需在 Registry 里执行 `setBLSValidator(newAddress)` 即可。
- **工厂与资产合约 (`xPNTsFactory` 及 `xPNTsToken` 等)**：保持原来的生产机制，不需要加入不必要的代理开销。

> **变动记录（需同步至 SDK 和部署代码）**：
> 1. `SuperPaymaster` 和 `Registry` 的 `constructor` 会完全被废除，改为 `initialize(...)` 函数，使用 `@openzeppelin/contracts-upgradeable` 替代原有静态库。
> 2. `ethers` / `viem` 等前端 SDK 的合约地址连接层完全无需更改。仅在项目仓库内部的部署脚本（`DeployScript.s.sol` / bash scripts）中，部署形式由普通的 `new` 变更为拉起 `ERC1967Proxy` 再进行初始化的步骤。

---

## 2. Storage Packing：抵消 UUPS Gas 损耗

由于全新部署，我们可以随心所欲地调整合约内的存储（Storage）布局。
引入 UUPS 代理将让外部合约呼叫额外付出 `DELEGATECALL` 约 **2600 Gas**。为了确保符合"Gas 不能更贵"的要求：
在 `validatePaymasterUserOp` 这个超高频调用方法中，原先对内存状态读取极为松散。
- 我们将把：`OperatorConfig`（包括其余额、配置状态等属性）以及当前操作这个用户独有的状态字典（包含拦截状态 `isBlocked` 和冷却时间 `lastTimestamp`），在底层压缩合并到极少量的存储槽（Slot）中。
- 大幅省去原来不必要的 `SLOAD` 和 `SSTORE`。一个冗余的 Cold SLOAD 消耗 2100 Gas。仅消除两次跨槽读取，即可**完全抵消并反赚** UUPS 带来的 Gas 损耗，使执行端感受到"比之前还要便宜"。

---

## 3. 解耦执行流：抽取记账内核

为实现微支付支持、跨环境扩展，以及不远的将来对接 EIP-8141（Native AA），我们需要将**核心账单结算器**从 EIP-4337 的繁杂参数中提取出来。

当前 `postOp` 内存在着大量的硬编码（比如计算以太坊相对 Token 的汇率与实际发生的 Gas Cost 的换算），我们要将其进行"纯函数化下沉"：

**核心抽象动作**：
在 `SuperPaymaster` 内部剥离出一个受到严格权限隔离的基础内部函数 `_consumeCredit_pure`:
```solidity
// 该函数脱离了 EIP-4337 UserOp 的限制，只关心"是谁、通过哪个算子、花了多少纯粹价值"
function _consumeCredit_pure(
    address user,
    address operator,
    uint256 usdAmountEquivalent
) internal returns (bool success) {
    // 1. 验证可用额度与注册表
    // 2. 扣除算子抵押的等值 aPNTs
    // 3. 将对应 Debt 记录到 xPNTsToken
}
```

**外延入口**：
基于这个干净牢固的核心基石，对外提供多种变体 Wrapper 包装：
1. **原兼容层（EIP-4337 原生）**：原本的 `validatePaymasterUserOp` 与 `postOp` 完全照旧工作，解析 UserOp 中的 Gas 限额后，依然向底层呼叫 `_consumeCredit_pure`。保证依赖关系与原逻辑零变化。
2. **微支付入口（Micro-payment）**：新增对外方法（比如 `chargeMicroPayment(...)`）。面向外部生态应用（比如特定的 NFT 发售或链上高频调用），提供用户的 EIP-712 签名，系统就可以使用这一套额度引擎提供支付担保。
3. **EIP-8141 原生入口**：协议更新后，外部 EOA 可提交原生支持的新格式，我们的智能合约只需暴露出一个适配 EIP-8141 的新验证 Hook 同样对接底座，就可无缝过渡。

---

## 4. 各合约改造细则

### 4.1 核心层：SuperPaymaster 升级流程（UUPS + Storage Packing）
**定位**：EIP-4337 入口及微支付信贷结算中枢。
**变动幅度**：核心逻辑不改，存储与初始化需大修。
- **改动步骤**：
  1. **引入基础库**：废除现有的 `Ownable.sol` 等引用，全部替换为 `@openzeppelin/contracts-upgradeable` 家族等价物（如 `OwnableUpgradeable`），并继承 `UUPSUpgradeable`。
  2. **构造函数改造**：将 `BasePaymaster` 及 `SuperPaymaster` 中针对不可变变量（`immutable`，如 `entryPoint`）的部分保留在裸 `constructor` 内，并加上 `_disableInitializers()` 保护代理。业务相关的初始设置全部迁移至带 `@initializer` 修饰的 `initialize(...)` 函数。
  3. **存储压缩（Storage Packing）重构**：重新审视 `ISuperPaymaster.OperatorConfig` 与 `userOpState` 的存储排列。将用户的阻断状态（`isBlocked`）与最后访问时间戳（`lastTimestamp`）紧凑打包，从而在 `validatePaymasterUserOp` 中实现单次或最少的 `SLOAD` 查询。
  4. **抽取挂账内核**：编写仅限内部调用的纯粹算账函数 `_consumeCredit_pure()`，承接原本嵌在 `postOp` 里的代扣逻辑。原本的 `postOp` 改为先读取实际耗费，再投喂给这层挂账内核。
  5. **权限强化**：重写 `_authorizeUpgrade`，严格限制只有提权后的 Owner 才能执行升级。

### 4.2 核心层：Registry 升级流程（UUPS）
**定位**：系统的全局名册表，维系着所有的社区关系、声望点数和权限配置。
**变动幅度**：业务零变动，初始化重写。
- **改动步骤**：
  1. 剥离初始化相关的状态如 `roleConfigs`、`creditTierConfig` 和 `_initRole` 至独立的 `initialize()` 方法。
  2. 确保持续迭代中增加变量时，必须在合约尾部采用 `uint256[50] private __gap;` 以避免产生被引用的存储碰撞。

### 4.3 边缘层：工具类与预言机合约处理（非 UUPS 化）
**定位**：支持类的子依赖，如 `BLSValidator`、`xPNTsFactory`、以及具体生产出来的子币 `xPNTsToken`。
**变动幅度**：极低。维持原部署与运行态。
- **处理策略**：坚决不套用 UUPS 代理模式，只在核心合约的配置变量中对其指针地址做路由替换，完全保留原来对接口调用的最高效率。

### 4.4 整体部署与关联链变动分析
**部署依赖拓扑影响分析**：
1. 原本的依赖流（例如 `Registry` 创建然后赋权 `SuperPaymaster`）没有本质变化。
2. Forge 脚本层需要摒弃原有的 `new Contract()` 黑盒，而是：部署 Implementation -> 部署 `ERC1967Proxy` 及 Payload 执行 `initialize` -> 生成不可变代理地址。

---

## 结论

本次设计符合所有的硬性规定。由于不再考虑数据兼容迁移：
1. 我们建立了一条崭新干净、模块化极强的 UUPS 结构链。
2. Storage 的高强度压缩抹平了哪怕 1 Wei 的效率损耗。
3. `_consumeCredit_pure` 的抽象分离完成了协议层面对未来不可知（Native AA / 微支付）请求的普适性支持。
