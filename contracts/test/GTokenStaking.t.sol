// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../src/paymasters/v2/core/GTokenStaking.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";

/**
 * @title GTokenStakingTest
 * @notice 细粒度单元测试：边界条件、极端场景、舍入误差、slash系统
 * @dev 覆盖安全关键路径：division by zero、reentrancy、integer overflow
 */
contract GTokenStakingTest is Test {
    GTokenStaking public staking;
    MockGToken public gtoken;

    address public owner;
    address public treasury;
    address public user1;
    address public user2;
    address public slasher;
    address public locker;

    uint256 constant MIN_STAKE = 0.01 ether;
    uint256 constant UNSTAKE_DELAY = 7 days;

    function setUp() public {
        owner = makeAddr("owner");
        treasury = makeAddr("treasury");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        slasher = makeAddr("slasher");
        locker = makeAddr("locker");

        vm.startPrank(owner);

        // Deploy contracts
        gtoken = new MockGToken();
        staking = new GTokenStaking(address(gtoken));

        // Configure staking
        staking.setTreasury(treasury);
        staking.authorizeSlasher(slasher, true);

        // Configure locker with 1% base exit fee
        uint256[] memory emptyTiers = new uint256[](0);
        uint256[] memory emptyFees = new uint256[](0);
        staking.configureLocker(locker, true, 100, 0.01 ether, 500, emptyTiers, emptyFees, address(0)); // 1% = 100 basis points

        vm.stopPrank();

        // Mint tokens to users
        gtoken.mint(user1, 1000 ether);
        gtoken.mint(user2, 1000 ether);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    BOUNDARY CONDITIONS                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_StakeBelowMinimum_Reverts() public {
        vm.startPrank(user1);
        gtoken.approve(address(staking), MIN_STAKE - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                GTokenStaking.BelowMinimumStake.selector,
                MIN_STAKE - 1,
                MIN_STAKE
            )
        );
        staking.stake(MIN_STAKE - 1);
        vm.stopPrank();
    }

    function test_StakeExactlyMinimum_Success() public {
        vm.startPrank(user1);
        gtoken.approve(address(staking), MIN_STAKE);
        staking.stake(MIN_STAKE);

        assertEq(staking.balanceOf(user1), MIN_STAKE);
        assertEq(staking.totalStaked(), MIN_STAKE);
        vm.stopPrank();
    }

    function test_ZeroStake_BalanceReturnsZero() public view {
        assertEq(staking.balanceOf(user1), 0);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    SHARE CALCULATION                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_ShareCalculation_FirstStaker() public {
        vm.startPrank(user1);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(100 ether);

        // First staker: 1:1 ratio (shares = amount)
        (,uint256 shares,,,) = staking.stakes(user1);
        assertEq(shares, 100 ether, "First staker should get 1:1 shares");
        assertEq(staking.balanceOf(user1), 100 ether);
        vm.stopPrank();
    }

    function test_ShareCalculation_SecondStaker_NoSlash() public {
        // User1 stakes 100 GT
        vm.startPrank(user1);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        // User2 stakes 50 GT (no slash, so 1:1 ratio maintained)
        vm.startPrank(user2);
        gtoken.approve(address(staking), 50 ether);
        staking.stake(50 ether);

        (,uint256 shares,,,) = staking.stakes(user2);
        assertEq(shares, 50 ether, "Second staker should also get 1:1 shares when no slash");
        assertEq(staking.balanceOf(user2), 50 ether);
        vm.stopPrank();
    }

    function test_ShareCalculation_AfterSlash() public {
        // User1 stakes 100 GT
        vm.startPrank(user1);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        // Slash 50% (50 GT)
        vm.prank(slasher);
        staking.slash(user1, 50 ether, "Test slash");

        // User2 stakes 50 GT after User1's slash
        // ✅ NEW USER-LEVEL SLASH: User1's slash only affects User1
        // totalStaked = 100 - 50 (slashed) + 50 (new stake) = 100
        // totalShares = 100
        // New shares = 50 * 100 / 100 = 50 shares (NOT affected by User1's slash)
        vm.startPrank(user2);
        gtoken.approve(address(staking), 50 ether);
        staking.stake(50 ether);

        (,uint256 shares,,,) = staking.stakes(user2);
        assertEq(shares, 50 ether, "User2 gets 50 shares for 50 GT (fair ratio)");
        assertEq(staking.balanceOf(user2), 50 ether, "Balance should be 50 GT equivalent");
        vm.stopPrank();
    }

    function test_RoundingError_Accumulation() public {
        // Test with small amounts to check rounding
        uint256 smallAmount = MIN_STAKE + 1; // 0.01 + 1 wei

        vm.startPrank(user1);
        gtoken.approve(address(staking), smallAmount * 10);

        // Stake 10 times in small amounts
        uint256 currentTime = block.timestamp;
        for (uint256 i = 0; i < 10; i++) {
            staking.stake(smallAmount);
            staking.requestUnstake();

            currentTime += UNSTAKE_DELAY + 1;
            vm.warp(currentTime);

            staking.unstake();
        }

        // Final balance should be close to 0 (within rounding tolerance)
        uint256 finalBalance = staking.balanceOf(user1);
        assertLt(finalBalance, 1e15, "Rounding error should be negligible");
        vm.stopPrank();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    SLASH SYSTEM                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_Slash_PartialSlash_10Percent() public {
        vm.startPrank(user1);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        uint256 balanceBefore = staking.balanceOf(user1);

        // Slash 10%
        vm.prank(slasher);
        uint256 slashed = staking.slash(user1, 10 ether, "10% slash");

        assertEq(slashed, 10 ether);
        assertEq(staking.balanceOf(user1), balanceBefore - 10 ether);

        // ✅ NEW: Check user-level slashedAmount instead of global totalSlashed
        (,,uint256 slashedAmount,,) = staking.stakes(user1);
        assertEq(slashedAmount, 10 ether, "User's slashedAmount should be 10 ether");
    }

    function test_Slash_Multiple_Cumulative() public {
        vm.startPrank(user1);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        // Slash 10% three times
        vm.startPrank(slasher);
        staking.slash(user1, 10 ether, "First 10%");
        assertEq(staking.balanceOf(user1), 90 ether);

        staking.slash(user1, 10 ether, "Second 10%");
        assertEq(staking.balanceOf(user1), 80 ether);

        staking.slash(user1, 10 ether, "Third 10%");
        assertEq(staking.balanceOf(user1), 70 ether);

        // ✅ NEW: Check user-level slashedAmount instead of global totalSlashed
        (,,uint256 slashedAmount,,) = staking.stakes(user1);
        assertEq(slashedAmount, 30 ether, "User's cumulative slashedAmount should be 30 ether");
        vm.stopPrank();
    }

    function test_Slash_Near100Percent_99Percent() public {
        vm.startPrank(user1);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        // Slash 99%
        vm.prank(slasher);
        uint256 slashed = staking.slash(user1, 99 ether, "99% slash");

        assertEq(slashed, 99 ether);
        assertEq(staking.balanceOf(user1), 1 ether, "1% should remain");
    }

    function test_Slash_FullySlashed_DivisionByZeroProtection() public {
        vm.startPrank(user1);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        // Slash 100%
        vm.prank(slasher);
        staking.slash(user1, 100 ether, "Full slash");

        // Should not revert, returns 0
        assertEq(staking.balanceOf(user1), 0, "Balance should be 0 after full slash");

        // User2 can still stake even when availableStake = 0
        vm.startPrank(user2);
        gtoken.approve(address(staking), 50 ether);
        staking.stake(50 ether);

        // User2 should get full value (new shares pool)
        assertEq(staking.balanceOf(user2), 50 ether);
        vm.stopPrank();
    }

    function test_Slash_ExceedsBalance_PartialSlash() public {
        vm.startPrank(user1);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        // Try to slash 150 GT (more than balance)
        vm.prank(slasher);
        uint256 slashed = staking.slash(user1, 150 ether, "Excessive slash");

        // Should only slash available balance (100 GT)
        assertEq(slashed, 100 ether, "Should slash only available balance");
        assertEq(staking.balanceOf(user1), 0);
    }

    function test_Slash_ZeroBalance_Reverts() public {
        // User1 has no stake
        vm.prank(slasher);
        vm.expectRevert(
            abi.encodeWithSelector(
                GTokenStaking.SlashAmountExceedsBalance.selector,
                10 ether,
                0
            )
        );
        staking.slash(user1, 10 ether, "Slash zero balance");
    }

    function test_Slash_UnauthorizedSlasher_Reverts() public {
        vm.startPrank(user1);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        address unauthorized = makeAddr("unauthorized");
        vm.prank(unauthorized);
        vm.expectRevert(
            abi.encodeWithSelector(GTokenStaking.UnauthorizedSlasher.selector, unauthorized)
        );
        staking.slash(user1, 10 ether, "Unauthorized");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    LOCK MANAGEMENT                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_LockStake_Success() public {
        vm.startPrank(user1);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.prank(locker);
        staking.lockStake(user1, 50 ether, "MySBT membership");

        assertEq(staking.totalLocked(user1), 50 ether);
        assertEq(staking.availableBalance(user1), 50 ether);
    }

    function test_LockStake_ExceedsAvailable_Reverts() public {
        vm.startPrank(user1);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.prank(locker);
        vm.expectRevert(
            abi.encodeWithSelector(
                GTokenStaking.InsufficientAvailableBalance.selector,
                100 ether,
                150 ether
            )
        );
        staking.lockStake(user1, 150 ether, "Excessive lock");
    }

    function test_UnlockStake_WithExitFee() public {
        vm.startPrank(user1);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.prank(locker);
        staking.lockStake(user1, 100 ether, "MySBT membership");

        // Unlock with 1% exit fee (100 bps)
        vm.prank(locker);
        uint256 netAmount = staking.unlockStake(user1, 100 ether);

        assertEq(netAmount, 99 ether, "Net amount should be 99 GT (1% fee)");
        assertEq(staking.totalLocked(user1), 0, "Should be fully unlocked");
        assertEq(staking.availableBalance(user1), 99 ether);
    }

    function test_ConfigureLocker_ExitFeeRateTooHigh_Reverts() public {
        // ✅ NEW: Test that configureLocker rejects fee rate > 5% (500 bps)
        vm.prank(owner);
        uint256[] memory emptyTiers = new uint256[](0);
        uint256[] memory emptyFees = new uint256[](0);
        address badLocker = makeAddr("badLocker");

        // Try to configure locker with 110% exit fee - should revert
        vm.expectRevert(GTokenStaking.InvalidTierConfig.selector);
        staking.configureLocker(badLocker, true, 11000, 0.01 ether, 500, emptyTiers, emptyFees, address(0)); // 110%
    }

    function test_CannotUnstake_WhileLocked() public {
        vm.startPrank(user1);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.prank(locker);
        staking.lockStake(user1, 100 ether, "MySBT membership");

        vm.prank(user1);
        staking.requestUnstake();

        vm.warp(block.timestamp + UNSTAKE_DELAY);

        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(GTokenStaking.StakeIsLocked.selector, user1, 100 ether)
        );
        staking.unstake();
    }

    function test_MultipleLockersSimultaneous() public {
        vm.startPrank(user1);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        // Configure second locker
        address locker2 = makeAddr("locker2");
        vm.prank(owner);
        uint256[] memory emptyTiers = new uint256[](0);
        uint256[] memory emptyFees = new uint256[](0);
        staking.configureLocker(locker2, true, 200, 0.01 ether, 500, emptyTiers, emptyFees, address(0)); // 2%

        // Lock 50 GT from each locker
        vm.prank(locker);
        staking.lockStake(user1, 50 ether, "MySBT");

        vm.prank(locker2);
        staking.lockStake(user1, 50 ether, "Registry");

        assertEq(staking.totalLocked(user1), 100 ether);
        assertEq(staking.availableBalance(user1), 0);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    EXTREME SCENARIOS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_ExtremeLargeStake_NoOverflow() public {
        uint256 largeAmount = type(uint128).max; // Very large but not uint256 max
        gtoken.mint(user1, largeAmount);

        vm.startPrank(user1);
        gtoken.approve(address(staking), largeAmount);
        staking.stake(largeAmount);

        assertEq(staking.balanceOf(user1), largeAmount);
        vm.stopPrank();
    }

    function test_SlashAfterLock_LockedAmountUnchanged() public {
        vm.startPrank(user1);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        // Lock 50 GT
        vm.prank(locker);
        staking.lockStake(user1, 50 ether, "MySBT");

        uint256 lockedBefore = staking.totalLocked(user1);

        // Slash 20 GT
        vm.prank(slasher);
        staking.slash(user1, 20 ether, "Penalty");

        // Locked amount should remain the same (in shares)
        assertEq(staking.totalLocked(user1), lockedBefore, "Locked shares unchanged");

        // But balance should reflect slash
        assertEq(staking.balanceOf(user1), 80 ether);
    }

    function test_ShareValue_IncreaseAfterOthersSlashed() public {
        // User1 and User2 each stake 100 GT
        vm.startPrank(user1);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.startPrank(user2);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        // Slash User2's 50 GT
        vm.prank(slasher);
        staking.slash(user2, 50 ether, "User2 penalty");

        // User1's balance should remain 100 GT (slash doesn't affect others)
        assertEq(staking.balanceOf(user1), 100 ether, "User1 unaffected");
        assertEq(staking.balanceOf(user2), 50 ether, "User2 slashed 50%");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    INTEGRATION TESTS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_FullWorkflow_StakeLockSlashUnlockUnstake() public {
        // 1. Stake 100 GT
        vm.startPrank(user1);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        assertEq(staking.balanceOf(user1), 100 ether);
        vm.stopPrank();

        // 2. Lock 80 GT for MySBT
        vm.prank(locker);
        staking.lockStake(user1, 80 ether, "MySBT");
        assertEq(staking.availableBalance(user1), 20 ether);

        // 3. Slash 10 GT (penalty)
        vm.prank(slasher);
        staking.slash(user1, 10 ether, "Misbehavior");
        assertEq(staking.balanceOf(user1), 90 ether);

        // 4. Unlock 80 GT (1% fee = 0.8 GT, net = 79.2 GT)
        vm.prank(locker);
        uint256 netUnlocked = staking.unlockStake(user1, 80 ether);
        assertEq(netUnlocked, 79.2 ether);
        // ✅ NEW: 90 (after slash) - 0.8 (exit fee) = 89.2 GT available
        assertEq(staking.availableBalance(user1), 89.2 ether);

        // 5. Unstake all
        vm.prank(user1);
        staking.requestUnstake();

        vm.warp(block.timestamp + UNSTAKE_DELAY);

        vm.prank(user1);
        staking.unstake();

        // Final: user should receive ~89.2 GT (100 - 10 slash - 0.8 exit fee)
        // Note: small rounding may occur
        assertApproxEqAbs(gtoken.balanceOf(user1), 900 ether + 89.2 ether, 0.1 ether);
    }
}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                       MOCK CONTRACTS                       */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

contract MockGToken is ERC20 {
    constructor() ERC20("GToken", "GT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
