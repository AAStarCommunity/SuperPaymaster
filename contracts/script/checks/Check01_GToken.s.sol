// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/tokens/GToken.sol";

contract Check01_GToken is Script {
    function run() external view {
        string memory root = vm.projectRoot();
        string memory configFile = vm.envOr("CONFIG_FILE", string("anvil.json"));
        string memory path = string.concat(root, "/deployments/", configFile);
        string memory json = vm.readFile(path);
        address gTokenAddr = vm.parseJsonAddress(json, ".gToken");

        GToken token = GToken(gTokenAddr);
        console.log("--- GToken Check ---");
        console.log("Address:", gTokenAddr);
        console.log("Name:", token.name());
        console.log("Symbol:", token.symbol());
        console.log("Total Supply:", token.totalSupply() / 1e18, "GToken");
        console.log("Owner:", token.owner());
        
        console.log("Version:", token.version());
        console.log("--------------------");
    }
}
