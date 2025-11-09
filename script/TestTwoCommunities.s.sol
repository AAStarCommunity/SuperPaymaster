// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "src/paymasters/v2/core/GToken.sol";
import "src/paymasters/v2/core/GTokenStaking.sol";
import "src/paymasters/v2/core/Registry_v2_2_0.sol";

/**
 * @title TestTwoCommunities
 * @notice Test script to mint GToken and register two communities
 *
 * Steps:
 * 1. Mint GToken to two test accounts
 * 2. Approve GToken to GTokenStaking
 * 3. Register two communities using registerCommunityWithAutoStake
 *
 * Usage:
 *   forge script script/TestTwoCommunities.s.sol:TestTwoCommunities \
 *     --rpc-url $SEPOLIA_RPC_URL \
 *     --broadcast \
 *     -vvv
 */
contract TestTwoCommunities is Script {
    // Sepolia addresses
    address constant GTOKEN = 0x99cCb70646Be7A5aeE7aF98cE853a1EA1A676DCc;
    address constant GTOKEN_STAKING = 0xbEbF9b4c6a4cDB92Ac184aF211AdB13a0b9BF6c0;
    address constant REGISTRY = 0x028aB52B4E0EF26820043ca4F1B5Fe14FfC1EF75;

    function run() external {
        // Load private keys
        uint256 deployer1PK = vm.envUint("PRIVATE_KEY");
        uint256 deployer2PK = vm.envUint("OWNER2_PRIVATE_KEY");

        address account1 = vm.addr(deployer1PK);
        address account2 = vm.addr(deployer2PK);

        console.log("================================================================================");
        console.log("=== Test: Register Two Communities ===");
        console.log("================================================================================");
        console.log("Account 1:", account1);
        console.log("Account 2:", account2);
        console.log("");

        GToken gtoken = GToken(GTOKEN);
        GTokenStaking staking = GTokenStaking(GTOKEN_STAKING);
        Registry registry = Registry(REGISTRY);

        // ========================================
        // Step 1: Mint GToken to both accounts
        // ========================================
        console.log("Step 1: Minting GToken...");

        uint256 mintAmount = 100 ether; // 100 GT for each account

        vm.startBroadcast(deployer1PK);

        // Check if account1 needs minting
        uint256 balance1 = gtoken.balanceOf(account1);
        console.log("Account 1 GToken balance:", balance1 / 1e18, "GT");

        if (balance1 < mintAmount) {
            gtoken.mint(account1, mintAmount);
            console.log("  Minted", mintAmount / 1e18, "GT to Account 1");
        } else {
            console.log("  Account 1 already has sufficient GToken");
        }

        // Mint to account2
        uint256 balance2 = gtoken.balanceOf(account2);
        console.log("Account 2 GToken balance:", balance2 / 1e18, "GT");

        if (balance2 < mintAmount) {
            gtoken.mint(account2, mintAmount);
            console.log("  Minted", mintAmount / 1e18, "GT to Account 2");
        } else {
            console.log("  Account 2 already has sufficient GToken");
        }

        vm.stopBroadcast();
        console.log("");

        // ========================================
        // Step 2: Register Community 1 (Account 1)
        // ========================================
        console.log("Step 2: Registering Community 1 (AAstar)...");

        vm.startBroadcast(deployer1PK);

        // Check if already registered
        (bool isRegistered1, ) = registry.getCommunityStatus(account1);

        if (!isRegistered1) {
            // Approve GToken for auto-stake (approve Registry, not GTokenStaking)
            uint256 stakeAmount1 = 50 ether; // 50 GT stake
            gtoken.approve(REGISTRY, stakeAmount1);
            console.log("  Approved", stakeAmount1 / 1e18, "GT to Registry for auto-stake");

            // Create community profile
            Registry.CommunityProfile memory profile1;
            profile1.name = "AAstar Community";
            profile1.ensName = "aastar.eth";
            profile1.xPNTsToken = address(0); // Will deploy later
            profile1.supportedSBTs = new address[](0);
            profile1.nodeType = Registry.NodeType.PAYMASTER_SUPER; // SuperPaymaster mode
            profile1.paymasterAddress = address(0); // Not required for now
            profile1.community = account1;
            profile1.registeredAt = 0; // Will be set by contract
            profile1.lastUpdatedAt = 0;
            profile1.isActive = true;
            profile1.allowPermissionlessMint = true;

            // Register with auto-stake
            registry.registerCommunityWithAutoStake(profile1, stakeAmount1);

            console.log("  Community 1 registered successfully!");
            console.log("  Name: AAstar Community");
            console.log("  Stake:", stakeAmount1 / 1e18, "GT");
        } else {
            console.log("  Community 1 already registered");
        }

        vm.stopBroadcast();
        console.log("");

        // ========================================
        // Step 3: Register Community 2 (Account 2)
        // ========================================
        console.log("Step 3: Registering Community 2 (Bread)...");

        vm.startBroadcast(deployer2PK);

        // Check if already registered
        (bool isRegistered2, ) = registry.getCommunityStatus(account2);

        if (!isRegistered2) {
            // Approve GToken for auto-stake (approve Registry, not GTokenStaking)
            uint256 stakeAmount2 = 50 ether; // 50 GT stake
            gtoken.approve(REGISTRY, stakeAmount2);
            console.log("  Approved", stakeAmount2 / 1e18, "GT to Registry for auto-stake");

            // Create community profile
            Registry.CommunityProfile memory profile2;
            profile2.name = "Bread Community";
            profile2.ensName = "bread.eth";
            profile2.xPNTsToken = address(0); // Will deploy later
            profile2.supportedSBTs = new address[](0);
            profile2.nodeType = Registry.NodeType.PAYMASTER_AOA; // AOA independent mode
            profile2.paymasterAddress = address(0);
            profile2.community = account2;
            profile2.registeredAt = 0;
            profile2.lastUpdatedAt = 0;
            profile2.isActive = true;
            profile2.allowPermissionlessMint = false;

            // Register with auto-stake
            registry.registerCommunityWithAutoStake(profile2, stakeAmount2);

            console.log("  Community 2 registered successfully!");
            console.log("  Name: Bread Community");
            console.log("  Stake:", stakeAmount2 / 1e18, "GT");
        } else {
            console.log("  Community 2 already registered");
        }

        vm.stopBroadcast();
        console.log("");

        // ========================================
        // Step 4: Verify registrations
        // ========================================
        console.log("Step 4: Verifying registrations...");
        console.log("");

        // Verify Community 1
        Registry.CommunityProfile memory c1 = registry.getCommunityProfile(account1);
        console.log("Community 1 (AAstar):");
        console.log("  Name:", c1.name);
        console.log("  ENS:", c1.ensName);
        console.log("  Node Type:", uint256(c1.nodeType));
        console.log("  Is Active:", c1.isActive);
        console.log("  Registered At:", c1.registeredAt);
        console.log("");

        // Verify Community 2
        Registry.CommunityProfile memory c2 = registry.getCommunityProfile(account2);
        console.log("Community 2 (Bread):");
        console.log("  Name:", c2.name);
        console.log("  ENS:", c2.ensName);
        console.log("  Node Type:", uint256(c2.nodeType));
        console.log("  Is Active:", c2.isActive);
        console.log("  Registered At:", c2.registeredAt);
        console.log("");

        // Check total community count
        uint256 totalCommunities = registry.getCommunityCount();
        console.log("Total communities registered:", totalCommunities);
        console.log("");

        console.log("================================================================================");
        console.log("=== Test Complete! ===");
        console.log("================================================================================");
        console.log("");
        console.log("Next steps:");
        console.log("1. Deploy xPNTs tokens for each community");
        console.log("2. Update community profiles with xPNTs addresses");
        console.log("3. Deploy SBT contracts for identity verification");
        console.log("4. Test auto-stake feature with MySBT minting");
    }
}
