// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";

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
import {EntryPoint} from "@account-abstraction-v7/core/EntryPoint.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title DeployLive
 * @notice Phase 1: Core Infrastructure Deployment (Steps 1-38)
 */
contract DeployLive is Script {
    using Clones for address;

    uint256 deployerPK;
    address deployer;
    address entryPointAddr;
    address priceFeedAddr;
    address simpleAccountFactory;

    GToken gtoken;
    GTokenStaking staking;
    MySBT mysbt;
    Registry registry;
    xPNTsToken apnts;
    SuperPaymaster superPaymaster;
    ReputationSystem repSystem;
    BLSAggregator aggregator;
    DVTValidator dvt;
    address blsValidator;
    xPNTsFactory xpntsFactory;
    PaymasterFactory pmFactory;
    Paymaster pmV4Impl;

    function setUp() public {
        deployerPK = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPK);
        
        // System / External Infrastructure (Remains in ENV)
        entryPointAddr = vm.envAddress("ENTRY_POINT");
        priceFeedAddr = vm.envAddress("ETH_USD_FEED");
        simpleAccountFactory = vm.envAddress("SIMPLE_ACCOUNT_FACTORY");
    }

    function run() external {
        vm.startBroadcast(deployerPK);

        console.log("=== Step 1: Deploy Foundation ===");
        gtoken = new GToken(21_000_000 * 1e18);
        staking = new GTokenStaking(address(gtoken), deployer);
        uint256 nonce = vm.getNonce(deployer);
        address precomputedRegistry = vm.computeCreateAddress(deployer, nonce + 1);
        mysbt = new MySBT(address(gtoken), address(staking), precomputedRegistry, deployer);
        registry = new Registry(address(gtoken), address(staking), address(mysbt));

        console.log("=== Step 2: Deploy Core ===");
        xpntsFactory = new xPNTsFactory(address(0), address(registry));
        superPaymaster = new SuperPaymaster(IEntryPoint(entryPointAddr), deployer, registry, address(0), priceFeedAddr, deployer, 86400);

        console.log("=== Step 3: Deploy Modules ===");
        repSystem = new ReputationSystem(address(registry));
        aggregator = new BLSAggregator(address(registry), address(superPaymaster), address(0));
        dvt = new DVTValidator(address(registry));
        
        blsValidator = address(new BLSValidator());
        pmFactory = new PaymasterFactory();
        pmV4Impl = new Paymaster(address(registry));

        console.log("=== Step 4: The Grand Wiring ===");
        _executeWiring();

        console.log("=== Step 5: Role Orchestration (Jason Final) ===");
        _orchestrateRolesJason();

        vm.stopBroadcast();
        _generateConfig();
    }

    function _executeWiring() internal {
        staking.setRegistry(address(registry));
        mysbt.setRegistry(address(registry));
        registry.setSuperPaymaster(address(superPaymaster));
        registry.setReputationSource(address(repSystem), true);
        registry.setBLSAggregator(address(aggregator));
        registry.setBLSValidator(blsValidator);
        aggregator.setDVTValidator(address(dvt));
        dvt.setBLSAggregator(address(aggregator));
        pmFactory.addImplementation("v4.2", address(pmV4Impl));
        superPaymaster.setXPNTsFactory(address(xpntsFactory));
        xpntsFactory.setSuperPaymasterAddress(address(superPaymaster));
        
        // Oracle Init
        try AggregatorV3Interface(priceFeedAddr).latestRoundData() returns (uint80, int256 price, uint256, uint256, uint80) {
            try superPaymaster.updatePriceDVT(price, block.timestamp, "") {
                console.log("  Cache Price Force-Initialized");
            } catch {
                superPaymaster.updatePrice();
            }
        } catch {}

        // Step 24 & 25: 0.1 ETH
        superPaymaster.deposit{value: 0.1 ether}();
        superPaymaster.addStake{value: 0.1 ether}(1 days);
    }

    function _orchestrateRolesJason() internal {
        gtoken.mint(deployer, 2000 ether); // Increased to 2000 to cover sub-sequent roles and Anni funding
        gtoken.approve(address(staking), 2000 ether);
        
        // Step 28: Register AAStar
        Registry.CommunityRoleData memory aaStarData = Registry.CommunityRoleData({
            name: "AAStar",
            ensName: "aastar.eth",
            website: "aastar.io",
            description: "AAStar Community - Empower Community!",
            logoURI: "ipfs://aastar-logo",
            stakeAmount: 30 ether
        });
        registry.registerRole(registry.ROLE_COMMUNITY(), deployer, abi.encode(aaStarData));
        
        // Step 29: aPNTs
        address apntsAddr = xpntsFactory.deployxPNTsToken("AAStar PNTs", "aPNTs", "AAStar", "aastar.eth", 1e18, address(0));
        apnts = xPNTsToken(apntsAddr);
        console.log("  aPNTs Deployed at:", apntsAddr);
        
        // Factory handles auto-wiring of SuperPaymaster firewall if set beforehand
        require(apnts.SUPERPAYMASTER_ADDRESS() == address(superPaymaster), "Deploy: aPNTs Factory auto-wiring failed!");
        
        superPaymaster.setAPNTsToken(apntsAddr);
        console.log("  aPNTs Firewall auto-wired via Factory to SP:", address(superPaymaster));

        // Step 31-36: AOA Paymaster
        bytes memory init = abi.encodeWithSignature(
            "initialize(address,address,address,address,uint256,uint256,uint256)",
            entryPointAddr, deployer, deployer, priceFeedAddr, 100, 1 ether, 86400
        );
        address pmProxy = pmFactory.deployPaymaster("v4.2", init);
        Paymaster(payable(pmProxy)).addStake{value: 0.05 ether}(86400); // Reduced to 0.05 ETH as requested
        Paymaster(payable(pmProxy)).updatePrice();
        // Step 34: $0.02
        Paymaster(payable(pmProxy)).setTokenPrice(address(apnts), 2_000_000); 

        Registry.PaymasterRoleData memory pmData = Registry.PaymasterRoleData({
            paymasterContract: pmProxy,
            name: "Jason V4 PM",
            apiEndpoint: "https://rpc.aastar.io/pm",
            stakeAmount: 30 ether
        });
        gtoken.approve(address(staking), 33 ether);
        registry.registerRole(keccak256("PAYMASTER_AOA"), deployer, abi.encode(pmData));
        
        // Step 37: 0.05 ETH
        IEntryPoint(entryPointAddr).depositTo{value: 0.05 ether}(pmProxy);
        
        // Step 38: Mint 20,000 aPNTs
        apnts.mint(deployer, 20_000 ether);

        // EXTRA STEP: Register as SuperPaymaster Operator (Required for deposit)
        // Note: Stake 50 ETH (Standard)
        Registry.GenericRoleData memory spRoleData = Registry.GenericRoleData({
            name: "Jason SuperPM",
            extraData: "",
            stakeAmount: 50 ether
        });
        gtoken.approve(address(staking), 55 ether); // 33 for AOA + 55 for Super (Total ~88 safe buffer)
        registry.registerRole(registry.ROLE_PAYMASTER_SUPER(), deployer, abi.encode(spRoleData));
        

        // NEW: Deposit into SuperPaymaster as active Operating Balance
        apnts.approve(address(superPaymaster), 500 ether);
        superPaymaster.deposit(500 ether);
        console.log("  500 aPNTs Deposited into SuperPaymaster for Deployer");
    }

    function _generateConfig() internal {
        string memory network = vm.envString("ENV");
        string memory finalPath = string.concat(vm.projectRoot(), "/deployments/config.", network, ".json");
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
        vm.serializeAddress(jsonObj, "blsValidator", blsValidator);
        vm.serializeAddress(jsonObj, "xPNTsFactory", address(xpntsFactory));
        vm.serializeAddress(jsonObj, "paymasterV4Impl", address(pmV4Impl));
        vm.serializeAddress(jsonObj, "simpleAccountFactory", simpleAccountFactory);
        vm.serializeString(jsonObj, "srcHash", vm.envOr("SRC_HASH", string("")));
        vm.serializeAddress(jsonObj, "priceFeed", priceFeedAddr);
        string memory finalJson = vm.serializeAddress(jsonObj, "entryPoint", entryPointAddr);
        vm.writeFile(finalPath, finalJson);
        console.log("\n--- Live Phase 1 Complete ---");
        console.log("Config saved to: %s", finalPath);
    }
}