// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";

/**
 * @title GTokenStaking v3.0.0
 * @notice Registry-driven staking for Mycelium Protocol
 * @dev Simplified design for Registry atomic operations
 *   - lockStake() burns entryBurn amount, locks remainder
 *   - unlockStake() deducts exitFee, returns remainder to user
 *   - All fee/burn amounts calculated and passed by Registry
 *   - No complex fee tiers or per-locker configuration
 *   - Burn records tracked for reputation
 */
contract GTokenStaking is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ====================================
    // Structs
    // ====================================

    /// @notice User stake information
    struct StakeInfo {
        uint256 stakedAmount;         // Total staked (not including burns)
        uint256 lockedAmount;         // Currently locked by protocols
        uint256 totalBurned;          // Total burned (entry + exit fees)
        uint256 stakedAt;             // Stake timestamp
        uint256 lastUnlockedAt;       // Last unlock timestamp
    }

    /// @notice Burn record
    struct BurnRecord {
        uint256 amount;               // Burn amount
        bytes32 roleId;               // Role burning for
        string reason;                // Burn reason (entry/exit)
        uint256 timestamp;            // Burn timestamp
    }

    // ====================================
    // Storage
    // ====================================

    /// @notice User stake information
    mapping(address => StakeInfo) public stakes;

    /// @notice Burn history per user
    mapping(address => BurnRecord[]) public burnHistory;

    /// @notice Authorized lockers (only Registry)
    mapping(address => bool) public authorizedLockers;

    /// @notice Total staked across all users
    uint256 public totalStaked;

    /// @notice Total burned across all users
    uint256 public totalBurned;

    /// @notice Treasury for protocol fees
    address public treasury;

    address public immutable GTOKEN;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    uint256 public constant MIN_STAKE = 0.01 ether;

    // ====================================
    // Events
    // ====================================

    event StakeLocked(
        address indexed user,
        bytes32 indexed roleId,
        uint256 lockedAmount,
        uint256 burnAmount,
        uint256 timestamp
    );

    event StakeUnlocked(
        address indexed user,
        bytes32 indexed roleId,
        uint256 unlockedAmount,
        uint256 exitFee,
        uint256 refund,
        uint256 timestamp
    );

    event BurnRecorded(
        address indexed user,
        bytes32 indexed roleId,
        uint256 amount,
        string reason,
        uint256 timestamp
    );

    event LockerAuthorized(address indexed locker, bool authorized, uint256 timestamp);

    event TreasuryUpdated(address indexed newTreasury, uint256 timestamp);

    // ====================================
    // Errors
    // ====================================

    error InvalidAddress();
    error Unauthorized();
    error InsufficientBalance();
    error InsufficientStake();
    error BelowMinimumStake();
    error TransferFailed();

    // ====================================
    // Modifiers
    // ====================================

    modifier onlyAuthorized() {
        require(authorizedLockers[msg.sender], "Unauthorized locker");
        _;
    }

    modifier onlyOwner() {
        require(msg.sender == owner(), "Only owner");
        _;
    }

    // ====================================
    // Constructor
    // ====================================

    constructor(address _gtoken, address _treasury) Ownable(msg.sender) {
        require(_gtoken != address(0), "Invalid GToken");
        require(_treasury != address(0), "Invalid Treasury");

        GTOKEN = _gtoken;
        treasury = _treasury;
    }

    // ====================================
    // User-Facing: Stake & Unstake
    // ====================================

    /**
     * @notice User: Stake GT tokens
     * @param amount Amount of GT to stake (must be >= 0.01 GT)
     *
     * @dev User approves GT transfer, stakes amount
     *      Can be called multiple times to add to stake
     */
    function stake(uint256 amount) external nonReentrant {
        require(amount >= MIN_STAKE, "Below minimum stake");

        // Transfer GT from user to this contract
        IERC20(GTOKEN).safeTransferFrom(msg.sender, address(this), amount);

        // Update user stake
        stakes[msg.sender].stakedAmount += amount;
        stakes[msg.sender].lockedAmount = 0;  // New stake not locked

        if (stakes[msg.sender].stakedAt == 0) {
            stakes[msg.sender].stakedAt = block.timestamp;
        }

        totalStaked += amount;
    }

    // ====================================
    // Registry-Facing: Lock & Unlock
    // ====================================

    /**
     * @notice Registry: Lock stake for role registration
     * @param user User whose stake to lock
     * @param roleId Role being registered
     * @param stakeAmount Amount to lock
     * @param entryBurn Amount to burn on entry
     *
     * @dev Called by Registry.registerRole():
     *      1. User approves GT
     *      2. Registry.registerRole() calls:
     *         - lockStake(user, ROLE_X, stakeAmount, entryBurn)
     *         - Burn: stakeAmount (sent to 0xdEaD)
     *         - Lock: stakeAmount (locked in GTokenStaking)
     *      3. MySBT mints SBT
     *
     * Example (0.3 GT user, ENDUSER):
     *   - User balance: 0.3 GT
     *   - lockStake(user, ENDUSER, 0.3, 0.1)
     *   - Burn: 0.1 GT → address(0xdEaD)
     *   - Lock: 0.2 GT in GTokenStaking
     *   - User can't unstake 0.2 GT until exitRole()
     */
    function lockStake(
        address user,
        bytes32 roleId,
        uint256 stakeAmount,
        uint256 entryBurn
    ) external onlyAuthorized nonReentrant {
        require(user != address(0), "Invalid user");
        require(stakeAmount >= MIN_STAKE, "Stake too small");
        require(entryBurn < stakeAmount, "Burn >= stake");

        StakeInfo storage info = stakes[user];

        // === CHECKS ===
        if (info.stakedAmount < stakeAmount) {
            revert InsufficientBalance();
        }

        uint256 lockAmount = stakeAmount - entryBurn;

        // === EFFECTS ===
        // Update stake: move from staked to locked
        info.stakedAmount -= stakeAmount;
        info.lockedAmount += lockAmount;
        info.totalBurned += entryBurn;

        totalBurned += entryBurn;

        // Record burn
        _recordBurn(user, roleId, entryBurn, "entry");

        // === INTERACTIONS ===
        // Burn entry fee
        if (entryBurn > 0) {
            IERC20(GTOKEN).safeTransfer(BURN_ADDRESS, entryBurn);
        }

        emit StakeLocked(user, roleId, lockAmount, entryBurn, block.timestamp);
    }

    /**
     * @notice Registry: Unlock stake on role exit
     * @param user User whose stake to unlock
     * @param roleId Role being exited
     * @param lockedAmount Amount that was locked
     * @param exitFee Exit fee to deduct (calculated by Registry)
     * @return refund Amount returned to user
     *
     * @dev Called by Registry.exitRole():
     *      1. User calls exitRole()
     *      2. Registry.exitRole() calls:
     *         - unlockStake(user, ROLE_X, lockedAmount, exitFee)
     *         - Fee: exitFee → treasury
     *         - Refund: lockedAmount - exitFee → user
     *      3. MySBT burns SBT
     *
     * Example (user exits ENDUSER with 0.2 locked, 17% fee):
     *   - lockedAmount: 0.2 GT
     *   - exitFee: 0.05 GT (17% of 0.2 = 0.034, but min fee is 0.05)
     *   - Refund: 0.15 GT
     *   - Treasury: +0.05 GT
     *   - User: +0.15 GT
     */
    function unlockStake(
        address user,
        bytes32 roleId,
        uint256 lockedAmount,
        uint256 exitFee
    ) external onlyAuthorized nonReentrant returns (uint256 refund) {
        require(user != address(0), "Invalid user");
        require(lockedAmount > 0, "No locked amount");
        require(exitFee < lockedAmount, "Fee >= locked");

        StakeInfo storage info = stakes[user];

        // === CHECKS ===
        if (info.lockedAmount < lockedAmount) {
            revert InsufficientStake();
        }

        // === EFFECTS ===
        refund = lockedAmount - exitFee;

        // Update stake: unlock and burn fee
        info.lockedAmount -= lockedAmount;
        info.stakedAmount += refund;  // Return remainder to available
        info.totalBurned += exitFee;  // Exit fee counted as burn
        info.lastUnlockedAt = block.timestamp;

        totalBurned += exitFee;

        // Record burn for exit fee
        _recordBurn(user, roleId, exitFee, "exit");

        // === INTERACTIONS ===
        // Transfer fee to treasury
        if (exitFee > 0 && treasury != address(0)) {
            IERC20(GTOKEN).safeTransfer(treasury, exitFee);
        }

        // Transfer refund to user
        if (refund > 0) {
            IERC20(GTOKEN).safeTransfer(user, refund);
        }

        emit StakeUnlocked(user, roleId, lockedAmount, exitFee, refund, block.timestamp);

        return refund;
    }

    // ====================================
    // View Functions
    // ====================================

    /**
     * @notice Get available (unlocked) balance for user
     * @param user User address
     * @return Available GT amount
     */
    function getAvailableBalance(address user) external view returns (uint256) {
        return stakes[user].stakedAmount;
    }

    /**
     * @notice Get locked balance for user
     * @param user User address
     * @return Locked GT amount
     */
    function getLockedBalance(address user) external view returns (uint256) {
        return stakes[user].lockedAmount;
    }

    /**
     * @notice Get total balance (staked + locked)
     * @param user User address
     * @return Total GT amount
     */
    function getTotalBalance(address user) external view returns (uint256) {
        StakeInfo memory info = stakes[user];
        return info.stakedAmount + info.lockedAmount;
    }

    /**
     * @notice Get burn history for user
     * @param user User address
     * @return Array of burn records
     */
    function getBurnHistory(address user) external view returns (BurnRecord[] memory) {
        return burnHistory[user];
    }

    /**
     * @notice Get total burned by user
     * @param user User address
     * @return Total burned amount
     */
    function getTotalBurned(address user) external view returns (uint256) {
        return stakes[user].totalBurned;
    }

    /**
     * @notice Get stake info
     * @param user User address
     * @return Stake info struct
     */
    function getStakeInfo(address user) external view returns (StakeInfo memory) {
        return stakes[user];
    }

    // ====================================
    // Admin Functions
    // ====================================

    /**
     * @notice Owner: Authorize locker (Registry)
     * @param locker Locker contract address
     * @param authorized True to authorize
     */
    function setLockerAuthorization(address locker, bool authorized) external onlyOwner {
        require(locker != address(0), "Invalid address");
        authorizedLockers[locker] = authorized;
        emit LockerAuthorized(locker, authorized, block.timestamp);
    }

    /**
     * @notice Owner: Update treasury address
     * @param newTreasury New treasury address
     */
    function setTreasury(address newTreasury) external onlyOwner {
        require(newTreasury != address(0), "Invalid address");
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury, block.timestamp);
    }

    // ====================================
    // Internal Functions
    // ====================================

    /**
     * @notice Internal: Record burn
     * @param user User address
     * @param roleId Role burning for
     * @param amount Burn amount
     * @param reason Burn reason
     */
    function _recordBurn(
        address user,
        bytes32 roleId,
        uint256 amount,
        string memory reason
    ) internal {
        burnHistory[user].push(
            BurnRecord({
                amount: amount,
                roleId: roleId,
                reason: reason,
                timestamp: block.timestamp
            })
        );

        emit BurnRecorded(user, roleId, amount, reason, block.timestamp);
    }
}
