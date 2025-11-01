// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/paymasters/v2/tokens/xPNTsFactory.sol";

/**
 * @title DeployBPNTs
 * @notice Deploy bPNTs from xPNTsFactory using DEPLOYER2 account
 */
contract DeployBPNTs is Script {
    function run() external {
        address factory = vm.envAddress("XPNTS_FACTORY");
        uint256 deployer2PrivateKey = vm.envUint("PRIVATE_KEY_DEPLOYER2");

        console.log("=== Deploying bPNTs from Factory ===");
        console.log("xPNTsFactory:", factory);
        console.log();

        xPNTsFactory factoryContract = xPNTsFactory(factory);

        vm.startBroadcast(deployer2PrivateKey);

        // Deploy bPNTs (BuilderDAO community token)
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
        console.log("bPNTs:", bPNTs);
        console.log();
        console.log("Verifying VERSION interface...");
        console.log("bPNTs VERSION:", xPNTsToken(bPNTs).VERSION());
        console.log("bPNTs VERSION_CODE:", xPNTsToken(bPNTs).VERSION_CODE());
    }
}
