// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";
import "src/tokens/xPNTsToken.sol";
import {SuperPaymaster} from "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import {Paymaster} from "src/paymasters/v4/Paymaster.sol";
import {PaymasterFactory} from "src/paymasters/v4/core/PaymasterFactory.sol";

/**
 * @title Check09_TestAccounts
 * @notice Phase 2 Verification Script
 * @dev Verifies Anni's demo community and Paymaster setup
 */
contract Check09_TestAccounts is Script {
    function run() external view {
        string memory root = vm.projectRoot();
        string memory configFile = vm.envOr("CONFIG_FILE", string("config.anvil.json"));
        string memory path = string.concat(root, "/deployments/", configFile);
        string memory json = vm.readFile(path);
        
        address registry = stdJson.readAddress(json, ".registry");
        address superPaymaster = stdJson.readAddress(json, ".superPaymaster");
        address gToken = stdJson.readAddress(json, ".gToken");
        address pmFactory = stdJson.readAddress(json, ".paymasterFactory");
        
        address anni = 0xEcAACb915f7D92e9916f449F7ad42BD0408733c9;
        
        console.log("=== Phase 2 Verification: Test Accounts (Anni) ===");

        // 1. Role Verification
        bool isAnniCommunity = Registry(registry).hasRole(keccak256("COMMUNITY"), anni);
        bool isAnniOperator = Registry(registry).hasRole(keccak256("PAYMASTER_SUPER"), anni);
        bool isAnniPMAOA = Registry(registry).hasRole(keccak256("PAYMASTER_AOA"), anni);
        
        console.log("  Anni Community Role: ", isAnniCommunity);
        console.log("  Anni SP Operator Role:", isAnniOperator);
        console.log("  Anni PM_AOA Role:    ", isAnniPMAOA);
        
        require(isAnniCommunity, "Check09: Anni missing Community role");
        require(isAnniOperator, "Check09: Anni missing SP Operator role");
        require(isAnniPMAOA, "Check09: Anni missing PM_AOA role");

        // 2. Token & Config Verification
        (
            uint128 aPNTsBalance,
            uint96 exchangeRate,
            bool isConfigured,
            bool isPaused,
            address xPNTsToken,
            uint32 reputation,
            uint48 minTxInterval,
            address treasury,
            uint256 totalSpent,
            uint256 totalTxSponsored
        ) = SuperPaymaster(payable(superPaymaster)).operators(anni);
        
        console.log("  Anni SP Token:       ", xPNTsToken);
        console.log("  Anni SP Rate:        ", exchangeRate);
        console.log("  Anni SP Treasury:    ", treasury);
        
        require(xPNTsToken != address(0), "Check09: Anni SP Token not configured");
        require(treasury == anni, "Check09: Anni SP Treasury mismatch");

        // 3. V4 Paymaster Verification
        address anniPM = PaymasterFactory(pmFactory).getPaymasterByOperator(anni);
        console.log("  Anni V4 PM Proxy:    ", anniPM);
        require(anniPM != address(0), "Check09: Anni V4 PM not deployed");
        
        // 4. Funding Verification
        uint256 anniGT = GToken(gToken).balanceOf(anni);
        console.log("  Anni GT Balance:     ", anniGT / 1e18);
        require(anniGT >= 50 ether, "Check09: Anni low GT balance");

        console.log("=== Phase 2 Verification Success ===");
    }
}
