// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../src/paymasters/v2/core/Registry.sol";
import "../../src/paymasters/v2/core/GTokenStaking.sol";
import "../../src/paymasters/v2/tokens/GToken.sol";

/**
 * @title RegistryTest
 * @notice Test Registry v2.1 core functionality
 */
contract RegistryTest is Test {
    Registry public registry;
    GTokenStaking public staking;
    GToken public gtoken;

    address public operator = address(0x1);
    address public xpnts = address(0x2);
    address public sbt = address(0x3);

    function setUp() public {
        // Deploy GToken
        gtoken = new GToken("GToken", "GT", address(this));

        // Deploy GTokenStaking
        staking = new GTokenStaking(address(gtoken));

        // Deploy Registry v2.1
        registry = new Registry(address(staking));

        // Configure Registry as locker in staking
        staking.addLocker(address(registry));

        // Mint GToken to operator
        gtoken.mint(operator, 1000 ether);

        // Operator stakes GT
        vm.startPrank(operator);
        gtoken.approve(address(staking), 1000 ether);
        staking.stake(100 ether);
        vm.stopPrank();
    }

    function test_DeploymentDefaults() public {
        // Check default configs for each node type
        (uint256 minStake, uint256 slashThreshold, uint256 slashBase, uint256 slashIncrement, uint256 slashMax)
            = registry.nodeTypeConfigs(Registry.NodeType.PAYMASTER_AOA);

        assertEq(minStake, 30 ether, "AOA min stake should be 30");
        assertEq(slashThreshold, 10, "AOA slash threshold should be 10");
        assertEq(slashBase, 2, "AOA slash base should be 2%");
        assertEq(slashIncrement, 1, "AOA slash increment should be 1%");
        assertEq(slashMax, 10, "AOA slash max should be 10%");
    }

    function test_RegisterCommunity_AOA() public {
        address[] memory sbts = new address[](1);
        sbts[0] = sbt;

        Registry.CommunityProfile memory profile = Registry.CommunityProfile({
            name: "Test AOA",
            ensName: "test.eth",
            description: "Test community",
            website: "https://test.com",
            logoURI: "",
            twitterHandle: "@test",
            githubOrg: "test-org",
            telegramGroup: "",
            xPNTsToken: xpnts,
            supportedSBTs: sbts,
            mode: Registry.PaymasterMode.INDEPENDENT,
            nodeType: Registry.NodeType.PAYMASTER_AOA,
            paymasterAddress: address(0),
            community: address(0),
            registeredAt: 0,
            lastUpdatedAt: 0,
            isActive: false,
            memberCount: 0
        });

        vm.prank(operator);
        registry.registerCommunity(profile, 30 ether);

        // Verify registration
        (string memory name,,,,,,,,,,,, uint256 registeredAt,,,) = registry.communities(operator);
        assertEq(name, "Test AOA", "Community name should match");
        assertGt(registeredAt, 0, "Should be registered");

        // Check stake
        (uint256 locked,,,,,) = registry.communityStakes(operator);
        assertEq(locked, 30 ether, "Should have 30 GT locked");
    }

    function test_ConfigureNodeType() public {
        Registry.NodeTypeConfig memory newConfig = Registry.NodeTypeConfig({
            minStake: 50 ether,
            slashThreshold: 5,
            slashBase: 3,
            slashIncrement: 2,
            slashMax: 15
        });

        registry.configureNodeType(Registry.NodeType.PAYMASTER_AOA, newConfig);

        (uint256 minStake, uint256 slashThreshold, uint256 slashBase, uint256 slashIncrement, uint256 slashMax)
            = registry.nodeTypeConfigs(Registry.NodeType.PAYMASTER_AOA);

        assertEq(minStake, 50 ether, "Min stake should be updated");
        assertEq(slashThreshold, 5, "Slash threshold should be updated");
        assertEq(slashBase, 3, "Slash base should be updated");
        assertEq(slashIncrement, 2, "Slash increment should be updated");
        assertEq(slashMax, 15, "Slash max should be updated");
    }

    function test_SetSuperPaymasterV2() public {
        address newSuper = address(0x999);
        registry.setSuperPaymasterV2(newSuper);
        assertEq(registry.superPaymasterV2(), newSuper, "SuperPaymaster address should be set");
    }

    function test_BackwardCompatibility() public {
        // Test that PaymasterMode.INDEPENDENT maps to NodeType.PAYMASTER_AOA
        address[] memory sbts = new address[](1);
        sbts[0] = sbt;

        Registry.CommunityProfile memory profile = Registry.CommunityProfile({
            name: "Test Compat",
            ensName: "compat.eth",
            description: "Test backward compat",
            website: "",
            logoURI: "",
            twitterHandle: "",
            githubOrg: "",
            telegramGroup: "",
            xPNTsToken: xpnts,
            supportedSBTs: sbts,
            mode: Registry.PaymasterMode.INDEPENDENT,
            nodeType: Registry.NodeType.PAYMASTER_AOA,
            paymasterAddress: address(0),
            community: address(0),
            registeredAt: 0,
            lastUpdatedAt: 0,
            isActive: false,
            memberCount: 0
        });

        vm.prank(operator);
        registry.registerCommunity(profile, 30 ether);

        // Verify that mode is preserved
        (,,,,,,,,,, Registry.PaymasterMode mode,,,,,,,) = registry.communities(operator);
        assertEq(uint8(mode), uint8(Registry.PaymasterMode.INDEPENDENT), "Mode should be INDEPENDENT");
    }
}
