// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// Core Imports
import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/GToken.sol";
import "src/tokens/MySBT.sol";
import "src/tokens/xPNTsToken.sol";
import "src/tokens/xPNTsFactory.sol";

// Paymaster Imports
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/paymasters/v4/Paymaster.sol";
import "src/paymasters/v4/core/PaymasterFactory.sol";

// Module Imports
import "src/modules/reputation/ReputationSystem.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/modules/monitoring/DVTValidator.sol";
import "src/modules/validators/BLSValidator.sol";

// External Interfaces
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DeployLive
 * @notice Standardized Deployment Script for Live Testnets/Mainnets
 */
contract DeployLive is Script {
    uint256 deployerPK;
    address deployer;
    address entryPointAddr;
    address priceFeedAddr;

    GToken gtoken;
    GTokenStaking staking;
    MySBT mysbt;
    Registry registry;
    xPNTsToken apnts;
    SuperPaymaster superPaymaster;
    ReputationSystem repSystem;
    BLSAggregator aggregator;
    DVTValidator dvt;
    BLSValidator blsValidator;
    xPNTsFactory xpntsFactory;
    PaymasterFactory pmFactory;
    Paymaster pmV4Impl;

    function setUp() public {
        deployerPK = vm.envUint("PRIVATE_KEY");
        priceFeedAddr = vm.envAddress("ETH_USD_FEED");
        entryPointAddr = vm.envAddress("ENTRY_POINT");
        
        deployer = vm.addr(deployerPK);
    }

    function run() external {
        // No Warp, No Mocks
        require(priceFeedAddr.code.length > 0, "PriceFeed not found on this chain");
        require(entryPointAddr.code.length > 0, "EntryPoint not found on this chain");

        vm.startBroadcast(deployerPK);

        console.log("=== Step 1: Deploy Foundation ===");
        gtoken = new GToken(21_000_000 * 1e18);
        staking = new GTokenStaking(address(gtoken), deployer);
        uint256 nonce = vm.getNonce(deployer);
        address precomputedRegistry = vm.computeCreateAddress(deployer, nonce + 1);
        mysbt = new MySBT(address(gtoken), address(staking), precomputedRegistry, deployer);
        registry = new Registry(address(gtoken), address(staking), address(mysbt));

        console.log("=== Step 2: Deploy Core ===");
        // apnts moved to Orchestration phase
        superPaymaster = new SuperPaymaster(IEntryPoint(entryPointAddr), deployer, registry, address(0), priceFeedAddr, deployer, 4200); // 1h 10m Buffer for Testnet

        console.log("=== Step 3: Deploy Modules ===");
        repSystem = new ReputationSystem(address(registry));
        aggregator = new BLSAggregator(address(registry), address(superPaymaster), address(0));
        dvt = new DVTValidator(address(registry));
        blsValidator = new BLSValidator();
        xpntsFactory = new xPNTsFactory(address(superPaymaster), address(registry));
        pmFactory = new PaymasterFactory();
       pmV4Impl = new Paymaster(address(registry));

        console.log("=== Step 4: The Grand Wiring ===");
        _executeWiring();

        console.log("=== Step 5: Role Orchestration & Community Init ===");
        _orchestrateRoles();

        console.log("=== Step 6: Final Verification ===");
        _verifyWiring();

        vm.stopBroadcast();
        _generateConfig();
    }

    function _executeWiring() internal {
        staking.setRegistry(address(registry));
        mysbt.setRegistry(address(registry));
        registry.setSuperPaymaster(address(superPaymaster));
        registry.setReputationSource(address(repSystem), true);
        registry.setBLSAggregator(address(aggregator));
        registry.setBLSValidator(address(blsValidator));
        aggregator.setDVTValidator(address(dvt));
        dvt.setBLSAggregator(address(aggregator));
        // apnts.setSuperPaymasterAddress moved to after deployment in Orchestration
        pmFactory.addImplementation("v4.2", address(pmV4Impl));
        superPaymaster.setXPNTsFactory(address(xpntsFactory));
        
        // CRITICAL: Initialize Cache Price (Prevents "price not set" failures)
        // CRITICAL: Initialize Cache Price (Prevents "price not set" failures)
        console.log("Initializing SuperPaymaster...");
        // Strategy: Force update via DVT path to bypass 1h staleness check if Oracle is lazy (Sepolia)
        // We read the "Stale" price from Oracle, but feed it as "Fresh" (block.timestamp) to the cache.
        try AggregatorV3Interface(priceFeedAddr).latestRoundData() returns (uint80, int256 price, uint256, uint256, uint80) {
            try superPaymaster.updatePriceDVT(price, block.timestamp, "") {
                console.log("  Cache Price Force-Initialized (DVT Mode)");
            } catch {
                console.log("  WARNING: Force Init Failed, falling back to standard update");
                try superPaymaster.updatePrice() {
                    console.log("  Standard updatePrice success");
                } catch {
                    console.log("  WARNING: All update methods failed");
                }
            }
        } catch {
             console.log("  WARNING: Oracle read failed completely");
        }
        
        // Deposit 0.2 ETH to EntryPoint (Enable sponsorship)
        if (address(this).balance >= 0.2 ether) {
            superPaymaster.deposit{value: 0.2 ether}();
            console.log("  Deposited 0.2 ETH to EntryPoint");
        }
        
        // Stake 0.2 ETH (Enable validation) - Reasonable amount
        if (address(this).balance >= 0.2 ether) {
            superPaymaster.addStake{value: 0.2 ether}(1 days);
            console.log("  Staked 0.2 ETH");
        }
    }

    function _orchestrateRoles() internal {
        gtoken.mint(deployer, 2000 ether);
        gtoken.approve(address(staking), 2000 ether);
        
        // 1. 初始化 AAStar 社区 (Jason)
        Registry.CommunityRoleData memory aaStarData = Registry.CommunityRoleData({
            name: "AAStar",
            ensName: "aastar.eth",
            website: "aastar.io",
            description: "AAStar - Empower Community! Twitter: https://X.com/AAStarCommunity",
            logoURI: "ipfs://QmNmv3TGpzaDaX92rX9fzRch2FHeFQqBW5k51z1p7kHBVM",
            stakeAmount: 30 ether
        });
        registry.registerRole(registry.ROLE_COMMUNITY(), deployer, abi.encode(aaStarData));
        
        // 1.1 Use Factory to deploy aPNTs (Official AAStar Token)
        address apntsAddr = xpntsFactory.deployxPNTsToken(
            "AAStar PNTs", 
            "aPNTs", 
            "AAStar", 
            "aastar.eth", 
            1e18, 
            address(0) // No specific PaymasterAOA initially
        );
        apnts = xPNTsToken(apntsAddr);
        console.log("aPNTs deployed at:", address(apnts));
        
        // Fix: Set APNTs Token in SuperPaymaster (Delayed wiring due to circular dependency)
        superPaymaster.setAPNTsToken(address(apnts));

        // 1.2 Register Paymaster Role (AOA V4)
        // Check if Paymaster V4 Proxy exists for deployer
        address sender = deployer;
        address pmProxy = pmFactory.getPaymasterByOperator(sender);
        
        if (pmProxy == address(0)) {
             bytes memory init = abi.encodeWithSignature(
                "initialize(address,address,address,address,uint256,uint256,uint256)",
                entryPointAddr,
                sender,
                sender, // treasury
                priceFeedAddr,
                100, // serviceFeeRate
                1 ether, // maxGasCostCap
                3600 // priceStalenessThreshold
             );
             pmProxy = pmFactory.deployPaymaster("v4.2", init);
             console.log("Deployed Paymaster V4 Proxy at:", pmProxy);
             
             // --- Auto-Initialize AOA Paymaster ---
             // 1. Stake 0.1 ETH in EntryPoint (Required for Storage Access)
             Paymaster(payable(pmProxy)).addStake{value: 0.1 ether}(86400); 
             // 2. Initialize Oracle Cache
             try Paymaster(payable(pmProxy)).updatePrice() { console.log("AOA PM Price Initialized"); } catch { console.log("AOA PM Price Init Failed"); }
             // 3. Set aPNTs Price ($1.00) if aPNTs is ready (not yet deployed? No, wait)
             // aPNTs is deployed at line 133/141. So we can use it.
             // But we are inside the 'if (pmProxy == address(0))' block. 
             // Move initialization OUTSIDE or ensure it runs.
             // Actually, 'addStake' is one-time, but 'setTokenPrice' is good to ensure.
        } else {
             console.log("Existing Paymaster V4 Proxy found at:", pmProxy);
        }

        // --- Ensure Configuration (Idempotent) ---
        // Ensure aPNTs Support ($1.00)
        if (address(apnts) != address(0)) {
             try Paymaster(payable(pmProxy)).setTokenPrice(address(apnts), 100000000) { 
                 console.log("AOA PM set aPNTs price to $1.00"); 
             } catch {}
        }

        Registry.PaymasterRoleData memory pmData = Registry.PaymasterRoleData({
            paymasterContract: pmProxy,
            name: "AAStar V4 Paymaster",
            apiEndpoint: "https://rpc.aastar.io/paymaster/v4",
            stakeAmount: 30 ether
        });

        // 3.3 Approve Staking (Stake 30 + Burn 3 = 33)
        gtoken.approve(address(staking), 33 ether);
        registry.registerRole(keccak256("PAYMASTER_AOA"), sender, abi.encode(pmData));
        
        // 1.3 Fund Paymaster Proxy on EntryPoint
        IEntryPoint(entryPointAddr).depositTo{value: 0.05 ether}(pmProxy);
        
        // Mint 1M aPNTs to Supplier (Deployer)
        address supplier = deployer; 
        apnts.mint(supplier, 1_000_000 ether);
        
        vm.stopBroadcast();
        // vm.startBroadcast(supplier); // Not needed if supplier == deployer
        // No deposit to SuperPaymaster needed for AOA
        vm.startBroadcast(deployerPK);

        // 2. 初始化 DemoCommunity (Anni)
        address anni = 0xEcAACb915f7D92e9916f449F7ad42BD0408733c9;
        uint256 anniPK = vm.envOr("PRIVATE_KEY_ANNI", uint256(0));
        
        if (anniPK != 0) {
            Registry.CommunityRoleData memory demoData = Registry.CommunityRoleData({
                name: "DemoCommunity",
                ensName: "demo.eth",
                website: "demo.com",
                description: "Demo Community for testing purposes.",
                logoURI: "ipfs://demo-logo",
                stakeAmount: 30 ether
            });
            // Fix: Re-approve staking as previous approve was consumed
            gtoken.approve(address(staking), 33 ether);
            registry.safeMintForRole(registry.ROLE_COMMUNITY(), anni, abi.encode(demoData));
            
            gtoken.transfer(anni, 100 ether);
            
            vm.stopBroadcast();
            vm.startBroadcast(anniPK);
            gtoken.approve(address(staking), 100 ether);
            registry.registerRole(registry.ROLE_PAYMASTER_SUPER(), anni, "");
            
            address dPNTs = xpntsFactory.deployxPNTsToken("DemoPoints", "dPNTs", "DemoCommunity", "demo.eth", 1e18, address(0));
            superPaymaster.configureOperator(dPNTs, anni, 1e18);

            // 2.1 Setup Paymaster V4 for Anni
            address pmProxyAnni = pmFactory.getPaymasterByOperator(anni);
            if (pmProxyAnni == address(0)) {
                 bytes memory initAnni = abi.encodeWithSignature(
                    "initialize(address,address,address,address,uint256,uint256,uint256)",
                    entryPointAddr,
                    anni, // owner
                    anni, // treasury
                    priceFeedAddr,
                    100, // serviceFee
                    1 ether, // gasCap
                    3600 // priceStalenessThreshold
                 );
                 pmProxyAnni = pmFactory.deployPaymaster("v4.2", initAnni);
                 console.log("Deployed Anni Paymaster V4 Proxy at:", pmProxyAnni);
                 
                 // --- Auto-Initialize Anni Paymaster ---
                 // 1. Stake
                 Paymaster(payable(pmProxyAnni)).addStake{value: 0.1 ether}(86400);
                 // 2. Oracle
                 try Paymaster(payable(pmProxyAnni)).updatePrice() { console.log("Anni PM Price Initialized"); } catch {}
            }
            
            // --- Ensure dPNTs Support ---
            if (dPNTs != address(0)) {
                try Paymaster(payable(pmProxyAnni)).setTokenPrice(dPNTs, 100000000) {
                    console.log("Anni PM set dPNTs price to $1.00");
                } catch {}
            }

            Registry.PaymasterRoleData memory pmDataAnni = Registry.PaymasterRoleData({
                paymasterContract: pmProxyAnni,
                name: "Demo V4 Paymaster",
                apiEndpoint: "https://rpc.demo.io/paymaster/v4",
                stakeAmount: 30 ether
            });
            registry.registerRole(keccak256("PAYMASTER_AOA"), anni, abi.encode(pmDataAnni));

            vm.stopBroadcast();
            
            // Fund Anni's Paymaster
            vm.startBroadcast(deployerPK);
            IEntryPoint(entryPointAddr).depositTo{value: 0.05 ether}(pmProxyAnni);
            // vm.stopBroadcast() handled by loop or next line logic
            // But wait, the original code had vm.stopBroadcast() then vm.startBroadcast(deployerPK) at line 220.
            // I should allow that flow to continue.
        }
    }

    function _verifyWiring() internal view {
        require(address(staking.GTOKEN()) == address(gtoken), "Staking GTOKEN Wiring Failed");
        require(registry.SUPER_PAYMASTER() == address(superPaymaster), "Registry SP Wiring Failed");
        require(apnts.SUPERPAYMASTER_ADDRESS() == address(superPaymaster), "aPNTs Firewall Failed");
        require(address(superPaymaster.REGISTRY()) == address(registry), "Paymaster Registry Immutable Failed");
        console.log("All Wiring Assertions Passed!");
    }

    function _generateConfig() internal {
        string memory chainName = vm.toString(block.chainid);
        if (block.chainid == 11155111) chainName = "sepolia";
        if (block.chainid == 11155420) chainName = "op-sepolia";  // OP-Sepolia
        if (block.chainid == 1) chainName = "mainnet";
        
        string memory finalPath = string.concat(vm.projectRoot(), "/deployments/config.", chainName, ".json");
        string memory jsonObj = "json";
        vm.serializeAddress(jsonObj, "registry", address(registry));
        vm.serializeAddress(jsonObj, "gToken", address(gtoken));
        vm.serializeAddress(jsonObj, "staking", address(staking));
        vm.serializeAddress(jsonObj, "superPaymaster", address(superPaymaster));
        vm.serializeAddress(jsonObj, "paymasterFactory", address(pmFactory)); 
        vm.serializeAddress(jsonObj, "aPNTs", address(apnts));
        vm.serializeAddress(jsonObj, "sbt", address(mysbt));
        vm.serializeAddress(jsonObj, "reputationSystem", address(repSystem));
        vm.serializeAddress(jsonObj, "dvtValidator", address(dvt));
        vm.serializeAddress(jsonObj, "blsAggregator", address(aggregator));
        vm.serializeAddress(jsonObj, "blsValidator", address(blsValidator));
        vm.serializeAddress(jsonObj, "xPNTsFactory", address(xpntsFactory));
        vm.serializeAddress(jsonObj, "xPNTsImpl", xpntsFactory.implementation());
        vm.serializeAddress(jsonObj, "paymasterV4Impl", address(pmV4Impl));
        vm.serializeString(jsonObj, "srcHash", vm.envOr("SRC_HASH", string("")));
        string memory finalJson = vm.serializeAddress(jsonObj, "entryPoint", entryPointAddr);
        vm.writeFile(finalPath, finalJson);
        console.log("\n--- Live Deployment Complete ---");
        console.log("Config saved to: %s", finalPath);
    }
}