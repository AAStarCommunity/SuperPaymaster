// SPDX-License-Identifier: Apache-2.0
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;
import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "src/interfaces/v3/IRegistry.sol";
import "src/interfaces/v3/IBLSAggregator.sol";
import "src/interfaces/v3/IGTokenStaking.sol";
import "src/interfaces/IVersioned.sol";

/// @notice Local sub-view of Registry exposing the staking pointer. Kept here
///         (rather than on IRegistry) so existing mocks across the test suite
///         do not need to implement the GTOKEN_STAKING getter — DVTValidator
///         simply casts its registry reference to this narrower interface.
interface IRegistryStakingAware {
    function GTOKEN_STAKING() external view returns (IGTokenStaking);
}

/**
 * @title DVTValidator
 * @notice Distributed Validator Technology for operator monitoring (V3)
 * @dev Manages slash proposals and coordinates with BLSAggregator.
 */
contract DVTValidator is Ownable, IVersioned {

    struct ValidatorInfo {
        address validatorAddress;
        bool isActive;
    }

    struct SlashProposal {
        address operator;
        uint8 slashLevel;
        string reason;
        bool executed;
        // P0-4 fix: explicit existence flag so that operator==address(0) remains
        // a valid proposal target. BLSAggregator intentionally supports zero-
        // operator proposals (it skips slash when operator is zero), so using
        // operator==address(0) as a non-existence sentinel breaks that path.
        bool exists;
        // ✅ Removed validators[] and signatures[]
        // Individual signatures collected off-chain via DVT P2P protocol
        // Only aggregated BLS proof submitted on-chain
    }

    IRegistry public immutable REGISTRY;
    address public BLS_AGGREGATOR;
    
    mapping(address => bool) public isValidator;
    mapping(uint256 => SlashProposal) public proposals;
    uint256 public nextProposalId = 1;

    event ProposalCreated(uint256 indexed id, address indexed operator, uint8 level);
    event ProposalSigned(uint256 indexed id, address indexed validator);
    event ProposalExecuted(uint256 indexed id);
    /// @notice Emitted when a validator is permissionlessly pruned because they
    ///         no longer satisfy the role+stake requirements. `hadRole` and
    ///         `stakeAmount` capture the on-chain reason at prune time so off-
    ///         chain monitors can attribute the eviction.
    event ValidatorPruned(address indexed v, bool hadRole, uint256 stakeAmount);
    /// @notice Emitted when the owner force-removes a validator regardless of
    ///         their current role/stake state.
    event ValidatorRemoved(address indexed v);

    error NotValidator();
    error AlreadySigned();
    error ProposalExecutedAlready();
    error OnlyBLSAggregator();
    /// @notice Reverted when an action references a proposalId that has not been
    ///         created via createProposal. Defense against pre-poison attacks
    ///         where an adversary tricks the BLS aggregator path into marking
    ///         an unborn proposalId as executed.
    error ProposalDoesNotExist();
    error NotAuthorizedExecutor();
    /// @notice Reverted when addValidator is called for an address that does
    ///         not hold ROLE_DVT in the Registry.
    error ValidatorMissingRole();
    /// @notice Reverted when addValidator is called for an address whose
    ///         locked stake under ROLE_DVT is below the role's minStake.
    error ValidatorStakeBelowMinimum(uint256 actual, uint256 required);
    /// @notice Reverted when the Registry has no staking pointer wired up yet.
    error StakingNotConfigured();
    /// @notice Reverted when an operation references an address that is not
    ///         currently flagged as a validator (`isValidator[v] == false`).
    error NotActiveValidator(address v);
    /// @notice Reverted when an active validator's ROLE_DVT has been revoked
    ///         in Registry but the local `isValidator` flag is still set —
    ///         the live-liveness check (P0 follow-up) catches this drift.
    error ValidatorRoleRevoked(address v);
    /// @notice Reverted when `pruneValidator` is called for a validator that
    ///         still satisfies the role + stake requirements; only ineligible
    ///         validators may be permissionlessly pruned.
    error ValidatorStillEligible(address v);

    constructor(address _registry) Ownable(msg.sender) {
        REGISTRY = IRegistry(_registry);
    }

    function version() external pure override returns (string memory) {
        return "DVTValidator-0.6.0";
    }

    /// @notice Restrict to BLS aggregator or registered DVT validators (P0-4)
    modifier onlyAuthorizedExecutor() {
        if (msg.sender != BLS_AGGREGATOR && !isValidator[msg.sender]) {
            revert NotAuthorizedExecutor();
        }
        _;
    }

    /// @notice Register a new DVT validator after verifying both role and stake.
    /// @dev    P0-2: Pre-V5.4 this was an unconditional `onlyOwner` write,
    ///         meaning the owner could grow the quorum with stake-less keys
    ///         and the entire DVT economic guarantee evaporated. Combined with
    ///         the BLS forgery (P0-1) it left the consensus layer with no real
    ///         skin-in-the-game backing.
    ///
    ///         The check reads minStake dynamically from
    ///         `Registry.getRoleConfig(ROLE_DVT)` so governance can tune the
    ///         floor via `Registry.configureRole` without redeploying. Initial
    ///         deploy-time floor is 200 ether GToken (10x previous default).
    /// @dev KNOWN LIMITATION: Stake is validated at registration time only.
    ///      A validator can exit their GTokenStaking stake after registration
    ///      without isValidator[v] being cleared. Mitigation:
    ///      1. Off-chain: operators should periodically call removeValidator()
    ///         for addresses whose stake has dropped below minStake.
    ///      2. On-chain enforcement would require a callback from GTokenStaking
    ///         (out of scope for this fix; tracked as future enhancement).
    function addValidator(address _v) external onlyOwner {
        bytes32 roleDvt = REGISTRY.ROLE_DVT();

        if (!REGISTRY.hasRole(roleDvt, _v)) revert ValidatorMissingRole();

        IGTokenStaking staking = IRegistryStakingAware(address(REGISTRY)).GTOKEN_STAKING();
        if (address(staking) == address(0)) revert StakingNotConfigured();

        IRegistry.RoleConfig memory cfg = REGISTRY.getRoleConfig(roleDvt);
        (uint128 amount,,,, ) = staking.roleLocks(_v, roleDvt);
        if (uint256(amount) < cfg.minStake) {
            revert ValidatorStakeBelowMinimum(uint256(amount), cfg.minStake);
        }

        isValidator[_v] = true;
    }

    /// @notice Real-time validator liveness gate (P0 follow-up).
    /// @dev    The legacy `addValidator` only checked role+stake at registration
    ///         time. After that, exitRole / unlockAndTransfer / slash could leave
    ///         a validator with zero stake or no ROLE_DVT, but `isValidator[v]`
    ///         and the BLS slot stayed live — the operator could keep voting in
    ///         quorums even though their economic backing was gone.
    ///
    ///         This helper re-validates against Registry + Staking on every
    ///         consensus-affecting call. Three independent checks must all hold:
    ///           1. Local `isValidator[v]` flag still set.
    ///           2. Registry still grants ROLE_DVT to `v` (covers explicit
    ///              role revocation outside an exitRole flow).
    ///           3. Locked GToken stake under ROLE_DVT >= role's `minStake`
    ///              (covers exitRole, partial unlock, and slash drawdowns).
    function _requireActiveValidator(address v) internal view {
        if (!isValidator[v]) revert NotActiveValidator(v);
        bytes32 roleDvt = REGISTRY.ROLE_DVT();
        if (!REGISTRY.hasRole(roleDvt, v)) revert ValidatorRoleRevoked(v);
        IGTokenStaking staking = IRegistryStakingAware(address(REGISTRY)).GTOKEN_STAKING();
        if (address(staking) == address(0)) revert StakingNotConfigured();
        IRegistry.RoleConfig memory cfg = REGISTRY.getRoleConfig(roleDvt);
        (uint128 amount,,,, ) = staking.roleLocks(v, roleDvt);
        if (uint256(amount) < cfg.minStake) {
            revert ValidatorStakeBelowMinimum(uint256(amount), cfg.minStake);
        }
    }


    function createProposal(address operator, uint8 level, string calldata reason) external returns (uint256 id) {
        // P0 follow-up: enforce live liveness before allowing a stake-less
        // ex-validator to mint new proposals.
        _requireActiveValidator(msg.sender);
        id = nextProposalId++;
        SlashProposal storage p = proposals[id];
        p.operator = operator;
        p.slashLevel = level;
        p.reason = reason;
        // P0-4 fix: mark the proposal as created so existence checks use p.exists
        // instead of operator==address(0), allowing zero-operator proposals.
        p.exists = true;
        // P0-17: explicit reset — auto-increment id implies executed defaults to
        // false, but a hostile BLS aggregator path could have pre-set executed
        // for an unborn id. Resetting here guarantees a freshly created proposal
        // starts in an executable state.
        p.executed = false;
        emit ProposalCreated(id, operator, level);
    }

    /**
     * @notice Mark proposal as executed (called by BLSAggregator after successful execution)
     * @dev This is called after BLS proof verification succeeds
     */
    function markProposalExecuted(uint256 id) external {
        if (msg.sender != BLS_AGGREGATOR) revert OnlyBLSAggregator();
        SlashProposal storage p = proposals[id];
        // P0-17: even though caller is gated to the BLS aggregator, defense-in-
        // depth requires the targeted proposal to actually exist. Without this
        // guard, a forged BLS proof (P0-1) would let the aggregator mark any
        // future proposalId as executed, permanently DoS'ing it once createProposal
        // assigns that id (the legitimate executeWithProof would revert on
        // ProposalExecutedAlready).
        // P0-4 fix: use p.exists instead of operator==address(0) — zero-operator
        // proposals are valid in BLSAggregator (it skips slash for address(0)).
        if (!p.exists) revert ProposalDoesNotExist();
        p.executed = true;
        emit ProposalExecuted(id);
    }

    // ✅ Removed signProposal and _forward functions
    // DVT validators collect signatures off-chain via P2P protocol
    // Last validator aggregates BLS signatures and calls executeWithProof

    /**
     * @notice Direct execution with an aggregated proof
     */
    function executeWithProof(
        uint256 id,
        address[] calldata repUsers,
        uint256[] calldata newScores,
        uint256 epoch,
        bytes calldata proof
    ) external onlyAuthorizedExecutor {
        // P0 follow-up: a registered validator that has since exited their
        // role / withdrawn their stake must not be allowed to drive an
        // executeWithProof call, even though the modifier `onlyAuthorizedExecutor`
        // would still treat them as authorized purely on `isValidator[v]`. The
        // BLS aggregator (BLS_AGGREGATOR) is exempted because its own quorum
        // verification re-validates each signing slot independently in
        // BLSAggregator._reconstructPkAgg.
        if (msg.sender != BLS_AGGREGATOR) {
            _requireActiveValidator(msg.sender);
        }
        SlashProposal storage p = proposals[id];
        // P0-17: reject ids that were never created — an unborn id would otherwise
        // be silently forwarded to the aggregator with bogus fields.
        // P0-4 fix: use p.exists instead of operator==address(0) — zero-operator
        // proposals are valid in BLSAggregator (it skips slash for address(0)).
        if (!p.exists) revert ProposalDoesNotExist();
        if (p.executed) revert ProposalExecutedAlready();

        IBLSAggregator(BLS_AGGREGATOR).verifyAndExecute(
            id,
            p.operator,
            p.slashLevel,
            repUsers,
            newScores,
            epoch,
            proof
        );
    }

    function setBLSAggregator(address _bls) external onlyOwner {
        BLS_AGGREGATOR = _bls;
    }

    /// @notice Permissionless eviction when a validator no longer meets the
    ///         role + stake requirements (P0 follow-up).
    /// @dev    Anyone can call this. The function reverts (`ValidatorStillEligible`)
    ///         if the validator still has ROLE_DVT AND stake >= minStake — so it
    ///         only succeeds when there's a genuine drift between the local
    ///         flag and on-chain reality. This gives off-chain monitors / public-
    ///         goods bots a way to prune stale validators without waiting for
    ///         the owner. The BLS slot is NOT freed here; revocation of the BLS
    ///         key remains an `onlyOwner` action via `BLSAggregator.revokeBLSPublicKey`
    ///         to keep slot lifecycle decisions privileged.
    function pruneValidator(address v) external {
        if (!isValidator[v]) revert NotActiveValidator(v);
        bytes32 roleDvt = REGISTRY.ROLE_DVT();
        bool hasRole_ = REGISTRY.hasRole(roleDvt, v);
        IGTokenStaking staking = IRegistryStakingAware(address(REGISTRY)).GTOKEN_STAKING();
        if (address(staking) == address(0)) revert StakingNotConfigured();
        IRegistry.RoleConfig memory cfg = REGISTRY.getRoleConfig(roleDvt);
        (uint128 amount,,,, ) = staking.roleLocks(v, roleDvt);
        if (hasRole_ && uint256(amount) >= cfg.minStake) {
            revert ValidatorStillEligible(v);
        }
        isValidator[v] = false;
        emit ValidatorPruned(v, hasRole_, uint256(amount));
    }

    /// @notice Owner-only forced removal — used when governance wants to evict
    ///         a validator regardless of their current role/stake state (e.g.
    ///         emergency response to an off-chain key compromise).
    function removeValidator(address v) external onlyOwner {
        if (!isValidator[v]) revert NotActiveValidator(v);
        isValidator[v] = false;
        emit ValidatorRemoved(v);
    }
}
