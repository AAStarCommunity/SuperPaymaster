// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/MySBT.sol";
import "src/tokens/GToken.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

/// @notice P0-14 (H-01): `GTokenStaking.slashByDVT` and friends mutate
///         `roleLocks[user][role].amount` directly. Without a Registry
///         write-back, `Registry.roleStakes[role][user]` silently drifts:
///         an operator can `topUpStake` against a stale "1000 GT" cache
///         after Staking already slashed them down to 500 GT, and any
///         UI/SDK reading Registry shows wrong values. This breaks
///         INV-12 (Registry == Staking).
///
///         Fix: GTokenStaking now calls `Registry.syncStakeFromStaking`
///         after every roleLock mutation; Registry exposes
///         `getEffectiveStake` which reads Staking directly. Staking is
///         the canonical source of truth; Registry is a cache.
contract SlashSync_RegistryStakingTest is Test {
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
    address otherOperator = address(0x6);

    bytes32 constant ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
    bytes32 constant ROLE_DVT = keccak256("DVT");
    bytes32 constant ROLE_COMMUNITY = keccak256("COMMUNITY");

    function setUp() public {
        vm.startPrank(owner);
        gtoken = new GToken(21_000_000 ether);

        registry = UUPSDeployHelper.deployRegistryProxy(owner, address(0), address(0));
        staking = new GTokenStaking(address(gtoken), treasury, address(registry));
        sbt = new MySBT(address(gtoken), address(staking), address(registry), dao);

        registry.setStaking(address(staking));
        registry.setMySBT(address(sbt));

        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(0x123)),
            IRegistry(address(registry)),
            address(0),
            owner,
            address(gtoken),
            treasury,
            3600
        );
        paymaster.setBLSAggregator(dvtAggregator);
        staking.setAuthorizedSlasher(dvtAggregator, true);
        paymaster.updateReputation(operator, 100);
        paymaster.updateReputation(otherOperator, 100);

        gtoken.mint(operator, 1_000_000 ether);
        gtoken.mint(otherOperator, 1_000_000 ether);
        vm.stopPrank();
    }

    function _registerOperatorWithStake(address op, uint256 paymasterStake) internal {
        vm.startPrank(op);
        gtoken.approve(address(staking), paymasterStake + 100 ether);

        bytes memory commData = abi.encode(
            Registry.CommunityRoleData({
                name: string(abi.encodePacked("OpComm-", op)),
                ensName: "",
                website: "",
                description: "",
                logoURI: "",
                stakeAmount: 30 ether
            })
        );
        registry.registerRole(registry.ROLE_COMMUNITY(), op, commData);

        bytes memory roleData = abi.encode(paymasterStake);
        registry.registerRole(ROLE_PAYMASTER_SUPER, op, roleData);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Core invariant: slash → Registry mirrors Staking
    // -----------------------------------------------------------------------

    function test_SlashByDVT_SyncsRegistryRoleStakes() public {
        _registerOperatorWithStake(operator, 50 ether);

        // Pre-state: both views agree.
        assertEq(registry.roleStakes(ROLE_PAYMASTER_SUPER, operator), 50 ether);
        assertEq(staking.getLockedStake(operator, ROLE_PAYMASTER_SUPER), 50 ether);

        // Slash 10 GT.
        vm.prank(dvtAggregator);
        staking.slashByDVT(operator, ROLE_PAYMASTER_SUPER, 10 ether, "rule break");

        // Post-state: both views must agree on 40 GT (no drift).
        assertEq(staking.getLockedStake(operator, ROLE_PAYMASTER_SUPER), 40 ether, "Staking truth");
        assertEq(registry.roleStakes(ROLE_PAYMASTER_SUPER, operator), 40 ether, "Registry must mirror");
    }

    function test_SlashByDVT_EmitsSyncEvent() public {
        _registerOperatorWithStake(operator, 50 ether);

        vm.expectEmit(true, true, false, true, address(registry));
        emit StakeSyncedFromStaking(operator, ROLE_PAYMASTER_SUPER, 40 ether);

        vm.prank(dvtAggregator);
        staking.slashByDVT(operator, ROLE_PAYMASTER_SUPER, 10 ether, "rule break");
    }

    // -----------------------------------------------------------------------
    // Access control on the sync hook
    // -----------------------------------------------------------------------

    function test_SyncStakeFromStaking_OnlyStaking() public {
        // Random caller — must revert.
        vm.prank(address(0xBAD));
        vm.expectRevert(Registry.Unauthorized.selector);
        registry.syncStakeFromStaking(operator, ROLE_PAYMASTER_SUPER, 999 ether);

        // Even owner must not bypass — single source-of-truth invariant.
        vm.prank(owner);
        vm.expectRevert(Registry.Unauthorized.selector);
        registry.syncStakeFromStaking(operator, ROLE_PAYMASTER_SUPER, 999 ether);

        // Staking can.
        vm.prank(address(staking));
        registry.syncStakeFromStaking(operator, ROLE_PAYMASTER_SUPER, 42 ether);
        assertEq(registry.roleStakes(ROLE_PAYMASTER_SUPER, operator), 42 ether);
    }

    // -----------------------------------------------------------------------
    // getEffectiveStake reads Staking directly (no cache lag)
    // -----------------------------------------------------------------------

    function test_GetEffectiveStake_ReadsStaking() public {
        _registerOperatorWithStake(operator, 50 ether);
        assertEq(registry.getEffectiveStake(operator, ROLE_PAYMASTER_SUPER), 50 ether);

        vm.prank(dvtAggregator);
        staking.slashByDVT(operator, ROLE_PAYMASTER_SUPER, 15 ether, "x");

        // getEffectiveStake forwards to Staking — always fresh.
        assertEq(registry.getEffectiveStake(operator, ROLE_PAYMASTER_SUPER), 35 ether);
    }

    /// @notice If Staking pointer is unset (e.g. early bootstrap), the view
    ///         falls back to the cached `roleStakes` so downstream readers
    ///         don't crash. This is a no-staking edge case, not a security
    ///         path.
    function test_GetEffectiveStake_FallbackWhenStakingUnset() public {
        // Deploy a fresh Registry proxy without staking attached.
        Registry r = UUPSDeployHelper.deployRegistryProxy(owner, address(0), address(0));
        // No staking → returns cached value (which is 0 by default).
        assertEq(r.getEffectiveStake(operator, ROLE_PAYMASTER_SUPER), 0);
    }

    // -----------------------------------------------------------------------
    // lockStakeWithTicket (the registerRole path) keeps the mirror in sync
    // -----------------------------------------------------------------------

    /// @notice After fresh registration via Registry → Staking, both sides
    ///         must agree. (Smoke test — pre-existing path, just confirming
    ///         the new `_syncRegistry` hook in `lockStakeWithTicket` is a
    ///         no-op for the cache value already written by Registry.)
    function test_LockStakeWithTicket_MirrorsRegistry() public {
        _registerOperatorWithStake(operator, 80 ether);
        assertEq(staking.getLockedStake(operator, ROLE_PAYMASTER_SUPER), 80 ether);
        assertEq(registry.roleStakes(ROLE_PAYMASTER_SUPER, operator), 80 ether);
    }

    // -----------------------------------------------------------------------
    // The core property the audit cares about: invariant under mixed ops
    // -----------------------------------------------------------------------

    function test_INV_RegistryEqualsStaking_AfterMixedOps() public {
        _registerOperatorWithStake(operator, 100 ether);

        // 1) Slash 25 GT.
        vm.prank(dvtAggregator);
        staking.slashByDVT(operator, ROLE_PAYMASTER_SUPER, 25 ether, "first");
        _assertInvariant(operator, ROLE_PAYMASTER_SUPER, 75 ether);

        // 2) Slash again 30 GT.
        vm.prank(dvtAggregator);
        staking.slashByDVT(operator, ROLE_PAYMASTER_SUPER, 30 ether, "second");
        _assertInvariant(operator, ROLE_PAYMASTER_SUPER, 45 ether);

        // 3) Slash to zero.
        vm.prank(dvtAggregator);
        staking.slashByDVT(operator, ROLE_PAYMASTER_SUPER, 45 ether, "fatal");
        _assertInvariant(operator, ROLE_PAYMASTER_SUPER, 0);
    }

    // Multi-operator: slashing op A must not affect op B's mirror.
    function test_INV_NoCrossUserDrift() public {
        _registerOperatorWithStake(operator, 100 ether);
        _registerOperatorWithStake(otherOperator, 200 ether);

        vm.prank(dvtAggregator);
        staking.slashByDVT(operator, ROLE_PAYMASTER_SUPER, 30 ether, "A only");

        _assertInvariant(operator, ROLE_PAYMASTER_SUPER, 70 ether);
        _assertInvariant(otherOperator, ROLE_PAYMASTER_SUPER, 200 ether); // unaffected
    }

    function _assertInvariant(address user, bytes32 role, uint256 expected) internal view {
        uint256 stakingView = staking.getLockedStake(user, role);
        uint256 registryView = registry.roleStakes(role, user);
        uint256 effective = registry.getEffectiveStake(user, role);
        assertEq(stakingView, expected, "Staking mismatch");
        assertEq(registryView, expected, "Registry cache mismatch");
        assertEq(effective, expected, "getEffectiveStake mismatch");
    }

    // Local copy of the event for vm.expectEmit (event lives on Registry).
    event StakeSyncedFromStaking(address indexed user, bytes32 indexed roleId, uint256 newAmount);
}
