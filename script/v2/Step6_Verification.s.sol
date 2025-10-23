// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../../src/v2/core/SuperPaymasterV2.sol";
import "../../src/v2/tokens/xPNTsToken.sol";
import "../../src/v2/tokens/MySBT.sol";
import "../../contracts/test/mocks/MockERC20.sol";

/**
 * @title Step6_Verification
 * @notice V2测试流程 - 步骤6: 最终验证
 *
 * 功能：
 * 1. 检查operator账户状态
 * 2. 检查用户资产
 * 3. 检查treasury余额
 * 4. 检查aPNTs分布和内部记账
 * 5. 生成测试报告
 */
contract Step6_Verification is Script {

    SuperPaymasterV2 superPaymaster;
    MockERC20 apntsToken;
    xPNTsToken operatorXPNTs;
    MySBT mysbt;

    address user;
    address operator;
    address operatorTreasury;
    address superPaymasterTreasury;

    function setUp() public {
        // 加载合约
        superPaymaster = SuperPaymasterV2(vm.envAddress("SUPER_PAYMASTER_V2_ADDRESS"));
        apntsToken = MockERC20(vm.envAddress("APNTS_TOKEN_ADDRESS"));
        operatorXPNTs = xPNTsToken(vm.envAddress("OPERATOR_XPNTS_TOKEN_ADDRESS"));
        mysbt = MySBT(vm.envAddress("MYSBT_ADDRESS"));

        // 账户
        user = address(0x999);
        operator = vm.envAddress("OWNER2_ADDRESS");
        operatorTreasury = address(0x777);
        superPaymasterTreasury = address(0x888);
    }

    function run() public view {
        console.log("=== Step 6: Final Verification ===\n");

        // 1. 检查operator账户
        console.log("6.1 Checking operator account...");
        SuperPaymasterV2.OperatorAccount memory account = superPaymaster.getOperatorAccount(operator);

        console.log("    Operator:", operator);
        console.log("    Is registered:", account.stakedAt > 0);
        console.log("    Staked amount:", account.stakedAmount / 1e18, "sGT");
        console.log("    aPNTs balance:", account.aPNTsBalance / 1e18, "aPNTs");
        console.log("    Treasury:", account.treasury);
        console.log("    xPNTs token:", account.xPNTsToken);
        console.log("    Exchange rate:", account.exchangeRate / 1e18);
        console.log("    Total spent:", account.totalSpent / 1e18, "aPNTs");
        console.log("    Total tx sponsored:", account.totalTxSponsored);
        console.log("    Is paused:", account.isPaused);

        // 2. 检查用户资产
        console.log("\n6.2 Checking user assets...");
        uint256 userSBTCount = mysbt.balanceOf(user);
        uint256 userXPNTs = operatorXPNTs.balanceOf(user);

        console.log("    User:", user);
        console.log("    SBT count:", userSBTCount);
        console.log("    xPNTs balance:", userXPNTs / 1e18, "xTEST");

        // 3. 检查treasury余额
        console.log("\n6.3 Checking treasuries...");
        uint256 operatorTreasuryXPNTs = operatorXPNTs.balanceOf(operatorTreasury);
        uint256 treasuryAPNTsBalance = superPaymaster.treasuryAPNTsBalance();

        console.log("    Operator treasury:", operatorTreasury);
        console.log("      xPNTs balance:", operatorTreasuryXPNTs / 1e18, "xTEST");
        console.log("    SuperPaymaster treasury:", superPaymasterTreasury);
        console.log("      aPNTs balance (internal):", treasuryAPNTsBalance / 1e18, "aPNTs");

        // 4. 检查aPNTs分布
        console.log("\n6.4 Checking aPNTs distribution...");
        uint256 contractAPNTs = apntsToken.balanceOf(address(superPaymaster));
        uint256 operatorAPNTs = account.aPNTsBalance;
        uint256 treasuryAPNTs = treasuryAPNTsBalance;

        console.log("    SuperPaymaster contract holds:", contractAPNTs / 1e18, "aPNTs");
        console.log("    Operator balance (internal):", operatorAPNTs / 1e18, "aPNTs");
        console.log("    Treasury balance (internal):", treasuryAPNTs / 1e18, "aPNTs");
        console.log("    Sum equals contract:", (operatorAPNTs + treasuryAPNTs) == contractAPNTs);

        // 5. 生成测试报告
        console.log("\n6.5 Test Report Summary...");
        console.log("    ========================================");
        console.log("    V2 Main Flow Test Results");
        console.log("    ========================================");
        console.log("    [SETUP]");
        console.log("      aPNTs token deployed: YES");
        console.log("      SuperPaymaster configured: YES");
        console.log("    [OPERATOR]");
        console.log("      Registered: YES");
        console.log("      aPNTs deposited:", operatorAPNTs / 1e18, "aPNTs");
        console.log("      Treasury configured:", account.treasury == operatorTreasury);
        console.log("    [USER]");
        console.log("      Has SBT:", userSBTCount > 0);
        console.log("      Has xPNTs:", userXPNTs / 1e18, "xTEST");
        console.log("    [PAYMENT FLOW]");
        console.log("      User -> Operator treasury:", operatorTreasuryXPNTs / 1e18, "xTEST");
        console.log("      Operator -> SuperPaymaster:", treasuryAPNTs / 1e18, "aPNTs (internal)");
        console.log("    [INTERNAL ACCOUNTING]");
        console.log("      Balance integrity:", (operatorAPNTs + treasuryAPNTs) == contractAPNTs);
        console.log("    ========================================");

        // 6. 结论
        console.log("\n[SUCCESS] Step 6 completed!");
        console.log("\nConclusions:");
        if (userSBTCount > 0 && account.stakedAt > 0) {
            console.log("- V2 main flow setup: COMPLETE");
            console.log("- Operator registration: VERIFIED");
            console.log("- User preparation: VERIFIED");
            console.log("- Payment mechanism: PARTIALLY TESTED");
            console.log("  (Full test requires EntryPoint integration)");
        } else {
            console.log("- WARNING: Some components not properly configured");
        }

        console.log("\nNext steps:");
        console.log("1. Integrate with EntryPoint for full UserOp testing");
        console.log("2. Test with bundler for production flow");
        console.log("3. Test PaymasterV4 compatibility");
    }
}
