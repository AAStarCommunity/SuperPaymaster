// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/v2/core/GTokenStaking.sol";
import "src/paymasters/v2/core/Registry.sol";
import "src/paymasters/v2/core/SuperPaymasterV2.sol";
import "src/paymasters/v2/tokens/MySBT_v2.4.0.sol";
import "src/paymasters/v2/tokens/xPNTsFactory.sol";
import "src/paymasters/v2/monitoring/DVTValidator.sol";
import "src/paymasters/v2/monitoring/BLSAggregator.sol";

/**
 * @title DeployAllV2WithVersion
 * @notice Deploy all V2 contracts with VERSION interfaces
 */
contract DeployAllV2WithVersion is Script {

    address constant GTOKEN = 0x868F843723a98c6EECC4BF0aF3352C53d5004147;
    address constant GTOKEN_STAKING = 0x7b0bb7D5a5bf7A5839A6e6B53bDD639865507A69;
    address constant ENTRYPOINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant ETH_USD_PRICE_FEED = 0x694AA1769357215DE4FAC081bf1f309aDC325306; // Chainlink Sepolia ETH/USD
    
    function run() external {
        console.log("=== Deploying All V2 Contracts with VERSION ===");
        console.log("");

        vm.startBroadcast();

        // ====== Phase 2: Registry ======
        console.log("Phase 2: Deploying Registry v2.1.3...");
        Registry registry = new Registry(GTOKEN_STAKING);
        console.log("  Registry:", address(registry));
        console.log("  VERSION:", registry.VERSION());
        console.log("");

        // ====== Phase 3: SuperPaymasterV2 ======
        console.log("Phase 3: Deploying SuperPaymasterV2 v2.0.0...");
        SuperPaymasterV2 superPaymaster = new SuperPaymasterV2(
            GTOKEN_STAKING,
            address(registry),
            ETH_USD_PRICE_FEED
        );
        console.log("  SuperPaymasterV2:", address(superPaymaster));
        console.log("  VERSION:", superPaymaster.VERSION());

        // Configure EntryPoint
        superPaymaster.setEntryPoint(ENTRYPOINT_V07);
        console.log("  EntryPoint configured:", ENTRYPOINT_V07);
        console.log("");

        // ====== Phase 4: MySBT ======
        console.log("Phase 4: Deploying MySBT v2.4.0...");
        MySBT_v2_4_0 mySBT = new MySBT_v2_4_0(
            GTOKEN,
            GTOKEN_STAKING,
            address(registry),
            msg.sender       // DAO address
        );
        console.log("  MySBT:", address(mySBT));
        console.log("  VERSION:", mySBT.VERSION());
        console.log("");

        // ====== Phase 5: xPNTsFactory ======
        console.log("Phase 5: Deploying xPNTsFactory v2.0.0...");
        xPNTsFactory factory = new xPNTsFactory(
            address(superPaymaster),
            address(registry)
        );
        console.log("  xPNTsFactory:", address(factory));
        console.log("  VERSION:", factory.VERSION());
        console.log("");

        // ====== Phase 6: DVT/BLS ======
        console.log("Phase 6: Deploying DVT/BLS Monitoring...");
        DVTValidator dvtValidator = new DVTValidator(
            address(superPaymaster)
        );
        console.log("  DVTValidator:", address(dvtValidator));
        console.log("  VERSION:", dvtValidator.VERSION());
        
        BLSAggregator blsAggregator = new BLSAggregator(
            address(superPaymaster),
            address(dvtValidator)
        );
        console.log("  BLSAggregator:", address(blsAggregator));
        console.log("  VERSION:", blsAggregator.VERSION());

        // Configure cross references
        dvtValidator.setBLSAggregator(address(blsAggregator));
        superPaymaster.setDVTAggregator(address(blsAggregator));
        console.log("  DVT/BLS cross-configured");
        console.log("");

        // ====== Configure GTokenStaking lockers ======
        console.log("Configuring GTokenStaking lockers...");
        GTokenStaking staking = GTokenStaking(GTOKEN_STAKING);

        // MySBT locker: 1% fee, 0.01 GT min exit fee
        staking.configureLocker(
            address(mySBT),
            true,                // authorized
            100,                 // feeRateBps (1%)
            0.01 ether,          // minExitFee
            500,                 // maxFeePercent (5%)
            new uint256[](0),    // timeTiers (no time-based tiers)
            new uint256[](0),    // tierFees (no tier fees)
            address(0)           // feeRecipient (use default treasury)
        );
        console.log("  MySBT locker configured");

        // SuperPaymaster locker: time-based percentage fees
        uint256[] memory timeTiers = new uint256[](4);
        timeTiers[0] = 7 days;      // 1 week
        timeTiers[1] = 30 days;     // 1 month
        timeTiers[2] = 90 days;     // 3 months
        timeTiers[3] = 180 days;    // 6 months

        uint256[] memory tierFees = new uint256[](5);  // length = timeTiers.length + 1
        tierFees[0] = 500;          // 5% for < 7 days
        tierFees[1] = 400;          // 4% for 7-30 days
        tierFees[2] = 300;          // 3% for 30-90 days
        tierFees[3] = 200;          // 2% for 90-180 days
        tierFees[4] = 100;          // 1% for > 180 days

        staking.configureLocker(
            address(superPaymaster),
            true,                // authorized
            100,                 // feeRateBps (1% base)
            0.01 ether,          // minExitFee
            500,                 // maxFeePercent (5%)
            timeTiers,
            tierFees,
            address(0)           // feeRecipient (use default treasury)
        );
        console.log("  SuperPaymaster locker configured");
        console.log("");

        vm.stopBroadcast();

        // ====== Deployment Summary ======
        console.log("====================================");
        console.log("DEPLOYMENT SUMMARY");
        console.log("====================================");
        console.log("");
        console.log("Core System:");
        console.log("  GTokenStaking v2.0.0:", GTOKEN_STAKING);
        console.log("  Registry v2.1.3:", address(registry));
        console.log("  SuperPaymasterV2 v2.0.0:", address(superPaymaster));
        console.log("");
        console.log("Token System:");
        console.log("  MySBT v2.4.0:", address(mySBT));
        console.log("  xPNTsFactory v2.0.0:", address(factory));
        console.log("");
        console.log("Monitoring:");
        console.log("  DVTValidator v2.0.0:", address(dvtValidator));
        console.log("  BLSAggregator v2.0.0:", address(blsAggregator));
        console.log("");
        console.log("Next Steps:");
        console.log("1. Deploy aPNTs through xPNTsFactory");
        console.log("2. Update shared-config with all new addresses");
        console.log("3. Run integration tests");
        console.log("====================================");
    }
}
