# SuperPaymaster DApp
因为从功能核心来看，SuperPaymaster是一个registry，所以dapp简称registry-app。
此应用目标是对运营者、开发者展示核心能力和流程。
## 页面和概述
入口：SuperPaymaster.aastar.io
landing page：SuperPaymaster, A Decentralized ,Neagative Cost, Seamless Gas Sponsor Public Goods on Ethereum.
Feats：
1. Decentralization: No centralized server, just contract.
2. Permissionless: Anyone can create and register a paymaster.
3. Free Market: Get your sponsorship from the market.
Statistics Area:
Network: [Sepolia][Mainnet][OP Sepolia][OP Mainnet] link to cnotract address
Registered Paymasters: 5[filter link to all registered paymasters]
Supported Gas Tokens: 5 [USDC, USDT, DAI, ETH, ASTR] link to contract
Communities members: 6 [AAStar, BBCommunity, CCCommunity, DDCommunity, EECommunity, FFCommunity] link to community website(add exchange links each other)
Sponsored UserOperations: 1035[link to a list, jeyllyscan]

页面中间两个button： Community Operators，Developer Operators
分布链接到两个独立页面


## page
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

4.开发者流程
- 获得SuperPaymaster 某链的ENS
- 配置SDK，运行初始化命令
- 创建一个AA账户A，提供一个EOA账户B
- 分别领取测试token：SBT和PNTs以及测试的USDT
- 使用node运行js文件，完成从A转5USDT
- 无Gas支付，无approve等Web3传统体验，Web2丝滑体验
- 实际自动扣除了PNTs支付Gas（参考Report和机制说明）

## Developer Quick Test Page
简单点说：
我们做两个外部测试，任何dapp都可以通过下述方式来获得我们的v4 paymaster的赞助
测试1: 还没部署的合约账户
1. 获得PNTs（发地址给我

测试2: 已经部署的合约账户

这个 super Paymaster APP，它有一个运营者界面，

## Developer Page
还有一个开发者页面，这个测试页面主要是为这些开发者准备的，换句话说，如果开发者他想要去调用 super Paymaster 能力，他应该怎么办？首先 super Paymaster 会有一个这个页，目前我们只在这个sepolia, op sepolia 和op mainnet这三个网络上尝试部署 ens:sepolia.superpaymaster.aastar.eth; op-sepolia.superpaymaster.aastar.eth,op-mainnet.superpaymaster.aastar.eth，这三个 ens 分别指向，不同的预部署的合约地址，这三个合约地址是就是 super master 的合约地址，这个要显示出信息来，当然我们可以通过这个预设的 ENS name 来去获取到这对应的合约地址。对，同时开发者他知道了这个合约地址之后，他需要做的就是设置这个。自己的 user operation 的 Paymaster 地址为这个任意一个不同链的这个 ens 就是 Paymaster 的地址。然后我们提供三个版本的，就是0.6、0.7、0.8同版本的 us operation 应该如何构造,然后如何发起一个正常 user operation？用我们的这个 superpaymaster v4测试脚本为基础，
这里会预设两个Test Contract Account A和Test Contract Account B，这两个账户都是通过我们的合约工厂来创建的，然后我们提供三个版本的，就是0.6、0.7、0.8同版本的 us operation form，默认已经获得了SBT和pnt（提示从faucet.aastar.io获得测试sbt和token）；

为每个社区开发他们自己的加油卡和积分，然后部署他们的加油站（paymaster）合约即可让社区成员获得无感的web3体验。

另外完成交易后，参考v4 report脚本，输出一些关键的report概述，比如说交易从哪里提交？设置了哪些 TOKEN？等等


## Operator Page

它完成的任务是主要有四个页面：新建，设置自己，设置stake（entrypoint或者pnts），注册。
第一就是给这些 Paymaster v four 合约提供一个注册的入口，它这个注册的过程需要连接自己的小狐狸，然后提交这个交易，把自己的 Paymaster v four 已经部署的合约地址注册到 super pay master 合约上(还有先问用户，要新建paymaster，还是注册paymaster。新建就需要使用我们的paymasterv4合约部署自己的，登录的metamask会默认是owner，部署完成后要完成相关的设置（在第二个页面完成，具体看v4代码），都需要owner支付gas；owner后面可以转让给多签；对然后就是部署完成后引导到注册入口，需要stake GToken，默认10个，可以增加更多获得更多信用；stake完成后，就可以注册到superpaymaster了；

然后第二个作用是他需要提供这个，比如说一些和entrypoint的交互界面，比如说像 entry point，0.6、0.7、0.8，去 Stake，去 deposit。那同时，嗯，他还可以去查询这个 Paymaster v four 在各个不同版本 entry point 的 balance。这是他和这个 entry point 的交互管理的界面。

那第三个就是它可以查看自己的相关信息，详细查看合约代码就可以知道；因为每一个 ppaymaster 会设置一个 treasury，就是哪一个国库它会接收自己相关的这个 against TOKEN 的收入。对，同时这个界面还要包括他发行的这个 Paymaster 发行的这个 ERC twenty TOKEN，the gas TOKEN，我们会为这个发行提供这个合约模板，合约工厂，然后他基于合约工厂来发行他 ERC twenty 发行完之后，他要注册到这个自己的 Paymaster account 上。从而别人可以从他这儿这个获得 gas TOKEN 的支持，大概就这些。
