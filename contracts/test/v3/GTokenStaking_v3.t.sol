// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../src/paymasters/v2/core/GTokenStaking_v3_0_0.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";

/**
 * @title GTokenStaking_v3_0_0 Test Suite
 * @notice 15+ test cases for staking, locking, and burn tracking
 */

contract MockGToken is ERC20 {
    constructor() ERC20("GToken", "GT") {
        _mint(msg.sender, 10000 ether);
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}

contract GTokenStakingV3Test is Test {
    GTokenStaking gtStaking;
    MockGToken gtoken;

    address owner = makeAddr("owner");
    address treasury = makeAddr("treasury");
    address registry = makeAddr("registry");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");

    bytes32 ROLE_ENDUSER = keccak256("ENDUSER");
    bytes32 ROLE_COMMUNITY = keccak256("COMMUNITY");

    function setUp() public {
        gtoken = new MockGToken();

        gtoken.mint(user1, 100 ether);
        gtoken.mint(user2, 100 ether);

        vm.prank(owner);
        gtStaking = new GTokenStaking(address(gtoken), treasury);

        vm.prank(owner);
        gtStaking.setLockerAuthorization(registry, true);
    }

    // ====================================
    // Test Suite 1: Basic Staking
    // ====================================

    function test_stake() public {
        vm.prank(user1);
        gtoken.approve(address(gtStaking), 10 ether);

        vm.prank(user1);
        gtStaking.stake(10 ether);

        assertEq(gtStaking.getAvailableBalance(user1), 10 ether);
        assertEq(gtStaking.getTotalBalance(user1), 10 ether);
    }

    function test_stake_multiple() public {
        vm.prank(user1);
        gtoken.approve(address(gtStaking), 20 ether);

        vm.prank(user1);
        gtStaking.stake(10 ether);

        vm.prank(user1);
        gtStaking.stake(10 ether);

        assertEq(gtStaking.getAvailableBalance(user1), 20 ether);
    }

    function test_stake_belowMinimum() public {
        vm.prank(user1);
        gtoken.approve(address(gtStaking), 0.001 ether);

        vm.prank(user1);
        vm.expectRevert();
        gtStaking.stake(0.001 ether);
    }

    // ====================================
    // Test Suite 2: Lock Stake
    // ====================================

    function test_lockStake_ENDUSER() public {
        // Setup
        vm.prank(user1);
        gtoken.approve(address(gtStaking), 0.3 ether);

        vm.prank(user1);
        gtStaking.stake(0.3 ether);

        // Lock
        vm.prank(registry);
        gtStaking.lockStake(user1, ROLE_ENDUSER, 0.3 ether, 0.1 ether);

        // Verify
        assertEq(gtStaking.getAvailableBalance(user1), 0, "Available should be 0");
        assertEq(gtStaking.getLockedBalance(user1), 0.2 ether, "Locked should be 0.2");
        assertEq(gtStaking.getTotalBurned(user1), 0.1 ether, "Burned should be 0.1");
    }

    function test_lockStake_COMMUNITY() public {
        vm.prank(user2);
        gtoken.approve(address(gtStaking), 30 ether);

        vm.prank(user2);
        gtStaking.stake(30 ether);

        vm.prank(registry);
        gtStaking.lockStake(user2, ROLE_COMMUNITY, 30 ether, 3 ether);

        assertEq(gtStaking.getLockedBalance(user2), 27 ether);
        assertEq(gtStaking.getTotalBurned(user2), 3 ether);
    }

    function test_lockStake_burnToZeroDead() public {
        uint256 balanceBefore = gtoken.balanceOf(address(0xdEaD));

        vm.prank(user1);
        gtoken.approve(address(gtStaking), 0.3 ether);

        vm.prank(user1);
        gtStaking.stake(0.3 ether);

        vm.prank(registry);
        gtStaking.lockStake(user1, ROLE_ENDUSER, 0.3 ether, 0.1 ether);

        uint256 balanceAfter = gtoken.balanceOf(address(0xdEaD));
        assertEq(balanceAfter - balanceBefore, 0.1 ether, "0.1 GT should be burned");
    }

    function test_lockStake_unauthorized() public {
        vm.prank(user1);
        gtoken.approve(address(gtStaking), 0.3 ether);

        vm.prank(user1);
        gtStaking.stake(0.3 ether);

        vm.prank(user1);
        vm.expectRevert("Unauthorized locker");
        gtStaking.lockStake(user1, ROLE_ENDUSER, 0.3 ether, 0.1 ether);
    }

    function test_lockStake_insufficientStake() public {
        vm.prank(user1);
        gtoken.approve(address(gtStaking), 0.1 ether);

        vm.prank(user1);
        gtStaking.stake(0.1 ether);

        vm.prank(registry);
        vm.expectRevert();
        gtStaking.lockStake(user1, ROLE_ENDUSER, 0.3 ether, 0.1 ether);
    }

    function test_lockStake_burnEqualsStake() public {
        vm.prank(user1);
        gtoken.approve(address(gtStaking), 0.3 ether);

        vm.prank(user1);
        gtStaking.stake(0.3 ether);

        vm.prank(registry);
        vm.expectRevert();
        gtStaking.lockStake(user1, ROLE_ENDUSER, 0.3 ether, 0.3 ether);
    }

    // ====================================
    // Test Suite 3: Unlock Stake
    // ====================================

    function test_unlockStake_ENDUSER() public {
        // Setup
        vm.prank(user1);
        gtoken.approve(address(gtStaking), 0.3 ether);

        vm.prank(user1);
        gtStaking.stake(0.3 ether);

        vm.prank(registry);
        gtStaking.lockStake(user1, ROLE_ENDUSER, 0.3 ether, 0.1 ether);

        // Unlock
        uint256 balanceBefore = gtoken.balanceOf(user1);

        vm.prank(registry);
        uint256 refund = gtStaking.unlockStake(
            user1,
            ROLE_ENDUSER,
            0.2 ether,
            0.05 ether
        );

        // Verify
        assertEq(refund, 0.15 ether, "Refund should be 0.15");
        uint256 balanceAfter = gtoken.balanceOf(user1);
        assertEq(balanceAfter - balanceBefore, 0.15 ether, "User should receive 0.15");
    }

    function test_unlockStake_COMMUNITY() public {
        vm.prank(user2);
        gtoken.approve(address(gtStaking), 30 ether);

        vm.prank(user2);
        gtStaking.stake(30 ether);

        vm.prank(registry);
        gtStaking.lockStake(user2, ROLE_COMMUNITY, 30 ether, 3 ether);

        uint256 refundBefore = gtoken.balanceOf(user2);

        vm.prank(registry);
        uint256 refund = gtStaking.unlockStake(
            user2,
            ROLE_COMMUNITY,
            27 ether,
            2.7 ether  // 10% of 27
        );

        assertEq(refund, 24.3 ether);
        uint256 refundAfter = gtoken.balanceOf(user2);
        assertEq(refundAfter - refundBefore, 24.3 ether);
    }

    function test_unlockStake_feeToTreasury() public {
        vm.prank(user1);
        gtoken.approve(address(gtStaking), 0.3 ether);

        vm.prank(user1);
        gtStaking.stake(0.3 ether);

        vm.prank(registry);
        gtStaking.lockStake(user1, ROLE_ENDUSER, 0.3 ether, 0.1 ether);

        uint256 treasuryBefore = gtoken.balanceOf(treasury);

        vm.prank(registry);
        gtStaking.unlockStake(user1, ROLE_ENDUSER, 0.2 ether, 0.05 ether);

        uint256 treasuryAfter = gtoken.balanceOf(treasury);
        assertEq(treasuryAfter - treasuryBefore, 0.05 ether, "Fee should go to treasury");
    }

    function test_unlockStake_insufficientLocked() public {
        vm.prank(user1);
        gtoken.approve(address(gtStaking), 0.3 ether);

        vm.prank(user1);
        gtStaking.stake(0.3 ether);

        vm.prank(registry);
        gtStaking.lockStake(user1, ROLE_ENDUSER, 0.3 ether, 0.1 ether);

        vm.prank(registry);
        vm.expectRevert();
        gtStaking.unlockStake(user1, ROLE_ENDUSER, 1 ether, 0.1 ether);
    }

    // ====================================
    // Test Suite 4: Burn Recording
    // ====================================

    function test_recordBurn_entry() public {
        vm.prank(user1);
        gtoken.approve(address(gtStaking), 0.3 ether);

        vm.prank(user1);
        gtStaking.stake(0.3 ether);

        vm.prank(registry);
        gtStaking.lockStake(user1, ROLE_ENDUSER, 0.3 ether, 0.1 ether);

        uint256 totalBurned = gtStaking.getTotalBurned(user1);
        assertEq(totalBurned, 0.1 ether);
    }

    function test_recordBurn_exit() public {
        vm.prank(user1);
        gtoken.approve(address(gtStaking), 0.3 ether);

        vm.prank(user1);
        gtStaking.stake(0.3 ether);

        vm.prank(registry);
        gtStaking.lockStake(user1, ROLE_ENDUSER, 0.3 ether, 0.1 ether);

        vm.prank(registry);
        gtStaking.unlockStake(user1, ROLE_ENDUSER, 0.2 ether, 0.05 ether);

        uint256 totalBurned = gtStaking.getTotalBurned(user1);
        assertEq(totalBurned, 0.15 ether, "Entry + exit fee");
    }

    function test_getBurnHistory() public {
        vm.prank(user1);
        gtoken.approve(address(gtStaking), 0.3 ether);

        vm.prank(user1);
        gtStaking.stake(0.3 ether);

        vm.prank(registry);
        gtStaking.lockStake(user1, ROLE_ENDUSER, 0.3 ether, 0.1 ether);

        vm.prank(registry);
        gtStaking.unlockStake(user1, ROLE_ENDUSER, 0.2 ether, 0.05 ether);

        GTokenStaking.BurnRecord[] memory history = gtStaking.getBurnHistory(user1);
        assertEq(history.length, 2);
        assertEq(history[0].amount, 0.1 ether);
        assertEq(history[1].amount, 0.05 ether);
    }

    // ====================================
    // Test Suite 5: View Functions
    // ====================================

    function test_getStakeInfo() public {
        vm.prank(user1);
        gtoken.approve(address(gtStaking), 0.3 ether);

        vm.prank(user1);
        gtStaking.stake(0.3 ether);

        GTokenStaking.StakeInfo memory info = gtStaking.getStakeInfo(user1);
        assertEq(info.stakedAmount, 0.3 ether);
        assertEq(info.lockedAmount, 0);
    }

    function test_getTotalBalance() public {
        vm.prank(user1);
        gtoken.approve(address(gtStaking), 0.3 ether);

        vm.prank(user1);
        gtStaking.stake(0.3 ether);

        assertEq(gtStaking.getTotalBalance(user1), 0.3 ether);
    }

    // ====================================
    // Test Suite 6: Authorization Management
    // ====================================

    function test_setLockerAuthorization() public {
        address newLocker = makeAddr("newLocker");

        vm.prank(owner);
        gtStaking.setLockerAuthorization(newLocker, true);

        assertTrue(gtStaking.authorizedLockers(newLocker));

        vm.prank(owner);
        gtStaking.setLockerAuthorization(newLocker, false);

        assertFalse(gtStaking.authorizedLockers(newLocker));
    }

    function test_setTreasury() public {
        address newTreasury = makeAddr("newTreasury");

        vm.prank(owner);
        gtStaking.setTreasury(newTreasury);

        // Unlock and verify fee goes to new treasury
        vm.prank(user1);
        gtoken.approve(address(gtStaking), 0.3 ether);

        vm.prank(user1);
        gtStaking.stake(0.3 ether);

        vm.prank(registry);
        gtStaking.lockStake(user1, ROLE_ENDUSER, 0.3 ether, 0.1 ether);

        vm.prank(registry);
        gtStaking.unlockStake(user1, ROLE_ENDUSER, 0.2 ether, 0.05 ether);

        assertEq(gtoken.balanceOf(newTreasury), 0.05 ether);
    }

    // ====================================
    // Test Suite 7: Edge Cases
    // ====================================

    function test_lockStake_zeroRole() public {
        vm.prank(user1);
        gtoken.approve(address(gtStaking), 0.3 ether);

        vm.prank(user1);
        gtStaking.stake(0.3 ether);

        vm.prank(registry);
        gtStaking.lockStake(user1, bytes32(0), 0.3 ether, 0.1 ether);

        // Should still work, roleId is just for tracking
        assertEq(gtStaking.getLockedBalance(user1), 0.2 ether);
    }

    function test_unlockStake_zeroFee() public {
        vm.prank(user1);
        gtoken.approve(address(gtStaking), 0.3 ether);

        vm.prank(user1);
        gtStaking.stake(0.3 ether);

        vm.prank(registry);
        gtStaking.lockStake(user1, ROLE_ENDUSER, 0.3 ether, 0.1 ether);

        vm.prank(registry);
        uint256 refund = gtStaking.unlockStake(user1, ROLE_ENDUSER, 0.2 ether, 0);

        assertEq(refund, 0.2 ether, "No fee should return full amount");
    }

    function test_multipleLocksUnlocks() public {
        // First lock/unlock cycle
        vm.prank(user1);
        gtoken.approve(address(gtStaking), 1 ether);

        vm.prank(user1);
        gtStaking.stake(1 ether);

        vm.prank(registry);
        gtStaking.lockStake(user1, ROLE_ENDUSER, 0.3 ether, 0.1 ether);

        vm.prank(registry);
        gtStaking.unlockStake(user1, ROLE_ENDUSER, 0.2 ether, 0.05 ether);

        // Second cycle
        vm.prank(registry);
        gtStaking.lockStake(user1, ROLE_COMMUNITY, 0.3 ether, 0.05 ether);

        vm.prank(registry);
        uint256 refund = gtStaking.unlockStake(user1, ROLE_COMMUNITY, 0.25 ether, 0.05 ether);

        assertEq(refund, 0.2 ether);
    }

    // ====================================
    // Test Suite 8: State Consistency
    // ====================================

    function test_totalStakedTracking() public {
        vm.prank(user1);
        gtoken.approve(address(gtStaking), 10 ether);

        vm.prank(user1);
        gtStaking.stake(10 ether);

        vm.prank(user2);
        gtoken.approve(address(gtStaking), 20 ether);

        vm.prank(user2);
        gtStaking.stake(20 ether);

        assertEq(gtStaking.totalStaked(), 30 ether);
    }

    function test_totalBurnedTracking() public {
        vm.prank(user1);
        gtoken.approve(address(gtStaking), 0.3 ether);

        vm.prank(user1);
        gtStaking.stake(0.3 ether);

        vm.prank(registry);
        gtStaking.lockStake(user1, ROLE_ENDUSER, 0.3 ether, 0.1 ether);

        vm.prank(user2);
        gtoken.approve(address(gtStaking), 30 ether);

        vm.prank(user2);
        gtStaking.stake(30 ether);

        vm.prank(registry);
        gtStaking.lockStake(user2, ROLE_COMMUNITY, 30 ether, 3 ether);

        assertEq(gtStaking.totalBurned(), 3.1 ether);
    }
}
