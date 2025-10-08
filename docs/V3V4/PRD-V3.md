# SuperPaymasterV3 产品需求文档 (PRD)

- **版本**: 0.1 (草案)
- **目标**: 为开发团队提供 SuperPaymasterV3 的产品功能、技术需求和实现流程的清晰指引。

---

## 1. 背景与目标

### 1.1. 项目背景
当前以太坊生态的账户抽象标准 ERC-4337 依赖于链下 Paymaster 服务和 Bundler 来实现 Gas 赞助，此模式存在中心化、延迟和运营成本等问题。同时，随着 RIP-7560（Layer2原生支持账户抽象/合约账户）、EIP-7702 (EOA代理账户抽象)、EIP-7701（Layer1原生支持账户抽象/合约账户） 等协议的演进，Bundler 的角色可能被削弱乃至融合到节点内功能，但 Paymaster 的需求将持续存在。

### 1.2. 产品目标
SuperPaymasterV3 旨在构建一个纯链上、面向资产、兼容未来的 Gas 赞助协议，解决现有方案的痛点。

- **核心目标**: 提供一个更低成本、更高效、更去中心化的 Gas 赞助基础设施。
- **用户目标**: 为 DApp 用户（包括 EOA 和合约账户）提供近乎零感知的 Gas 赞助体验。
- **工程目标**: 构建一个模块化、可扩展、逐步去中心化的健壮系统。

## 2. 核心概念 (Glossary)

- **AOC (All-On-Chain)**: 全链上。所有核心验证逻辑均在智能合约中执行，无需依赖链下签名或验证服务。
- **AOA (Asset-Oriented Abstraction)**: 面向资产抽象。以用户持有的链上资产（如 NFT, SBT, ERC20 Token）作为 Gas 赞助的资格凭证和结算单位。
- **DVT (Decentralized Validator Technology)**: 去中心化验证者技术。此处指代负责监控和批量处理链上结算的去中心化网络节点。
- **Points 合约**: 链上积分/信用合约，用于记录不同社区发行的PNTs以及用户的余额，是 AOA 验证的核心组件之一。
- **Settlement 合约**: 链上结算合约，用于记录待偿还的 Gas 债务。
- **SuperPaymaster（Market）合约**: 链上聚合合约，用于建立基于多种社区Token和多样性信用+报价的Gas 赞助市场。
- **Paymaster 合约**: 链上Gas sponsor合约，ERC-4337标准要求，用于向Entrypoint存入ETH和为用户代付Gas 赞助。


## 3. 功能需求 (Features)
流程假设：作为最终用户，已经获得了合约账户，并且持有约定的SBT，账户内有一定的约定的ERC-20 Token余额。

### 3.1. 无许可发行流程
发行加油卡和积分：SBT/ERC-20 Gas Token流程
任何社区可以从Github获得开源代码，建立自己的前端应用，基于开源公开合约，发行自己的加油卡和积分。
基于ERC-4337合约和开源Paymaster合约模板,发布自己的链上Paymaster合约，存入ETH到Entrypoint，开始提供支持自己的社区Gas Token。

### 3.2. 加入链上市场流程
SuperPaymaster合约提供一个聚合和信用管理，以及成交结算机制。
包括提供Paymaster自己Stake ETH到Entrypoint，以及Stake服务方资产，使用SuperPaymaster 余额支付。
SuperPaymaster服务机制基于去中心化合约和去中心化节点，提供Paymaster聚合机制，方便用户、开发者和DApp找到对各种社区Token、各种信用、各种价格等多样性的Gas Sponsor市场。
SuperPaymaster合约开源开放，任何社区和个人都可以自行部署。内嵌Stake 机制，可以更简单的快速部署自己的社区赞助服务，支持社区Gas Token的发行和管理。
SuperPaymaster服务机制为社区提供一步部署自己的Paymaster合约的开源前端和Paymaster合约模板。

- 公开报价，被动积累信用
- 合约计算，智能返回最佳路由
- 提供去中心化结算机制（DNT，去中心化节点，包括结算在内的很多服务）

### 3.3. 核心 Gas 赞助流程

- **【F-01】链上资格验证**: Paymaster 合约必须能够在 `validatePaymasterUserOp` 函数中，通过读取其他合约状态（Points 合约、NFT 合约等）来完成对用户 Gas 赞助资格的验证。
- **【F-02】无链下签名支持**: 协议必须支持在 `UserOperation` 中不包含 `paymasterSignature` 的情况下，完成 Gas 赞助。需要兼容Entrypoint 0.6, 0.7, 0.8.
- **【F-03】债务记录**: 验证通过后，Paymaster 合约必须在 Settlement 合约中记录一笔待结算的债务，包含用户地址、赞助金额等关键信息。
- **【F-04】支持空 Gas Price**: 系统需能处理 `gasPrice` 字段为空或零的 `UserOperation`，以适配非标准 Bundler 或未来原生 AA 交易。

### 3.4. 异步结算机制

- **【F-05】批量结算**: 系统需支持将多笔待结算的债务聚合成一笔交易，在链上进行批量结算，以节省 Gas 成本。
- **【F-06】去中心化触发**: 批量结算交易的触发应是去中心化和无需许可的。DVT 网络的任何节点都可以竞争打包和提交结算交易。

### 3.5. 信用与声誉系统

- **【F-07】信用额度**: Points 合约需实现一个信用额度，允许用户在一定额度内“欠费”（余额为负）。
- **【F-08】信用约束**: 当用户的欠费超过其信用额度时，Paymaster 合约必须能拒绝其新的 Gas 赞助请求。

## 4. 系统架构与流程

### 4.1. 组件架构

1.  **用户端 (Client)**: 负责构建 `UserOperation`。
2.  **EntryPoint (ERC-4337)**: 链上交易入口点合约。
3.  **SuperPaymaster**:聚合市场。
3.  **Paymaster 合约 (On-Chain)**: 实现赞助。 `validatePaymasterUserOp`，核心验证逻辑所在地。
4.  **Settlement 合约 (On-Chain)**: 债务账本。
5.  **Points 合约 (On-Chain)**: 用户信用记录。
6.  **DVT 网络 (Off-Chain)**: 结算触发器。

### 4.2. 详细工作流程

**流程 A: 无许可发行**
1. 基于开源SBT和PNTs模板和前端框架，可以自部署或使用AAStar免费服务，发行自己的社区SBT（身份识别和信用积累）和积分（默认锚定aPNTs）
2. 了解预授权和结算合约以及结算流程
- 采用服务承诺-发行代币-用户获取代币-履行承诺-Burn代币
- 因为代币代表的服务承诺是有期限的，并且发行组织尽力缩短履约周期，从而避免组织存续造成的可能损失。因此Burn代币再新发行比持续有效更可靠。
- 所有代币预授权公共结算合约进行结算，结算合约采用授权和执行分离的机制，每次用户使用了某社区的代币如bPNTs支付gas，则结算合约只是记录此结构化账单（从此用户账户余额扣除几个bPNTs）
- 发行汇率，以个社区自行决定，例如c社区为激励社区参与活动，提供积分激励，参加一次记录一个cPNTs，20次后可以兑换一次住宿（这个价格社区自行调整）。而a社区提供gas赞助服务，购买价格是0.03U一积分，2-3积分价格提供一次gas代付服务（gas是波动的，平均价格）。则a和c社区汇率需要自行建立pool来确定，如果没有pool，则需要从公共pool兑换。

**流程 B: 加入链上市场**
1. 基于开源模板，发布自己的Paymaster链上合约，绑定Sponsor策略。
2. 选择自己的Sponsor机制：自行存入ETH或者使用aPNTs（AAStar社区服务承诺代币，基于Layer2 的平均gas fee 0.02-0.05+服务费（每次约0.02-0.03），提供服务承诺，每2-3个aPNTs，提供一次Gas Sponsor服务。一定程度上隔绝了gas 波动。
3. 到SuperPaymaster注册，提交自己的SBT和PNTs合约地址
4. 如果选择策略2（stake aPNTs），则需要需要购买并存入到SuperPaymaster合约内，会有详细的结算记录。

**流程 C: 用户交易与 Gas 赞助**

1.  用户构建 `UserOperation`，提供赞助策略查询SuperPaymasterV3合，约获得一个paymaster合约地址，将 `paymaster` 字段设置为此地址，`paymasterSignature` 留空。
2.  Bundler 将 `UserOperation` 提交给 `EntryPoint`。
3.  `EntryPoint` 调用 `Paymaster合约.validatePaymasterUserOp()`。
4.  `Paymaster合约` 执行 AOA 验证：
    a.  检查用户的 NFT/SBT 凭证。
    b.  查询 `Points合约`，检查用户额度/信用是否充足。
5.  验证通过，执行用户合约的动作，Entrypoint会扣取paymaster一定额度作为gas。
6. 执行完毕后调用postOps：`Paymaster合约` 向 `Settlement合约` 写入一笔债务记录。
6.  `EntryPoint` 继续执行 `UserOperation`。

**流程 D: 债务结算**

1.  DVT 网络的节点监控 `Settlement合约` 中的债务记录。
2.  当债务记录达到一定数量（如 100 条）或时间（如 1 小时），节点开始工作。
3.  节点从 `Settlement合约` 读取一批债务，构建一笔批量转账交易（调用用户授权的 ERC20 合约的 `transferFrom`）。
4.  节点提交该批量交易至链上，完成结算，并更新 `Settlement合约` 和 `Points合约` 中的状态。

## 5. 技术要求

- **兼容性**: 必须完全兼容 ERC-4337 v0.6 和 v0.7，0.8 标准。架构设计需考虑 EIP-7702 和 RIP-7560，预留升级路径。
- **安全性**: 所有合约必须经过严格审计，防范重入攻击、经济攻击等。信用系统需具备抗女巫攻击的能力。
- **Gas 效率**: 批量结算机制需被优化，确保其 Gas 成本显著低于单笔结算的总和。
- **模块化**: `Paymaster`、`Settlement`、`Points` 合约应设计为可独立升级的模块化组件。

## 6. 难点分析
帮我确认下，如果有一个公共结算合约，唯一可以调用某ERC20内置函数进行结算。而结算非实时，从安全角度看，是否可以让任何人都可以触发批量结算的公共结算合约函数，批量执行一些结算呢，这样更节约成本（实时转账是一笔gas，批量更节约）
好的，这是一个非常棒的智能合约设计问题，涉及到常见的Gas优化模式和相关的安全考量。

您的想法是完全可行的，并且在很多场景下是推荐的设计模式。这种模式的核心思想是 **“将‘权限验证’与‘执行触发’相分离”**。

简单来说：**任何人都可以触发结算，但结算的具体内容（结算谁、结算多少）必须是经过严格授权且不可篡改的。**

下面我从安全性、设计模式和成本三个角度为您详细分析。

### 1. 安全性考量 (Security Considerations)

让任何人都可以调用批量结算函数（我们称之为 `processSettlements`）是安全的，**前提是必须满足以下几个关键条件**：

*   **结算数据的来源必须安全**：调用 `processSettlements` 的人不能决定结算的内容。所有待结算的交易记录（例如，从A转移X数量到B）必须已经安全地存储在结算合约中。这些记录只能由一个或多个拥有特权的角色（例如，`ADMIN_ROLE` 或 `SETTLEMENT_REQUESTER_ROLE`）通过一个独立的、有权限控制的函数来添加。
    *   **反模式 (Anti-Pattern)**：`processSettlements(Settlement[] memory settlements)` 函数允许调用者传入一个结算数组。这是**极其危险**的，因为调用者可以随意构造结算内容。
    *   **正确模式 (Correct Pattern)**：`processSettlements(uint256 batchSize)` 函数从合约内部存储的一个队列或列表中读取 `batchSize` 数量的、已经过验证的结算请求来进行处理。

*   **防止重入攻击 (Re-entrancy Protection)**：当结算合约调用外部ERC20合约时，必须防止外部合约回调（re-enter）结算合约并造成状态错乱。最简单的方法是使用 OpenZeppelin 的 `nonReentrant` 修饰符。同时，遵循“检查-生效-交互”（Checks-Effects-Interactions）模式，即先更新合约内部状态（如标记结算已完成），再调用外部ERC20合约。

*   **拒绝服务攻击 (Denial-of-Service / Gas Griefing)**：
    *   **问题**：如果结算队列中有一笔交易注定会失败（例如，转账给一个会拒绝收款的合约），那么整个批量结算交易可能会因为这一个失败而全部回滚。攻击者可以故意构造一个这样的结算请求，来“堵塞”整个结算流程。
    *   **解决方案**：在循环处理每一笔结算时，使用 `try/catch` 语句。这样，即使单笔结算失败，也可以捕获异常，将其标记为失败并继续处理队列中的其余结算，而不会导致整个交易失败。
    *   **问题**：调用者可能会传入一个极大的 `batchSize`，导致交易的Gas消耗超过区块Gas上限（Block Gas Limit）而永远无法成功。
    *   **解决方案**：在 `processSettlements` 函数内部对 `batchSize` 设置一个合理的上限。

*   **激励机制 (Incentive Mechanism)**：既然任何人都可以调用这个函数，那大家为什么要消耗自己的Gas来为大家服务呢？这通常被称为“Keeper Network”模式。
    *   您可以设计一种激励：每次成功处理一批结算后，调用者（`msg.sender`）可以获得一小笔费用作为奖励。这笔费用可以从每笔结算中抽取，或者由系统额外提供。这样就创造了一个开放的、有经济激励的系统来保证结算的持续进行。

### 2. 推荐的设计架构 (Recommended Architecture)

#### 合约一：ERC20 代币合约

这个合约本身逻辑很简单，但需要包含一个**内部或受限的结算函数**。

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MySettledToken is ERC20 {
    address public settlementContract;

    modifier onlySettlementContract() {
        require(msg.sender == settlementContract, "Caller is not the settlement contract");
        _;
    }

    constructor() ERC20("My Settled Token", "MST") {
        // ...
    }

    function setSettlementContract(address _contract) external onlyOwner {
        settlementContract = _contract;
    }

    /**
     * @dev 核心结算函数，只能由结算合约调用。
     * 它直接操作账户余额，绕过了常规的 `transfer` 或 `approve/transferFrom` 流程。
     * 注意：这里的 `_from` 账户的余额必须足够。
     */
    function settle(address _from, address _to, uint256 _amount) external onlySettlementContract {
        _transfer(_from, _to, _amount);
    }
}
```

#### 合约二：公共结算合约 (Public Settlement Contract)

这是您设计的核心，分离了权限和执行。

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "./MySettledToken.sol";

contract PublicSettlement is AccessControl, ReentrancyGuard {
    bytes32 public constant SETTLEMENT_REQUESTER_ROLE = keccak256("SETTLEMENT_REQUESTER_ROLE");

    MySettledToken public token;

    struct SettlementRequest {
        address from;
        address to;
        uint256 amount;
        bool executed;
        bool failed;
    }

    // 存储待结算请求的队列
    SettlementRequest[] public settlementQueue;
    uint256 public nextQueueIndex;

    // 事件
    event SettlementRequested(uint256 indexed requestId, address indexed from, address indexed to, uint256 amount);
    event SettlementProcessed(uint256 indexed requestId, bool success);

    constructor(address _tokenAddress) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        token = MySettledToken(_tokenAddress);
    }

    /**
     * @dev [权限函数] 添加一个新的结算请求到队列中。
     * 只有拥有 SETTLEMENT_REQUESTER_ROLE 角色的地址才能调用。
     */
    function requestSettlement(address _from, address _to, uint256 _amount)
        external
        onlyRole(SETTLEMENT_REQUESTER_ROLE)
    {
        uint256 requestId = settlementQueue.length;
        settlementQueue.push(SettlementRequest({
            from: _from,
            to: _to,
            amount: _amount,
            executed: false,
            failed: false
        }));
        emit SettlementRequested(requestId, _from, _to, _amount);
    }

    /**
     * @dev [公共函数] 处理一批待结算的请求。任何人都可以调用。
     * @param _batchSize 要处理的请求数量。
     */
    function processSettlements(uint256 _batchSize) external nonReentrant {
        uint256 queueEnd = nextQueueIndex + _batchSize;
        // 防止 batchSize 过大
        if (queueEnd > settlementQueue.length) {
            queueEnd = settlementQueue.length;
        }

        require(nextQueueIndex < queueEnd, "No pending settlements to process");

        for (uint256 i = nextQueueIndex; i < queueEnd; i++) {
            SettlementRequest storage request = settlementQueue[i];

            // 跳过已处理的
            if (request.executed) {
                continue;
            }

            request.executed = true; // 遵循 Checks-Effects-Interactions 模式

            try token.settle(request.from, request.to, request.amount) {
                emit SettlementProcessed(i, true);
            } catch {
                request.failed = true;
                emit SettlementProcessed(i, false);
            }
        }

        nextQueueIndex = queueEnd;
    }

    function getQueueLength() external view returns (uint256) {
        return settlementQueue.length;
    }
}
```

### 3. 成本分析 (Cost Analysis)

*   **实时转账**：每笔交易都需要一次独立的 `transfer` 调用，成本是 `基础交易费 (21000 Gas) + transfer函数执行费`。如果交易频繁，总成本会非常高。
*   **批量结算**：
    *   **请求阶段**：`requestSettlement` 函数的成本相对较低，因为它只涉及状态写入（`sstore`）。
    *   **处理阶段**：`processSettlements` 函数的成本是 `基础交易费 + 循环处理N笔结算的费用`。由于多个 `sstore` 和外部调用（`call`）被打包在一次交易中，摊销到每笔结算上的基础交易费几乎为零，极大地节约了总成本。

### 结论

**是的，让任何人都可以触发批量结算是安全且高效的，但这要求您在架构上做出精心的设计。**

核心要点是：
1.  **分离职责**：特权角色负责**授权和添加**结算请求，公共调用者只负责**触发执行**。
2.  **内部队列**：结算函数必须从合约内部的安全队列中读取数据，绝不能接受来自外部的结算数据。
3.  **健壮性设计**：使用 `nonReentrant` 防止重入，`try/catch` 处理单笔失败，并限制批处理大小以防Gas耗尽。
4.  **激励机制（可选但推荐）**：为调用者提供少量奖励，以确保系统能被持续、及时地维护。

这种模式将链下或有权限的链上系统的灵活性与链上结算的去中心化和成本效益完美结合了起来。


## 一期：基础流程
实现无链下Server，just SBT+ERC20（实时链上）支付gas的Gas Sponsor
### 一个使用ERC20支付gas的交易
0. 准备：具备0.6,0.7,0.8的合约账户：airaccount.aastar.io，直接用minter app，给合约地址mint SBT和ERC-20：https://gemini-minter.vercel.app/,定价0.03U=1个PNTs ERC-20
1. 入参：标准ERC-4337 UserOperation，本次支付gas sponsor使用的ERC-20 合约地址
2. 查询SuperPaymaster合约，携带ERC-20 合约地址，返回是否支持和哪个Paymaster支持（包括合约地址和价格，价格是模糊报价，基于平均价格报价，例如近24小时平均价格是0.024U，则价格是2.3 xPNTs（根据实时gas计算），如何定价是由赞助方决定）
3. UserOperation写入此Paymaster地址到对应字段(需要测试0.6/0.7/0.8).
4. 发送交易到Bundler（采用公开API，测试Pimlico和Alchemy）
5. 链上行为：其他遵守ERC-4337标准即可，gas部分Entrypoint查询到由特定paymaster赞助，则计算，扣除deposit 余额；postOps根据实际gas计算需要扣除的积分，加上交易hash，address，调用结算合约存储记录
6. 结算合约会检查合法性，然后记录，完成一次赞助
7. 几个基础安全考虑
  - 需要paymaster注册的时候stake GToken，以保障安全和服务（例如恶意操纵结算合约记账，多扣用户gas token等）
  - 只有注册的paymaster才可以调用结算合约记账
  - 链下结算出发需要对账，然后生成proof，聚合签名后广播，触发结算
  -

#### 配置
- 默认网络：Etereum Sepolia Test Network, Chain ID, 11155111
- SBT合约地址：0xBfde68c232F2248114429DDD9a7c3Adbff74bD7f
- PNTs ERC20合约地址：0x3e7B771d4541eC85c8137e950598Ac97553a337a
- 结算合约：待开发
- Paymaster合约：待开发新版本
- SuperPaymaster合约：0x4e67678AF714f6B5A8882C2e5a78B15B08a79575
- EntryPoint:
  - 0.6: 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789
  - 0.7: 0x0000000071727De22E5E9d8BAf0edAc6f37da032
  - 0.8: 0x0000000071727De22E5E9d8BAf0edAc6f37da032

#### Paymaster合约V2
- 新分支V3（sp contract repo）
- 基于Sigleton合约，分析其中的核心逻辑
- 去掉冗余分钟，只使用verify部分，检查代码和逻辑，编译
- 优化为SBT和PNTs余额检测的verify逻辑
- postOps部分添加调用结算合约的动作
- 结算合约只被我们指定的Paymaster工厂部署的Paymaster合约调用
- 约定的账单结构和账单状态，是否支持构建账单和提交上链分离？
- 结算流程背景：
  1. 建立ERC-20工厂合约，所有积分都基于此工厂合约发行自己的ERC-20 Gas Token
  2. 工厂合约内置了预approve：允许结算合约以某个上限和某个验证规则为基准进行token转移
  3. 上限是计算单个交易gas上限的100倍（一般足够了，目前只在layer2,因此实际金额很小）
  4. 验证规则是提供确认：这个账单是我的地址提交的（useroperation hash+address）再hash为key的未结算状态的账单

  结算可能需要实时从uniswapV4某个交易对（pool）获得aPNTs和PNTs的汇率，这个gas消耗不多吧

  ------

  === L2 Gas成本分析 (以Arbitrum/Optimism为例) ===

  L2 Gas Price参考:
  - Arbitrum: 0.01-0.1 Gwei
  - Optimism: 0.001-0.01 Gwei
  - Base: 0.001-0.01 Gwei

  === 实际成本计算 (Arbitrum, 0.1 Gwei) ===
  Gas Price: 0.1 Gwei = 100000000.0 wei
  Total Gas: 380000
  Cost in Wei: 38000000000000.0
  Cost in ETH: .0000380000
  Cost in USD: $.0950000000

  === PNT成本计算 (1 PNT = $0.02) ===
  需要PNT: 4.7500 PNT

  === 100 PNT可用次数 ===
  可用次数: 21 次

  === 不同L2的对比 ===

  Optimism (0.001 Gwei):
    Cost: $.00095000 USD = .0475 PNT

  Base (0.005 Gwei):
    Cost: $.00475000 USD = .2375 PNT

```
主网 (Sepolia测试网类似):
- Gas Price: 1-50 Gwei
- 一次转账: 380,000 gas
- 成本: 0.00038-0.019 ETH = $0.95-$47.5 ❌ 太贵

L2 (Arbitrum/Optimism):
- Gas Price: 0.001-0.1 Gwei (是主网的1/100-1/1000)
- 一次转账: 380,000 gas
- 成本: 0.00000038-0.000038 ETH = $0.00095-$0.095 ✅ 合理
```
**历史价格数据源:**
- [ ] Chainlink历史数据 (推荐,去中心化)
- [ ] CoinGecko API (备选,中心化)
- [ ] 其他?

**Keeper部署方式:**
- [ ] 自建服务器
- [ ] Gelato Network (去中心化keeper)
- [ ] Chainlink Automation
- [ ] 其他?

## 二期：异步结算
1. DVT挖矿逻辑：干活，分PNTs
2. 定时订阅结算合约消息，有了之后竞价，信用+最低报价胜出；整体采用概率随机，轮流获得结算机会。
3. 结算具体流程看难点分析
4. 负值处理：每个人给不同reputation（初始化），20=6PNTs credit，30=10PNTs credit，40=15PNTs credit,以此类推
5. 检查预approve的安全，提升
6. 接入SuperPaymaster然后配置报价，可以设置动态费率，跟随gas价格波动+一定利润率
