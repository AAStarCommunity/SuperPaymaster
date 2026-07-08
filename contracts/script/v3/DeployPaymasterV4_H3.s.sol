// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "src/paymasters/v4/Paymaster.sol";

interface IPaymasterFactory {
    function implementations(string memory) external view returns (address);
    function addImplementation(string memory version, address implementation) external;
    function upgradeImplementation(string memory version, address newImplementation) external;
    function defaultVersion() external view returns (string memory);
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

        // The factory's defaultVersion (the key every deploy script passes to deployPaymaster —
        // "v4.2") is what NEW community paymasters actually clone. Registering the fixed impl under a
        // fresh key alone would be orphaned, so we ALSO repoint that active version at the fixed impl.
        string memory activeVersion = factory.defaultVersion();

        vm.startBroadcast();
        // 1. Deploy + register the fixed impl under its own version key (idempotent).
        address impl = factory.implementations(VERSION);
        if (impl == address(0)) {
            Paymaster newImpl = new Paymaster(registry);
            require(keccak256(bytes(newImpl.version())) == keccak256(bytes(VERSION)), "V: impl version mismatch");
            factory.addImplementation(VERSION, address(newImpl));
            impl = address(newImpl);
        }
        // 2. Repoint the ACTIVE deploy version at the fixed impl so deployPaymaster(defaultVersion)
        //    actually yields the H-3 fix. Existing EIP-1167 clones are immutable and keep the old impl.
        if (factory.implementations(activeVersion) != impl) {
            factory.upgradeImplementation(activeVersion, impl);
        }
        vm.stopBroadcast();

        require(factory.implementations(VERSION) == impl, "V: registration failed");
        require(factory.implementations(activeVersion) == impl, "V: active version not repointed");
        console.log("  New impl:", impl);
        console.log("  Registered as:", VERSION);
        console.log("  Active version repointed:", activeVersion);

        vm.writeJson(vm.toString(impl), configPath, ".paymasterV4Impl");
        _ensureTrailingNewline(configPath);
        console.log("=== Done. deployPaymaster(defaultVersion) now yields the H-3-fixed impl ===");
    }

    function _ensureTrailingNewline(string memory path) internal {
        bytes memory content = bytes(vm.readFile(path));
        if (content.length == 0) return;
        if (content[content.length - 1] == 0x0a) return;
        vm.writeFile(path, string.concat(string(content), "\n"));
    }
}
