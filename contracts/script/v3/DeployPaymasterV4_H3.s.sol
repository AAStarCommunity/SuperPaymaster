// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "src/paymasters/v4/Paymaster.sol";

interface IPaymasterFactory {
    function implementations(string memory) external view returns (address);
    function addImplementation(string memory version, address implementation) external;
    function owner() external view returns (address);
}

/**
 * @title DeployPaymasterV4_H3
 * @notice Deploy the PaymasterV4 4.3.2 impl (H-3 / #327: reject ops over maxGasCostCap — no ETH
 *         subsidy leak) and register it in the versioned PaymasterFactory. Existing EIP-1167
 *         instances are immutable and keep the old impl; NEW community paymasters deployed via
 *         `deployPaymaster("PMV4-Deposit-4.5.1", ...)` get the fix. Idempotent: skips if the version
 *         is already registered.
 *
 * Run:
 *   source .env.sepolia && forge script contracts/script/v3/DeployPaymasterV4_H3.s.sol:DeployPaymasterV4_H3 \
 *     --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast -vvvv
 */
contract DeployPaymasterV4_H3 is Script {
    string constant VERSION = "PMV4-Deposit-4.5.1";

    function run() external {
        string memory network = vm.envOr("ENV", string("sepolia"));
        string memory configPath = string.concat(vm.projectRoot(), "/deployments/config.", network, ".json");
        string memory config = vm.readFile(configPath);

        address registry = vm.parseJsonAddress(config, ".registry");
        address factoryAddr = vm.parseJsonAddress(config, ".paymasterFactory");
        IPaymasterFactory factory = IPaymasterFactory(factoryAddr);

        console.log("=== Deploy PaymasterV4 4.3.2 impl (#327) ===");
        console.log("  Factory:", factoryAddr);

        address existing = factory.implementations(VERSION);
        if (existing != address(0)) {
            console.log("  Version already registered at", existing, "- skipping");
            return;
        }

        vm.startBroadcast();
        Paymaster impl = new Paymaster(registry);
        require(keccak256(bytes(impl.version())) == keccak256(bytes(VERSION)), "V: impl version mismatch");
        factory.addImplementation(VERSION, address(impl));
        vm.stopBroadcast();

        require(factory.implementations(VERSION) == address(impl), "V: registration failed");
        console.log("  New impl:", address(impl));
        console.log("  Registered as", VERSION);

        vm.writeJson(vm.toString(address(impl)), configPath, ".paymasterV4Impl");
        _ensureTrailingNewline(configPath);
        console.log("=== Done. New community paymasters use", VERSION, "===");
    }

    function _ensureTrailingNewline(string memory path) internal {
        bytes memory content = bytes(vm.readFile(path));
        if (content.length == 0) return;
        if (content[content.length - 1] == 0x0a) return;
        vm.writeFile(path, string.concat(string(content), "\n"));
    }
}
