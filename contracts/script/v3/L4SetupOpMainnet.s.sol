// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// Interfaces & Core
import "src/core/Registry.sol";
import "src/interfaces/v3/IRegistry.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/GToken.sol";
import "src/tokens/xPNTsToken.sol";
import "src/tokens/xPNTsFactory.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/paymasters/v4/Paymaster.sol";
import "src/paymasters/v4/core/PaymasterFactory.sol";

interface ISimpleAccountFactory {
    function createAccount(address owner, uint256 salt) external returns (address ret);
    function getAddress(address owner, uint256 salt) external view returns (address);
}

interface ISimpleAccount {
    function execute(address dest, uint256 value, bytes calldata func) external;
}

/**
 * @title L4SetupOpMainnet
 * @notice Simplified Setup for Optimism Mainnet (L4 Data Collection)
 * Ver 2.0: Refined Roles & Idempotency
 */
contract L4SetupOpMainnet is Script {
    
    struct Config {
        address registry;
        address gToken;
        address staking;
        address superPaymaster;
        address paymasterFactory;
        address aPNTs;
        address xPNTsFactory;
        address simpleAccountFactory;
        address priceFeed;
        address blsAggregator;
    }
    Config config;

    // Fixed Addresses
    address constant DEPLOYER = 0x51Ac694981b6CEa06aA6c51751C227aac5F6b8A3; 
    address constant ANNI = 0x08822612177e93a5B8dA59b45171638eb53D495a;

    function setUp() public {
        string memory root = vm.projectRoot();
        string memory path = string.concat(root, "/deployments/config.optimism.json");
        string memory json = vm.readFile(path);

        config.registry = vm.parseJsonAddress(json, ".registry");
        config.gToken = vm.parseJsonAddress(json, ".gToken");
        config.staking = vm.parseJsonAddress(json, ".staking");
        config.superPaymaster = vm.parseJsonAddress(json, ".superPaymaster");
        config.paymasterFactory = vm.parseJsonAddress(json, ".paymasterFactory");
        config.aPNTs = vm.parseJsonAddress(json, ".aPNTs");
        config.xPNTsFactory = vm.parseJsonAddress(json, ".xPNTsFactory");
        config.simpleAccountFactory = vm.parseJsonAddress(json, ".simpleAccountFactory");
        config.priceFeed = vm.parseJsonAddress(json, ".priceFeed");
        config.blsAggregator = vm.parseJsonAddress(json, ".blsAggregator");
    }

    function run() external {
        address sender = msg.sender;
        console.log("-----------------------------------------");
        console.log("Running L4SetupMainnet as:", sender);
        console.log("-----------------------------------------");

        vm.startBroadcast();

        GToken gToken = GToken(config.gToken);
        Registry registry = Registry(config.registry);
        xPNTsFactory xFactory = xPNTsFactory(config.xPNTsFactory);
        SuperPaymaster sp = SuperPaymaster(payable(config.superPaymaster));
        xPNTsToken globalAPNTs = xPNTsToken(config.aPNTs);
        PaymasterFactory pmFactory = PaymasterFactory(config.paymasterFactory);

        // Core Management (Jason Only)
        if (sender == DEPLOYER) {
            // 1. BLS Aggregator Configuration
            address currentAggregator = sp.BLS_AGGREGATOR();
            if (currentAggregator == address(0)) {
                if (config.blsAggregator != address(0)) {
                    sp.setBLSAggregator(config.blsAggregator);
                    console.log(unicode"🔧 Set BLS_AGGREGATOR on SP:", config.blsAggregator);
                } else {
                    console.log(unicode"⚠️ BLS_AGGREGATOR not found in config");
                }
            } else {
                console.log(unicode"✅ BLS_AGGREGATOR already set:", currentAggregator);
                if (currentAggregator != config.blsAggregator) {
                    console.log(unicode"⚠️ Config mismatch! Current:", currentAggregator);
                    console.log(unicode"   Configured:", config.blsAggregator);
                }
            }

            // 2. Refined Funding Logic
            // GToken: Threshold 100, Top-up 200
            if (gToken.balanceOf(ANNI) < 100 ether) {
                gToken.transfer(ANNI, 200 ether);
                console.log(unicode"✅ Sent 200 GToken to Anni");
            }
            // aPNTs: Threshold 300, Top-up 2000
            if (globalAPNTs.balanceOf(ANNI) < 300 ether) {
                globalAPNTs.transfer(ANNI, 2000 ether);
                console.log(unicode"   ✅ Sent 2000 aPNTs to Anni");
            }

            // 3. Smart Price Refresh
            (int256 price, uint256 timestamp, , ) = sp.cachedPrice();
            if (timestamp == 0 || block.timestamp - timestamp > sp.priceStalenessThreshold()) {
                try sp.updatePrice() {
                     console.log(unicode"   ✅ SuperPaymaster price refreshed");
                } catch {
                     console.log(unicode"   ⚠️ SuperPaymaster price refresh failed");
                }
            } else {
                 console.log(unicode"   ✅ SuperPaymaster price is fresh");
            }
        }

        address[2] memory users;
        users[0] = DEPLOYER;
        users[1] = ANNI;

        for (uint i = 0; i < 2; i++) {
            address user = users[i];
            console.log("--- Processing Account:", user == DEPLOYER ? "Jason" : "Anni");

            // -------------------------------------------------------------
            // Step 1: Community Role (Both Jason & Anni EOAs)
            // -------------------------------------------------------------
            bytes32 ROLE_COMMUNITY = registry.ROLE_COMMUNITY();
            if (!registry.hasRole(ROLE_COMMUNITY, user)) {
                gToken.approve(config.staking, 100 ether);
                Registry.CommunityRoleData memory data;
                if (user == DEPLOYER) {
                    data = Registry.CommunityRoleData({
                        name: "AAStar", ensName: "aastar.eth", website: "https://aastar.io",
                        description: "AAStar Community", logoURI: "ipfs://...", stakeAmount: 30 ether
                    });
                } else {
                    data = Registry.CommunityRoleData({
                        name: "Mycelium", ensName: "mushroom.box", website: "https://mushroom.box",
                        description: "Mycelium Network", logoURI: "ipfs://...", stakeAmount: 30 ether
                    });
                }
                registry.registerRole(ROLE_COMMUNITY, user, abi.encode(data));
                console.log(unicode"✅ Community Registered");
            }

            // -------------------------------------------------------------
            // Step 2: Paymaster Roles & Deployment (Divergent Path)
            // -------------------------------------------------------------
            if (user == DEPLOYER) {
                // Jason: PaymasterV4 Role (ROLE_PAYMASTER_AOA)
                
                // A. Deploy/Get PaymasterV4
                address pm = pmFactory.getPaymasterByOperator(DEPLOYER);
                if (pm == address(0)) {
                    console.log(unicode"⛽ Deploying PaymasterV4...");
                    bytes memory init = abi.encodeWithSignature(
                        "initialize(address,address,address,address,uint256,uint256,uint256)",
                        0x0000000071727De22E5E9d8BAf0edAc6f37da032, // EntryPoint
                        DEPLOYER, DEPLOYER, config.priceFeed, 
                        100, 1 ether, 86400
                    );
                    pm = pmFactory.deployPaymaster("v4.2", init);
                    console.log(unicode"   ✅ PaymasterV4 Deployed:", pm);
                    Paymaster(payable(pm)).addStake{value: 0.05 ether}(86400);
                    Paymaster(payable(pm)).setTokenPrice(config.aPNTs, 100000000); // $1
                } else {
                    console.log(unicode"✅ PaymasterV4 exists:", pm);
                }

                // Activate Anni's token in PMV4 (Critical for T2.1/T5)
                address anniToken = xFactory.getTokenAddress(ANNI);
                if (anniToken != address(0)) {
                    Paymaster pmV4 = Paymaster(payable(pm));
                    if (pmV4.tokenPrices(anniToken) == 0 && sender == DEPLOYER) {
                        pmV4.setTokenPrice(anniToken, 100000000);
                        console.log(unicode"   ✅ Activated Anni PNTs in Jason's PM V4");
                    }
                }

                // B. Register ROLE_PAYMASTER_AOA
                bytes32 ROLE_AOA = registry.ROLE_PAYMASTER_AOA();
                if (!registry.hasRole(ROLE_AOA, user)) {
                     gToken.approve(config.staking, 100 ether);
                     Registry.PaymasterRoleData memory pmData = Registry.PaymasterRoleData({
                         paymasterContract: pm,
                         name: "AAStar Paymaster",
                         apiEndpoint: "https://rpc.aastar.io",
                         stakeAmount: 30 ether
                     });
                     registry.registerRole(ROLE_AOA, user, abi.encode(pmData));
                     console.log(unicode"✅ Registered ROLE_PAYMASTER_AOA");
                }

            } else if (user == ANNI) {
                // Anni: SuperPaymaster Role (ROLE_PAYMASTER_SUPER)

                // A. Ensure Token Exists
                address myToken = xFactory.getTokenAddress(user);
                if (myToken == address(0)) {
                    myToken = xFactory.deployxPNTsToken("PNTs Token", "PNTs", "Mycelium", "mushroom.box", 1e18, address(0));
                    console.log(unicode"✅ Deployed PNTs for Anni:", myToken);
                }

                // B. Register ROLE_PAYMASTER_SUPER
                bytes32 ROLE_SP = registry.ROLE_PAYMASTER_SUPER();
                if (!registry.hasRole(ROLE_SP, user)) {
                    gToken.approve(config.staking, 100 ether);
                    Registry.PaymasterRoleData memory spData = Registry.PaymasterRoleData({
                         paymasterContract: config.superPaymaster,
                         name: "Mycelium SuperPM",
                         apiEndpoint: "",
                         stakeAmount: 50 ether
                    });
                    registry.registerRole(ROLE_SP, user, abi.encode(spData));
                    console.log(unicode"✅ Registered ROLE_PAYMASTER_SUPER");
                }

                // C. Configure Operator in SuperPaymaster
                (,, bool isConfigured, , , , , , , ) = sp.operators(user);
                if (!isConfigured) {
                     sp.configureOperator(myToken, user, 1e18);
                     console.log(unicode"✅ SuperPM Operator Configured");
                }
            }

            // -------------------------------------------------------------
            // Step 3: AA Setup (Smart Wallet)
            // -------------------------------------------------------------
            ISimpleAccountFactory aaSAccountFactory = ISimpleAccountFactory(config.simpleAccountFactory);
            address myAA = aaSAccountFactory.getAddress(user, 0);
            uint256 size; assembly { size := extcodesize(myAA) }
            if (size == 0) {
                aaSAccountFactory.createAccount(user, 0);
                console.log(unicode"🏭 AA Account Deployed:", myAA);
            }

            // -------------------------------------------------------------
            // Step 4: ENDUSER Role (AA Only)
            // -------------------------------------------------------------
            bytes32 ROLE_ENDUSER = registry.ROLE_ENDUSER();
            if (!registry.hasRole(ROLE_ENDUSER, myAA)) {
                // Ensure ROLE_ENDUSER is active (Deployer maintenance)
                if (user == DEPLOYER && sender == DEPLOYER) {
                    (address roleOwner) = registry.roleOwners(ROLE_ENDUSER);
                    // Minimal Config if needed
                     IRegistry.RoleConfig memory euConfig = IRegistry.RoleConfig({
                        minStake: 1 wei, entryBurn: 0, slashThreshold: 0, slashBase: 0, slashInc: 0, slashMax: 0,
                        exitFeePercent: 0, isActive: true, minExitFee: 0, description: "EndUser Role",
                        owner: DEPLOYER, roleLockDuration: 0
                     });

                     if (roleOwner == address(0)) {
                         console.log(unicode"📝 Creating ROLE_ENDUSER...");
                         registry.createNewRole(ROLE_ENDUSER, euConfig, DEPLOYER);
                     } else {
                         (,,,,,,,bool isActive,,,,) = registry.roleConfigs(ROLE_ENDUSER);
                         if (!isActive && roleOwner == DEPLOYER) {
                            console.log(unicode"📝 Activating ROLE_ENDUSER...");
                            registry.configureRole(ROLE_ENDUSER, euConfig);
                         }
                     }
                }

                if (gToken.balanceOf(user) >= 1 ether) {
                    gToken.transfer(myAA, 1 ether);
                    ISimpleAccount(myAA).execute(address(gToken), 0, abi.encodeCall(gToken.approve, (config.staking, 1 ether)));
                    
                    Registry.EndUserRoleData memory euData = Registry.EndUserRoleData({
                        account: myAA, community: user, avatarURI: "", ensName: "", stakeAmount: 0.3 ether
                    });
                    registry.registerRole(ROLE_ENDUSER, myAA, abi.encode(euData));
                    console.log(unicode"✅ AA registered as ENDUSER");
                }
            }
        }

        vm.stopBroadcast();
    }
}
