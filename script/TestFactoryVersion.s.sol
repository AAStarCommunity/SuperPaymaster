// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/v2/tokens/xPNTsFactory.sol";

/**
 * @title TestFactoryVersion
 * @notice 测试xPNTsFactory是否支持统一架构（6参数 + aPNTs价格管理）
 */
contract TestFactoryVersion is Script {
    function run() external view {
        address factoryAddr = vm.envAddress("XPNTS_FACTORY_ADDRESS");

        console.log("Testing xPNTsFactory at:", factoryAddr);
        console.log("");

        xPNTsFactory factory = xPNTsFactory(factoryAddr);

        // Test 1: Check if getAPNTsPrice() exists and returns value
        try factory.getAPNTsPrice() returns (uint256 price) {
            console.log("[PASS] getAPNTsPrice() exists");
            console.log("       aPNTs Price USD:", price);
            console.log("       Expected: 20000000000000000 (0.02e18)");

            if (price == 0.02 ether) {
                console.log("       [OK] Price matches expected value");
            } else {
                console.log("       [WARN] Price does not match");
            }
        } catch {
            console.log("[FAIL] getAPNTsPrice() does not exist");
            console.log("       This factory is NOT the unified architecture version");
            console.log("       Need to deploy new factory with:");
            console.log("       - aPNTsPriceUSD storage");
            console.log("       - getAPNTsPrice() function");
            console.log("       - updateAPNTsPrice() function");
            console.log("       - deployxPNTsToken() with 6 parameters");
            return;
        }

        console.log("");
        console.log("====================================");
        console.log("Factory Version: UNIFIED ARCHITECTURE");
        console.log("Ready for 6-parameter deployxPNTsToken");
        console.log("====================================");
    }
}
