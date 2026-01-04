// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/core/Registry.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/modules/monitoring/DVTValidator.sol";
import "src/modules/validators/BLSValidator.sol";

contract DeployV3ModulesSepolia is Script {
    function run() external {
        uint256 deployerPK = vm.envUint("ADMIN_KEY");
        address registryAddr = vm.envAddress("REGISTRY_ADDRESS");
        address paymasterAddr = vm.envAddress("SUPER_PAYMASTER");

        vm.startBroadcast(deployerPK);

        console.log("Deploying V3 Modules on Sepolia...");
        console.log("Registry:", registryAddr);

        // 1. Deploy BLSValidator
        BLSValidator blsValidator = new BLSValidator();
        console.log("BLSValidator deployed at:", address(blsValidator));

        // 2. Deploy BLSAggregator
        BLSAggregator aggregator = new BLSAggregator(registryAddr, paymasterAddr, address(0));
        console.log("BLSAggregator deployed at:", address(aggregator));

        // 3. Deploy DVTValidator
        DVTValidator dvt = new DVTValidator(registryAddr);
        console.log("DVTValidator deployed at:", address(dvt));

        // 4. Wiring
        Registry registry = Registry(registryAddr);
        registry.setBLSValidator(address(blsValidator));
        registry.setBLSAggregator(address(aggregator));
        
        // Update Aggregator with DVT Validator
        aggregator.setDVTValidator(address(dvt));
        
        // Optional: Set default threshold if needed
        aggregator.setThreshold(3);

        vm.stopBroadcast();
    }
}
