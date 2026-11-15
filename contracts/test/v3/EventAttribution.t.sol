// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/core/Registry.sol";
import "src/core/GTokenStaking.sol";
import "src/tokens/GToken.sol";
import "src/tokens/MySBT.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import {SuperPaymasterAdminCalls} from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

using SuperPaymasterAdminCalls for SuperPaymaster;

contract AttributionOracle {
    int256 public price = 2000e8;
    uint256 public updatedAt = block.timestamp;

    function set(int256 value, uint256 timestamp) external {
        price = value;
        updatedAt = timestamp;
    }

    function decimals() external pure returns (uint8) { return 8; }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, updatedAt, updatedAt, 1);
    }
}

/// @dev Minimal factory/token boundary for configuring an operator through the public API.
contract AttributionTokenFactory {
    function getTokenAddress(address) external view returns (address) { return address(this); }
    function BALANCE_MODE_VERSION() external pure returns (uint16) { return 1; }
}

contract EventAttributionTest is Test {
    Registry registry;
    GTokenStaking staking;
    GToken gtoken;
    SuperPaymaster sp;
    AttributionOracle oracle;
    address owner = address(0x101);
    address guardian = address(0x102);
    address bls = address(0x103);
    address operator = address(0x104);
    address random = address(0x105);
    bytes32 constant SUPER_ROLE = keccak256("PAYMASTER_SUPER");

    // Literal reason values pin the public event contract independently of implementation constants.
    event OperatorPaused(address indexed operator, address indexed by, uint8 reason);
    event OperatorUnpaused(address indexed operator, address indexed by, uint8 reason);
    event SlashQueued(address indexed operator, address indexed by);
    event SlashCancelled(address indexed operator, address indexed by);
    event PriceUpdated(int256 indexed price, uint256 indexed timestamp, address by);
    event PriceModeChanged(uint8 oldMode, uint8 newMode, address by);
    event OperatorSlashed(address indexed operator, uint256 amount, ISuperPaymaster.SlashLevel level, address by);
    event ReputationUpdated(address indexed operator, uint256 newScore, address by);
    event SBTStatusUpdated(address indexed user, bool status);
    event RoleStakeSynced(address indexed user, bytes32 indexed roleId, uint256 newAmount);

    function setUp() public {
        vm.warp(1_700_000_000);
        vm.startPrank(owner);
        gtoken = new GToken(21_000_000 ether);
        registry = UUPSDeployHelper.deployRegistryProxy(owner, address(0), address(0));
        staking = new GTokenStaking(address(gtoken), owner, address(registry));
        MySBT sbt = new MySBT(address(gtoken), address(staking), address(registry), owner);
        registry.setStaking(address(staking));
        registry.setMySBT(address(sbt));
        staking.setAuthorizedSlasher(bls, true);
        oracle = new AttributionOracle();
        sp = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(0x123)), registry, address(oracle), owner, address(gtoken), owner, 4200
        );
        sp.setGuardian(guardian);
        sp.initBLSAggregator(bls);
        sp.setXPNTsFactory(address(new AttributionTokenFactory()));
        sp.updatePrice();
        sp.updateReputation(operator, 100);
        gtoken.mint(operator, 10_000 ether);
        gtoken.mint(random, 10_000 ether);
        vm.stopPrank();
        _register(operator);
        vm.startPrank(operator);
        sp.configureOperator(sp.xpntsFactory(), operator);
        gtoken.approve(address(sp), 1000 ether);
        sp.depositFor(operator, 1000 ether);
        vm.stopPrank();
    }

    function _register(address user) internal {
        vm.startPrank(user);
        gtoken.approve(address(staking), type(uint256).max);
        registry.registerRole(keccak256("COMMUNITY"), user, abi.encode(
            Registry.CommunityRoleData({name: string(abi.encodePacked("Community", user)), ensName: "", stakeAmount: 30 ether})
        ));
        registry.registerRole(SUPER_ROLE, user, abi.encode(uint256(50 ether)));
        vm.stopPrank();
    }

    function test_OwnerPause_OWNER_PAUSE() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit OperatorPaused(operator, owner, 1);
        sp.setOperatorPaused(operator, true);
    }

    function test_GuardianPause_GUARDIAN_PAUSE() public {
        vm.prank(guardian);
        vm.expectEmit(true, true, true, true);
        emit OperatorPaused(operator, guardian, 2);
        sp.setOperatorPaused(operator, true);
    }

    function test_OwnerGuardianPause_OwnerPrecedence() public {
        vm.startPrank(owner);
        sp.setGuardian(owner);
        vm.expectEmit(true, true, true, true);
        emit OperatorPaused(operator, owner, 1);
        sp.setOperatorPaused(operator, true);
        vm.stopPrank();
    }

    function test_OwnerUnpause_OWNER_UNPAUSE() public {
        vm.startPrank(owner);
        sp.setOperatorPaused(operator, true);
        vm.expectEmit(true, true, true, true);
        emit OperatorUnpaused(operator, owner, 3);
        sp.setOperatorPaused(operator, false);
        vm.stopPrank();
    }

    function _understake() internal {
        vm.prank(bls);
        staking.slashByDVT(operator, SUPER_ROLE, 49 ether, "understake");
    }

    function test_RandomUnderstakePause_ByCaller() public {
        _understake();
        vm.prank(random);
        vm.expectEmit(true, true, true, true);
        emit OperatorPaused(operator, random, 4);
        sp.pauseUnderstakedOperator(operator);
    }

    function test_GuardianUnderstakePause_UNDERSTAKED() public {
        _understake();
        vm.prank(guardian);
        vm.expectEmit(true, true, true, true);
        emit OperatorPaused(operator, guardian, 4);
        sp.pauseUnderstakedOperator(operator);
    }

    function _expectSlash(address by, ISuperPaymaster.SlashLevel level, uint256 amount, uint256 score) internal {
        _expectSlash(by, level, amount, score, true);
    }

    function _expectSlash(address by, ISuperPaymaster.SlashLevel level, uint256 amount, uint256 score, bool pauses)
        internal
    {
        if (pauses) {
            vm.expectEmit(true, true, true, true);
            emit OperatorPaused(operator, by, 5);
        }
        vm.expectEmit(true, true, true, true);
        emit OperatorSlashed(operator, amount, level, by);
        vm.expectEmit(true, true, true, true);
        emit ReputationUpdated(operator, score, by);
    }

    function test_OwnerMajorSlash_ActiveOperator_SLASH() public {
        vm.startPrank(owner);
        sp.queueSlash(operator);
        _expectSlash(owner, ISuperPaymaster.SlashLevel.MAJOR, 100 ether, 50);
        sp.slashOperator(operator, ISuperPaymaster.SlashLevel.MAJOR, 100 ether, "major");
        vm.stopPrank();
    }

    function _nonMajorSlashDoesNotPause(ISuperPaymaster.SlashLevel level, uint256 amount, uint256 score) internal {
        (,, bool paused,,,,,,) = sp.operators(operator);
        assertFalse(paused, "precondition: unpaused");
        vm.startPrank(owner);
        sp.queueSlash(operator);
        _expectSlash(owner, level, amount, score, false);
        vm.recordLogs();
        sp.slashOperator(operator, level, amount, "non-major");
        vm.stopPrank();
        _assertNoPauseEvent();
        (,, paused,,,,,,) = sp.operators(operator);
        assertFalse(paused, "non-major slash must leave operator unpaused");
    }

    function test_OwnerWarningSlash_ActiveOperator_NoPause() public {
        _nonMajorSlashDoesNotPause(ISuperPaymaster.SlashLevel.WARNING, 0, 90);
    }

    function test_OwnerMinorSlash_ActiveOperator_NoPause() public {
        _nonMajorSlashDoesNotPause(ISuperPaymaster.SlashLevel.MINOR, 100 ether, 80);
    }

    function test_OwnerMinorSlash_AlreadyPaused_NoPauseReattribution() public {
        vm.startPrank(owner);
        sp.setOperatorPaused(operator, true);
        sp.queueSlash(operator);
        _expectSlash(owner, ISuperPaymaster.SlashLevel.MINOR, 100 ether, 80, false);
        vm.recordLogs();
        sp.slashOperator(operator, ISuperPaymaster.SlashLevel.MINOR, 100 ether, "minor");
        vm.stopPrank();
        _assertNoPauseEvent();
    }

    function test_OwnerMajorSlash_AlreadyPaused_NoPauseReattribution() public {
        vm.startPrank(owner);
        sp.setOperatorPaused(operator, true);
        sp.queueSlash(operator);
        _expectSlash(owner, ISuperPaymaster.SlashLevel.MAJOR, 100 ether, 50, false);
        vm.recordLogs();
        sp.slashOperator(operator, ISuperPaymaster.SlashLevel.MAJOR, 100 ether, "major");
        vm.stopPrank();
        _assertNoPauseEvent();
        (,, bool paused,,,,,,) = sp.operators(operator);
        assertTrue(paused, "operator stays paused");
    }

    /// @dev Absence check with a live instrument: the selector must match the declared event.
    function _assertNoPauseEvent() internal {
        _assertNoEvent(keccak256("OperatorPaused(address,address,uint8)"), "slash must not emit OperatorPaused");
    }

    function _assertNoEvent(bytes32 topic, string memory why) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(sp) && logs[i].topics.length > 0) {
                assertTrue(logs[i].topics[0] != topic, why);
            }
        }
    }

    /// @dev Live instrument for _assertNoEvent: the same recording does see a real transition.
    function test_NoEventInstrument_SeesARealPause() public {
        vm.recordLogs();
        vm.prank(guardian);
        sp.setOperatorPaused(operator, true);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(sp) && logs[i].topics[0] == keccak256("OperatorPaused(address,address,uint8)")) seen = true;
        }
        assertTrue(seen, "instrument must see a real OperatorPaused");
    }

    function test_GuardianRepeatPause_AfterOwnerPause_NoReattribution() public {
        vm.prank(owner);
        sp.setOperatorPaused(operator, true);
        vm.recordLogs();
        vm.prank(guardian);
        sp.setOperatorPaused(operator, true);
        _assertNoEvent(keccak256("OperatorPaused(address,address,uint8)"), "a repeat pause must not re-attribute the pause");
        (,, bool paused,,,,,,) = sp.operators(operator);
        assertTrue(paused, "operator stays paused");
    }

    function test_OwnerRepeatUnpause_NoEvent() public {
        (,, bool paused,,,,,,) = sp.operators(operator);
        assertFalse(paused, "precondition: unpaused");
        vm.recordLogs();
        vm.prank(owner);
        sp.setOperatorPaused(operator, false);
        _assertNoEvent(keccak256("OperatorUnpaused(address,address,uint8)"), "unpausing an unpaused operator must not emit");
    }

    function test_RandomRepeatPause_RevertsUnauthorized() public {
        vm.prank(owner);
        sp.setOperatorPaused(operator, true);
        (,, bool paused,,,,,,) = sp.operators(operator);
        assertTrue(paused, "precondition: already paused");
        vm.prank(random);
        vm.expectRevert(SuperPaymasterStorage.Unauthorized.selector);
        sp.setOperatorPaused(operator, true);
    }

    function test_GuardianRepeatUnpause_RevertsUnauthorized() public {
        (,, bool paused,,,,,,) = sp.operators(operator);
        assertFalse(paused, "precondition: already unpaused");
        vm.prank(guardian);
        vm.expectRevert(SuperPaymasterStorage.Unauthorized.selector);
        sp.setOperatorPaused(operator, false);
    }

    function test_BLSMajorSlash_PreservesExternalCaller() public {
        vm.startPrank(bls);
        sp.queueSlash(operator);
        _expectSlash(bls, ISuperPaymaster.SlashLevel.MAJOR, 300 ether, 50);
        sp.executeSlashWithBLS(operator, ISuperPaymaster.SlashLevel.MAJOR, "proof");
        vm.stopPrank();
    }

    function test_OwnerSlashAfterReleasing_PreservesExternalCaller() public {
        vm.startPrank(owner);
        sp.queueSlash(operator);
        _expectSlash(owner, ISuperPaymaster.SlashLevel.MAJOR, 100 ether, 50);
        sp.slashOperatorAfterReleasing(operator, ISuperPaymaster.SlashLevel.MAJOR, 100 ether, "major", new bytes32[](0));
        vm.stopPrank();
    }

    function _queue(address by) internal {
        vm.prank(by);
        vm.expectEmit(true, true, true, true);
        emit SlashQueued(operator, by);
        sp.queueSlash(operator);
    }

    function test_QueueSlash_Owner() public { _queue(owner); }
    function test_QueueSlash_Guardian() public { _queue(guardian); }
    function test_QueueSlash_BLS() public { _queue(bls); }

    function test_CancelSlash_Owner() public {
        _queue(guardian);
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SlashCancelled(operator, owner);
        sp.cancelSlash(operator);
    }

    function test_CancelSlash_NoQueue_NoEvent() public {
        // The queuedAt == 0 guard arm is a documented no-op: current paths set and clear the flag and queue together.
        vm.recordLogs();
        vm.prank(owner);
        sp.cancelSlash(operator);
        _assertNoEvent(keccak256("SlashCancelled(address,address)"), "nothing queued: no SlashCancelled");
    }

    function test_CancelSlash_LegacyFlagWithoutQueue_ClearsAndUnblocksWithdrawal() public {
        // forge inspect SuperPaymaster storageLayout: _pendingSlash is mapping(address => bool) at slot 34.
        bytes32 pendingSlot = keccak256(abi.encode(operator, uint256(34)));
        assertEq(vm.load(address(sp), pendingSlot), bytes32(0), "precondition: flag clear");
        vm.startPrank(owner);
        sp.queueSlash(operator);
        assertEq(vm.load(address(sp), pendingSlot), bytes32(uint256(1)), "slot must track a real queue");
        sp.cancelSlash(operator);
        vm.stopPrank();
        assertEq(vm.load(address(sp), pendingSlot), bytes32(0), "slot must track a real cancellation");

        vm.store(address(sp), pendingSlot, bytes32(uint256(1)));
        (address queuedBy, uint48 queuedAt, bool guardianQueued) = sp.slashQueues(operator);
        assertEq(queuedBy, address(0), "legacy flag has no queue actor");
        assertEq(queuedAt, 0, "legacy flag has no queue timestamp");
        assertFalse(guardianQueued, "legacy flag has no guardian queue");
        assertTrue(sp.isSlashPending(operator), "legacy flag is effective");
        vm.prank(operator);
        vm.expectRevert(SuperPaymasterStorage.SlashPending.selector);
        sp.requestWithdraw(100 ether);

        vm.prank(owner);
        vm.expectEmit(true, true, true, true, address(sp));
        emit SlashCancelled(operator, owner);
        sp.cancelSlash(operator);
        assertEq(vm.load(address(sp), pendingSlot), bytes32(0), "legacy flag cleared");
        assertFalse(sp.isSlashPending(operator), "withdrawal no longer blocked");

        uint256 balanceBefore = gtoken.balanceOf(operator);
        vm.prank(operator);
        sp.requestWithdraw(100 ether);
        (uint128 amount, uint48 readyAt) = sp.pendingWithdrawals(operator);
        assertEq(amount, 100 ether, "withdrawal request accepted");
        vm.warp(readyAt);
        vm.prank(operator);
        sp.withdraw(100 ether);
        assertEq(gtoken.balanceOf(operator), balanceBefore + 100 ether, "withdrawal paid");
    }

    function test_CancelSlash_Twice_SecondIsSilent() public {
        _queue(guardian);
        vm.prank(owner);
        sp.cancelSlash(operator);
        vm.recordLogs();
        vm.prank(owner);
        sp.cancelSlash(operator);
        _assertNoEvent(keccak256("SlashCancelled(address,address)"), "second cancel must not emit");
    }

    function test_CancelSlash_ExpiredGuardianQueue_StillClearsAndEmits() public {
        _queue(guardian);
        vm.warp(block.timestamp + sp.GUARDIAN_SLASH_FREEZE() + 1);
        assertFalse(sp.isSlashPending(operator), "precondition: guardian queue expired");
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit SlashCancelled(operator, owner);
        sp.cancelSlash(operator);
        (, uint48 queuedAt,) = sp.slashQueues(operator);
        assertEq(queuedAt, 0, "expired queue record is cleared");
    }

    function test_UpdateReputation_Owner() public {
        vm.prank(owner);
        vm.expectEmit(true, true, true, true);
        emit ReputationUpdated(operator, 123, owner);
        sp.updateReputation(operator, 123);
    }

    function test_SBTStatusUpdated_TrueAndFalse() public {
        vm.startPrank(address(registry));
        vm.expectEmit(true, true, true, true);
        emit SBTStatusUpdated(random, true);
        sp.updateSBTStatus(random, true);
        vm.expectEmit(true, true, true, true);
        emit SBTStatusUpdated(random, false);
        sp.updateSBTStatus(random, false);
        vm.stopPrank();
    }

    function _queueEmergency() internal {
        oracle.set(2000e8, block.timestamp - 2 hours);
        vm.prank(owner);
        sp.emergencySetPrice(1900e8);
        vm.warp(block.timestamp + 1 hours);
    }

    function test_ExecuteEmergencyPrice_KeeperAttribution() public {
        _queueEmergency();
        vm.prank(random);
        vm.expectEmit(true, true, true, true);
        emit PriceModeChanged(0, 1, random);
        vm.expectEmit(true, true, true, true);
        emit PriceUpdated(1900e8, block.timestamp, random);
        sp.executeEmergencyPrice();
    }

    function _enterEmergency() internal {
        _queueEmergency();
        sp.executeEmergencyPrice();
        vm.warp(block.timestamp + 1);
    }

    function _dvtRecovery(address by) internal {
        _enterEmergency();
        vm.prank(by);
        vm.expectEmit(true, true, true, true);
        emit PriceModeChanged(1, 0, by);
        vm.expectEmit(true, true, true, true);
        emit PriceUpdated(2000e8, block.timestamp, by);
        sp.updatePriceDVT(2000e8, block.timestamp, "proof", 1);
    }

    function test_UpdatePriceDVT_OwnerRecovery() public { _dvtRecovery(owner); }
    function test_UpdatePriceDVT_BLSRecovery() public { _dvtRecovery(bls); }

    function test_UpdatePrice_ChainlinkRecoveryKeeper() public {
        _enterEmergency();
        oracle.set(2050e8, block.timestamp);
        vm.prank(random);
        vm.expectEmit(true, true, true, true);
        emit PriceModeChanged(1, 0, random);
        vm.expectEmit(true, true, true, true);
        emit PriceUpdated(2050e8, block.timestamp, random);
        sp.updatePrice();
    }

    function _assertStake(address user, uint256 amount) internal view {
        assertEq(registry.getRoleStake(SUPER_ROLE, user), amount, "RoleStakeSynced matches Registry write");
        assertEq(staking.getLockedStake(user, SUPER_ROLE), amount, "RoleStakeSynced matches Staking");
    }

    function test_RegistryRoleStakeSynced_Lock() public {
        vm.startPrank(random);
        gtoken.approve(address(staking), type(uint256).max);
        registry.registerRole(keccak256("COMMUNITY"), random, abi.encode(
            Registry.CommunityRoleData({name: "New community", ensName: "", stakeAmount: 30 ether})
        ));
        vm.expectEmit(true, true, true, true);
        emit RoleStakeSynced(random, SUPER_ROLE, 50 ether);
        registry.registerRole(SUPER_ROLE, random, abi.encode(uint256(50 ether)));
        vm.stopPrank();
        _assertStake(random, 50 ether);
    }

    function test_RegistryRoleStakeSynced_TopUp() public {
        vm.prank(address(registry));
        vm.expectEmit(true, true, true, true);
        emit RoleStakeSynced(operator, SUPER_ROLE, 75 ether);
        staking.topUpStake(operator, SUPER_ROLE, 25 ether, operator);
        _assertStake(operator, 75 ether);
    }

    function test_RegistryRoleStakeSynced_Unlock() public {
        vm.warp(block.timestamp + 365 days);
        vm.prank(operator);
        vm.expectEmit(true, true, true, true);
        emit RoleStakeSynced(operator, SUPER_ROLE, 0);
        registry.exitRole(SUPER_ROLE);
        _assertStake(operator, 0);
    }

    function test_RegistryRoleStakeSynced_Slash() public {
        vm.prank(bls);
        vm.expectEmit(true, true, true, true);
        emit RoleStakeSynced(operator, SUPER_ROLE, 40 ether);
        staking.slashByDVT(operator, SUPER_ROLE, 10 ether, "slash");
        _assertStake(operator, 40 ether);
    }
}
