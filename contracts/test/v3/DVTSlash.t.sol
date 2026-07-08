// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/core/Registry.sol";
import "src/interfaces/v3/IRegistry.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/MySBT.sol";
import "src/tokens/GToken.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

contract DVTSlashTest is Test {
    Registry registry;
    GTokenStaking staking;
    MySBT sbt;
    GToken gtoken;
    SuperPaymaster paymaster;

    address owner = address(0x1);
    address dao = address(0x2);
    address treasury = address(0x3);
    address operator = address(0x4);
    address dvtAggregator = address(0x5);

    bytes32 constant ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");

    function setUp() public {
        vm.startPrank(owner);

        gtoken = new GToken(1000000 ether);

        // Scheme B: Deploy Registry proxy first with placeholders
        registry = UUPSDeployHelper.deployRegistryProxy(owner, address(0), address(0));

        // Deploy Staking and MySBT with immutable Registry
        staking = new GTokenStaking(address(gtoken), treasury, address(registry));
        sbt = new MySBT(address(gtoken), address(staking), address(registry), dao);

        // Wire into Registry
        registry.setStaking(address(staking));
        registry.setMySBT(address(sbt));
        
        // Define new variables for the SuperPaymaster constructor
        address entryPoint = address(0x123); // Dummy non-zero address
        address oracle = address(0); // No price feed needed, so address(0)

        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(entryPoint),
            IRegistry(address(registry)),
            address(oracle),
            owner,
            address(gtoken), // Assuming aPNTs refers to gtoken based on context
            treasury,
            3600
        );

        paymaster.queueBLSAggregator(dvtAggregator);
        vm.warp(block.timestamp + 24 hours + 1);
        paymaster.applyBLSAggregator();
        staking.setAuthorizedSlasher(dvtAggregator, true);
        
        // Initialize reputation
        paymaster.updateReputation(operator, 100);
        
        gtoken.mint(operator, 1000000 ether);
        vm.stopPrank();
    }

    function test_FullTwoTierSlashIntegration() public {
        // 1. Register Operator
        vm.startPrank(operator);
        gtoken.approve(address(staking), 100 ether);
        
        bytes memory commData = abi.encode(
            Registry.CommunityRoleData({
                name: "OpComm",
                ensName: "",
                stakeAmount: 30 ether
            })
        );
        registry.registerRole(keccak256("COMMUNITY"), operator, commData);

        bytes memory roleData = abi.encode(uint256(50 ether));
        registry.registerRole(ROLE_PAYMASTER_SUPER, operator, roleData);
        vm.stopPrank();

        // Verify initial stake (COMMUNITY is non-operator: no stake; 50 for paymaster only)
        assertEq(staking.balanceOf(operator), 50 ether);

        // 2. Perform Tier 1 Slash (aPNTs Rep Loss) via SuperPaymaster
        // HIGH-1: queue slash first (BLS_AGGREGATOR can call queueSlash)
        vm.startPrank(dvtAggregator);
        paymaster.queueSlash(operator);
        paymaster.executeSlashWithBLS(
            operator,
            ISuperPaymaster.SlashLevel.MINOR,
            "Tier 1 Penalty"
        );
        
        // Verify rep loss (assuming starting rep is 100, MINOR loss is 20)
        (,,,, uint32 reputation,,,,) = paymaster.operators(operator);
        assertEq(reputation, 80);

        // 3. Perform Tier 2 Slash (GToken Stake) via GTokenStaking
        staking.slashByDVT(
            operator,
            ROLE_PAYMASTER_SUPER,
            10 ether,
            "Tier 2 Penalty"
        );
        
        // Verify GToken balance reduced (50 - 10 = 40)
        assertEq(staking.balanceOf(operator), 40 ether);
        assertEq(staking.totalStaked(), 40 ether);
        
        vm.stopPrank();
    }

    function test_SlashByDVT_Unauthorized_Reverts() public {
        address hacker = address(0x1337);
        vm.startPrank(hacker);
        
        vm.expectRevert(abi.encodeWithSelector(GTokenStaking.NotAuthorizedSlasher.selector));
        staking.slashByDVT(operator, ROLE_PAYMASTER_SUPER, 1 ether, "Hacked");
        
        vm.stopPrank();
    }

    function test_SlashByDVT_InsufficientStake_Reverts() public {
        vm.prank(owner);
        staking.setAuthorizedSlasher(dvtAggregator, true);

        vm.startPrank(dvtAggregator);
        vm.expectRevert(abi.encodeWithSelector(GTokenStaking.InsufficientStake.selector));
        staking.slashByDVT(operator, ROLE_PAYMASTER_SUPER, 1 ether, "No stake yet");
        vm.stopPrank();
    }

    // ============================================================
    // CC-13: BLS-path slash cooldown (anti double-slash) + isSlashPending
    // ============================================================

    function _registerOperatorForSlash() internal {
        vm.startPrank(operator);
        gtoken.approve(address(staking), 100 ether);
        bytes memory commData = abi.encode(
            Registry.CommunityRoleData({ name: "OpComm", ensName: "", stakeAmount: 30 ether })
        );
        registry.registerRole(keccak256("COMMUNITY"), operator, commData);
        bytes memory roleData = abi.encode(uint256(50 ether));
        registry.registerRole(ROLE_PAYMASTER_SUPER, operator, roleData);
        vm.stopPrank();
    }

    /// @dev Two DVT nodes observing the same violation at different finalized blocks derive
    ///      different epochs → distinct queue-hashes that bypass the aggregator replay-guard.
    ///      Node B re-queues after node A cleared _pendingSlash and would double-slash. The
    ///      BLS-path cooldown must block the second execute within the window.
    function test_ExecuteSlashWithBLS_CooldownBlocksReQueue() public {
        _registerOperatorForSlash();

        vm.startPrank(dvtAggregator);
        paymaster.queueSlash(operator);
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.MINOR, "proof-1");
        assertFalse(paymaster.isSlashPending(operator), "pending cleared after first execute");

        // A raced second node re-queues within the cooldown → blocked at the queue step, so no
        // stale pending flag is parked (this is what actually prevents the double-slash).
        vm.expectRevert(SuperPaymaster.SlashCooldown.selector);
        paymaster.queueSlash(operator);
        assertFalse(paymaster.isSlashPending(operator), "no stale pending parked during cooldown");
        vm.stopPrank();
    }

    /// @dev Regression for the Codex finding: once the window lapses, a slash must NOT be primed
    ///      by a stale pending flag. Since the raced re-queue was blocked during the window, an
    ///      execute-only attempt after the window reverts (a fresh queue is required).
    function test_ExecuteSlashWithBLS_NoPrimedSlashAfterWindow() public {
        _registerOperatorForSlash();

        vm.startPrank(dvtAggregator);
        paymaster.queueSlash(operator);
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.MINOR, "proof-1");

        vm.warp(block.timestamp + 1 hours + 1); // window lapses; no re-queue happened
        vm.expectRevert(bytes("SP: must queueSlash first"));
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.MINOR, "proof-2");
        assertFalse(paymaster.isSlashPending(operator), "still no pending after window");
        vm.stopPrank();
    }

    /// @dev After the 1h cooldown elapses, a legitimate later slash (fresh queue + execute) succeeds.
    function test_ExecuteSlashWithBLS_CooldownExpires() public {
        _registerOperatorForSlash();

        vm.startPrank(dvtAggregator);
        paymaster.queueSlash(operator);
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.MINOR, "proof-1");

        vm.warp(block.timestamp + 1 hours + 1);
        paymaster.queueSlash(operator);
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.MINOR, "proof-2");
        assertFalse(paymaster.isSlashPending(operator), "pending cleared after cooldown-expiry execute");
        vm.stopPrank();
    }

    /// @dev The public getter must mirror the private _pendingSlash flag through its lifecycle.
    function test_IsSlashPending_ReflectsFlag() public {
        _registerOperatorForSlash();

        assertFalse(paymaster.isSlashPending(operator), "no pending initially");
        vm.startPrank(dvtAggregator);
        paymaster.queueSlash(operator);
        assertTrue(paymaster.isSlashPending(operator), "pending after queue");
        paymaster.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.MINOR, "proof");
        assertFalse(paymaster.isSlashPending(operator), "cleared after execute");
        vm.stopPrank();

        // Owner queue is exempt from the BLS cooldown; cancelSlash path also reflected.
        vm.prank(owner);
        paymaster.queueSlash(operator);
        assertTrue(paymaster.isSlashPending(operator), "pending after owner re-queue");
        vm.prank(owner);
        paymaster.cancelSlash(operator);
        assertFalse(paymaster.isSlashPending(operator), "cleared after cancel");
    }
}
