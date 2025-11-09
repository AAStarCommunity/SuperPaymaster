// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/v2/core/Registry_v2_2_0.sol";

/**
 * @title UpdateCommunityTokens
 * @notice Update community profiles with xPNTs tokens and MySBT contracts
 *
 * Updates:
 * 1. AAstar Community - Add aPNTs token
 * 2. Bread Community - Add bPNTs token
 * 3. Both communities - Add MySBT contract to supportedSBTs
 *
 * Usage:
 *   forge script script/UpdateCommunityTokens.s.sol:UpdateCommunityTokens \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --broadcast \
 *     -vvv
 */
contract UpdateCommunityTokens is Script {
    // Sepolia addresses
    address constant REGISTRY = 0x028aB52B4E0EF26820043ca4F1B5Fe14FfC1EF75;
    address constant MYSBT = 0xD1e6BDfb907EacD26FF69a40BBFF9278b1E7Cf5C;
    address constant APNTS = 0xBD0710596010a157B88cd141d797E8Ad4bb2306b;
    address constant BPNTS = 0x70Da2c1B7Fcf471247Bc3B09f8927a4ab1751Ba3;

    function run() external {
        uint256 deployer1PK = vm.envUint("PRIVATE_KEY");
        uint256 deployer2PK = vm.envUint("OWNER2_PRIVATE_KEY");

        address account1 = vm.addr(deployer1PK);
        address account2 = vm.addr(deployer2PK);

        console.log("================================================================================");
        console.log("=== Updating Community Tokens and SBTs ===");
        console.log("================================================================================");
        console.log("Registry:", REGISTRY);
        console.log("MySBT:", MYSBT);
        console.log("aPNTs:", APNTS);
        console.log("bPNTs:", BPNTS);
        console.log("");

        Registry registry = Registry(REGISTRY);

        // ========================================
        // Update Community 1 (AAstar) - Add aPNTs
        // ========================================
        console.log("Step 1: Updating AAstar Community...");

        vm.startBroadcast(deployer1PK);

        // Get current profile
        Registry.CommunityProfile memory profile1 = registry.getCommunityProfile(account1);

        console.log("  Current state:");
        console.log("    Name:", profile1.name);
        console.log("    xPNTsToken:", profile1.xPNTsToken);
        console.log("    supportedSBTs count:", profile1.supportedSBTs.length);

        // Update with aPNTs and MySBT
        profile1.xPNTsToken = APNTS;

        address[] memory sbts1 = new address[](1);
        sbts1[0] = MYSBT;
        profile1.supportedSBTs = sbts1;

        // Call update
        registry.updateCommunityProfile(profile1);

        console.log("  Updated successfully!");
        console.log("    xPNTsToken:", APNTS);
        console.log("    supportedSBTs: [MySBT]");

        vm.stopBroadcast();
        console.log("");

        // ========================================
        // Update Community 2 (Bread) - Add bPNTs
        // ========================================
        console.log("Step 2: Updating Bread Community...");

        vm.startBroadcast(deployer2PK);

        // Get current profile
        Registry.CommunityProfile memory profile2 = registry.getCommunityProfile(account2);

        console.log("  Current state:");
        console.log("    Name:", profile2.name);
        console.log("    xPNTsToken:", profile2.xPNTsToken);
        console.log("    supportedSBTs count:", profile2.supportedSBTs.length);

        // Update with bPNTs and MySBT
        profile2.xPNTsToken = BPNTS;

        address[] memory sbts2 = new address[](1);
        sbts2[0] = MYSBT;
        profile2.supportedSBTs = sbts2;

        // Call update
        registry.updateCommunityProfile(profile2);

        console.log("  Updated successfully!");
        console.log("    xPNTsToken:", BPNTS);
        console.log("    supportedSBTs: [MySBT]");

        vm.stopBroadcast();
        console.log("");

        // ========================================
        // Verify Updates
        // ========================================
        console.log("Step 3: Verifying updates...");
        console.log("");

        // Verify Community 1
        Registry.CommunityProfile memory updated1 = registry.getCommunityProfile(account1);
        console.log("AAstar Community (verified):");
        console.log("  Name:", updated1.name);
        console.log("  ENS:", updated1.ensName);
        console.log("  xPNTsToken:", updated1.xPNTsToken);
        console.log("  supportedSBTs count:", updated1.supportedSBTs.length);
        if (updated1.supportedSBTs.length > 0) {
            console.log("  supportedSBTs[0]:", updated1.supportedSBTs[0]);
        }
        console.log("  Node Type:", uint256(updated1.nodeType));
        console.log("  Is Active:", updated1.isActive);
        console.log("");

        // Verify Community 2
        Registry.CommunityProfile memory updated2 = registry.getCommunityProfile(account2);
        console.log("Bread Community (verified):");
        console.log("  Name:", updated2.name);
        console.log("  ENS:", updated2.ensName);
        console.log("  xPNTsToken:", updated2.xPNTsToken);
        console.log("  supportedSBTs count:", updated2.supportedSBTs.length);
        if (updated2.supportedSBTs.length > 0) {
            console.log("  supportedSBTs[0]:", updated2.supportedSBTs[0]);
        }
        console.log("  Node Type:", uint256(updated2.nodeType));
        console.log("  Is Active:", updated2.isActive);
        console.log("");

        console.log("================================================================================");
        console.log("=== Update Complete! ===");
        console.log("================================================================================");
        console.log("");
        console.log("Summary:");
        console.log("  AAstar Community: aPNTs + MySBT configured");
        console.log("  Bread Community: bPNTs + MySBT configured");
        console.log("");
        console.log("Next steps:");
        console.log("1. Update @aastar/shared-config with community info");
        console.log("2. Test MySBT minting for both communities");
        console.log("3. Test xPNTs token operations");
    }
}
