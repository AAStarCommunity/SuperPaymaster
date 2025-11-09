// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/v2/tokens/xPNTsFactory.sol";

/**
 * @title DeployTestTokens
 * @notice Deploy aPNTs and bPNTs from xPNTsFactory for testing
 */
contract DeployTestTokens is Script {
    function run() external {
        address factory = vm.envAddress("XPNTS_FACTORY");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log("=== Deploying Test Tokens from Factory ===");
        console.log("xPNTsFactory:", factory);
        console.log();

        xPNTsFactory factoryContract = xPNTsFactory(factory);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy aPNTs (AAStar community token)
        console.log("Deploying aPNTs...");
        address aPNTs = factoryContract.deployxPNTsToken(
            "AAStar Points",           // name
            "aPNTs",                   // symbol
            "AAStar",                  // communityName
            "aastar.eth",              // communityENS
            50000000000000000,         // exchangeRate (0.05 USD per aPNTs, 18 decimals)
            address(0)                 // paymasterAOA (no specific AOA paymaster)
        );
        console.log("aPNTs deployed:", aPNTs);

        // Deploy bPNTs (BuilderDAO community token)
        console.log();
        console.log("Deploying bPNTs...");
        address bPNTs = factoryContract.deployxPNTsToken(
            "BuilderDAO Points",       // name
            "bPNTs",                   // symbol
            "BuilderDAO",              // communityName
            "builderdao.eth",          // communityENS
            30000000000000000,         // exchangeRate (0.03 USD per bPNTs, 18 decimals)
            address(0)                 // paymasterAOA (no specific AOA paymaster)
        );
        console.log("bPNTs deployed:", bPNTs);

        vm.stopBroadcast();

        console.log();
        console.log("=== Deployment Complete ===");
        console.log("aPNTs:", aPNTs);
        console.log("bPNTs:", bPNTs);
        console.log();
        console.log("Verifying VERSION interfaces...");
        console.log("aPNTs VERSION:", xPNTsToken(aPNTs).VERSION());
        console.log("aPNTs VERSION_CODE:", xPNTsToken(aPNTs).VERSION_CODE());
        console.log("bPNTs VERSION:", xPNTsToken(bPNTs).VERSION());
        console.log("bPNTs VERSION_CODE:", xPNTsToken(bPNTs).VERSION_CODE());
    }
}
