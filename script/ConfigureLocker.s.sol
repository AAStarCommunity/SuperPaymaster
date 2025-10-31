// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/paymasters/v2/core/GTokenStaking.sol";

/**
 * @title ConfigureLocker
 * @notice 配置 SuperPaymasterV2 为 GTokenStaking 的授权 locker
 *
 * 使用方法:
 * forge script script/ConfigureLocker.s.sol:ConfigureLocker \
 *   --rpc-url $SEPOLIA_RPC_URL \
 *   --private-key $OWNER_PRIVATE_KEY \
 *   --broadcast
 */
contract ConfigureLocker is Script {
    // Sepolia 部署的合约地址
    address constant GTOKEN_STAKING = 0x1D75C42e8A72D83207e9a0dF940B0Fa43d63CBc5;
    address constant SUPERPAYMASTER_V2 = 0xe25b068d4239C6dAc484B8c51d62cC86F44859A7;

    // Locker 配置参数
    bool constant AUTHORIZED = true;
    uint256 constant FEE_RATE_BPS = 100;       // 1% 基础费率 (100 bps)
    uint256 constant MIN_EXIT_FEE = 0.01 ether; // 最低退出费用 0.01 GT
    uint256 constant MAX_FEE_PERCENT = 500;     // 最高 5% (500 bps)

    // 时间层级配置 (秒)
    uint256[] timeTiers;
    uint256[] tierFees;

    // 费用接收者（通常是 treasury 或 owner）
    address constant FEE_RECIPIENT = 0x411BD567E46C0781248dbB6a9211891C032885e5; // Deployer address

    function setUp() public {
        // 配置时间层级: [90天, 180天, 365天]
        timeTiers = new uint256[](3);
        timeTiers[0] = 90 days;
        timeTiers[1] = 180 days;
        timeTiers[2] = 365 days;

        // 配置层级费率 (basis points): [<90天, 90-180天, 180-365天, ≥365天]
        tierFees = new uint256[](4);
        tierFees[0] = 150;  // < 90天: 1.5%
        tierFees[1] = 100;  // 90-180天: 1%
        tierFees[2] = 70;   // 180-365天: 0.7%
        tierFees[3] = 50;   // ≥365天: 0.5% (最低)
    }

    function run() external {
        console.log("================================================");
        console.log("   Configuring SuperPaymasterV2 as Locker");
        console.log("================================================");

        console.log("\nContract Addresses:");
        console.log("  GTokenStaking:", GTOKEN_STAKING);
        console.log("  SuperPaymasterV2:", SUPERPAYMASTER_V2);
        console.log("  Fee Recipient:", FEE_RECIPIENT);

        console.log("\nLocker Configuration:");
        console.log("  Authorized:", AUTHORIZED);
        console.log("  Base Fee Rate (bps):", FEE_RATE_BPS);
        console.log("  Min Exit Fee (GT):", MIN_EXIT_FEE / 1e18);
        console.log("  Max Fee Percent (bps):", MAX_FEE_PERCENT);
        console.log("\nTime Tiers:");
        console.log("  Tier 1 (days):", timeTiers[0] / 1 days);
        console.log("  Tier 1 Fee (bps):", tierFees[0]);
        console.log("  Tier 2 (days):", timeTiers[1] / 1 days);
        console.log("  Tier 2 Fee (bps):", tierFees[1]);
        console.log("  Tier 3 (days):", timeTiers[2] / 1 days);
        console.log("  Tier 3 Fee (bps):", tierFees[2]);
        console.log("  Tier 4 Fee (bps):", tierFees[3]);

        // 开始广播交易
        vm.startBroadcast();

        GTokenStaking gTokenStaking = GTokenStaking(GTOKEN_STAKING);

        console.log("\nCalling configureLocker...");
        gTokenStaking.configureLocker(
            SUPERPAYMASTER_V2,
            AUTHORIZED,
            FEE_RATE_BPS,
            MIN_EXIT_FEE,
            MAX_FEE_PERCENT,
            timeTiers,
            tierFees,
            FEE_RECIPIENT
        );

        vm.stopBroadcast();

        console.log("\n================================================");
        console.log("   Configuration Complete!");
        console.log("================================================");
        console.log("\nSuperPaymasterV2 is now authorized as a locker");
        console.log("Users can now lock stGTokens via SuperPaymasterV2");

        // 验证配置
        console.log("\nVerifying configuration...");
        GTokenStaking.LockerConfig memory config = gTokenStaking.getLockerConfig(SUPERPAYMASTER_V2);

        console.log("  Authorized:", config.authorized);
        console.log("  Fee Rate (bps):", config.feeRateBps);
        console.log("  Min Exit Fee (GT):", config.minExitFee / 1e18);
        console.log("  Max Fee Percent (bps):", config.maxFeePercent);
        console.log("  Fee Recipient:", config.feeRecipient);

        require(config.authorized == AUTHORIZED, "Authorization mismatch");
        require(config.feeRateBps == FEE_RATE_BPS, "Fee rate mismatch");
        require(config.minExitFee == MIN_EXIT_FEE, "Min exit fee mismatch");
        require(config.maxFeePercent == MAX_FEE_PERCENT, "Max fee percent mismatch");
        require(config.feeRecipient == FEE_RECIPIENT, "Fee recipient mismatch");

        console.log("\nVerification passed!");
    }
}
