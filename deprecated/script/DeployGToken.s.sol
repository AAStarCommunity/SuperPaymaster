// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/tokens/GToken.sol";

/**
 * @title DeployGToken
 * @notice Deploy GToken v2.0.0 with VERSION interface
 */
contract DeployGToken is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Cap: 21,000,000 * 10^18
        uint256 cap = 21_000_000 ether;

        console.log("=== Deploying GToken v2.0.0 ===");
        console.log("Cap:", cap);
        console.log();

        vm.startBroadcast(deployerPrivateKey);

        GToken gtoken = new GToken(cap);

        console.log("GToken deployed:", address(gtoken));
        console.log("VERSION:", gtoken.VERSION());
        console.log("VERSION_CODE:", gtoken.VERSION_CODE());
        console.log("Name:", gtoken.name());
        console.log("Symbol:", gtoken.symbol());
        console.log("Cap:", gtoken.cap());

        vm.stopBroadcast();

        console.log();
        console.log("=== Deployment Complete ===");
        console.log("Address:", address(gtoken));
        console.log("Owner:", gtoken.owner());
    }
}
