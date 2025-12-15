// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {SuperPaymasterV2} from "../src/paymasters/superpaymaster/v2/SuperPaymasterV2_3.sol";

/**
 * @title ConfigureSuperPaymaster
 * @notice Configure SuperPaymaster V2 contract with aPNTs token address
 * @dev Run: forge script script/ConfigureSuperPaymaster.s.sol:ConfigureSuperPaymaster --rpc-url sepolia --broadcast --verify -vvvv
 *
 * Required .env variables:
 * - PRIVATE_KEY: Owner private key
 * - SEPOLIA_RPC_URL: Sepolia RPC URL
 */
contract ConfigureSuperPaymaster is Script {
    // Sepolia addresses from shared-config v0.3.1
    address constant SUPERPAYMASTER_V2 = 0xfaB5B2A129DF8308a70DA2fE77c61001e4Df58BC;
    address constant APNTS_TOKEN = 0xBD0710596010a157B88cd141d797E8Ad4bb2306b;  // ✅ CORRECT: shared-config/src/contract-addresses.ts:33

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Configure SuperPaymaster V2 ===");
        console.log("Deployer address:", deployer);
        console.log("SuperPaymaster V2:", SUPERPAYMASTER_V2);
        console.log("aPNTs Token:", APNTS_TOKEN);

        SuperPaymasterV2 superPaymaster = SuperPaymasterV2(payable(SUPERPAYMASTER_V2));

        // Check current aPNTs token
        address currentAPNTs;
        try superPaymaster.aPNTsToken() returns (address _aPNTs) {
            currentAPNTs = _aPNTs;
            console.log("\nCurrent aPNTs token:", currentAPNTs);
        } catch {
            console.log("\nCannot read current aPNTs token (may not have public getter)");
        }

        // Check owner
        address owner;
        try superPaymaster.owner() returns (address _owner) {
            owner = _owner;
            console.log("Contract owner:", owner);

            if (owner != deployer) {
                console.log("\n!!! WARNING !!!");
                console.log("Deployer is not the owner!");
                console.log("Expected:", deployer);
                console.log("Actual owner:", owner);
                console.log("You need to use the owner's private key");
                revert("Not authorized: deployer is not owner");
            }
        } catch {
            console.log("Cannot read owner (contract may not have owner() function)");
        }

        // Set aPNTs token
        vm.startBroadcast(deployerPrivateKey);

        console.log("\n--- Setting aPNTs token address ---");
        superPaymaster.setAPNTsToken(APNTS_TOKEN);
        console.log("Transaction sent!");

        vm.stopBroadcast();

        // Verify
        console.log("\n=== Verification ===");
        try superPaymaster.aPNTsToken() returns (address newAPNTs) {
            console.log("New aPNTs token:", newAPNTs);

            if (newAPNTs == APNTS_TOKEN) {
                console.log("SUCCESS: aPNTs token configured correctly!");
            } else {
                console.log("WARNING: aPNTs token mismatch!");
                console.log("Expected:", APNTS_TOKEN);
                console.log("Got:", newAPNTs);
            }
        } catch {
            console.log("Cannot verify (may need to wait for transaction confirmation)");
        }

        console.log("\n=== Configuration Complete ===");
    }
}
