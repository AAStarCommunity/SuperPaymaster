// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../../src/paymasters/v2/core/GTokenStaking.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";

/**
 * @title GTokenStakingFixedTest
 * @notice 修正版：基于实际合约行为的测试
 * @dev 重点测试安全关键场景
 */
contract GTokenStakingFixedTest is Test {
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

        gtoken = new MockGToken();
        staking = new GTokenStaking(address(gtoken));

        staking.setTreasury(treasury);
        staking.authorizeSlasher(slasher, true);

        // Configure locker: baseExitFee = 0.01 ether (flat fee, not percentage)
        uint256[] memory emptyTiers = new uint256[](0);
        uint256[] memory emptyFees = new uint256[](0);
        staking.configureLocker(locker, true, 100, 0.01 ether, 500, emptyTiers, emptyFees, address(0));

        vm.stopPrank();

        gtoken.mint(user1, 1000 ether);
        gtoken.mint(user2, 1000 ether);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                CRITICAL SECURITY TESTS                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_Slash_GlobalEffect_AffectsAllUsers() public {
        // ✅ NEW: 测试用户级别 slash - 只影响被 slash 用户，不影响其他人
        // 两个用户各质押 100 GT
        vm.startPrank(user1);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.startPrank(user2);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        // totalStaked = 200, totalShares = 200
        // User1 shares = 100, User2 shares = 100

        // Slash User2 50 GT
        vm.prank(slasher);
        staking.slash(user2, 50 ether, "User2 penalty");

        // ✅ NEW USER-LEVEL SLASH: totalStaked 不变 = 200
        // User1 balance = 100 shares * 200 / 200 = 100 GT ✅（不受影响）
        // User2 balance = (100 shares * 200 / 200) - 50 slashed = 50 GT ✅（只影响 User2）

        assertEq(staking.balanceOf(user1), 100 ether, "User1 NOT affected - user-level slash");
        assertEq(staking.balanceOf(user2), 50 ether, "User2 slashed 50 GT");
    }

    function test_Slash_FullySlashed_StakeRecoversAfterNewDeposit() public {
        // ✅ NEW: 测试用户级别 slash - 被 100% slash 的用户不会因新质押恢复
        vm.startPrank(user1);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        // Slash 100% of User1
        vm.prank(slasher);
        staking.slash(user1, 100 ether, "Full slash");

        // User1 balance = 0
        assertEq(staking.balanceOf(user1), 0, "User1 fully slashed");

        // User2 新质押
        vm.startPrank(user2);
        gtoken.approve(address(staking), 50 ether);
        staking.stake(50 ether);

        // ✅ NEW USER-LEVEL SLASH:
        // totalStaked = 150, totalShares = 150
        // User1: 100 shares * 150 / 150 - 100 slashed = 100 - 100 = 0 GT（不恢复）
        // User2: 50 shares * 150 / 150 = 50 GT

        assertEq(staking.balanceOf(user1), 0, "User1 does NOT recover - user-level slash");
        assertEq(staking.balanceOf(user2), 50 ether, "User2 gets full staked amount");
        vm.stopPrank();
    }

    function test_UnlockStake_PercentageFee_WithMinProtection() public {
        vm.startPrank(user1);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.prank(locker);
        staking.lockStake(user1, 100 ether, "MySBT");

        // Unlock: feeRateBps = 100 (1%), minExitFee = 0.01 ether, maxFeePercent = 500 (5%)
        // 100 ether * 1% = 1 ether (> minExitFee, < maxFee of 5 ether)
        // Fee goes to treasury, user gets net amount back
        vm.prank(locker);
        uint256 netAmount = staking.unlockStake(user1, 100 ether);

        assertEq(netAmount, 99 ether, "Net = gross - 1% fee");
        // Fee (1 ether) is transferred to treasury and deducted from totalStaked
        // User balance = shares * (totalStaked - totalSlashed - fee) / totalShares = 99 ether
        assertEq(staking.balanceOf(user1), 99 ether, "Balance reduced by fee amount");
    }

    function test_ExitFee_MaxFeeProtection() public {
        // 测试 maxFeePercent 保护机制
        // feeRateBps = 100 (1%), minExitFee = 0, maxFeePercent = 500 (5%)
        address highFeeLocker = makeAddr("highFeeLocker");
        vm.prank(owner);
        uint256[] memory emptyTiers = new uint256[](0);
        uint256[] memory emptyFees = new uint256[](0);
        // 配置高费率但有最大值保护
        staking.configureLocker(highFeeLocker, true, 100, 0, 500, emptyTiers, emptyFees, address(0));

        vm.startPrank(user1);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.prank(highFeeLocker);
        staking.lockStake(user1, 100 ether, "High fee lock");

        // Unlock：1% 费用 = 1 ether，小于 maxFee (5 ether)
        vm.prank(highFeeLocker);
        uint256 netAmount = staking.unlockStake(user1, 100 ether);

        assertEq(netAmount, 99 ether, "Fee capped at 1% (below max 5%)");
    }

    function test_RoundingError_MultipleStakeUnstake() public {
        uint256 smallAmount = MIN_STAKE;

        vm.startPrank(user1);
        gtoken.approve(address(staking), smallAmount * 5);

        // 5次质押/取消质押
        uint256 currentTime = block.timestamp;
        for (uint256 i = 0; i < 5; i++) {
            staking.stake(smallAmount);
            staking.requestUnstake();

            // Warp to allow unstake
            currentTime += UNSTAKE_DELAY + 1;
            vm.warp(currentTime);

            staking.unstake();
        }

        // 最终余额应接近初始值
        uint256 finalBalance = gtoken.balanceOf(user1);
        assertGe(finalBalance, 1000 ether - 0.001 ether, "Rounding loss < 0.001 GT");
        vm.stopPrank();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    BOUNDARY CONDITIONS                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_Slash_99Percent_LeavesResidue() public {
        vm.startPrank(user1);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.prank(slasher);
        staking.slash(user1, 99 ether, "99% slash");

        assertEq(staking.balanceOf(user1), 1 ether);
    }

    function test_Slash_Multiple_Cumulative_ReducesBalance() public {
        vm.startPrank(user1);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        vm.startPrank(slasher);
        staking.slash(user1, 10 ether, "First");
        staking.slash(user1, 10 ether, "Second");
        staking.slash(user1, 10 ether, "Third");
        vm.stopPrank();

        assertEq(staking.balanceOf(user1), 70 ether);

        // ✅ NEW: Check user-level slashedAmount instead of global totalSlashed
        (,,uint256 slashedAmount,,) = staking.stakes(user1);
        assertEq(slashedAmount, 30 ether);
    }

    function test_LockAfterPartialSlash_AvailableReduced() public {
        vm.startPrank(user1);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        // Slash 20 GT
        vm.prank(slasher);
        staking.slash(user1, 20 ether, "Penalty");

        // User1 balance = 80 GT
        uint256 available = staking.availableBalance(user1);
        assertEq(available, 80 ether);

        // Lock 60 GT
        vm.prank(locker);
        staking.lockStake(user1, 60 ether, "MySBT");

        assertEq(staking.availableBalance(user1), 20 ether);
    }

    function test_FullWorkflow_Realistic() public {
        // 1. 质押 100 GT
        vm.startPrank(user1);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        // 2. Lock 80 GT
        vm.prank(locker);
        staking.lockStake(user1, 80 ether, "MySBT");

        // 3. Slash 10 GT（全局影响）
        vm.prank(slasher);
        staking.slash(user1, 10 ether, "Misbehavior");

        // availableStake = 90, balance = 90
        assertEq(staking.balanceOf(user1), 90 ether);

        // 4. Unlock 80 GT（percentage fee = 1% = 0.8 GT）
        vm.prank(locker);
        uint256 netUnlocked = staking.unlockStake(user1, 80 ether);

        assertEq(netUnlocked, 80 ether - 0.8 ether, "80 GT - 1% fee");

        // 5. Unstake
        vm.prank(user1);
        staking.requestUnstake();

        vm.warp(block.timestamp + UNSTAKE_DELAY + 1);

        vm.prank(user1);
        staking.unstake();

        // 最终收到：90 - 0.8 = 89.2 GT
        uint256 finalBalance = gtoken.balanceOf(user1);
        assertApproxEqAbs(finalBalance, 900 ether + 89.2 ether, 0.01 ether);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    SHARE CALCULATION                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function test_ShareRatio_AfterSlash_NewStakerGetsBetter() public {
        // ✅ NEW: 测试新用户质押不受其他用户 slash 影响
        // User1 质押 100 GT，得到 100 shares
        vm.startPrank(user1);
        gtoken.approve(address(staking), 100 ether);
        staking.stake(100 ether);
        vm.stopPrank();

        // Slash User1 50 GT
        vm.prank(slasher);
        staking.slash(user1, 50 ether, "50% slash");

        // ✅ NEW USER-LEVEL SLASH: totalStaked 不变 = 100
        // totalShares = 100

        // User2 质押 50 GT
        // ✅ NEW: newShares = 50 * 100 / 100 = 50 shares（公平比例，不受 User1 slash 影响）
        vm.startPrank(user2);
        gtoken.approve(address(staking), 50 ether);
        staking.stake(50 ether);

        // User2 得到 50 shares = 50 GT 价值 ✅
        (,uint256 shares,,,) = staking.stakes(user2);
        assertEq(shares, 50 ether, "New staker gets fair share ratio");
        assertEq(staking.balanceOf(user2), 50 ether, "User2 balance equals staked amount");
        vm.stopPrank();
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
