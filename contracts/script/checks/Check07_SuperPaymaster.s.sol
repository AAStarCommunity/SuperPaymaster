// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/paymasters/superpaymaster/v3/SuperPaymaster.sol";

contract Check07_SuperPaymaster is Script {
    function run() external view {
        string memory root = vm.projectRoot();
        string memory configFile = vm.envOr("CONFIG_FILE", string("anvil.json"));
        string memory path = string.concat(root, "/deployments/", configFile);
        string memory json = vm.readFile(path);
        address spAddr = vm.parseJsonAddress(json, ".superPaymaster");

        SuperPaymaster sp = SuperPaymaster(payable(spAddr));
        console.log("--- SuperPaymaster V3.1 Check ---");
        console.log("Address:", spAddr);
        console.log("Registry:", address(sp.REGISTRY()));
        console.log("EntryPoint:", address(sp.entryPoint()));
        console.log("aPNTs Token:", sp.APNTS_TOKEN());
        console.log("Price Feed:", address(sp.ETH_USD_PRICE_FEED()));
        console.log("Protocol Treasury:", sp.treasury());
        console.log("Owner:", sp.owner());
        console.log("---------------------------------");
    }
}
