// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/superpaymaster/v2/SuperPaymasterV2_3.sol";

/**
 * @title FixAPNTsAddress
 * @notice Update SuperPaymaster aPNTs token address to match shared-config
 *
 * Root Cause:
 * - SuperPaymaster configured with: 0x2ee6b2bc43022c37b5efb533836495209de5eca8 (no code)
 * - shared-config uses: 0xBD0710596010a157B88cd141d797E8Ad4bb2306b (deployed)
 * - Frontend approves shared-config address, but SuperPaymaster expects configured address
 * - Result: AddressEmptyCode error when depositing aPNTs
 *
 * Solution:
 * - Call setAPNTsToken() to update SuperPaymaster configuration
 */
contract FixAPNTsAddress is Script {
    // Sepolia addresses
    address constant SUPERPAYMASTER = 0xfaB5B2A129DF8308a70DA2fE77c61001e4Df58BC;
    address constant CORRECT_APNTS = 0xBD0710596010a157B88cd141d797E8Ad4bb2306b;  // shared-config address

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log("=== Fixing SuperPaymaster aPNTs Address ===");
        console.log("SuperPaymaster:", SUPERPAYMASTER);
        console.log("Correct aPNTs:", CORRECT_APNTS);
        console.log();

        SuperPaymasterV2_3 superPaymaster = SuperPaymasterV2_3(payable(SUPERPAYMASTER));

        // Check current configuration
        address currentAPNTs = superPaymaster.aPNTsToken();
        console.log("Current aPNTs token:", currentAPNTs);
        console.log("Has code:", currentAPNTs.code.length > 0);
        console.log();

        if (currentAPNTs == CORRECT_APNTS) {
            console.log("Already configured correctly!");
            return;
        }

        vm.startBroadcast(deployerPrivateKey);

        // Update aPNTs token address
        console.log("Updating aPNTs token address...");
        superPaymaster.setAPNTsToken(CORRECT_APNTS);
        console.log("Transaction sent!");

        vm.stopBroadcast();

        // Verify
        address newAPNTs = superPaymaster.aPNTsToken();
        console.log();
        console.log("=== Verification ===");
        console.log("New aPNTs token:", newAPNTs);
        console.log("Has code:", newAPNTs.code.length > 0);
        console.log("Match expected:", newAPNTs == CORRECT_APNTS ? "YES" : "NO");

        if (newAPNTs == CORRECT_APNTS && newAPNTs.code.length > 0) {
            console.log();
            console.log("SUCCESS! aPNTs address fixed.");
            console.log("Users can now deposit aPNTs.");
        } else {
            console.log();
            console.log("ERROR! Configuration failed.");
        }
    }
}
