// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/v2/core/Registry_v2_2_0.sol";

/**
 * @title DeployRegistry_v2_2_1
 * @notice Deploy Registry v2.2.1 with isRegistered mapping (duplicate prevention)
 *
 * @dev Changes in v2.2.1:
 *   - Added isRegistered mapping to prevent duplicate entries in communityList
 *   - Fixed getCommunityStatus shadowing warning
 *
 * @dev Required Environment Variables:
 *   - GTOKEN: GToken ERC20 contract address
 *   - GTOKEN_STAKING: GTokenStaking contract address
 *   - PRIVATE_KEY: Deployer private key
 *
 * @dev Usage:
 *   source .env
 *   forge script script/v2/DeployRegistry_v2_2_1.s.sol:DeployRegistry_v2_2_1 \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --broadcast \
 *     --verify \
 *     --etherscan-api-key $ETHERSCAN_API_KEY \
 *     -vvvv
 */
contract DeployRegistry_v2_2_1 is Script {
    function run() external {
        // Load from shared-config addresses (latest deployed)
        address gtoken = vm.envOr("GTOKEN", 0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc);
        address gtokenStaking = vm.envOr("GTOKEN_STAKING", 0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0);
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("================================================================================");
        console.log("=== Deploying Registry v2.2.1 (Duplicate Prevention) ===");
        console.log("================================================================================");
        console.log("Deployer:       ", deployer);
        console.log("GToken:         ", gtoken);
        console.log("GTokenStaking:  ", gtokenStaking);
        console.log("");

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Registry v2.2.1
        Registry registry = new Registry(gtoken, gtokenStaking);

        console.log("Registry v2.2.1 deployed:", address(registry));
        console.log("VERSION:                 ", registry.VERSION());
        console.log("VERSION_CODE:            ", registry.VERSION_CODE());
        console.log("");

        // Verify deployment
        console.log("=== Verification ===");
        console.log("GTOKEN:                  ", address(registry.GTOKEN()));
        console.log("GTOKEN_STAKING:          ", address(registry.GTOKEN_STAKING()));
        console.log("Owner:                   ", registry.owner());
        console.log("Community Count:         ", registry.getCommunityCount());

        vm.stopBroadcast();

        console.log("");
        console.log("================================================================================");
        console.log("=== Deployment Complete! ===");
        console.log("================================================================================");
        console.log("");
        console.log("Registry v2.2.1 Address:", address(registry));
        console.log("");
        console.log("Next Steps:");
        console.log("1. Configure Registry as authorized locker in GTokenStaking");
        console.log("   forge script script/v2/ConfigureRegistry_v2_2_1_Locker.s.sol --broadcast");
        console.log("");
        console.log("2. Update .env file with new Registry address");
        console.log("   REGISTRY_V2_2_1=", vm.toString(address(registry)));
        console.log("");
        console.log("3. Update shared-config with new Registry address");
        console.log("");
    }
}
