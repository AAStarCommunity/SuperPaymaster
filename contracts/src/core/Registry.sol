// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/v3/IRegistryV3.sol";
import "../interfaces/v3/IGTokenStakingV3.sol";
import "../interfaces/v3/IMySBTV3.sol";


contract Registry is Ownable, ReentrancyGuard, IRegistryV3 {
    using SafeERC20 for IERC20;

    struct CommunityRoleData { string name; string ensName; string website; string description; string logoURI; uint256 stakeAmount; }
    struct EndUserRoleData { address account; address community; string avatarURI; string ensName; uint256 stakeAmount; }
    struct PaymasterRoleData { address paymasterContract; string name; string apiEndpoint; uint256 stakeAmount; }
    struct KMSRoleData { address kmsContract; string name; string apiEndpoint; bytes32[] supportedAlgos; uint256 maxKeysPerUser; uint256 stakeAmount; }
    struct GenericRoleData { string name; bytes extraData; uint256 stakeAmount; }

    uint256 public constant VERSION_CODE = 30000;
    string public constant VERSION = "3.0.0";

    bytes32 public constant ROLE_COMMUNITY = keccak256("COMMUNITY");
    bytes32 public constant ROLE_ENDUSER = keccak256("ENDUSER");
    bytes32 public constant ROLE_PAYMASTER_AOA = keccak256("PAYMASTER_AOA");
    bytes32 public constant ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
    bytes32 public constant ROLE_KMS = keccak256("KMS");

    IGTokenStakingV3 public immutable GTOKEN_STAKING;
    IMySBTV3 public immutable MYSBT;

    mapping(bytes32 => RoleConfig) public roleConfigs;
    mapping(bytes32 => mapping(address => bool)) public hasRole;
    mapping(bytes32 => mapping(address => uint256)) public roleStakes;
    mapping(bytes32 => address[]) public roleMembers;
    mapping(bytes32 => mapping(address => uint256)) public roleSBTTokenIds;
    mapping(bytes32 => mapping(address => bytes)) public roleMetadata;

    mapping(string => address) public communityByNameV3;
    mapping(string => address) public communityByENSV3;
    mapping(address => address) public accountToUser;

    // V3.1 Credit & Reputation Storage
    mapping(address => uint256) public globalReputation;
    mapping(address => uint256) public lastReputationEpoch;
    mapping(uint256 => uint256) public creditTierConfig; // Level => Credit Limit
    mapping(address => bool) public isReputationSource;  // Trusted DVT Aggregators

    mapping(bytes32 => string) public proposedRoleNames;
    mapping(bytes32 => address) public roleOwners;
    mapping(bytes32 => uint256) public roleLockDurations; // NEW

    BurnRecord[] public burnHistory;
    mapping(address => uint256[]) public userBurnHistory;

    error InvalidParameter(string message);
    error RoleNotConfigured(bytes32 roleId);
    error RoleAlreadyGranted(bytes32 roleId, address user);
    error RoleNotGranted(bytes32 roleId, address user);
    error InsufficientStake(uint256 provided, uint256 required);

    constructor(address _gtoken, address _gtokenStaking, address _mysbt) Ownable(msg.sender) {
        require(_gtokenStaking != address(0), "Invalid Staking");
        require(_mysbt != address(0), "Invalid SBT");
        GTOKEN_STAKING = IGTokenStakingV3(_gtokenStaking);
        MYSBT = IMySBTV3(_mysbt);
        
        address regOwner = msg.sender;
        // NOTE: setRoleExitFee will be called by _initRole, but it will fail if REGISTRY is not set in GTokenStaking
        // The deployment script MUST call staking.setRegistry(address(registry)) BEFORE this constructor completes
        // OR we need to defer _initRole calls until after setRegistry
        // For now, we'll comment out _initRole and do it in the deployment script
        
        // Format: _initRole(roleId, minStake, entryBurn, slashThresh, slashBase, slashInc, slashMax, exitFeePercent, minExitFee, active, desc, owner)
        _initRole(ROLE_PAYMASTER_AOA, 30 ether, 3 ether, 10, 2, 1, 10, 1000, 1 ether, true, "AOA Paymaster", regOwner);
        _initRole(ROLE_PAYMASTER_SUPER, 50 ether, 5 ether, 10, 2, 1, 10, 1000, 2 ether, true, "SuperPaymaster", regOwner);
        _initRole(keccak256("ANODE"), 20 ether, 2 ether, 15, 1, 1, 5, 1000, 1 ether, true, "ANODE", regOwner);
        _initRole(ROLE_KMS, 100 ether, 10 ether, 5, 5, 2, 20, 1000, 5 ether, true, "KMS", regOwner);
        _initRole(ROLE_COMMUNITY, 30 ether, 3 ether, 10, 2, 1, 10, 500, 1 ether, true, "Community", regOwner);
        _initRole(ROLE_ENDUSER, 0.3 ether, 0.05 ether, 0, 0, 0, 0, 1000, 0.05 ether, true, "EndUser", regOwner);

        // Initialize Credit Tiers (Default in aPNTs)
        // Level 1: Rep < 13
        creditTierConfig[1] = 0; 
        // Level 2: Rep 13-33 (Fib 7)
        creditTierConfig[2] = 100 ether; 
        // Level 3: Rep 34-88 (Fib 9)
        creditTierConfig[3] = 300 ether;
        // Level 4: Rep 89-232 (Fib 11) 
        creditTierConfig[4] = 600 ether;
        // Level 5: Rep 233-609 (Fib 13)
        creditTierConfig[5] = 1000 ether;
        // Level 6: Rep 610+ (Fib 15)
        creditTierConfig[6] = 2000 ether;

        isReputationSource[regOwner] = true; // Owner is trusted for now (Bootstrapping)
    }

    function _initRole(
        bytes32 roleId, 
        uint256 min, 
        uint256 burn, 
        uint256 thresh, 
        uint256 base, 
        uint256 inc, 
        uint256 max,
        uint256 exitFeePercent,
        uint256 minExitFee,
        bool active, 
        string memory desc, 
        address owner
    ) internal {
        roleConfigs[roleId] = RoleConfig(min, burn, thresh, base, inc, max, exitFeePercent, minExitFee, active, desc);
        roleOwners[roleId] = owner;
        // NOTE: Skip setRoleExitFee during construction, will be set by deployment script
        // Calling setRoleExitFee here would fail because REGISTRY is not yet set in GTokenStaking
    }

    function registerRole(bytes32 roleId, address user, bytes calldata roleData) public nonReentrant {
        RoleConfig memory config = roleConfigs[roleId];
        if (!config.isActive) revert RoleNotConfigured(roleId);
        if (hasRole[roleId][user]) revert RoleAlreadyGranted(roleId, user);

        uint256 stakeAmount = _validateAndExtractStake(roleId, user, roleData);
        if (stakeAmount < config.minStake) revert InsufficientStake(stakeAmount, config.minStake);

        hasRole[roleId][user] = true;
        roleStakes[roleId][user] = stakeAmount;
        roleMembers[roleId].push(user);
        roleMetadata[roleId][user] = roleData;

        GTOKEN_STAKING.lockStake(user, roleId, stakeAmount, config.entryBurn, user);
        
        bytes memory sbtData = _convertRoleDataForSBT(roleId, user, roleData);
        (uint256 sbtTokenId, ) = MYSBT.mintForRole(user, roleId, sbtData);
        roleSBTTokenIds[roleId][user] = sbtTokenId;

        _postRegisterRole(roleId, user, roleData);

        emit RoleRegistered(roleId, user, config.entryBurn, block.timestamp);
    }

    function registerRoleSelf(bytes32 roleId, bytes calldata roleData) external returns (uint256 sbtTokenId) {
        registerRole(roleId, msg.sender, roleData);
        return roleSBTTokenIds[roleId][msg.sender];
    }

    function exitRole(bytes32 roleId) external nonReentrant {
        if (!hasRole[roleId][msg.sender]) revert RoleNotGranted(roleId, msg.sender);
        
        // --- TIMELOCK CHECK ---
        uint256 lockDuration = roleLockDurations[roleId];
        if (lockDuration > 0) {
            uint256 lockedAt;
            // Get lockedAt from Staking
            (,,,lockedAt,) = GTOKEN_STAKING.roleLocks(msg.sender, roleId);
            if (block.timestamp < lockedAt + lockDuration) revert("Lock duration not met");
        }

        uint256 stakedAmount = roleStakes[roleId][msg.sender];
        
        hasRole[roleId][msg.sender] = false;
        roleStakes[roleId][msg.sender] = 0;

        // --- SBT LINKAGE ---
        if (roleId == ROLE_ENDUSER) {
            bytes memory metadata = roleMetadata[roleId][msg.sender];
            if (metadata.length > 0) {
                EndUserRoleData memory data = abi.decode(metadata, (EndUserRoleData));
                MYSBT.deactivateMembership(msg.sender, data.community);
            }
        } else if (roleId == ROLE_COMMUNITY) {
             // For community role, we might want to deactivate its own record?
        }

        burnHistory.push(BurnRecord(roleId, msg.sender, stakedAmount, block.timestamp, "Exit"));
        userBurnHistory[msg.sender].push(burnHistory.length - 1);
        
        hasRole[roleId][msg.sender] = false;
        // Remove from roleMembers (O(n) but usually small members or handled by indexing)
        _removeFromRoleMembers(roleId, msg.sender);

        uint256 netAmount = GTOKEN_STAKING.unlockAndTransfer(msg.sender, roleId);
        
        emit RoleExited(roleId, msg.sender, stakedAmount - netAmount, block.timestamp);
    }

    function safeMintForRole(bytes32 roleId, address user, bytes calldata data) external nonReentrant returns (uint256 tokenId) {
        RoleConfig memory config = roleConfigs[roleId];
        if (!config.isActive) revert RoleNotConfigured(roleId);
        if (hasRole[roleId][user]) revert RoleAlreadyGranted(roleId, user);
        
        if (!hasRole[ROLE_COMMUNITY][msg.sender]) revert("Caller must be Community");

        uint256 stakeAmount = _validateAndExtractStake(roleId, user, data);
        if (stakeAmount < config.minStake) revert InsufficientStake(stakeAmount, config.minStake);

        hasRole[roleId][user] = true;
        roleStakes[roleId][user] = stakeAmount;
        roleMembers[roleId].push(user);
        roleMetadata[roleId][user] = data;

        GTOKEN_STAKING.lockStake(user, roleId, stakeAmount, config.entryBurn, msg.sender);
        
        bytes memory sbtData = _convertRoleDataForSBT(roleId, user, data);
        (uint256 sbtTokenId, ) = MYSBT.airdropMint(user, roleId, sbtData);
        roleSBTTokenIds[roleId][user] = sbtTokenId;

        _postRegisterRole(roleId, user, data);
        emit RoleRegistered(roleId, user, config.entryBurn, block.timestamp);
        return sbtTokenId;
    }

    function configureRole(bytes32 roleId, RoleConfig calldata config) external {
        if (msg.sender != roleOwners[roleId] && msg.sender != owner()) revert("Unauthorized");
        roleConfigs[roleId] = config;
        // Sync exit fee to GTokenStaking when role is reconfigured
        GTOKEN_STAKING.setRoleExitFee(roleId, config.exitFeePercent, config.minExitFee);
        emit RoleConfigured(roleId, config, block.timestamp);
    }
    
    /**
     * @notice Create a new role (Owner only)
     * @dev This allows the protocol admin to dynamically add new roles
     * @param roleId Unique role identifier (e.g., keccak256("NEW_ROLE"))
     * @param config Role configuration
     * @param roleOwner Address that will own this role (can reconfigure it later)
     */
    function createNewRole(bytes32 roleId, RoleConfig calldata config, address roleOwner) external onlyOwner {
        require(roleOwners[roleId] == address(0), "Role already exists");
        require(roleOwner != address(0), "Invalid owner");
        
        roleConfigs[roleId] = config;
        roleOwners[roleId] = roleOwner;
        
        // Sync exit fee to GTokenStaking
        GTOKEN_STAKING.setRoleExitFee(roleId, config.exitFeePercent, config.minExitFee);
        
        emit RoleConfigured(roleId, config, block.timestamp);
    }

    /**
     * @notice Set the owner of a role (Protocol Admin only)
     * @param roleId Role to update
     * @param newOwner New owner address
     */
    function setRoleOwner(bytes32 roleId, address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        roleOwners[roleId] = newOwner;
        // No event needed specifically for ownership transfer in minimal V3, but can be added if needed
    }

    // ====================================
    // V3.1: Reputation & Credit Management
    // ====================================

    event GlobalReputationUpdated(address indexed user, uint256 newScore, uint256 epoch);
    event CreditTierUpdated(uint256 level, uint256 creditLimit);
    event ReputationSourceUpdated(address indexed source, bool isActive);

    /**
     * @notice Batch update global reputation (called by DVT Aggregator or Reputation System)
     * @dev Uses Epoch to prevent replay attacks.
     *      Safety: Limits the maximum score change per update to prevent malicious spikes.
     */
    function batchUpdateGlobalReputation(
        address[] calldata users,
        uint256[] calldata newScores,
        uint256 epoch,
        bytes calldata /* proof */
    ) external nonReentrant {
        if (!isReputationSource[msg.sender]) revert("Unauthorized Reputation Source");
        require(users.length == newScores.length, "Length mismatch");

        uint256 maxChange = 100; // Protocol safety limit

        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];

            if (epoch <= lastReputationEpoch[user]) {
                continue;
            }

            uint256 oldScore = globalReputation[user];
            uint256 newScore = newScores[i];

            // Safety check: Prevent extreme swings
            if (newScore > oldScore) {
                if (newScore - oldScore > maxChange) newScore = oldScore + maxChange;
            } else if (oldScore > newScore) {
                if (oldScore - newScore > maxChange) newScore = oldScore - maxChange;
            }

            globalReputation[user] = newScore;
            lastReputationEpoch[user] = epoch;

            emit GlobalReputationUpdated(user, newScore, epoch);
        }
    }

    function setCreditTier(uint256 level, uint256 limit) external onlyOwner {
        creditTierConfig[level] = limit;
        emit CreditTierUpdated(level, limit);
    }

    function setReputationSource(address source, bool active) external onlyOwner {
        isReputationSource[source] = active;
        emit ReputationSourceUpdated(source, active);
    }

    function getCreditLimit(address user) external view returns (uint256) {
        uint256 rep = globalReputation[user];
        
        // Simple mapping logic (can be optimized or moved to library)
        // 0-10: Level 1 (0 credit)
        // 11-50: Level 2
        // 51-100: Level 3
        // 101-500: Level 4
        // >500: Level 5
        
        uint256 level = 1;
        if (rep >= 610) level = 6;
        else if (rep >= 233) level = 5;
        else if (rep >= 89) level = 4;
        else if (rep >= 34) level = 3;
        else if (rep >= 13) level = 2;

        return creditTierConfig[level];
    }

    function _validateAndExtractStake(bytes32 roleId, address user, bytes calldata roleData) internal view returns (uint256 stakeAmount) {
        if (roleId == ROLE_COMMUNITY) {
            CommunityRoleData memory data = abi.decode(roleData, (CommunityRoleData));
            if (bytes(data.name).length == 0) revert InvalidParameter("Name required");
            if (communityByNameV3[data.name] != address(0)) revert InvalidParameter("Name taken");
            stakeAmount = data.stakeAmount;
        } else if (roleId == ROLE_ENDUSER) {
            EndUserRoleData memory data = abi.decode(roleData, (EndUserRoleData));
            bool commActive = hasRole[ROLE_COMMUNITY][data.community];
            if (!commActive) revert InvalidParameter("Invalid community");
            stakeAmount = data.stakeAmount;
        } else {
            if (roleData.length == 32) stakeAmount = abi.decode(roleData, (uint256));
        }
        if (stakeAmount == 0) stakeAmount = roleConfigs[roleId].minStake;
    }

    function _convertRoleDataForSBT(bytes32 roleId, address user, bytes calldata roleData) internal pure returns (bytes memory) {
        if (roleId == ROLE_ENDUSER) {
            EndUserRoleData memory data = abi.decode(roleData, (EndUserRoleData));
            return abi.encode(data.community, "");
        }
        return abi.encode(user, "");
    }

    function _postRegisterRole(bytes32 roleId, address user, bytes calldata roleData) internal {
        if (roleId == ROLE_COMMUNITY) {
            CommunityRoleData memory data = abi.decode(roleData, (CommunityRoleData));
            communityByNameV3[data.name] = user;
            if (bytes(data.ensName).length > 0) communityByENSV3[data.ensName] = user;
        } else if (roleId == ROLE_ENDUSER) {
            EndUserRoleData memory data = abi.decode(roleData, (EndUserRoleData));
            accountToUser[data.account] = user;
        }
    }
    
    // View Functions
    function checkRole(bytes32 roleId, address user) external view returns (bool) { return hasRole[roleId][user]; }
    function getRoleConfig(bytes32 roleId) external view returns (RoleConfig memory) { return roleConfigs[roleId]; }
    function getUserRoles(address user) external view returns (bytes32[] memory) {
        // Find all roles this user has
        bytes32[3] memory allRoles = [ROLE_KMS, ROLE_COMMUNITY, ROLE_ENDUSER];
        uint256 count = 0;
        for(uint i=0; i<3; i++){
            if(hasRole[allRoles[i]][user]) count++;
        }
        bytes32[] memory roles = new bytes32[](count);
        uint256 idx = 0;
        for(uint i=0; i<3; i++){
            if(hasRole[allRoles[i]][user]) roles[idx++] = allRoles[i];
        }
        return roles;
    }
    
    function getBurnHistory(address user) external view returns (BurnRecord[] memory) {
        uint256[] memory indices = userBurnHistory[user];
        BurnRecord[] memory userHistory = new BurnRecord[](indices.length);
        for(uint i=0; i<indices.length; i++) {
            userHistory[i] = burnHistory[indices[i]];
        }
        return userHistory;
    }

    function getAllBurnHistory() external view returns (BurnRecord[] memory) { return burnHistory; }

    function calculateExitFee(bytes32 roleId, uint256 amount) external view returns (uint256) {
        (uint256 fee, ) = GTOKEN_STAKING.previewExitFee(address(0), roleId); // Mock address(0) if not used by staking logic
        // Or if staking logic needs user:
        // (uint256 fee, ) = GTOKEN_STAKING.previewExitFee(msg.sender, roleId);
        return fee;
    }

    function getRoleMembers(bytes32 roleId) external view returns (address[] memory) { return roleMembers[roleId]; }
    function getRoleUserCount(bytes32 roleId) external view returns (uint256) { return roleMembers[roleId].length; }

    function _removeFromRoleMembers(bytes32 roleId, address user) internal {
        address[] storage members = roleMembers[roleId];
        for (uint256 i = 0; i < members.length; i++) {
            if (members[i] == user) {
                members[i] = members[members.length - 1];
                members.pop();
                break;
            }
        }
    }
}
