// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "src/paymasters/v4/Paymaster.sol";

interface IPaymasterFactory {
    function implementations(string memory) external view returns (address);
    function addImplementation(string memory version, address implementation) external;
    function upgradeImplementation(string memory version, address newImplementation) external;
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
    // The specific factory version key every deploy script passes to deployPaymaster(). Hardcoded
    // (not read from defaultVersion()) so a changed default can never repoint the WRONG key.
    string constant ACTIVE_VERSION = "v4.2";
    // The known pre-fix impl version this fix supersedes — we only repoint ACTIVE_VERSION when it
    // still points at this (or is unset), never clobbering a different/newer impl a maintainer set.
    string constant PREV_VERSION = "PMV4-Deposit-4.5.0";

    function run() external {
        string memory network = vm.envOr("ENV", string("sepolia"));
        string memory configPath = string.concat(vm.projectRoot(), "/deployments/config.", network, ".json");
        string memory config = vm.readFile(configPath);

        address registry = vm.parseJsonAddress(config, ".registry");
        address factoryAddr = vm.parseJsonAddress(config, ".paymasterFactory");
        IPaymasterFactory factory = IPaymasterFactory(factoryAddr);

        console.log("=== Deploy PaymasterV4 4.3.2 impl (#327) ===");
        console.log("  Factory:", factoryAddr);

        // ACTIVE_VERSION ("v4.2") is the key every deploy script passes to deployPaymaster(), so
        // that's what NEW community paymasters clone. Registering the fixed impl under VERSION alone
        // would be orphaned; we also repoint ACTIVE_VERSION at the fixed impl — but ONLY when it
        // still points at the known pre-fix impl, never clobbering a different/newer one.
        vm.startBroadcast();
        // 1. Deploy + register the fixed impl under its own version key (idempotent).
        address impl = factory.implementations(VERSION);
        if (impl == address(0)) {
            Paymaster newImpl = new Paymaster(registry);
            require(keccak256(bytes(newImpl.version())) == keccak256(bytes(VERSION)), "V: impl version mismatch");
            factory.addImplementation(VERSION, address(newImpl));
            impl = address(newImpl);
        }
        // 2. Repoint ACTIVE_VERSION at the fixed impl. Guard: only when it currently points at the
        //    known pre-fix impl (or is unset). Refuse to clobber an unexpected impl — a maintainer
        //    may have deliberately set a newer one under this key.
        address activeImpl = factory.implementations(ACTIVE_VERSION);
        if (activeImpl != impl) {
            require(
                activeImpl == address(0) ||
                keccak256(bytes(Paymaster(payable(activeImpl)).version())) == keccak256(bytes(PREV_VERSION)),
                "V: v4.2 points at an unexpected impl - refusing to clobber"
            );
            factory.upgradeImplementation(ACTIVE_VERSION, impl);
        }
        vm.stopBroadcast();

        require(factory.implementations(VERSION) == impl, "V: registration failed");
        require(factory.implementations(ACTIVE_VERSION) == impl, "V: active version not repointed");
        console.log("  New impl:", impl);
        console.log("  Registered as:", VERSION);
        console.log("  Active version repointed:", ACTIVE_VERSION);

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
