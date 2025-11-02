// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "../src/paymasters/v4/PaymasterV4_1i.sol";

/**
 * @title DeployPaymasterV4_1i
 * @notice Deployment script for PaymasterV4_1i implementation (for factory pattern)
 * @dev Deploys only the implementation contract, NOT a proxy instance
 * @dev Factory will use this implementation to create EIP-1167 minimal proxies
 *
 * @dev Usage (Sepolia with verification):
 *   forge script script/DeployPaymasterV4_1i.s.sol:DeployPaymasterV4_1i \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     --etherscan-api-key $ETHERSCAN_API_KEY \
 *     -vvvv
 *
 * @dev After deployment:
 *   1. Call PaymasterFactory.addImplementation("v4.1i", <implementation_address>)
 *   2. Update registry frontend to use factory deployment
 *   3. Test end-to-end flow with factory.createPaymaster()
 */
contract DeployPaymasterV4_1i is Script {
    function run() external {
        console.log("\n=== PaymasterV4_1i Implementation Deployment ===");
        console.log("Deployer:", msg.sender);
        console.log("Chain ID:", block.chainid);

        vm.startBroadcast();

        // Deploy implementation contract
        // Constructor calls _disableInitializers() to prevent initialization
        PaymasterV4_1i implementation = new PaymasterV4_1i();

        vm.stopBroadcast();

        console.log("\n=== Deployment Successful ===");
        console.log("Implementation:", address(implementation));
        console.log("Version:", implementation.version());

        console.log("\n=== Next Steps ===");
        console.log("1. Register implementation in PaymasterFactory:");
        console.log("   factory.addImplementation(\"v4.1i\", ", address(implementation), ")");
        console.log("\n2. Update registry frontend to use factory deployment");
        console.log("\n3. Test proxy creation:");
        console.log("   factory.createPaymaster(\"v4.1i\", initializeData)");

        console.log("\nDeployment complete! Manual save required.");
    }
}
