// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/MySBT.sol";
import "src/tokens/xPNTsToken.sol";
import "src/modules/reputation/ReputationSystem.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/modules/monitoring/DVTValidator.sol";
import "src/tokens/xPNTsFactory.sol";
import "src/paymasters/v4/PaymasterV4.sol";
import "src/paymasters/v4/PaymasterV4_1i.sol";
import "src/paymasters/v4/core/PaymasterFactory.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import { SimpleAccountFactory } from "@account-abstraction-v7/samples/SimpleAccountFactory.sol";
import "src/modules/validators/BLSValidator.sol";

/**
 * @title DeployStage3Sepolia
 * @notice Complete System Deployment for Sepolia Stage 3 Experiment.
 */
contract DeployStage3Sepolia is Script {
    function run() external {
        uint256 deployerPK = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPK);

        console.log("--- AAStar Stage 3 Sepolia Deployment ---");
        console.log("Deployer:", deployer);

        // Env Config (Sepolia Defaults)
        address entryPointAddr = vm.envOr("ENTRY_POINT_V07", 0x0000000071727De22E5E9d8BAf0edAc6f37da032);
        address priceFeedAddr = vm.envOr("PRICE_FEED", 0x694AA1769357215DE4FAC081bf1f309aDC325306); 

        vm.startBroadcast(deployerPK);

        // 1. Deploy Foundation
        GToken gtoken = new GToken(21_000_000 * 1e18);
        GTokenStaking staking = new GTokenStaking(address(gtoken), deployer);

        uint256 deployerNonce = vm.getNonce(deployer);
        address precomputedSBT = vm.computeCreateAddress(deployer, deployerNonce + 1);

        Registry registry = new Registry(address(gtoken), address(staking), precomputedSBT);
        MySBT mysbt = new MySBT(address(gtoken), address(staking), address(registry), deployer);
        
        // 2. Reputation & Token
        ReputationSystem repSystem = new ReputationSystem(address(registry));
                xPNTsToken apnts = new xPNTsToken();
        apnts.initialize("aPNTs", "aPNTs", deployer, "SepoliaHub", "sepolia.eth", 1e18);

        // 3. SuperPaymaster
        SuperPaymaster paymaster = new SuperPaymaster(
            IEntryPoint(entryPointAddr),
            deployer,
            registry,
            address(apnts),
            priceFeedAddr,
            deployer
        );

        // 3.1 BLS & DVT Modules
        BLSAggregator aggregator = new BLSAggregator(address(registry), address(paymaster), address(0));
        aggregator.setThreshold(3);
        registry.setBLSAggregator(address(aggregator));

        DVTValidator dvt = new DVTValidator(address(registry));
        dvt.setBLSAggregator(address(aggregator));

        BLSValidator blsValidator = new BLSValidator();
        registry.setBLSValidator(address(blsValidator));

        // 3.3 factories
        xPNTsFactory factory = new xPNTsFactory(address(paymaster), address(registry));
        SimpleAccountFactory accountFactory = new SimpleAccountFactory(IEntryPoint(entryPointAddr));

        // 4. Paymaster V4 Suite
        PaymasterV4 paymasterV4 = new PaymasterV4(
            entryPointAddr,
            deployer,
            deployer, // treasury
            priceFeedAddr,
            1000,     // 10% fee
            1 ether,  // max gas cost
            address(factory)
        );

        PaymasterFactory pmFactory = new PaymasterFactory();
        PaymasterV4_1i v41i = new PaymasterV4_1i();
        pmFactory.addImplementation("v4.1i", address(v41i));

        // 5. Wiring
        staking.setRegistry(address(registry));
        mysbt.setRegistry(address(registry));
        registry.setReputationSource(address(repSystem), true);
        apnts.setSuperPaymasterAddress(address(paymaster));
        
        // Initial Deposit for SuperPaymaster (Set to 0 or very small for testing)
        // IEntryPoint(entryPointAddr).depositTo{value: 0.01 ether}(address(paymaster));

        vm.stopBroadcast();
        
        // 6. Config Export
        string memory jsonObj = "json";
        vm.serializeAddress(jsonObj, "registry", address(registry));
        vm.serializeAddress(jsonObj, "gToken", address(gtoken));
        vm.serializeAddress(jsonObj, "staking", address(staking));
        vm.serializeAddress(jsonObj, "superPaymaster", address(paymaster));
        vm.serializeAddress(jsonObj, "paymasterFactory", address(pmFactory)); 
        vm.serializeAddress(jsonObj, "aPNTs", address(apnts));
        vm.serializeAddress(jsonObj, "sbt", address(mysbt));
        vm.serializeAddress(jsonObj, "reputationSystem", address(repSystem));
        vm.serializeAddress(jsonObj, "dvtValidator", address(dvt));
        vm.serializeAddress(jsonObj, "blsAggregator", address(aggregator));
        vm.serializeAddress(jsonObj, "blsValidator", address(blsValidator));
        vm.serializeAddress(jsonObj, "xPNTsFactory", address(factory));
        vm.serializeAddress(jsonObj, "paymasterV4", address(paymasterV4));
        vm.serializeAddress(jsonObj, "accountFactory", address(accountFactory));
        string memory finalJson = vm.serializeAddress(jsonObj, "entryPoint", entryPointAddr);

        vm.writeFile("script/v3/config.json", finalJson);
        console.log("Generated script/v3/config.json for Stage 3");

        console.log("\n=== Sepolia Stage 3 Deployment Complete ===");
    }
}
