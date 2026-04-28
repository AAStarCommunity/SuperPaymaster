// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/core/Registry.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {UUPSUpgradeable} from "@openzeppelin-v5.0.2/contracts/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title UpgradeToV5_3
 * @notice UUPS upgrade: SuperPaymaster v5.2.0 → v5.3.0 on Sepolia
 *
 * Changes in V5.3:
 *   - isEligibleForSponsorship() dual-channel (SBT OR Agent NFT)
 *   - settleX402Payment() via EIP-3009 (USDC native)
 *   - settleX402PaymentDirect() for xPNTs (auto-approved)
 *   - Removed Permit2 path (settleX402PaymentPermit2)
 *
 * No reinitializer needed: new functions only, no new storage.
 *
 * Run:
 *   source .env.sepolia && forge script contracts/script/v3/UpgradeToV5_3.s.sol:UpgradeToV5_3 \
 *     --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast -vvvv
 */
contract UpgradeToV5_3 is Script {
    function run() external {
        string memory configPath = string.concat(vm.projectRoot(), "/deployments/config.sepolia.json");
        string memory config = vm.readFile(configPath);

        address spProxy = vm.parseJsonAddress(config, ".superPaymaster");
        address registryProxy = vm.parseJsonAddress(config, ".registry");
        address entryPoint = vm.parseJsonAddress(config, ".entryPoint");
        address priceFeed = vm.parseJsonAddress(config, ".priceFeed");

        console.log("=== UUPS Upgrade: SuperPaymaster v5.2.0 -> v5.3.0 ===");
        console.log("  SP Proxy:", spProxy);

        string memory oldVersion = SuperPaymaster(payable(spProxy)).version();
        console.log("  Current version:", oldVersion);

        vm.startBroadcast();

        SuperPaymaster newImpl = new SuperPaymaster(
            IEntryPoint(entryPoint),
            Registry(registryProxy),
            priceFeed
        );
        console.log("  New implementation:", address(newImpl));

        UUPSUpgradeable(spProxy).upgradeToAndCall(address(newImpl), "");
        console.log("  upgradeToAndCall executed");

        vm.stopBroadcast();

        string memory newVersion = SuperPaymaster(payable(spProxy)).version();
        console.log("  New version:", newVersion);

        require(
            keccak256(bytes(newVersion)) == keccak256(bytes("SuperPaymaster-5.3.0")),
            "Version mismatch after upgrade!"
        );

        console.log("=== Upgrade successful! ===");
    }
}
