// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/MySBT.sol";
import "src/tokens/xPNTsToken.sol";
import "src/modules/reputation/ReputationSystemV3.sol";
import "src/modules/monitoring/BLSAggregatorV3.sol";
import "src/modules/monitoring/DVTValidatorV3.sol";
import "src/tokens/xPNTsFactory.sol";
import "src/paymasters/v4/PaymasterV4.sol";
import "src/paymasters/v4/PaymasterV4_1i.sol";
import "src/paymasters/v4/core/PaymasterFactory.sol";
import "src/modules/validators/BLSValidator.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";

/**
 * @title DeployV3Full
 * @notice Deploys the complete V3.1.1 System: Registry, SuperPaymaster, GToken, ReputationSystem, etc.
 */
contract DeployV3FullSepolia is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("--- SuperPaymaster V3.1.1 Full System Deployment ---");
        console.log("Deployer:", deployer);

        // Env Config
        address entryPointAddr = vm.envOr("ENTRY_POINT_V07", 0x0000000071727De22E5E9d8BAf0edAc6f37da032);
        address priceFeedAddr = vm.envOr("PRICE_FEED", 0x694AA1769357215DE4FAC081bf1f309aDC325306); 

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Foundation
        GToken gtoken = new GToken(21_000_000 * 1e18);
        console.log("GToken:", address(gtoken));

        GTokenStaking staking = new GTokenStaking(address(gtoken), deployer);
        console.log("Staking:", address(staking));

        // 2. Circular Dependency Management (Registry <-> MySBT)
        uint256 deployerNonce = vm.getNonce(deployer);
        // Registry is Nonce N, MySBT is Nonce N+1
        address precomputedSBT = vm.computeCreateAddress(deployer, deployerNonce + 1);

        Registry registry = new Registry(address(gtoken), address(staking), precomputedSBT);
        console.log("Registry (V3.1.1):", address(registry));
        
        MySBT mysbt = new MySBT(address(gtoken), address(staking), address(registry), deployer);
        console.log("MySBT (SBT):", address(mysbt));
        
        require(address(mysbt) == precomputedSBT, "SBT Address Mismatch!");

        // 3. Deploy Reputation System
        ReputationSystemV3 repSystem = new ReputationSystemV3(address(registry));
        console.log("ReputationSystem:", address(repSystem));

        // 4. Deploy Global Token (aPNTs)
        xPNTsToken apnts = new xPNTsToken("aPNTs", "aPNTs", deployer, "Global", "aastar.eth", 1e18);
        console.log("aPNTs:", address(apnts));

        // 5. Deploy SuperPaymaster
        SuperPaymasterV3 paymaster = new SuperPaymasterV3(
            IEntryPoint(entryPointAddr),
            deployer,
            registry,
            address(apnts),
            priceFeedAddr,
            deployer // Treasury
        );
        console.log("SuperPaymaster V3.1.1:", address(paymaster));

        // 6. Wiring
        staking.setRegistry(address(registry));
        mysbt.setRegistry(address(registry));
        registry.setReputationSource(address(repSystem), true);
        apnts.setSuperPaymasterAddress(address(paymaster));

        // 7. DVT & BLS Infrastructure
        // 7.1 BLS Aggregator (Threshold 3)
        BLSAggregatorV3 aggregator = new BLSAggregatorV3(address(registry), address(paymaster), address(0));
        aggregator.setThreshold(3);
        registry.setBLSAggregator(address(aggregator));
        console.log("BLSAggregator:", address(aggregator));

        // 7.2 DVT Validator
        DVTValidatorV3 dvt = new DVTValidatorV3(address(registry));
        dvt.setBLSAggregator(address(aggregator));
        console.log("DVTValidator:", address(dvt));

        // 7.3 BLS Validator Strategy
        BLSValidator blsValidator = new BLSValidator();
        registry.setBLSValidator(address(blsValidator));
        console.log("BLSValidator:", address(blsValidator));

        // 7.4 xPNTs Factory
        xPNTsFactory factory = new xPNTsFactory(address(paymaster), address(registry));
        console.log("xPNTsFactory:", address(factory));

        // 8. Paymaster V4 Ecosystem
        PaymasterV4 paymasterV4 = new PaymasterV4(
            entryPointAddr,
            deployer,
            deployer, // Treasury
            priceFeedAddr,
            1000, // 10% Service Fee
            1 ether, // Max Cost Cap
            address(factory)
        );
        console.log("PaymasterV4:", address(paymasterV4));

        PaymasterFactory pmFactory = new PaymasterFactory();
        PaymasterV4_1i v41i = new PaymasterV4_1i();
        pmFactory.addImplementation("v4.1i", address(v41i));
        console.log("PaymasterFactory:", address(pmFactory));

        // 9. Configuration & Wiring
        bytes32 ROLE_PAYMASTER_AOA = keccak256("PAYMASTER_AOA");
        bytes32 ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
        bytes32 ROLE_ANODE = keccak256("ANODE");
        bytes32 ROLE_KMS = keccak256("KMS");
        bytes32 ROLE_COMMUNITY = keccak256("COMMUNITY");
        bytes32 ROLE_ENDUSER = keccak256("ENDUSER");
        
        staking.setRoleExitFee(ROLE_PAYMASTER_AOA, 1000, 1 ether);
        staking.setRoleExitFee(ROLE_PAYMASTER_SUPER, 1000, 2 ether);
        staking.setRoleExitFee(ROLE_ANODE, 1000, 1 ether);
        staking.setRoleExitFee(ROLE_KMS, 1000, 5 ether);
        staking.setRoleExitFee(ROLE_COMMUNITY, 1000, 0.5 ether);
        staking.setRoleExitFee(ROLE_ENDUSER, 1000, 0.05 ether);

        // 10. Bootstrap Operator (Deployer)
        gtoken.mint(deployer, 5000 ether);
        gtoken.approve(address(staking), 5000 ether);

        bytes memory opData = abi.encode(
            Registry.CommunityRoleData("Sepolia Operator", "sepolia.eth", "https://sepolia.etherscan.io", "Sepolia Hub", "", 30 ether)
        );
        registry.registerRole(ROLE_COMMUNITY, deployer, opData);
        registry.registerRole(ROLE_PAYMASTER_SUPER, deployer, "");
        
        apnts.mint(address(paymaster), 1000 ether); // Initial credit

        vm.stopBroadcast();
        
        console.log("\n=== Deployment Complete ===");
        console.log("Export these addresses to your .env:");
        console.log("GTOKEN_ADDRESS=", address(gtoken));
        console.log("STAKING_ADDRESS=", address(staking));
        console.log("REGISTRY_ADDRESS=", address(registry));
        console.log("MYSBT_ADDRESS=", address(mysbt));
        console.log("REPUTATION_SYSTEM_ADDRESS=", address(repSystem));
        console.log("APNTS_ADDRESS=", address(apnts));
        console.log("SUPERPAYMASTER_ADDRESS=", address(paymaster));

        // Generate script/v3/config.json for automatic sync
        // Generate script/v3/config.json with extended data
        string memory jsonObj = "json";
        vm.serializeAddress(jsonObj, "registry", address(registry));
        vm.serializeAddress(jsonObj, "gToken", address(gtoken));
        vm.serializeAddress(jsonObj, "staking", address(staking));
        vm.serializeAddress(jsonObj, "superPaymaster", address(paymaster));
        vm.serializeAddress(jsonObj, "aPNTs", address(apnts));
        vm.serializeAddress(jsonObj, "sbt", address(mysbt));
        vm.serializeAddress(jsonObj, "reputationSystem", address(repSystem));
        
        // New Modules
        vm.serializeAddress(jsonObj, "dvtValidator", address(dvt));
        vm.serializeAddress(jsonObj, "blsAggregator", address(aggregator));
        vm.serializeAddress(jsonObj, "blsValidator", address(blsValidator));
        vm.serializeAddress(jsonObj, "xPNTsFactory", address(factory));
        vm.serializeAddress(jsonObj, "paymasterFactory", address(pmFactory));
        vm.serializeAddress(jsonObj, "entryPoint", entryPointAddr);
        
        string memory finalJson = vm.serializeAddress(jsonObj, "paymasterV4", address(paymasterV4));
        vm.writeFile("script/v3/config.json", finalJson);
        console.log("Generated script/v3/config.json");
    }
}
