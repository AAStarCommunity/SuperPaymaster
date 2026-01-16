// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "src/paymasters/v4/core/PaymasterFactory.sol";

/**
 * @title DeployPaymasterFactory
 * @notice Deploy PaymasterFactory for permissionless Paymaster deployment
 *
 * Usage:
 * forge script script/DeployPaymasterFactory.s.sol:DeployPaymasterFactory \
 *   --rpc-url $SEPOLIA_RPC_URL \
 *   --private-key $DEPLOYER_PRIVATE_KEY \
 *   --broadcast \
 *   --legacy
 */
contract DeployPaymasterFactory is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy PaymasterFactory
        PaymasterFactory factory = new PaymasterFactory();

        console.log("=== PaymasterFactory Deployed ===");
        console.log("Address:", address(factory));
        console.log("Owner:", factory.owner());
        console.log("Default Version:", factory.defaultVersion());

        vm.stopBroadcast();
    }
}
