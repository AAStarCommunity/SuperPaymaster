// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/v2/core/SuperPaymasterV2.sol";

/**
 * @title ConfigureSuperPaymaster_v2_1_0
 * @notice Configure SuperPaymaster V2.1.0 with EntryPoint, aPNTs token, and Treasury
 *
 * @dev Configuration Steps:
 *   1. setEntryPoint() - ERC-4337 EntryPoint v0.7
 *   2. setAPNTsToken() - AAStar Points token address
 *   3. setSuperPaymasterTreasury() - Treasury for receiving consumed aPNTs
 *
 * @dev Required Environment Variables:
 *   - SUPERPAYMASTER_V2_1_0: SuperPaymaster v2.1.0 contract address (from deployment)
 *   - ENTRYPOINT_V07: EntryPoint v0.7 address
 *   - APNTS_TOKEN: aPNTs token address (from shared-config)
 *   - SUPERPAYMASTER_TREASURY: Treasury address for receiving aPNTs
 *   - PRIVATE_KEY: Owner private key
 *
 * @dev Usage:
 *   source .env
 *   forge script script/v2/ConfigureSuperPaymaster_v2_1_0.s.sol:ConfigureSuperPaymaster_v2_1_0 \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --broadcast \
 *     -vvvv
 */
contract ConfigureSuperPaymaster_v2_1_0 is Script {
    function run() external {
        address superPaymasterV210 = vm.envAddress("SUPERPAYMASTER_V2_1_0");
        address entrypointV07 = vm.envOr("ENTRYPOINT_V07", 0x0000000071727De22E5E9d8BAf0edAc6f37da032);
        address apntsToken = vm.envOr("APNTS_TOKEN", 0xBD0710596010a157B88cd141d797E8Ad4bb2306b);
        address treasury = vm.envAddress("SUPERPAYMASTER_TREASURY");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("================================================");
        console.log("   Configuring SuperPaymaster V2.1.0");
        console.log("================================================");

        console.log("\nContract Addresses:");
        console.log("  SuperPaymaster v2.1.0: ", superPaymasterV210);
        console.log("  EntryPoint v0.7:       ", entrypointV07);
        console.log("  aPNTs Token:           ", apntsToken);
        console.log("  Treasury:              ", treasury);
        console.log("  Owner:                 ", deployer);
        console.log("");

        SuperPaymasterV2 superPaymaster = SuperPaymasterV2(payable(superPaymasterV210));

        // Verify ownership
        address owner = superPaymaster.owner();
        console.log("Contract Owner:", owner);
        if (owner != deployer) {
            console.log("\n!!! WARNING !!!");
            console.log("Deployer is not the owner!");
            console.log("Expected:", deployer);
            console.log("Actual owner:", owner);
            revert("Not authorized: deployer is not owner");
        }

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        console.log("\n--- Step 1: Configure EntryPoint ---");
        superPaymaster.setEntryPoint(entrypointV07);
        console.log("EntryPoint configured!");

        console.log("\n--- Step 2: Configure aPNTs Token ---");
        superPaymaster.setAPNTsToken(apntsToken);
        console.log("aPNTs token configured!");

        console.log("\n--- Step 3: Configure Treasury ---");
        superPaymaster.setSuperPaymasterTreasury(treasury);
        console.log("Treasury configured!");

        vm.stopBroadcast();

        console.log("\n================================================");
        console.log("   Configuration Complete!");
        console.log("================================================");

        // Verify configuration
        console.log("\nVerifying configuration...");
        console.log("  ENTRY_POINT:           ", superPaymaster.ENTRY_POINT());
        console.log("  aPNTsToken:            ", superPaymaster.aPNTsToken());
        console.log("  superPaymasterTreasury:", superPaymaster.superPaymasterTreasury());

        require(superPaymaster.ENTRY_POINT() == entrypointV07, "EntryPoint mismatch");
        require(superPaymaster.aPNTsToken() == apntsToken, "aPNTs token mismatch");
        require(superPaymaster.superPaymasterTreasury() == treasury, "Treasury mismatch");

        console.log("\nVerification passed!");
        console.log("");
        console.log("Next Step:");
        console.log("Configure SuperPaymaster as authorized locker:");
        console.log("  forge script script/v2/ConfigureSuperPaymaster_v2_1_0_Locker.s.sol --broadcast");
    }
}
