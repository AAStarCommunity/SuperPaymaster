// SPDX-License-Identifier: MIT
// 01_DeployGToken.s.sol
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/tokens/GToken.sol";

contract Deploy01_GToken is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deploying GToken with account:", deployer);
        
        vm.startBroadcast(deployerPrivateKey);
        
        uint256 gTokenCap = 21_000_000 * 1e18;
        GToken gToken = new GToken(gTokenCap);
        
        vm.stopBroadcast();
        
        console.log("GToken deployed to:", address(gToken));
    }
}
