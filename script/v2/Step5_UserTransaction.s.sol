// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/superpaymaster/v2/SuperPaymasterV2.sol";
import "src/tokens/xPNTsToken.sol";

/**
 * @title Step5_UserTransaction
 * @notice V2测试流程 - 步骤5: 用户交易模拟
 *
 * 功能：
 * 1. 用户approve xPNTs
 * 2. 模拟用户交易（手动计算费用并转账）
 * 3. 验证双重支付（用户支付xPNTs，operator消耗aPNTs）
 *
 * 注意：
 * - 这是简化版本，实际需要EntryPoint调用validatePaymasterUserOp
 * - 这里手动模拟支付流程来验证经济模型
 */
contract Step5_UserTransaction is Script {

    SuperPaymasterV2 superPaymaster;
    xPNTsToken operatorXPNTs;

    address user;
    uint256 userKey;
    address operator;
    address operatorTreasury;

    function setUp() public {
        // 加载合约
        superPaymaster = SuperPaymasterV2(vm.envAddress("SUPER_PAYMASTER_V2_ADDRESS"));
        operatorXPNTs = xPNTsToken(vm.envAddress("OPERATOR_XPNTS_TOKEN_ADDRESS"));

        // 账户 - 使用与Step4相同的用户私钥
        userKey = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef;
        user = vm.addr(userKey);
        operator = vm.envAddress("OWNER2_ADDRESS");
        operatorTreasury = address(0x777);
    }

    function run() public {
        console.log("=== Step 5: User Transaction Simulation ===\n");

        // 1. 计算费用
        console.log("5.1 Calculating transaction cost...");

        // 模拟gas cost: 0.001 ETH
        uint256 gasCost = 0.001 ether;

        // 计算aPNTs和xPNTs费用
        // gasToUSDRate = 3000 USD/ETH, aPNTsPriceUSD = 0.02 USD
        // gasCostUSD = 0.001 * 3000 = 3 USD
        // with 2% fee = 3.06 USD
        // aPNTs = 3.06 / 0.02 = 153 aPNTs
        uint256 aPNTsCost = 153 ether;
        uint256 xPNTsCost = aPNTsCost;  // 1:1 exchange rate

        console.log("    Gas cost:");
        console.logUint(gasCost);
        console.log("    aPNTs cost:");
        console.log(aPNTsCost / 1e18, "aPNTs");
        console.log("    xPNTs cost:");
        console.log(xPNTsCost / 1e18, "xTEST");

        // 2. 记录交易前余额
        console.log("\n5.2 Recording balances before transaction...");

        uint256 userXPNTsBefore = operatorXPNTs.balanceOf(user);
        uint256 treasuryXPNTsBefore = operatorXPNTs.balanceOf(operatorTreasury);

        SuperPaymasterV2.OperatorAccount memory accountBefore = superPaymaster.getOperatorAccount(operator);
        uint256 treasuryAPNTsBefore = superPaymaster.treasuryAPNTsBalance();

        console.log("    [BEFORE]");
        console.log("      User xPNTs:");
        console.log(userXPNTsBefore / 1e18, "xTEST");
        console.log("      Operator treasury xPNTs:");
        console.log(treasuryXPNTsBefore / 1e18, "xTEST");
        console.log("      Operator aPNTs balance:");
        console.log(accountBefore.aPNTsBalance / 1e18, "aPNTs");
        console.log("      SuperPaymaster treasury aPNTs (internal):");
        console.log(treasuryAPNTsBefore / 1e18, "aPNTs");

        // 3. 用户approve并支付xPNTs
        console.log("\n5.3 User approving and paying xPNTs...");
        vm.startBroadcast(userKey);
        operatorXPNTs.approve(address(superPaymaster), xPNTsCost);
        console.log("    User approved", xPNTsCost / 1e18, "xTEST");
        vm.stopBroadcast();

        // 4. 手动模拟双重支付
        console.log("\n5.4 Simulating dual payment...");
        console.log("    Note: In production, EntryPoint calls validatePaymasterUserOp");

        // 模拟用户xPNTs转账到operator treasury
        vm.startBroadcast(userKey);
        operatorXPNTs.transfer(operatorTreasury, xPNTsCost);
        console.log("    [1] User xPNTs -> Operator treasury: DONE");
        vm.stopBroadcast();

        // 注意：aPNTs的内部记账需要通过合约调用
        // 这里我们只能验证xPNTs的转账，aPNTs的扣除需要真实的EntryPoint调用
        console.log("    [2] Operator aPNTs accounting: SKIPPED (needs EntryPoint)");

        // 5. 记录交易后余额
        console.log("\n5.5 Recording balances after transaction...");

        uint256 userXPNTsAfter = operatorXPNTs.balanceOf(user);
        uint256 treasuryXPNTsAfter = operatorXPNTs.balanceOf(operatorTreasury);

        console.log("    [AFTER]");
        console.log("      User xPNTs:");
        console.log(userXPNTsAfter / 1e18, "xTEST");
        console.log("      Operator treasury xPNTs:");
        console.log(treasuryXPNTsAfter / 1e18, "xTEST");
        console.log("      xPNTs transferred:", (treasuryXPNTsAfter - treasuryXPNTsBefore) / 1e18, "xTEST");

        // 6. 验证
        console.log("\n5.6 Verifying payment...");
        require(userXPNTsAfter == userXPNTsBefore - xPNTsCost, "User xPNTs mismatch");
        require(treasuryXPNTsAfter == treasuryXPNTsBefore + xPNTsCost, "Treasury xPNTs mismatch");

        console.log("\n[SUCCESS] Step 5 completed!");
        console.log("\nNote:");
        console.log("- User payment verified (xPNTs transferred)");
        console.log("- Full dual payment requires EntryPoint integration");
        console.log("- See Step 6 for final verification");
    }
}
