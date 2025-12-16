// SPDX-License-Identifier: MIT
// 09_MintInitialTokens.s.sol
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/tokens/GToken.sol";
import "src/tokens/xPNTsToken.sol";

contract Deploy09_MintInitialTokens is Script {
    function run(address gTokenAddr, address apntsTokenAddr) external {
        require(gTokenAddr != address(0), "GToken address cannot be zero.");
        require(apntsTokenAddr != address(0), "aPNTs address cannot be zero.");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Minting initial tokens to account:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        GToken(gTokenAddr).mint(deployer, 1_000_000 * 1e18);
        // The mock aPNTs token is an xPNTsToken, which has a restricted mint function
        xPNTsToken(apntsTokenAddr).mint(deployer, 1_000_000 * 1e18);

        vm.stopBroadcast();

        console.log("Initial tokens minted successfully.");
    }
}
