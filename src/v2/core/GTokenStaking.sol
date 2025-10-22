// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title GTokenStaking
 * @notice Staking contract for GToken with slash-aware share calculation
 * @dev Implements sGToken (staked GToken) share system with automatic slash distribution
 *
 * Key Features:
 * - GToken → sGToken conversion with dynamic shares
 * - Slash-aware balance calculation: balanceOf = shares * (totalStaked - totalSlashed) / totalShares
 * - 7-day unstake delay for security
 * - 30 GT minimum stake requirement
 * - Only SuperPaymaster can execute slash
 *
 * Share Mechanism:
 * - When slashing occurs, totalSlashed increases
 * - All stakers automatically share the loss proportionally via share-based calculation
 * - Individual shares remain constant, but share value decreases
 */
contract GTokenStaking is Ownable {
    using SafeERC20 for IERC20;

    // ====================================
    // Structs
    // ====================================

    struct StakeInfo {
        uint256 amount;             // Original staked GToken amount
        uint256 sGTokenShares;      // User's sGToken shares
        uint256 stakedAt;           // Stake timestamp
        uint256 unstakeRequestedAt; // Unstake request timestamp (0 = not requested)
    }

    // ====================================
    // Storage
    // ====================================

    /// @notice User stake information
    mapping(address => StakeInfo) public stakes;

    /// @notice Total amount of GToken staked
    uint256 public totalStaked;

    /// @notice Total amount of GToken slashed
    uint256 public totalSlashed;

    /// @notice Total sGToken shares issued
    uint256 public totalShares;

    /// @notice GToken ERC20 contract address
    address public immutable GTOKEN;

    /// @notice SuperPaymaster contract address (only authorized slasher)
    address public SUPERPAYMASTER;

    /// @notice 7-day delay before unstaking
    uint256 public constant UNSTAKE_DELAY = 7 days;

    /// @notice Minimum stake amount: 30 GToken
    uint256 public constant MIN_STAKE = 30 ether;

    // ====================================
    // Events
    // ====================================

    event Staked(
        address indexed user,
        uint256 amount,
        uint256 shares,
        uint256 timestamp
    );

    event UnstakeRequested(
        address indexed user,
        uint256 requestTime
    );

    event Unstaked(
        address indexed user,
        uint256 originalAmount,
        uint256 actualAmount,
        uint256 timestamp
    );

    event Slashed(
        address indexed operator,
        uint256 amount,
        string reason,
        uint256 timestamp
    );

    event SuperPaymasterUpdated(
        address indexed oldAddress,
        address indexed newAddress
    );

    // ====================================
    // Errors
    // ====================================

    error BelowMinimumStake(uint256 amount, uint256 minimum);
    error AlreadyStaked(address user);
    error NoStakeFound(address user);
    error UnstakeNotRequested(address user);
    error UnstakeDelayNotPassed(uint256 remainingTime);
    error UnauthorizedSlasher(address caller);
    error SlashAmountExceedsBalance(uint256 amount, uint256 balance);
    error InvalidAddress(address addr);

    // ====================================
    // Constructor
    // ====================================

    /**
     * @notice Initialize GTokenStaking contract
     * @param _gtoken GToken ERC20 contract address
     */
    constructor(address _gtoken) Ownable(msg.sender) {
        if (_gtoken == address(0)) revert InvalidAddress(_gtoken);
        GTOKEN = _gtoken;
    }

    // ====================================
    // Core Functions
    // ====================================

    /**
     * @notice Stake GToken and receive sGToken shares
     * @param amount Amount of GToken to stake (must be >= 30 GT)
     * @return shares Number of sGToken shares received
     * @dev Share calculation:
     *      - First stake: shares = amount
     *      - Subsequent: shares = amount * totalShares / (totalStaked - totalSlashed)
     */
    function stake(uint256 amount) external returns (uint256 shares) {
        if (amount < MIN_STAKE) {
            revert BelowMinimumStake(amount, MIN_STAKE);
        }

        if (stakes[msg.sender].sGTokenShares > 0) {
            revert AlreadyStaked(msg.sender);
        }

        // Transfer GToken from user
        IERC20(GTOKEN).safeTransferFrom(msg.sender, address(this), amount);

        // Calculate shares (slash-aware)
        if (totalShares == 0) {
            shares = amount;
        } else {
            shares = amount * totalShares / (totalStaked - totalSlashed);
        }

        // Update user stake info
        stakes[msg.sender] = StakeInfo({
            amount: amount,
            sGTokenShares: shares,
            stakedAt: block.timestamp,
            unstakeRequestedAt: 0
        });

        // Update global state
        totalStaked += amount;
        totalShares += shares;

        emit Staked(msg.sender, amount, shares, block.timestamp);
    }

    /**
     * @notice Query user's actual balance after slash
     * @param user User address
     * @return balance Current balance (shares * (totalStaked - totalSlashed) / totalShares)
     * @dev This automatically reflects slash penalties
     */
    function balanceOf(address user) public view returns (uint256 balance) {
        StakeInfo memory info = stakes[user];
        if (info.sGTokenShares == 0) return 0;

        // Slash-aware calculation
        // All stakers share the slash loss proportionally
        return info.sGTokenShares * (totalStaked - totalSlashed) / totalShares;
    }

    /**
     * @notice Execute slash on operator (only SuperPaymaster)
     * @param operator Operator to slash
     * @param amount Amount of GToken to slash
     * @param reason Slash reason
     * @dev Increases totalSlashed, automatically reducing all balanceOf values
     */
    function slash(address operator, uint256 amount, string memory reason) external {
        if (msg.sender != SUPERPAYMASTER) {
            revert UnauthorizedSlasher(msg.sender);
        }

        uint256 operatorBalance = balanceOf(operator);
        if (amount > operatorBalance) {
            revert SlashAmountExceedsBalance(amount, operatorBalance);
        }

        totalSlashed += amount;

        emit Slashed(operator, amount, reason, block.timestamp);
    }

    /**
     * @notice Request unstake (starts 7-day delay)
     * @dev User must wait UNSTAKE_DELAY before calling unstake()
     */
    function requestUnstake() external {
        if (stakes[msg.sender].sGTokenShares == 0) {
            revert NoStakeFound(msg.sender);
        }

        stakes[msg.sender].unstakeRequestedAt = block.timestamp;

        emit UnstakeRequested(msg.sender, block.timestamp);
    }

    /**
     * @notice Execute unstake after 7-day delay
     * @dev Returns actual balance (original amount minus proportional slash)
     */
    function unstake() external {
        StakeInfo memory info = stakes[msg.sender];

        if (info.unstakeRequestedAt == 0) {
            revert UnstakeNotRequested(msg.sender);
        }

        uint256 elapsed = block.timestamp - info.unstakeRequestedAt;
        if (elapsed < UNSTAKE_DELAY) {
            revert UnstakeDelayNotPassed(UNSTAKE_DELAY - elapsed);
        }

        // Calculate actual balance (after slash)
        uint256 actualAmount = balanceOf(msg.sender);

        // Update global state
        totalStaked -= info.amount;
        totalSlashed -= (info.amount - actualAmount); // Adjust slash accounting
        totalShares -= info.sGTokenShares;

        // Delete user stake
        delete stakes[msg.sender];

        // Transfer GToken back to user
        IERC20(GTOKEN).safeTransfer(msg.sender, actualAmount);

        emit Unstaked(msg.sender, info.amount, actualAmount, block.timestamp);
    }

    // ====================================
    // Admin Functions
    // ====================================

    /**
     * @notice Set SuperPaymaster address (only owner)
     * @param _superPaymaster SuperPaymaster contract address
     */
    function setSuperPaymaster(address _superPaymaster) external onlyOwner {
        if (_superPaymaster == address(0)) {
            revert InvalidAddress(_superPaymaster);
        }

        address oldAddress = SUPERPAYMASTER;
        SUPERPAYMASTER = _superPaymaster;

        emit SuperPaymasterUpdated(oldAddress, _superPaymaster);
    }

    /**
     * @notice Lock stake for operator (called by SuperPaymaster)
     * @param operator Operator address
     * @param amount Amount to lock
     * @dev This allows SuperPaymaster to lock existing stakes
     */
    function lockStake(address operator, uint256 amount) external {
        require(msg.sender == SUPERPAYMASTER, "Only SuperPaymaster");
        require(balanceOf(operator) >= amount, "Insufficient stake");
        // Lock logic can be implemented as needed
        // For now, we just verify the stake exists
    }

    // ====================================
    // View Functions
    // ====================================

    /**
     * @notice Get stake info for user
     * @param user User address
     * @return info Complete stake information
     */
    function getStakeInfo(address user)
        external
        view
        returns (StakeInfo memory info)
    {
        return stakes[user];
    }

    /**
     * @notice Get time remaining for unstake delay
     * @param user User address
     * @return remaining Seconds remaining (0 if can unstake)
     */
    function getUnstakeTimeRemaining(address user)
        external
        view
        returns (uint256 remaining)
    {
        StakeInfo memory info = stakes[user];
        if (info.unstakeRequestedAt == 0) {
            return type(uint256).max; // Not requested
        }

        uint256 elapsed = block.timestamp - info.unstakeRequestedAt;
        if (elapsed >= UNSTAKE_DELAY) {
            return 0; // Can unstake now
        }

        return UNSTAKE_DELAY - elapsed;
    }

    /**
     * @notice Calculate shares for given stake amount
     * @param amount Amount of GToken
     * @return shares Estimated sGToken shares
     */
    function calculateShares(uint256 amount)
        external
        view
        returns (uint256 shares)
    {
        if (totalShares == 0) {
            return amount;
        }
        return amount * totalShares / (totalStaked - totalSlashed);
    }

    /**
     * @notice Get global staking statistics
     * @return _totalStaked Total GToken staked
     * @return _totalSlashed Total GToken slashed
     * @return _totalShares Total sGToken shares
     * @return effectiveValue Value per share (scaled by 1e18)
     */
    function getGlobalStats()
        external
        view
        returns (
            uint256 _totalStaked,
            uint256 _totalSlashed,
            uint256 _totalShares,
            uint256 effectiveValue
        )
    {
        _totalStaked = totalStaked;
        _totalSlashed = totalSlashed;
        _totalShares = totalShares;

        if (_totalShares > 0) {
            effectiveValue = ((_totalStaked - _totalSlashed) * 1e18) / _totalShares;
        } else {
            effectiveValue = 1e18; // 1:1 ratio initially
        }
    }
}
