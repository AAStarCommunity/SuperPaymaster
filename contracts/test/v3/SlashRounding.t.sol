// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/core/GTokenStaking.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";

/// @dev Minimal ERC20 for tests
contract MockGToken2 is ERC20 {
    constructor() ERC20("GToken", "GT") {
        _mint(msg.sender, 21_000_000 ether);
    }
}

/// @dev Stub Registry that accepts syncStakeFromStaking calls
contract StubRegistry {
    function syncStakeFromStaking(address, bytes32, uint256) external {}
    function getEffectiveStake(address, bytes32) external pure returns (uint256) { return 0; }
}

/**
 * @title SlashRoundingTest
 * @notice H-2 fix: GTokenStaking.slash() distributes rounding dust to the last non-zero role lock.
 *         Invariant: sum(roleLocks) == stakes.amount at all times after a slash.
 */
contract SlashRoundingTest is Test {
    GTokenStaking internal staking;
    MockGToken2  internal gtoken;
    StubRegistry internal reg;

    address internal constant OWNER    = address(0x1);
    address internal constant TREASURY = address(0x2);
    address internal constant USER     = address(0x10);

    bytes32 internal constant ROLE_A = keccak256("ROLE_A");
    bytes32 internal constant ROLE_B = keccak256("ROLE_B");
    bytes32 internal constant ROLE_C = keccak256("ROLE_C");

    function setUp() public {
        vm.startPrank(OWNER);
        gtoken = new MockGToken2();
        reg = new StubRegistry();
        staking = new GTokenStaking(address(gtoken), TREASURY, address(reg));
        staking.setAuthorizedSlasher(OWNER, true);
        vm.stopPrank();
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    /// @dev Fund user and have Registry lock three roles (1 ether each).
    function _lockThreeRoles() internal {
        // Transfer tokens to USER so they can approve
        vm.prank(OWNER);
        gtoken.transfer(USER, 3 ether);

        vm.startPrank(address(reg));
        // lockStakeWithTicket requires onlyRegistry; we call from reg address
        vm.stopPrank();

        // We need registry (address(reg)) to call lockStakeWithTicket.
        // Impersonate registry address.
        vm.startPrank(address(reg));
        // USER must have tokens approved to staking
        vm.stopPrank();

        // Give USER tokens and approve staking
        vm.prank(USER);
        gtoken.approve(address(staking), 3 ether);

        // Lock each role (1 ether each, 0 ticket)
        vm.prank(address(reg));
        staking.lockStakeWithTicket(USER, ROLE_A, 1 ether, 0, USER);
        vm.prank(address(reg));
        staking.lockStakeWithTicket(USER, ROLE_B, 1 ether, 0, USER);
        vm.prank(address(reg));
        staking.lockStakeWithTicket(USER, ROLE_C, 1 ether, 0, USER);
    }

    /// @dev Sum all current role lock amounts for USER.
    function _sumLocks() internal view returns (uint256 sum) {
        sum = _lockAmt(ROLE_A) + _lockAmt(ROLE_B) + _lockAmt(ROLE_C);
    }

    function _lockAmt(bytes32 role) internal view returns (uint256 amt) {
        // roleLocks returns a storage struct; use getLockedStake which returns uint256
        amt = staking.getLockedStake(USER, role);
    }

    // -----------------------------------------------------------------------
    // Tests
    // -----------------------------------------------------------------------

    /**
     * @notice After slash, sum(roleLocks) must equal stakes.amount (no dust leakage).
     */
    function test_H2_NoDustLeakageAfterSlash() public {
        _lockThreeRoles();

        // Precondition: 3 ether locked, stakes.amount == 3 ether
        assertEq(staking.balanceOf(USER), 3 ether, "initial balance");
        assertEq(_sumLocks(), 3 ether, "initial sum locks");

        // Slash 1 token (creates rounding: floor(1/3)*3 < 1)
        vm.prank(OWNER);
        uint256 slashed = staking.slash(USER, 1 ether, "test");
        assertEq(slashed, 1 ether, "full slash executed");

        uint256 stakeBal = staking.balanceOf(USER);
        uint256 lockSum  = _sumLocks();

        // Core invariant: sum of role locks == stakes.amount
        assertEq(lockSum, stakeBal, "H-2: sum(roleLocks) must equal stakes.amount");
        assertEq(stakeBal, 2 ether, "balance reduced by slashed amount");
    }

    /**
     * @notice Slash with an amount that creates maximum dust (amount = totalAmountAcrossLocks - 1).
     */
    function test_H2_SlashAllButOne() public {
        _lockThreeRoles();

        // Slash 2 ether out of 3
        vm.prank(OWNER);
        staking.slash(USER, 2 ether, "test2");

        uint256 stakeBal = staking.balanceOf(USER);
        uint256 lockSum  = _sumLocks();
        assertEq(lockSum, stakeBal, "H-2: invariant holds after 2/3 slash");
        assertEq(stakeBal, 1 ether);
    }

    /**
     * @notice Multiple sequential slashes should never accumulate dust.
     */
    function test_H2_MultipleSequentialSlashes() public {
        _lockThreeRoles();

        vm.startPrank(OWNER);
        staking.slash(USER, 1 ether, "slash1");
        staking.slash(USER, 1 ether, "slash2");
        vm.stopPrank();

        uint256 stakeBal = staking.balanceOf(USER);
        uint256 lockSum  = _sumLocks();
        assertEq(lockSum, stakeBal, "H-2: invariant holds after two sequential slashes");
        assertEq(stakeBal, 1 ether);
    }

    /**
     * @notice After full slash + role exits, no underflow occurs.
     */
    function test_H2_NoUnderflowOnExitAfterSlash() public {
        _lockThreeRoles();

        // Partial slash (creates dust in floor division)
        vm.prank(OWNER);
        staking.slash(USER, 1 ether, "partial");

        // Now exit remaining roles — should not underflow
        vm.startPrank(address(reg));
        staking.unlockAndTransfer(USER, ROLE_A);
        staking.unlockAndTransfer(USER, ROLE_B);
        staking.unlockAndTransfer(USER, ROLE_C);
        vm.stopPrank();

        assertEq(staking.balanceOf(USER), 0, "all stake exited, no underflow");
    }
}
