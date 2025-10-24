// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/paymasters/v2/core/SuperPaymasterV2.sol";
import "../../contracts/test/mocks/MockERC20.sol";

/**
 * @title Step1_Setup
 * @notice V2测试流程 - 步骤1: 初始配置
 *
 * 功能：
 * 1. 部署aPNTs token (AAStar社区token)
 * 2. 配置SuperPaymaster的aPNTs token地址
 * 3. 配置SuperPaymaster的treasury地址
 * 4. 验证配置成功
 */
contract Step1_Setup is Script {

    SuperPaymasterV2 superPaymaster;
    MockERC20 apntsToken;

    address superPaymasterTreasury;

    function setUp() public {
        // 加载已部署的SuperPaymaster合约
        superPaymaster = SuperPaymasterV2(vm.envAddress("SUPER_PAYMASTER_V2_ADDRESS"));

        // 设置treasury地址
        superPaymasterTreasury = address(0x888);
    }

    function run() public {
        console.log("=== Step 1: Setup & Configuration ===\n");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        // 1. 部署aPNTs token
        console.log("1.1 Deploying aPNTs token (AAStar Points)...");
        apntsToken = new MockERC20("AAStar Points", "aPNTs", 18);
        console.log("    aPNTs token deployed at:", address(apntsToken));

        // 2. 配置SuperPaymaster
        console.log("\n1.2 Configuring SuperPaymaster...");
        superPaymaster.setAPNTsToken(address(apntsToken));
        console.log("    aPNTs token configured");

        superPaymaster.setSuperPaymasterTreasury(superPaymasterTreasury);
        console.log("    SuperPaymaster treasury:", superPaymasterTreasury);

        // 3. 验证配置
        console.log("\n1.3 Verifying configuration...");
        address configuredAPNTs = superPaymaster.aPNTsToken();
        address configuredTreasury = superPaymaster.superPaymasterTreasury();

        console.log("    Configured aPNTs:", configuredAPNTs);
        console.log("    Configured treasury:", configuredTreasury);

        require(configuredAPNTs == address(apntsToken), "aPNTs token mismatch");
        require(configuredTreasury == superPaymasterTreasury, "Treasury mismatch");

        console.log("\n[SUCCESS] Step 1 completed!");
        console.log("\nEnvironment variables to save:");
        console.log("APNTS_TOKEN_ADDRESS=", address(apntsToken));

        vm.stopBroadcast();
    }
}
