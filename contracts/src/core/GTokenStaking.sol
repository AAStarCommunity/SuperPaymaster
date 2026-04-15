// SPDX-License-Identifier: MIT
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;
import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/v3/IGTokenStaking.sol";

/**
 * @title GTokenStaking v4.0.0 — Ticket Model
 * @notice Unified Role-Based Staking with Ticket Model (burn to treasury)
 * @dev v4: Replace true burn with treasury transfer ("ticket")
 *      - Regular users (ENDUSER, COMMUNITY): burnTicket() — transfer to treasury, no stake
 *      - Operators (DVT, KMS, PAYMASTER_*, ANODE): lockStakeWithTicket() — ticket to treasury + stake locked
 *      - lockStake() kept for backward compatibility (deprecated)
 *      - 21M GT total supply is CONSTANT — nothing is destroyed
 */
contract GTokenStaking is ReentrancyGuard, Ownable, IGTokenStaking {
    using SafeERC20 for IERC20;

    error OnlyRegistry();
    error InvalidAddress();
    error RoleAlreadyLocked();
    error AmountExceedsUint128();
    error RoleNotLocked();
    error NoLockFound();
    error OnlyRegistryOrAuthorized();
    error Unauthorized();
    error NotAuthorizedSlasher();
    error InsufficientStake();
    error TotalStakeExceedsCap();

    // ...

    function version() external pure override returns (string memory) {
        return "Staking-4.0.0";
    }

    // ====================================
    // Storage
    // ====================================

    IERC20 public immutable GTOKEN;
    address public immutable REGISTRY;
    address public treasury;

    // User stake info (total per user)
    mapping(address => StakeInfo) public stakes;
    
    // Role locks: user => roleId => Lock
    mapping(address => mapping(bytes32 => RoleLock)) public roleLocks;
    
    // User's active roles list (for enumeration)
    mapping(address => bytes32[]) public userActiveRoles;
    
    // Role configuration
    struct RoleExitConfig {
        uint256 feePercent; // Basis points (100 = 1%)
        uint256 minFee;
    }
    mapping(bytes32 => RoleExitConfig) public roleExitConfigs;

    // Global stats
    uint256 public totalStaked;

    /// @notice Maximum total stake cap — equals GToken total supply (21M).
    /// GToken is a limited-issuance governance token (analogous to BTC's 21M cap).
    /// Using `constant` is intentional: the supply cap is a protocol invariant,
    /// not a tunable parameter. Adjusting it requires a full token economics redesign.
    uint256 public constant MAX_TOTAL_STAKE = 21_000_000 ether;


    // Authorized slashers
    mapping(address => bool) public authorizedSlashers;

    // ====================================
    // Modifiers
    // ====================================

    modifier onlyRegistry() {
        if (msg.sender != REGISTRY) revert OnlyRegistry();
        _;
    }

    constructor(address _gtoken, address _treasury, address _registry) Ownable(msg.sender) {
        if (_gtoken == address(0)) revert InvalidAddress();
        if (_treasury == address(0)) revert InvalidAddress();
        if (_registry == address(0)) revert InvalidAddress();
        GTOKEN = IERC20(_gtoken);
        treasury = _treasury;
        REGISTRY = _registry;
    }

    // ====================================
    // Core Functions - Role Locking
    // ====================================

    /**
     * @notice Lock stake for a role (Registry only)
     * @dev DEPRECATED — kept for backward compatibility. New registrations should use
     *      burnTicket() for regular users or lockStakeWithTicket() for operators.
     *      Uses true burn (ERC20Burnable.burn) which reduces totalSupply.
     */
    function lockStake(
        address user,
        bytes32 roleId,
        uint256 stakeAmount,
        uint256 entryBurn,
        address payer
    ) external nonReentrant onlyRegistry returns (uint256 lockId) {
        if (roleLocks[user][roleId].amount > 0) revert RoleAlreadyLocked();

        uint256 totalAmount = stakeAmount + entryBurn;

        // Transfer GToken from PAYER (stake + burn)
        GTOKEN.safeTransferFrom(payer, address(this), totalAmount);

        // Handle entry burn: TRUE BURN (totalSupply decreases)
        if (entryBurn > 0) {
            ERC20Burnable(address(GTOKEN)).burn(entryBurn);
            emit TokensBurned(user, roleId, entryBurn, "Entry Burn");
        }

        // Update user global stake info
        stakes[user].amount += stakeAmount;
        if (stakes[user].stakedAt == 0) {
            stakes[user].stakedAt = block.timestamp;
        }

        // Safe Casts for Packed Storage
        if (stakeAmount > type(uint128).max) revert AmountExceedsUint128();
        if (entryBurn > type(uint128).max) revert AmountExceedsUint128();

        // Create lock
        RoleLock memory newLock = RoleLock({
            amount: uint128(stakeAmount),
            ticketPrice: uint128(entryBurn),
            lockedAt: uint48(block.timestamp),
            roleId: roleId,
            metadata: ""
        });

        roleLocks[user][roleId] = newLock;
        userActiveRoles[user].push(roleId);

        // Update global stats — pre-check avoids a second SLOAD after the write
        uint256 newTotal = totalStaked + stakeAmount;
        if (newTotal > MAX_TOTAL_STAKE) revert TotalStakeExceedsCap();
        totalStaked = newTotal;

        emit StakeLocked(user, roleId, stakeAmount, entryBurn, block.timestamp);
        return uint256(roleId); // Use roleId as lockId
    }

    /**
     * @notice Burn ticket for a regular user role (Registry only)
     * @dev Transfers ticketPrice from payer directly to treasury. No stake, no lock.
     *      CRITICAL: Does NOT call ERC20Burnable.burn() — transfer to treasury preserves totalSupply.
     *      For ENDUSER and COMMUNITY roles — lifetime membership, no exit.
     */
    function burnTicket(
        address user,
        bytes32 roleId,
        uint256 ticketPrice,
        address payer
    ) external nonReentrant onlyRegistry {
        // Transfer ticket price directly from payer to treasury
        if (ticketPrice > 0) {
            GTOKEN.safeTransferFrom(payer, treasury, ticketPrice);
        }

        emit TicketBurned(user, roleId, ticketPrice, payer);
    }

    /**
     * @notice Lock stake with ticket for an operator role (Registry only)
     * @dev Transfers (stakeAmount + ticketPrice) from payer.
     *      ticketPrice goes to treasury (NOT burned), stakeAmount stays locked in contract.
     *      CRITICAL: Does NOT call ERC20Burnable.burn() — transfer to treasury preserves totalSupply.
     *      For DVT, KMS, PAYMASTER_*, ANODE roles.
     */
    function lockStakeWithTicket(
        address user,
        bytes32 roleId,
        uint256 stakeAmount,
        uint256 ticketPrice,
        address payer
    ) external nonReentrant onlyRegistry returns (uint256 lockId) {
        if (roleLocks[user][roleId].amount > 0) revert RoleAlreadyLocked();

        uint256 totalAmount = stakeAmount + ticketPrice;

        // Transfer total from payer to this contract
        GTOKEN.safeTransferFrom(payer, address(this), totalAmount);

        // Ticket portion goes to treasury (NOT burned)
        if (ticketPrice > 0) {
            GTOKEN.safeTransfer(treasury, ticketPrice);
            emit TicketBurned(user, roleId, ticketPrice, payer);
        }

        // Update user global stake info (stake portion only)
        stakes[user].amount += stakeAmount;
        if (stakes[user].stakedAt == 0) {
            stakes[user].stakedAt = block.timestamp;
        }

        // Safe Casts for Packed Storage
        if (stakeAmount > type(uint128).max) revert AmountExceedsUint128();
        if (ticketPrice > type(uint128).max) revert AmountExceedsUint128();

        // Create lock — ticketPrice records what went to treasury (for audit trail)
        RoleLock memory newLock = RoleLock({
            amount: uint128(stakeAmount),
            ticketPrice: uint128(ticketPrice),
            lockedAt: uint48(block.timestamp),
            roleId: roleId,
            metadata: ""
        });

        roleLocks[user][roleId] = newLock;
        userActiveRoles[user].push(roleId);

        // Update global stats
        uint256 newTotal = totalStaked + stakeAmount;
        if (newTotal > MAX_TOTAL_STAKE) revert TotalStakeExceedsCap();
        totalStaked = newTotal;

        emit StakeLocked(user, roleId, stakeAmount, ticketPrice, block.timestamp);
        return uint256(roleId);
    }

    /**
     * @notice Top up stake for an existing role (Registry only)
     * @dev Does NOT reset lockedAt time. Only increases amount.
     */
    function topUpStake(
        address user,
        bytes32 roleId,
        uint256 stakeAmount,
        address payer
    ) external nonReentrant onlyRegistry {
        RoleLock storage lock = roleLocks[user][roleId];
        if (lock.amount == 0) revert RoleNotLocked();

        GTOKEN.safeTransferFrom(payer, address(this), stakeAmount);
        
        uint256 newTotal = totalStaked + stakeAmount;
        if (newTotal > MAX_TOTAL_STAKE) revert TotalStakeExceedsCap();
        lock.amount += uint128(stakeAmount);
        stakes[user].amount += stakeAmount;
        totalStaked = newTotal;

        emit StakeLocked(user, roleId, stakeAmount, 0, lock.lockedAt); // Reuse existing lockedAt
    }

    /**
     * @notice Unlock and transfer to user (Registry only)
     * @dev OPERATORS ONLY — Regular user roles (ENDUSER, COMMUNITY) have no exit.
     *      Registry enforces this by checking isOperatorRole before calling.
     */
    function unlockAndTransfer(
        address user,
        bytes32 roleId
    ) external nonReentrant onlyRegistry returns (uint256 netAmount) {
        RoleLock storage lock = roleLocks[user][roleId];
        if (lock.lockedAt == 0) revert NoLockFound();
        
        // Slashes are now handled immediately in slash() by transferring to treasury
        // and reducing totalStaked. Here we just process the remaining lock.
        uint256 originalAmount = lock.amount;
        
        // Update state before transfer (CEI)
        delete roleLocks[user][roleId];
        _removeUserRole(user, roleId);
        
        // Global accounting uses the original lock amount
        stakes[user].amount -= originalAmount;
        
        // FIX: Clear slashedAmount residue if no active stake remains (cleaner state)
        if (stakes[user].amount == 0) {
            stakes[user].slashedAmount = 0;
        }

        totalStaked -= originalAmount;

        // Transfers
        (uint256 exitFee, uint256 net) = _previewExitFee(user, roleId, originalAmount);
        netAmount = net;
        
        if (exitFee > 0) {
            GTOKEN.safeTransfer(treasury, exitFee);
        }
        
        if (netAmount > 0) {
            GTOKEN.safeTransfer(user, netAmount);
        }
        
        emit StakeUnlocked(user, roleId, originalAmount, exitFee, netAmount, block.timestamp);
        return netAmount;
    }

    /**
     * @notice Slash a user
     */
    function slash(
        address user,
        uint256 amount,
        string calldata reason
    ) external nonReentrant returns (uint256 slashedAmount) {
        if (msg.sender != REGISTRY && !authorizedSlashers[msg.sender]) {
            revert OnlyRegistryOrAuthorized();
        }

        StakeInfo storage info = stakes[user];
        
        // H-01 FIX: Calculate available balance correctly
        // Since info.amount is now NET of slashes, the available amount IS the info.amount
        uint256 available = info.amount;
        slashedAmount = amount > available ? available : amount;

        if (slashedAmount > 0) {
            // H-01 FIX: Synchronize both fields to prevent underflow
            info.slashedAmount += slashedAmount;  // Track cumulative slashed
            info.amount -= slashedAmount;         // Reduce actual balance
            totalStaked -= slashedAmount;

            // Proportionally reduce role locks (Weighted Distribution)
            bytes32[] storage roles = userActiveRoles[user];
            uint256 totalAmountAcrossLocks = info.amount + slashedAmount; // Amount BEFORE this slash
            
            if (totalAmountAcrossLocks > 0) {
                for (uint256 i = 0; i < roles.length; i++) {
                    RoleLock storage lock = roleLocks[user][roles[i]];
                    // deduction = (lock.amount * slashedAmount) / totalAmountAcrossLocks
                    uint256 deduct = (uint256(lock.amount) * slashedAmount) / totalAmountAcrossLocks;
                    if (deduct > lock.amount) deduct = lock.amount;
                    lock.amount -= uint128(deduct);
                }
            }

            // Cleanup zero-amount role locks to prevent storage bloat
            _cleanupZeroLocks(user);

            GTOKEN.safeTransfer(treasury, slashedAmount);
        }

        emit UserSlashed(user, slashedAmount, reason, block.timestamp);
        return slashedAmount;
    }

    // ====================================
    // Internal Helpers
    // ====================================

    function _previewExitFee(address /* user */, bytes32 roleId, uint256 amount) internal view returns (uint256 fee, uint256 net) {
        RoleExitConfig memory config = roleExitConfigs[roleId];
        fee = (amount * config.feePercent) / 10000;
        if (fee < config.minFee) {
            fee = config.minFee;
        }
        if (fee > amount) {
            fee = amount;
        }
        net = amount - fee;
    }

    /// @dev Remove all zero-amount role locks from userActiveRoles (post-slash cleanup)
    function _cleanupZeroLocks(address user) internal {
        bytes32[] storage roles = userActiveRoles[user];
        uint256 i = 0;
        while (i < roles.length) {
            if (roleLocks[user][roles[i]].amount == 0) {
                roles[i] = roles[roles.length - 1];
                roles.pop();
            } else {
                i++;
            }
        }
    }

    function _removeUserRole(address user, bytes32 roleId) internal {
        bytes32[] storage roles = userActiveRoles[user];
        for (uint256 i = 0; i < roles.length; i++) {
            if (roles[i] == roleId) {
                roles[i] = roles[roles.length - 1];
                roles.pop();
                break;
            }
        }
    }

    // ====================================
    // View Functions
    // ====================================

    function getLockedStake(address user, bytes32 roleId) external view returns (uint256) {
        return roleLocks[user][roleId].amount;
    }

    function getUserRoleLocks(address user) external view returns (RoleLock[] memory) {
        bytes32[] memory roleIds = userActiveRoles[user];
        RoleLock[] memory locks = new RoleLock[](roleIds.length);
        for(uint256 i=0; i<roleIds.length; i++) {
            locks[i] = roleLocks[user][roleIds[i]];
        }
        return locks;
    }

    function hasRoleLock(address user, bytes32 roleId) external view returns (bool) {
        return roleLocks[user][roleId].amount > 0;
    }

    function balanceOf(address user) public view override returns (uint256) {
        // H-01 FIX: amount is now always net of slashes
        // No need to subtract slashedAmount again
        return stakes[user].amount;
    }

    function availableBalance(address /* user */) external pure returns (uint256) {
        // In V3, all stakes are locked by roles. Available is what?
        // If stake was done outside roles... but stake() is removed.
        // So available is likely 0 unless we allow general staking (disabled).
        // Or if we have surplus?
        // For now, return 0 as all stake is strictly role-locked.
        return 0; 
    }



    function previewExitFee(address user, bytes32 roleId) external view returns (uint256 fee, uint256 netAmount) {
        uint256 amount = roleLocks[user][roleId].amount;
        return _previewExitFee(user, roleId, amount);
    }



    // ====================================
    // Admin Functions
    // ====================================

    function setRoleExitFee(bytes32 roleId, uint256 feePercent, uint256 minFee) external {
        if (msg.sender != REGISTRY && msg.sender != owner()) revert Unauthorized();
        
        RoleExitConfig storage config = roleExitConfigs[roleId]; // Assuming RoleExitConfig is the correct struct name based on original code
        config.feePercent = feePercent;
        config.minFee = minFee;
        // Assuming 'isActive' field is not part of RoleExitConfig based on original code,
        // and 'RoleExitFeeConfigured' event is not defined.
        // Sticking to the original structure for setRoleExitFee, but adding the new function.
        // If the user intended to change RoleExitConfig to RoleExitFee and add isActive,
        // they should provide the full context for that struct and event.
        // For now, I will only apply the setTreasury function and keep setRoleExitFee as close to original as possible,
        // while incorporating the new require/revert style.
    }

    /**
     * @notice Set the protocol treasury address
     * @param _treasury New treasury address
     */
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert InvalidAddress();
        treasury = _treasury;
    }

    function setAuthorizedSlasher(address slasher, bool authorized) external onlyOwner {
        authorizedSlashers[slasher] = authorized;
    }

    // ====================================
    // DVT Slash Interface (Two-Tier Penalty)
    // ====================================

    event StakeSlashed(
        address indexed operator,
        bytes32 indexed roleId,
        uint256 amount,
        string reason,
        uint256 timestamp
    );

    /**
     * @notice Slash operator's stake (DVT Validator only)
     * @param operator Operator to slash
     * @param roleId Role being slashed
     * @param penaltyAmount Amount of GToken to slash
     * @param reason Reason for slashing
     */
    function slashByDVT(
        address operator,
        bytes32 roleId,
        uint256 penaltyAmount,
        string calldata reason
    ) external {
        if (!authorizedSlashers[msg.sender]) revert NotAuthorizedSlasher();
        
        RoleLock storage lock = roleLocks[operator][roleId];
        if (lock.amount < penaltyAmount) revert InsufficientStake();
        
        // Deduct from role lock  
        lock.amount -= uint128(penaltyAmount);
        
        // H-01 FIX: Deduct from stake and track cumulative slashed
        StakeInfo storage stake = stakes[operator];
        if (stake.amount < penaltyAmount) revert InsufficientStake();
        stake.slashedAmount += penaltyAmount;  // Track cumulative slashed
        stake.amount -= penaltyAmount;         // Reduce actual balance
        totalStaked -= penaltyAmount;
        
        // Cleanup if lock is now zero
        if (lock.amount == 0) {
            _removeUserRole(operator, roleId);
        }

        // Transfer to treasury
        GTOKEN.safeTransfer(treasury, penaltyAmount);
        emit UserSlashed(operator, penaltyAmount, reason, block.timestamp);
    }

    /**
     * @notice Get operator's stake info for a role
     * @param operator Operator address
     * @param roleId Role identifier
     * @return Stake information (role-specific view)
     */
    function getStakeInfo(address operator, bytes32 roleId) external view returns (StakeInfo memory) {
        RoleLock memory lock = roleLocks[operator][roleId];
        StakeInfo memory stake = stakes[operator];
        
        return StakeInfo({
            amount: lock.amount,  // Already reduced by immediate slashes
            slashedAmount: stake.slashedAmount,
            stakedAt: lock.lockedAt,
            unstakeRequestedAt: 0
        });
    }
}
