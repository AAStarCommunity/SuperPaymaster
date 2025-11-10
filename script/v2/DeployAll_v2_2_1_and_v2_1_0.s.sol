// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/v2/core/Registry.sol";
import "src/paymasters/v2/core/SuperPaymasterV2.sol";
import "src/paymasters/v2/core/GTokenStaking.sol";

/**
 * @title DeployAll_v2_2_1_and_v2_1_0
 * @notice Deploy Registry v2.2.1 + SuperPaymaster V2.1.0 with full configuration
 *
 * @dev Deployment Order:
 *   1. Deploy Registry v2.2.1 (duplicate prevention)
 *   2. Configure Registry as authorized locker in GTokenStaking
 *   3. Deploy SuperPaymaster V2.1.0 (auto-stake registration)
 *   4. Configure SuperPaymaster (EntryPoint + aPNTs + Treasury)
 *   5. Configure SuperPaymaster as authorized locker in GTokenStaking
 *
 * @dev Required Environment Variables:
 *   - GTOKEN: GToken ERC20 contract address
 *   - GTOKEN_STAKING: GTokenStaking contract address
 *   - ETH_USD_PRICE_FEED: Chainlink ETH/USD price feed address
 *   - ENTRYPOINT_V07: EntryPoint v0.7 address
 *   - APNTS_TOKEN: aPNTs token address
 *   - SUPERPAYMASTER_TREASURY: Treasury address
 *   - DEPLOYER_ADDRESS: Deployer/owner address
 *   - PRIVATE_KEY: Deployer private key
 *
 * @dev Usage:
 *   source .env
 *   forge script script/v2/DeployAll_v2_2_1_and_v2_1_0.s.sol:DeployAll_v2_2_1_and_v2_1_0 \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     --etherscan-api-key $ETHERSCAN_API_KEY \
 *     -vvvv
 */
contract DeployAll_v2_2_1_and_v2_1_0 is Script {
    // Locker configuration (same for both Registry and SuperPaymaster)
    bool constant AUTHORIZED = true;
    uint256 constant FEE_RATE_BPS = 0;
    uint256 constant MIN_EXIT_FEE = 0;
    uint256 constant MAX_FEE_PERCENT = 0;

    function run() external {
        // Load addresses
        address gtoken = vm.envOr("GTOKEN", 0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc);
        address gtokenStaking = vm.envOr("GTOKEN_STAKING", 0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0);
        address ethUsdPriceFeed = vm.envOr("ETH_USD_PRICE_FEED", 0x694AA1769357215DE4FAC081bf1f309aDC325306);
        address entrypointV07 = vm.envOr("ENTRYPOINT_V07", 0x0000000071727De22E5E9d8BAf0edAc6f37da032);
        address apntsToken = vm.envOr("APNTS_TOKEN", 0xBD0710596010a157B88cd141d797E8Ad4bb2306b);
        address treasury = vm.envAddress("SUPERPAYMASTER_TREASURY");
        address feeRecipient = vm.envAddress("DEPLOYER_ADDRESS");
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("====================================================================================");
        console.log("=== Deploy Registry v2.2.1 + SuperPaymaster V2.1.0 (Full Configuration) ===");
        console.log("====================================================================================");
        console.log("Deployer:                 ", deployer);
        console.log("GToken:                   ", gtoken);
        console.log("GTokenStaking:            ", gtokenStaking);
        console.log("ETH/USD Price Feed:       ", ethUsdPriceFeed);
        console.log("EntryPoint v0.7:          ", entrypointV07);
        console.log("aPNTs Token:              ", apntsToken);
        console.log("Treasury:                 ", treasury);
        console.log("Fee Recipient:            ", feeRecipient);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // ============================================================
        // STEP 1: Deploy Registry v2.2.1
        // ============================================================
        console.log("====================================================================================");
        console.log("=== STEP 1: Deploy Registry v2.2.1 ===");
        console.log("====================================================================================");

        Registry registry = new Registry(gtoken, gtokenStaking);

        console.log("Registry v2.2.1 deployed:   ", address(registry));
        console.log("VERSION:                     ", registry.VERSION());
        console.log("VERSION_CODE:                ", registry.VERSION_CODE());
        console.log("");

        // ============================================================
        // STEP 2: Configure Registry as Locker
        // ============================================================
        console.log("====================================================================================");
        console.log("=== STEP 2: Configure Registry as Authorized Locker ===");
        console.log("====================================================================================");

        GTokenStaking gts = GTokenStaking(gtokenStaking);
        gts.configureLocker(
            address(registry),
            AUTHORIZED,
            FEE_RATE_BPS,
            MIN_EXIT_FEE,
            MAX_FEE_PERCENT,
            new uint256[](0),
            new uint256[](0),
            feeRecipient
        );

        console.log("Registry configured as locker!");
        console.log("");

        // ============================================================
        // STEP 3: Deploy SuperPaymaster V2.1.0
        // ============================================================
        console.log("====================================================================================");
        console.log("=== STEP 3: Deploy SuperPaymaster V2.1.0 ===");
        console.log("====================================================================================");

        SuperPaymasterV2 superPaymaster = new SuperPaymasterV2(
            gtoken,
            gtokenStaking,
            address(registry),
            ethUsdPriceFeed
        );

        console.log("SuperPaymaster V2.1.0 deployed:", address(superPaymaster));
        console.log("VERSION:                        ", superPaymaster.VERSION());
        console.log("VERSION_CODE:                   ", superPaymaster.VERSION_CODE());
        console.log("");

        // ============================================================
        // STEP 4: Configure SuperPaymaster
        // ============================================================
        console.log("====================================================================================");
        console.log("=== STEP 4: Configure SuperPaymaster (EntryPoint + aPNTs + Treasury) ===");
        console.log("====================================================================================");

        superPaymaster.setEntryPoint(entrypointV07);
        console.log("EntryPoint configured:          ", entrypointV07);

        superPaymaster.setAPNTsToken(apntsToken);
        console.log("aPNTs token configured:         ", apntsToken);

        superPaymaster.setSuperPaymasterTreasury(treasury);
        console.log("Treasury configured:            ", treasury);
        console.log("");

        // ============================================================
        // STEP 5: Configure SuperPaymaster as Locker
        // ============================================================
        console.log("====================================================================================");
        console.log("=== STEP 5: Configure SuperPaymaster as Authorized Locker ===");
        console.log("====================================================================================");

        gts.configureLocker(
            address(superPaymaster),
            AUTHORIZED,
            FEE_RATE_BPS,
            MIN_EXIT_FEE,
            MAX_FEE_PERCENT,
            new uint256[](0),
            new uint256[](0),
            feeRecipient
        );

        console.log("SuperPaymaster configured as locker!");
        console.log("");

        vm.stopBroadcast();

        // ============================================================
        // Verification
        // ============================================================
        console.log("====================================================================================");
        console.log("=== Deployment & Configuration Verification ===");
        console.log("====================================================================================");

        console.log("\n--- Registry v2.2.1 ---");
        console.log("Address:                      ", address(registry));
        console.log("GTOKEN:                       ", address(registry.GTOKEN()));
        console.log("GTOKEN_STAKING:               ", address(registry.GTOKEN_STAKING()));
        console.log("Owner:                        ", registry.owner());
        console.log("Community Count:              ", registry.getCommunityCount());

        GTokenStaking.LockerConfig memory registryConfig = gts.getLockerConfig(address(registry));
        console.log("Authorized as Locker:         ", registryConfig.authorized);

        console.log("\n--- SuperPaymaster V2.1.0 ---");
        console.log("Address:                      ", address(superPaymaster));
        console.log("GTOKEN:                       ", superPaymaster.GTOKEN());
        console.log("GTOKEN_STAKING:               ", superPaymaster.GTOKEN_STAKING());
        console.log("REGISTRY:                     ", superPaymaster.REGISTRY());
        console.log("ENTRY_POINT:                  ", superPaymaster.ENTRY_POINT());
        console.log("aPNTsToken:                   ", superPaymaster.aPNTsToken());
        console.log("superPaymasterTreasury:       ", superPaymaster.superPaymasterTreasury());
        console.log("Owner:                        ", superPaymaster.owner());
        console.log("MinOperatorStake:             ", superPaymaster.minOperatorStake() / 1e18, "GT");
        console.log("MinAPNTsBalance:              ", superPaymaster.minAPNTsBalance() / 1e18, "aPNTs");

        GTokenStaking.LockerConfig memory superPaymasterConfig = gts.getLockerConfig(address(superPaymaster));
        console.log("Authorized as Locker:         ", superPaymasterConfig.authorized);

        // Final checks
        require(registryConfig.authorized, "Registry not authorized");
        require(superPaymasterConfig.authorized, "SuperPaymaster not authorized");
        require(superPaymaster.ENTRY_POINT() == entrypointV07, "EntryPoint mismatch");
        require(superPaymaster.aPNTsToken() == apntsToken, "aPNTs token mismatch");
        require(superPaymaster.superPaymasterTreasury() == treasury, "Treasury mismatch");

        console.log("");
        console.log("====================================================================================");
        console.log("=== ALL DEPLOYMENT & CONFIGURATION COMPLETE! ===");
        console.log("====================================================================================");
        console.log("");
        console.log("Deployed Contracts:");
        console.log("  Registry v2.2.1:            ", address(registry));
        console.log("  SuperPaymaster V2.1.0:      ", address(superPaymaster));
        console.log("");
        console.log("Update .env file with:");
        console.log("  REGISTRY_V2_2_1=", vm.toString(address(registry)));
        console.log("  SUPERPAYMASTER_V2_1_0=", vm.toString(address(superPaymaster)));
        console.log("");
        console.log("Next Steps:");
        console.log("1. Update shared-config package with new addresses and ABIs");
        console.log("2. Publish new shared-config version");
        console.log("3. Update frontend to use new contracts");
        console.log("4. Test registerCommunityWithAutoStake() (AOA mode)");
        console.log("5. Test registerOperatorWithAutoStake() (AOA+ mode)");
        console.log("");
    }
}
