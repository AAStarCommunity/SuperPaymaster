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
import "src/paymasters/v4/PaymasterV4.sol";
import "src/paymasters/v4/Paymaster.sol";
import "src/paymasters/v4/core/PaymasterFactory.sol";

// Module Imports
import "src/modules/reputation/ReputationSystem.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/modules/monitoring/DVTValidator.sol";
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
 * @notice Standardized V3/V4 Deployment Script (Environment Strict)
 */
contract DeployStandardV3 is Script {
    uint256 deployerPK;
    address deployer;
    address entryPointAddr;
    address priceFeedAddr;
    string configPath;

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
        deployerPK = vm.envOr("PRIVATE_KEY", uint256(0));
        priceFeedAddr = vm.envOr("ETH_USD_FEED", address(0));
        entryPointAddr = vm.envOr("ENTRY_POINT", address(0));

        // 严格根据 ChainID 设置默认值
        if (block.chainid == 31337) { // Anvil
            if (deployerPK == 0) deployerPK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
            // Anvil 下这些地址通常没用，会被 run() 里的 Mock 覆盖
        } else if (block.chainid == 11155111) { // Sepolia
            if (priceFeedAddr == address(0)) priceFeedAddr = 0x694AA1769357215DE4FAC081bf1f309aDC325306;
            if (entryPointAddr == address(0)) entryPointAddr = 0x0000000071727De13552189EF0715af1D2095830; // v0.7
        }
        
        require(deployerPK != 0, "Deployer Private Key not set");
        deployer = vm.addr(deployerPK);
        
        string memory root = vm.projectRoot();
        string memory configFileName = vm.envOr("CONFIG_FILE", string("config.json"));
        configPath = string.concat(root, "/", configFileName);
    }

    function run() external {
        // 1. 只有在 Anvil 下才执行 Warp 和 Mock 部署
        if (block.chainid == 31337) {
            vm.warp(1 days); 
            vm.startBroadcast(deployerPK);
            priceFeedAddr = address(new MockPriceFeed());
            entryPointAddr = address(new MockEntryPoint());
            vm.stopBroadcast();
            console.log("Anvil: Deployed Mocks and Warped Time");
        } else {
            // 在正式网，确保地址有效
            require(priceFeedAddr.code.length > 0, "PriceFeed not found on this chain");
            require(entryPointAddr.code.length > 0, "EntryPoint not found on this chain");
            console.log("Live Network: Using existing infrastructure");
        }

        vm.startBroadcast(deployerPK);

        console.log("=== Step 1: Deploy Foundation ===");
        _deployFoundation();

        console.log("=== Step 2: Deploy Core ===");
        _deployCore();

        console.log("=== Step 3: Deploy Modules ===");
        _deployModules();

        console.log("=== Step 4: The Grand Wiring ===");
        _executeWiring();

        console.log("=== Step 5: Role Orchestration ===");
        _orchestrateRoles();

        console.log("=== Step 6: Final Verification ===");
        _verifyWiring();

        vm.stopBroadcast();

        _generateConfig();
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
        superPaymaster = new SuperPaymaster(IEntryPoint(entryPointAddr), deployer, registry, address(apnts), priceFeedAddr, deployer, 3600);
    }

    function _deployModules() internal {
        repSystem = new ReputationSystem(address(registry));
        aggregator = new BLSAggregator(address(registry), address(superPaymaster), address(0));
        dvt = new DVTValidator(address(registry));
        blsValidator = new BLSValidator();
        xpntsFactory = new xPNTsFactory(address(superPaymaster), address(registry));
        pmFactory = new PaymasterFactory();
        pmV4Impl = new Paymaster(
            IEntryPoint(entryPointAddr),
            deployer,
            deployer, // treasury
            priceFeedAddr,
            1000, // serviceFeeRate
            5000000, // maxGasCostCap
            address(xpntsFactory),
            address(registry),
            3600 // priceStalenessThreshold
        );
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
        bytes memory opData = abi.encode(Registry.CommunityRoleData("Genesis Operator", "genesis.eth", "http://aastar.io", "Genesis Hub", "", 30 ether));
        registry.registerRole(registry.ROLE_COMMUNITY(), deployer, opData);
        registry.registerRole(registry.ROLE_PAYMASTER_SUPER(), deployer, "");
        IEntryPoint(entryPointAddr).depositTo{value: 0.1 ether}(address(superPaymaster));
        apnts.mint(deployer, 1000 ether);
        apnts.approve(address(superPaymaster), 1000 ether);
        superPaymaster.depositFor(deployer, 1000 ether);
    }

    function _getChainName(uint256 id) internal pure returns (string memory) {
        if (id == 31337) return "anvil";
        if (id == 11155111) return "sepolia";
        return vm.toString(id);
    }

    function _generateConfig() internal {
        string memory chainName = _getChainName(block.chainid);
        string memory finalPath = string.concat(vm.projectRoot(), "/deployments/", chainName, ".json");
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
        console.log("\n--- Deployment Summary ---");
        console.log("REGISTRY_ADDR=%s", address(registry));
        console.log("SUPER_PAYMASTER_ADDR=%s", address(superPaymaster));
        console.log("Config saved to: %s", finalPath);
    }
}
