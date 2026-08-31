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

interface IGuardianExitGate {
    function consumeGuardianExit(address guardian) external;
}

contract Registry is Ownable, ReentrancyGuard, Initializable, UUPSUpgradeable, IRegistry {

    // Role identifiers — imported as file-level constants from IRegistry.sol.
    // Use ROLE_COMMUNITY / ROLE_ENDUSER / etc. directly anywhere in this contract.

    struct CommunityRoleData { string name; string ensName; uint256 stakeAmount; }
    struct EndUserRoleData { address community; uint256 stakeAmount; }

    function version() external pure virtual override returns (string memory) {
        return "Registry-5.8.0";
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

        // CC-48 round-9 (EIP-170): these seven bootstrap rows used to be seven separate
        // `_initRole(...)` call sites. `via_ir` inlined the callee at every one of them,
        // costing ~552 runtime bytes EACH -- about 3.8 KB of the contract, spent on writing
        // seven rows of a table. Driving them through ONE call site from a memory array
        // keeps exactly the same values and the same writes (asserted field-by-field by
        // `test_RoleBootstrapMatrixUnchanged`) and hands the headroom back to the credit
        // subsystem this round grows. The rows read in the same order as before.
        bytes32[7] memory ids = [
            ROLE_PAYMASTER_AOA, ROLE_PAYMASTER_SUPER, ROLE_DVT, ROLE_ANODE,
            ROLE_KMS, ROLE_COMMUNITY, ROLE_ENDUSER
        ];
        uint256[7] memory mins = [uint256(30 ether), 50 ether, 30 ether, 20 ether, 100 ether, 0, 0];
        uint256[7] memory tickets =
            [uint256(3 ether), 5 ether, 3 ether, 2 ether, 10 ether, 30 ether, 0.3 ether];
        uint32[7] memory threshs = [uint32(10), 10, 10, 15, 5, 0, 0];
        uint32[7] memory bases = [uint32(2), 2, 2, 1, 5, 0, 0];
        uint32[7] memory incs = [uint32(1), 1, 1, 1, 2, 0, 0];
        uint32[7] memory maxes = [uint32(10), 10, 10, 5, 20, 0, 0];
        uint16[7] memory exitFees = [uint16(1000), 1000, 1000, 1000, 1000, 0, 0];
        uint256[7] memory minExitFees = [uint256(1 ether), 2 ether, 1 ether, 1 ether, 5 ether, 0, 0];
        uint256[7] memory locks = [uint256(30 days), 30 days, 30 days, 30 days, 30 days, 0, 0];
        for (uint256 r = 0; r < 7; r++) {
            _initRole(
                ids[r], mins[r], tickets[r], threshs[r], bases[r], incs[r], maxes[r],
                exitFees[r], minExitFees[r], _owner, locks[r]
            );
        }

        // AUDIT H-1: level-1 (new / zero-reputation users) MUST default to a NON-ZERO
        // credit ceiling. SuperPaymaster now enforces the ceiling in validation
        // regardless of xPNTs balance (Plan A), so a level-1 default of 0 would reject
        // every fresh user even when they hold tokens. The defaults below keep the tier
        // monotonic (level 1 ≤ 2 ≤ … ≤ 6) so higher reputation never *lowers* credit.
        // NOTE: these are FRESH-INIT bootstrap values only — they apply when a new
        // Registry is initialized, NOT to an already-initialized UUPS proxy (its stored
        // tiers are untouched on upgrade — measured across the 5.4.2 -> 5.8.0 swap of
        // 2026-08-30, where the stored schedule survived unchanged). This note used to
        // add "the live Sepolia proxy keeps level 1 = 1000"; that is WRONG as of
        // 2026-08-31 — `creditTierConfig(1)` on 0xf5Bf37ca…8E71 reads 300e18, and 1/2/3
        // are all 300e18. Do not read a live-chain value out of a source comment: check
        // it (`cast call <proxy> "creditTierConfig(uint256)(uint256)" 1`), because a
        // comment cannot track a value only `setCreditTier` moves.
        // 100 ether covers the MEASURED ~38 aPNTs per-op charge
        // with margin, but a high-maxFeePerGas op can exceed it — every deployment MUST
        // call setCreditTier() to cover its own worst-case charge + economic model.
        // Final tier economics are a team decision (tracked in audit issue #245).
        creditTierConfig[1] = 100 ether;
        creditTierConfig[2] = 100 ether;
        creditTierConfig[3] = 300 ether;
        creditTierConfig[4] = 600 ether;
        creditTierConfig[5] = 1000 ether;
        creditTierConfig[6] = 2000 ether;

        // Fresh deployments fail closed at a finite proposal-level issuance
        // budget. Existing UUPS proxies read zero after upgrade, which also
        // fails closed for positive uplifts until governance configures a cap.
        maxAggregateCreditUpliftPerProposal = 2000 ether;
        // CC-48 HIGH-1: fresh deployments start with a finite protocol-wide ceiling
        // (100x the per-proposal guard). Governance is expected to set the real number
        // via setCreditPolicy before opening the reputation path to production traffic.
        maxTotalCreditExposure = 200_000 ether;

        levelThresholds.push(13);
        levelThresholds.push(34);
        levelThresholds.push(89);
        levelThresholds.push(233);
        levelThresholds.push(610);

        isReputationSource[_owner] = true;

        // CC-48 round-9 MEDIUM-HIGH-B3: a FRESH Registry has no users, so its credit
        // population is empty and its derived exposure is zero -- provably, not by
        // operator assertion. Marking it seeded here is what keeps the fail-closed gate in
        // `updateGlobalReputation` aimed exclusively at UPGRADED proxies, whose population
        // slots read empty while real promoted users exist on-chain.
        creditPopulationSeededAt = block.timestamp;
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

    /// @dev P0-3: push a role's exit fee to staking via a low-level call so a staking-side
    ///      revert cannot brick registration/config; emits SyncFailed for indexer alerting.
    ///      Extracted from _initRole / _syncExitFeeForRole / syncExitFees so the encode+call+emit
    ///      sequence is compiled once instead of three times (EIP-170 compression; behavior and
    ///      P0-3 fail-open semantics unchanged).
    function _safeSetRoleExitFee(bytes32 roleId, uint16 exitFeePercent, uint256 minExitFee) internal {
        (bool ok,) = address(GTOKEN_STAKING).call(
            abi.encodeCall(IGTokenStaking.setRoleExitFee, (roleId, exitFeePercent, minExitFee))
        );
        if (!ok) emit SyncFailed(address(GTOKEN_STAKING), roleId);
    }

    function _initRole(
        bytes32 roleId, uint256 min, uint256 ticketPrice,
        uint32 thresh, uint32 base, uint32 inc, uint32 max,
        uint16 exitFeePercent, uint256 minExitFee,
        address roleOwner, uint256 lockDuration
    ) internal {
        roleConfigs[roleId] = RoleConfig(min, ticketPrice, thresh, base, inc, max, exitFeePercent, true, minExitFee, "", roleOwner, lockDuration);
        if (address(GTOKEN_STAKING) != address(0) && address(GTOKEN_STAKING).code.length > 0) {
            _safeSetRoleExitFee(roleId, exitFeePercent, minExitFee);
        }
    }

    function _syncExitFeeForRole(bytes32 roleId) internal {
        RoleConfig memory cfg = roleConfigs[roleId];
        if (cfg.isActive) {
            _safeSetRoleExitFee(roleId, cfg.exitFeePercent, cfg.minExitFee);
        }
    }

    /// @notice Admin-triggered batch sync. Emits SyncFailed for any role whose
    ///         call to staking reverts — indexers watch this topic for alerting.
    function syncExitFees(bytes32[] calldata roles) external onlyOwner {
        for (uint256 i = 0; i < roles.length; ) {
            bytes32 r = roles[i];
            RoleConfig storage cfg = roleConfigs[r];
            if (cfg.isActive) {
                _safeSetRoleExitFee(r, cfg.exitFeePercent, cfg.minExitFee);
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
        if (_mysbt == address(0) || _mysbt.code.length == 0) revert InvalidAddr();
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
        if (roleId == ROLE_DVT) {
            if (blsAggregator == address(0)) revert BLSNotConfigured();
            IGuardianExitGate(blsAggregator).consumeGuardianExit(msg.sender);
        }

        // M-6: gate real fund release on Staking's source-of-truth, NOT the local
        // `roleStakes` cache. The cache is synced best-effort (try/catch in
        // GTokenStaking._syncRegistry); if a sync ever failed it could be stale,
        // and gating on it would either strand a real lock (cache 0, lock > 0) or
        // brick exit via NoLockFound (cache > 0, lock already cleared).
        bool hasStake = GTOKEN_STAKING.getLockedStake(msg.sender, roleId) > 0;

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
                // M-2: non-fatal — a reverting or paused SuperPaymaster.updateSBTStatus must not
                // deadlock exitRole and freeze the user's locked-stake withdrawal. Mirrors the
                // burnSBT low-level pattern below; the SBT desync is re-syncable, fund release wins.
                (bool _sbtOk,) = SUPER_PAYMASTER.call(
                    abi.encodeCall(ISuperPaymaster.updateSBTStatus, (msg.sender, false))
                );
                if (!_sbtOk) emit SBTStatusSyncFailed(msg.sender, roleId);
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
    /// @dev CC-48 round-9. Emitted by every owner call that can move protocol-wide
    ///      exposure without a proposal, so a monitor sees the ledger move with the policy.
    event CreditExposureResynced(uint256 newExposure);
    event ReputationSourceUpdated(address indexed source, bool isActive);
    /// @notice Full credit accounting for one reputation proposal: what it issued,
    ///         the transaction-level guard it cleared, and the resulting protocol-wide
    ///         outstanding exposure against its ceiling.
    event ReputationProposalUplift(
        uint256 indexed proposalId,
        uint256 aggregateUplift,
        uint256 cap,
        uint256 totalExposure,
        uint256 totalCap
    );
    event CreditPolicyUpdated(uint256 perProposalCap, uint256 totalCap, uint256 exposureBaseline);

    // ====================================
    // CC-48 round-2: versioned domain separation (mirrors BLSAggregator)
    // ====================================
    //
    // Registry re-derives the separator LOCALLY rather than reading it off the
    // aggregator. The whole point of Registry's second verification is that it does
    // not take the aggregator's word for anything; asking the aggregator to name its
    // own domain would hand that back. Because the separator commits to
    // `address(this)` (Registry) and to the aggregator address Registry has
    // configured, the two only agree when the aggregator's immutable REGISTRY really
    // is this Registry — a mis-wired pair fails closed instead of verifying.
    bytes32 internal constant DOMAIN_NAME = keccak256("SuperPaymaster.BLSConsensus.v1");
    bytes32 internal constant TAG_REPUTATION = keccak256("SuperPaymaster.BLS.Reputation.v1");
    bytes32 internal constant TAG_BLACKLIST = keccak256("SuperPaymaster.BLS.Blacklist.v1");

    /// @notice The BLS domain separator this Registry verifies under.
    /// @dev    MUST equal `BLSAggregator.domainSeparator()` of the configured
    ///         aggregator; asserted in tests and exposed for DVT/SDK pinning.
    function blsDomainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_NAME, block.chainid, blsAggregator, address(this)));
    }

    /// @notice Canonical reputation-batch pre-image; byte-identical to
    ///         `BLSAggregator.reputationMessageHash`.
    function _reputationMessageHash(
        uint256 proposalId,
        address[] calldata users,
        uint256[] calldata newScores,
        uint256 epoch
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(blsDomainSeparator(), TAG_REPUTATION, proposalId, users, newScores, epoch)
        );
    }

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
        // L-C: epoch=0 would skip every user (epoch <= lastReputationEpoch, default 0)
        // yet still burn the proposalId below — a permanently wasted, un-retryable proposal.
        if (epoch == 0) revert InvalidParam();
        // CC-48 round-9 MEDIUM-HIGH-B3: a freshly upgraded proxy reads zero in the
        // population slots while real, already-promoted users exist on-chain. Deriving
        // exposure from that empty population would under-count the live stock by exactly
        // the pre-upgrade issuance, so the reputation path stays SHUT until governance has
        // seeded the population and declared it complete. Fresh deployments are seeded in
        // `initialize`, where the population provably IS empty.
        if (creditPopulationSeededAt == 0) revert CreditPopulationNotSeeded();
        if (executedProposals[proposalId]) revert ProposalAlreadyExecuted();

        executedProposals[proposalId] = true;
        _verifyBLS(proof, _reputationMessageHash(proposalId, users, newScores, epoch));

        uint256 aggregateUplift;
        uint256 aggregateRelease;
        uint256 backfill;
        uint256 marker = creditPopulationEpoch + 1;
        uint256 floorLimit = creditTierConfig[1];
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
            uint256 oldLimit = creditTierConfig[_levelForReputation(_old)];
            uint256 newLimit = creditTierConfig[_levelForReputation(clamped)];
            if (newLimit > oldLimit) aggregateUplift += newLimit - oldLimit;
            else if (oldLimit > newLimit) aggregateRelease += oldLimit - newLimit;
            // CC-48 round-9 MEDIUM-HIGH-B3: self-healing. A promoted user the migration
            // seed missed carries stock this ledger has never seen, so the FIRST proposal
            // that touches them books their whole standing above-floor limit. Counted as
            // `backfill` rather than as uplift so it cannot spuriously trip the
            // per-proposal cap, which measures what THIS proposal issued.
            if (creditPopulationEpochOf[user] != marker) {
                creditPopulationEpochOf[user] = marker;
                creditPopulationTotal += 1;
                if (oldLimit > floorLimit) backfill += oldLimit - floorLimit;
            }
            globalReputation[user] = clamped;
            lastReputationEpoch[user] = epoch;
            emit GlobalReputationUpdated(user, clamped, epoch);
            unchecked { ++i; }
        }
        uint256 cap = maxAggregateCreditUpliftPerProposal;
        if (aggregateUplift > cap) revert AggregateCreditUpliftExceeded(aggregateUplift, cap);

        // CC-48 HIGH-1: the per-proposal cap above is only a transaction-level guard --
        // a colluding quorum can emit N proposals in one block and mint N * cap. The real
        // bound is this running stock of outstanding credit exposure, which every proposal
        // is measured against no matter how the work is sliced.
        //
        // The stock is exact rather than approximate because the ONLY other things that can
        // move a user's credit limit -- `setCreditTier` and `setLevelThresholds` -- do not
        // edit this number, they INVALIDATE it (round-9 HIGH-B1): they shut this path until
        // governance re-counts. So between two re-counts the tier schedule is frozen and
        // these deltas are the whole of the movement.
        //
        // Saturating subtraction keeps the running total from ever underflowing. Round-8
        // established the comparison that matters: the alternative to saturating is
        // REVERTING, which would leave the downgrade unapplied and the user holding the
        // HIGHER limit -- strictly worse for the bound. It can only be more conservative.
        uint256 total = totalCreditExposure + aggregateUplift + backfill;
        total = total > aggregateRelease ? total - aggregateRelease : 0;
        uint256 totalCap = maxTotalCreditExposure;
        if (total > totalCap) revert TotalCreditExposureExceeded(total, totalCap);
        totalCreditExposure = total;

        emit ReputationProposalUplift(proposalId, aggregateUplift, cap, total, totalCap);
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
            blsDomainSeparator(), TAG_BLACKLIST, nonce, operator, users, statuses
        )));

        ISuperPaymaster(SUPER_PAYMASTER).updateBlockedStatus(operator, users, statuses);
    }

    /// @notice Emitted when the BLS aggregator marks a proposal id executed.
    /// @dev    L-7: gives off-chain monitors an auditable signal for every
    ///         executedProposals write on this path, so a trusted-but-misbehaving
    ///         aggregator pre-locking a proposal id is observable (the call is
    ///         already gated to `blsAggregator`; this adds visibility, not a gate).
    event ProposalMarkedExecuted(uint256 indexed proposalId, address indexed by);

    function markProposalExecuted(uint256 proposalId) external {
        if (msg.sender != blsAggregator) revert UnauthorizedSource();
        if (proposalId == 0) revert InvalidProposalId();
        executedProposals[proposalId] = true;
        emit ProposalMarkedExecuted(proposalId, msg.sender);
    }

    /// @notice Set the aPNT credit limit of one reputation level.
    /// @dev    CC-48 round-9 HIGH-B1. This call changes the credit limit of EVERY user
    ///         sitting at `level`, so it necessarily changes protocol-wide exposure -- and
    ///         round-8 let it do that while `totalCreditExposure` sat still, which is how
    ///         one owner call moved the drawable total 16.6x without the protocol-wide cap
    ///         noticing. It is not allowed to leave the ledger behind any more: the
    ///         population is INVALIDATED in the same call (`_invalidateCreditPopulation`),
    ///         which discards the now-meaningless stock and shuts the reputation path until
    ///         governance re-counts. There is no "remember to re-seed afterwards" step to
    ///         forget, because forgetting it stops issuance rather than un-bounding it.
    ///
    ///         Two writes are exempt, and only because neither can move anybody's credit
    ///         limit: re-writing the price a level already has, and pricing a level above
    ///         the currently reachable top (CC-48 round-11 LOW-L1). See the branches
    ///         below for why each is safe; every write that CAN move a limit invalidates.
    ///
    ///         CC-48 round-9 LOW-B6: `initialize` documents the schedule as monotonic
    ///         ("higher reputation never lowers credit"). That invariant is now ENFORCED
    ///         against the immediate neighbours, which is sufficient by induction because
    ///         every level is written through this function.
    function setCreditTier(uint256 level, uint256 limit) external onlyOwner {
        uint256 maxLevel = levelThresholds.length + 1;
        // 20 thresholds is the hard cap (`setLevelThresholds`), so 21 is the highest level
        // that can ever be reachable. Levels ABOVE the currently reachable top are allowed
        // deliberately: `setLevelThresholds` refuses to grow the schedule onto a level whose
        // price is still 0, so a growth has to price the new top FIRST. The two rules meet
        // in the middle -- a level's price must exist before the level does -- and neither
        // can be satisfied by writing a number nobody checks.
        if (level == 0 || level > 21) revert InvalidParam();
        if (level > 1 && limit < creditTierConfig[level - 1]) revert CreditTiersNotMonotonic();
        if (level < maxLevel && limit > creditTierConfig[level + 1]) revert CreditTiersNotMonotonic();
        // Re-writing the price it already has moves nobody's credit limit, so it must not
        // cost a governance outage. Everything below this line assumes the schedule really
        // changed.
        if (creditTierConfig[level] == limit) return;
        creditTierConfig[level] = limit;
        emit CreditTierUpdated(level, limit);
        // CC-48 round-11 LOW-L1. Same principle as the no-op early return above: a write
        // that moves NOBODY's credit limit must not cost a governance outage. Levels above
        // `maxLevel` are exactly that -- `_levelForReputation` never returns more than
        // `levelThresholds.length + 1`, so no `getCreditLimit`, no proposal delta and no
        // re-count can read this slot while it stays out of reach, and the outstanding
        // stock is therefore still exact. It matters because pricing an unreachable level
        // is the MANDATORY first step of growing the schedule (`setLevelThresholds` refuses
        // to grow onto an unpriced level), so round-9 charged a full re-count for the one
        // move that has to happen first.
        //
        // Nothing escapes through this branch: the step that makes such a level reachable
        // is `setLevelThresholds`, which invalidates unconditionally. The ledger is
        // therefore discarded at the moment the price starts applying to someone, not
        // before.
        if (level <= maxLevel) _invalidateCreditPopulation();
    }

    /// @dev CC-48 round-9 HIGH-B1. The one place that answers "what happens to the ledger
    ///      when the schedule moves under it". Re-pricing a tier or moving a threshold
    ///      changes the credit limit of users this contract cannot enumerate, so the
    ///      outstanding stock becomes unknowable from storage alone. It is therefore
    ///      DISCARDED, not adjusted, and the reputation path is shut
    ///      (`creditPopulationSeededAt = 0`) until governance re-counts through
    ///      `seedCreditPopulation`, which reads every user's level out of this contract's
    ///      own storage. Bumping the epoch un-counts every address at once -- there is no
    ///      enumerable user set to iterate, and this needs none.
    ///
    ///      The failure mode is a governance outage (no new reputation credit until the
    ///      re-count lands), never a bound that silently stops measuring reality.
    function _invalidateCreditPopulation() internal {
        // Nothing counted means this ledger is tracking nobody, so there is no stock for a
        // schedule change to invalidate and nothing to re-count -- shutting the path would
        // be pure governance damage. That is the state a fresh deployment configures its
        // tier economics in, and the state an upgraded proxy sits in before it is seeded
        // (already shut: `creditPopulationSeededAt` starts at zero and only seeding opens
        // it).
        //
        // Note precisely what this does NOT claim: it does not claim no promoted address
        // exists. An operator who finalized a seed with an incomplete list leaves promoted
        // addresses uncounted, and those keep their real credit limits. They are not lost
        // and they are not silently under-bounded either -- the first proposal that touches
        // one books its whole standing above-floor limit against whatever schedule is in
        // force by then. Uncounted addresses are the backfill's job, not this branch's.
        if (creditPopulationTotal == 0) return;
        creditPopulationEpoch += 1;
        creditPopulationTotal = 0;
        creditPopulationSeededAt = 0;
        totalCreditExposure = 0;
        emit CreditExposureResynced(0);
    }

    /// @notice Set both credit bounds in one owner call.
    /// @dev    Deliberately a single entry point: the two caps are one policy, and an
    ///         upgrade batch that set them in separate transactions would leave a window
    ///         where the protocol-wide ceiling was still 0 (fail-closed, but a governance
    ///         outage) or still unbounded.
    ///
    ///         CC-48 round-9 MEDIUM-HIGH-B3: the exposure BASELINE is gone from this
    ///         signature. It used to be an operator-supplied aPNT number that nothing
    ///         on-chain could check and that the documented derivation computed WRONG on a
    ///         live deployment. The only thing governance still declares is the population
    ///         MEMBERSHIP -- see `seedCreditPopulation`, where the contract reads each
    ///         member's reputation out of its own storage instead of trusting a total.
    /// @param perProposalCap   Transaction-level guard: max positive credit-limit uplift
    ///                         summed within a single proposal.
    /// @param totalCap         Protocol-wide ceiling on outstanding credit exposure.
    function setCreditPolicy(uint256 perProposalCap, uint256 totalCap) external onlyOwner {
        maxAggregateCreditUpliftPerProposal = perProposalCap;
        maxTotalCreditExposure = totalCap;
        // Refuse a ceiling below the exposure this ledger is currently TRACKING.
        //
        // CC-48 round-11 LOW-L2, stated exactly rather than generously. Round-9 described
        // this line as preventing a frozen reputation path, which overclaims: while the
        // population is invalidated (`creditPopulationSeededAt == 0`, after a
        // `setCreditTier` / `setLevelThresholds` that moved a live schedule)
        // `totalCreditExposure` reads 0 by construction, so this comparison passes for ANY
        // ceiling while real, drawable limits are still outstanding. In that window it
        // guards nothing.
        //
        // It is not the protection, and it was never the only one. The protection is
        // `seedCreditPopulation`, which recomputes exposure from this contract's own
        // storage and reverts the whole batch when the recount exceeds the ceiling -- so a
        // too-low ceiling set in the window cannot open the reputation path, it can only
        // keep it shut until governance raises the ceiling and re-counts. Fail-closed, just
        // reported later. This line's real job is the narrower one it can actually do:
        // catch the mistake immediately in the ordinary, seeded case.
        //
        // Deliberately NOT fixed by refusing to lower the ceiling while unseeded: lowering
        // it is the conservative move, and an outage window is when governance is most
        // likely to need it.
        uint256 exposure = totalCreditExposure;
        if (exposure > totalCap) revert TotalCreditExposureExceeded(exposure, totalCap);
        emit CreditPolicyUpdated(perProposalCap, totalCap, exposure);
    }

    /// @notice Seed (or re-count) the credit population from this contract's own storage.
    /// @dev    CC-48 round-9 MEDIUM-HIGH-B3. Two situations need it: an UPGRADED proxy,
    ///         whose population slots read empty while promoted users already exist, and a
    ///         schedule change (`setCreditTier` / `setLevelThresholds`), which invalidates
    ///         the count it was computed from. Both leave
    ///         `creditPopulationSeededAt == 0`, which shuts `updateGlobalReputation`, so
    ///         neither can quietly issue credit against a wrong stock.
    ///
    ///         Governance supplies ONLY an address list. Each address's level is read from
    ///         `globalReputation` here, so no operator arithmetic — and in particular no
    ///         repetition of the old, structurally wrong "sum the GlobalReputationUpdated
    ///         events into an aPNT baseline" recipe — can misstate a tier.
    ///         `expectedPopulationTotal` is a declared headcount checked against what the
    ///         contract actually counted, so a truncated batch cannot be finalized.
    ///
    ///         Addresses that were never promoted may be omitted: they sit at level 1 and
    ///         contribute exactly zero to the derived stock (see `totalCreditExposure`).
    ///         A promoted address missed here is self-healing — the next proposal touching
    ///         it counts it at its then-current level.
    ///
    ///         Re-running this after finalization is harmless rather than forbidden: an
    ///         address already counted in the current epoch is skipped, so the only effect
    ///         of a second call is to count addresses that were missed. Refusing it would
    ///         buy nothing and would make the migration batch order-dependent on whether
    ///         the proxy had ever been initialized by this implementation.
    /// @param users                   candidate addresses. Already-counted ones are skipped,
    ///                                so the list may be split into batches and may overlap.
    /// @param expectedPopulationTotal headcount governance declares; checked on finalize.
    /// @param finalize                declare the count complete and re-open the path.
    function seedCreditPopulation(
        address[] calldata users,
        uint256 expectedPopulationTotal,
        bool finalize
    ) external onlyOwner {
        uint256 marker = creditPopulationEpoch + 1;
        uint256 counted = creditPopulationTotal;
        uint256 exposure = totalCreditExposure;
        uint256 floor = creditTierConfig[1];
        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            if (creditPopulationEpochOf[user] == marker) continue;
            creditPopulationEpochOf[user] = marker;
            counted += 1;
            uint256 limit = creditTierConfig[_levelForReputation(globalReputation[user])];
            if (limit > floor) exposure += limit - floor;
        }
        creditPopulationTotal = counted;
        totalCreditExposure = exposure;
        // Checked on EVERY batch, not only the finalizing one: a partial count that already
        // exceeds the ceiling can only get worse, and leaving an over-ceiling number in the
        // slot between batches is a state no later call would re-examine.
        uint256 cap = maxTotalCreditExposure;
        if (exposure > cap) revert TotalCreditExposureExceeded(exposure, cap);
        if (finalize) {
            if (counted != expectedPopulationTotal) revert CreditPopulationCountMismatch();
            creditPopulationSeededAt = block.timestamp;
        }
        emit CreditExposureResynced(exposure);
    }

    function setReputationSource(address source, bool active) external onlyOwner {
        isReputationSource[source] = active;
        emit ReputationSourceUpdated(source, active);
    }

    /// @notice Replace the reputation thresholds.
    /// @dev    CC-48 round-9 HIGH-B1. Moving a threshold moves users between levels with no
    ///         proposal involved, so like `setCreditTier` it changes the credit limit of
    ///         users this contract cannot enumerate. Same treatment, for the same reason:
    ///         the population is DISCARDED and the reputation path shuts
    ///         (`creditPopulationSeededAt` back to zero) until governance re-counts through
    ///         `seedCreditPopulation`, which reads every level out of this contract's own
    ///         `globalReputation` storage. Bumping `creditPopulationEpoch` un-counts every
    ///         address at once without needing an enumerable user set.
    ///
    ///         The alternative considered and rejected was accepting an operator-supplied
    ///         re-bucketing (a per-level headcount passed as calldata). It would keep the
    ///         path open across a threshold move, but the numbers in it are exactly the
    ///         kind of unverifiable operator arithmetic round-9 exists to remove.
    ///
    ///         The failure mode is a governance outage (no new credit until the re-count
    ///         lands), never a silent decoupling of the bound from reality.
    function setLevelThresholds(uint256[] calldata thresholds) external onlyOwner {
        if (thresholds.length > 20) revert TooManyLevels();
        delete levelThresholds;
        for (uint256 i = 0; i < thresholds.length; i++) {
            if (i > 0 && thresholds[i] <= thresholds[i - 1]) revert ThreshNotAscending();
            levelThresholds.push(thresholds[i]);
        }
        // CC-48 round-9 LOW-B6, second half. `setCreditTier` cannot make the table
        // non-monotonic, but GROWING the schedule here can: a new top level whose tier was
        // never configured reads 0, so the highest-reputation users would drop to a limit
        // BELOW the level under them -- precisely the "higher reputation never lowers
        // credit" invariant, broken from the other side. Check the resulting table, not
        // just the thresholds.
        uint256 maxLevel = thresholds.length + 1;
        for (uint256 level = 2; level <= maxLevel; level++) {
            if (creditTierConfig[level] < creditTierConfig[level - 1]) revert CreditTiersNotMonotonic();
        }
        _invalidateCreditPopulation();
    }

    function getCreditLimit(address user) external view returns (uint256) {
        return creditTierConfig[_levelForReputation(globalReputation[user])];
    }

    function _levelForReputation(uint256 rep) internal view returns (uint256) {
        for (uint256 i = levelThresholds.length; i > 0; i--) {
            if (rep >= levelThresholds[i - 1]) {
                return i + 1;
            }
        }
        return 1;
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
            // M-2: the REGISTER path stays fatal (fail-closed) on purpose. Registration is atomic
            // (no stake locked yet if it reverts), so a revert here is a clean rollback the user can
            // retry — unlike exitRole, where a fatal call would freeze already-locked stake. Making
            // this non-fatal would risk a silent half-registration (registered but not SBT-eligible).
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

    /// @notice Maximum positive credit-limit uplift (aPNT, 18 decimals) per proposal.
    /// @dev    Transaction-level guard only. It bounds one proposal, NOT total
    ///         issuance — see totalCreditExposure for the protocol-wide bound.
    uint256 public maxAggregateCreditUpliftPerProposal;

    error AggregateCreditUpliftExceeded(uint256 aggregateUplift, uint256 cap);

    /// @notice Protocol-wide OUTSTANDING aPNT credit exposure created by the REPUTATION
    ///         path: the sum, over every address, of the credit limit its current global
    ///         reputation buys it ABOVE the permissionless level-1 floor.
    /// @dev    CC-48 HIGH-1, corrected in round-9 (LOW-B4). This is a STOCK: each member's
    ///         LEVEL is read out of this contract's own storage at re-count
    ///         (`seedCreditPopulation`), never supplied by the operator, and the number then
    ///         moves only by proposal deltas -- exact, because the two calls that could move
    ///         a limit without a proposal (`setCreditTier`, `setLevelThresholds`) do not edit
    ///         it, they discard it and shut the path. So the tier schedule is frozen for the
    ///         whole life of any value this slot holds, and splitting a mint across many
    ///         proposals, blocks or rolling windows changes nothing.
    ///
    ///         WHAT IS NOT DERIVED FROM CHAIN STATE, stated because the previous wording
    ///         ("COMPUTED from on-chain reputation") over-claimed: the MEMBERSHIP LIST is
    ///         supplied by governance. This contract cannot enumerate its own users, so
    ///         `seedCreditPopulation` counts exactly the addresses it is handed, and
    ///         `expectedPopulationTotal` is checked against that same list -- both numbers
    ///         come from the same caller in the same transaction, so the check catches a
    ///         truncated calldata, not a short list. A governance operator who seeds an
    ///         incomplete roster gets a stock below the truth, and the ceiling it is measured
    ///         against is correspondingly loose.
    ///
    ///         Uncounted addresses are not lost -- the first proposal that touches one books
    ///         its whole standing above-floor limit against whatever schedule is then in
    ///         force -- but an address that is never touched again never enters the stock at
    ///         all. So this bound holds relative to the population governance DECLARED, not
    ///         relative to the population that exists. Deriving that roster off-chain (the
    ///         `GlobalReputationUpdated` log is the source) and committing to it is the
    ///         operator's job; nothing in this contract can check it for them.
    ///
    ///         WHAT IT DELIBERATELY DOES NOT COVER, stated plainly because the previous
    ///         wording claimed otherwise: the level-1 floor (`creditTierConfig[1]`) is
    ///         granted to EVERY address by construction -- including addresses that have
    ///         never been the subject of a proposal and addresses that do not yet exist.
    ///         That population is unbounded, so NO counter in this contract can bound the
    ///         floor, and pretending otherwise is what made the old "sum over all users"
    ///         docstring false. Measuring exposure above the floor makes this number a
    ///         complete stock over all addresses, because every uncounted address
    ///         contributes exactly zero to it. The floor is bounded elsewhere and by
    ///         different means -- per-operator deposits and debt limits in SuperPaymaster,
    ///         and the tier-1 economics themselves -- and raising `creditTierConfig[1]` is
    ///         a decision about that other budget, not about this one.
    uint256 public totalCreditExposure;

    /// @notice Hard ceiling on totalCreditExposure. Zero is intentionally fail-closed.
    uint256 public maxTotalCreditExposure;

    error TotalCreditExposureExceeded(uint256 total, uint256 cap);
    error CreditTiersNotMonotonic();
    error CreditPopulationNotSeeded();
    error CreditPopulationCountMismatch();

    /// @notice How many addresses are counted into `totalCreditExposure` in the current
    ///         population epoch.
    /// @dev    CC-48 round-9. Checked against the headcount governance declares when it
    ///         finalizes a re-count, so a truncated calldata batch cannot be declared
    ///         complete.
    uint256 public creditPopulationTotal;

    /// @notice Population marker: `creditPopulationEpoch + 1` for an address counted in
    ///         the current epoch, anything else (including the untouched zero) for one that
    ///         is not.
    /// @dev    Comparing against a global epoch is what lets an invalidation un-count every
    ///         address at once — this contract has no enumerable user set to iterate.
    ///
    ///         The OFFSET is load-bearing, and a round-9 regression test is what found
    ///         that out. On a genuinely pre-5.8.0 proxy BOTH this slot and
    ///         `creditPopulationEpoch` read zero, so storing the raw epoch made every
    ///         never-counted address look ALREADY counted: the migration seed would have
    ///         counted nobody, and (thanks to the declared-headcount check) reverted --
    ///         fail-closed, but a migration that could not be performed at all. With the
    ///         +1 offset, an untouched slot can never equal a live marker.
    mapping(address => uint256) internal creditPopulationEpochOf;

    /// @notice Bumped whenever the credit population is invalidated wholesale.
    uint256 internal creditPopulationEpoch;

    /// @notice When governance declared the credit population complete. Zero means the
    ///         reputation path is shut (fail-closed for an upgraded proxy).
    uint256 public creditPopulationSeededAt;

    uint256[43] private __gap;
}
