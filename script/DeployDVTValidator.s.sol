// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/paymasters/v2/monitoring/DVTValidator.sol";

/**
 * @title DeployDVTValidator
 * @notice Deploy DVTValidator v2.0.0 with VERSION interface
 */
contract DeployDVTValidator is Script {
    function run() external {
        address superPaymaster = vm.envAddress("SUPER_PAYMASTER_V2");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log("=== Deploying DVTValidator v2.0.0 ===");
        console.log("SuperPaymasterV2:", superPaymaster);
        console.log();

        vm.startBroadcast(deployerPrivateKey);

        DVTValidator dvt = new DVTValidator(superPaymaster);

        console.log("DVTValidator deployed:", address(dvt));
        console.log("VERSION:", dvt.VERSION());
        console.log("VERSION_CODE:", dvt.VERSION_CODE());

        vm.stopBroadcast();

        console.log();
        console.log("=== Deployment Complete ===");
        console.log("Address:", address(dvt));
        console.log("Owner:", dvt.owner());
    }
}
