// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/v3/IGTokenStakingV3.sol";

/**
 * @title GTokenStaking v3.0.0
 * @notice Unified Role-Based Staking System
 * @dev Replaces v2 locker system with role-based locking
 *      Strictly couples staking with Registry roles
 */
contract GTokenStaking is Ownable, ReentrancyGuard, IGTokenStakingV3 {
    using SafeERC20 for IERC20;

    // ====================================
    // Constants
    // ====================================

    string public constant VERSION = "3.0.0";
    uint256 public constant VERSION_CODE = 30000;
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

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
    uint256 public totalShares;

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
     * @dev Transfers tokens, burns entry fee, locks remainder
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
        
        // Handle entry burn
        if (entryBurn > 0) {
            GTOKEN.safeTransfer(BURN_ADDRESS, entryBurn);
            emit TokensBurned(user, roleId, entryBurn, "Entry Burn");
        }
        
        // Update user global stake info
        stakes[user].amount += stakeAmount;
        stakes[user].stGTokenShares += stakeAmount; // 1:1 ratio
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
        totalShares += stakeAmount;

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
        if (lock.amount == 0) revert("No lock found");
        
        uint256 originalAmount = lock.amount;
        uint256 slashDeduction = 0;
        
        // Handle slashes from global debt
        StakeInfo storage info = stakes[user];
        if (info.slashedAmount > 0) {
            slashDeduction = originalAmount > info.slashedAmount ? info.slashedAmount : originalAmount;
            info.slashedAmount -= slashDeduction;
            
            // Tokens already in contract, just transfer the slashed part to treasury
            GTOKEN.safeTransfer(treasury, slashDeduction);
        }

        uint256 grossForFee = originalAmount - slashDeduction;
        uint256 exitFee = 0;
        
        // Calculate fee on remaining amount
        (exitFee, netAmount) = _previewExitFee(user, roleId, grossForFee);
        
        // Update state before transfer (CEI)
        delete roleLocks[user][roleId];
        _removeUserRole(user, roleId);
        
        // Global accounting uses the original lock amount
        stakes[user].amount -= originalAmount;
        stakes[user].stGTokenShares -= originalAmount;
        
        totalStaked -= originalAmount;
        totalShares -= originalAmount;

        // Transfers
        if (exitFee > 0) {
            GTOKEN.safeTransfer(treasury, exitFee);
        }
        
        if (netAmount > 0) {
            GTOKEN.safeTransfer(user, netAmount);
        }

        emit StakeUnlocked(user, roleId, originalAmount, exitFee + slashDeduction, netAmount, block.timestamp);
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
            // Note: Actual token transfer happens at unstake/unlock time if we followed strict stETH
            // But here, since we lock specific amounts for roles, we should probably reduce the lock?
            // V3 Design: User-level slash affects global balance. 
            // Since locks are specific, we just mark the user as slashed.
            // But if a role exits, can they withdraw full amount?
            // In unlockAndTransfer, we return `netAmount`. 
            // If slashed, we should probably deduct there too? 
            // Current V3 implementation in interface suggests `slash` just updates state.
            // But logic needs to enforce it.
            // For simplicity in this V3 migration: We track slashedAmount. 
            // But `unlockAndTransfer` logic above uses `lock.amount`. 
            // If slashed, `stakes[user].amount` is used for accounting but `lock.amount` is specific.
            // We'll trust the simple slash tracking for now as per V2.
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

    function sharesOf(address user) external view returns (uint256) {
        return stakes[user].stGTokenShares;
    }

    function previewExitFee(address user, bytes32 roleId) external view returns (uint256 fee, uint256 netAmount) {
        uint256 amount = roleLocks[user][roleId].amount;
        return _previewExitFee(user, roleId, amount);
    }

    // Use default getter for totalStaked/totalShares

    function convertToAssets(uint256 shares) external pure returns (uint256) {
        return shares; // 1:1
    }

    function convertToShares(uint256 amount) external pure returns (uint256) {
        return amount; // 1:1
    }

    // ====================================
    // Admin Functions
    // ====================================

    function setRoleExitFee(bytes32 roleId, uint256 feePercent, uint256 minFee) external {
        require(msg.sender == owner() || msg.sender == REGISTRY, "Only owner or registry");
        roleExitConfigs[roleId] = RoleExitConfig(feePercent, minFee);
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
    // FIXME: This function has incorrect mapping access
    // stakes is mapping(address => StakeInfo), not mapping(address => mapping(bytes32 => StakeInfo))
    // function slashByDVT(
    //     address operator,
    //     bytes32 roleId,
    //     uint256 penaltyAmount,
    //     string calldata reason
    // ) external {
    //     require(authorizedSlashers[msg.sender], "Not authorized slasher");
    //     
    //     StakeInfo storage stake = stakes[operator][roleId];
    //     require(stake.lockedAmount >= penaltyAmount, "Insufficient stake");
    //     
    //     // Deduct from locked stake
    //     stake.lockedAmount -= penaltyAmount;
    //     totalStaked -= penaltyAmount;
    //     
    //     // Transfer slashed amount to treasury
    //     require(GTOKEN.transfer(treasury, penaltyAmount), "Transfer failed");
    //     
    //     emit StakeSlashed(operator, roleId, penaltyAmount, reason, block.timestamp);
    // }

    /**
     * @notice Get operator's stake info for a role
     * @param operator Operator address
     * @param roleId Role identifier
     * @return Stake information
     */
    // FIXME: This function has incorrect mapping access
    // function getStakeInfo(address operator, bytes32 roleId) external view returns (StakeInfo memory) {
    //     return stakes[operator][roleId];
    // }
}
