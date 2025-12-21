// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {Registry} from "src/paymasters/v2/core/Registry.sol";

/**
 * @title RegisterTestCommunities
 * @notice Script to register multiple test communities for MySBT v2.3.1 testing
 * @dev Registers 3 communities with permissionless mint enabled by default
 */
contract RegisterTestCommunities is Script {
    Registry public registry;

    // Test community accounts (use different accounts for each community)
    address public communityA = 0xf63F964cCAf8A1BAD4B65D1fAc2CE844c095287E;
    address public communityB = 0x2dE69065D657760E2C58daD1DaF26C331207c676;
    address public communityC = vm.envAddress("DEPLOYER_ADDRESS");  // Use deployer as 3rd community

    function run() external {
        // Load environment variables
        registry = Registry(vm.envAddress("REGISTRY"));

        // For testing, we'll use the deployer to register communities
        // In production, each community would register themselves
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerPrivateKey);

        // Register Community A: "AAstar Test Community A"
        _registerCommunity(
            communityA,
            "AAstar Test Community A",
            "test-a.aastar.eth",
            "Test community for permissionless MySBT minting - Community A",
            "https://test-a.aastar.io",
            "https://avatars.githubusercontent.com/u/test-a",
            "@aastar_test_a",
            "aastar-test-a",
            "https://t.me/aastar_test_a"
        );

        // Register Community B: "AAstar Test Community B"
        _registerCommunity(
            communityB,
            "AAstar Test Community B",
            "test-b.aastar.eth",
            "Test community for permissionless MySBT minting - Community B",
            "https://test-b.aastar.io",
            "https://avatars.githubusercontent.com/u/test-b",
            "@aastar_test_b",
            "aastar-test-b",
            "https://t.me/aastar_test_b"
        );

        // Register Community C: "AAstar Test Community C"
        _registerCommunity(
            communityC,
            "AAstar Test Community C",
            "test-c.aastar.eth",
            "Test community for permissionless MySBT minting - Community C",
            "https://test-c.aastar.io",
            "https://avatars.githubusercontent.com/u/test-c",
            "@aastar_test_c",
            "aastar-test-c",
            "https://t.me/aastar_test_c"
        );

        vm.stopBroadcast();

        console.log("=== Test Communities Registered ===");
        console.log("Community A:", communityA);
        console.log("Community B:", communityB);
        console.log("Community C:", communityC);
        console.log();
        console.log("All communities have permissionless mint ENABLED by default");
    }

    function _registerCommunity(
        address communityAddress,
        string memory name,
        string memory ensName,
        string memory description,
        string memory website,
        string memory logoURI,
        string memory twitterHandle,
        string memory githubOrg,
        string memory telegramGroup
    ) internal {
        // Create community profile
        Registry.CommunityProfile memory profile = Registry.CommunityProfile({
            name: name,
            ensName: ensName,
            xPNTsToken: address(0),  // No xPNTs token for test communities
            supportedSBTs: new address[](0),
            nodeType: Registry.NodeType.PAYMASTER_AOA,
            paymasterAddress: address(0),  // No paymaster for test communities
            community: communityAddress,
            registeredAt: 0,  // Will be set by contract
            lastUpdatedAt: 0,  // Will be set by contract
            isActive: true,
            allowPermissionlessMint: true  // Enable permissionless mint by default
        });

        // Register with 0 stGToken (minimal registration for testing)
        // Note: In production, communities should lock 30-100 stGT
        try registry.registerCommunity(profile, 0) {
            console.log("Registered:", name);
        } catch Error(string memory reason) {
            if (keccak256(bytes(reason)) == keccak256(bytes("Community already registered"))) {
                console.log("Already registered:", name);
            } else {
                console.log("Failed to register:", name);
                console.log("Reason:", reason);
            }
        } catch {
            console.log("Failed to register (unknown error):", name);
        }
    }
}
