// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {LivenessRegistry} from "src/core/LivenessRegistry.sol";

/**
 * @title DeployLivenessRegistry
 * @notice CC-29 — deploy the standalone LivenessRegistry (objective on-chain operator liveness).
 *
 * Ownership model (jason's call): deploy with the deployer EOA as owner so the window can be tuned
 * freely during bring-up / debugging WITHOUT a multisig round-trip. Once stable, hand ownership to
 * the Mycelium community Safe via `transferOwnership(<Safe>)` — an ops action, not part of this
 * script. `renounceOwnership()` is disabled in the contract, so ownership can only ever be
 * transferred, never dropped.
 *
 *   Mycelium community Safe (three-chain same address): 0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114
 *     Sepolia sep: | Ethereum eth: | OP mainnet oeth:
 *
 * Params (env overrides, sane defaults):
 *   PRIVATE_KEY       — deployer/broadcaster key; its address becomes the initial owner unless
 *                       LIVENESS_OWNER is set.
 *   LIVENESS_WINDOW   — fleet-wide liveness window in blocks (default 300 ≈ 1h on ~12s Sepolia).
 *   LIVENESS_OWNER    — optional explicit initial owner (e.g. the Safe) to skip the later transfer.
 *
 * Run (Sepolia dry-run — no --broadcast):
 *   source .env.sepolia && forge script contracts/script/v3/DeployLivenessRegistry.s.sol:DeployLivenessRegistry \
 *     --rpc-url https://ethereum-sepolia-rpc.publicnode.com -vvvv
 * Add --broadcast to actually deploy.
 */
contract DeployLivenessRegistry is Script {
    // Canonical Mycelium community Safe (documented for the post-deploy transferOwnership step).
    address internal constant MYCELIUM_SAFE = 0x51eDf11fDb0A4F66220eFb8efA54Eca77232E114;

    function run() external {
        string memory configPath = string.concat(vm.projectRoot(), "/deployments/config.sepolia.json");
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        uint256 window = vm.envOr("LIVENESS_WINDOW", uint256(300));
        address owner = vm.envOr("LIVENESS_OWNER", deployer);

        console.log("=== CC-29 LivenessRegistry deploy ===");
        console.log("  deployer:", deployer);
        console.log("  initial owner:", owner);
        console.log("  livenessWindow (blocks):", window);

        vm.startBroadcast(deployerPk);
        LivenessRegistry reg = new LivenessRegistry(owner, window);
        vm.stopBroadcast();

        // Readback verification — assert the deployed state matches the intended config.
        require(reg.owner() == owner, "LR: owner mismatch");
        require(reg.livenessWindow() == window, "LR: window mismatch");
        require(reg.MAX_ATTEST_ANCHOR_AGE() == 256, "LR: anchor age");
        require(
            keccak256(bytes(reg.version())) == keccak256(bytes("LivenessRegistry-1.0.0")),
            "LR: version"
        );

        // Record (additive key — config-driven convention; downstream tooling / DVT read it here).
        vm.writeJson(vm.toString(address(reg)), configPath, ".livenessRegistry");
        // Read back so a silent vm.writeJson no-op fails loud (mirrors the CC-28 deploy pattern).
        require(
            vm.parseJsonAddress(vm.readFile(configPath), ".livenessRegistry") == address(reg),
            "LR: config write failed"
        );

        console.log("  LivenessRegistry:", address(reg));
        console.log("  version:", reg.version());
        console.log("  recorded to:", configPath);
        if (owner == deployer) {
            console.log("  NOTE: owner = deployer EOA. After bring-up, transferOwnership to the");
            console.log("        Mycelium community Safe:", MYCELIUM_SAFE);
        }
        console.log("=== Done. DVT reads isOffline/lastLive/areOffline at the address above. ===");
    }
}
