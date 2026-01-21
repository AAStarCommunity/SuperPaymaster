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
import "src/mocks/MockBLSValidator.sol";

// External Interfaces
import {EntryPoint} from "@account-abstraction-v7/core/EntryPoint.sol";
import {SimpleAccountFactory} from "@account-abstraction-v7/samples/SimpleAccountFactory.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";

contract MockPriceFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000 * 1e8, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

/**
 * @title DeployAnvil
 * @notice Standardized Local Deployment Script with Atomic Initialization
 */
contract DeployAnvil is Script {
    using Clones for address;
    uint256 deployerPK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; 
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
    MockBLSValidator blsValidator;
    xPNTsFactory xpntsFactory;
    PaymasterFactory pmFactory;
    Paymaster pmV4Impl;
    SimpleAccountFactory accountFactory;

    function setUp() public {
        deployer = vm.addr(deployerPK); 
    }

    function run() external {
        vm.warp(86400); 
        vm.startBroadcast(deployerPK);
        
        priceFeedAddr = address(new MockPriceFeed());
        entryPointAddr = address(new EntryPoint());

        console.log("=== Step 1: Deploy Foundation ===");
        gtoken = new GToken(21_000_000 * 1e18);
        staking = new GTokenStaking(address(gtoken), deployer);
        uint256 nonce = vm.getNonce(deployer);
        address precomputedRegistry = vm.computeCreateAddress(deployer, nonce + 1);
        mysbt = new MySBT(address(gtoken), address(staking), precomputedRegistry, deployer);
        registry = new Registry(address(gtoken), address(staking), address(mysbt));

        console.log("=== Step 2: Deploy Core ===");
        address xPNTsImpl = address(new xPNTsToken());
        apnts = xPNTsToken(xPNTsImpl.clone());
        apnts.initialize("AAStar PNTs", "aPNTs", deployer, "GlobalHub", "local.eth", 1e18);
        superPaymaster = new SuperPaymaster(IEntryPoint(entryPointAddr), deployer, registry, address(apnts), priceFeedAddr, deployer, 3600);

        console.log("=== Step 3: Deploy Modules ===");
        repSystem = new ReputationSystem(address(registry));
        aggregator = new BLSAggregator(address(registry), address(superPaymaster), address(0));
        dvt = new DVTValidator(address(registry));
        blsValidator = new MockBLSValidator();
        xpntsFactory = new xPNTsFactory(address(superPaymaster), address(registry));
        pmFactory = new PaymasterFactory();
        pmV4Impl = new Paymaster(address(registry));
        accountFactory = new SimpleAccountFactory(IEntryPoint(entryPointAddr));

        console.log("=== Step 4: The Grand Wiring ===");
        _executeWiring();

        console.log("=== Step 5: Atomic Role & Community Orchestration ===");
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
        apnts.setSuperPaymasterAddress(address(superPaymaster));
        pmFactory.addImplementation("v4.2", address(pmV4Impl));
        superPaymaster.setXPNTsFactory(address(xpntsFactory));
        superPaymaster.updatePrice();
    }

    function _orchestrateRoles() internal {
        gtoken.mint(deployer, 2000 ether);
        gtoken.approve(address(staking), 2000 ether);
        
        // 1. 初始化 AAStar 社区 (Jason)
        Registry.CommunityRoleData memory aaStarData = Registry.CommunityRoleData({
            name: "AAStar",
            ensName: "aastar.eth",
            website: "aastar.io",
            description: "AAStar Community - Empower Community! Twitter: https://X.com/AAStarCommunity",
            logoURI: "ipfs://aastar-logo",
            stakeAmount: 30 ether
        });
        registry.registerRole(registry.ROLE_COMMUNITY(), deployer, abi.encode(aaStarData));
        registry.registerRole(registry.ROLE_PAYMASTER_SUPER(), deployer, "");
        superPaymaster.configureOperator(address(apnts), deployer, 1e18);
        
        apnts.mint(deployer, 1000 ether);        // Initial Refill (SuperPaymaster is already auto-approved in xPNTsToken via setSuperPaymasterAddress)
        superPaymaster.depositFor(deployer, 1000 ether);

        // 2. 初始化 DemoCommunity (Anni)
        uint256 anniPK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
        address anni = vm.addr(anniPK);
        Registry.CommunityRoleData memory demoData = Registry.CommunityRoleData({
            name: "DemoCommunity",
            ensName: "demo.eth",
            website: "demo.com",
            description: "Demo Community for testing purposes.",
            logoURI: "ipfs://demo-logo",
            stakeAmount: 30 ether
        });

        // Jason 代付 Anni 的质押并注册社区
        registry.safeMintForRole(registry.ROLE_COMMUNITY(), anni, abi.encode(demoData));
        
        // 关键：Anni 在 Anvil 下也需要点钱进行 Paymaster 注册
        gtoken.mint(anni, 100 ether);
        registry.safeMintForRole(registry.ROLE_PAYMASTER_SUPER(), anni, "");
        
        // 补全 DemoCommunity 的 Operator 配置
        vm.stopBroadcast();
        vm.startBroadcast(anniPK);
        address dPNTs = xpntsFactory.deployxPNTsToken("DemoPoints", "dPNTs", "DemoCommunity", "demo.eth", 1e18, address(0));
        superPaymaster.configureOperator(dPNTs, anni, 1e18);
        
        // 为 DemoCommunity 注入 500 ether 资金
        xPNTsToken(dPNTs).mint(anni, 500 ether);        // Initial Refill for dPNTs
        // superPaymaster.deposit(500 ether); // This line was commented out in the original, and the instruction implies removing an approve call, not adding a deposit call.
        vm.stopBroadcast();

        // 切换回 Deployer 继续后续操作
        vm.startBroadcast(deployerPK);
    }

    function _verifyWiring() internal view {
        require(address(staking.GTOKEN()) == address(gtoken), "Staking GTOKEN Wiring Failed");
        require(registry.SUPER_PAYMASTER() == address(superPaymaster), "Registry SP Wiring Failed");
        require(apnts.SUPERPAYMASTER_ADDRESS() == address(superPaymaster), "aPNTs Firewall Failed");
        require(address(superPaymaster.REGISTRY()) == address(registry), "Paymaster Registry Immutable Failed");
        console.log("All Wiring Assertions Passed!");
    }

    function _generateConfig() internal {
        string memory finalPath = string.concat(vm.projectRoot(), "/deployments/config.anvil.json");
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
        vm.serializeAddress(jsonObj, "simpleAccountFactory", address(accountFactory));
        vm.serializeString(jsonObj, "srcHash", vm.envOr("SRC_HASH", string("")));
        vm.serializeAddress(jsonObj, "priceFeed", priceFeedAddr);
        string memory finalJson = vm.serializeAddress(jsonObj, "entryPoint", entryPointAddr);
        vm.writeFile(finalPath, finalJson);
        console.log("\n--- Anvil Deployment Complete ---");
        console.log("Config saved to: %s", finalPath);
    }
}