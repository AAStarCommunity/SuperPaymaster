// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import "../interfaces/v3/IRegistry.sol";
import "../interfaces/v3/IGTokenStaking.sol";
import "../interfaces/v3/IMySBT.sol";
import "../interfaces/ISuperPaymaster.sol";
import "../interfaces/v3/IBLSAggregator.sol";
import "../interfaces/v3/IBLSValidator.sol";


contract Registry is Ownable, ReentrancyGuard, IRegistry {
    using SafeERC20 for IERC20;

    struct CommunityRoleData { string name; string ensName; string website; string description; string logoURI; uint256 stakeAmount; }
    struct EndUserRoleData { address account; address community; string avatarURI; string ensName; uint256 stakeAmount; }
    struct PaymasterRoleData { address paymasterContract; string name; string apiEndpoint; uint256 stakeAmount; }
    struct KMSRoleData { address kmsContract; string name; string apiEndpoint; bytes32[] supportedAlgos; uint256 maxKeysPerUser; uint256 stakeAmount; }
    struct GenericRoleData { string name; bytes extraData; uint256 stakeAmount; }



    function version() external pure override returns (string memory) {
        return "Registry-3.0.2";
    }

    // --- Constants ---
    bytes32 public constant ROLE_COMMUNITY = keccak256("COMMUNITY");
    bytes32 public constant ROLE_ENDUSER = keccak256("ENDUSER");
    bytes32 public constant ROLE_PAYMASTER_AOA = keccak256("PAYMASTER_AOA");
    bytes32 public constant ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
    bytes32 public constant ROLE_DVT = keccak256("DVT");
    bytes32 public constant ROLE_ANODE = keccak256("ANODE");
    bytes32 public constant ROLE_KMS = keccak256("KMS");
    
    // BLS constants moved to implementation contract (Strategy Pattern)

    // --- Storage ---
    IGTokenStaking public GTOKEN_STAKING;
    IMySBT public MYSBT;
    address public SUPER_PAYMASTER;
    address public blsAggregator;
    IBLSValidator public blsValidator;

    mapping(bytes32 => RoleConfig) public roleConfigs;
    mapping(bytes32 => mapping(address => bool)) public hasRole;
    mapping(bytes32 => mapping(address => uint256)) public roleStakes;
    mapping(bytes32 => address[]) public roleMembers;
    mapping(bytes32 => mapping(address => uint256)) public roleMemberIndex; // 1-based index (0 means not in array)
    mapping(bytes32 => mapping(address => uint256)) public roleSBTTokenIds;
    mapping(bytes32 => mapping(address => bytes)) public roleMetadata;

    mapping(string => address) public communityByName;
    mapping(string => address) public communityByENS;
    mapping(address => address) public accountToUser;

    // V3.1 Credit & Reputation Storage
    mapping(address => uint256) public globalReputation;
    mapping(address => uint256) public lastReputationEpoch;
    mapping(uint256 => uint256) public creditTierConfig; // Level => Credit Limit
    mapping(address => bool) public isReputationSource;  // Trusted DVT Aggregators
    
    // V3.2: Dynamic Level Thresholds (Reputation Score → Level)
    // levelThresholds[i] = minimum reputation score for level i+2 (level 1 is default)
    // Example: levelThresholds[0] = 13 means rep >= 13 → level 2
    uint256[] public levelThresholds;

    mapping(bytes32 => string) public proposedRoleNames;
    mapping(bytes32 => address) public roleOwners;
    mapping(bytes32 => uint256) public roleLockDurations; // NEW

    error InvalidParameter(string message);
    error RoleNotConfigured(bytes32 roleId, bool isActive);
    error RoleAlreadyGranted(bytes32 roleId, address user);
    error RoleNotGranted(bytes32 roleId, address user);
    error InsufficientStake(uint256 provided, uint256 required);

    constructor(address _gtoken, address _gtokenStaking, address _mysbt) Ownable(msg.sender) {
        GTOKEN_STAKING = IGTokenStaking(_gtokenStaking);
        MYSBT = IMySBT(_mysbt);
        
        address regOwner = msg.sender;
        // NOTE: setRoleExitFee will be called by _initRole, but it will fail if REGISTRY is not set in GTokenStaking
        // The deployment script MUST call staking.setRegistry(address(registry)) BEFORE this constructor completes
        // OR we need to defer _initRole calls until after setRegistry
        // For now, we'll comment out _initRole and do it in the deployment script
        
        // Format: _initRole(roleId, minStake, entryBurn, slashThresh, slashBase, slashInc, slashMax, exitFeePercent, minExitFee, active, desc, owner)
        _initRole(ROLE_PAYMASTER_AOA, 30 ether, 3 ether, 10, 2, 1, 10, 1000, 1 ether, true, "AOA Paymaster", regOwner, 30 days);
        _initRole(ROLE_PAYMASTER_SUPER, 50 ether, 5 ether, 10, 2, 1, 10, 1000, 2 ether, true, "SuperPaymaster", regOwner, 30 days);
        _initRole(ROLE_DVT, 30 ether, 3 ether, 10, 2, 1, 10, 1000, 1 ether, true, "Generic DVT", regOwner, 30 days);
        _initRole(ROLE_ANODE, 20 ether, 2 ether, 15, 1, 1, 5, 1000, 1 ether, true, "ANODE", regOwner, 30 days);


        _initRole(ROLE_KMS, 100 ether, 10 ether, 5, 5, 2, 20, 1000, 5 ether, true, "KMS", regOwner, 30 days);
        _initRole(ROLE_COMMUNITY, 30 ether, 3 ether, 10, 2, 1, 10, 500, 1 ether, true, "Community", regOwner, 30 days);
        _initRole(ROLE_ENDUSER, 0.3 ether, 0.05 ether, 0, 0, 0, 0, 1000, 0.05 ether, true, "EndUser", regOwner, 7 days);

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

        // Initialize Level Thresholds (Fibonacci sequence)
        // levelThresholds[i] = min reputation for level i+2 (level 1 is default)
        levelThresholds.push(13);   // Level 2: rep >= 13
        levelThresholds.push(34);   // Level 3: rep >= 34
        levelThresholds.push(89);   // Level 4: rep >= 89
        levelThresholds.push(233);  // Level 5: rep >= 233
        levelThresholds.push(610);  // Level 6: rep >= 610

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
        address owner,
        uint256 lockDuration
    ) internal {
        roleConfigs[roleId] = RoleConfig(min, burn, thresh, base, inc, max, exitFeePercent, minExitFee, active, desc);
        roleOwners[roleId] = owner;
        roleLockDurations[roleId] = lockDuration;
        // Automatically set exit fee in staking contract if setup correctly
        // NOTE: If this fails during deployment, ensure staking.setRegistry(address(this)) is called first.
        if (address(GTOKEN_STAKING) != address(0) && address(GTOKEN_STAKING).code.length > 0) {
            try GTOKEN_STAKING.setRoleExitFee(roleId, exitFeePercent, minExitFee) {} catch {}
        }
    }


    function setStaking(address _staking) external onlyOwner {
        GTOKEN_STAKING = IGTokenStaking(_staking);
    }

    function setMySBT(address _mysbt) external onlyOwner {
        MYSBT = IMySBT(_mysbt);
    }

    function setSuperPaymaster(address _sp) external onlyOwner {
        SUPER_PAYMASTER = _sp;
    }

    function setBLSAggregator(address _aggregator) external onlyOwner {
        blsAggregator = _aggregator;
    }

    function setBLSValidator(address _validator) external onlyOwner {
        blsValidator = IBLSValidator(_validator);
    }

    function registerRole(bytes32 roleId, address user, bytes calldata roleData) public nonReentrant {
        RoleConfig memory config = roleConfigs[roleId];
        if (!config.isActive) revert RoleNotConfigured(roleId, config.isActive);
        
        // IDEMPOTENT only for ROLE_ENDUSER to support multi-community joining.
        // For other roles, keep it strict to avoid configuration corruption.
        bool alreadyHasRole = hasRole[roleId][user];
        if (alreadyHasRole && roleId != ROLE_ENDUSER) revert RoleAlreadyGranted(roleId, user);

        // BUS-RULE: Must be Community to be Paymaster
        if (roleId == ROLE_PAYMASTER_SUPER || roleId == ROLE_PAYMASTER_AOA) {
             if (!hasRole[ROLE_COMMUNITY][user]) revert RoleNotGranted(ROLE_COMMUNITY, user);
        }

        uint256 stakeAmount = _validateAndExtractStake(roleId, user, roleData);
        if (stakeAmount < config.minStake) revert InsufficientStake(stakeAmount, config.minStake);

        if (!alreadyHasRole) {
            // First time registration: Full flow
            hasRole[roleId][user] = true;
            roleStakes[roleId][user] = stakeAmount;
            roleMembers[roleId].push(user);
            roleMemberIndex[roleId][user] = roleMembers[roleId].length; // 1-based
            
            // Lock stake with entryBurn for first-time registration
            GTOKEN_STAKING.lockStake(user, roleId, stakeAmount, config.entryBurn, user);
        }
        
        // Always update metadata (supports multiple communities)
        roleMetadata[roleId][user] = roleData;

        // Always call MySBT.mintForRole (idempotent at MySBT level)
        // MySBT will mint new SBT on first call, add membership on subsequent calls
        bytes memory sbtData = _convertRoleDataForSBT(roleId, user, roleData);
        (uint256 sbtTokenId, bool isNewMint) = MYSBT.mintForRole(user, roleId, sbtData);
        roleSBTTokenIds[roleId][user] = sbtTokenId;

        _postRegisterRole(roleId, user, roleData);

        // Emit event with 0 burn for re-registration
        emit RoleRegistered(roleId, user, alreadyHasRole ? 0 : config.entryBurn, block.timestamp);
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
            // RELEASE NAMESPACE: If a community exits, we release the name so it can be reclaimed
            // but the historical transactions remain tied to the 'user' address in events.
            bytes memory metadata = roleMetadata[roleId][msg.sender];
            if (metadata.length > 0) {
                CommunityRoleData memory data = abi.decode(metadata, (CommunityRoleData));
                if (communityByName[data.name] == msg.sender) {
                    delete communityByName[data.name];
                }
                if (bytes(data.ensName).length > 0 && communityByENS[data.ensName] == msg.sender) {
                    delete communityByENS[data.ensName];
                }
            }
            // V3: Deactivate community's own SBT membership
            MYSBT.deactivateMembership(msg.sender, msg.sender);
        }

        emit BurnExecuted(msg.sender, roleId, stakedAmount, "Exit");
        
        hasRole[roleId][msg.sender] = false;
        // Remove from roleMembers (O(n) but usually small members or handled by indexing)
        _removeFromRoleMembers(roleId, msg.sender);

        // Sync SBT removal to SuperPaymaster if no identity roles left
        if (this.getUserRoles(msg.sender).length == 0) {
            if (SUPER_PAYMASTER != address(0)) {
                ISuperPaymaster(SUPER_PAYMASTER).updateSBTStatus(msg.sender, false);
            }
            // ⚡ FINAL CLOSURE: Burn the physical SBT badge as well
            MYSBT.burnSBT(msg.sender);
        }

        uint256 netAmount = GTOKEN_STAKING.unlockAndTransfer(msg.sender, roleId);
        
        emit RoleExited(roleId, msg.sender, stakedAmount - netAmount, block.timestamp);
    }

    function safeMintForRole(bytes32 roleId, address user, bytes calldata data) external nonReentrant returns (uint256 tokenId) {
        RoleConfig memory config = roleConfigs[roleId];
        if (!config.isActive) revert RoleNotConfigured(roleId, config.isActive);
        if (hasRole[roleId][user]) revert RoleAlreadyGranted(roleId, user);
        
        if (!hasRole[ROLE_COMMUNITY][msg.sender]) revert("Caller must be Community");

        // BUS-RULE: Must be Community to be Paymaster
        if (roleId == ROLE_PAYMASTER_SUPER || roleId == ROLE_PAYMASTER_AOA) {
             if (!hasRole[ROLE_COMMUNITY][user]) revert RoleNotGranted(ROLE_COMMUNITY, user);
        }

        uint256 stakeAmount = _validateAndExtractStake(roleId, user, data);
        if (stakeAmount < config.minStake) revert InsufficientStake(stakeAmount, config.minStake);

        hasRole[roleId][user] = true;
        roleStakes[roleId][user] = stakeAmount;
        roleMembers[roleId].push(user);
        roleMemberIndex[roleId][user] = roleMembers[roleId].length; // 1-based
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
        require(config.exitFeePercent <= 2000, "Fee too high");
        roleConfigs[roleId] = config;
        // Sync exit fee to GTokenStaking when role is reconfigured
        GTOKEN_STAKING.setRoleExitFee(roleId, config.exitFeePercent, config.minExitFee);
        emit RoleConfigured(roleId, config, block.timestamp);
    }

    /**
     * @notice Admin-only role configuration with full parameter control
     */
    function adminConfigureRole(
        bytes32 roleId,
        uint256 minStake,
        uint256 entryBurn,
        uint256 exitFeePercent,
        uint256 minExitFee
    ) external onlyOwner {
        require(exitFeePercent <= 2000, "Fee too high");
        RoleConfig storage config = roleConfigs[roleId];
        config.minStake = minStake;
        config.entryBurn = entryBurn;
        config.exitFeePercent = exitFeePercent;
        config.minExitFee = minExitFee;
        
        GTOKEN_STAKING.setRoleExitFee(roleId, exitFeePercent, minExitFee);
        emit RoleConfigured(roleId, config, block.timestamp);
    }

    function setRoleLockDuration(bytes32 roleId, uint256 duration) external {
        if (msg.sender != roleOwners[roleId] && msg.sender != owner()) revert("Unauthorized");
        roleLockDurations[roleId] = duration;
        emit RoleLockDurationUpdated(roleId, duration);
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
        bytes calldata proof
    ) external nonReentrant {
        if (!isReputationSource[msg.sender]) revert("Unauthorized Reputation Source");
        require(users.length == newScores.length, "Length mismatch");

        // --- BLS12-381 PAIRING CHECK (EIP-2537) ---
        require(proof.length > 0, "BLS Proof required");
        
        // proof: abi.encode(bytes aggregatedPkG1, bytes aggregatedSigG2, bytes msgG2, uint256 signerMask)
        (bytes memory pkG1, bytes memory sigG2, bytes memory msgG2, uint256 signerMask) = abi.decode(proof, (bytes, bytes, bytes, uint256));
        
        // Check threshold from aggregator or default to 3
        uint256 count = _countSetBits(signerMask);
        uint256 threshold = 3; // Minimum allowed as per requirement
        if (blsAggregator != address(0)) {
            try IBLSAggregator(blsAggregator).threshold() returns (uint256 t) {
                threshold = t;
            } catch {
                // Fallback to 3 if call fails
            }
        }
        require(count >= threshold, "Insufficient consensus threshold");

        // Strategy Pattern for BLS Verification
        if (address(blsValidator) != address(0)) {
            // CRITICAL FIX: Bind message to specific context (epoch + users + newScores)
            // Reconstruct the message that was ostensibly signed
            bytes memory message = abi.encodePacked(
                keccak256(abi.encode(epoch, users, newScores))
            );
            
            require(blsValidator.verifyProof(proof, message), "Registry: BLS Verification Failed");
        } else {
            revert("BLS Validator not configured");
        }

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

    /**
     * @notice Update operator blacklist (via DVT consensus)
     * @dev Forwards the update to SuperPaymaster
     */
    function updateOperatorBlacklist(
        address operator,
        address[] calldata users,
        bool[] calldata statuses,
        bytes calldata proof
    ) external nonReentrant {
        if (!isReputationSource[msg.sender]) revert("Unauthorized Reputation Source");
        require(users.length == statuses.length, "Length mismatch");
        require(SUPER_PAYMASTER != address(0), "SuperPaymaster not set");

        // --- BLS Verification ---
        if (address(blsValidator) != address(0) && proof.length > 0) {
             bytes memory message = abi.encode(operator, users, statuses);
             require(blsValidator.verifyProof(proof, message), "Registry: BLS Verification Failed");
        }

        // Forward to SuperPaymaster
        ISuperPaymaster(SUPER_PAYMASTER).updateBlockedStatus(operator, users, statuses);
    }

    function setCreditTier(uint256 level, uint256 limit) external onlyOwner {
        creditTierConfig[level] = limit;
        emit CreditTierUpdated(level, limit);
    }

    function setReputationSource(address source, bool active) external onlyOwner {
        isReputationSource[source] = active;
        emit ReputationSourceUpdated(source, active);
    }

    /**
     * @notice Set or update a level threshold
     * @param index Index in levelThresholds array (0-based)
     * @param threshold Minimum reputation score for this level
     * @dev levelThresholds[i] defines the min score for level i+2 (level 1 is default)
     */
    function setLevelThreshold(uint256 index, uint256 threshold) external onlyOwner {
        require(index < levelThresholds.length, "Index out of bounds");
        if (index > 0) {
            require(threshold > levelThresholds[index - 1], "Thresholds must be ascending");
        }
        if (index < levelThresholds.length - 1) {
            require(threshold < levelThresholds[index + 1], "Thresholds must be ascending");
        }
        levelThresholds[index] = threshold;
    }

    /**
     * @notice Add a new level threshold (extends the level system)
     * @param threshold Minimum reputation score for the new level
     */
    function addLevelThreshold(uint256 threshold) external onlyOwner {
        if (levelThresholds.length > 0) {
            require(threshold > levelThresholds[levelThresholds.length - 1], "Threshold must be higher than last");
        }
        levelThresholds.push(threshold);
    }

    function getCreditLimit(address user) external view returns (uint256) {
        uint256 rep = globalReputation[user];
        
        // Dynamic level lookup using threshold array
        uint256 level = 1; // Default level
        
        // Linear scan from highest to lowest (optimized for common case: high rep users)
        for (uint256 i = levelThresholds.length; i > 0; i--) {
            if (rep >= levelThresholds[i - 1]) {
                level = i + 1; // levelThresholds[0] → level 2, etc.
                break;
            }
        }

        return creditTierConfig[level];
    }

    function _decodeCommunityData(bytes calldata roleData) internal pure returns (CommunityRoleData memory data) {
        if (roleData.length >= 32 && bytes32(roleData[0:32]) == bytes32(uint256(0x20))) {
            data = abi.decode(roleData, (CommunityRoleData));
        } else {
            (string memory n, string memory e, string memory w, string memory d, string memory l, uint256 s) = 
                abi.decode(roleData, (string, string, string, string, string, uint256));
            data = CommunityRoleData(n, e, w, d, l, s);
        }
    }

    function _decodeEndUserData(bytes calldata roleData) internal pure returns (EndUserRoleData memory data) {
        if (roleData.length >= 32 && bytes32(roleData[0:32]) == bytes32(uint256(0x20))) {
            data = abi.decode(roleData, (EndUserRoleData));
        } else {
            (address acc, address comm, string memory avatar, string memory ens, uint256 stake) = 
                abi.decode(roleData, (address, address, string, string, uint256));
            data = EndUserRoleData(acc, comm, avatar, ens, stake);
        }
    }

    function _validateAndExtractStake(bytes32 roleId, address user, bytes calldata roleData) internal view returns (uint256 stakeAmount) {
        RoleConfig memory config = roleConfigs[roleId];
        if (roleId == ROLE_COMMUNITY) {
            CommunityRoleData memory data = _decodeCommunityData(roleData);
            if (bytes(data.name).length == 0) revert InvalidParameter("Name required");
            if (communityByName[data.name] != address(0)) revert InvalidParameter("Name taken");
            stakeAmount = data.stakeAmount;
        } else if (roleId == ROLE_ENDUSER) {
            EndUserRoleData memory data = _decodeEndUserData(roleData);
            bool commActive = hasRole[ROLE_COMMUNITY][data.community];
            if (!commActive) revert InvalidParameter("Invalid community");
            stakeAmount = data.stakeAmount;
        } else {
            if (roleData.length == 32) stakeAmount = abi.decode(roleData, (uint256));
        }
        if (stakeAmount == 0) stakeAmount = config.minStake;
    }

    function _convertRoleDataForSBT(bytes32 roleId, address user, bytes calldata roleData) internal pure returns (bytes memory) {
        if (roleId == ROLE_ENDUSER) {
            EndUserRoleData memory data = _decodeEndUserData(roleData);
            return abi.encode(data.community, "");
        }
        return abi.encode(user, "");
    }

    function _postRegisterRole(bytes32 roleId, address user, bytes calldata roleData) internal {
        // Sync SBT status to SuperPaymaster (System Qualification)
        if (SUPER_PAYMASTER != address(0)) {
            ISuperPaymaster(SUPER_PAYMASTER).updateSBTStatus(user, true);
        }

        if (roleId == ROLE_COMMUNITY) {
            CommunityRoleData memory data = _decodeCommunityData(roleData);
            communityByName[data.name] = user;
            if (bytes(data.ensName).length > 0) communityByENS[data.ensName] = user;
        } else if (roleId == ROLE_ENDUSER) {
            EndUserRoleData memory data = _decodeEndUserData(roleData);
            accountToUser[data.account] = user;
        }
    }
    
    // View Functions
    function getRoleConfig(bytes32 roleId) external view returns (RoleConfig memory) { return roleConfigs[roleId]; }
    function getUserRoles(address user) external view returns (bytes32[] memory) {
        // Find all roles this user has
        bytes32[7] memory allRoles = [
            ROLE_COMMUNITY, 
            ROLE_ENDUSER, 
            ROLE_PAYMASTER_AOA, 
            ROLE_PAYMASTER_SUPER, 
            ROLE_DVT, 
            ROLE_ANODE, 
            ROLE_KMS
        ];
        uint256 count = 0;
        for(uint i=0; i<7; i++){
            if(hasRole[allRoles[i]][user]) count++;
        }
        bytes32[] memory roles = new bytes32[](count);
        uint256 idx = 0;
        for(uint i=0; i<7; i++){
            if(hasRole[allRoles[i]][user]) roles[idx++] = allRoles[i];
        }
        return roles;
    }

    function calculateExitFee(bytes32 roleId, uint256 amount) external view returns (uint256) {
        (uint256 fee, ) = GTOKEN_STAKING.previewExitFee(msg.sender, roleId);
        return fee;
    }

    function getRoleMembers(bytes32 roleId) external view returns (address[] memory) { return roleMembers[roleId]; }
    function getRoleUserCount(bytes32 roleId) external view returns (uint256) { return roleMembers[roleId].length; }

    function _removeFromRoleMembers(bytes32 roleId, address user) internal {
        uint256 indexPlusOne = roleMemberIndex[roleId][user];
        if (indexPlusOne == 0) return;

        address[] storage members = roleMembers[roleId];
        uint256 index = indexPlusOne - 1;
        uint256 lastIndex = members.length - 1;

        if (index != lastIndex) {
            address lastUser = members[lastIndex];
            members[index] = lastUser;
            roleMemberIndex[roleId][lastUser] = indexPlusOne; // Update lastUser's index
        }

        members.pop();
        delete roleMemberIndex[roleId][user];
    }

    // _negateG1 and BLS constants removed in favor of IBLSValidator strategy

    function _countSetBits(uint256 n) internal pure returns (uint256 count) {
        while (n != 0) {
            n &= (n - 1);
            count++;
        }
    }
}
// This is a test comment to verify hash change
