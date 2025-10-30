// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title GTokenStaking with Lock Management and Slash System
 * @notice Enhanced staking contract following Lido stETH best practices
 * @dev Implements stGToken (staked GToken) share system with:
 *      - Slash-aware share calculation
 *      - Multi-slasher support (Registry, SuperPaymaster)
 *      - Lock management for multiple protocols (MySBT, SuperPaymaster, Registry)
 *      - Configurable exit fees (time-based tiers or flat rate)
 *      - Low minimum stake (0.01 GT, like Lido's no minimum)
 *      - Treasury for protocol fees
 *
 * Architecture:
 * - Users stake GT → receive stGToken shares
 * - Protocols (MySBT, SuperPaymaster, Registry) lock user's stGToken
 * - Users can't unstake while locked
 * - Unlocking charges exit fees → treasury
 * - Registry and SuperPaymaster can slash for malicious behavior
 *
 * v2.0: Lido-compliant architecture with governance slash
 */
contract GTokenStaking is Ownable {
    using SafeERC20 for IERC20;

    // ====================================
    // Structs
    // ====================================

    struct StakeInfo {
        uint256 amount;             // Original staked GToken amount
        uint256 stGTokenShares;      // User's stGToken shares
        uint256 stakedAt;           // Stake timestamp
        uint256 unstakeRequestedAt; // Unstake request timestamp (0 = not requested)
    }

    struct LockInfo {
        uint256 amount;          // Locked stGToken amount
        uint256 lockedAt;        // Lock timestamp
        string purpose;          // Lock purpose (e.g., "MySBT membership")
        address beneficiary;     // Who benefits from this lock
    }

    struct LockerConfig {
        bool authorized;         // Is authorized to lock stakes
        uint256 baseExitFee;     // Base exit fee (for simple lockers like MySBT)
        uint256[] timeTiers;     // Time thresholds in seconds (for tiered fees)
        uint256[] tierFees;      // Corresponding fees for each tier
        address feeRecipient;    // Where exit fees go (address(0) = use default treasury)
    }

    // ====================================
    // Storage
    // ====================================

    /// @notice User stake information
    mapping(address => StakeInfo) public stakes;

    /// @notice Lock information: user => locker => LockInfo
    mapping(address => mapping(address => LockInfo)) public locks;

    /// @notice Total locked per user
    mapping(address => uint256) public totalLocked;

    /// @notice Locker configurations
    mapping(address => LockerConfig) public lockerConfigs;

    /// @notice Total amount of GToken staked
    uint256 public totalStaked;

    /// @notice Total amount of GToken slashed
    uint256 public totalSlashed;

    /// @notice Total stGToken shares issued
    uint256 public totalShares;

    /// @notice GToken ERC20 contract address
    address public immutable GTOKEN;

    /// @notice Authorized slashers (Registry, SuperPaymaster)
    mapping(address => bool) public authorizedSlashers;

    /// @notice Default treasury for exit fees
    address public treasury;

    /// @notice 7-day delay before unstaking
    uint256 public constant UNSTAKE_DELAY = 7 days;

    /// @notice Minimum stake amount: 0.01 GToken (Lido-like low barrier)
    uint256 public constant MIN_STAKE = 0.01 ether;

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

    event LockerConfigured(
        address indexed locker,
        bool authorized,
        uint256 baseExitFee,
        uint256[] timeTiers,
        uint256[] tierFees,
        address feeRecipient
    );

    event StakeLocked(
        address indexed user,
        address indexed locker,
        uint256 amount,
        string purpose
    );

    event StakeUnlocked(
        address indexed user,
        address indexed locker,
        uint256 grossAmount,
        uint256 exitFee,
        uint256 netAmount
    );

    event TreasuryUpdated(
        address indexed oldTreasury,
        address indexed newTreasury
    );

    event SlasherAuthorized(
        address indexed slasher,
        bool authorized
    );

    event StakeSlashed(
        address indexed user,
        address indexed slasher,
        uint256 amount,
        string reason,
        uint256 timestamp
    );

    // ====================================
    // Errors
    // ====================================

    error BelowMinimumStake(uint256 amount, uint256 minimum);
    error AlreadyStaked(address user);
    error NoStakeFound(address user);
    error UnstakeNotRequested(address user);
    error UnstakeDelayNotPassed(uint256 remainingTime);
    error StakeIsLocked(address user, uint256 lockedAmount);
    error UnauthorizedSlasher(address caller);
    error UnauthorizedLocker(address caller);
    error SlashAmountExceedsBalance(uint256 amount, uint256 balance);
    error InsufficientAvailableBalance(uint256 available, uint256 required);
    error InsufficientLockedAmount(uint256 locked, uint256 required);
    error ExitFeeTooHigh(uint256 fee, uint256 amount);
    error InvalidAddress(address addr);
    error InvalidTierConfig();
    error InvalidFeeRecipient();

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
    // Core Staking Functions
    // ====================================

    /**
     * @notice Stake GToken and receive stGToken shares
     * @param amount Amount of GToken to stake (must be >= 0.01 GT)
     * @return shares Number of stGToken shares received
     * @dev Share calculation:
     *      - First stake: shares = amount
     *      - Subsequent: shares = amount * totalShares / (totalStaked - totalSlashed)
     */
    function stake(uint256 amount) external returns (uint256 shares) {
        if (amount < MIN_STAKE) {
            revert BelowMinimumStake(amount, MIN_STAKE);
        }

        // ✅ FIXED: Allow users to add more stake (permissionless design)
        // Removed AlreadyStaked check to support:
        // - Multiple stake additions
        // - Community registration + Paymaster deployment
        // - Flexible stake management

        // Transfer GToken from user
        IERC20(GTOKEN).safeTransferFrom(msg.sender, address(this), amount);

        // Calculate shares (slash-aware)
        if (totalShares == 0) {
            shares = amount;
        } else {
            shares = amount * totalShares / (totalStaked - totalSlashed);
        }

        // Update user stake info (support both new stake and adding to existing)
        StakeInfo storage userStake = stakes[msg.sender];

        if (userStake.stGTokenShares > 0) {
            // Adding to existing stake
            userStake.amount += amount;
            userStake.stGTokenShares += shares;
            // Keep original stakedAt timestamp
            // Reset unstake request if user is adding more stake
            if (userStake.unstakeRequestedAt > 0) {
                userStake.unstakeRequestedAt = 0;
            }
        } else {
            // First time staking
            stakes[msg.sender] = StakeInfo({
                amount: amount,
                stGTokenShares: shares,
                stakedAt: block.timestamp,
                unstakeRequestedAt: 0
            });
        }

        // Update global state
        totalStaked += amount;
        totalShares += shares;

        emit Staked(msg.sender, amount, shares, block.timestamp);
    }

    /**
     * @notice Request unstake (starts 7-day delay)
     * @dev User must wait UNSTAKE_DELAY before calling unstake()
     */
    function requestUnstake() external {
        if (stakes[msg.sender].stGTokenShares == 0) {
            revert NoStakeFound(msg.sender);
        }

        stakes[msg.sender].unstakeRequestedAt = block.timestamp;

        emit UnstakeRequested(msg.sender, block.timestamp);
    }

    /**
     * @notice Execute unstake after 7-day delay
     * @dev Returns actual balance (original amount minus proportional slash)
     *      Reverts if stake is locked by any protocol
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

        // ✅ NEW: Check if stake is locked by any protocol
        if (totalLocked[msg.sender] > 0) {
            revert StakeIsLocked(msg.sender, totalLocked[msg.sender]);
        }

        // Calculate actual balance (after slash)
        uint256 actualAmount = balanceOf(msg.sender);

        // Update global state
        totalStaked -= info.amount;
        totalSlashed -= (info.amount - actualAmount); // Adjust slash accounting
        totalShares -= info.stGTokenShares;

        // Delete user stake
        delete stakes[msg.sender];

        // Transfer GToken back to user
        IERC20(GTOKEN).safeTransfer(msg.sender, actualAmount);

        emit Unstaked(msg.sender, info.amount, actualAmount, block.timestamp);
    }

    // ====================================
    // Lock Management Functions
    // ====================================

    /**
     * @notice Lock user's stGToken for usage by authorized protocol
     * @param user User whose stake to lock
     * @param amount Amount of stGToken shares to lock
     * @param purpose Lock purpose description
     * @dev Called by authorized lockers (MySBT, SuperPaymaster, etc.)
     */
    function lockStake(
        address user,
        uint256 amount,
        string memory purpose
    ) external {
        LockerConfig memory config = lockerConfigs[msg.sender];
        if (!config.authorized) {
            revert UnauthorizedLocker(msg.sender);
        }

        uint256 available = availableBalance(user);
        if (available < amount) {
            revert InsufficientAvailableBalance(available, amount);
        }

        // Update lock info
        locks[user][msg.sender].amount += amount;
        locks[user][msg.sender].lockedAt = block.timestamp;
        locks[user][msg.sender].purpose = purpose;
        locks[user][msg.sender].beneficiary = msg.sender;

        totalLocked[user] += amount;

        emit StakeLocked(user, msg.sender, amount, purpose);
    }

    /**
     * @notice Unlock user's stGToken with exit fee
     * @param user User whose stake to unlock
     * @param grossAmount Gross amount to unlock (before exit fee)
     * @return netAmount Net amount unlocked after exit fee deduction
     * @dev Called by locker when user exits (burns SBT, unregisters operator, etc.)
     *      Exit fee is transferred to treasury
     */
    function unlockStake(
        address user,
        uint256 grossAmount
    ) external returns (uint256 netAmount) {
        LockInfo storage lockInfo = locks[user][msg.sender];

        if (lockInfo.amount < grossAmount) {
            revert InsufficientLockedAmount(lockInfo.amount, grossAmount);
        }

        // Calculate exit fee
        uint256 exitFee = calculateExitFee(msg.sender, user);

        if (exitFee >= grossAmount) {
            revert ExitFeeTooHigh(exitFee, grossAmount);
        }

        netAmount = grossAmount - exitFee;

        // Update lock state
        lockInfo.amount -= grossAmount;
        totalLocked[user] -= grossAmount;

        // Transfer exit fee to treasury (if fee > 0)
        if (exitFee > 0) {
            LockerConfig memory config = lockerConfigs[msg.sender];
            address feeRecipient = config.feeRecipient != address(0)
                ? config.feeRecipient
                : treasury;

            if (feeRecipient == address(0)) {
                revert InvalidFeeRecipient();
            }

            // Convert stGToken shares to GT amount and transfer
            uint256 feeInGT = sharesToGToken(exitFee);
            IERC20(GTOKEN).safeTransfer(feeRecipient, feeInGT);

            // Adjust totalStaked and totalSlashed to account for fee transfer
            totalStaked -= feeInGT;
        }

        emit StakeUnlocked(user, msg.sender, grossAmount, exitFee, netAmount);
    }

    /**
     * @notice Calculate exit fee for a user's lock
     * @param locker Locker contract address
     * @param user User address
     * @return fee Exit fee in stGToken shares
     */
    function calculateExitFee(
        address locker,
        address user
    ) public view returns (uint256 fee) {
        LockerConfig memory config = lockerConfigs[locker];
        LockInfo memory lockInfo = locks[user][locker];

        if (lockInfo.amount == 0) return 0;

        // Simple base fee (for MySBT: flat 0.1 sGT)
        if (config.timeTiers.length == 0) {
            return config.baseExitFee;
        }

        // Time-based tiered fee (for SuperPaymaster: 5-15 sGT based on duration)
        uint256 lockDuration = block.timestamp - lockInfo.lockedAt;

        // Find appropriate tier
        for (uint256 i = 0; i < config.timeTiers.length; i++) {
            if (lockDuration < config.timeTiers[i]) {
                return config.tierFees[i];
            }
        }

        // Last tier (longest duration = lowest fee)
        return config.tierFees[config.timeTiers.length];
    }

    // ====================================
    // Slash Functions
    // ====================================

    /**
     * @notice Execute slash on user (called by authorized slashers)
     * @param user User to slash
     * @param amount Amount of GToken to slash
     * @param reason Slash reason
     * @return slashedAmount Actual amount slashed (may be less if insufficient balance)
     * @dev Increases totalSlashed, automatically reducing all balanceOf values
     *      Called by Registry or SuperPaymaster for malicious/failing operators
     */
    function slash(
        address user,
        uint256 amount,
        string memory reason
    ) external returns (uint256 slashedAmount) {
        if (!authorizedSlashers[msg.sender]) {
            revert UnauthorizedSlasher(msg.sender);
        }

        uint256 userBalance = balanceOf(user);

        // Slash up to available balance (partial slash if insufficient)
        slashedAmount = amount > userBalance ? userBalance : amount;

        if (slashedAmount == 0) {
            revert SlashAmountExceedsBalance(amount, userBalance);
        }

        totalSlashed += slashedAmount;

        emit Slashed(user, slashedAmount, reason, block.timestamp);
        emit StakeSlashed(user, msg.sender, slashedAmount, reason, block.timestamp);

        return slashedAmount;
    }

    // ====================================
    // Admin Functions
    // ====================================

    /**
     * @notice Configure locker contract with exit fee parameters
     * @param locker Locker contract address
     * @param authorized Whether authorized to lock stakes
     * @param baseExitFee Base exit fee (for simple lockers)
     * @param timeTiers Array of time thresholds in seconds
     * @param tierFees Array of fees for each time tier
     * @param feeRecipient Address to receive exit fees (address(0) = use treasury)
     *
     * Example for MySBT (flat fee):
     *   baseExitFee = 0.1 ether
     *   timeTiers = []
     *   tierFees = []
     *
     * Example for SuperPaymaster (tiered):
     *   baseExitFee = 0
     *   timeTiers = [90 days, 180 days, 365 days]
     *   tierFees = [15 ether, 10 ether, 7 ether, 5 ether]
     *   (< 90d: 15, 90-180d: 10, 180-365d: 7, ≥365d: 5)
     */
    function configureLocker(
        address locker,
        bool authorized,
        uint256 baseExitFee,
        uint256[] calldata timeTiers,
        uint256[] calldata tierFees,
        address feeRecipient
    ) external onlyOwner {
        if (locker == address(0)) revert InvalidAddress(locker);

        // Validate time tiers
        if (timeTiers.length > 0) {
            if (tierFees.length != timeTiers.length + 1) {
                revert InvalidTierConfig();
            }

            // Ensure tiers are ascending
            for (uint256 i = 1; i < timeTiers.length; i++) {
                if (timeTiers[i] <= timeTiers[i-1]) {
                    revert InvalidTierConfig();
                }
            }
        }

        lockerConfigs[locker] = LockerConfig({
            authorized: authorized,
            baseExitFee: baseExitFee,
            timeTiers: timeTiers,
            tierFees: tierFees,
            feeRecipient: feeRecipient
        });

        emit LockerConfigured(locker, authorized, baseExitFee, timeTiers, tierFees, feeRecipient);
    }

    /**
     * @notice Set treasury address for exit fees
     * @param newTreasury New treasury address
     */
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert InvalidAddress(newTreasury);

        address oldTreasury = treasury;
        treasury = newTreasury;

        emit TreasuryUpdated(oldTreasury, newTreasury);
    }

    /**
     * @notice Authorize or revoke slasher (Registry, SuperPaymaster)
     * @param slasher Slasher contract address
     * @param authorized Whether to authorize or revoke
     */
    function authorizeSlasher(address slasher, bool authorized) external onlyOwner {
        if (slasher == address(0)) {
            revert InvalidAddress(slasher);
        }

        authorizedSlashers[slasher] = authorized;

        emit SlasherAuthorized(slasher, authorized);
    }

    // ====================================
    // View Functions
    // ====================================

    /**
     * @notice Query user's total stGToken balance (shares value after slash)
     * @param user User address
     * @return balance Current balance in GT equivalent
     * @dev This automatically reflects slash penalties
     */
    function balanceOf(address user) public view returns (uint256 balance) {
        StakeInfo memory info = stakes[user];
        if (info.stGTokenShares == 0) return 0;

        // Slash-aware calculation
        return info.stGTokenShares * (totalStaked - totalSlashed) / totalShares;
    }

    /**
     * @notice Get available (unlocked) balance in stGToken shares
     * @param user User address
     * @return available Available stGToken shares
     */
    function availableBalance(address user) public view returns (uint256) {
        StakeInfo memory info = stakes[user];
        uint256 userShares = info.stGTokenShares;
        uint256 locked = totalLocked[user];

        return userShares > locked ? userShares - locked : 0;
    }

    /**
     * @notice Get locked balance by specific locker
     * @param user User address
     * @param locker Locker contract address
     * @return amount Locked stGToken shares
     */
    function lockedBalanceBy(
        address user,
        address locker
    ) external view returns (uint256) {
        return locks[user][locker].amount;
    }

    /**
     * @notice Get locked stake for user from specific locker (alias for lockedBalanceBy)
     * @param user User address
     * @param locker Locker contract address (Registry or SuperPaymaster)
     * @return amount Locked stGToken shares
     */
    function getLockedStake(
        address user,
        address locker
    ) external view returns (uint256) {
        return locks[user][locker].amount;
    }

    /**
     * @notice Get complete lock information
     * @param user User address
     * @param locker Locker contract
     * @return lockInfo Complete lock information
     */
    function getLockInfo(
        address user,
        address locker
    ) external view returns (LockInfo memory) {
        return locks[user][locker];
    }

    /**
     * @notice Preview exit fee and net amount for user
     * @param user User address
     * @param locker Locker contract
     * @return fee Exit fee in stGToken shares
     * @return netAmount Net amount after fee (in stGToken shares)
     */
    function previewExitFee(
        address user,
        address locker
    ) external view returns (uint256 fee, uint256 netAmount) {
        uint256 lockedAmount = locks[user][locker].amount;
        fee = calculateExitFee(locker, user);
        netAmount = lockedAmount > fee ? lockedAmount - fee : 0;
    }

    /**
     * @notice Get locker configuration
     * @param locker Locker address
     * @return config Complete locker configuration
     */
    function getLockerConfig(
        address locker
    ) external view returns (LockerConfig memory) {
        return lockerConfigs[locker];
    }

    /**
     * @notice Convert stGToken shares to GT amount
     * @param shares stGToken shares
     * @return amount GT amount
     */
    function sharesToGToken(uint256 shares) public view returns (uint256) {
        if (totalShares == 0) return 0;
        return shares * (totalStaked - totalSlashed) / totalShares;
    }

    /**
     * @notice Convert GT amount to stGToken shares
     * @param amount GT amount
     * @return shares stGToken shares
     */
    function gTokenToShares(uint256 amount) public view returns (uint256) {
        if (totalShares == 0) return amount;
        return amount * totalShares / (totalStaked - totalSlashed);
    }

    /**
     * @notice Get stake info for user
     * @param user User address
     * @return info Complete stake information
     */
    function getStakeInfo(address user)
        external
        view
        returns (StakeInfo memory)
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
     * @return shares Estimated stGToken shares
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
     * @return _totalShares Total stGToken shares
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
