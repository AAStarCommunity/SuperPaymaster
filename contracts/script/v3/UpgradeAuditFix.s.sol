// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/core/Registry.sol";
import "src/modules/reputation/ReputationSystem.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {UUPSUpgradeable} from "@openzeppelin-v5.0.2/contracts/proxy/utils/UUPSUpgradeable.sol";

/**
 * @title UpgradeAuditFix
 * @notice Deploys audit-fix versions of Registry, ReputationSystem, SuperPaymaster on Sepolia.
 *
 * Fixes applied (PR #63 — fix/audit-remediation):
 *   Registry (UUPS upgrade):
 *     - H-02: proposalId=0 now reverts with InvalidProposalId()
 *     - L-04: setSuperPaymaster / setBLSAggregator zero-addr guard
 *
 *   ReputationSystem (full redeploy):
 *     - H-02 companion: proposalId = keccak256(user, epoch) — non-zero, unique
 *     - Must be redeployed alongside Registry or all syncReputation calls will revert
 *
 *   SuperPaymaster (UUPS upgrade):
 *     - H-01: recordDebt called BEFORE aPNTs refund (proper CEI order)
 *     - L-04: setBLSAggregator zero-addr guard
 *
 * Contracts NOT redeployed (low priority / high migration cost):
 *   GTokenStaking — gas optimization only, locked-stake migration too costly
 *   MySBT         — pure refactor, identical behavior
 *   PaymasterBase — comment cleanup only
 *
 * Run on Sepolia:
 *   source .env.sepolia && forge script contracts/script/v3/UpgradeAuditFix.s.sol:UpgradeAuditFix \
 *     --rpc-url $RPC_URL --account $DEPLOYER_ACCOUNT --broadcast -vvvv
 *
 *   Or with raw key:
 *   source .env.sepolia && forge script contracts/script/v3/UpgradeAuditFix.s.sol:UpgradeAuditFix \
 *     --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast -vvvv
 */
contract UpgradeAuditFix is Script {

    function run() external {
        string memory configPath = string.concat(vm.projectRoot(), "/deployments/config.sepolia.json");
        string memory config = vm.readFile(configPath);

        address spProxy       = vm.parseJsonAddress(config, ".superPaymaster");
        address registryProxy = vm.parseJsonAddress(config, ".registry");
        address entryPoint    = vm.parseJsonAddress(config, ".entryPoint");
        address priceFeed     = vm.parseJsonAddress(config, ".priceFeed");
        address oldRepSystem  = vm.parseJsonAddress(config, ".reputationSystem");

        console.log("================================================================");
        console.log(" SuperPaymaster Audit Fix Deployment");
        console.log("================================================================");
        console.log("  Registry proxy:     ", registryProxy);
        console.log("  SuperPaymaster proxy:", spProxy);
        console.log("  Old ReputationSystem:", oldRepSystem);
        console.log("");

        // Pre-checks
        string memory regVerBefore = Registry(registryProxy).version();
        string memory spVerBefore  = SuperPaymaster(payable(spProxy)).version();
        console.log("  Registry version before:      ", regVerBefore);
        console.log("  SuperPaymaster version before: ", spVerBefore);

        vm.startBroadcast();

        // ────────────────────────────────────────────────────────────────
        // Step 1: Upgrade Registry impl (H-02 + L-04)
        // ────────────────────────────────────────────────────────────────
        console.log("\n[Step 1] Deploy + upgrade Registry impl (H-02 + L-04)...");

        Registry newRegistryImpl = new Registry();
        console.log("  New Registry impl: ", address(newRegistryImpl));

        UUPSUpgradeable(registryProxy).upgradeToAndCall(address(newRegistryImpl), "");
        console.log("  Registry upgraded (proxy address unchanged)");

        // ────────────────────────────────────────────────────────────────
        // Step 2: Redeploy ReputationSystem (H-02 companion)
        // ────────────────────────────────────────────────────────────────
        console.log("\n[Step 2] Redeploy ReputationSystem (H-02 companion)...");

        ReputationSystem newRepSystem = new ReputationSystem(registryProxy);
        console.log("  New ReputationSystem: ", address(newRepSystem));

        // Authorize new, deauthorize old
        Registry registry = Registry(registryProxy);
        registry.setReputationSource(address(newRepSystem), true);
        console.log("  Authorized new ReputationSystem");

        registry.setReputationSource(oldRepSystem, false);
        console.log("  Deauthorized old ReputationSystem");

        // ────────────────────────────────────────────────────────────────
        // Step 3: Upgrade SuperPaymaster impl (H-01 + L-04)
        // ────────────────────────────────────────────────────────────────
        console.log("\n[Step 3] Deploy + upgrade SuperPaymaster impl (H-01 + L-04)...");

        SuperPaymaster newSPImpl = new SuperPaymaster(
            IEntryPoint(entryPoint),
            Registry(registryProxy),
            priceFeed
        );
        console.log("  New SuperPaymaster impl: ", address(newSPImpl));

        UUPSUpgradeable(spProxy).upgradeToAndCall(address(newSPImpl), "");
        console.log("  SuperPaymaster upgraded (proxy address unchanged)");

        vm.stopBroadcast();

        // ────────────────────────────────────────────────────────────────
        // Post-deployment verification
        // ────────────────────────────────────────────────────────────────
        console.log("\n[Verification]");

        string memory regVerAfter = Registry(registryProxy).version();
        string memory spVerAfter  = SuperPaymaster(payable(spProxy)).version();
        string memory repVer      = newRepSystem.version();

        console.log("  Registry version after:       ", regVerAfter);
        console.log("  SuperPaymaster version after:  ", spVerAfter);
        console.log("  ReputationSystem version:      ", repVer);

        // Version checks (versions stay same — audit fixes don't bump minor versions)
        require(
            keccak256(bytes(regVerAfter)) == keccak256(bytes("Registry-4.1.0")),
            "Registry version mismatch"
        );
        require(
            keccak256(bytes(spVerAfter)) == keccak256(bytes("SuperPaymaster-5.3.0")),
            "SuperPaymaster version mismatch"
        );

        // isReputationSource check
        bool newAuthorized = Registry(registryProxy).isReputationSource(address(newRepSystem));
        bool oldDeauthorized = !Registry(registryProxy).isReputationSource(oldRepSystem);
        require(newAuthorized, "New ReputationSystem not authorized");
        require(oldDeauthorized, "Old ReputationSystem still authorized");

        console.log("\n================================================================");
        console.log(" All verifications passed!");
        console.log("================================================================");
        console.log("");
        console.log("  IMPORTANT: Update config.sepolia.json:");
        console.log("    reputationSystem:", address(newRepSystem));
        console.log("");
        console.log("  Registry + SuperPaymaster proxy addresses UNCHANGED.");
    }
}
