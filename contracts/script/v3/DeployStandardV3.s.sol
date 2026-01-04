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
import "src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol";
import "src/paymasters/v4/PaymasterV4.sol";
import "src/paymasters/v4/PaymasterV4_2.sol";
import "src/paymasters/v4/core/PaymasterFactory.sol";

// Module Imports
import "src/modules/reputation/ReputationSystemV3.sol";
import "src/modules/monitoring/BLSAggregatorV3.sol";
import "src/modules/monitoring/DVTValidatorV3.sol";
import "src/modules/validators/BLSValidator.sol";

// External Interfaces
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";

contract MockPriceFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000 * 1e8, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

contract MockEntryPoint {
    function depositTo(address) external payable {}
    function getUserOpHash(PackedUserOperation calldata) external pure returns (bytes32) {
        return keccak256("mock_hash");
    }
    function getDepositInfo(address) external pure returns (IStakeManager.DepositInfo memory) {
        return IStakeManager.DepositInfo(0, false, 0, 0, 0);
    }
}

/**
 * @title DeployStandardV3
 * @notice Standardized V3/V4 Deployment Script
 */
contract DeployStandardV3 is Script {
    // -----------------------------------------------------------------------
    // Config
    // -----------------------------------------------------------------------
    uint256 deployerPK;
    address deployer;
    address entryPointAddr;
    address priceFeedAddr;
    string configPath;

    // -----------------------------------------------------------------------
    // Instances
    // -----------------------------------------------------------------------
    GToken gtoken;
    GTokenStaking staking;
    MySBT mysbt;
    Registry registry;
    xPNTsToken apnts;
    SuperPaymasterV3 superPaymaster;
    ReputationSystemV3 repSystem;
    BLSAggregatorV3 aggregator;
    DVTValidatorV3 dvt;
    BLSValidator blsValidator;
    xPNTsFactory xpntsFactory;
    PaymasterFactory pmFactory;
    PaymasterV4_2 pmV4Impl;

    function setUp() public {
        if (block.chainid == 31337) { 
            deployerPK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
            priceFeedAddr = 0x694AA1769357215DE4FAC081bf1f309aDC325306; 
            entryPointAddr = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789; 
        } else {
            deployerPK = vm.envOr("PRIVATE_KEY", uint256(0));
            priceFeedAddr = vm.envOr("ETH_USD_FEED", address(0));
            entryPointAddr = vm.envOr("ENTRY_POINT", address(0));
        }
        
        if (deployerPK != 0) {
            deployer = vm.addr(deployerPK);
        }

        string memory root = vm.projectRoot();
        string memory configFileName = vm.envOr("CONFIG_FILE", string("config.json"));
        configPath = string.concat(root, "/", configFileName);
    }

    function run() external {
        vm.warp(block.timestamp + 1 days); 
        
        if (block.chainid == 31337) {
            vm.startBroadcast(deployerPK);
            MockPriceFeed mockFeed = new MockPriceFeed();
            priceFeedAddr = address(mockFeed);
            
            MockEntryPoint mockEP = new MockEntryPoint();
            entryPointAddr = address(mockEP);
            vm.stopBroadcast();
            
            console.log("Anvil: Deployed Mocks (PriceFeed and EntryPoint)");
        }

        vm.startBroadcast(deployerPK);

        console.log("=== Step 1: Deploy Foundation (Asset Layer) ===");
        _deployFoundation();

        console.log("=== Step 2: Deploy Core (Logic Layer) ===");
        _deployCore();

        console.log("=== Step 3: Deploy Modules (Feature Layer) ===");
        _deployModules();

        console.log("=== Step 4: The Grand Wiring (Interconnection) ===");
        _executeWiring();

        console.log("=== Step 5: Role Orchestration (Bootstrapping) ===");
        _orchestrateRoles();

        console.log("=== Step 6: Final Verification (Assertions) ===");
        _verifyWiring();

        vm.stopBroadcast();

        _generateConfig();
        console.log("Deployment Complete. Config saved to:", configPath);
    }

    function _verifyWiring() internal view {
        require(address(staking.GTOKEN()) == address(gtoken), "Staking GTOKEN Wiring Failed");
        require(registry.SUPER_PAYMASTER() == address(superPaymaster), "Registry SP Wiring Failed");
        require(apnts.SUPERPAYMASTER_ADDRESS() == address(superPaymaster), "aPNTs Firewall Failed");
        require(address(superPaymaster.REGISTRY()) == address(registry), "Paymaster Registry Immutable Failed");
        require(mysbt.REGISTRY() == address(registry), "MySBT Registry Wiring Failed");
        require(mysbt.SUPER_PAYMASTER() == address(superPaymaster), "MySBT SP Wiring Failed");
        
        console.log("All Wiring Assertions Passed!");
    }

    function _deployFoundation() internal {
        gtoken = new GToken(21_000_000 * 1e18);
        staking = new GTokenStaking(address(gtoken), deployer);
        
        uint256 nonce = vm.getNonce(deployer);
        address precomputedRegistry = vm.computeCreateAddress(deployer, nonce + 1);
        
        mysbt = new MySBT(address(gtoken), address(staking), precomputedRegistry, deployer);
        registry = new Registry(address(gtoken), address(staking), address(mysbt));
    }

    function _deployCore() internal {
        apnts = new xPNTsToken("AAStar PNTs", "aPNTs", deployer, "GlobalHub", "local.eth", 1e18);
        
        superPaymaster = new SuperPaymasterV3(
            IEntryPoint(entryPointAddr),
            deployer,
            registry,
            address(apnts),
            priceFeedAddr,
            deployer
        );
    }

    function _deployModules() internal {
        repSystem = new ReputationSystemV3(address(registry));
        aggregator = new BLSAggregatorV3(address(registry), address(superPaymaster), address(0));
        dvt = new DVTValidatorV3(address(registry));
        blsValidator = new BLSValidator();
        xpntsFactory = new xPNTsFactory(address(superPaymaster), address(registry));
        pmFactory = new PaymasterFactory();
        pmV4Impl = new PaymasterV4_2(address(registry));
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
        apnts.setSuperPaymasterAddress(address(superPaymaster));
        mysbt.setSuperPaymaster(address(superPaymaster));
        pmFactory.addImplementation("v4.2", address(pmV4Impl));
        superPaymaster.updatePrice();
    }

    function _orchestrateRoles() internal {
        gtoken.mint(deployer, 1000 ether);
        gtoken.approve(address(staking), 1000 ether);
        
        bytes memory opData = abi.encode(
            Registry.CommunityRoleData("Genesis Operator", "genesis.eth", "http://aastar.io", "Genesis Hub", "", 30 ether)
        );
        registry.registerRole(registry.ROLE_COMMUNITY(), deployer, opData);
        registry.registerRole(registry.ROLE_PAYMASTER_SUPER(), deployer, "");
        IEntryPoint(entryPointAddr).depositTo{value: 0.5 ether}(address(superPaymaster));
        apnts.mint(deployer, 1000 ether);
        apnts.approve(address(superPaymaster), 1000 ether);
        superPaymaster.depositFor(deployer, 1000 ether);
    }

    function _getChainName(uint256 id) internal pure returns (string memory) {
        if (id == 31337) return "anvil";
        if (id == 11155111) return "sepolia";
        if (id == 1) return "mainnet";
        if (id == 10) return "optimism";
        if (id == 8453) return "base";
        return vm.toString(id);
    }

    function _generateConfig() internal {
        string memory chainName = _getChainName(block.chainid);
        string memory dirPath = string.concat(vm.projectRoot(), "/deployments/");
        string memory finalPath = string.concat(dirPath, chainName, ".json");

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
        vm.serializeAddress(jsonObj, "paymasterV4Impl", address(pmV4Impl));
        string memory finalJson = vm.serializeAddress(jsonObj, "entryPoint", entryPointAddr);

        vm.writeFile(finalPath, finalJson);
        
        console.log("--- Deployment Summary (%s) ---", chainName);
        console.log("REGISTRY_ADDR=%s", address(registry));
        console.log("SUPER_PAYMASTER_ADDR=%s", address(superPaymaster));
        console.log("APNTS_ADDR=%s", address(apnts));
        console.log("STAKING_ADDR=%s", address(staking));
        console.log("PAYMASTER_V4_IMPL=%s", address(pmV4Impl));
        console.log("Config saved to: %s", finalPath);
    }
}