# SuperPaymaster DApp
因为从功能核心来看，SuperPaymaster是一个registry，所以dapp简称registry-app。
此应用目标是对运营者、开发者展示核心能力和流程，所有说明性页面提供中英文，默认英文，在开头提供中文页面链接；功能页面仅英文。
## 页面和概述
入口：SuperPaymaster.aastar.io
landing page：SuperPaymaster, A Decentralized ,Neagative Cost, Seamless Gas Sponsor Public Goods on Ethereum.
显示一个svg动画在landing page top：@public/gas_station_animation.svg
Feats：
1. Decentralization: No centralized server, just contract.
2. Permissionless: Anyone can create and register a paymaster.
3. Free Market: Get your sponsorship from the market.

### Statistics Area
- Network: [Sepolia][Mainnet][OP Sepolia][OP Mainnet] link to contract address
- Registered Paymasters: 5[filter link to all registered paymasters]
- Supported Gas Tokens: 5 [USDC, USDT, DAI, ETH, ASTR] link to contract
- Communities members: 6 [AAStar, BBCommunity, CCCommunity, DDCommunity, EECommunity, FFCommunity] link to community website(add exchange links each other)
- Sponsored UserOperations: 1035[link to a list, jeyllyscan]
- Saving Cost：a calculated value from total UserOperations cost
- more like bundlebear

页面中间两个button： Developer和Community Operators，分别链接到对应的独立页面。页面热情橙色（可以渐变）和冷静蓝色（可以渐变）为主色调，白色辅助。

## Developer Page
说明：

还有一个开发者页面，这个测试页面主要是为这些开发者准备的，换句话说，如果开发者他想要去调用 super Paymaster 能力，他应该怎么办？首先 super Paymaster 会有一个这个页，目前我们只在这个sepolia, op sepolia 和op mainnet这三个网络上尝试部署 ens:sepolia.superpaymaster.aastar.eth; op-sepolia.superpaymaster.aastar.eth,op-mainnet.superpaymaster.aastar.eth，这三个 ens 分别指向，不同的预部署的合约地址，这三个合约地址是就是 super master 的合约地址，这个要显示出信息来，当然我们可以通过这个预设的 ENS name 来去获取到这对应的合约地址。对，同时开发者他知道了这个合约地址之后，他需要做的就是设置这个。自己的 user operation 的 Paymaster 地址为这个任意一个不同链的这个 ens 就是 Paymaster 的地址。然后我们提供三个版本的，就是0.6、0.7、0.8同版本的 us operation 应该如何构造,然后如何发起一个正常 user operation？用我们的这个 superpaymaster v4测试脚本为基础，
这里会预设两个Test Contract Account A和Test Contract Account B，这两个账户都是通过我们的合约工厂来创建的，然后我们提供三个版本的，就是0.6、0.7、0.8同版本的 us operation form，默认已经获得了SBT和pnt（提示从faucet.aastar.io获得测试sbt和token）；

为每个社区开发他们自己的加油卡和积分，然后部署他们的加油站（paymaster）合约即可让社区成员获得无感的web3体验。

另外完成交易后，参考v4 report脚本，输出一些关键的report概述，比如说交易从哪里提交？设置了哪些 TOKEN？等等

- What is SuperPaymaster and AAStar eco?
- How to get gas sponsor ability for your DApp?
- How to help your community to build their own Paymaster with ETH staking?
### What is SuperPaymaster and AAStar eco?
SuperPaymaster is a public goods **registry** for all Community Paymasters. Provides **Smart Router** for any DApp users holding on any gas token with best choice(support, price, speed, reputation, reliability). It creates a **sustainable** ecosystem for all communities with a basic **revenue model**.

AAStar is a open source group, builds infrastructure and components on Ethereum. The Mission of AAStar is **Empower Community**.
AAStar creates a ecosystem based on Mycelium Protocol, include:
- AirAccount
- SuperPaymaster
- AAStar SDK
- OpenCards/OpenPNTs
- More...

### How to get gas sponsor ability for your DApp?
- 安装AAStar SDK，完成下述配置后运行quick-start.js
- 获得SuperPaymaster 某链的ENS，例如op.SuperPaymaster.aastar.eth
- 运行初始化命令,会生成用于quick-start的测试配置
- 或者自行创建一个ERC-4337标准的AA（合约）账户A，一个EOA账户B
- 或者为测试账户A到faucet领取测试token：SBT和PNTs以及测试的USDT
- 配置使用某个Paymaster，指定Gas Token，或不知道Gas Token,自动匹配（根据SBT和PNT），使用node运行js文件，完成从A转5USDT
- 无需ETH Gas支付，无需ERC-20 approve等Web3传统体验，Web2丝滑体验
- 实际自动扣除了PNTs支付Gas（参考运行后的Report和GitHub repo的设计文档）

### How to build Paymaster with ETH staking for your community?
考虑大部分社区没有专职技术人员，我们提供了标准流程来快速的质押GToken和aPNTs，从而发行自己的加油卡和社区Gas Token（参考社区运营者页面）。，而社区的扩展选择是加入去中心化网络，运行自己的服务器，这个去中心化网络服务于所有协议内的账户声明周期，类似于以太坊信标链的验证者网络，每个社区可以选择运行自己的服务器，组成了一个去中心化节点网络，提供Passkey签名验证、BLS签名聚合、KMS调用、Guardian签名等等去中心化的服务，也获得整个网络协议的aPNTs奖励以及熵值Reputation和GToken分配。
当然，你也可以不加入这个协议，纯粹为了帮助自己的社区发行Gas Token，服务于所有社区Gas Token的持有者，我们为此提供下面的技术指导。

- 准备一个工作用EOA，完成下面操作后可以Transfer Owner给社区多签账户
- 准备一个Treasury账户，建议是多签账户，一般每个链有一个Paymaster，对应了一个Treasury收益账户，是为社区成员提供服务的Service Fee的收入账户，默认2%，管理员可更改，如果设置为0,则仍然需要账户，但实际不发生收入。
- 采用社区的SimpleAccount工厂合约或者自行开发符合ERC-4337的工厂合约，可以计算地址来初始化社区账户
- 准备适当的ETH，用来给你的社区初始化账户，每个账户初始化创建之前需要你打入到计算地址中，从而可以第一次交易时部署。注意：因为你没有加入协议，只运行自己的服务，可以免费使用SuperPaymaster公共物品，但无法利用已有的协议能力（无gas自动创建账户）。更多技术信息可以参考ERC-4337技术标准。
- 使用社区提供的SBT和PNT合约工厂，创建自己的SBT和Gas Token
- 使用社区提供的PaymasterV4（或者更新版本）发布自己的Paymaster，设置要求的SBT和Gas Token为你刚发布的地址，有专门页面提供Paymaster管理
- 注册Paymaster到SuperPaymaster，记不住你地址或者变动后依然可以通过ENS找到你，无法积累信用，无法获得熵值，无法和其他协议用户交换等协议行为。
- 测试你的Paymaster：参考 Developer Page：[### How to get gas sponsor ability for your DApp?]



## Community Operators Page
说明：
它完成的任务是主要有四个页面：新建，设置自己，设置stake（entrypoint或者pnts），注册。
第一就是给这些 Paymaster v four 合约提供一个注册的入口，它这个注册的过程需要连接自己的小狐狸，然后提交这个交易，把自己的 Paymaster v four 已经部署的合约地址注册到 super pay master 合约上(还有先问用户，要新建paymaster，还是注册paymaster。新建就需要使用我们的paymasterv4合约部署自己的，登录的metamask会默认是owner，部署完成后要完成相关的设置（在第二个页面完成，具体看v4代码），都需要owner支付gas；owner后面可以转让给多签；对然后就是部署完成后引导到注册入口，需要stake GToken，默认10个，可以增加更多获得更多信用；stake完成后，就可以注册到superpaymaster了；

然后第二个作用是他需要提供这个，比如说一些和entrypoint的交互界面，比如说像 entry point，0.6、0.7、0.8，去 Stake，去 deposit。那同时，嗯，他还可以去查询这个 Paymaster v four 在各个不同版本 entry point 的 balance。这是他和这个 entry point 的交互管理的界面。

那第三个就是它可以查看自己的相关信息，详细查看合约代码就可以知道；因为每一个 ppaymaster 会设置一个 treasury，就是哪一个国库它会接收自己相关的这个 against TOKEN 的收入。对，同时这个界面还要包括他发行的这个 Paymaster 发行的这个 ERC twenty TOKEN，the gas TOKEN，我们会为这个发行提供这个合约模板，合约工厂，然后他基于合约工厂来发行他 ERC twenty 发行完之后，他要注册到这个自己的 Paymaster account 上。从而别人可以从他这儿这个获得 gas TOKEN 的支持，大概就这些。

- Why I need a Community Paymaster?
- How to quick launch your community Paymaster?
- How to get a sustainable revenue for your community?
- How to join the protocol and get facilities and help?

### Why I need a Community Paymaster?
Communities or any Organization, they want create some flow to create value, but be always failed at three key questions: Onboarding, Check, and Motivation. In short Communities need sustainabilities. We provide a low cost solution to solve these problems. This solution named COS72, including some infrastructures and protocols to help us.
SuperPaymaster is a part of infrastructure in COS72.
SuperPaymaster can easily create a community Paymaster. And we provide a circulation model on Tasks, PNTs and Shops:
- Do something for Community(Tasks)
- Get PNTs from Community(PNTs)
- Spend PNTs in Shops(Shops)
- PNTs are not only for Web3 activity gas sponsorship.

这里放一个居中的svg：SuperPaymaster/registry-app/public/triangle.svg

### How to quick launch your community Paymaster?
使用AAStar SDK，快速集成去中心化Web3账户能力，定制自己的DApp。
核心优点：
1. 全流程Decentralization，解释：开源获取SDK和合约代码，EtherScan验证链上合约，Passkey确保意图简单传递，去中心化KMS提供安全审核，社交恢复可迁移，去中心化Validator杜绝共谋和欺诈，去中心化Paymaster提供无Censorship Gas Sponsor；即便社区开发小组突然消失，社区成员可以随时接管社区项目，网络服务依然自组织自运转。
2. 内置强大协议：由社区不断创新，基建小组不断完善的Mycelium Protocol，基于以太坊安全保障，持续构建转化为创新动力，为社区成员（所有持有GToken、SBT）持续增强Utility。
  - Seamless Gas Sponsor Protocol（SuperPaymaster）
  - Valuation Spreading Incentivation（Spores）
  - Create and sell on Blockchain（Shops）
  - On-chain Task Market(Tasks)
  - Launch Your Business Points Token (OpenPNTs)
  - SBT and NFT creation and using (OpenCards)
  - Individual's Promise Tokenization(Asset3)
  - Permissionless Creator AI tools (Doris)
  - Your Human Emotional Expression Asset (sBlackBook)
  - Smart City Protocol (OpenCity)
  - More...

3. Permissionless的社区共创参与,社区不仅仅提供Web3基础设施来帮助组织和个人构建新资产和新协作，更会着眼人类文明高度，持续思考，关注和投入不同研究课题。

- AI模型创新和应用
- 人类个体价值和社会网络、社会资本
- 复杂系统和演进
- 社会可持续发展
- 登月和外地文明探索


业界钱包、账户和Gas Payment解决方案对比表格：
待从论文copy


### How to get a sustainable revenue for your community?
### How to join the protocol and get facilities and help?

1. 运营者能力展示：任何组织/个人都可以赋能自己的成员Web2的体验+Web3的应用。
- Web2账户、Email快速绑定和创建自己的Web3/ENS账户
- 基于指纹+TEE KMS+DVT来保障安全，支持社交恢复等AA能力
- 社区身份SBT/NFT集成加油卡以及社区积分赋能
- 社区可持续循环：Task-->PNTs-->Shop
- 视频和快速开始教程（Cos72快速开始）
2. 开发者能力展示：开发者可以构建自己的Web2体验的Web3 DApp
- SDK 和范例支持
- Mobile App支持：Zu.coffee
- Web3 Page DApp支持：Zu.coffee


3. 社区运营者操作流程
- Paymaster的创建和初始化设置
- Paymaster的stake和注册
- Paymaster的日常管理


## Demo Playground
在测试网展示：
End user：用户快速创建账户、拥有SBT和PNTs、无Gas测试USDT转到任意账户、更多feats
社区运营者：部署自己的Paymaster合约、配置、Stake+注册到SuperPaymaster、发行自己的SBT和PNTs、上架NFT销售充值卡

开发者：网站引入Web3用户体系、为用户AA账户设置Superpaymaster.aastar.eth 作为paymaster，自动辨认注册过的paymaster（自动检查SBT和接受PNTs）

DApp开发体验：快速集成去中心化的账户体系和经济模型，接受多社区的价值承诺和流通，展示最简单的对比：创建AA账户（传统Vs无感）

EOA无感迁移绑定：注册账户，绑定passkey，绑定delegation 合约（官方模板），获得SBT和PNTs，转载给任意账户无需Gas支付，获得ENS，页面passkey认证转帐，只授权最基础gas sponsor积分权限，其他资产无安全风险


开发者接口能力介绍：（安装SDK后）
1. 创建账户接口，CURL测试
2. 定制创建账户配置，解释配置的作用
3. Guardian：默认配置和可选配置
4. 社交恢复：去中心化的发起恢复，收集签名，恢复
5. 发行SBT/NFT/PNTS,二次开发
6. NFT充值卡发行和使用
7. PNTs发行的stake机制
8. 配置和发布社区自己的Paymaster（PNTs版）
9. 进阶复杂版：配置和发布社区自己的Paymaster（ETH版）
10. 基础使用：AA账户和EOA绑定delegation后的账户发起免Gas交易
11. 进阶使用：从SuperPaymaster.aastar.eth发起免Gas交易，支持多签名，支持多币种，支持多链
11. 细节测试：测试1: 还没部署的合约账户
            1. TODO：基于V4的GToken的流动性挖矿：获得GToken并Stake，从而持有LpToken（ERC-20）在账户，持续获得协议分润
            2. 到商店购买SBT/NFT,SBT只有协议可以发行，提供开放接口（底层接口reputation，熵值）
            3. 目前持有PNTs就可以，无需SBT，未来会检查lpToken/stToken.

          测试2: 已经部署的合约账户
          同10,11
