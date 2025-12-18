// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/paymasters/superpaymaster/v3/SuperPaymasterV3.sol";

contract Check07_SuperPaymaster is Script {
    function run(address spAddr) external view {
        SuperPaymasterV3 sp = SuperPaymasterV3(payable(spAddr));
        console.log("--- SuperPaymaster V3.1 Check ---");
        console.log("Address:", spAddr);
        console.log("Registry:", address(sp.REGISTRY()));
        console.log("EntryPoint:", address(sp.entryPoint()));
        console.log("aPNTs Token:", sp.APNTS_TOKEN());
        console.log("Price Feed:", address(sp.ETH_USD_PRICE_FEED()));
        console.log("Protocol Treasury:", sp.SUPER_PAYMASTER_TREASURY());
        console.log("Owner:", sp.owner());
        console.log("---------------------------------");
    }
}
