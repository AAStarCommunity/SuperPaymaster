// SPDX-License-Identifier: MIT
// 06_3_MintAPNTs.s.sol
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/tokens/xPNTsToken.sol"; 

contract MintAPNTs is Script {
    function run(address tokenAddr, address toAddr, uint256 amount) external {
        uint256 jasonPrivateKey = vm.envUint("PRIVATE_KEY_JASON");
        address owner = vm.addr(jasonPrivateKey);
        console.log("Minting aPNTs using Owner (Jason):", owner);

        vm.startBroadcast(jasonPrivateKey);

        // Cast to xPNTsToken and call mint
        xPNTsToken(tokenAddr).mint(toAddr, amount);

        vm.stopBroadcast();
        console.log("Minted", amount/1e18, "aPNTs to", toAddr);
    }
}
