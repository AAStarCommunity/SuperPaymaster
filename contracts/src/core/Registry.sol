// SPDX-License-Identifier: MIT
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;
import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/utils/UUPSUpgradeable.sol";
import "../interfaces/v3/IRegistry.sol";
import "../interfaces/v3/IGTokenStaking.sol";
import "../interfaces/v3/IMySBT.sol";
import "../interfaces/ISuperPaymaster.sol";
import "../interfaces/v3/IBLSValidator.sol";
import "../interfaces/v3/IBLSAggregator.sol";


contract Registry is Ownable, ReentrancyGuard, Initializable, UUPSUpgradeable, IRegistry {

    struct CommunityRoleData { string name; string ensName; string website; string description; string logoURI; uint256 stakeAmount; }
    struct EndUserRoleData { address community; string avatarURI; string ensName; uint256 stakeAmount; }

    function version() external pure virtual override returns (string memory) {
        return "Registry-5.1.0";
    }

    bytes32 public constant ROLE_COMMUNITY = keccak256("COMMUNITY");
    bytes32 public constant ROLE_ENDUSER = keccak256("ENDUSER");
    bytes32 public constant ROLE_PAYMASTER_AOA = keccak256("PAYMASTER_AOA");
    bytes32 public constant ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
    bytes32 public constant ROLE_DVT = keccak256("DVT");
    bytes32 public constant ROLE_ANODE = keccak256("ANODE");
    bytes32 public constant ROLE_KMS = keccak256("KMS");

    IGTokenStaking public GTOKEN_STAKING;
    IMySBT public MYSBT;
    address public SUPER_PAYMASTER;
    address public blsAggregator;
    IBLSValidator public blsValidator;

    mapping(bytes32 => RoleConfig) public roleConfigs;
    mapping(bytes32 => mapping(address => bool)) public hasRole;
    mapping(bytes32 => mapping(address => uint256)) public roleStakes;
    mapping(bytes32 => address[]) public roleMembers;
    mapping(bytes32 => mapping(address => uint256)) public roleMemberIndex;
    mapping(bytes32 => mapping(address => uint256)) public roleSBTTokenIds;
    mapping(bytes32 => mapping(address => bytes)) public roleMetadata;

    mapping(string => address) public communityByName;
    mapping(string => address) public communityByENS;
    mapping(address => bytes32[]) public userRoles;
    mapping(address => uint256) public userRoleCount;

    mapping(address => uint256) public globalReputation;
    mapping(address => uint256) public lastReputationEpoch;
    mapping(uint256 => uint256) public creditTierConfig;
    mapping(address => bool) public isReputationSource;
    mapping(uint256 => bool) public executedProposals;

    uint256[] public levelThresholds;

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
    error InsufficientConsensus();
    error InvalidProposalId();
    error ProposalAlreadyExecuted();
    error BLSFailed();
    error BLSNotConfigured();
    error SPNotSet();
    error ThreshNotAscending();
    error BatchTooLarge();
    error TooManyLevels();
    constructor() Ownable(msg.sender) {
        _disableInitializers();
    }

    function initialize(address _owner, address _gtokenStaking, address _mysbt) external initializer {
        _transferOwnership(_owner);
        GTOKEN_STAKING = IGTokenStaking(_gtokenStaking);
        MYSBT = IMySBT(_mysbt);

        _initRole(ROLE_PAYMASTER_AOA, 30 ether, 3 ether, 10, 2, 1, 10, 1000, 1 ether, _owner, 30 days);
        _initRole(ROLE_PAYMASTER_SUPER, 50 ether, 5 ether, 10, 2, 1, 10, 1000, 2 ether, _owner, 30 days);
        _initRole(ROLE_DVT, 30 ether, 3 ether, 10, 2, 1, 10, 1000, 1 ether, _owner, 30 days);
        _initRole(ROLE_ANODE, 20 ether, 2 ether, 15, 1, 1, 5, 1000, 1 ether, _owner, 30 days);
        _initRole(ROLE_KMS, 100 ether, 10 ether, 5, 5, 2, 20, 1000, 5 ether, _owner, 30 days);
        _initRole(ROLE_COMMUNITY, 0, 30 ether, 0, 0, 0, 0, 0, 0, _owner, 0);
        _initRole(ROLE_ENDUSER, 0, 0.3 ether, 0, 0, 0, 0, 0, 0, _owner, 0);

        creditTierConfig[1] = 0;
        creditTierConfig[2] = 100 ether;
        creditTierConfig[3] = 300 ether;
        creditTierConfig[4] = 600 ether;
        creditTierConfig[5] = 1000 ether;
        creditTierConfig[6] = 2000 ether;

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
    /// @notice P0-14: Staking pushed a fresh stake snapshot for (user, role)
    /// @dev    Emitted for off-chain indexers when slash / unlock / topUp
    ///         operations on the Staking side update Registry's cache.
    event StakeSyncedFromStaking(address indexed user, bytes32 indexed roleId, uint256 newAmount);

    function _initRole(
        bytes32 roleId, uint256 min, uint256 ticketPrice,
        uint32 thresh, uint32 base, uint32 inc, uint32 max,
        uint16 exitFeePercent, uint256 minExitFee,
        address roleOwner, uint256 lockDuration
    ) internal {
        roleConfigs[roleId] = RoleConfig(min, ticketPrice, thresh, base, inc, max, exitFeePercent, true, minExitFee, "", roleOwner, lockDuration);
        if (address(GTOKEN_STAKING) != address(0) && address(GTOKEN_STAKING).code.length > 0) {
            try GTOKEN_STAKING.setRoleExitFee(roleId, exitFeePercent, minExitFee) {} catch {}
        }
    }

    function syncExitFees(bytes32[] calldata roles) external onlyOwner {
        for (uint256 i = 0; i < roles.length; ) {
            RoleConfig memory cfg = roleConfigs[roles[i]];
            if (cfg.isActive) {
                try GTOKEN_STAKING.setRoleExitFee(roles[i], cfg.exitFeePercent, cfg.minExitFee) {} catch {
                    emit ExitFeeSyncFailed(roles[i]);
                }
            }
            unchecked { ++i; }
        }
    }

    function setStaking(address _staking) external onlyOwner {
        address old = address(GTOKEN_STAKING);
        GTOKEN_STAKING = IGTokenStaking(_staking);
        emit StakingContractUpdated(old, _staking);
    }

    /// @notice Push a fresh stake snapshot from Staking into Registry's
    ///         per-role cache (`roleStakes[roleId][user]`).
    /// @dev    P0-14 (H-01): when `GTokenStaking.slashByDVT` or other
    ///         lock-mutating operations run, Staking is the canonical source
    ///         of truth for `roleLocks[user][role].amount`. Without this
    ///         hook the Registry-side cache silently drifts (e.g. a user can
    ///         `topUpStake` against a stale "1000 GT" cache after Staking
    ///         already slashed them down to 500 GT, over-counting their
    ///         backing).
    ///         Caller MUST be the configured `GTOKEN_STAKING`. We do NOT
    ///         allow `owner()` here on purpose — the invariant we're
    ///         restoring is "Registry mirrors Staking", and a privileged
    ///         manual override would re-introduce the drift this function
    ///         is meant to eliminate. Owner can still rotate the staking
    ///         pointer via `setStaking`.
    /// @param user User whose stake changed.
    /// @param roleId Role identifier whose lock amount changed.
    /// @param newAmount Authoritative `roleLocks[user][role].amount` after
    ///                  the Staking-side mutation.
    function syncStakeFromStaking(
        address user,
        bytes32 roleId,
        uint256 newAmount
    ) external {
        if (msg.sender != address(GTOKEN_STAKING)) revert Unauthorized();
        roleStakes[roleId][user] = newAmount;
        emit StakeSyncedFromStaking(user, roleId, newAmount);
    }

    /// @notice Effective per-role stake, read from the Staking-side source
    ///         of truth.
    /// @dev    P0-14: prefer this over reading `roleStakes` directly when
    ///         consumers need fresh values regardless of whether Staking
    ///         has called `syncStakeFromStaking` yet for the latest mutation.
    ///         The cache is best-effort; the on-chain truth is on Staking.
    /// @param user User to query.
    /// @param roleId Role identifier.
    /// @return Locked stake amount currently held by Staking for this role.
    function getEffectiveStake(address user, bytes32 roleId) external view returns (uint256) {
        if (address(GTOKEN_STAKING) == address(0)) return roleStakes[roleId][user];
        return GTOKEN_STAKING.getLockedStake(user, roleId);
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

    function _enforceMinStake(uint256 stakeAmount, uint256 minStake) internal pure returns (uint256) {
        if (minStake == 0) return 0;
        if (stakeAmount == 0) stakeAmount = minStake;
        if (stakeAmount < minStake) revert InsufficientStake(stakeAmount, minStake);
        return stakeAmount;
    }

    function _requireCommunityForPaymaster(bytes32 roleId, address user) internal view {
        if (roleId == ROLE_PAYMASTER_SUPER || roleId == ROLE_PAYMASTER_AOA) {
             if (!hasRole[ROLE_COMMUNITY][user]) revert RoleNotGranted(ROLE_COMMUNITY, user);
        }
    }

    function registerRole(bytes32 roleId, address user, bytes calldata roleData) public nonReentrant {
        if (user == address(0)) revert InvalidParam();
        if (msg.sender != user) revert Unauthorized();
        if (roleData.length > 2048) revert InvalidParam();

        RoleConfig memory config = roleConfigs[roleId];
        if (!config.isActive) revert RoleNotConfigured(roleId, config.isActive);

        bool alreadyHasRole = hasRole[roleId][user];
        if (alreadyHasRole && roleId != ROLE_ENDUSER) revert RoleAlreadyGranted(roleId, user);

        _requireCommunityForPaymaster(roleId, user);

        (uint256 stakeAmount, bytes memory sbtData) = _validateAndProcessRole(roleId, user, roleData);
        stakeAmount = _enforceMinStake(stakeAmount, config.minStake);

        if (!alreadyHasRole) {
            _firstTimeRegister(roleId, user, roleData, stakeAmount, config.ticketPrice, user);
        } else {
            if (stakeAmount > roleStakes[roleId][user]) {
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

        bool hasStake = roleStakes[roleId][msg.sender] > 0;

        // --- common state cleanup (both staked and ticket-only roles) ---
        hasRole[roleId][msg.sender] = false;
        _removeFromRoleMembers(roleId, msg.sender);
        if (userRoleCount[msg.sender] > 0) {
            userRoleCount[msg.sender]--;
        }
        _removeFromUserRoles(msg.sender, roleId);

        // Clean up community name/ENS slots so they can be re-registered
        if (roleId == ROLE_COMMUNITY) {
            bytes memory meta = roleMetadata[roleId][msg.sender];
            if (meta.length > 0) {
                CommunityRoleData memory data = abi.decode(meta, (CommunityRoleData));
                delete communityByName[data.name];
                if (bytes(data.ensName).length > 0) delete communityByENS[data.ensName];
            }
            delete roleMetadata[roleId][msg.sender];
            delete roleSBTTokenIds[roleId][msg.sender];
        } else if (roleId == ROLE_ENDUSER) {
            delete roleMetadata[roleId][msg.sender];
            delete roleSBTTokenIds[roleId][msg.sender];
        }

        if (userRoleCount[msg.sender] == 0) {
            if (SUPER_PAYMASTER != address(0)) {
                ISuperPaymaster(SUPER_PAYMASTER).updateSBTStatus(msg.sender, false);
            }
            MYSBT.burnSBT(msg.sender);
        }

        // --- stake unlock (operator roles only) ---
        uint256 exitFee;
        if (hasStake) {
            uint256 lockDuration = roleConfigs[roleId].roleLockDuration;
            if (lockDuration > 0) {
                uint256 lockedAt;
                (,,lockedAt,,) = GTOKEN_STAKING.roleLocks(msg.sender, roleId);
                if (block.timestamp < lockedAt + lockDuration) revert LockNotMet();
            }
            uint256 actualLocked = GTOKEN_STAKING.getLockedStake(msg.sender, roleId);
            emit BurnExecuted(msg.sender, roleId, actualLocked, "Exit");
            roleStakes[roleId][msg.sender] = 0;
            uint256 netAmount = GTOKEN_STAKING.unlockAndTransfer(msg.sender, roleId);
            exitFee = actualLocked > netAmount ? actualLocked - netAmount : 0;
        }

        emit RoleExited(roleId, msg.sender, exitFee, block.timestamp);
    }

    function safeMintForRole(bytes32 roleId, address user, bytes calldata data) external nonReentrant returns (uint256 tokenId) {
        RoleConfig memory config = roleConfigs[roleId];
        if (!config.isActive) revert RoleNotConfigured(roleId, config.isActive);
        if (hasRole[roleId][user]) revert RoleAlreadyGranted(roleId, user);
        if (!hasRole[ROLE_COMMUNITY][msg.sender]) revert CallerNotCommunity();

        _requireCommunityForPaymaster(roleId, user);

        (uint256 stakeAmount, bytes memory sbtData) = _validateAndProcessRole(roleId, user, data);
        stakeAmount = _enforceMinStake(stakeAmount, config.minStake);

        _firstTimeRegister(roleId, user, data, stakeAmount, config.ticketPrice, msg.sender);

        emit RoleGranted(roleId, user, msg.sender);
        (uint256 sbtTokenId, ) = MYSBT.airdropMint(user, roleId, sbtData);
        roleSBTTokenIds[roleId][user] = sbtTokenId;
        emit RoleRegistered(roleId, user, config.ticketPrice, block.timestamp);
        return sbtTokenId;
    }

    function _firstTimeRegister(
        bytes32 roleId, address user, bytes calldata roleData,
        uint256 stakeAmount, uint256 ticketPrice, address sponsor
    ) internal {
        hasRole[roleId][user] = true;
        roleMembers[roleId].push(user);
        roleMemberIndex[roleId][user] = roleMembers[roleId].length;
        roleMetadata[roleId][user] = roleData;
        userRoleCount[user]++;
        userRoles[user].push(roleId);

        if (stakeAmount > 0) {
            roleStakes[roleId][user] = stakeAmount;
        }
        GTOKEN_STAKING.lockStakeWithTicket(user, roleId, stakeAmount, ticketPrice, sponsor);
    }

    function configureRole(bytes32 roleId, RoleConfig calldata config) external nonReentrant {
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

    event GlobalReputationUpdated(address indexed user, uint256 newScore, uint256 epoch);
    event CreditTierUpdated(uint256 level, uint256 creditLimit);
    event ReputationSourceUpdated(address indexed source, bool isActive);

    function batchUpdateGlobalReputation(
        uint256 proposalId,
        address[] calldata users,
        uint256[] calldata newScores,
        uint256 epoch,
        bytes calldata proof
    ) external nonReentrant {
        if (!isReputationSource[msg.sender]) revert UnauthorizedSource();
        if (users.length != newScores.length) revert LenMismatch();
        if (users.length > 200) revert BatchTooLarge();

        if (proof.length == 0) revert BLSProofRequired();
        (,,, uint256 signerMask) = abi.decode(proof, (bytes, bytes, bytes, uint256));
        uint256 signerCount = _countSetBits(signerMask);
        uint256 threshold = 3;
        if (blsAggregator != address(0)) {
            try IBLSAggregator(blsAggregator).defaultThreshold() returns (uint256 t) {
                threshold = t;
            } catch {}
        }
        if (signerCount < threshold) revert InsufficientConsensus();
        if (address(blsValidator) == address(0)) revert BLSNotConfigured();
        if (proposalId == 0) revert InvalidProposalId();
        if (executedProposals[proposalId]) revert ProposalAlreadyExecuted();
        executedProposals[proposalId] = true;
        bytes32 messageHash = keccak256(abi.encode(
            proposalId, address(0), uint8(0),
            users, newScores, epoch, block.chainid
        ));
        if (!blsValidator.verifyProof(proof, abi.encodePacked(messageHash))) revert BLSFailed();

        for (uint256 i = 0; i < users.length; ) {
            address user = users[i];
            if (epoch <= lastReputationEpoch[user]) {
                unchecked { ++i; }
                continue;
            }
            uint256 clamped = _clampReputation(globalReputation[user], newScores[i], 100);
            globalReputation[user] = clamped;
            lastReputationEpoch[user] = epoch;
            emit GlobalReputationUpdated(user, clamped, epoch);
            unchecked { ++i; }
        }
    }

    function updateOperatorBlacklist(
        address operator,
        address[] calldata users,
        bool[] calldata statuses,
        bytes calldata proof
    ) external nonReentrant {
        if (!isReputationSource[msg.sender]) revert UnauthorizedSource();
        if (users.length != statuses.length) revert LenMismatch();
        if (SUPER_PAYMASTER == address(0)) revert SPNotSet();

        if (address(blsValidator) != address(0) && proof.length > 0) {
             bytes memory message = abi.encode(operator, users, statuses);
             if (!blsValidator.verifyProof(proof, message)) revert BLSFailed();
        }

        ISuperPaymaster(SUPER_PAYMASTER).updateBlockedStatus(operator, users, statuses);
    }

    /// @notice Mark a proposal as executed in Registry (called by BLSAggregator for slash-only proposals
    ///         where repUsers.length == 0, preventing cross-path replay attacks).
    function markProposalExecuted(uint256 proposalId) external {
        if (msg.sender != blsAggregator) revert UnauthorizedSource();
        if (proposalId == 0) revert InvalidProposalId();
        executedProposals[proposalId] = true;
    }

    function setCreditTier(uint256 level, uint256 limit) external onlyOwner {
        creditTierConfig[level] = limit;
        emit CreditTierUpdated(level, limit);
    }

    function setReputationSource(address source, bool active) external onlyOwner {
        isReputationSource[source] = active;
        emit ReputationSourceUpdated(source, active);
    }

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
        uint256 level = 1;
        for (uint256 i = levelThresholds.length; i > 0; i--) {
            if (rep >= levelThresholds[i - 1]) {
                level = i + 1;
                break;
            }
        }
        return creditTierConfig[level];
    }

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
        } else {
            if (roleData.length == 32) stakeAmount = abi.decode(roleData, (uint256));
            sbtData = abi.encode(user, "");
        }
        if (SUPER_PAYMASTER != address(0)) {
            ISuperPaymaster(SUPER_PAYMASTER).updateSBTStatus(user, true);
        }
    }

    function getRoleConfig(bytes32 roleId) external view returns (RoleConfig memory) { return roleConfigs[roleId]; }
    function getUserRoles(address user) external view returns (bytes32[] memory) { return userRoles[user]; }
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
            roleMemberIndex[roleId][lastUser] = indexPlusOne;
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

    function _clampReputation(uint256 oldScore, uint256 newScore, uint256 maxChange) internal pure returns (uint256) {
        if (newScore > oldScore) {
            if (newScore - oldScore > maxChange) return oldScore + maxChange;
        } else if (oldScore > newScore) {
            if (oldScore - newScore > maxChange) return oldScore - maxChange;
        }
        return newScore;
    }

    function _countSetBits(uint256 n) internal pure returns (uint256 count) {
        while (n != 0) { n &= (n - 1); count++; }
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    uint256[50] private __gap;
}
