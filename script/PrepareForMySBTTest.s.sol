// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import "../src/paymasters/v2/core/GTokenStaking.sol";
import "../src/paymasters/v2/core/Registry.sol";

/**
 * @title PrepareForMySBTTest
 * @notice Stake GT and register community for testing
 */
contract PrepareForMySBTTest is Script {
    function run() external {
        uint256 userPrivateKey = vm.envUint("PRIVATE_KEY");
        address user = vm.addr(userPrivateKey);

        address gtokenAddress = vm.envAddress("GTOKEN");
        address gtokenStakingAddress = vm.envAddress("GTOKEN_STAKING");
        address registryAddress = vm.envAddress("REGISTRY");

        console.log("=== Prepare for MySBT Test ===");
        console.log("User:", user);
        console.log("GToken:", gtokenAddress);
        console.log("GTokenStaking:", gtokenStakingAddress);
        console.log("Registry:", registryAddress);
        console.log();

        GTokenStaking staking = GTokenStaking(gtokenStakingAddress);
        IERC20 gtoken = IERC20(gtokenAddress);
        Registry registry = Registry(registryAddress);

        // Check current balances
        uint256 gtBalance = gtoken.balanceOf(user);
        uint256 stGTBalance = staking.balanceOf(user);

        console.log("Current GT balance:", gtBalance);
        console.log("Current stGT balance:", stGTBalance);
        console.log();

        // Need: 30 stGT (community) + 0.3 stGT (SBT) = 30.3 stGT
        uint256 requiredStake = 31 ether; // Stake 31 GT for safety

        if (stGTBalance < 30.3 ether) {
            console.log("=== Step 1: Stake GT ===");
            console.log("Staking", requiredStake, "GT...");

            vm.startBroadcast(userPrivateKey);

            // Approve and stake
            gtoken.approve(gtokenStakingAddress, requiredStake);
            staking.stake(requiredStake);

            vm.stopBroadcast();

            console.log("[OK] Staked", requiredStake, "GT");
            stGTBalance = staking.balanceOf(user);
            console.log("New stGT balance:", stGTBalance);
            console.log();
        } else {
            console.log("[SKIP] Already have enough stGT");
            console.log();
        }

        // Check if already registered
        bool isRegistered = registry.isRegisteredCommunity(user);

        if (!isRegistered) {
            console.log("=== Step 2: Register Community ===");

            address[] memory emptySBTs = new address[](0);

            Registry.CommunityProfile memory profile = Registry.CommunityProfile({
                name: "Test Community",
                ensName: "",
                description: "Test community for MySBT testing",
                website: "https://example.com",
                logoURI: "https://example.com/logo.png",
                twitterHandle: "",
                githubOrg: "",
                telegramGroup: "",
                xPNTsToken: address(0),
                supportedSBTs: emptySBTs,
                mode: Registry.PaymasterMode.SUPER,
                nodeType: Registry.NodeType.PAYMASTER_SUPER,
                paymasterAddress: address(0),
                community: user,
                registeredAt: 0,
                lastUpdatedAt: 0,
                isActive: true,
                memberCount: 0,
                allowPermissionlessMint: true
            });

            vm.startBroadcast(userPrivateKey);

            registry.registerCommunity(profile, 30 ether);

            vm.stopBroadcast();

            console.log("[OK] Community registered");
            console.log();
        } else {
            console.log("[SKIP] Already registered as community");
            console.log();
        }

        // Final check
        console.log("=== Final Status ===");
        console.log("stGT balance:", staking.balanceOf(user));
        console.log("Is registered community:", registry.isRegisteredCommunity(user));
        console.log();
        console.log("[SUCCESS] Ready for MySBT testing!");
    }
}
