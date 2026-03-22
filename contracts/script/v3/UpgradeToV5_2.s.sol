// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/core/Registry.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {UUPSUpgradeable} from "@openzeppelin-v5.0.2/contracts/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title UpgradeToV5_2
 * @notice UUPS upgrade: SuperPaymaster v4.1.0 → v5.2.0 on Sepolia
 *
 * What this does:
 *   1. Deploy new SuperPaymaster implementation (same immutables)
 *   2. Call upgradeToAndCall on existing proxy
 *   3. Verify version string changed
 *
 * No reinitializer needed:
 *   - New mappings default to empty
 *   - agentIdentityRegistry / agentReputationRegistry default to address(0)
 *   - facilitatorFeeBPS defaults to 0 (no fee — safe)
 *   - Constants (PERMIT2, WITNESS_TYPE_STRING, X402_SETTLEMENT_TYPEHASH) in bytecode
 *
 * Run:
 *   source .env.sepolia && forge script contracts/script/v3/UpgradeToV5_2.s.sol:UpgradeToV5_2 \
 *     --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast -vvvv
 */
contract UpgradeToV5_2 is Script {
    function run() external {
        // Load from config
        string memory configPath = string.concat(vm.projectRoot(), "/deployments/config.sepolia.json");
        string memory config = vm.readFile(configPath);

        address spProxy = vm.parseJsonAddress(config, ".superPaymaster");
        address registryProxy = vm.parseJsonAddress(config, ".registry");
        address entryPoint = vm.parseJsonAddress(config, ".entryPoint");
        address priceFeed = vm.parseJsonAddress(config, ".priceFeed");

        console.log("=== UUPS Upgrade: SuperPaymaster v4.1.0 -> v5.2.0 ===");
        console.log("  SP Proxy:", spProxy);
        console.log("  Registry:", registryProxy);
        console.log("  EntryPoint:", entryPoint);
        console.log("  PriceFeed:", priceFeed);

        // Pre-upgrade version check
        string memory oldVersion = SuperPaymaster(payable(spProxy)).version();
        console.log("  Current version:", oldVersion);

        vm.startBroadcast();

        // 1. Deploy new implementation
        SuperPaymaster newImpl = new SuperPaymaster(
            IEntryPoint(entryPoint),
            Registry(registryProxy),
            priceFeed
        );
        console.log("  New implementation:", address(newImpl));

        // 2. Upgrade proxy (no reinitializer call needed)
        UUPSUpgradeable(spProxy).upgradeToAndCall(address(newImpl), "");
        console.log("  upgradeToAndCall executed");

        vm.stopBroadcast();

        // 3. Verify
        string memory newVersion = SuperPaymaster(payable(spProxy)).version();
        console.log("  New version:", newVersion);

        require(
            keccak256(bytes(newVersion)) == keccak256(bytes("SuperPaymaster-5.2.0")),
            "Version mismatch after upgrade!"
        );

        console.log("=== Upgrade successful! ===");
    }
}
