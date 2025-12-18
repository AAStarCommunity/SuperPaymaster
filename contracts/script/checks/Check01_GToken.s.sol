// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/tokens/GToken.sol";

contract Check01_GToken is Script {
    function run(address gTokenAddr) external view {
        GToken token = GToken(gTokenAddr);
        console.log("--- GToken Check ---");
        console.log("Address:", gTokenAddr);
        console.log("Name:", token.name());
        console.log("Symbol:", token.symbol());
        console.log("Total Supply:", token.totalSupply() / 1e18, "GToken");
        console.log("Owner:", token.owner());
        
        try token.VERSION() returns (string memory v) {
            console.log("Version:", v);
        } catch {
            console.log("Version: N/A");
        }
        console.log("--------------------");
    }
}
