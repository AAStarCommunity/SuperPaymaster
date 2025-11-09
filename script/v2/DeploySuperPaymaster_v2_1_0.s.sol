// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/v2/core/SuperPaymasterV2.sol";

/**
 * @title DeploySuperPaymaster_v2_1_0
 * @notice Deploy SuperPaymasterV2 v2.1.0 with registerOperatorWithAutoStake
 *
 * @dev Updates in v2.1.0:
 *   - Added GTOKEN immutable storage
 *   - Added registerOperatorWithAutoStake() (one-step registration)
 *   - Reduces operator registration from 5-6 signatures to 1
 *
 * @dev Required Environment Variables:
 *   - GTOKEN: GToken ERC20 contract address
 *   - GTOKEN_STAKING: GTokenStaking contract address
 *   - REGISTRY_V2_2_1: Registry v2.2.1 contract address (must deploy Registry first)
 *   - ETH_USD_PRICE_FEED: Chainlink ETH/USD price feed address
 *   - PRIVATE_KEY: Deployer private key
 *
 * @dev Usage:
 *   source .env
 *   forge script script/v2/DeploySuperPaymaster_v2_1_0.s.sol:DeploySuperPaymaster_v2_1_0 \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     --etherscan-api-key $ETHERSCAN_API_KEY \
 *     -vvvv
 */
contract DeploySuperPaymaster_v2_1_0 is Script {
    function run() external {
        // Load addresses
        address gtoken = vm.envOr("GTOKEN", 0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc);
        address gtokenStaking = vm.envOr("GTOKEN_STAKING", 0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0);
        address registryV221 = vm.envAddress("REGISTRY_V2_2_1");  // Must be deployed first
        address ethUsdPriceFeed = vm.envOr("ETH_USD_PRICE_FEED", 0x694AA1769357215DE4FAC081bf1f309aDC325306);
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("================================================================================");
        console.log("=== Deploying SuperPaymasterV2 v2.1.0 (Auto-Stake Registration) ===");
        console.log("================================================================================");
        console.log("Deployer:           ", deployer);
        console.log("GToken:             ", gtoken);
        console.log("GTokenStaking:      ", gtokenStaking);
        console.log("Registry v2.2.1:    ", registryV221);
        console.log("ETH/USD Price Feed: ", ethUsdPriceFeed);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy SuperPaymasterV2 v2.1.0
        SuperPaymasterV2 superPaymaster = new SuperPaymasterV2(
            gtoken,
            gtokenStaking,
            registryV221,
            ethUsdPriceFeed
        );

        console.log("SuperPaymasterV2 v2.1.0 deployed:", address(superPaymaster));
        console.log("VERSION:                         ", superPaymaster.VERSION());
        console.log("VERSION_CODE:                    ", superPaymaster.VERSION_CODE());
        console.log("");

        // Verify deployment
        console.log("=== Verification ===");
        console.log("GTOKEN:              ", superPaymaster.GTOKEN());
        console.log("GTOKEN_STAKING:      ", superPaymaster.GTOKEN_STAKING());
        console.log("REGISTRY:            ", superPaymaster.REGISTRY());
        console.log("ethUsdPriceFeed:     ", address(superPaymaster.ethUsdPriceFeed()));
        console.log("Owner:               ", superPaymaster.owner());
        console.log("MinOperatorStake:    ", superPaymaster.minOperatorStake() / 1e18, "GT");
        console.log("MinAPNTsBalance:     ", superPaymaster.minAPNTsBalance() / 1e18, "aPNTs");

        vm.stopBroadcast();

        console.log("");
        console.log("================================================================================");
        console.log("=== Deployment Complete! ===");
        console.log("================================================================================");
        console.log("");
        console.log("SuperPaymasterV2 v2.1.0 Address:", address(superPaymaster));
        console.log("");
        console.log("Next Steps:");
        console.log("1. Configure SuperPaymaster (EntryPoint + aPNTs + Treasury)");
        console.log("   forge script script/v2/ConfigureSuperPaymaster_v2_1_0.s.sol --broadcast");
        console.log("");
        console.log("2. Configure SuperPaymaster as authorized locker in GTokenStaking");
        console.log("   forge script script/v2/ConfigureSuperPaymaster_v2_1_0_Locker.s.sol --broadcast");
        console.log("");
        console.log("3. Update .env file with new SuperPaymaster address");
        console.log("   SUPERPAYMASTER_V2_1_0=", vm.toString(address(superPaymaster)));
        console.log("");
        console.log("4. Update shared-config with new SuperPaymaster address and ABI");
        console.log("");
    }
}
