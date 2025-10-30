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
    uint256 constant BASE_EXIT_FEE = 5 ether;  // 5 个 stGToken 基础退出费用

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

        // 配置层级费用: [<90天, 90-180天, 180-365天, ≥365天]
        tierFees = new uint256[](4);
        tierFees[0] = 15 ether;  // < 90天: 15 stGToken
        tierFees[1] = 10 ether;  // 90-180天: 10 stGToken
        tierFees[2] = 7 ether;   // 180-365天: 7 stGToken
        tierFees[3] = 5 ether;   // ≥365天: 5 stGToken (最低)
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
        console.log("  Base Exit Fee (stGToken):", BASE_EXIT_FEE / 1e18);
        console.log("\nTime Tiers:");
        console.log("  Tier 1 (days):", timeTiers[0] / 1 days);
        console.log("  Tier 1 Fee (stGToken):", tierFees[0] / 1e18);
        console.log("  Tier 2 (days):", timeTiers[1] / 1 days);
        console.log("  Tier 2 Fee (stGToken):", tierFees[1] / 1e18);
        console.log("  Tier 3 (days):", timeTiers[2] / 1 days);
        console.log("  Tier 3 Fee (stGToken):", tierFees[2] / 1e18);
        console.log("  Tier 4 Fee (stGToken):", tierFees[3] / 1e18);

        // 开始广播交易
        vm.startBroadcast();

        GTokenStaking gTokenStaking = GTokenStaking(GTOKEN_STAKING);

        console.log("\nCalling configureLocker...");
        gTokenStaking.configureLocker(
            SUPERPAYMASTER_V2,
            AUTHORIZED,
            BASE_EXIT_FEE,
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
        console.log("  Base Exit Fee (stGToken):", config.baseExitFee / 1e18);
        console.log("  Fee Recipient:", config.feeRecipient);

        require(config.authorized == AUTHORIZED, "Authorization mismatch");
        require(config.baseExitFee == BASE_EXIT_FEE, "Base exit fee mismatch");
        require(config.feeRecipient == FEE_RECIPIENT, "Fee recipient mismatch");

        console.log("\nVerification passed!");
    }
}
