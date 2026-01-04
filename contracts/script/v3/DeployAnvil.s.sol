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
 * @title DeployAnvil
 * @notice Dedicated Local Deployment Script for Anvil Regression
 */
contract DeployAnvil is Script {
    uint256 deployerPK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; 
    address deployer;
    address entryPointAddr;
    address priceFeedAddr;

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
        deployer = vm.addr(deployerPK); 
    }

    function run() external {
        // Local setup
        vm.warp(1 days); 
        vm.startBroadcast(deployerPK);
        
        priceFeedAddr = address(new MockPriceFeed());
        entryPointAddr = address(new MockEntryPoint());

        console.log("=== Step 1: Deploy Foundation ===");
        gtoken = new GToken(21_000_000 * 1e18);
        staking = new GTokenStaking(address(gtoken), deployer);
        uint256 nonce = vm.getNonce(deployer);
        address precomputedRegistry = vm.computeCreateAddress(deployer, nonce + 1);
        mysbt = new MySBT(address(gtoken), address(staking), precomputedRegistry, deployer);
        registry = new Registry(address(gtoken), address(staking), address(mysbt));

        console.log("=== Step 2: Deploy Core ===");
        apnts = new xPNTsToken("AAStar PNTs", "aPNTs", deployer, "GlobalHub", "local.eth", 1e18);
        superPaymaster = new SuperPaymasterV3(IEntryPoint(entryPointAddr), deployer, registry, address(apnts), priceFeedAddr, deployer);

        console.log("=== Step 3: Deploy Modules ===");
        repSystem = new ReputationSystemV3(address(registry));
        aggregator = new BLSAggregatorV3(address(registry), address(superPaymaster), address(0));
        dvt = new DVTValidatorV3(address(registry));
        blsValidator = new BLSValidator();
        xpntsFactory = new xPNTsFactory(address(superPaymaster), address(registry));
        pmFactory = new PaymasterFactory();
        pmV4Impl = new PaymasterV4_2(address(registry));

        console.log("=== Step 4: The Grand Wiring ===");
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

        console.log("=== Step 5: Role Orchestration ===");
        gtoken.mint(deployer, 1000 ether);
        gtoken.approve(address(staking), 1000 ether);
        bytes memory opData = abi.encode(Registry.CommunityRoleData("Genesis Operator", "genesis.eth", "http://aastar.io", "Genesis Hub", "", 30 ether));
        registry.registerRole(registry.ROLE_COMMUNITY(), deployer, opData);
        registry.registerRole(registry.ROLE_PAYMASTER_SUPER(), deployer, "");
        IEntryPoint(entryPointAddr).depositTo{value: 0.1 ether}(address(superPaymaster));
        apnts.mint(deployer, 1000 ether);
        apnts.approve(address(superPaymaster), 1000 ether);
        superPaymaster.depositFor(deployer, 1000 ether);

        console.log("=== Step 6: Verification ===");
        _verifyWiring();

        vm.stopBroadcast();
        _generateConfig();
    }

    function _verifyWiring() internal view {
        require(address(staking.GTOKEN()) == address(gtoken), "Staking GTOKEN Wiring Failed");
        require(registry.SUPER_PAYMASTER() == address(superPaymaster), "Registry SP Wiring Failed");
        require(apnts.SUPERPAYMASTER_ADDRESS() == address(superPaymaster), "aPNTs Firewall Failed");
        require(address(superPaymaster.REGISTRY()) == address(registry), "Paymaster Registry Immutable Failed");
        console.log("All Wiring Assertions Passed!");
    }

    function _generateConfig() internal {
        string memory finalPath = string.concat(vm.projectRoot(), "/deployments/anvil.json");
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
        console.log("\n--- Anvil Deployment Complete ---");
        console.log("Config saved to: %s", finalPath);
    }
}
