Starting Anvil...
Anvil started with PID 36947
Deploying Contracts locally...
❌ Deployment Failed. Check script/v3/logs/deploy.log
Warning: Found unknown `exclude` config for profile `default` defined in foundry.toml.
No files changed, compilation skipped
Traces:
  [23171749] SetupV3::run()
    ├─ [0] VM::envUint("PRIVATE_KEY") [staticcall]
    │   └─ ← [Return] <env var value>
    ├─ [0] VM::addr(<pk>) [staticcall]
    │   └─ ← [Return] 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
    ├─ [0] VM::envOr("TREASURY_ADDRESS", 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266) [staticcall]
    │   └─ ← [Return] <env var value>
    ├─ [0] VM::envOr("DAO_MULTISIG", 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266) [staticcall]
    │   └─ ← [Return] <env var value>
    ├─ [0] VM::startBroadcast(<pk>)
    │   └─ ← [Return]
    ├─ [44499] → new MockV3Aggregator@0x5FbDB2315678afecb367f032d93F642f64180aa3
    │   └─ ← [Return] 222 bytes of code
    ├─ [2518226] → new EntryPoint@0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512
    │   ├─ [65923] → new SenderCreator@0xCafac3dD18aC6c6e92c921884f9E4176737C052c
    │   │   └─ ← [Return] 329 bytes of code
    │   └─ ← [Return] 11977 bytes of code
    ├─ [530334] → new GToken@0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0
    │   ├─ emit OwnershipTransferred(previousOwner: 0x0000000000000000000000000000000000000000, newOwner: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266)
    │   └─ ← [Return] 2304 bytes of code
    ├─ [1307310] → new GTokenStaking@0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9
    │   ├─ emit OwnershipTransferred(previousOwner: 0x0000000000000000000000000000000000000000, newOwner: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266)
    │   └─ ← [Return] 6188 bytes of code
    ├─ [2268668] → new MySBT@0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9
    │   └─ ← [Return] 10428 bytes of code
    ├─ [7477831] → new Registry@0x5FC8d32690cc91D4c39d9d3abcBD16989F875707
    │   ├─ emit OwnershipTransferred(previousOwner: 0x0000000000000000000000000000000000000000, newOwner: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266)
    │   └─ ← [Return] 29317 bytes of code
    ├─ [3265] MySBT::setRegistry(Registry: [0x5FC8d32690cc91D4c39d9d3abcBD16989F875707])
    │   ├─ emit RegistryUpdated(oldRegistry: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266, newRegistry: Registry: [0x5FC8d32690cc91D4c39d9d3abcBD16989F875707], timestamp: 1765784414 [1.765e9])
    │   └─ ← [Return]
    ├─ [22984] GTokenStaking::setRegistry(Registry: [0x5FC8d32690cc91D4c39d9d3abcBD16989F875707])
    │   └─ ← [Stop]
    ├─ [1242105] → new xPNTsToken@0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6
    │   └─ ← [Return] 5520 bytes of code
    ├─ [0] VM::toString(xPNTsToken: [0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6]) [staticcall]
    │   └─ ← [Return] "0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6"
    ├─ [1258629] → new SuperPaymasterV3@0x8A791620dd6260079BF849Dc5567aDC3F2FdC318
    │   ├─ emit OwnershipTransferred(previousOwner: 0x0000000000000000000000000000000000000000, newOwner: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266)
    │   └─ ← [Return] 5942 bytes of code
    ├─ [2612660] → new xPNTsFactory@0x610178dA211FEF7D417bC0e6FeD39F05609AD788
    │   ├─ emit OwnershipTransferred(previousOwner: 0x0000000000000000000000000000000000000000, newOwner: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266)
    │   └─ ← [Return] 12264 bytes of code
    ├─ [1132659] → new PaymasterFactory@0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e
    │   ├─ emit OwnershipTransferred(previousOwner: 0x0000000000000000000000000000000000000000, newOwner: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266)
    │   └─ ← [Return] 5539 bytes of code
    ├─ [1932515] → new PaymasterV4_1i@0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0
    │   ├─ emit OwnershipTransferred(previousOwner: 0x0000000000000000000000000000000000000000, newOwner: 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266)
    │   ├─ emit Initialized(version: 18446744073709551615 [1.844e19])
    │   └─ ← [Return] 9307 bytes of code
    ├─ [47937] PaymasterFactory::addImplementation("v4.1i", PaymasterV4_1i: [0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0])
    │   ├─ emit ImplementationAdded(version: 0xdc9d4a55ad883758f981ac3df24d8468bbb602b8b460f4cbef9652e3f690b038, implementation: PaymasterV4_1i: [0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0])
    │   └─ ← [Stop]
    ├─ [4927] PaymasterFactory::setDefaultVersion("v4.1i")
    │   ├─ emit DefaultVersionChanged(oldVersion: "v4.1i", newVersion: "v4.1i")
    │   └─ ← [Stop]
    ├─ [158300] PaymasterFactory::deployPaymasterDefault(0x)
    │   ├─ [156529] PaymasterFactory::deployPaymaster("v4.1i", 0x)
    │   │   ├─ [9031] → new <unknown>@0x8dAF17A20c9DBA35f005b6324F493785D239719d
    │   │   │   └─ ← [Return] 45 bytes of code
    │   │   ├─ emit PaymasterDeployed(operator: PaymasterFactory: [0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e], paymaster: 0x8dAF17A20c9DBA35f005b6324F493785D239719d, version: "v4.1i", timestamp: 1765784414 [1.765e9])
    │   │   └─ ← [Return] 0x8dAF17A20c9DBA35f005b6324F493785D239719d
    │   └─ ← [Return] 0x8dAF17A20c9DBA35f005b6324F493785D239719d
    ├─ [0] VM::stopBroadcast()
    │   └─ ← [Return]
    ├─ [0] VM::serializeAddress("<stringified JSON>", "gToken", 0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0)
    │   └─ ← [Return] "{\"gToken\":\"0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0\"}"
    ├─ [0] VM::serializeAddress("<stringified JSON>", "staking", 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9)
    │   └─ ← [Return] "{\"gToken\":\"0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0\",\"staking\":\"0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9\"}"
    ├─ [0] VM::serializeAddress("<stringified JSON>", "registry", 0x5FC8d32690cc91D4c39d9d3abcBD16989F875707)
    │   └─ ← [Return] "{\"gToken\":\"0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0\",\"registry\":\"0x5FC8d32690cc91D4c39d9d3abcBD16989F875707\",\"staking\":\"0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9\"}"
    ├─ [0] VM::serializeAddress("<stringified JSON>", "sbt", 0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9)
    │   └─ ← [Return] "{\"gToken\":\"0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0\",\"registry\":\"0x5FC8d32690cc91D4c39d9d3abcBD16989F875707\",\"sbt\":\"0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9\",\"staking\":\"0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9\"}"
    ├─ [0] VM::serializeAddress("<stringified JSON>", "superPaymaster", 0x8A791620dd6260079BF849Dc5567aDC3F2FdC318)
    │   └─ ← [Return] "{\"gToken\":\"0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0\",\"registry\":\"0x5FC8d32690cc91D4c39d9d3abcBD16989F875707\",\"sbt\":\"0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9\",\"staking\":\"0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9\",\"superPaymaster\":\"0x8A791620dd6260079BF849Dc5567aDC3F2FdC318\"}"
    ├─ [0] VM::serializeString("<stringified JSON>", "aPNTs", "0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6")
    │   └─ ← [Return] "{\"aPNTs\":\"0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6\",\"gToken\":\"0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0\",\"registry\":\"0x5FC8d32690cc91D4c39d9d3abcBD16989F875707\",\"sbt\":\"0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9\",\"staking\":\"0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9\",\"superPaymaster\":\"0x8A791620dd6260079BF849Dc5567aDC3F2FdC318\"}"
    ├─ [0] VM::serializeAddress("<stringified JSON>", "xPNTsFactory", 0x610178dA211FEF7D417bC0e6FeD39F05609AD788)
    │   └─ ← [Return] "{\"aPNTs\":\"0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6\",\"gToken\":\"0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0\",\"registry\":\"0x5FC8d32690cc91D4c39d9d3abcBD16989F875707\",\"sbt\":\"0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9\",\"staking\":\"0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9\",\"superPaymaster\":\"0x8A791620dd6260079BF849Dc5567aDC3F2FdC318\",\"xPNTsFactory\":\"0x610178dA211FEF7D417bC0e6FeD39F05609AD788\"}"
    ├─ [0] VM::serializeAddress("<stringified JSON>", "paymasterFactory", 0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e)
    │   └─ ← [Return] "{\"aPNTs\":\"0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6\",\"gToken\":\"0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0\",\"paymasterFactory\":\"0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e\",\"registry\":\"0x5FC8d32690cc91D4c39d9d3abcBD16989F875707\",\"sbt\":\"0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9\",\"staking\":\"0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9\",\"superPaymaster\":\"0x8A791620dd6260079BF849Dc5567aDC3F2FdC318\",\"xPNTsFactory\":\"0x610178dA211FEF7D417bC0e6FeD39F05609AD788\"}"
    ├─ [0] VM::serializeAddress("<stringified JSON>", "paymasterV4Impl", 0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0)
    │   └─ ← [Return] "{\"aPNTs\":\"0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6\",\"gToken\":\"0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0\",\"paymasterFactory\":\"0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e\",\"paymasterV4Impl\":\"0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0\",\"registry\":\"0x5FC8d32690cc91D4c39d9d3abcBD16989F875707\",\"sbt\":\"0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9\",\"staking\":\"0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9\",\"superPaymaster\":\"0x8A791620dd6260079BF849Dc5567aDC3F2FdC318\",\"xPNTsFactory\":\"0x610178dA211FEF7D417bC0e6FeD39F05609AD788\"}"
    ├─ [0] VM::serializeAddress("<stringified JSON>", "paymasterV4Proxy", 0x8dAF17A20c9DBA35f005b6324F493785D239719d)
    │   └─ ← [Return] "{\"aPNTs\":\"0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6\",\"gToken\":\"0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0\",\"paymasterFactory\":\"0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e\",\"paymasterV4Impl\":\"0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0\",\"paymasterV4Proxy\":\"0x8dAF17A20c9DBA35f005b6324F493785D239719d\",\"registry\":\"0x5FC8d32690cc91D4c39d9d3abcBD16989F875707\",\"sbt\":\"0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9\",\"staking\":\"0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9\",\"superPaymaster\":\"0x8A791620dd6260079BF849Dc5567aDC3F2FdC318\",\"xPNTsFactory\":\"0x610178dA211FEF7D417bC0e6FeD39F05609AD788\"}"
    ├─ [0] VM::serializeAddress("<stringified JSON>", "entryPoint", 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512)
    │   └─ ← [Return] "{\"aPNTs\":\"0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6\",\"entryPoint\":\"0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512\",\"gToken\":\"0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0\",\"paymasterFactory\":\"0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e\",\"paymasterV4Impl\":\"0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0\",\"paymasterV4Proxy\":\"0x8dAF17A20c9DBA35f005b6324F493785D239719d\",\"registry\":\"0x5FC8d32690cc91D4c39d9d3abcBD16989F875707\",\"sbt\":\"0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9\",\"staking\":\"0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9\",\"superPaymaster\":\"0x8A791620dd6260079BF849Dc5567aDC3F2FdC318\",\"xPNTsFactory\":\"0x610178dA211FEF7D417bC0e6FeD39F05609AD788\"}"
    ├─ [0] VM::writeFile("script/v3/config.json", "{\"aPNTs\":\"0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6\",\"entryPoint\":\"0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512\",\"gToken\":\"0x9fE46736679d2D9a65F0992F2272dE9f3c7fa6e0\",\"paymasterFactory\":\"0xB7f8BC63BbcaD18155201308C8f3540b07f84F5e\",\"paymasterV4Impl\":\"0xA51c1fc2f0D1a1b8494Ed1FE312d7C3a78Ed91C0\",\"paymasterV4Proxy\":\"0x8dAF17A20c9DBA35f005b6324F493785D239719d\",\"registry\":\"0x5FC8d32690cc91D4c39d9d3abcBD16989F875707\",\"sbt\":\"0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9\",\"staking\":\"0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9\",\"superPaymaster\":\"0x8A791620dd6260079BF849Dc5567aDC3F2FdC318\",\"xPNTsFactory\":\"0x610178dA211FEF7D417bC0e6FeD39F05609AD788\"}")
    │   └─ ← [Return]
    └─ ← [Return]


Script ran successfully.
Error: `Unknown3` is above the contract size limit (29317 > 24576).
Error: IO error: not a terminal
Stopping Anvil...
