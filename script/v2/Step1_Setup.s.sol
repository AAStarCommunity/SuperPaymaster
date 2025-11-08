// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/v2/core/SuperPaymasterV2.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";

/**
 * @title Step1_Setup
 * @notice V2测试流程 - 步骤1: 初始配置
 *
 * 功能：
 * 1. 使用已部署的aPNTs token (从环境变量 APNTS_TOKEN_ADDRESS 读取)
 * 2. 配置SuperPaymaster的aPNTs token地址
 * 3. 配置SuperPaymaster的treasury地址
 * 4. 验证配置成功
 *
 * IMPORTANT: aPNTs token must be deployed separately before running this script.
 * For testing, you can deploy a standard ERC20 token using a separate deployment script.
 */
contract Step1_Setup is Script {

    SuperPaymasterV2 superPaymaster;
    IERC20 apntsToken;

    address superPaymasterTreasury;

    function setUp() public {
        // 加载已部署的SuperPaymaster合约
        superPaymaster = SuperPaymasterV2(vm.envAddress("SUPER_PAYMASTER_V2_ADDRESS"));

        // 设置treasury地址
        superPaymasterTreasury = address(0x888);
    }

    function run() public {
        console.log("=== Step 1: Setup & Configuration ===\n");

        // 1. 加载已部署的aPNTs token
        console.log("1.1 Loading aPNTs token (AAStar Points)...");
        apntsToken = IERC20(vm.envAddress("APNTS_TOKEN_ADDRESS"));
        console.log("    aPNTs token address:", address(apntsToken));

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        // 2. 配置SuperPaymaster
        console.log("\n1.2 Configuring SuperPaymaster...");
        superPaymaster.setAPNTsToken(address(apntsToken));
        console.log("    aPNTs token configured");

        superPaymaster.setSuperPaymasterTreasury(superPaymasterTreasury);
        console.log("    SuperPaymaster treasury:");
        console.logAddress(superPaymasterTreasury);

        // 3. 验证配置
        console.log("\n1.3 Verifying configuration...");
        address configuredAPNTs = superPaymaster.aPNTsToken();
        address configuredTreasury = superPaymaster.superPaymasterTreasury();

        console.log("    Configured aPNTs:");
        console.logAddress(configuredAPNTs);
        console.log("    Configured treasury:");
        console.logAddress(configuredTreasury);

        require(configuredAPNTs == address(apntsToken), "aPNTs token mismatch");
        require(configuredTreasury == superPaymasterTreasury, "Treasury mismatch");

        console.log("\n[SUCCESS] Step 1 completed!");
        console.log("\nNOTE: APNTS_TOKEN_ADDRESS environment variable is already set");

        vm.stopBroadcast();
    }
}
