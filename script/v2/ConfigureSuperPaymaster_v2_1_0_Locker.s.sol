// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/v2/core/GTokenStaking.sol";

/**
 * @title ConfigureSuperPaymaster_v2_1_0_Locker
 * @notice Configure SuperPaymaster v2.1.0 as authorized locker in GTokenStaking
 *
 * @dev Usage:
 *   source .env
 *   forge script script/v2/ConfigureSuperPaymaster_v2_1_0_Locker.s.sol:ConfigureSuperPaymaster_v2_1_0_Locker \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --broadcast \
 *     -vvvv
 */
contract ConfigureSuperPaymaster_v2_1_0_Locker is Script {
    // Locker configuration parameters
    bool constant AUTHORIZED = true;
    uint256 constant FEE_RATE_BPS = 0;          // 0% base fee for SuperPaymaster
    uint256 constant MIN_EXIT_FEE = 0;          // No minimum exit fee
    uint256 constant MAX_FEE_PERCENT = 0;       // No max fee

    function run() external {
        address gtokenStaking = vm.envOr("GTOKEN_STAKING", 0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0);
        address superPaymasterV210 = vm.envAddress("SUPERPAYMASTER_V2_1_0");  // Must be set after deployment
        address feeRecipient = vm.envAddress("DEPLOYER_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        console.log("========================================================");
        console.log("   Configuring SuperPaymaster v2.1.0 as Locker");
        console.log("========================================================");

        console.log("\nContract Addresses:");
        console.log("  GTokenStaking:            ", gtokenStaking);
        console.log("  SuperPaymaster v2.1.0:    ", superPaymasterV210);
        console.log("  Fee Recipient:            ", feeRecipient);

        console.log("\nLocker Configuration:");
        console.log("  Authorized:               ", AUTHORIZED);
        console.log("  Base Fee Rate (bps):      ", FEE_RATE_BPS);
        console.log("  Min Exit Fee (GT):        ", MIN_EXIT_FEE);
        console.log("  Max Fee Percent (bps):    ", MAX_FEE_PERCENT);

        // Start broadcasting transactions
        vm.startBroadcast(deployerPrivateKey);

        GTokenStaking gTokenStaking = GTokenStaking(gtokenStaking);

        console.log("\nCalling configureLocker...");
        gTokenStaking.configureLocker(
            superPaymasterV210,
            AUTHORIZED,
            FEE_RATE_BPS,
            MIN_EXIT_FEE,
            MAX_FEE_PERCENT,
            new uint256[](0),  // No time tiers for SuperPaymaster
            new uint256[](0),  // No tier fees for SuperPaymaster
            feeRecipient
        );

        vm.stopBroadcast();

        console.log("\n========================================================");
        console.log("   Configuration Complete!");
        console.log("========================================================");
        console.log("\nSuperPaymaster v2.1.0 is now authorized as a locker");
        console.log("Operators can now use registerOperatorWithAutoStake()");

        // Verify configuration
        console.log("\nVerifying configuration...");
        GTokenStaking.LockerConfig memory config = gTokenStaking.getLockerConfig(superPaymasterV210);

        console.log("  Authorized:               ", config.authorized);
        console.log("  Fee Rate (bps):           ", config.feeRateBps);
        console.log("  Min Exit Fee (GT):        ", config.minExitFee);
        console.log("  Max Fee Percent (bps):    ", config.maxFeePercent);
        console.log("  Fee Recipient:            ", config.feeRecipient);

        require(config.authorized == AUTHORIZED, "Authorization mismatch");
        require(config.feeRateBps == FEE_RATE_BPS, "Fee rate mismatch");
        require(config.minExitFee == MIN_EXIT_FEE, "Min exit fee mismatch");
        require(config.maxFeePercent == MAX_FEE_PERCENT, "Max fee percent mismatch");
        require(config.feeRecipient == feeRecipient, "Fee recipient mismatch");

        console.log("\nVerification passed!");
        console.log("");
        console.log("Next Steps:");
        console.log("1. Update shared-config with new addresses and ABIs");
        console.log("2. Test registerOperatorWithAutoStake() function");
        console.log("3. Update frontend to use new contracts");
    }
}
