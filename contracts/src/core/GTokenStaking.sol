// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/v3/IGTokenStaking.sol";

/**
 * @title GTokenStaking v3.1.0
 * @notice Unified Role-Based Staking System with True Burn
 * @dev Replaces v2 locker system with role-based locking
 *      Strictly couples staking with Registry roles
 *      
 * Version 3.1.0 Changes:
 * - Entry burn now uses true token destruction (ERC20Burnable.burn)
 * - totalSupply decreases on burn, creating auto-remint capacity
 * - Removed blackhole transfer (0xdead) pattern
 */
contract GTokenStaking is ReentrancyGuard, Ownable, IGTokenStaking {
    using SafeERC20 for IERC20;

    // ...

    function version() external pure override returns (string memory) {
        return "Staking-3.1.2";
    }

    // ====================================
    // Storage
    // ====================================

    IERC20 public immutable GTOKEN;
    address public REGISTRY;
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


    // Authorized slashers
    mapping(address => bool) public authorizedSlashers;

    // ====================================
    // Modifiers
    // ====================================

    modifier onlyRegistry() {
        if (msg.sender != REGISTRY) revert("Only Registry");
        _;
    }

    constructor(address _gtoken, address _treasury) Ownable(msg.sender) {
        if (_gtoken == address(0)) revert("Invalid GToken");
        if (_treasury == address(0)) revert("Invalid Treasury");
        GTOKEN = IERC20(_gtoken);
        treasury = _treasury;
    }

    function setRegistry(address _registry) external onlyOwner {
        if (_registry == address(0)) revert("Invalid Registry");
        REGISTRY = _registry;
    }

    // ====================================
    // Core Functions - Role Locking
    // ====================================

    /**
     * @notice Lock stake for a role (Registry only)
     * @dev Transfers tokens, burns entry fee (TRUE BURN), locks remainder
     * @custom:burn Entry burn uses ERC20Burnable.burn() to decrease totalSupply
     */
    function lockStake(
        address user,
        bytes32 roleId,
        uint256 stakeAmount,
        uint256 entryBurn,
        address payer
    ) external nonReentrant onlyRegistry returns (uint256 lockId) {
        if (roleLocks[user][roleId].amount > 0) revert("Role already locked");
        
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

        // Create lock
        RoleLock memory newLock = RoleLock({
            roleId: roleId,
            amount: stakeAmount, // Shares = Amount (1:1)
            entryBurn: entryBurn,
            lockedAt: block.timestamp,
            metadata: ""
        });
        
        roleLocks[user][roleId] = newLock;
        userActiveRoles[user].push(roleId);
        
        // Update global stats
        totalStaked += stakeAmount;

        emit StakeLocked(user, roleId, stakeAmount, entryBurn, block.timestamp);
        return uint256(roleId); // Use roleId as lockId
    }

    /**
     * @notice Unlock and transfer to user (Registry only)
     */
    function unlockAndTransfer(
        address user,
        bytes32 roleId
    ) external nonReentrant onlyRegistry returns (uint256 netAmount) {
        RoleLock storage lock = roleLocks[user][roleId];
        if (lock.lockedAt == 0) revert("No lock found");
        
        // Slashes are now handled immediately in slash() by transferring to treasury
        // and reducing totalStaked. Here we just process the remaining lock.
        uint256 originalAmount = lock.amount;
        
        // Update state before transfer (CEI)
        delete roleLocks[user][roleId];
        _removeUserRole(user, roleId);
        
        // Global accounting uses the original lock amount
        stakes[user].amount -= originalAmount;
        
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
        if (!authorizedSlashers[msg.sender] && msg.sender != REGISTRY) {
            revert("Unauthorized slasher");
        }

        StakeInfo storage info = stakes[user];
        uint256 available = info.amount > info.slashedAmount ? info.amount - info.slashedAmount : 0;
        
        slashedAmount = amount > available ? available : amount;
        
        if (slashedAmount > 0) {
            info.slashedAmount += slashedAmount;
            totalStaked -= slashedAmount;
            
            // For immediate transfer, we must also reduce the specific role locks
            // to keep totalStaked accounting consistent during unlockAndTransfer
            bytes32[] storage roles = userActiveRoles[user];
            uint256 remainingToSlash = slashedAmount;
            for (uint256 i = 0; i < roles.length && remainingToSlash > 0; i++) {
                RoleLock storage lock = roleLocks[user][roles[i]];
                uint256 deduct = remainingToSlash > lock.amount ? lock.amount : remainingToSlash;
                lock.amount -= deduct;
                remainingToSlash -= deduct;
            }

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

    function balanceOf(address user) external view returns (uint256) {
        StakeInfo memory info = stakes[user];
        if (info.slashedAmount >= info.amount) return 0;
        return info.amount - info.slashedAmount;
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
        if (msg.sender != REGISTRY && msg.sender != owner()) revert("Unauthorized");
        
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
        if (_treasury == address(0)) revert("Invalid Treasury");
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
        require(authorizedSlashers[msg.sender], "Not authorized slasher");
        
        RoleLock storage lock = roleLocks[operator][roleId];
        require(lock.amount >= penaltyAmount, "Insufficient stake");
        
        // Deduct from role lock
        lock.amount -= penaltyAmount;
        
        // Deduct from total stake
        StakeInfo storage stake = stakes[operator];
        require(stake.amount >= penaltyAmount, "Insufficient stake");
        stake.amount -= penaltyAmount;
        totalStaked -= penaltyAmount;
        
        // Transfer slashed amount to treasury
        GTOKEN.safeTransfer(treasury, penaltyAmount);
        
        emit StakeSlashed(operator, roleId, penaltyAmount, reason, block.timestamp);
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
