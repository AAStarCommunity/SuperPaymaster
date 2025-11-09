// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/v2/tokens/xPNTsFactory.sol";

/**
 * @title DeployAPNTs
 * @notice Deploy aPNTs from xPNTsFactory using main deployer account
 */
contract DeployAPNTs is Script {
    function run() external {
        address factory = vm.envAddress("XPNTS_FACTORY");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log("=== Deploying aPNTs from Factory ===");
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

        vm.stopBroadcast();

        console.log();
        console.log("=== Deployment Complete ===");
        console.log("aPNTs:", aPNTs);
        console.log();
        console.log("Verifying VERSION interface...");
        console.log("aPNTs VERSION:", xPNTsToken(aPNTs).VERSION());
        console.log("aPNTs VERSION_CODE:", xPNTsToken(aPNTs).VERSION_CODE());
    }
}
