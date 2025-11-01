// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/paymasters/v2/monitoring/BLSAggregator.sol";

/**
 * @title DeployBLSAggregator
 * @notice Deploy BLSAggregator v2.0.0 with VERSION interface
 */
contract DeployBLSAggregator is Script {
    function run() external {
        address superPaymaster = vm.envAddress("SUPER_PAYMASTER_V2");
        address dvtValidator = vm.envAddress("DVT_VALIDATOR");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log("=== Deploying BLSAggregator v2.0.0 ===");
        console.log("SuperPaymasterV2:", superPaymaster);
        console.log("DVTValidator:", dvtValidator);
        console.log();

        vm.startBroadcast(deployerPrivateKey);

        BLSAggregator bls = new BLSAggregator(superPaymaster, dvtValidator);

        console.log("BLSAggregator deployed:", address(bls));
        console.log("VERSION:", bls.VERSION());
        console.log("VERSION_CODE:", bls.VERSION_CODE());

        vm.stopBroadcast();

        console.log();
        console.log("=== Deployment Complete ===");
        console.log("Address:", address(bls));
        console.log("Owner:", bls.owner());
    }
}
