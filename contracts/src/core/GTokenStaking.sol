// SPDX-License-Identifier: Apache-2.0
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;
import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/v3/IGTokenStaking.sol";
import "../interfaces/v3/IRegistry.sol";

/**
 * @title GTokenStaking v4.2.0 — Unified Ticket Model
 * @notice Unified Role-Based Staking with Ticket Model (transfer to treasury)
 * @dev Single unified flow for all roles via lockStakeWithTicket():
 *      - stakeAmount=0: ticket-only (transfer to treasury, no lock)
 *      - stakeAmount>0: ticket to treasury + stake locked
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
        return "Staking-4.2.0";
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
     * @notice Unified registration: handle ticket + optional stake for any role
     * @dev Transfers (stakeAmount + ticketPrice) from payer.
     *      When stakeAmount=0: ticket-only, no lock created (for ENDUSER, COMMUNITY).
     *      When stakeAmount>0: ticket to treasury + stake locked (for operators).
     */
    function lockStakeWithTicket(
        address user,
        bytes32 roleId,
        uint256 stakeAmount,
        uint256 ticketPrice,
        address payer
    ) external nonReentrant onlyRegistry returns (uint256 lockId) {
        uint256 totalAmount = stakeAmount + ticketPrice;

        // CEI: validate and update all state before external calls
        if (stakeAmount > 0) {
            if (roleLocks[user][roleId].amount > 0) revert RoleAlreadyLocked();
            if (stakeAmount > type(uint128).max) revert AmountExceedsUint128();
            if (ticketPrice > type(uint128).max) revert AmountExceedsUint128();

            uint256 newTotal = totalStaked + stakeAmount;
            if (newTotal > MAX_TOTAL_STAKE) revert TotalStakeExceedsCap();

            totalStaked = newTotal;
            stakes[user].amount += stakeAmount;
            if (stakes[user].stakedAt == 0) {
                stakes[user].stakedAt = block.timestamp;
            }
            roleLocks[user][roleId] = RoleLock({
                amount: uint128(stakeAmount),
                ticketPrice: uint128(ticketPrice),
                lockedAt: uint48(block.timestamp),
                roleId: roleId,
                metadata: ""
            });
            userActiveRoles[user].push(roleId);
        }

        // External calls after state updates
        if (totalAmount > 0) {
            if (stakeAmount > 0) {
                // Stake + ticket: transfer to this contract first, then forward ticket to treasury
                GTOKEN.safeTransferFrom(payer, address(this), totalAmount);
                if (ticketPrice > 0) {
                    GTOKEN.safeTransfer(treasury, ticketPrice);
                }
            } else {
                // Ticket-only: transfer directly to treasury
                GTOKEN.safeTransferFrom(payer, treasury, ticketPrice);
            }
        }

        if (ticketPrice > 0) {
            emit TicketBurned(user, roleId, ticketPrice, payer);
        }
        if (stakeAmount > 0) {
            emit StakeLocked(user, roleId, stakeAmount, ticketPrice, block.timestamp);
        }

        // P0-14: Registry already updates `roleStakes[roleId][user]` in
        // `_firstTimeRegister` before reaching here, but we still push the
        // canonical amount to keep both sides in lockstep when this is
        // called from any non-registerRole entry point in the future.
        if (stakeAmount > 0) {
            _syncRegistry(user, roleId, roleLocks[user][roleId].amount);
        }

        // Ticket-only path creates no lock → return 0. Only stake locks have meaningful identifiers.
        if (stakeAmount == 0) return 0;
        return uint256(keccak256(abi.encode(user, roleId, block.number, totalStaked)));
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

        // Synchronize the updated stake amount to Registry so that role eligibility
        // reflects the new total. This keeps the Registry's roleStakes cache
        // consistent with Staking's internal roleLock, regardless of call ordering.
        _syncRegistry(user, roleId, lock.amount);
    }

    /**
     * @notice Unlock and transfer to user (Registry only)
     * @dev OPERATORS ONLY — Regular user roles (ENDUSER, COMMUNITY) have no exit.
     *      Registry enforces this by checking roleStakes before calling.
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

        // P0-14: lock has been deleted; reflect 0 in Registry's cache.
        // Registry.exitRole already sets `roleStakes[roleId][user] = 0`
        // before calling here, but the redundant sync makes the
        // post-condition explicit and safe under future call-graph changes.
        _syncRegistry(user, roleId, 0);

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

            // P0-14: snapshot the affected role list BEFORE _cleanupZeroLocks
            // mutates it, so we can sync each role's post-slash amount to
            // Registry. Roles are bytes32 — a memory copy is cheap.
            bytes32[] memory affectedRoles = new bytes32[](roles.length);
            uint256[] memory postSlashAmounts = new uint256[](roles.length);

            if (totalAmountAcrossLocks > 0) {
                for (uint256 i = 0; i < roles.length; i++) {
                    RoleLock storage lock = roleLocks[user][roles[i]];
                    // deduction = (lock.amount * slashedAmount) / totalAmountAcrossLocks
                    uint256 deduct = (uint256(lock.amount) * slashedAmount) / totalAmountAcrossLocks;
                    if (deduct > lock.amount) deduct = lock.amount;
                    lock.amount -= uint128(deduct);
                    affectedRoles[i] = roles[i];
                    postSlashAmounts[i] = lock.amount;
                }
            }

            // Cleanup zero-amount role locks to prevent storage bloat
            _cleanupZeroLocks(user);

            GTOKEN.safeTransfer(treasury, slashedAmount);

            // P0-14: push the post-slash per-role amounts to Registry so the
            // cache mirrors Staking. Done after `safeTransfer` per CEI; if
            // Registry reverts, slashing already landed (Staking is the
            // source of truth).
            for (uint256 i = 0; i < affectedRoles.length; i++) {
                _syncRegistry(user, affectedRoles[i], postSlashAmounts[i]);
            }
        }

        emit UserSlashed(user, slashedAmount, reason, block.timestamp);
        return slashedAmount;
    }

    // ====================================
    // Internal Helpers
    // ====================================

    /// @dev P0-14 (H-01): Push the post-mutation lock amount to Registry so
    ///      `roleStakes[roleId][user]` mirrors `roleLocks[user][roleId].amount`.
    ///      Wrapped in `try`/`catch` so a misconfigured / non-conforming
    ///      Registry implementation cannot brick Staking-side mutations
    ///      (Staking remains the canonical source of truth and exposes
    ///      `getLockedStake` / Registry.getEffectiveStake for fresh reads).
    function _syncRegistry(address user, bytes32 roleId, uint256 newAmount) internal {
        if (REGISTRY == address(0)) return;
        try IRegistry(REGISTRY).syncStakeFromStaking(user, roleId, newAmount) {} catch (bytes memory reason) {
            emit SyncFailed(REGISTRY, reason);
        }
    }

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
        RoleExitConfig storage config = roleExitConfigs[roleId];
        config.feePercent = feePercent;
        config.minFee = minFee;
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
    ) external nonReentrant {
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

        // Snapshot the post-slash lock amount BEFORE we potentially clean up
        // the userActiveRoles entry — Registry only cares about the final
        // per-role amount.
        uint256 postSlash = lock.amount;

        // Cleanup if lock is now zero
        if (lock.amount == 0) {
            _removeUserRole(operator, roleId);
        }

        // Transfer to treasury
        GTOKEN.safeTransfer(treasury, penaltyAmount);
        emit UserSlashed(operator, penaltyAmount, reason, block.timestamp);

        // P0-14 (H-01): keep Registry's roleStakes cache in lockstep with
        // Staking's roleLocks. Without this, an operator can `topUpStake`
        // against a stale cache after being slashed and silently
        // over-counts. We `try / catch` so a misconfigured Registry can't
        // brick slashing — Staking remains the source of truth.
        _syncRegistry(operator, roleId, postSlash);
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
