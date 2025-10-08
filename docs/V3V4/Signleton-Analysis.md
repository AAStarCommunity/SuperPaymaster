pimlicolabs/singleton-paymaster 是一个实现了 ERC-4337 标准的 Paymaster 合约，允许用户通过两种主要模式为交易支付 Gas 费用：ERC-20 模式和 Verifying（验证）模式，兼容 EntryPoint v0.6/v0.7/v0.8。

### 项目概述
该仓库的 Singleton Paymaster 设计用于增强用户操作（UserOperation）的灵活性和安全性。它支持：
- 用户用 ERC-20 Token 支付交易费用
- 用户用 Pimlico 余额支付
- 可选支持为 Sender 预先充值
- 可选限制 Bundler 白名单
- 管理员/所有者角色控制资金提取

Paymaster 是 permissioned 的，即用户需通过 Pimlico API 请求赞助，API 判定后由指定签名密钥签名，链上校验。

### 业务流程架构

#### ERC-20 模式
1. 用户发起 UserOperation，请求用指定的 ERC-20 Token 支付 Gas。
2. Pimlico API 提供实时兑换率报价。
3. 可以选择收取固定费用或设置剩余预充值收款地址（recipient）。
4. 合约在 `validatePaymasterUserOp` 阶段不收预充值（prefund），防止恶意用户跳过支付，若发生则从其 Pimlico 余额扣除。
5. 交易后在 `postOp` 阶段通过 on-chain 校验与 Token 转账结算。

#### Verifying（验证）模式
1. 用户发起 UserOperation，请求用 Pimlico 余额支付 Gas。
2. Pimlico API 校验余额及其它条件，返回签名。
3. 合约在 `validatePaymasterUserOp` 阶段校验签名和余额，预扣费用。
4. 交易后在 `postOp` 阶段完成结算，确保费用从 Pimlico 余额中扣除。

#### 数据结构和流程细节
- 两种模式在编码 paymasterAndData 字段时有所不同（长度、内容、签名等）。
- ERC-20 模式可选参数：constantFeePresent（是否固定费率）、recipientPresent（是否有剩余收款人）、preFundPresent（是否有预充值）。
- Verifying 模式则只涉及签名、有效期等基本参数。

#### 其它模式
从代码和文档来看，目前仅有 ERC-20 和 Verifying 两种核心模式。未发现其它支付模式，但合约架构允许灵活扩展，后续可能支持更多资产类型或业务逻辑。

---

**参考资料：**
- [README.md 业务架构说明](https://github.com/pimlicolabs/singleton-paymaster/blob/main/README.md)
- [主合约 SingletonPaymasterV7.sol](https://github.com/pimlicolabs/singleton-paymaster/blob/main/src/SingletonPaymasterV7.sol)
- [流程细节与测试实现](https://github.com/pimlicolabs/singleton-paymaster/blob/main/test/SingletonPaymasterV7.t.sol)

你的新方案需求如下：

1. **无链下签名**：即不依赖链下 API 或签名流程，链上直接判定资格；
2. **必须持有某 SBT**：用户必须有指定 SBT（不可转让 NFT）；
3. **账户必须有足够 PNTs（某 ERC20）**：账户余额需满足要求；
4. **验证通过直接赞助 gas**，无需链下签名；
5. **postOp 阶段提交记账请求到结算合约**：由结算合约累计记账，达到一定数量后批量链下结算；
6. **结算合约支持异步链下结算**。

你关心的问题：
- 现有合约 ERC20 模式是实时转账还是事后结算？
- 是否支持自定义 gas token，还是仅支持指定的 gas token？
- 如何评估和改造现有架构以支持你的新模式？

---

### 现有 ERC20 模式结算机制分析

根据代码和文档：

- **结算方式**：当前 ERC20 模式下，合约在 `postOp` 阶段通过 on-chain 校验与 Token 转账结算。即在用户操作完成后，Paymaster 合约会直接从用户账户扣除 ERC20 token 支付 gas，此为实时链上结算，而非事后链下。
- **Token 支持**：合约实现中支持自定义 ERC20 token，参数可指定，所以不是只支持特定 gas token。
- **链下签名流程**：当前合约强依赖链下 API 签名用于安全授权（permissioned paymaster），你的方案要去掉这部分。

参考代码片段：
````markdown name=README.md url=https://github.com/pimlicolabs/singleton-paymaster/blob/main/README.md
ERC-20 Mode:

- The user (sender) pays for gas with ERC-20 tokens.
- The Pimlico API provides the exchange rate quote.
- Optional ability to have a constant fee
- Optional ability to add a recipient to send unused pre-funds
...
**Note:** In ERC-20 mode, the paymaster does not take a prefund during the
`validatePaymasterUserOp` phase. This means that a malicious user can bypass the
payment in the `postOp` call. If a user does this, the userOperation will be
funded from their Pimlico balance.
````

### 你的方案与现有架构的对比与改造建议

#### 1. 去除链下签名

- 现有流程依赖链下签名（API），目的是防止恶意操作和权限控制。
- 你的方案要链上判定资格（SBT和ERC20余额），因此需要重写 `validatePaymasterUserOp`，直接在合约内通过 SBT 持有和 ERC20 余额判断，而不是验证签名。

#### 2. SBT 检查

- 新增合约参数，指定 SBT 合约地址。
- 在 `validatePaymasterUserOp` 内调用 SBT contract 的持有 check（如 `balanceOf` 或 `ownerOf`），不满足则拒绝赞助。

#### 3. ERC20 余额检查

- 现有合约已支持检测 ERC20 token 余额（用于支付 gas）。
- 可复用 ERC20 检查逻辑，但需确保非实时扣款（转账逻辑改为记账）。

#### 4. postOp 记账到结算合约

- 当前是实时转账，你需改为调用结算合约接口，传递用户、金额等信息，结算合约需实现累计逻辑和异步批量转账。
- 结算合约应可定制 ERC20 token，且批量结算由链下服务拉取和触发（用 keeper/oracle 或者多签操作）。

#### 5. 结算合约设计

- 需新建一个结算合约，负责累计记账和异步批量转账。
- 需要事件通知和定时批量转账功能（链下 watcher 监听并触发）。

#### 6. Token自定义

- 设计上可继续支持自定义 ERC20 token，只需在 Paymaster/结算合约参数中配置即可。

---

### 改造点总结

1. **重写验证流程**
   - 取消链下签名校验，链上 `validatePaymasterUserOp` 检查 SBT 和 ERC20 余额。
2. **SBT合约集成**
   - Paymaster合约需接入 SBT 合约接口。
3. **记账和结算逻辑**
   - 实时转账逻辑换为 postOp 调用结算合约，结算合约负责累计和异步结算。
4. **结算合约开发**
   - 新增独立结算合约，实现累计、批量结算、事件通知。
5. **安全性与权限**
   - SBT和ERC20余额门槛需合理设计，结算合约权限和清算流程需安全可靠。
6. **参数化token**
   - 支持自定义ERC20 Token，灵活配置。

---

### 风险点与建议

- 去除链下签名后，所有安全校验都依赖链上条件，注意逻辑漏洞。
- 结算合约资金安全与批量清算需严格控制，建议多签或定时 keeper。
- 批量结算延迟可能造成资金占用，需与业务场景权衡。

---

如需详细技术方案设计或代码改造建议，可进一步说明需求细节。

这是一个很有代表性的场景分析：
**ERC20实时转账 VS 链下批量结算**在Paymaster赞助Gas场景下的gas消耗区别。

---

### 1. ERC20实时转账模式

**流程**：
- 用户操作完成后，Paymaster合约在`postOp`阶段立即通过调用ERC20的`transferFrom`，把Gas费用从用户账户转给指定收款人或Treasury。
- 每笔用户操作都对应一次链上ERC20转账事件。

**gas成本**：
- 每次用户操作都需要一次ERC20转账（`transferFrom`），大约**40,000~60,000 gas**（具体与token实现有关）。
- 若涉及授权（approve）、余额判断、事件等，gas还会略有增加。
- 伴随每笔UserOperation都消耗一次转账gas，无法合并优化。

---

### 2. 链下批量结算模式

**流程**：
- Paymaster在`postOp`仅做“记账”，比如调用结算合约的`record()`函数，写入本次操作的费用记录，不做实际ERC20转账。
- 达到一定累计量后，链下服务发起批量结算，比如结算合约从多个用户扣费，统一转账到Treasury。
- 批量结算可一次性“合并”多个用户的费用，由链下触发（如多签/keeper等）。

**gas成本**：
- 单笔用户操作只需记账（例如写mapping、emit event），**一般 20,000~30,000 gas**。
- 实际ERC20转账操作由批量结算合约统一处理，可以合并多个用户金额，一笔转账gas消耗与单笔`transferFrom`接近，但每N笔操作只需一次转账，大幅降低均摊成本。

---

### 对比结论

| 模式         | 单笔操作gas消耗 | ERC20转账次数 | 批量优化效果 | 适合场景 |
| ------------ | -------------- | ------------- | ------------ | -------- |
| 实时转账     | 高（40k~60k）  | 每笔都转账    | 无           | 安全敏感，资金流转必须实时 |
| 链下批量结算 | 低（20k~30k）  | N笔合并一次   | 显著         | 批量运营、非实时资金结算 |

**节约效果**：
- 假设1000次UserOp，实时转账要消耗1000次ERC20转账gas（约4,000,000~6,000,000 gas）。
- 链下批量结算只需1000次记账（约2,000,000~3,000,000 gas）+ 1次批量转账（约40,000~60,000 gas）。
- 总体**节约约50%甚至更多gas**，实际按你的批量结算频率和记账复杂度而定。

---

### 其他注意

- 批量结算需要链下服务安全性，资金流动的实时性降低。
- 记账合约设计要防止恶意拖欠或积压。
- 资金归集延迟可能影响Treasury流动性。

---

**结论：**
链下批量结算可以显著减少gas消耗，特别是在高频、批量交易场景，节约效果非常明显。但需要权衡安全性和资金实时流转的需求。

你的质疑很正确！
在对比 ERC20 实时转账和链下批量结算的 gas 时，**不仅要计算 ERC20.transferFrom 的消耗，还要计算合约调用本身的基础 gas**，即 Paymaster 以及结算合约每次写入/调用的成本。

---

### 详细分解两种模式的合约调用gas

#### 1. ERC20 实时转账模式

实际流程：
- `postOp()`阶段，Paymaster合约被EntryPoint回调；
- Paymaster合约内部调用`ERC20.transferFrom(user, treasury, fee)`；
- 每次都包含：EntryPoint调用Paymaster（约8,000~20,000 gas），Paymaster内部逻辑（mapping查找、校验等，约5,000~10,000 gas），以及ERC20转账（约40,000~60,000 gas）。

**总消耗 = EntryPoint回调 + Paymaster内部处理 + ERC20转账**
- 总计约：**53,000 ~ 90,000 gas/次**

#### 2. 链下批量结算模式

实际流程：
- `postOp()`阶段，Paymaster合约被EntryPoint回调；
- Paymaster合约内部调用结算合约的`record()`（如mapping写入、event、累计金额等）；
- 结算合约批量结算时才真正调用`ERC20.transfer`，此时一次转账可覆盖多笔累计费用。

**单次消耗 = EntryPoint回调 + Paymaster内部处理 + 结算合约记账**
- 记账合约写mapping + emit event，一般约**20,000~30,000 gas/次**
- 批量结算时，结算合约+ERC20转账约40,000~60,000 gas，但可以合并N笔。

---

### 正确对比

| 模式         | 单笔操作总gas | 结算次数 | 批量优化效果 | 备注 |
| ------------ | ------------ | -------- | ------------ | ---- |
| 实时转账     | 53k~90k      | 每笔都结算 | 无           | Paymaster合约及ERC20全部每笔执行 |
| 批量结算     | 28k~50k      | N笔合并一次 | 显著         | Paymaster+结算合约每笔记账，结算时才ERC20转账 |

---

### 总结

- **链下批量结算的优势更大**，不仅节约ERC20转账的gas，也节约了Paymaster和结算合约的重复调用成本。
- 批量结算时，单笔操作gas消耗更低，总体节省量非常可观，尤其在高频场景下。
- 若批量阈值设置合理，整体gas可节约**50%以上**。

---

如果需要更精确的对比（根据具体Paymaster和结算合约代码），可以进一步给出代码片段或实际部署数据。

---
是的，你说得对：
**Paymaster 合约在 postOp 阶段调用结算合约的记账函数，这部分 gas 也计入了整体操作的 gas 费用。**

---

### 详细说明

1. **每笔 UserOperation 执行后，EntryPoint 会调用 Paymaster 的 postOp。**
2. **Paymaster 的 postOp 里会调用结算合约的记账方法**（如 record、addPending、logFee 等）。
3. **结算合约记账函数通常是写 mapping，emit event，甚至可能有逻辑检查**。这些都是链上存储操作，通常消耗在 20,000~30,000 gas/次（更复杂的记账逻辑会更高）。

#### 所以
- **每笔操作的总 gas = EntryPoint 调用 Paymaster + Paymaster 逻辑 + Paymaster 调用结算合约记账 + 结算合约内部逻辑**
- 如果记账合约设计合理，单次记账总消耗一般低于 ERC20 实时转账，但确实这部分也必须计入整体成本。

---

### 对比再次明确

| 模式         | Paymaster内部gas | 记账/转账合约gas | 总消耗 |
| ------------ | ---------------- | ---------------- | ------ |
| 实时转账     | Paymaster逻辑    | ERC20转账        | 较高   |
| 批量结算     | Paymaster逻辑    | 记账合约写入     | 较低   |

- 批量结算模式下，“记账合约写入”每笔都要消耗一次（虽然比ERC20转账低），但批量清算时才会发生一次真正的ERC20转账（覆盖N笔）。
- 实时转账则每一笔都要做ERC20转账，累计很高。

---

**结论：**
Paymaster 调用结算合约记账的 gas 是必须计入的，这部分 gas 虽然比 ERC20 实时转账低，但依然是链上存储成本，不容忽略。实际节约多少，还需结合你的具体记账逻辑和批量结算频率来评估。
当然可以。你的新模式是：
- 去掉链下签名、链下API
- 用户必须持有某SBT且PNT余额充足
- 验证后链上赞助Gas
- postOp只记账，批量异步结算

下面是针对 pimlicolabs/singleton-paymaster 仓库的重构建议，包括主要文件、核心改动点，以及示例代码片段。

---

## 主要重构工作

### 1. 去除链下签名相关逻辑
- 删除 validatePaymasterUserOp 里的外部签名校验流程
- 不再需要 paymasterAndData 里的签名字段和相关解析

### 2. 集成 SBT 校验
- 新增 SBT 合约地址参数
- 在 validatePaymasterUserOp 里校验 sender 是否持有 SBT

### 3. ERC20/PNT 余额校验
- 保留 ERC20 余额校验（支持自定义 token，建议用 PNT）
- 只做余额足够判断，不做实时扣款



### 4. postOp 记账逻辑
- 新增结算合约接口（如 recordGasFee(address user, uint256 fee)）
- 在 postOp 中调用结算合约记账，不做实时转账

### 5. 结算合约开发
- 新建 Settlement 合约，实现批量记账和批量清算（transfer）

---

## 推荐改动文件及说明

1. `src/SingletonPaymasterV7.sol` 或 `src/SingletonPaymasterV8.sol`
   - 这是主合约，建议基于最新版本改。

2. `src/base/BaseSingletonPaymaster.sol`
   - 公共逻辑抽象层，建议将签名相关和模式切换代码抽离/重构。

3. `src/interfaces/ISettle.sol`（新增）
   - Settlement合约接口定义。

4. `src/Settlement.sol`（新增）
   - 实现批量记账与批量结算。

---

## 示例代码片段

### SingletonPaymasterV8.sol（核心变更）

```solidity name=src/SingletonPaymasterV8.sol url=https://github.com/pimlicolabs/singleton-paymaster/blob/main/src/SingletonPaymasterV8.sol
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ISBT} from "./interfaces/ISBT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISettle} from "./interfaces/ISettle.sol";

contract SingletonPaymasterV8 {
    address public sbtContract;
    address public pntToken;
    address public settlementContract;

    constructor(address _sbt, address _pnt, address _settle) {
        sbtContract = _sbt;
        pntToken = _pnt;
        settlementContract = _settle;
    }

    function validatePaymasterUserOp(
        address sender,
        uint256 requiredPNT
    ) external view returns (bool) {
        // SBT持有校验
        require(ISBT(sbtContract).balanceOf(sender) > 0, "No SBT");

        // PNT余额校验
        require(IERC20(pntToken).balanceOf(sender) >= requiredPNT, "Insufficient PNT");

        return true;
    }

    function postOp(
        address sender,
        uint256 gasFee
    ) external {
        // 记账到结算合约
        ISettle(settlementContract).recordGasFee(sender, gasFee);
    }
}
```

### ISBT.sol（SBT接口）

```solidity name=src/interfaces/ISBT.sol
pragma solidity ^0.8.0;

interface ISBT {
    function balanceOf(address owner) external view returns (uint256);
}
```

### ISettle.sol（结算接口）

```solidity name=src/interfaces/ISettle.sol
pragma solidity ^0.8.0;

interface ISettle {
    function recordGasFee(address user, uint256 fee) external;
}
```

### Settlement.sol（结算合约主逻辑）

```solidity name=src/Settlement.sol
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract Settlement {
    address public pntToken;
    mapping(address => uint256) public pendingFees;

    constructor(address _pntToken) {
        pntToken = _pntToken;
    }

    function recordGasFee(address user, uint256 fee) external {
        pendingFees[user] += fee;
        // emit event for offchain watcher
        emit GasFeeRecorded(user, fee);
    }

    function batchSettle(address[] calldata users) external {
        for (uint256 i = 0; i < users.length; i++) {
            uint256 fee = pendingFees[users[i]];
            if (fee > 0) {
                IERC20(pntToken).transferFrom(users[i], address(this), fee);
                pendingFees[users[i]] = 0;
            }
        }
    }

    event GasFeeRecorded(address indexed user, uint256 fee);
}
```

---

## 其它优化建议

- **模块化设计**：接口抽象、参数可配置便于未来扩展。
- **安全性**：Settlement合约的批量结算建议用多签或keeper触发，防止单点风险。
- **事件设计**：记账、清算都应emit事件，方便链下同步和风控。
- **参数化Gas Token**：支持灵活配置Token，未来可扩展更多支付方式。
- **可升级合约设计**：如用UUPS或代理模式，方便后续升级业务逻辑。

---

如需更贴合你业务的代码骨架或者详细迁移方案，可以继续补充需求细节！



---

### SingletonPaymaster V7 vs V8 的主要区别

#### 1. 合约结构与接口升级

- **V8** 继承自 V7，主要增加了对 EIP-7702 的支持（见 V8 源码注释：`getHash is 7702 aware`），即在某些 userOp 校验和打包上兼容最新 Account Abstraction 相关提案。
- V7 面向 EntryPoint v0.7（PackedUserOperation），而 V8 面向 EntryPoint v0.8，并在打包和签名 hash 流程上有兼容和扩展。

#### 2. 功能区别

- V8 侧重于更强的兼容性和未来扩展（比如 EIP-7702），适合需要支持更高版本 EntryPoint 或新特性的场景。
- V7 则功能更纯粹，适配范围主要是 v0.7 的标准 ERC-4337 流程。

#### 3. 代码层面

- V8 代码主要在构造和 getHash、PackedUserOperation 相关部分与 V7 有区别。
- 其它核心逻辑（模式切换、ERC20、Verify、权限等）基本一致。

---

### 如果重构 V7 以适应你的新业务模式，建议如下：

#### 1. 去除链下签名流程
- 移除 validatePaymasterUserOp 中对签名的依赖，改为链上验证 SBT 和 ERC20 余额。

#### 2. 集成 SBT 验证
- 增加 SBT 合约地址存储和查询逻辑，validatePaymasterUserOp 内校验 sender 是否持有 SBT。

#### 3. ERC20 Token 可配置化
- 确认 ERC20 Token（PNT）可灵活配置为 gas token。
- ERC20 余额仅用来判断资格，实际扣款逻辑改为结算合约统一批量结算。

#### 4. 重构 postOp 记账
- postOp 不再做 transferFrom 实时扣款，仅调用结算合约（Settlement）记录 gas 赞助金额。
- Settlement 合约需单独开发，包含累计、批量结算功能。

#### 5. 精简模式切换
- 如果只保留你新的模式，可去除 mode 字段和相关分支逻辑。

#### 6. 安全与事件
- 加强事件设计，便于链下监控和异步结算。
- 检查批量结算流程资金安全。

---

### 建议改动文件及思路

#### 主要文件

- `src/SingletonPaymasterV7.sol`
- `src/base/BaseSingletonPaymaster.sol`
- 新增：`src/Settlement.sol`、`src/interfaces/ISettle.sol`、`src/interfaces/ISBT.sol`

#### 建议代码（伪代码/框架）

```solidity name=src/SingletonPaymasterV7.sol url=https://github.com/pimlicolabs/singleton-paymaster/blob/main/src/SingletonPaymasterV7.sol
pragma solidity ^0.8.26;

import {ISBT} from "./interfaces/ISBT.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISettle} from "./interfaces/ISettle.sol";

contract SingletonPaymasterV7 {
    address public sbtContract;
    address public pntToken;
    address public settlementContract;

    constructor(address _sbt, address _pnt, address _settle) {
        sbtContract = _sbt;
        pntToken = _pnt;
        settlementContract = _settle;
    }

    function validatePaymasterUserOp(address sender, uint256 minPNT) external view returns (bool) {
        require(ISBT(sbtContract).balanceOf(sender) > 0, "No SBT");
        require(IERC20(pntToken).balanceOf(sender) >= minPNT, "Insufficient PNT");
        return true;
    }

    function postOp(address sender, uint256 gasFee) external {
        ISettle(settlementContract).recordGasFee(sender, gasFee);
    }
}
```

---

**简要总结：**
- V8 主要为 EIP-7702 和更高 EntryPoint 版本扩展，V7 更简洁。
- 重构建议：去掉链下签名，集成 SBT、ERC20 校验，postOp只记账，批量清算，参数化 token，自定义事件。
- 主要改动在主合约、基础抽象合约和新增结算合约。

如需具体文件变更、代码实现细节，可进一步补充你的技术栈和业务细节！
