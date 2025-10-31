// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../src/paymasters/v2/core/GTokenStaking.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";

/**
 * @title GTokenStakingInvariants
 * @notice Simplified Echidna invariant tests for GTokenStaking
 * @dev Only no-argument invariants for Echidna property mode
 */
contract GTokenStakingInvariants {
    GTokenStaking public staking;
    MockGToken public gtoken;

    address public constant TREASURY = address(0x1234);
    address public constant SLASHER = address(0x5678);
    address public constant LOCKER = address(0xABCD);

    constructor() {
        gtoken = new MockGToken();
        staking = new GTokenStaking(address(gtoken));

        // Setup
        staking.setTreasury(TREASURY);
        staking.authorizeSlasher(SLASHER, true);

        // Configure locker with 1% fee
        uint256[] memory emptyTiers = new uint256[](0);
        uint256[] memory emptyFees = new uint256[](0);
        staking.configureLocker(
            LOCKER,
            true,
            100, // 1% fee
            0.01 ether,
            500,
            emptyTiers,
            emptyFees,
            address(0)
        );

        // Mint tokens for testing
        gtoken.mint(address(this), 1_000_000 ether);
        gtoken.approve(address(staking), type(uint256).max);

        // Initial stake for testing
        staking.stake(100 ether);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   CORE INVARIANTS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice INVARIANT 1: totalStaked must equal contract's GToken balance
     * @dev This is the most critical invariant - accounting must always be correct
     */
    function echidna_total_staked_equals_balance() public view returns (bool) {
        uint256 contractBalance = gtoken.balanceOf(address(staking));
        uint256 totalStaked = staking.totalStaked();
        return contractBalance == totalStaked;
    }

    /**
     * @notice INVARIANT 2: totalShares must equal totalStaked (1:1 model)
     * @dev With 1:1 shares, totalShares should always equal totalStaked
     */
    function echidna_total_shares_equals_total_staked() public view returns (bool) {
        return staking.totalShares() == staking.totalStaked();
    }

    /**
     * @notice INVARIANT 3: User balance cannot exceed their shares
     * @dev balanceOf = shares - slashedAmount, so must be <= shares
     */
    function echidna_user_balance_not_exceed_shares() public view returns (bool) {
        (,uint256 shares,,,) = staking.stakes(address(this));
        uint256 balance = staking.balanceOf(address(this));
        return balance <= shares;
    }

    /**
     * @notice INVARIANT 4: Available balance cannot exceed total balance
     * @dev availableBalance = balanceOf - totalLocked
     */
    function echidna_available_not_exceed_balance() public view returns (bool) {
        uint256 balance = staking.balanceOf(address(this));
        uint256 available = staking.availableBalance(address(this));
        return available <= balance;
    }

    /**
     * @notice INVARIANT 5: Locked amount cannot exceed balance
     */
    function echidna_locked_not_exceed_balance() public view returns (bool) {
        uint256 balance = staking.balanceOf(address(this));
        uint256 locked = staking.totalLocked(address(this));
        return locked <= balance;
    }

    /**
     * @notice INVARIANT 6: sharesToGToken is 1:1
     */
    function echidna_shares_conversion_is_one_to_one() public view returns (bool) {
        uint256 testAmount = 123 ether;
        return staking.sharesToGToken(testAmount) == testAmount;
    }

    /**
     * @notice INVARIANT 7: gTokenToShares is 1:1
     */
    function echidna_gtoken_conversion_is_one_to_one() public view returns (bool) {
        uint256 testAmount = 456 ether;
        return staking.gTokenToShares(testAmount) == testAmount;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    ACTION FUNCTIONS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Helper: Stake tokens
     */
    function stake(uint256 amount) public {
        if (amount < staking.MIN_STAKE()) return;
        if (amount > gtoken.balanceOf(address(this))) return;

        staking.stake(amount);
    }

    /**
     * @notice Helper: Request unstake
     */
    function requestUnstake() public {
        (,uint256 shares,,,) = staking.stakes(address(this));
        if (shares == 0) return;

        staking.requestUnstake();
    }
}

contract MockGToken is ERC20 {
    constructor() ERC20("GToken", "GT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
