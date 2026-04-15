// SPDX-License-Identifier: MIT
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;
import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/v3/IRegistry.sol";
import "../interfaces/v3/IGTokenStaking.sol";
import "../interfaces/v3/IMySBT.sol";
import "../interfaces/ISuperPaymaster.sol";
import "../interfaces/v3/IBLSAggregator.sol";
import "../interfaces/v3/IBLSValidator.sol";


contract Registry is Ownable, ReentrancyGuard, Initializable, UUPSUpgradeable, IRegistry {
    using SafeERC20 for IERC20;

    struct CommunityRoleData { string name; string ensName; string website; string description; string logoURI; uint256 stakeAmount; }
    struct EndUserRoleData { address account; address community; string avatarURI; string ensName; uint256 stakeAmount; }
    struct PaymasterRoleData { address paymasterContract; string name; string apiEndpoint; uint256 stakeAmount; }
    struct KMSRoleData { address kmsContract; string name; string apiEndpoint; bytes32[] supportedAlgos; uint256 maxKeysPerUser; uint256 stakeAmount; }
    struct GenericRoleData { string name; bytes extraData; uint256 stakeAmount; }



    function version() external pure virtual override returns (string memory) {
        return "Registry-5.0.0";
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
    mapping(uint256 => bool) public executedProposals; // V3.6: Proposal Nonce tracking
    mapping(address => bytes32[]) public userRoles; // V3.6: O(1) User role tracking
    // V3.5 Optimization: User Role Count (External Call Removal)
    mapping(address => uint256) public userRoleCount;

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

    error RoleNotConfigured(bytes32 roleId, bool isActive);
    error RoleAlreadyGranted(bytes32 roleId, address user);
    error RoleNotGranted(bytes32 roleId, address user);
    error InsufficientStake(uint256 provided, uint256 required);
    error InvalidParam();
    error LockNotMet();
    error CallerNotCommunity();
    error Unauthorized();
    error FeeTooHigh();
    error InvalidAddr();
    error UnauthorizedSource();
    error LenMismatch();
    error BLSProofRequired();
    error InvalidProposalId();
    error InsufficientConsensus();
    error ProposalExecuted();
    error BLSFailed();
    error BLSNotConfigured();
    error SPNotSet();
    error ThreshNotAscending();
    error BatchTooLarge();
    error TooManyLevels();
    error NoExitForTicketOnlyRoles();

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() Ownable(msg.sender) {
        _disableInitializers();
    }

    /**
     * @notice Initialize the UUPS proxy state (replaces constructor logic)
     * @param _owner Contract owner
     * @param _gtokenStaking GTokenStaking contract address
     * @param _mysbt MySBT contract address
     */
    function initialize(address _owner, address _gtokenStaking, address _mysbt) external initializer {
        _transferOwnership(_owner);

        GTOKEN_STAKING = IGTokenStaking(_gtokenStaking);
        MYSBT = IMySBT(_mysbt);

        // Initialize 7 roles — Ticket Model v4
        // Operators: isOperatorRole=true, have both ticketPrice and minStake
        // Regular users: isOperatorRole=false, ticketPrice only, minStake=0
        _initRole(ROLE_PAYMASTER_AOA, 30 ether, 3 ether, 10, 2, 1, 10, 1000, 1 ether, true, true, "", _owner, 30 days);
        _initRole(ROLE_PAYMASTER_SUPER, 50 ether, 5 ether, 10, 2, 1, 10, 1000, 2 ether, true, true, "", _owner, 30 days);
        _initRole(ROLE_DVT, 30 ether, 3 ether, 10, 2, 1, 10, 1000, 1 ether, true, true, "", _owner, 30 days);
        _initRole(ROLE_ANODE, 20 ether, 2 ether, 15, 1, 1, 5, 1000, 1 ether, true, true, "", _owner, 30 days);
        _initRole(ROLE_KMS, 100 ether, 10 ether, 5, 5, 2, 20, 1000, 5 ether, true, true, "", _owner, 30 days);
        _initRole(ROLE_COMMUNITY, 0, 30 ether, 10, 2, 1, 10, 500, 1 ether, true, false, "", _owner, 0);
        _initRole(ROLE_ENDUSER, 0, 0.3 ether, 0, 0, 0, 0, 1000, 0.05 ether, true, false, "", _owner, 0);

        // Initialize Credit Tiers (Default in aPNTs)
        creditTierConfig[1] = 0;
        creditTierConfig[2] = 100 ether;
        creditTierConfig[3] = 300 ether;
        creditTierConfig[4] = 600 ether;
        creditTierConfig[5] = 1000 ether;
        creditTierConfig[6] = 2000 ether;

        // Initialize Level Thresholds (Fibonacci sequence)
        levelThresholds.push(13);
        levelThresholds.push(34);
        levelThresholds.push(89);
        levelThresholds.push(233);
        levelThresholds.push(610);

        isReputationSource[_owner] = true;
    }

    event StakingContractUpdated(address indexed oldStaking, address indexed newStaking);
    event MySBTContractUpdated(address indexed oldMySBT, address indexed newMySBT);
    event SuperPaymasterUpdated(address indexed oldSP, address indexed newSP);
    event BLSAggregatorUpdated(address indexed oldAgg, address indexed newAgg);
    event BLSValidatorUpdated(address indexed oldVal, address indexed newVal);
    event ExitFeeSyncFailed(bytes32 indexed roleId);

    function _initRole(
        bytes32 roleId,
        uint256 min,
        uint256 ticketPrice,
        uint32 thresh,
        uint32 base,
        uint32 inc,
        uint32 max,
        uint16 exitFeePercent,
        uint256 minExitFee,
        bool active,
        bool isOperatorRole,
        string memory desc,
        address owner,
        uint256 lockDuration
    ) internal {
        roleConfigs[roleId] = RoleConfig(min, ticketPrice, thresh, base, inc, max, exitFeePercent, active, isOperatorRole, minExitFee, desc, owner, lockDuration);
        // roleOwners[roleId] = owner; // Moved into RoleConfig
        // roleLockDurations[roleId] = lockDuration; // Moved into RoleConfig
        // Automatically set exit fee in staking contract if setup correctly
        // NOTE: If this fails during deployment, ensure staking.setRegistry(address(this)) is called first.
        if (address(GTOKEN_STAKING) != address(0) && address(GTOKEN_STAKING).code.length > 0) {
            try GTOKEN_STAKING.setRoleExitFee(roleId, exitFeePercent, minExitFee) {} catch {}
        }
    }


    function _syncExitFees() internal {
        bytes32[7] memory roles = [ROLE_PAYMASTER_AOA, ROLE_PAYMASTER_SUPER, ROLE_DVT, ROLE_ANODE, ROLE_KMS, ROLE_COMMUNITY, ROLE_ENDUSER];
        for (uint256 i = 0; i < roles.length; i++) {
            RoleConfig memory cfg = roleConfigs[roles[i]];
            if (cfg.isActive) {
                try GTOKEN_STAKING.setRoleExitFee(roles[i], cfg.exitFeePercent, cfg.minExitFee) {} catch {
                    emit ExitFeeSyncFailed(roles[i]);
                }
            }
        }
    }

    function setStaking(address _staking) external onlyOwner {
        address old = address(GTOKEN_STAKING);
        GTOKEN_STAKING = IGTokenStaking(_staking);
        emit StakingContractUpdated(old, _staking);
        // Auto-sync exit fees for all roles when staking contract changes
        _syncExitFees();
    }

    function setMySBT(address _mysbt) external onlyOwner {
        address old = address(MYSBT);
        MYSBT = IMySBT(_mysbt);
        emit MySBTContractUpdated(old, _mysbt);
    }

    function setSuperPaymaster(address _sp) external onlyOwner {
        if (_sp == address(0)) revert InvalidAddr();
        address old = SUPER_PAYMASTER;
        SUPER_PAYMASTER = _sp;
        emit SuperPaymasterUpdated(old, _sp);
    }

    function setBLSAggregator(address _aggregator) external onlyOwner {
        if (_aggregator == address(0)) revert InvalidAddr();
        address old = blsAggregator;
        blsAggregator = _aggregator;
        emit BLSAggregatorUpdated(old, _aggregator);
    }

    function setBLSValidator(address _validator) external onlyOwner {
        address old = address(blsValidator);
        blsValidator = IBLSValidator(_validator);
        emit BLSValidatorUpdated(old, _validator);
    }

    function registerRole(bytes32 roleId, address user, bytes calldata roleData) public nonReentrant {
        if (user == address(0)) revert InvalidParam();
        if (roleData.length > 2048) revert InvalidParam();

        RoleConfig memory config = roleConfigs[roleId];
        if (!config.isActive) revert RoleNotConfigured(roleId, config.isActive);

        // IDEMPOTENT only for ROLE_ENDUSER to support multi-community joining.
        bool alreadyHasRole = hasRole[roleId][user];
        if (alreadyHasRole && roleId != ROLE_ENDUSER) revert RoleAlreadyGranted(roleId, user);

        if (roleId == ROLE_PAYMASTER_SUPER || roleId == ROLE_PAYMASTER_AOA) {
             if (!hasRole[ROLE_COMMUNITY][user]) revert RoleNotGranted(ROLE_COMMUNITY, user);
        }

        (uint256 stakeAmount, bytes memory sbtData) = _validateAndProcessRole(roleId, user, roleData);

        if (config.isOperatorRole) {
            // Operator roles: require stake
            if (stakeAmount == 0) stakeAmount = config.minStake;
            if (stakeAmount < config.minStake) revert InsufficientStake(stakeAmount, config.minStake);
        }

        if (!alreadyHasRole) {
            _firstTimeRegister(roleId, user, roleData, stakeAmount, config.ticketPrice, config.isOperatorRole, user);
        } else {
            // Re-registration / Top-up: preserve lockedAt (H-01/C-01 fix)
            // Only operator roles have stake to top up
            if (config.isOperatorRole) {
                GTOKEN_STAKING.topUpStake(user, roleId, stakeAmount - roleStakes[roleId][user], user);
                roleStakes[roleId][user] = stakeAmount;
            }
            roleMetadata[roleId][user] = roleData;
        }

        (uint256 sbtTokenId, ) = MYSBT.mintForRole(user, roleId, sbtData);
        roleSBTTokenIds[roleId][user] = sbtTokenId;
        emit RoleRegistered(roleId, user, alreadyHasRole ? 0 : config.ticketPrice, block.timestamp);
    }

    function exitRole(bytes32 roleId) external nonReentrant {
        if (!hasRole[roleId][msg.sender]) revert RoleNotGranted(roleId, msg.sender);
        if (!roleConfigs[roleId].isOperatorRole) revert NoExitForTicketOnlyRoles();

        uint256 lockDuration = roleConfigs[roleId].roleLockDuration;
        if (lockDuration > 0) {
            uint256 lockedAt;
            (,,lockedAt,,) = GTOKEN_STAKING.roleLocks(msg.sender, roleId);
            if (block.timestamp < lockedAt + lockDuration) revert LockNotMet();
        }

        uint256 stakedAmount = roleStakes[roleId][msg.sender];

        if (roleId == ROLE_ENDUSER) {
            MYSBT.deactivateAllMemberships(msg.sender);
        } else if (roleId == ROLE_COMMUNITY) {
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
            MYSBT.deactivateMembership(msg.sender, msg.sender);
        }

        emit BurnExecuted(msg.sender, roleId, stakedAmount, "Exit");

        hasRole[roleId][msg.sender] = false;
        _removeFromRoleMembers(roleId, msg.sender);

        if (userRoleCount[msg.sender] > 0) {
            userRoleCount[msg.sender]--;
        }
        _removeFromUserRoles(msg.sender, roleId);

        if (userRoleCount[msg.sender] == 0) {
            if (SUPER_PAYMASTER != address(0)) {
                ISuperPaymaster(SUPER_PAYMASTER).updateSBTStatus(msg.sender, false);
            }
            MYSBT.burnSBT(msg.sender);
        }

        uint256 netAmount = GTOKEN_STAKING.unlockAndTransfer(msg.sender, roleId);
        emit RoleExited(roleId, msg.sender, stakedAmount - netAmount, block.timestamp);
    }

    function safeMintForRole(bytes32 roleId, address user, bytes calldata data) external nonReentrant returns (uint256 tokenId) {
        RoleConfig memory config = roleConfigs[roleId];
        if (!config.isActive) revert RoleNotConfigured(roleId, config.isActive);
        if (hasRole[roleId][user]) revert RoleAlreadyGranted(roleId, user);
        if (!hasRole[ROLE_COMMUNITY][msg.sender]) revert CallerNotCommunity();

        if (roleId == ROLE_PAYMASTER_SUPER || roleId == ROLE_PAYMASTER_AOA) {
             if (!hasRole[ROLE_COMMUNITY][user]) revert RoleNotGranted(ROLE_COMMUNITY, user);
        }

        (uint256 stakeAmount, bytes memory sbtData) = _validateAndProcessRole(roleId, user, data);

        if (config.isOperatorRole) {
            if (stakeAmount == 0) stakeAmount = config.minStake;
            if (stakeAmount < config.minStake) revert InsufficientStake(stakeAmount, config.minStake);
        }

        _firstTimeRegister(roleId, user, data, stakeAmount, config.ticketPrice, config.isOperatorRole, msg.sender);

        emit RoleGranted(roleId, user, msg.sender);
        (uint256 sbtTokenId, ) = MYSBT.airdropMint(user, roleId, sbtData);
        roleSBTTokenIds[roleId][user] = sbtTokenId;
        emit RoleRegistered(roleId, user, config.ticketPrice, block.timestamp);
        return sbtTokenId;
    }

    /// @dev Shared first-time registration: state writes + ticket burn / stake lock
    function _firstTimeRegister(
        bytes32 roleId, address user, bytes calldata roleData,
        uint256 stakeAmount, uint256 ticketPrice, bool isOperatorRole, address sponsor
    ) internal {
        hasRole[roleId][user] = true;
        roleMembers[roleId].push(user);
        roleMemberIndex[roleId][user] = roleMembers[roleId].length;
        roleMetadata[roleId][user] = roleData;
        userRoleCount[user]++;
        userRoles[user].push(roleId);

        if (isOperatorRole) {
            // Operators: stake (locked) + ticket (to treasury)
            roleStakes[roleId][user] = stakeAmount;
            GTOKEN_STAKING.lockStakeWithTicket(user, roleId, stakeAmount, ticketPrice, sponsor);
        } else {
            // Regular users: ticket only (to treasury), no stake
            GTOKEN_STAKING.burnTicket(user, roleId, ticketPrice, sponsor);
        }
    }

    /// @notice Configure or create a role. New roles (owner==0) require contract owner.
    function configureRole(bytes32 roleId, RoleConfig calldata config) external {
        address currentOwner = roleConfigs[roleId].owner;
        if (currentOwner == address(0)) {
            if (msg.sender != owner()) revert Unauthorized();
        } else {
            if (msg.sender != currentOwner && msg.sender != owner()) revert Unauthorized();
        }
        if (config.exitFeePercent > 2000) revert FeeTooHigh();
        if (config.owner == address(0)) revert InvalidAddr();
        roleConfigs[roleId] = config;
        GTOKEN_STAKING.setRoleExitFee(roleId, config.exitFeePercent, config.minExitFee);
        emit RoleConfigured(roleId, config, block.timestamp);
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
        uint256 proposalId, // V3.6 FIX: Added proposalId for replay protection
        address[] calldata users,
        uint256[] calldata newScores,
        uint256 epoch,
        bytes calldata proof
    ) external nonReentrant {
        if (!isReputationSource[msg.sender]) revert UnauthorizedSource();
        if (users.length != newScores.length) revert LenMismatch();
        if (users.length > 200) revert BatchTooLarge();

        // --- BLS12-381 PAIRING CHECK (EIP-2537) ---
        if (proof.length == 0) revert BLSProofRequired();
        
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
        if (count < threshold) revert InsufficientConsensus();

        // Strategy Pattern for BLS Verification
        if (address(blsValidator) != address(0)) {
            // ✅ UNIFIED MESSAGE SCHEMA: Match BLSAggregator format exactly
            // This ensures "签名绑定" is consistent across the entire system
            // H-02 FIX: proposalId=0 previously bypassed replay protection entirely.
            // All proposals must have a non-zero ID; zero is reserved as "unset".
            if (proposalId == 0) revert InvalidProposalId();
            if (executedProposals[proposalId]) revert ProposalExecuted();
            executedProposals[proposalId] = true;

            bytes32 messageHash = keccak256(abi.encode(
                proposalId,     // actual proposalId
                address(0),     // operator: Registry has no operator, use 0
                uint8(0),       // slashLevel: Registry has no slash, use 0
                users,          // repUsers: matches BLSAggregator's repUsers
                newScores,      // newScores: same as BLSAggregator
                epoch,          // epoch: same as BLSAggregator
                block.chainid   // chainid: prevent cross-chain replay
            ));
            bytes memory message = abi.encodePacked(messageHash);
            
            if (!blsValidator.verifyProof(proof, message)) revert BLSFailed();
        } else {
            revert BLSNotConfigured();
        }

        uint256 maxChange = 100; // Protocol safety limit

        for (uint256 i = 0; i < users.length; ) {
            address user = users[i];

            if (epoch <= lastReputationEpoch[user]) {
                unchecked { ++i; }
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
            
            unchecked { ++i; }
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
        if (!isReputationSource[msg.sender]) revert UnauthorizedSource();
        if (users.length != statuses.length) revert LenMismatch();
        if (SUPER_PAYMASTER == address(0)) revert SPNotSet();

        // --- BLS Verification ---
        if (address(blsValidator) != address(0) && proof.length > 0) {
             bytes memory message = abi.encode(operator, users, statuses);
             if (!blsValidator.verifyProof(proof, message)) revert BLSFailed();
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

    /// @notice Replace all level thresholds (must be strictly ascending)
    function setLevelThresholds(uint256[] calldata thresholds) external onlyOwner {
        if (thresholds.length > 20) revert TooManyLevels();
        delete levelThresholds;
        for (uint256 i = 0; i < thresholds.length; i++) {
            if (i > 0 && thresholds[i] <= thresholds[i - 1]) revert ThreshNotAscending();
            levelThresholds.push(thresholds[i]);
        }
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

    /**
     * @dev Decode-once: validate, extract stake, build SBT data, and apply post-register
     *      side effects in a single pass to avoid redundant abi.decode calls.
     */
    function _validateAndProcessRole(bytes32 roleId, address user, bytes calldata roleData)
        internal returns (uint256 stakeAmount, bytes memory sbtData)
    {
        if (roleId == ROLE_COMMUNITY) {
            CommunityRoleData memory data = abi.decode(roleData, (CommunityRoleData));
            if (bytes(data.name).length == 0) revert InvalidParam();
            if (communityByName[data.name] != address(0)) revert InvalidParam();
            stakeAmount = data.stakeAmount;
            sbtData = abi.encode(user, "");
            communityByName[data.name] = user;
            if (bytes(data.ensName).length > 0) communityByENS[data.ensName] = user;
        } else if (roleId == ROLE_ENDUSER) {
            EndUserRoleData memory data = abi.decode(roleData, (EndUserRoleData));
            if (!hasRole[ROLE_COMMUNITY][data.community]) revert InvalidParam();
            stakeAmount = data.stakeAmount;
            sbtData = abi.encode(data.community, "");
            accountToUser[data.account] = user;
        } else {
            if (roleData.length == 32) stakeAmount = abi.decode(roleData, (uint256));
            sbtData = abi.encode(user, "");
        }
        if (SUPER_PAYMASTER != address(0)) {
            ISuperPaymaster(SUPER_PAYMASTER).updateSBTStatus(user, true);
        }
    }
    
    // View Functions
    function getRoleConfig(bytes32 roleId) external view returns (RoleConfig memory) { return roleConfigs[roleId]; }
    function getUserRoles(address user) external view returns (bytes32[] memory) {
        return userRoles[user];
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

    function _removeFromUserRoles(address user, bytes32 roleId) internal {
        bytes32[] storage roles = userRoles[user];
        uint256 length = roles.length;
        for (uint256 i = 0; i < length; i++) {
            if (roles[i] == roleId) {
                roles[i] = roles[length - 1];
                roles.pop();
                break;
            }
        }
    }

    // _negateG1 and BLS constants removed in favor of IBLSValidator strategy

    function _countSetBits(uint256 n) internal pure returns (uint256 count) {
        while (n != 0) {
            n &= (n - 1);
            count++;
        }
    }

    // ====================================
    // UUPS Authorization
    // ====================================

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ====================================
    // Storage Gap (UUPS upgrade safety)
    // ====================================

    uint256[50] private __gap;
}
