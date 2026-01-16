// SPDX-License-Identifier: MIT
// 06_2_MintBPNTs.s.sol
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/tokens/xPNTsToken.sol"; 

contract MintBPNTs is Script {
    function run(address tokenAddr, address toAddr, uint256 amount) external {
        uint256 anniPrivateKey = vm.envUint("PRIVATE_KEY_ANNI");
        address owner = vm.addr(anniPrivateKey);
        console.log("Minting bPNTs using Owner (Anni):", owner);

        vm.startBroadcast(anniPrivateKey);

        // Cast to xPNTsToken and call mint
        xPNTsToken(tokenAddr).mint(toAddr, amount);

        vm.stopBroadcast();
        console.log("Minted", amount/1e18, "bPNTs to", toAddr);
    }
}
