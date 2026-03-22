// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "src/paymasters/v4/Paymaster.sol";
import "src/paymasters/v4/core/PaymasterFactory.sol";

/**
 * @title DeployPaymasterV4_3_1
 * @notice Deploy new PaymasterV4 implementation v4.3.1 and register in factory
 *
 * Steps:
 *   1. Deploy new Paymaster implementation (constructor: registry address)
 *   2. Register "v4.3.1" in PaymasterFactory
 *   3. Verify version string
 *
 * Run:
 *   source .env.sepolia && forge script contracts/script/v3/DeployPaymasterV4_3_1.s.sol:DeployPaymasterV4_3_1 \
 *     --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast --slow -vvvv
 */
contract DeployPaymasterV4_3_1 is Script {
    function run() external {
        // Load config
        string memory configPath = "deployments/config.sepolia.json";
        string memory config = vm.readFile(configPath);

        address registry = vm.parseJsonAddress(config, ".registry");
        address factoryAddr = vm.parseJsonAddress(config, ".paymasterFactory");

        console.log("=== Deploy PaymasterV4 v4.3.1 ===");
        console.log("Registry:", registry);
        console.log("Factory:", factoryAddr);

        vm.startBroadcast();

        // 1. Deploy new implementation
        Paymaster newImpl = new Paymaster(registry);
        console.log("New PaymasterV4 impl:", address(newImpl));

        // 2. Verify version
        string memory ver = newImpl.version();
        console.log("Version:", ver);
        require(
            keccak256(bytes(ver)) == keccak256(bytes("PMV4-Deposit-4.3.1")),
            "Version mismatch!"
        );

        // 3. Register in factory
        PaymasterFactory factory = PaymasterFactory(factoryAddr);
        factory.addImplementation("v4.3.1", address(newImpl));
        console.log("Registered v4.3.1 in factory");

        vm.stopBroadcast();

        console.log("=== Done ===");
    }
}
