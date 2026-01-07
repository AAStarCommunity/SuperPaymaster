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
        apnts = new xPNTsToken("AAStar PNTs", "aPNTs", deployer, "GlobalHub", "local.eth", 1e18);
        superPaymaster = new SuperPaymaster(IEntryPoint(entryPointAddr), deployer, registry, address(apnts), priceFeedAddr, deployer, 3600);

        console.log("=== Step 3: Deploy Modules ===");
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
        apnts.setSuperPaymasterAddress(address(superPaymaster));
        mysbt.setSuperPaymaster(address(superPaymaster));
        pmFactory.addImplementation("v4.2", address(pmV4Impl));
        superPaymaster.setXPNTsFactory(address(xpntsFactory));
        // try superPaymaster.updatePrice() {} catch {}
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
        
        IEntryPoint(entryPointAddr).depositTo{value: 0.05 ether}(address(superPaymaster));
        apnts.mint(deployer, 1000 ether);
        apnts.approve(address(superPaymaster), 1000 ether);
        superPaymaster.depositFor(deployer, 1000 ether);

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
            registry.safeMintForRole(registry.ROLE_COMMUNITY(), anni, abi.encode(demoData));
            
            gtoken.transfer(anni, 100 ether);
            
            vm.stopBroadcast();
            vm.startBroadcast(anniPK);
            gtoken.approve(address(staking), 100 ether);
            registry.registerRole(registry.ROLE_PAYMASTER_SUPER(), anni, "");
            
            address dPNTs = xpntsFactory.deployxPNTsToken("DemoPoints", "dPNTs", "DemoCommunity", "demo.eth", 1e18, address(0));
            superPaymaster.configureOperator(dPNTs, anni, 1e18);
            vm.stopBroadcast();
            vm.startBroadcast(deployerPK);
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
        vm.serializeAddress(jsonObj, "paymasterV4Impl", address(pmV4Impl));
        vm.serializeString(jsonObj, "srcHash", vm.envOr("SRC_HASH", string("")));
        string memory finalJson = vm.serializeAddress(jsonObj, "entryPoint", entryPointAddr);
        vm.writeFile(finalPath, finalJson);
        console.log("\n--- Live Deployment Complete ---");
        console.log("Config saved to: %s", finalPath);
    }
}