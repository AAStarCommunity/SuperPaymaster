// SPDX-License-Identifier: Apache-2.0
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;
import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/utils/UUPSUpgradeable.sol";
import "src/interfaces/v3/IRegistry.sol";
import "../interfaces/v3/IGTokenStaking.sol";
import "../interfaces/v3/IMySBT.sol";
import "../interfaces/ISuperPaymaster.sol";
import "../interfaces/v3/IBLSAggregator.sol";


contract Registry is Ownable, ReentrancyGuard, Initializable, UUPSUpgradeable, IRegistry {

    // Role identifiers — imported as file-level constants from IRegistry.sol.
    // Use ROLE_COMMUNITY / ROLE_ENDUSER / etc. directly anywhere in this contract.

    struct CommunityRoleData { string name; string ensName; uint256 stakeAmount; }
    struct EndUserRoleData { address community; uint256 stakeAmount; }

    function version() external pure virtual override returns (string memory) {
        return "Registry-5.3.3";
    }

    IGTokenStaking public GTOKEN_STAKING;
    IMySBT public MYSBT;
    address public SUPER_PAYMASTER;
    address public blsAggregator;
    mapping(bytes32 => RoleConfig) internal roleConfigs;
    mapping(bytes32 => mapping(address => bool)) public hasRole;
    /// @notice Best-effort cache of locked stake amounts; use `getEffectiveStake()` for authoritative reads.
    mapping(bytes32 => mapping(address => uint256)) internal roleStakes;
    mapping(bytes32 => address[]) internal roleMembers;
    mapping(bytes32 => mapping(address => uint256)) internal roleMemberIndex;
    mapping(bytes32 => mapping(address => uint256)) internal roleSBTTokenIds;
    mapping(bytes32 => mapping(address => bytes)) internal roleMetadata;

    mapping(string => address) internal communityByName;
    mapping(string => address) internal communityByENS;
    mapping(address => bytes32[]) internal userRoles;
    mapping(address => uint256) internal userRoleCount;

    mapping(address => uint256) public globalReputation;
    mapping(address => uint256) internal lastReputationEpoch;
    mapping(uint256 => uint256) public creditTierConfig;
    mapping(address => bool) public isReputationSource;
    mapping(uint256 => bool) internal executedProposals;

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
    /// @notice Emitted when a low-level sync call to an external contract fails.
    /// @dev Replaces the former ExitFeeSyncFailed and StakeSyncedFromStaking events
    ///      with a single lightweight signal: target = staking address for exit-fee
    ///      sync failures; role identifies which role was affected.
    event SyncFailed(address indexed target, bytes32 indexed role);

    function _initRole(
        bytes32 roleId, uint256 min, uint256 ticketPrice,
        uint32 thresh, uint32 base, uint32 inc, uint32 max,
        uint16 exitFeePercent, uint256 minExitFee,
        address roleOwner, uint256 lockDuration
    ) internal {
        roleConfigs[roleId] = RoleConfig(min, ticketPrice, thresh, base, inc, max, exitFeePercent, true, minExitFee, "", roleOwner, lockDuration);
        if (address(GTOKEN_STAKING) != address(0) && address(GTOKEN_STAKING).code.length > 0) {
            address(GTOKEN_STAKING).call(abi.encodeCall(IGTokenStaking.setRoleExitFee, (roleId, exitFeePercent, minExitFee)));
        }
    }

    function _syncExitFeeForRole(bytes32 roleId) internal {
        RoleConfig memory cfg = roleConfigs[roleId];
        if (cfg.isActive) {
            address(GTOKEN_STAKING).call(
                abi.encodeCall(IGTokenStaking.setRoleExitFee, (roleId, cfg.exitFeePercent, cfg.minExitFee))
            );
        }
    }

    /// @notice Admin-triggered batch sync. Emits SyncFailed for any role whose
    ///         call to staking reverts — indexers watch this topic for alerting.
    function syncExitFees(bytes32[] calldata roles) external onlyOwner {
        address stk = address(GTOKEN_STAKING);
        for (uint256 i = 0; i < roles.length; ) {
            bytes32 r = roles[i];
            RoleConfig storage cfg = roleConfigs[r];
            if (cfg.isActive) {
                (bool ok,) = stk.call(
                    abi.encodeCall(IGTokenStaking.setRoleExitFee, (r, cfg.exitFeePercent, cfg.minExitFee))
                );
                if (!ok) emit SyncFailed(stk, r);
            }
            unchecked { ++i; }
        }
    }

    // Sync exit fees for all 7 known roles. Called after setStaking().
    function _syncAllExitFees() internal {
        _syncExitFeeForRole(ROLE_PAYMASTER_AOA);
        _syncExitFeeForRole(ROLE_PAYMASTER_SUPER);
        _syncExitFeeForRole(ROLE_DVT);
        _syncExitFeeForRole(ROLE_ANODE);
        _syncExitFeeForRole(ROLE_KMS);
        _syncExitFeeForRole(ROLE_COMMUNITY);
        _syncExitFeeForRole(ROLE_ENDUSER);
    }

    /// @notice Update the GTokenStaking contract pointer. Auto-syncs all exit fees.
    function setStaking(address _staking) external onlyOwner {
        if (_staking == address(0)) revert InvalidParam();
        address old = address(GTOKEN_STAKING);
        GTOKEN_STAKING = IGTokenStaking(_staking);
        _syncAllExitFees();
        emit StakingContractUpdated(old, _staking);
    }

    /// @notice Push a fresh stake snapshot from Staking into Registry's per-role cache.
    /// @dev    Only callable by GTOKEN_STAKING (P0-14).
    function syncStakeFromStaking(
        address user,
        bytes32 roleId,
        uint256 newAmount
    ) external {
        if (msg.sender != address(GTOKEN_STAKING)) revert Unauthorized();
        roleStakes[roleId][user] = newAmount;
    }

    /// @notice Effective per-role stake from Staking source of truth (P0-14).
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

        hasRole[roleId][msg.sender] = false;
        _removeFromRoleMembers(roleId, msg.sender);
        if (userRoleCount[msg.sender] > 0) {
            userRoleCount[msg.sender]--;
        }
        _removeFromUserRoles(msg.sender, roleId);

        if (roleId != ROLE_PAYMASTER_AOA && roleId != ROLE_PAYMASTER_SUPER) {
            if (roleId == ROLE_COMMUNITY) {
                bytes memory meta = roleMetadata[roleId][msg.sender];
                if (meta.length > 0) {
                    CommunityRoleData memory data = abi.decode(meta, (CommunityRoleData));
                    delete communityByName[data.name];
                    if (bytes(data.ensName).length > 0) delete communityByENS[data.ensName];
                }
            }
            // P1-32: clear slots so user can re-register after exit.
            delete roleMetadata[roleId][msg.sender];
            delete roleSBTTokenIds[roleId][msg.sender];
        }

        if (userRoleCount[msg.sender] == 0) {
            if (SUPER_PAYMASTER != address(0)) {
                ISuperPaymaster(SUPER_PAYMASTER).updateSBTStatus(msg.sender, false);
            }
            // L-04: non-fatal burnSBT — failure emits SBTBurnFailed.
            (bool _burnOk,) = address(MYSBT).call(abi.encodeCall(IMySBT.burnSBT, (msg.sender)));
            if (!_burnOk) emit SBTBurnFailed(msg.sender, roleId);
        }

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

    /// @dev Shared BLS decode + threshold check + verify helper.
    function _verifyBLS(bytes calldata proof, bytes32 messageHash) internal {
        (uint256 signerMask, bytes memory sigG2Bytes) = abi.decode(proof, (uint256, bytes));
        address agg = blsAggregator;
        uint256 threshold = IBLSAggregator(agg).defaultThreshold();
        uint256 _m = signerMask; uint256 _bits; while (_m != 0) { _m &= (_m - 1); _bits++; }
        if (_bits < threshold) revert InsufficientConsensus();
        if (!IBLSAggregator(agg).verify(messageHash, signerMask, threshold, sigG2Bytes)) revert BLSFailed();
    }

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
        if (blsAggregator == address(0)) revert BLSNotConfigured();
        if (proposalId == 0) revert InvalidProposalId();
        if (executedProposals[proposalId]) revert ProposalAlreadyExecuted();

        executedProposals[proposalId] = true;
        _verifyBLS(proof, keccak256(abi.encode(
            proposalId, address(0), uint8(0),
            users, newScores, epoch, block.chainid
        )));

        for (uint256 i = 0; i < users.length; ) {
            address user = users[i];
            if (epoch <= lastReputationEpoch[user]) {
                unchecked { ++i; }
                continue;
            }
            uint256 _old = globalReputation[user]; uint256 _new = newScores[i];
            uint256 clamped = (_new > _old)
                ? ((_new - _old > 100) ? _old + 100 : _new)
                : ((_old > _new && _old - _new > 100) ? _old - 100 : _new);
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
        if (operator == address(0)) revert InvalidParam();
        if (msg.sender != blsAggregator) revert UnauthorizedSource();
        if (users.length != statuses.length) revert LenMismatch();
        if (users.length > 200) revert BatchTooLarge();
        if (SUPER_PAYMASTER == address(0)) revert SPNotSet();
        if (proof.length == 0) revert BLSProofRequired();

        uint256 nonce = blacklistNonce + 1;
        blacklistNonce = nonce;

        _verifyBLS(proof, keccak256(abi.encode(
            block.chainid, nonce, operator, users, statuses
        )));

        ISuperPaymaster(SUPER_PAYMASTER).updateBlockedStatus(operator, users, statuses);
    }

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
            if (bytes(data.ensName).length > 0 && communityByENS[data.ensName] != address(0)) revert InvalidParam();
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
    function getRoleUserCount(bytes32 roleId) external view returns (uint256) { return roleMembers[roleId].length; }
    function getRoleStake(bytes32 roleId, address user) external view returns (uint256) { return roleStakes[roleId][user]; }
    function getCommunityByName(string calldata name) external view returns (address) { return communityByName[name]; }
    function getCommunityByENS(string calldata ensName) external view returns (address) { return communityByENS[ensName]; }

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

    function _authorizeUpgrade(address) internal override onlyOwner {}

    /// @notice Monotonic nonce for blacklist BLS proofs (P0-3 replay protection).
    uint256 public blacklistNonce;

    uint256[50] private __gap;
}
