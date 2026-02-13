// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// Interfaces & Core
import "src/core/Registry.sol";
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
 * Run this script TWICE:
 * 1. As Jason (Deployer): Checks AAStar, ensures V4 PM, deploys Jason_AA1
 *    `forge script script/v3/L4SetupOpMainnet.s.sol --rpc-url $RPC_URL --account optimism-deployer --broadcast`
 * 2. As Anni: Registers Mycelium, Deploys PNTs, Configures SuperPM, deploys Anni_AA1
 *    `forge script script/v3/L4SetupOpMainnet.s.sol --rpc-url $RPC_URL --account optimism-anni --broadcast`
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
    }
    Config config;

    // Fixed Addresses
    address constant DEPLOYER = 0x51Ac694981b6CEa06aA6c51751C227aac5F6b8A3; 

    function setUp() public {
        string memory root = vm.projectRoot();
        // Always load optimism config for mainnet
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
    }

    function run() external {
        address user = msg.sender;
        console.log("-----------------------------------------");
        console.log("Running L4SetupMainnet as:", user);
        console.log("-----------------------------------------");

        if (user == 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38) {
            console.log(unicode"❌ Error: Using default Foundry sender (0x1804...)!");
            console.log(unicode"   Please add the --sender flag to your command:");
            console.log(unicode"   Jason: --sender 0x51Ac694981b6CEa06aA6c51751C227aac5F6b8A3");
            console.log(unicode"   Anni:  --sender 0x08822612177e93a5B8dA59b45171638eb53D495a");
            revert("Incorrect Sender");
        }

        vm.startBroadcast();

        // 1. GToken check (Mint if needed - only Deployer can mint easily, others need transfer)
        // If user is NOT deployer and has low GToken, we assume Deployer sent some manually or in previous steps.
        // For simplicity, we just check and warn.
        GToken gToken = GToken(config.gToken);
        if (gToken.balanceOf(user) < 30 ether) {
             console.log(unicode"⚠️  Low GToken Balance! You need > 30 GT to register community.");
             // Try minting if we are deployer (owner)
             if (user == DEPLOYER || user == gToken.owner()) {
                 gToken.mint(user, 1000 ether);
                 console.log(unicode"   ✅ Minted 1000 GToken to self");
             }
        }

        // 1.1 Funding Helper (Jason Funds Anni with GToken AND aPNTs)
        // Anni needs ~33 GToken for registering.
        // Anni needs ~5000 aPNTs for SuperPaymaster deposit.
        address ANNI = 0x08822612177e93a5B8dA59b45171638eb53D495a;
        if (user == DEPLOYER) {
            // GToken
            if (gToken.balanceOf(ANNI) < 100 ether) {
                console.log(unicode"💸 Funding Anni with GToken...");
                gToken.transfer(ANNI, 100 ether);
                console.log(unicode"   ✅ Sent 100 GToken to Anni");
            }
            
            // aPNTs (Global Token for SuperPM Stake)
            xPNTsToken globalAPNTs = xPNTsToken(config.aPNTs);
            if (globalAPNTs.balanceOf(ANNI) < 5000 ether) {
                 console.log(unicode"💸 Funding Anni with aPNTs...");
                 // Try mint if Jason is owner/minter, otherwise transfer
                 try globalAPNTs.mint(ANNI, 10000 ether) {
                     console.log(unicode"   ✅ Minted 10k aPNTs to Anni");
                 } catch {
                     // Fallback: Transfer from Jason if he has balance
                     if (globalAPNTs.balanceOf(user) > 10000 ether) {
                         globalAPNTs.transfer(ANNI, 10000 ether);
                         console.log(unicode"   ✅ Transferred 10k aPNTs to Anni");
                     } else {
                         console.log(unicode"   ⚠️  Could not fund Anni with aPNTs (Check Jason's balance/role)");
                     }
                 }
            }
        }

        // 2. Community Registration
        Registry registry = Registry(config.registry);
        bytes32 ROLE_COMMUNITY = registry.ROLE_COMMUNITY();
        
        if (registry.hasRole(ROLE_COMMUNITY, user)) {
            console.log(unicode"✅ Already Registered as Community");
        } else {
            console.log(unicode"📝 Registering Community...");
            // Approve Staking
            gToken.approve(config.staking, 100 ether);
            
            Registry.CommunityRoleData memory data;
            if (user == DEPLOYER) {
                // Jason / AAStar (Should exist, but for recovery)
                data = Registry.CommunityRoleData({
                    name: "AAStar",
                    ensName: "aastar.eth",
                    website: "https://aastar.io",
                    description: "AAStar - Empower Community!",
                    logoURI: "ipfs://bafkreihqmsnyn4s5rt6nnyrxbwaufzmrsr2xfbj4yeqgi6qdr35umzxiay",
                    stakeAmount: 30 ether
                });
            } else {
                // Anni / Mycelium
                data = Registry.CommunityRoleData({
                    name: "Mycelium",
                    ensName: "mycelium.eth",
                    website: "https://mushroom.box",
                    description: "Connect to the Mycelium Network",
                    logoURI: "ipfs://bafybeiait3ds2fn42kmnu3ofp73ycujgppks3ma3zzvxnedthunpsrvn7e",
                    stakeAmount: 30 ether
                });
            }
            registry.registerRole(ROLE_COMMUNITY, user, abi.encode(data));
            console.log(unicode"   ✅ Registered Community:", data.name);
        }

        // 3. Token Deployment (xPNTs)
        xPNTsFactory factory = xPNTsFactory(config.xPNTsFactory);
        address myToken = factory.getTokenAddress(user);
        
        if (myToken == address(0)) {
            console.log(unicode"🏭 Deploying xPNTs Token...");
            if (user == DEPLOYER) {
                // Jason uses aPNTs - usually pre-deployed. 
                // If address(0), something is wrong or factory index mismatch.
                // We'll skip redeploying aPNTs to avoid confusion, assuming config.aPNTs is correct.
                console.log(unicode"   ⚠️  Deployer has no token in Factory? Using config.aPNTs:", config.aPNTs);
                myToken = config.aPNTs;
            } else {
                // Anni
                myToken = factory.deployxPNTsToken(
                    "PNTs Token", "PNTs", "Mycelium", "mycelium.eth", 1e18, address(0)
                );
                console.log(unicode"   ✅ Deployed PNTs:", myToken);
            }
        } else {
            console.log(unicode"✅ Token found:", myToken);
        }

        // 4. SuperPaymaster Operator Config
        // Anni needs to be an Operator + SuperPM Operator Role
        SuperPaymaster sp = SuperPaymaster(payable(config.superPaymaster));
        // operators struct has 10 fields: (uint128,uint96,bool,bool,address,uint32,uint48,address,uint256,uint256)
        // We need index 0 (balance) and index 2 (isConfigured)
        (uint128 bal, , bool isConfigured, , , , , , , ) = sp.operators(user);

        if (!isConfigured) {
             console.log(unicode"🔧 Configuring SuperPaymaster Operator...");
             // Register ROLE first
             bytes32 ROLE_SUPER_PM = registry.ROLE_PAYMASTER_SUPER();
             if (!registry.hasRole(ROLE_SUPER_PM, user)) {
                 // Register role (requires 50 GT stake usually, check Registry params)
                 // Assuming 30 is enough or strict
                 gToken.approve(config.staking, 100 ether);
                 registry.registerRole(ROLE_SUPER_PM, user, ""); 
                 console.log(unicode"   ✅ Registered ROLE_PAYMASTER_SUPER");
             }
             
             // Configure
             sp.configureOperator(myToken, user, 1e18); // 1:1 exchange rate
             console.log(unicode"   ✅ Configured Operator in SP");
        } else {
            console.log(unicode"✅ SuperPM Operator Configured");
        }
        
        // Deposit aPNTs to SuperPM (Credit)
        // We must deposit aPNTs (config.aPNTs), NOT our own xPNTs token.
        // We still check myToken to start minting xPNTs as well for user distribution later
        if (myToken != address(0) && user != DEPLOYER) {
            // Mint xPNTs for Users (Just to have some)
            xPNTsToken chToken = xPNTsToken(myToken);
            if (chToken.balanceOf(user) < 5000 ether) {
                try chToken.mint(user, 10000 ether) {
                    console.log(unicode"   ✅ Minted 10k PNTs (Community Token)");
                } catch {}
            }
            
            // Deposit aPNTs for Operator Credit
            // Check SP balance
            (bal, , , , , , , , , ) = sp.operators(user);
            if (bal < 1000 ether) {
                xPNTsToken globalAPNTs = xPNTsToken(config.aPNTs);
                if (globalAPNTs.balanceOf(user) >= 5000 ether) {
                    globalAPNTs.approve(address(sp), 5000 ether);
                    sp.deposit(5000 ether);
                    console.log(unicode"   💰 Deposited 5000 aPNTs to SuperPM");
                } else {
                    console.log(unicode"   ⚠️  Insufficient aPNTs to deposit (Wait for funding)");
                }
            }
        }

        // 5. PaymasterV4 (Deployer Only)
        // If Jason, ensure he has a PaymasterV4
        if (user == DEPLOYER) {
             PaymasterFactory pmFactory = PaymasterFactory(config.paymasterFactory);
             address pm = pmFactory.getPaymasterByOperator(user);
             if (pm == address(0)) {
                 console.log(unicode"⛽ Deploying PaymasterV4...");
                 bytes memory init = abi.encodeWithSignature(
                    "initialize(address,address,address,address,uint256,uint256,uint256)",
                    0x0000000071727De22E5E9d8BAf0edAc6f37da032, // EntryPoint
                    user, user, config.priceFeed, 
                    100, 1 ether, 86400
                 );
                 pm = pmFactory.deployPaymaster("v4.2", init);
                 console.log(unicode"   ✅ PaymasterV4 Deployed:", pm);
                 // Stake & Config
                 Paymaster(payable(pm)).addStake{value: 0.05 ether}(86400);
                 Paymaster(payable(pm)).setTokenPrice(config.aPNTs, 100000000); // $1
             } else {
                 console.log(unicode"✅ PaymasterV4 found:", pm);
             }
        }

        // 6. AA Account (Deploy 1 per user)
        ISimpleAccountFactory aaFactory = ISimpleAccountFactory(config.simpleAccountFactory);
        address myAA = aaFactory.getAddress(user, 0); // salt 0
        uint256 size;
        assembly { size := extcodesize(myAA) }
        
        if (size == 0) {
            console.log(unicode"🏭 Deploying AA Account:", myAA);
            aaFactory.createAccount(user, 0);
        } else {
             console.log(unicode"✅ AA Account exists:", myAA);
        }
        
        // Fund AA (0.002 ETH)
        if (myAA.balance < 0.002 ether) {
            console.log(unicode"⛽ Funding AA with 0.002 ETH...");
            (bool success, ) = myAA.call{value: 0.002 ether}("");
            require(success, "Fund failed");
        }

        // 7. Register AA as ENDUSER (Both users)
        bytes32 ROLE_ENDUSER = registry.ROLE_ENDUSER();
        if (!registry.hasRole(ROLE_ENDUSER, myAA)) {
            console.log(unicode"📝 Registering AA as ENDUSER...");
            
            // Fund AA with GToken for staking (0.3 min)
            if (gToken.balanceOf(myAA) < 1 ether) {
                gToken.transfer(myAA, 1 ether);
                console.log(unicode"   💸 Sent 1 GToken to AA for stake");
            }
            
            // The community for each user:
            // Jason's AA -> joins AAStar community (DEPLOYER)
            // Anni's AA -> joins Mycelium community (ANNI)
            address myCommunity = user; // Each registers under own community (they are community owners)
            
            Registry.EndUserRoleData memory euData = Registry.EndUserRoleData({
                account: myAA,
                community: myCommunity,
                avatarURI: "",
                ensName: "",
                stakeAmount: 0.3 ether
            });
            
            // AA must approve staking contract to spend its GToken
            // We call through SimpleAccount.execute since msg.sender is the AA's owner
            ISimpleAccount(myAA).execute(
                address(gToken),
                0,
                abi.encodeCall(gToken.approve, (config.staking, 1 ether))
            );
            registry.registerRole(ROLE_ENDUSER, myAA, abi.encode(euData));
            console.log(unicode"   ✅ AA registered as ENDUSER:", myAA);
        } else {
            console.log(unicode"✅ AA is already ENDUSER:", myAA);
        }

        // 8. Activate xPNTs in PaymasterV4 (Deployer Only)
        // Jason's PM needs to recognize Anni's community token for gasless payments
        if (user == DEPLOYER) {
            PaymasterFactory pmFactory = PaymasterFactory(config.paymasterFactory);
            address pm = pmFactory.getPaymasterByOperator(user);
            if (pm != address(0)) {
                Paymaster paymaster = Paymaster(payable(pm));
                
                // Get Anni's xPNTs token from factory
                xPNTsFactory xFactory = xPNTsFactory(config.xPNTsFactory);
                address anniToken = xFactory.getTokenAddress(ANNI);
                
                if (anniToken != address(0)) {
                    // Check if already activated
                    uint256 existingPrice = paymaster.tokenPrices(anniToken);
                    if (existingPrice == 0) {
                        // Set price: $1 = 100000000 (8 decimals like Chainlink)
                        paymaster.setTokenPrice(anniToken, 100000000);
                        console.log(unicode"   ✅ Activated Anni xPNTs in PM V4:", anniToken);
                    } else {
                        console.log(unicode"✅ Anni xPNTs already activated in PM V4 (price:", existingPrice, unicode")");
                    }
                } else {
                    console.log(unicode"   ⚠️ Anni has no token in xPNTsFactory yet");
                }
                
                // 9. Update cached price in PM (only if stale)
                {
                    (uint208 pmPrice, uint48 pmTs) = paymaster.cachedPrice();
                    uint256 pmThreshold = paymaster.priceStalenessThreshold();
                    if (pmTs == 0 || block.timestamp - uint256(pmTs) > pmThreshold) {
                        try paymaster.updatePrice() {
                            console.log(unicode"   ✅ PM V4 price refreshed");
                        } catch {
                            console.log(unicode"   ⚠️ PM updatePrice failed (Chainlink feed may be stale)");
                        }
                    } else {
                        console.log(unicode"✅ PM V4 price is fresh");
                    }
                }
            }
            
            // 10. Update SP cached price (only if stale)
            {
                SuperPaymaster sp = SuperPaymaster(payable(config.superPaymaster));
                (int256 spPrice, uint256 spTs, , ) = sp.cachedPrice();
                uint256 spThreshold = sp.priceStalenessThreshold();
                if (spTs == 0 || block.timestamp - spTs > spThreshold) {
                    try sp.updatePrice() {
                        console.log(unicode"   ✅ SP price refreshed");
                    } catch {
                        console.log(unicode"   ⚠️ SP updatePrice failed (Chainlink feed may be stale)");
                    }
                } else {
                    console.log(unicode"✅ SP price is fresh");
                }
            }
        }

        vm.stopBroadcast();
    }
}
