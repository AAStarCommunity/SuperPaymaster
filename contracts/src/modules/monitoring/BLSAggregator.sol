// SPDX-License-Identifier: Apache-2.0
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;
import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "src/interfaces/v3/IRegistry.sol";
import "src/interfaces/v3/IGTokenStaking.sol";
import "src/interfaces/IVersioned.sol";
import { BLS } from "src/utils/BLS.sol";

/// @notice Local sub-view of Registry used to fetch the staking pointer at
///         verification time. We cast `REGISTRY` to this narrower interface
///         rather than baking another constructor arg, so existing deploy
///         scripts (4 in production + multiple archives) keep their 3-arg
///         BLSAggregator construction unchanged. Mocks in the test suite
///         already implement this view (set via `setStakingAddr`).
interface IRegistryStakingAwareBLS {
    function GTOKEN_STAKING() external view returns (IGTokenStaking);
}

interface ISuperPaymasterSlash {
    enum SlashLevel { WARNING, MINOR, MAJOR }
    function queueSlash(address operator) external;
    function executeSlashWithBLS(address operator, SlashLevel level, bytes calldata proof) external;
}

interface IDVTValidator {
    function markProposalExecuted(uint256 proposalId) external;
}

/// @notice Narrow sub-view of GTokenStaking exposing only the directed
///         role-lock slash. `IGTokenStaking` (used elsewhere here for
///         `roleLocks`) does not surface `slashByDVT`, so we cast the same
///         staking pointer to this local interface rather than widening the
///         shared interface (which every mock/implementer would then have to
///         satisfy). The aggregator is already in `authorizedSlashers`.
interface IGTokenStakingSlash {
    function slashByDVT(address operator, bytes32 roleId, uint256 penaltyAmount, string calldata reason) external;
}

/// @notice External, DVT-supplied fraud-proof verifier (Protocol B stage 2).
///         Returns true iff `fraudProofId` proves the referenced proposal was
///         fraudulent AND `guiltyGuardians` are exactly the co-signers to blame.
///         Guardians are identified by ADDRESS, not slot: slots are reassignable
///         (revokeBLSPublicKey frees a slot for reuse), so a slot captured at
///         fraud time could later resolve to an innocent validator. Address
///         binding is stable and is what the slash reads.
///         BLSAggregator treats this as the sole authority on "who colluded";
///         it does not itself judge fraud. Kept behind an interface so the
///         detection layer can evolve without touching this contract.
///
///         CC-48 round-2: `domainDigest` is supplied by the aggregator and equals
///         `BLSAggregator.fraudProofDigest(fraudProofId, guiltyGuardians)` =
///         keccak256(abi.encode(domainSeparator(), TAG_FRAUD_PROOF, fraudProofId,
///         guiltyGuardians)). It binds the proof to (versioned domain name, chainid,
///         this aggregator, its Registry), so a fraud proof accepted on one
///         aggregator/chain is not byte-valid on another. Verifiers MUST bind
///         `domainDigest` into whatever they check; ignoring it re-opens
///         cross-contract replay.
interface IFraudProofVerifier {
    function verify(
        bytes32 domainDigest,
        uint256 fraudProofId,
        address[] calldata guiltyGuardians,
        bytes calldata fraudProof
    ) external view returns (bool);
}

/**
 * @title BLSAggregator
 * @notice BLS signature aggregation and verification for DVT slash consensus (V3)
 * @dev Aggregates signatures and updates global reputation in Registry V3.
 *
 *      P0-1 (B6-C1a): pkAgg is no longer accepted from the caller. Pre-fix
 *      `verify(message, signerMask, pkAgg, sig)` accepted any caller-supplied
 *      pkAgg, and the pairing equation `e(pk_agg, H(m)) == e(g1, sig)` is
 *      mathematically satisfiable for any chosen pair (sig, pkAgg). This
 *      allowed an anonymous attacker to forge BLS proofs against any operator
 *      and trigger slash / blacklist / reputation actions. The fix:
 *      1. Public keys are stored as typed `BLS.G1Point` (uncompressed, 128
 *         bytes) along with a 1-indexed validator slot in `[1..MAX_VALIDATORS]`.
 *      2. The aggregator reconstructs `pkAgg` itself from the on-chain
 *         `blsPublicKeys` selected by `signerMask` using the EIP-2537
 *         `BLS12_G1ADD` precompile.
 *      3. The proof payload no longer contains a public key field; it is
 *         strictly `abi.encode(signerMask, sigG2)` (msgG2 is also derived
 *         on-chain via `BLS.hashToG2(expectedMessageHash)`).
 *
 *      Companion fix: `BLSValidator.sol` and `IBLSValidator.sol` are deleted
 *      because the same forgery surface existed there. All callers (Registry,
 *      ReputationSystem, DVTValidator) are routed through this aggregator.
 */
contract BLSAggregator is Ownable, ReentrancyGuard, IVersioned {

    // ====================================
    // Structs
    // ====================================

    /// @notice Stored BLS validator key. Format is uncompressed EIP-2537 G1
    ///         (4 × 32 = 128 bytes) so the key can be fed directly to the
    ///         G1ADD precompile during `_reconstructPkAgg` without a costly
    ///         decompression step.
    struct BLSValidatorKey {
        BLS.G1Point publicKey;
        uint8 index;       // 1-indexed slot in [1..MAX_VALIDATORS]; 0 = unregistered
        bool isActive;
    }

    struct AggregatedSignature {
        bytes aggregatedSig;        // 256 bytes G2
        address[] signers;
        bytes32 messageHash;
        uint256 timestamp;
        bool verified;
    }

    struct GuardianSlashCase {
        bytes32 guardiansHash;
        uint64 deadline;
        uint8 status; // 0=none, 1=pending, 2=executed, 3=expired
        // CC-48 HIGH-2: a case is only "executed" once EVERY accused guardian has
        // been individually resolved. Partial progress keeps status == 1 so the
        // case stays retryable instead of collapsing into an all-or-nothing batch.
        uint16 guardianCount;
        uint16 resolvedCount;
        // CC-48 round-3 HIGH-1: the fraud-proof verifier PINNED at queue time.
        // `executeGuardianSlash` re-verifies against THIS address, never against the
        // live `fraudProofVerifier`. Without the snapshot, a rotation that was
        // proposed long before the case (and left matured-but-unapplied — the delay
        // only bounds propose->apply, nothing forces apply to be timely) could be
        // fired the block after a case is queued, swapping in an always-false
        // verifier and running the case out to expiry. The delay made the rotation
        // slow; only the snapshot makes the queued case immune to it.
        address verifier;
    }

    struct GuardianExitRequest {
        uint64 readyAt;
        uint64 expiresAt;
    }

    // ====================================
    // Storage
    // ====================================

    IRegistry public immutable REGISTRY;
    address public SUPERPAYMASTER;
    address public DVT_VALIDATOR;

    /// @notice Validator → registered key. `isActive` doubles as registration flag.
    mapping(address => BLSValidatorKey) internal _blsKeys;

    /// @notice 1-indexed slot → validator address. signerMask bit `i` (0-indexed)
    ///         corresponds to validator at slot `i+1`.
    mapping(uint8 => address) public validatorAtSlot;

    mapping(uint256 => AggregatedSignature) public aggregatedSignatures;
    mapping(uint256 => bool) public executedProposals;
    /// @notice Replay guard for queueSlashWithConsensus. A queue proof commits to
    ///         (operator, slashLevel, epoch, chainid); once consumed it cannot be
    ///         replayed — otherwise the same signed proof could re-flag an operator
    ///         after the owner cancelled the slash or after it already executed
    ///         (a reusable withdraw-block DoS). A fresh, legitimate re-queue simply
    ///         uses a new epoch (→ new hash).
    mapping(bytes32 => bool) public usedSlashQueueHashes;
    mapping(uint256 => uint256) public proposalNonces;

    uint256 public minThreshold = 3;    // Floor for the GENERIC executeProposal path only
    uint256 public defaultThreshold = 7; // Default for the reputation consensus path
    uint256 public constant MAX_VALIDATORS = 13;

    /// @notice Absolute signature floor enforced inside `_checkSignatures` for
    ///         EVERY verification path (a hard safety net; no path may verify
    ///         below this). The generic executeProposal path layers the stricter
    ///         `minThreshold` on top, so lowering the slash floor to 2 (for a
    ///         2-of-3 WARNING) does NOT widen the generic path — that stays at
    ///         minThreshold. Also the min a slash-table entry may be set to.
    uint8 public constant SLASH_THRESHOLD_FLOOR = 2;

    // ====================================
    // CC-48 round-2: versioned domain separation
    // ====================================
    //
    // Every signed pre-image on every path is
    //     keccak256(abi.encode(domainSeparator(), <PATH_TAG>, ...fields))
    // where
    //     domainSeparator() = keccak256(abi.encode(DOMAIN_NAME, block.chainid,
    //                                              address(this), address(REGISTRY)))
    //
    // Before this change a pre-image committed to chainid only. Two aggregators
    // deployed on the SAME chain over the SAME validator keys/slots therefore
    // accepted byte-identical proofs — an experiment-only deployment's signatures
    // replayed verbatim against a production one. Refusing to *configure* the
    // experimental contract is a policy control, not a cryptographic one; the
    // domain now carries `address(this)` and the bound Registry, so a proof simply
    // does not verify anywhere else. Registry re-derives the identical separator
    // locally (see Registry.blsDomainSeparator) — it never asks the aggregator for
    // it, keeping the second verification independent.
    //
    // Bump the *_v1 suffixes ONLY on a breaking encoding change; DVT/SDK pin them.

    /// @notice Versioned domain name shared by every BLS pre-image in this system.
    bytes32 public constant DOMAIN_NAME = keccak256("SuperPaymaster.BLSConsensus.v1");

    /// @notice Path tags. Distinct per path so a proof for one path is never a
    ///         valid proof for another, even with otherwise-identical fields.
    bytes32 public constant TAG_QUEUE_SLASH = keccak256("SuperPaymaster.BLS.QueueSlash.v1");
    bytes32 public constant TAG_EXECUTE_SLASH = keccak256("SuperPaymaster.BLS.ExecuteSlash.v1");
    bytes32 public constant TAG_REPUTATION = keccak256("SuperPaymaster.BLS.Reputation.v1");
    bytes32 public constant TAG_PROPOSAL = keccak256("SuperPaymaster.BLS.Proposal.v1");
    bytes32 public constant TAG_POP = keccak256("SuperPaymaster.BLS.PoP.v1");
    bytes32 public constant TAG_SIGNERS_COMMITMENT = keccak256("SuperPaymaster.BLS.SignersCommitment.v1");
    bytes32 public constant TAG_FRAUD_PROOF = keccak256("SuperPaymaster.BLS.FraudProof.v1");

    /// @notice The domain separator every pre-image on this contract commits to.
    /// @dev    Not cached in storage: `block.chainid` must stay live so a chain
    ///         fork cannot inherit the pre-fork domain, and both addresses are
    ///         immutable anyway, so there is nothing to cache.
    function domainSeparator() public view returns (bytes32) {
        return keccak256(abi.encode(DOMAIN_NAME, block.chainid, address(this), address(REGISTRY)));
    }

    /// @notice Canonical digest handed to `IFraudProofVerifier.verify`.
    /// @dev    Public so DVT can reproduce it byte-for-byte off-chain.
    function fraudProofDigest(uint256 fraudProofId, address[] calldata guiltyGuardians)
        public
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(domainSeparator(), TAG_FRAUD_PROOF, fraudProofId, guiltyGuardians));
    }

    /// @notice Canonical proof-of-possession digest for (validator, publicKey).
    /// @dev    CC-48 round-2 HIGH: the pre-image now binds the VALIDATOR ADDRESS
    ///         (and the domain). Previously it covered only the public key, so the
    ///         PoP sitting in one registrant's public calldata could be lifted by
    ///         any other ROLE_DVT address to register the same key at a second slot.
    ///         With the same key in N slots the reconstructed pkAgg is N*pk, and the
    ///         single key holder can produce N*sk*H(m) — one signer masquerading as
    ///         a quorum. Address binding kills the lift; `blsKeyOwner` (below) kills
    ///         the duplicate registration even when the key holder tries it himself.
    function popDigest(address validator, BLS.G1Point calldata publicKey) public view returns (bytes32) {
        return keccak256(
            abi.encode(domainSeparator(), TAG_POP, validator, publicKey.x_a, publicKey.x_b, publicKey.y_a, publicKey.y_b)
        );
    }

    /// @notice H-1: slash / consensus-marking selectors the GENERIC executeProposal
    ///         path may never invoke on any target. The aPNTs burn
    ///         (executeSlashWithBLS) and proposalId marking (markProposalExecuted)
    ///         must go through the threshold-checked slash path (verifyAndExecute),
    ///         and the reversible pre-flag (queueSlash) has its own dedicated
    ///         quorum-gated entry (queueSlashWithConsensus) — none belong on a
    ///         caller-chosen-threshold generic `.call`. We do NOT blocklist whole
    ///         targets: Registry.updateOperatorBlacklist is a legitimate DVT-consensus
    ///         generic action, and batchUpdateGlobalReputation self-protects via
    ///         Registry's independent proof re-verification.
    bytes4 private constant SEL_QUEUE_SLASH = bytes4(keccak256("queueSlash(address)"));
    bytes4 private constant SEL_EXECUTE_SLASH_BLS = bytes4(keccak256("executeSlashWithBLS(address,uint8,bytes)"));
    bytes4 private constant SEL_MARK_PROPOSAL_EXECUTED = bytes4(keccak256("markProposalExecuted(uint256)"));

    /// @notice Per-severity slash consensus threshold, keyed by SlashLevel
    ///         (0=WARNING, 1=MINOR, 2=MAJOR). Bootstrap (N=3): 2/3/3. This
    ///         replaces the flat defaultThreshold for the slash-only path so the
    ///         bar scales with severity and with the validator set over time,
    ///         by governance table update rather than a code change.
    mapping(uint8 => uint8) public slashThresholds;

    /// @notice Address permitted to update `slashThresholds`. Set this to a
    ///         multisig for plain governance, or to a TimelockController(multisig)
    ///         to get timelocked policy changes WITHOUT building timelock logic
    ///         (and its bytecode) into this contract. Owner rotates it.
    address public slashPolicyAdmin;

    /// @notice H-02: when true, a staked ROLE_DVT validator may self-register their OWN
    ///         BLS key (with proof-of-possession) instead of requiring an owner call.
    ///         Default false — onboarding stays owner-gated (off-chain trust established
    ///         first) until governance flips it on. Closes the otherwise-inconsistent
    ///         path where Registry ROLE_DVT is permissionless (self-service stake) but
    ///         BLS-key registration here was owner-only.
    bool public permissionlessBLSRegistration;

    /// @notice DVT-supplied fraud-proof verifier for guardian-collusion slashing
    ///         (Protocol B stage 2). address(0) = feature dormant: executeGuardianSlash
    ///         reverts until governance wires a verifier. This is the ONE seam the
    ///         detection layer plugs into; the aggregator never judges fraud itself.
    address public fraudProofVerifier;

    /// @notice Per-(fraudProofId, guardian) slash record for executeGuardianSlash.
    ///         Consumption is tracked PER GUARDIAN — and only for guardians actually
    ///         slashed — so submitting an already-exited co-signer can never burn the
    ///         proof for the still-staked colluders (the global-id-consumption flaw this
    ///         replaces). Own id-space; never collides with slash/reputation proposalIds.
    mapping(uint256 => mapping(address => bool)) public guardianSlashed;

    /// @notice A' attribution (CC-89 stage-2): commitment to the exact signer
    ///         ADDRESS set of each executed proposal, snapshotted at execution time
    ///         before any revokeBLSPublicKey can reassign a slot. A fraud-proof
    ///         verifier matches proof-supplied claimedSigners against this to
    ///         attribute a fraudulent slash to real addresses. It is a 1-slot
    ///         fingerprint and is NOT reversible — the address list's data
    ///         availability is the DVT detection layer's (redundant watchers) job.
    mapping(uint256 => bytes32) public proposalSignersCommitment;

    /// @notice Two-step guardian-slash lifecycle. Queueing a verifier-approved
    ///         case freezes every accused guardian's ROLE_DVT exit in Registry;
    ///         execution or permissionless expiry releases exactly one count.
    mapping(uint256 => GuardianSlashCase) public guardianSlashCases;
    mapping(address => GuardianExitRequest) public guardianExitRequests;
    mapping(address => uint256) public pendingGuardianSlashCount;

    /// @notice CC-48 HIGH-2: per-(case, guardian) release marker. Set exactly once,
    ///         when that guardian's `pendingGuardianSlashCount` contribution for the
    ///         case is given back — either because the slash succeeded, because the
    ///         guardian had nothing left to slash, or because the case expired. A
    ///         guardian whose `slashByDVT` reverted stays UNresolved and frozen, so a
    ///         single staking-side failure can no longer release the whole set.
    mapping(uint256 => mapping(address => bool)) public guardianCaseResolved;

    /// @notice CC-48 round-2: permanent binding of a G1 public key to the FIRST
    ///         validator address it was registered under.
    /// @dev    Deliberately never cleared — not on `revokeBLSPublicKey`, not on exit.
    ///         Clearing it would let a revoked key be re-claimed by a different
    ///         address, which is exactly the duplicate-key condition this prevents.
    ///         A validator re-registering its OWN key (rotation back, slot reuse)
    ///         still passes because the binding matches.
    ///         Key: keccak256(abi.encode(pk.x_a, pk.x_b, pk.y_a, pk.y_b)).
    mapping(bytes32 => address) public blsKeyOwner;

    /// @notice CC-48 BLOCKER-1: earliest timestamp at which a guardian may open a new
    ///         exit notice after cancelling one. Kills request/cancel flip-flopping as
    ///         a cheap, repeatable lever on the signer set.
    mapping(address => uint64) public guardianExitCooldownUntil;

    /// @notice CC-48 MEDIUM-1: two-step, delay-guarded fraud-proof verifier rotation.
    ///         `pendingFraudProofVerifierReadyAt != 0` means a rotation is in flight.
    address public pendingFraudProofVerifier;
    uint64 public pendingFraudProofVerifierReadyAt;

    /// @dev CC-48 HIGH-2: the case window MUST strictly dominate a full exit notice
    ///      (delay + consumption window). At 2 days each, an accused guardian could
    ///      line up `readyAt` with the case deadline and walk the moment the case
    ///      expired. 4 > 2 + 1 leaves no such alignment: an exit notice opened at or
    ///      after the queueing block always expires before the case does.
    uint256 public constant GUARDIAN_SLASH_CASE_WINDOW = 4 days;
    uint256 public constant GUARDIAN_EXIT_DELAY = 2 days;
    uint256 public constant GUARDIAN_EXIT_WINDOW = 1 days;
    /// @notice Quiet period imposed after cancelling an exit notice (BLOCKER-1).
    uint256 public constant GUARDIAN_EXIT_COOLDOWN = 1 days;
    /// @notice Verifier rotations mature no faster than a full case window, so
    ///         governance cannot retroactively kill a queued case by swapping in a
    ///         verifier that returns false (CC-48 MEDIUM-1).
    uint256 public constant VERIFIER_ROTATION_DELAY = GUARDIAN_SLASH_CASE_WINDOW;

    function version() external pure override returns (string memory) {
        return "BLSAggregator-4.7.0";
    }


    // ====================================
    // Events
    // ====================================
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);
    /// @notice Emitted when governance updates a per-severity slash threshold.
    event SlashThresholdUpdated(uint8 indexed slashLevel, uint8 oldThreshold, uint8 newThreshold);
    /// @notice Emitted when the owner rotates the slash-policy admin.
    event SlashPolicyAdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    /// @notice Emitted on a successful slash-only consensus, recording the
    ///         on-chain-committed evidence hash + the threshold it cleared, so
    ///         off-chain archives can bind their stored proof to the chain fact.
    event SlashConsensusReached(uint256 indexed proposalId, uint8 slashLevel, uint256 requiredThreshold, bytes32 evidenceHash);
    /// @notice Emitted when a DVT quorum pre-flags an operator for slashing (the
    ///         reversible first step of the two-step slash; blocks withdraw until
    ///         execute or owner cancel).
    event SlashPreQueued(address indexed operator, uint8 slashLevel, uint256 epoch, uint256 requiredThreshold);

    event BLSPublicKeyRegistered(address indexed validator, uint8 indexed slot);
    event PermissionlessBLSRegistrationSet(bool enabled);
    event BLSPublicKeyRevoked(address indexed validator, uint8 indexed slot);
    /// @notice CC-48 round-3: an owner-initiated recovery released a key-to-owner binding
    ///         that no active slot was using (misconfiguration escape hatch).
    event BLSKeyBindingReleased(bytes32 indexed keyHash, address indexed previousOwner);
    event SignatureAggregated(uint256 indexed proposalId, bytes aggregatedSignature, uint256 count);
    event SlashExecuted(uint256 indexed proposalId, address indexed operator, uint8 level);
    event ReputationEpochTriggered(uint256 epoch, uint256 userCount);
    event BLSVerificationStatus(uint256 indexed proposalId, bool success);
    event ProposalExecuted(uint256 indexed proposalId, address indexed target, bytes32 callDataHash);
    /// @notice Emitted when the SuperPaymaster address is updated by the owner.
    event SuperPaymasterUpdated(address indexed oldAddr, address indexed newAddr);
    /// @notice Emitted when the DVTValidator address is updated by the owner.
    event DVTValidatorUpdated(address indexed oldAddr, address indexed newAddr);
    /// @notice Emitted when the owner wires/rotates the fraud-proof verifier.
    event FraudProofVerifierUpdated(address indexed oldAddr, address indexed newAddr);
    /// @notice Emitted per guardian whose ROLE_DVT stake was slashed for proven
    ///         collusion. `amount` is the full lock slashed (→ auto-eject on next verify).
    event GuardianSlashed(uint256 indexed fraudProofId, address indexed guardian, uint256 amount);
    /// @notice Emitted when a named guardian had no ROLE_DVT lock to slash (exited /
    ///         already-ejected). On-chain trace so monitors can tell "escaped via exit"
    ///         apart from "was never on the list"; no id/guardian is consumed here.
    event GuardianSlashSkipped(uint256 indexed fraudProofId, address indexed guardian);
    event GuardianSlashQueued(uint256 indexed fraudProofId, bytes32 guardiansHash, uint256 deadline);
    event GuardianSlashCaseExpired(uint256 indexed fraudProofId);
    /// @notice CC-48 round-3 HIGH-1: the verifier a queued case is permanently bound to.
    event GuardianSlashVerifierPinned(uint256 indexed fraudProofId, address indexed verifier);
    /// @notice A case whose accused guardians have all been individually resolved.
    event GuardianSlashCaseResolved(uint256 indexed fraudProofId);
    /// @notice A single guardian's slash reverted on the staking side. The case stays
    ///         pending and this guardian stays frozen — the call is simply retryable.
    event GuardianSlashFailed(uint256 indexed fraudProofId, address indexed guardian);
    event GuardianExitRequested(address indexed guardian, uint256 readyAt, uint256 expiresAt);
    event GuardianExitCancelled(address indexed guardian, uint256 cooldownUntil);
    event FraudProofVerifierRotationProposed(address indexed verifier, uint256 readyAt);
    event FraudProofVerifierRotationCancelled(address indexed verifier);
    event GuardianExitConsumed(address indexed guardian);

    // ====================================
    // Constants (BLS12-381 Math)
    // ====================================

    uint256 constant P_HI = 0x1a0111ea397fe69a4b1ba7b6434bacd7;
    uint256 constant P_LO = 0x64774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab;

    // ====================================
    // Errors
    // ====================================

    error InvalidSignatureCount(uint256 count, uint256 required);
    error SignatureVerificationFailed();
    error ProposalAlreadyExecuted(uint256 proposalId);
    /// @notice A queueSlashWithConsensus proof was replayed (same operator/level/epoch).
    error SlashQueueProofAlreadyUsed(bytes32 queueHash);
    error UnauthorizedCaller(address caller);
    error InvalidAddress(address addr);
    error InvalidBLSKey();
    error InvalidParameter(string message);
    error ProposalExecutionFailed(uint256 proposalId, bytes returnData);
    error InvalidTarget(address target);
    error InvalidProposalId();
    /// @notice H-1: the generic executeProposal path invoked a slash / consensus-
    ///         marking selector that must go through the threshold-checked slash
    ///         path (verifyAndExecute), not a caller-chosen-threshold generic call.
    error ForbiddenGenericSelector(bytes4 selector);
    /// @notice A slash threshold update fell outside [SLASH_THRESHOLD_FLOOR, MAX_VALIDATORS].
    error SlashThresholdOutOfRange(uint8 threshold);
    /// @notice Caller is not the slash-policy admin.
    error NotSlashPolicyAdmin(address caller);
    /// @notice signerMask references a slot whose validator key is not registered/active.
    error UnknownValidatorSlot(uint8 slot);
    /// @notice signerMask references a slot index outside [1..MAX_VALIDATORS].
    error SlotOutOfRange(uint8 slot);
    /// @notice The provided slot is already bound to another validator.
    error SlotAlreadyTaken(uint8 slot);
    /// @notice signerMask is zero (no signers selected).
    error EmptySignerMask();
    /// @notice A slot referenced by signerMask resolves to a validator that no
    ///         longer holds ROLE_DVT in the Registry. P0 follow-up — pkAgg
    ///         reconstruction must reject ex-validators in real time.
    error SlotValidatorRoleRevoked(uint8 slot, address v);
    /// @notice A slot referenced by signerMask resolves to a validator whose
    ///         locked GToken stake under ROLE_DVT has fallen below `minStake`.
    ///         Catches partial unlocks and post-slash drawdowns.
    error SlotValidatorStakeBelowMinimum(uint8 slot, address v, uint256 actual, uint256 required);
    /// @notice The Registry has no staking pointer wired up yet — the per-slot
    ///         real-time validation cannot resolve role locks. Mirrors
    ///         DVTValidator.StakingNotConfigured for symmetry.
    error StakingNotConfigured();
    /// @notice `revokeBLSPublicKey` was called for a validator whose key is not
    ///         currently active. Stricter than the previous idempotent return
    ///         so misbehavior is loudly surfaced to off-chain operators.
    error KeyNotActive(address v);
    /// @notice H-02: a non-owner tried to self-register a BLS key while the
    ///         permissionless switch is off.
    error PermissionlessRegistrationDisabled();
    /// @notice H-02: the proof-of-possession did not verify against the public key.
    error InvalidPoP();
    /// @notice The supplied G1 point is not on the BLS12-381 G1 curve (G1ADD precompile rejected it),
    ///         or it is the point at infinity (identity element), which is forbidden to prevent
    ///         key-cancellation attacks during pkAgg reconstruction.
    error InvalidBLSKeyNotOnCurve();
    /// @notice The supplied G1 point is not in the prime-order subgroup of G1 (r*P != infinity).
    ///         Small-subgroup points contaminate the reconstructed pkAgg and can be used to
    ///         bias or forge aggregate signatures.
    error InvalidBLSKeyNotInSubgroup();
    /// @notice executeGuardianSlash called while no fraud-proof verifier is wired (feature dormant).
    error FraudProofVerifierNotSet();
    /// @notice The fraud-proof verifier rejected (fraudProofId, guiltyGuardians, fraudProof).
    error InvalidFraudProof(uint256 fraudProofId);
    /// @notice executeGuardianSlash received an empty guiltyGuardians array.
    error EmptyGuiltyGuardians();
    error GuardianSlashCaseAlreadyOpened(uint256 fraudProofId);
    error GuardianSlashCaseNotPending(uint256 fraudProofId);
    error GuardianSlashCaseExpiredError(uint256 fraudProofId, uint256 deadline);
    error GuardianSlashCaseNotExpired(uint256 fraudProofId, uint256 deadline);
    error GuardianSetMismatch(uint256 fraudProofId);
    error GuardianExitAlreadyRequested(address guardian);
    error GuardianExitNotRequested(address guardian);
    error GuardianExitNotReady(address guardian, uint256 readyAt);
    error GuardianExitRequestExpired(address guardian, uint256 expiresAt);
    error GuardianExitBlockedBySlash(address guardian, uint256 pendingCount);
    error NotRegistry(address caller);
    error SlotValidatorExitPending(uint8 slot, address validator);
    error GuardianExitCooldownActive(address guardian, uint256 cooldownUntil);
    error GuardianExitWouldBreakQuorum(uint256 remainingActive, uint256 required);
    error NoPendingVerifierRotation();
    error VerifierRotationNotReady(uint256 readyAt);
    /// @dev CC-48 round-3 HIGH-1: the verifier snapshotted when the case was queued no
    ///      longer holds code (selfdestructed / never was a contract). Fail CLOSED —
    ///      the case cannot be executed against a different verifier, and must be left
    ///      to expire. Silently falling back to the live `fraudProofVerifier` would
    ///      re-open exactly the retroactive-swap hole the snapshot closes.
    error GuardianSlashVerifierGone(uint256 fraudProofId, address verifier);
    /// @dev CC-48 round-3: a verifier must be a contract at queue time; snapshotting an
    ///      EOA would pin a case to something that can never verify.
    error VerifierNotContract(address verifier);
    /// @dev CC-48 round-3: the key-to-owner binding may only be released while NO active
    ///      slot holds that key. Otherwise releasing it would let a second address claim
    ///      the key of a live signer.
    error KeyBindingStillActive(bytes32 keyHash, address boundTo);
    /// @dev CC-48 round-3: a proposal that carries no reputation batch, no operator and
    ///      no severity does nothing but burn a proposalId in two contracts. It still
    ///      requires a real quorum, so it is not an attack — but a consensus path with a
    ///      no-op shape is a place for future divergence, so the shape is rejected.
    error EmptyProposalNotSupported();
    /// @dev CC-48 round-2: the same G1 public key may never be bound to two
    ///      validator addresses. N slots holding one key make pkAgg = N*pk, which a
    ///      single secret-key holder can sign for — a 1-of-N quorum forgery.
    error DuplicatePublicKey(bytes32 keyHash, address boundTo);
    /// @dev CC-48 round-2: the combined (reputation + slash) proposal shape is
    ///      rejected outright. Its aggregator pre-image committed to the real
    ///      operator/slashLevel while Registry re-derived the reputation pre-image
    ///      with address(0)/0, so the two verifications could never agree on the same
    ///      signature. Rather than invent a second reputation schema, the shape is
    ///      forbidden: submit the slash and the reputation update as separate proposals.
    error CombinedProposalNotSupported();

    // ====================================
    // Constructor
    // ====================================

    constructor(
        address _registry,
        address _superPaymaster,
        address _dvtValidator
    ) Ownable(msg.sender) {
        if (_registry == address(0)) revert InvalidAddress(_registry);
        if (_superPaymaster == address(0)) revert InvalidAddress(_superPaymaster);
        if (_dvtValidator == address(0)) revert InvalidAddress(_dvtValidator);
        REGISTRY = IRegistry(_registry);
        SUPERPAYMASTER = _superPaymaster;
        DVT_VALIDATOR = _dvtValidator;

        // Bootstrap slash thresholds for N=3: WARNING 2-of-3 (no funds moved,
        // reputation ding only), MINOR/MAJOR 3-of-3 (real aPNTs at stake).
        // Governance raises these via setSlashThreshold as the validator set grows.
        slashThresholds[uint8(ISuperPaymasterSlash.SlashLevel.WARNING)] = 2;
        slashThresholds[uint8(ISuperPaymasterSlash.SlashLevel.MINOR)]   = 3;
        slashThresholds[uint8(ISuperPaymasterSlash.SlashLevel.MAJOR)]   = 3;

        // Owner is the initial policy admin; rotate to a multisig / timelock post-deploy.
        slashPolicyAdmin = msg.sender;
    }

    /// @notice Update the per-severity slash consensus threshold.
    /// @dev    Gated to `slashPolicyAdmin` (a multisig, or a TimelockController for
    ///         timelocked changes). Floored at SLASH_THRESHOLD_FLOOR and capped at
    ///         MAX_VALIDATORS. Operationally the value should stay <= the active
    ///         validator count, otherwise that severity becomes unslashable.
    function setSlashThreshold(uint8 slashLevel, uint8 threshold) external {
        if (msg.sender != slashPolicyAdmin) revert NotSlashPolicyAdmin(msg.sender);
        if (slashLevel > uint8(ISuperPaymasterSlash.SlashLevel.MAJOR)) revert InvalidParameter("slashLevel");
        if (threshold < SLASH_THRESHOLD_FLOOR || threshold > MAX_VALIDATORS) {
            revert SlashThresholdOutOfRange(threshold);
        }
        emit SlashThresholdUpdated(slashLevel, slashThresholds[slashLevel], threshold);
        slashThresholds[slashLevel] = threshold;
    }

    /// @notice Rotate the slash-policy admin (owner only).
    function setSlashPolicyAdmin(address newAdmin) external onlyOwner {
        if (newAdmin == address(0)) revert InvalidAddress(newAdmin);
        emit SlashPolicyAdminUpdated(slashPolicyAdmin, newAdmin);
        slashPolicyAdmin = newAdmin;
    }

    // ====================================
    // Core Functions
    // ====================================

    /// @notice Register a BLS validator's public key into a deterministic slot.
    /// @dev    P0-1: keys are stored uncompressed so `_reconstructPkAgg` can
    ///         feed them straight into the G1ADD precompile. The slot encodes
    ///         the validator's bit position in `signerMask` and is fixed at
    ///         registration to make the bitmap → key mapping unambiguous.
    ///
    ///         P0-1 sub-fix (on-curve + subgroup check): `_validateG1Point` is
    ///         called before storing to guarantee (a) the point is on the
    ///         BLS12-381 G1 curve and (b) it is in the prime-order subgroup r.
    ///         Without (b) an attacker can register a small-subgroup point that
    ///         contaminates the reconstructed pkAgg used in later pairing checks.
    ///         The identity point (point at infinity) is also rejected to prevent
    ///         key-cancellation attacks during aggregation.
    /// @param  validator  validator address (used for events / dedup).
    /// @param  publicKey  uncompressed EIP-2537 G1 point (4×32 bytes).
    /// @param  slot       1-indexed slot in [1..MAX_VALIDATORS]. Must not collide
    ///                    with another validator's already-bound slot.
    /// @param  popSignature proof-of-possession (G2): the validator's BLS signature over
    ///                    `popDigest(validator, publicKey)`. REQUIRED on BOTH paths
    ///                    (CC-48 round-3); a registration without a valid PoP reverts.
    ///
    /// @dev    SECURITY — PoP is enforced on both registration paths.
    ///         There are exactly two registration paths and NEITHER of them skips the
    ///         proof-of-possession check:
    ///           • Owner path (`msg.sender == owner()`): the owner still decides WHO is
    ///             onboarded and at WHICH slot, but no longer decides whether the key is
    ///             really the registrant's. Before round-3 this path skipped PoP on the
    ///             argument that a compromised owner is game-over anyway. That argument
    ///             covers authorization, not this property: `blsKeyOwner` is a permanent,
    ///             deliberately irreversible binding, so one mistyped address bound a
    ///             third party's public key forever, and an owner could pre-empt a
    ///             validator's own self-registration by binding its key first. Both are
    ///             gone: producing `popSignature` requires the corresponding secret key.
    ///           • Permissionless path (`permissionlessBLSRegistration == true`, off by
    ///             default): an untrusted staked ROLE_DVT validator self-registers its OWN
    ///             key. Unchanged — PoP was always enforced here.
    ///         Recovery: `releaseKeyBinding` (owner-only, and only while NO active slot
    ///         holds the key) is the escape hatch for a binding created in error. It
    ///         cannot touch a live signer's binding, so the anti-duplicate property is
    ///         preserved; see the runbook in docs/architecture/dvt-validator-workflow.md.
    ///         Defense-in-depth: a registered key can only contribute to an aggregate if
    ///         its validator address still holds ROLE_DVT with locked stake >= minStake at
    ///         verification time (re-checked live in `_reconstructPkAgg`); a key registered
    ///         for an address lacking the role/stake can never enter a slash/reputation proof.
    function registerBLSPublicKey(
        address validator,
        BLS.G1Point calldata publicKey,
        uint8 slot,
        BLS.G2Point calldata popSignature
    ) external {
        if (validator == address(0)) revert InvalidAddress(address(0));
        if (slot == 0 || slot > MAX_VALIDATORS) revert SlotOutOfRange(slot);

        // Access control. The owner may always register any validator's key at the
        // caller-chosen slot (the permissioned default; popSignature is not inspected).
        // Otherwise — only when the permissionless switch is on — a validator may
        // self-register their OWN key, provided they currently hold ROLE_DVT with
        // sufficient stake AND supply a valid proof-of-possession. PoP blocks the
        // rogue-key attack the owner would otherwise prevent by vetting keys off-chain.
        // Cheap auth checks run BEFORE the G1/pairing precompiles so an unauthorized
        // caller reverts without paying for them; G1 is still validated before _verifyPoP.
        bool ownerCall = msg.sender == owner();
        if (!ownerCall) {
            if (!permissionlessBLSRegistration) revert PermissionlessRegistrationDisabled();
            if (msg.sender != validator) revert UnauthorizedCaller(msg.sender);
            _requireDVTStake(validator, slot);
        }

        // CC-48 round-3: proof-of-possession is MANDATORY on BOTH paths. On-curve +
        // prime-order subgroup membership is validated first, so `_verifyPoP` never
        // pairs against a small-subgroup point.
        _validateG1Point(publicKey);
        if (!_verifyPoP(validator, publicKey, popSignature)) revert InvalidPoP();

        if (!ownerCall) {
            // Permissionless callers do NOT choose their slot: the contract assigns the
            // lowest free slot deterministically (re-registration keeps the prior slot).
            // This removes the slot-squatting / front-running vector where a caller could
            // grab or deny a specific slot. (Filling the whole capped set still costs
            // minStake per identity and remains owner-revocable.)
            slot = _assignSlot(validator);
        }

        // CC-48 round-2: one public key, one validator address — forever. Enforced on
        // the OWNER path too: the owner is trusted to curate keys, not to be immune to
        // a copy-paste, and a duplicated key silently multiplies one signer's weight.
        bytes32 keyHash =
            keccak256(abi.encode(publicKey.x_a, publicKey.x_b, publicKey.y_a, publicKey.y_b));
        address keyOwner = blsKeyOwner[keyHash];
        if (keyOwner == address(0)) {
            blsKeyOwner[keyHash] = validator;
        } else if (keyOwner != validator) {
            revert DuplicatePublicKey(keyHash, keyOwner);
        }

        BLSValidatorKey storage existing = _blsKeys[validator];
        // Re-registration of the SAME validator must reuse the prior slot to
        // avoid leaving a dangling slot pointer for an already-active mask bit.
        if (existing.isActive && existing.index != slot) revert SlotAlreadyTaken(slot);

        // The slot must either be free, or currently occupied by this same validator.
        address current = validatorAtSlot[slot];
        if (current != address(0) && current != validator) revert SlotAlreadyTaken(slot);

        _blsKeys[validator] = BLSValidatorKey({
            publicKey: publicKey,
            index: slot,
            isActive: true
        });
        validatorAtSlot[slot] = validator;
        emit BLSPublicKeyRegistered(validator, slot);
    }

    /// @notice Revoke a previously registered BLS validator key.
    /// @dev    P0 follow-up: stricter semantics than the prior idempotent stub.
    ///         Reverts with `KeyNotActive` if the key is not currently active so
    ///         off-chain operators get a clear failure signal instead of a
    ///         silent no-op. The full key bytes are intentionally preserved
    ///         (only `isActive` is cleared and `validatorAtSlot[slot]` is reset
    ///         to address(0)) so historical proofs that reference the slot can
    ///         still be audited via `getBLSPublicKey`. Re-registration of the
    ///         same validator must use `registerBLSPublicKey` again, which will
    ///         pass `_validateG1Point` and either reuse or claim a new slot.
    function revokeBLSPublicKey(address validator) external onlyOwner {
        BLSValidatorKey storage existing = _blsKeys[validator];
        if (!existing.isActive) revert KeyNotActive(validator);
        uint8 slot = existing.index;
        existing.isActive = false;
        validatorAtSlot[slot] = address(0);
        emit BLSPublicKeyRevoked(validator, slot);
    }

    /// @notice CC-48 round-3 recovery: release a `blsKeyOwner` binding that no ACTIVE
    ///         slot is using.
    /// @dev    The binding is intentionally permanent on the normal paths — clearing it
    ///         on `revokeBLSPublicKey` would let a revoked key be re-claimed by a
    ///         different address, which is exactly the duplicate-key condition the
    ///         binding exists to prevent. This function is the ONE escape hatch for a
    ///         binding created in error, and it is deliberately narrow:
    ///           - owner-only (governance action, not a validator-facing one), and
    ///           - refuses while ANY active slot holds this key, so a live signer's
    ///             binding can never be released out from under it. Combined with the
    ///             now-mandatory PoP on both registration paths, the only way to reach
    ///             this function's precondition is a key that is registered nowhere.
    ///         Runbook: revoke the slot first (`revokeBLSPublicKey`), confirm
    ///         `getBLSPublicKey(...).isActive == false` for every holder, then release.
    ///         After release the key may be re-registered by whoever can produce a PoP
    ///         for it — i.e. its actual holder.
    /// @param  keyHash keccak256(abi.encode(pk.x_a, pk.x_b, pk.y_a, pk.y_b)).
    function releaseKeyBinding(bytes32 keyHash) external onlyOwner {
        address boundTo = blsKeyOwner[keyHash];
        if (boundTo == address(0)) revert InvalidParameter("keyHash");
        // Scan the (capped, 13-slot) active table rather than trusting `boundTo`'s own
        // record: the key may have been rotated to a different address's slot, and the
        // property we need is "no ACTIVE slot holds this key", not "boundTo is idle".
        for (uint8 slot = 1; slot <= uint8(MAX_VALIDATORS); ) {
            address holder = validatorAtSlot[slot];
            if (holder != address(0)) {
                BLSValidatorKey storage k = _blsKeys[holder];
                if (
                    k.isActive
                        && keccak256(
                            abi.encode(k.publicKey.x_a, k.publicKey.x_b, k.publicKey.y_a, k.publicKey.y_b)
                        ) == keyHash
                ) {
                    revert KeyBindingStillActive(keyHash, holder);
                }
            }
            unchecked { ++slot; }
        }
        delete blsKeyOwner[keyHash];
        emit BLSKeyBindingReleased(keyHash, boundTo);
    }

    /// @notice View accessor returning the stored G1 public key + slot for a validator.
    function getBLSPublicKey(address validator)
        external
        view
        returns (BLS.G1Point memory publicKey, uint8 slot, bool isActive)
    {
        BLSValidatorKey memory k = _blsKeys[validator];
        return (k.publicKey, k.index, k.isActive);
    }

    /// @notice External BLS pairing verification used by Registry / ReputationSystem.
    /// @dev    P0-1: callers cannot supply pkAgg or msgG2 anymore. Both are
    ///         derived deterministically — pkAgg from `signerMask` against the
    ///         on-chain validator set, msgG2 from `expectedMessageHash`. Returns
    ///         true iff the pairing equation holds and at least
    ///         `requiredThreshold` distinct on-chain validators are selected.
    /// @param  expectedMessageHash The exact hash the signers committed to.
    /// @param  signerMask Bitmask of signing validator slots (bit i = slot i+1).
    /// @param  requiredThreshold Caller's minimum signer count requirement.
    /// @param  sigBytes abi.encode(BLS.G2Point) of the aggregated G2 signature.
    function verify(
        bytes32 expectedMessageHash,
        uint256 signerMask,
        uint256 requiredThreshold,
        bytes calldata sigBytes
    ) external view returns (bool) {
        if (signerMask == 0) revert EmptySignerMask();
        if (requiredThreshold < minThreshold) {
            revert InvalidParameter("Threshold below minimum");
        }
        if (requiredThreshold > MAX_VALIDATORS) {
            revert InvalidParameter("Threshold exceeds max");
        }

        (BLS.G1Point memory pkAgg, uint256 signerCount) = _reconstructPkAgg(signerMask);
        if (signerCount < requiredThreshold) {
            revert InvalidSignatureCount(signerCount, requiredThreshold);
        }

        BLS.G2Point memory sig = abi.decode(sigBytes, (BLS.G2Point));
        BLS.G2Point memory msgG2 = BLS.hashToG2(abi.encodePacked(expectedMessageHash));

        BLS.G1Point[] memory g1s = new BLS.G1Point[](2);
        BLS.G2Point[] memory g2s = new BLS.G2Point[](2);
        g1s[0] = _getG1Generator();
        g2s[0] = sig;
        g1s[1] = _negateG1Point(pkAgg);
        g2s[1] = msgG2;

        return BLS.pairing(g1s, g2s);
    }

    /// @notice Step 1 of the two-step slash: a DVT quorum pre-flags `operator` for
    ///         slashing (SP.queueSlash), blocking their withdraw until the slash is
    ///         executed (verifyAndExecute) or the owner cancels it. Kept SEPARATE
    ///         from execution so the flag lands in an earlier tx — closing the
    ///         front-run window an atomic queue+execute would reopen.
    /// @dev    Dedicated (not the generic executeProposal) so it (a) is gated at the
    ///         per-severity slash threshold, (b) does NOT consume a proposalId /
    ///         executedProposals slot (queueSlash is idempotent — re-flagging is a
    ///         no-op), leaving the execute-step proposalId intact, and (c) requires a
    ///         real quorum, so no single validator can DoS an operator's withdraw.
    ///         The queue message is domain-separated ("QUEUE_SLASH") so a queue proof
    ///         can never be replayed as an execute proof.
    function queueSlashWithConsensus(
        address operator,
        uint8 slashLevel,
        uint256 epoch,
        bytes calldata proof
    ) external nonReentrant {
        if (msg.sender != DVT_VALIDATOR && msg.sender != owner()) {
            revert UnauthorizedCaller(msg.sender);
        }
        if (operator == address(0)) revert InvalidTarget(operator);
        if (slashLevel > uint8(ISuperPaymasterSlash.SlashLevel.MAJOR)) revert InvalidParameter("slashLevel");
        uint256 requiredThreshold = slashThresholds[slashLevel];
        bytes32 expectedMessageHash = keccak256(abi.encode(
            domainSeparator(), TAG_QUEUE_SLASH, operator, slashLevel, epoch
        ));
        // Replay guard: a consumed queue proof cannot re-flag the operator after a
        // cancel/execute cleared the flag. A legitimate re-queue uses a new epoch.
        if (usedSlashQueueHashes[expectedMessageHash]) revert SlashQueueProofAlreadyUsed(expectedMessageHash);
        _checkSignatures(proof, expectedMessageHash, requiredThreshold);
        usedSlashQueueHashes[expectedMessageHash] = true;
        ISuperPaymasterSlash(SUPERPAYMASTER).queueSlash(operator);
        emit SlashPreQueued(operator, slashLevel, epoch, requiredThreshold);
    }

    function verifyAndExecute(
        uint256 proposalId,
        address operator,
        uint8 slashLevel,
        address[] calldata repUsers,
        uint256[] calldata newScores,
        uint256 epoch,
        bytes32 evidenceHash,
        bytes calldata proof
    ) external nonReentrant {
        if (msg.sender != DVT_VALIDATOR && msg.sender != owner()) {
            revert UnauthorizedCaller(msg.sender);
        }
        if (proposalId == 0) revert InvalidProposalId();
        if (executedProposals[proposalId]) {
            revert ProposalAlreadyExecuted(proposalId);
        }
        // CC-48 round-2: reject the combined shape before any signature work. See
        // CombinedProposalNotSupported — the aggregator and Registry pre-images for a
        // reputation batch can only agree when operator/slashLevel are absent, so a
        // reputation proposal carrying a slash target was never executable anyway
        // (it reverted deep inside Registry with an opaque BLSFailed). Failing here,
        // by name, turns a silent dead path into an explicit protocol rule.
        if (repUsers.length != 0 && (operator != address(0) || slashLevel != 0)) {
            revert CombinedProposalNotSupported();
        }
        // CC-48 round-3 LOW: pin the slash-only shape from the OTHER side too. The
        // slash pre-image commits to (proposalId, operator, slashLevel, epoch,
        // evidenceHash) and NOT to `newScores`, so a non-empty `newScores` here would be
        // caller-controlled input that passed a signature check without being covered by
        // any signature. It is unused on this branch today; requiring it empty means it
        // can never become used-but-unsigned by a later edit.
        if (repUsers.length == 0) {
            if (newScores.length != 0) revert CombinedProposalNotSupported();
            // A proposal with no batch, no target and no severity only burns a
            // proposalId in this contract and in Registry. It needs a real quorum, so it
            // is not an attack surface — but a no-op shape on a consensus path is a
            // place for future divergence, and CC-48 is about making the protocol rules
            // explicit rather than incidental.
            if (operator == address(0) && slashLevel == 0) revert EmptyProposalNotSupported();
        }

        // 1. Construct expected message + resolve the required threshold.
        // The signed message MUST commit to chainid to prevent cross-chain replay.
        bytes32 expectedMessageHash;
        uint256 requiredThreshold;
        if (repUsers.length == 0) {
            // Slash-only consensus path: bar = per-severity governance table
            // (2/3/3 at bootstrap), and the signed message additionally commits to
            // `evidenceHash` so every slash is bound on-chain to the off-chain
            // evidence that justified it. Keeps the reputation branch (below)
            // byte-identical so Registry's independent re-verification still matches.
            if (slashLevel > uint8(ISuperPaymasterSlash.SlashLevel.MAJOR)) revert InvalidParameter("slashLevel");
            requiredThreshold = slashThresholds[slashLevel];
            expectedMessageHash = keccak256(abi.encode(
                domainSeparator(), TAG_EXECUTE_SLASH, proposalId, operator, slashLevel, epoch, evidenceHash
            ));
        } else {
            // Reputation (or combined) path: unchanged 7-field encoding +
            // defaultThreshold, so Registry.batchUpdateGlobalReputation's
            // re-verification reconstructs the identical hash.
            requiredThreshold = defaultThreshold;
            // Byte-identical to Registry._reputationMessageHash. operator/slashLevel
            // are NOT fields here: they are pinned to zero by the combined-shape guard
            // above, so including them could only re-introduce the divergence.
            expectedMessageHash = _reputationMessageHash(proposalId, repUsers, newScores, epoch);
        }

        // 2. Verify BLS pairing using on-chain reconstructed pkAgg (P0-1).
        _checkSignatures(proof, expectedMessageHash, requiredThreshold);

        // 2b. A' attribution snapshot (CC-89 stage-2): commit to the signer ADDRESS
        //     set NOW — after signatures verified, before any revoke can reassign a
        //     slot — so a later fraud proof can attribute this proposal to the real
        //     addresses that signed it. Covers BOTH branches (slash-only + rep).
        proposalSignersCommitment[proposalId] =
            _computeSignersCommitment(proof, proposalId, expectedMessageHash);

        // 3. Update Global Reputation in Registry
        if (repUsers.length > 0) {
            REGISTRY.batchUpdateGlobalReputation(proposalId, repUsers, newScores, epoch, proof);
            emit ReputationEpochTriggered(epoch, repUsers.length);
        } else {
            // Slash-only proposal: mark proposalId in Registry to prevent cross-path replay
            // (attacker holding valid proof cannot reuse proposalId via direct Registry call)
            REGISTRY.markProposalExecuted(proposalId);
            emit SlashConsensusReached(proposalId, slashLevel, requiredThreshold, evidenceHash);
        }

        // 4. Execute Slash if operator is provided
        if (operator != address(0)) {
            _executeSlash(proposalId, operator, slashLevel, proof);
        }

        executedProposals[proposalId] = true;
        if (DVT_VALIDATOR != address(0)) {
            IDVTValidator(DVT_VALIDATOR).markProposalExecuted(proposalId);
        }
    }

    /**
     * @notice Execute any proposal via BLS consensus (Generic DVT)
     * @dev Allows executing arbitrary calls to authorized target contracts after BLS signature verification.
     *      The target contract is responsible for its own access control (checking msg.sender == BLSAggregator).
     * @param proposalId Unique proposal ID
     * @param target Target contract to call
     * @param callData Encoded function call (abi.encodeCall)
     * @param requiredThreshold Required number of signatures (must be >= minThreshold)
     * @param proof BLS aggregated signature proof: abi.encode(uint256 signerMask, bytes sigG2)
     */
    function executeProposal(
        uint256 proposalId,
        address target,
        bytes calldata callData,
        uint256 requiredThreshold,
        bytes calldata proof
    ) external nonReentrant {
        // 1. Access Control
        if (msg.sender != DVT_VALIDATOR && msg.sender != owner()) {
            revert UnauthorizedCaller(msg.sender);
        }
        if (target == address(0)) revert InvalidTarget(target);
        // H-1: block the slash / consensus-marking selectors on the generic path (any
        // target) so a caller-chosen (minThreshold) quorum can never drive
        // SuperPaymaster.queueSlash/executeSlashWithBLS or markProposalExecuted. The
        // fund-moving slash goes through the per-severity threshold in
        // verifyAndExecute; the reversible pre-flag has its own dedicated quorum-gated
        // entry (queueSlashWithConsensus) — neither should be a generic .call, and
        // routing queueSlash through executeProposal would also consume its
        // proposalId (executedProposals + markProposalExecuted), breaking a later
        // verifyAndExecute for the same id. Selector-scoped (not target-scoped) so
        // Registry.updateOperatorBlacklist still works.
        if (callData.length >= 4) {
            bytes4 sel = bytes4(callData[0:4]);
            if (sel == SEL_QUEUE_SLASH || sel == SEL_EXECUTE_SLASH_BLS || sel == SEL_MARK_PROPOSAL_EXECUTED) {
                revert ForbiddenGenericSelector(sel);
            }
        }
        if (proposalId == 0) revert InvalidProposalId();
        if (executedProposals[proposalId]) revert ProposalAlreadyExecuted(proposalId);
        if (requiredThreshold < minThreshold) revert InvalidParameter("Threshold below minimum");
        if (requiredThreshold > MAX_VALIDATORS) revert InvalidParameter("Threshold exceeds max");

        // 2. Construct Generic Message Hash (includes requiredThreshold + chainid)
        bytes32 expectedMessageHash = keccak256(abi.encode(
            domainSeparator(),
            TAG_PROPOSAL,
            proposalId,
            target,
            keccak256(callData),
            requiredThreshold
        ));

        // 3. Verify BLS Signatures with custom threshold
        _checkSignatures(proof, expectedMessageHash, requiredThreshold);

        // 4. Execute Call
        (bool success, bytes memory returnData) = target.call(callData);
        if (!success) revert ProposalExecutionFailed(proposalId, returnData);

        // 5. Mark as Executed
        executedProposals[proposalId] = true;
        if (DVT_VALIDATOR != address(0)) {
            IDVTValidator(DVT_VALIDATOR).markProposalExecuted(proposalId);
        }

        emit ProposalExecuted(proposalId, target, keccak256(callData));
    }

    // ====================================
    // Internal Functions
    // ====================================

    /// @dev Validate that a G1 point is:
    ///      1. Not the identity (point at infinity — all-zero coordinates).
    ///      2. On the BLS12-381 G1 curve — verified via G1ADD precompile (0x0b)
    ///         by adding the point to the identity. The precompile rejects points
    ///         not on the curve with a failed staticcall.
    ///      3. In the prime-order subgroup of G1 — verified via G1MUL precompile
    ///         (0x0c) by multiplying by the subgroup order r. A point in the
    ///         main subgroup must satisfy r*P = O (identity). Points in small
    ///         subgroups would produce a non-zero result.
    ///
    ///      EIP-2537 G1ADD input:  256 bytes (two 128-byte G1 points, big-endian).
    ///      EIP-2537 G1MUL input:  160 bytes (128-byte G1 point + 32-byte scalar).
    ///      Subgroup order r: 0x73eda753299d7d483339d80809a1d80553bda402fffe5bfeffffffff00000001
    function _validateG1Point(BLS.G1Point calldata pk) internal view {
        // 1. Reject the identity element (all-zero x and y).
        //    A registered identity key cancels out any other key's contribution
        //    during pkAgg reconstruction (e.g. P + O = P) — which is safe by
        //    itself, but an attacker could exploit the identity to register a
        //    "ghost" validator slot that passes pairing checks trivially.
        if (
            pk.x_a == bytes32(0) && pk.x_b == bytes32(0) &&
            pk.y_a == bytes32(0) && pk.y_b == bytes32(0)
        ) {
            revert InvalidBLSKeyNotOnCurve();
        }

        // 2. On-curve check via G1ADD(P, O) — add point to the identity.
        //    The precompile returns the input point unchanged if P is on the
        //    curve; it reverts (staticcall returns false) if P is not on the
        //    curve. The G1 identity in uncompressed EIP-2537 format is 128 zero
        //    bytes, which we encode as the second point in the 256-byte input.
        {
            // Input: P (128 bytes) || O (128 bytes of zeros).
            bytes memory g1AddInput = abi.encodePacked(
                pk.x_a, pk.x_b, pk.y_a, pk.y_b,  // P: 128 bytes
                bytes32(0), bytes32(0), bytes32(0), bytes32(0)  // O (identity): 128 bytes
            );
            (bool onCurve,) = address(0x0b).staticcall(g1AddInput);
            if (!onCurve) revert InvalidBLSKeyNotOnCurve();
        }

        // 3. Subgroup check via G1MUL(P, r) — multiply by subgroup order.
        //    r*P must equal the identity (all zeros) for any P in the prime-order
        //    subgroup. Points in a small subgroup have order dividing r but not
        //    equal to r, so r*P_small != O for those points.
        //    r = 0x73eda753299d7d483339d80809a1d80553bda402fffe5bfeffffffff00000001
        {
            bytes32 r = bytes32(uint256(0x73eda753299d7d483339d80809a1d80553bda402fffe5bfeffffffff00000001));
            // Input: P (128 bytes) || r (32-byte scalar).
            bytes memory g1MulInput = abi.encodePacked(
                pk.x_a, pk.x_b, pk.y_a, pk.y_b,  // P: 128 bytes
                r                                   // scalar r: 32 bytes
            );
            (bool ok, bytes memory result) = address(0x0c).staticcall(g1MulInput);
            // The precompile call itself must succeed (point is on curve, already
            // checked above, but defensive).
            if (!ok) revert InvalidBLSKeyNotInSubgroup();
            // Result is a 128-byte G1 point. It must equal the identity (all zeros).
            // We check all four 32-byte words of the returned point.
            if (result.length != 128) revert InvalidBLSKeyNotInSubgroup();
            bytes32 r0; bytes32 r1; bytes32 r2; bytes32 r3;
            assembly {
                r0 := mload(add(result, 32))
                r1 := mload(add(result, 64))
                r2 := mload(add(result, 96))
                r3 := mload(add(result, 128))
            }
            if (r0 != bytes32(0) || r1 != bytes32(0) || r2 != bytes32(0) || r3 != bytes32(0)) {
                revert InvalidBLSKeyNotInSubgroup();
            }
        }
    }

    /// @dev Reconstruct the aggregate public key from `signerMask` by accumulating
    ///      every selected validator's stored G1 point with the EIP-2537 G1ADD
    ///      precompile. Reverts if any selected slot is empty/inactive — this is
    ///      the gate that closes P0-1: the caller cannot inject an unrelated
    ///      pkAgg, every contributing key is read straight from on-chain state.
    ///
    ///      P0 follow-up — every selected slot is also re-validated in real time:
    ///        1. `BLSValidatorKey.isActive` must be true (key not revoked).
    ///        2. The slot's validator must still hold ROLE_DVT in the Registry.
    ///        3. The slot's validator's locked GToken stake under ROLE_DVT must
    ///           be >= the role's `minStake` from `Registry.getRoleConfig`.
    ///      Any one failure reverts the entire aggregation. This closes the
    ///      attack where a registered validator exits / unstakes / loses their
    ///      role but keeps voting power because the slot pointer was never
    ///      cleared. Aggregator owns the trust decision (Registry + Staking) so
    ///      no callback into DVTValidator is needed — avoids a circular
    ///      BLSAggregator ↔ DVTValidator dependency.
    function _reconstructPkAgg(uint256 signerMask)
        internal
        view
        returns (BLS.G1Point memory pkAgg, uint256 count)
    {
        // Reject mask bits beyond MAX_VALIDATORS to prevent silent truncation —
        // a clever attacker could otherwise pad with high-order bits hoping the
        // contract ignored them.
        if (signerMask >> uint256(MAX_VALIDATORS) != 0) {
            revert SlotOutOfRange(uint8(MAX_VALIDATORS + 1));
        }

        // Resolve role+stake context once for the whole loop. The Registry
        // pointer is immutable; the staking pointer (and minStake) are read
        // from Registry per-call so governance can rotate either without
        // redeploying BLSAggregator.
        bytes32 roleDvt = keccak256("DVT");
        IGTokenStaking staking = IRegistryStakingAwareBLS(address(REGISTRY)).GTOKEN_STAKING();
        if (address(staking) == address(0)) revert StakingNotConfigured();
        uint256 minStake = REGISTRY.getRoleConfig(roleDvt).minStake;

        bool initialized = false;
        for (uint8 slot = 1; slot <= MAX_VALIDATORS; slot++) {
            if ((signerMask >> uint256(slot - 1)) & 1 == 0) continue;

            address v = validatorAtSlot[slot];
            if (v == address(0)) revert UnknownValidatorSlot(slot);
            BLSValidatorKey storage k = _blsKeys[v];
            if (!k.isActive) revert UnknownValidatorSlot(slot);

            // Real-time liveness — cheap on-chain reads, but they catch every
            // post-registration drift the original P0-1 fix missed.
            if (!REGISTRY.hasRole(roleDvt, v)) {
                revert SlotValidatorRoleRevoked(slot, v);
            }
            // CC-48 BLOCKER-1: an exit NOTICE must not take effect in the block it is
            // filed. Pre-fix, `readyAt != 0` alone disqualified the slot, so any single
            // ROLE_DVT member could watch the mempool, front-run a quorum transaction
            // with requestGuardianExit() (~1 SSTORE), make it revert, then immediately
            // cancelGuardianExit() — a free, repeatable, self-erasing 1-of-N halt on
            // every BLS-gated governance path. Honouring the notice only once
            // `block.timestamp >= readyAt` means the exclusion is always announced
            // GUARDIAN_EXIT_DELAY in advance: it cannot touch an in-flight proof, and
            // governance has the whole notice period to seat a replacement.
            uint64 exitReadyAt = guardianExitRequests[v].readyAt;
            if (exitReadyAt != 0 && block.timestamp >= uint256(exitReadyAt)) {
                revert SlotValidatorExitPending(slot, v);
            }
            (uint128 amount,,,, ) = staking.roleLocks(v, roleDvt);
            if (uint256(amount) < minStake) {
                revert SlotValidatorStakeBelowMinimum(slot, v, uint256(amount), minStake);
            }

            if (!initialized) {
                pkAgg = k.publicKey;
                initialized = true;
            } else {
                pkAgg = BLS.add(pkAgg, k.publicKey);
            }
            count += 1;
        }

        if (!initialized) revert EmptySignerMask();
    }

    /// @notice A' attribution helper (CC-89 stage-2): compute the signer-set
    ///         commitment for a proposal. Deliberately re-walks signerMask instead
    ///         of threading signers out of _reconstructPkAgg, to keep the
    ///         load-bearing verification path untouched; N ≤ MAX_VALIDATORS so the
    ///         extra SLOAD loop + insertion sort are negligible vs the BLS pairing.
    /// @dev    MUST be called only AFTER _checkSignatures has passed — that guarantees
    ///         signerMask has no out-of-range bits and every selected slot resolves
    ///         to a live validator (validatorAtSlot != 0). Canonical order = ascending
    ///         uint160(address) (no duplicates: each slot maps to one address), so an
    ///         off-chain verifier sorting claimedSigners the same way reproduces the
    ///         identical commitment. signerMask is bound in too (slot layout), and the
    ///         encoding is domain-separated to prevent cross-proposal/chain/contract reuse.
    function _computeSignersCommitment(
        bytes calldata proof,
        uint256 proposalId,
        bytes32 messageHash
    ) internal view returns (bytes32) {
        // proof = abi.encode(uint256 signerMask, bytes sigG2); its first 32-byte
        // word is the mask value. Decode ONLY that slice so we don't copy the
        // (unused here) sigG2 bytes — saves gas on this live consensus path.
        uint256 signerMask = abi.decode(proof[:32], (uint256));
        // popcount → exact array size.
        uint256 n;
        { uint256 m = signerMask; while (m != 0) { m &= (m - 1); n++; } }

        address[] memory signers = new address[](n);
        uint256 k;
        for (uint8 slot = 1; slot <= MAX_VALIDATORS; slot++) {
            if ((signerMask >> uint256(slot - 1)) & 1 == 0) continue;
            signers[k++] = validatorAtSlot[slot];
        }

        // Insertion sort ascending by uint160(address) (n ≤ MAX_VALIDATORS).
        for (uint256 i = 1; i < n; i++) {
            address key = signers[i];
            uint256 j = i;
            while (j > 0 && uint160(signers[j - 1]) > uint160(key)) {
                signers[j] = signers[j - 1];
                unchecked { j--; }
            }
            signers[j] = key;
        }

        return keccak256(abi.encode(
            domainSeparator(),
            TAG_SIGNERS_COMMITMENT,
            proposalId,
            messageHash,
            signerMask,
            signers
        ));
    }

    /// @notice Canonical reputation-batch pre-image. MUST stay byte-identical to
    ///         `Registry._reputationMessageHash` — Registry independently re-verifies
    ///         the same signature, and any divergence turns every reputation proposal
    ///         into an unexplained `BLSFailed`.
    /// @dev    Public so DVT/SDK can reproduce it without re-deriving the layout.
    function reputationMessageHash(
        uint256 proposalId,
        address[] calldata users,
        uint256[] calldata newScores,
        uint256 epoch
    ) external view returns (bytes32) {
        return _reputationMessageHash(proposalId, users, newScores, epoch);
    }

    function _reputationMessageHash(
        uint256 proposalId,
        address[] calldata users,
        uint256[] calldata newScores,
        uint256 epoch
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(domainSeparator(), TAG_REPUTATION, proposalId, users, newScores, epoch)
        );
    }

    function _checkSignatures(
        bytes calldata proof,
        bytes32 expectedMessageHash,
        uint256 requiredThreshold
    ) internal view {
        // P0-1: proof = abi.encode(uint256 signerMask, bytes sigG2). pkG1 and
        // msgG2 are NEVER read from the proof — they're reconstructed/derived
        // on-chain so a forged proof cannot satisfy the pairing.
        (uint256 signerMask, bytes memory sigG2Bytes) = abi.decode(proof, (uint256, bytes));

        // Absolute floor for ALL paths. The generic executeProposal path enforces
        // the stricter `minThreshold` before it reaches here (see executeProposal),
        // so this hard floor lets the slash path verify a 2-of-3 WARNING without
        // widening the generic path's 3-of-N minimum.
        if (requiredThreshold < SLASH_THRESHOLD_FLOOR) revert InvalidParameter("Threshold below minimum");
        if (requiredThreshold > MAX_VALIDATORS) revert InvalidParameter("Threshold exceeds max");

        (BLS.G1Point memory pkAgg, uint256 count) = _reconstructPkAgg(signerMask);
        if (count < requiredThreshold) revert InvalidSignatureCount(count, requiredThreshold);

        BLS.G2Point memory sig = abi.decode(sigG2Bytes, (BLS.G2Point));
        BLS.G2Point memory msgG2 = BLS.hashToG2(abi.encodePacked(expectedMessageHash));

        BLS.G1Point[] memory g1s = new BLS.G1Point[](2);
        BLS.G2Point[] memory g2s = new BLS.G2Point[](2);
        g1s[0] = _getG1Generator();
        g2s[0] = sig;
        g1s[1] = _negateG1Point(pkAgg);
        g2s[1] = msgG2;

        if (!BLS.pairing(g1s, g2s)) revert SignatureVerificationFailed();
    }

    // @dev Negates a G1 point (for pairing check)
    function _negateG1Point(BLS.G1Point memory p) internal pure returns (BLS.G1Point memory) {
        // P - Y in BLS12-381 field
        uint256 p_hi_local = 0x1a0111ea397fe69a4b1ba7b6434bacd7;
        uint256 p_lo_local = 0x64774b84f38512bf6730d2a0f6b0f6241eabfffeb153ffffb9feffffffffaaab;

        uint256 ya = uint256(p.y_a);
        uint256 yb = uint256(p.y_b);
        if (ya == 0 && yb == 0) return p;

        unchecked {
            uint256 res_b = p_lo_local - yb;
            uint256 borrow = (yb > p_lo_local) ? 1 : 0;
            uint256 res_a = p_hi_local - ya - borrow;
            p.y_a = bytes32(res_a);
            p.y_b = bytes32(res_b);
        }
        return p;
    }

    /// @dev Returns BLS12-381 G1 generator point
    function _getG1Generator() internal pure returns (BLS.G1Point memory p) {
        p.x_a = bytes32(uint256(0x17f1d3a73197d7942695638c4fa9ac0f));
        p.x_b = bytes32(uint256(0xc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb));
        p.y_a = bytes32(uint256(0x08b3f481e3aaa0f1a09e30ed741d8ae4));
        p.y_b = bytes32(uint256(0xfcf5e095d5d00af600db18cb2c04b3edd03cc744a2888ae40caa232946c5e7e1));
    }

    /// @dev H-02: deterministic slot assignment for the permissionless path. A validator
    ///      that already has an active key keeps its slot; otherwise the lowest free slot
    ///      is returned. Reverts when the capped set is full. The caller cannot influence
    ///      which slot it gets, so it cannot squat or front-run a specific slot.
    function _assignSlot(address validator) internal view returns (uint8) {
        BLSValidatorKey storage existing = _blsKeys[validator];
        if (existing.isActive) return existing.index;
        for (uint8 s = 1; s <= MAX_VALIDATORS; s++) {
            if (validatorAtSlot[s] == address(0)) return s;
        }
        revert SlotOutOfRange(uint8(MAX_VALIDATORS + 1));
    }

    /// @dev H-02: a self-registering validator must currently hold ROLE_DVT in the
    ///      Registry with locked stake >= the role's minStake. Mirrors the per-signer
    ///      liveness check used during aggregate verification (reads staking pointer +
    ///      minStake live so governance can rotate them without redeploying).
    function _requireDVTStake(address validator, uint8 slot) internal view {
        bytes32 roleDvt = keccak256("DVT");
        if (!REGISTRY.hasRole(roleDvt, validator)) revert SlotValidatorRoleRevoked(slot, validator);
        IGTokenStaking staking = IRegistryStakingAwareBLS(address(REGISTRY)).GTOKEN_STAKING();
        if (address(staking) == address(0)) revert StakingNotConfigured();
        uint256 minStake = REGISTRY.getRoleConfig(roleDvt).minStake;
        (uint128 amount,,,, ) = staking.roleLocks(validator, roleDvt);
        if (uint256(amount) < minStake) {
            revert SlotValidatorStakeBelowMinimum(slot, validator, uint256(amount), minStake);
        }
    }

    /// @dev H-02: proof-of-possession — verify the registrant signed their OWN public key
    ///      under a PoP-specific domain, proving they hold the secret key. Without it a
    ///      permissionless registrant could submit a rogue key (pk_rogue = pk_target − Σpk_i)
    ///      and bias the reconstructed pkAgg. Same pairing form as aggregate verification:
    ///      e(G1, pop) == e(pk, H_pop(pk)), i.e. e(G1, pop) · e(-pk, H_pop(pk)) == 1.
    ///      The "..._POP_v1" domain tag keeps PoP signatures disjoint from slash-consensus
    ///      message hashes, so neither can ever be replayed as the other.
    function _verifyPoP(address validator, BLS.G1Point calldata publicKey, BLS.G2Point calldata popSignature)
        internal
        view
        returns (bool)
    {
        BLS.G2Point memory msgG2 = BLS.hashToG2(abi.encodePacked(popDigest(validator, publicKey)));
        BLS.G1Point[] memory g1s = new BLS.G1Point[](2);
        BLS.G2Point[] memory g2s = new BLS.G2Point[](2);
        g1s[0] = _getG1Generator();
        g2s[0] = popSignature;
        g1s[1] = _negateG1Point(publicKey);
        g2s[1] = msgG2;
        return BLS.pairing(g1s, g2s);
    }

    function _countSetBits(uint256 n) internal pure returns (uint256 count) {
        while (n != 0) {
            n &= (n - 1);
            count++;
        }
    }

    function _executeSlash(uint256 proposalId, address operator, uint8 level, bytes calldata proof) internal {
        ISuperPaymasterSlash.SlashLevel sLevel = ISuperPaymasterSlash.SlashLevel(level);
        // Two-step slash: the operator MUST already be flagged via SP.queueSlash in a
        // SEPARATE, earlier consensus tx — the dedicated queueSlashWithConsensus entry
        // (queueSlash IS selector-blocked on the generic executeProposal path). That
        // flag blocks the operator's withdraw() between the queue and this execute.
        // Queuing + slashing atomically here would REOPEN the front-run window (the
        // operator could drain their balance before the slash lands), regressing the
        // HIGH-1 two-step protection — so the flag stays a distinct prior step. Only
        // the fund-moving executeSlashWithBLS runs here, and it is reachable solely
        // through this per-severity threshold-checked path.
        ISuperPaymasterSlash(SUPERPAYMASTER).executeSlashWithBLS(operator, sLevel, proof);
        emit SlashExecuted(proposalId, operator, level);
    }

    // ====================================
    // Admin Functions
    // ====================================

    function setSuperPaymaster(address _sp) external onlyOwner {
        if (_sp == address(0)) revert InvalidParameter("Zero address");
        emit SuperPaymasterUpdated(SUPERPAYMASTER, _sp);
        SUPERPAYMASTER = _sp;
    }

    function setDVTValidator(address _dv) external onlyOwner {
        if (_dv == address(0)) revert InvalidParameter("Zero address");
        emit DVTValidatorUpdated(DVT_VALIDATOR, _dv);
        DVT_VALIDATOR = _dv;
    }

    /**
     * @notice Set minimum consensus threshold (global floor)
     */
    function setMinThreshold(uint256 _newThreshold) external onlyOwner {
        if (_newThreshold < 2) revert InvalidParameter("Min threshold too low");
        if (_newThreshold > MAX_VALIDATORS) revert InvalidParameter("Threshold > Max");
        // Invariant: minThreshold must not exceed defaultThreshold
        if (_newThreshold > defaultThreshold) revert InvalidParameter("minThreshold > defaultThreshold");
        emit ThresholdUpdated(minThreshold, _newThreshold);
        minThreshold = _newThreshold;
    }

    /// @notice H-02: toggle permissionless (stake + proof-of-possession) self-registration
    ///         of BLS validator keys. Default off — flip on once governance is ready to let
    ///         staked ROLE_DVT validators onboard their own keys without an owner call.
    function setPermissionlessBLSRegistration(bool enabled) external onlyOwner {
        permissionlessBLSRegistration = enabled;
        emit PermissionlessBLSRegistrationSet(enabled);
    }

    /**
     * @notice Set default threshold for legacy calls (verifyAndExecute)
     */
    function setDefaultThreshold(uint256 _newThreshold) external onlyOwner {
        if (_newThreshold < minThreshold) revert InvalidParameter("Below minThreshold");
        if (_newThreshold > MAX_VALIDATORS) revert InvalidParameter("Threshold > Max");
        emit ThresholdUpdated(defaultThreshold, _newThreshold);
        defaultThreshold = _newThreshold;
    }

    /// @notice Wire/rotate the guardian-collusion fraud-proof verifier (Protocol B
    ///         stage 2 detection layer, supplied by the DVT repo). Owner-gated.
    ///         Setting address(0) disables executeGuardianSlash (feature dormant).
    /// @dev    This is the SOLE authorization surface for an unbounded, permissionless,
    ///         100%-of-lock slash path, so CC-48 MEDIUM-1 moved it to a two-step,
    ///         delay-guarded rotation: propose -> wait VERIFIER_ROTATION_DELAY -> apply.
    ///         The delay is >= GUARDIAN_SLASH_CASE_WINDOW precisely so that a queued
    ///         case always outlives any rotation started after it; an owner can no
    ///         longer swap in an always-false verifier mid-case to let colluders time
    ///         out. `owner` should still be a multisig behind a TimelockController —
    ///         that is defence in depth, no longer the only defence.
    /// @dev    ROLE_DVT exit is now gated by requestGuardianExit + a bounded
    ///         unbonding delay. The request immediately removes the guardian from
    ///         valid signer masks; a verifier-approved queued case increments the
    ///         pending counter and Registry cannot consume the exit until all cases
    ///         resolve. Governance must wire this aggregator into Registry before
    ///         arming the verifier.
    function proposeFraudProofVerifier(address verifier) external onlyOwner {
        uint64 readyAt = uint64(block.timestamp + VERIFIER_ROTATION_DELAY);
        pendingFraudProofVerifier = verifier;
        pendingFraudProofVerifierReadyAt = readyAt;
        emit FraudProofVerifierRotationProposed(verifier, readyAt);
    }

    /// @notice Abandon an in-flight verifier rotation.
    function cancelFraudProofVerifierRotation() external onlyOwner {
        if (pendingFraudProofVerifierReadyAt == 0) revert NoPendingVerifierRotation();
        emit FraudProofVerifierRotationCancelled(pendingFraudProofVerifier);
        delete pendingFraudProofVerifier;
        delete pendingFraudProofVerifierReadyAt;
    }

    /// @notice Finalise a matured verifier rotation.
    /// @dev    Permissionless on purpose: the decision was already taken by `owner`
    ///         and has served its full delay, so anyone may push the button. Keeping
    ///         it owner-only would just hand the owner a second, unbounded veto.
    function applyFraudProofVerifier() external {
        uint64 readyAt = pendingFraudProofVerifierReadyAt;
        if (readyAt == 0) revert NoPendingVerifierRotation();
        if (block.timestamp < uint256(readyAt)) revert VerifierRotationNotReady(uint256(readyAt));
        address next = pendingFraudProofVerifier;
        delete pendingFraudProofVerifier;
        delete pendingFraudProofVerifierReadyAt;
        emit FraudProofVerifierUpdated(fraudProofVerifier, next);
        fraudProofVerifier = next;
    }

    /// @notice Start a bounded ROLE_DVT unbonding notice. A guardian with an
    ///         active request is excluded from BLS verification immediately,
    ///         giving watchers the full delay to queue a fraud proof.
    function requestGuardianExit() external {
        if (!REGISTRY.hasRole(keccak256("DVT"), msg.sender)) {
            revert SlotValidatorRoleRevoked(0, msg.sender);
        }
        if (pendingGuardianSlashCount[msg.sender] != 0) {
            revert GuardianExitBlockedBySlash(msg.sender, pendingGuardianSlashCount[msg.sender]);
        }
        if (guardianExitRequests[msg.sender].readyAt != 0) revert GuardianExitAlreadyRequested(msg.sender);
        uint64 cooldownUntil = guardianExitCooldownUntil[msg.sender];
        if (block.timestamp < uint256(cooldownUntil)) {
            revert GuardianExitCooldownActive(msg.sender, uint256(cooldownUntil));
        }
        _requireCommitteeSurvivesExit(msg.sender);
        uint64 readyAt = uint64(block.timestamp + GUARDIAN_EXIT_DELAY);
        uint64 expiresAt = uint64(uint256(readyAt) + GUARDIAN_EXIT_WINDOW);
        guardianExitRequests[msg.sender] = GuardianExitRequest(readyAt, expiresAt);
        emit GuardianExitRequested(msg.sender, readyAt, expiresAt);
    }

    /// @notice Withdraw an exit notice and re-enter the signer set.
    /// @dev    CC-48 BLOCKER-1 / MEDIUM-5. Two changes over the original: an accused
    ///         guardian (pending case) may no longer cancel back into the signing set,
    ///         and every cancel arms a GUARDIAN_EXIT_COOLDOWN quiet period before a new
    ///         notice may be filed, so request/cancel cannot be cycled. This is also the
    ///         supported way to clear an EXPIRED notice: the record survives expiry (and
    ///         keeps excluding the slot), and cancelling is what puts the guardian back.
    function cancelGuardianExit() external {
        if (guardianExitRequests[msg.sender].readyAt == 0) revert GuardianExitNotRequested(msg.sender);
        uint256 pending = pendingGuardianSlashCount[msg.sender];
        if (pending != 0) revert GuardianExitBlockedBySlash(msg.sender, pending);
        delete guardianExitRequests[msg.sender];
        uint64 cooldownUntil = uint64(block.timestamp + GUARDIAN_EXIT_COOLDOWN);
        guardianExitCooldownUntil[msg.sender] = cooldownUntil;
        emit GuardianExitCancelled(msg.sender, cooldownUntil);
    }

    /// @notice Highest signer count any BLS-gated path can demand right now.
    /// @dev    Reputation/blacklist proposals clear `defaultThreshold`; slash proposals
    ///         clear the per-severity `slashThresholds`. The committee floor has to
    ///         respect whichever is largest, otherwise exits could quietly strand the
    ///         severity with the strictest quorum.
    function _maxRequiredThreshold() internal view returns (uint256 required) {
        required = defaultThreshold;
        for (uint8 lvl = 0; lvl <= uint8(ISuperPaymasterSlash.SlashLevel.MAJOR); ) {
            uint256 t = uint256(slashThresholds[lvl]);
            if (t > required) required = t;
            unchecked { ++lvl; }
        }
    }

    /// @notice Count the guardians that would still be able to sign once every
    ///         outstanding exit notice (including `leaving`'s) has matured.
    /// @dev    CC-48 MEDIUM-2 / BLOCKER-1 (second half). Guardians that merely
    ///         ANNOUNCED an exit are excluded here even before `readyAt`, because the
    ///         floor has to hold at the end state, not just today. Stake is not
    ///         re-read: `_reconstructPkAgg` already enforces minStake at verification
    ///         time, and pulling every lock here would make a routine notice cost a
    ///         full committee sweep of external staking reads.
    ///
    ///         Consequence, stated plainly: with N eligible guardians and a required
    ///         threshold of N, NO guardian can open an exit notice until governance
    ///         seats a replacement or lowers the threshold. That is deliberate — the
    ///         alternative is letting one member unilaterally park the committee below
    ///         quorum. Deployments running N == threshold (the RepCredit 3-of-3
    ///         evidence stack) must seat a spare before any operator can leave.
    ///
    ///         The check only fires when THIS exit is what breaks quorum. If the
    ///         committee is already short of the threshold, the BLS paths are dead
    ///         anyway and holding guardians hostage buys nothing — so exits stay open
    ///         and the fix is governance's (raise the set, or lower the threshold).
    function _requireCommitteeSurvivesExit(address leaving) internal view {
        // A guardian with no active BLS key is not part of any signer mask, so its
        // departure cannot move the committee below quorum — nothing to check.
        if (!_blsKeys[leaving].isActive) return;
        bytes32 roleDvt = keccak256("DVT");
        uint256 remaining;
        bool leavingEligible;
        for (uint8 slot = 1; slot <= MAX_VALIDATORS; ) {
            address v = validatorAtSlot[slot];
            unchecked { ++slot; }
            if (v == address(0)) continue;
            if (!_blsKeys[v].isActive) continue;
            // Guardians that merely ANNOUNCED an exit are excluded even before
            // readyAt: the floor has to hold at the end state, not just today.
            if (v != leaving && guardianExitRequests[v].readyAt != 0) continue;
            if (!REGISTRY.hasRole(roleDvt, v)) continue;
            if (v == leaving) { leavingEligible = true; continue; }
            unchecked { ++remaining; }
        }
        uint256 required = _maxRequiredThreshold();
        if (!leavingEligible) return;
        if (remaining + 1 < required) return; // already below quorum without this exit
        if (remaining < required) revert GuardianExitWouldBreakQuorum(remaining, required);
    }

    /// @notice Registry-only atomic gate called by Registry.exitRole(ROLE_DVT).
    function consumeGuardianExit(address guardian) external {
        if (msg.sender != address(REGISTRY)) revert NotRegistry(msg.sender);
        GuardianExitRequest memory request = guardianExitRequests[guardian];
        if (request.readyAt == 0) revert GuardianExitNotRequested(guardian);
        if (pendingGuardianSlashCount[guardian] != 0) {
            revert GuardianExitBlockedBySlash(guardian, pendingGuardianSlashCount[guardian]);
        }
        if (block.timestamp < request.readyAt) revert GuardianExitNotReady(guardian, request.readyAt);
        if (block.timestamp > request.expiresAt) revert GuardianExitRequestExpired(guardian, request.expiresAt);
        delete guardianExitRequests[guardian];
        emit GuardianExitConsumed(guardian);
    }

    /// @notice Queue a verifier-approved guardian slash and freeze ROLE_DVT exits.
    /// @dev The full proof is checked before any freeze is installed, so arbitrary
    ///      callers cannot lock honest guardians. A bounded two-day window prevents
    ///      an abandoned case from becoming a permanent withdrawal denial.
    function queueGuardianSlash(
        uint256 fraudProofId,
        address[] calldata guiltyGuardians,
        bytes calldata fraudProof
    ) external nonReentrant {
        address verifier = fraudProofVerifier;
        if (verifier == address(0)) revert FraudProofVerifierNotSet();
        // A snapshot is only meaningful if it points at code; an EOA verifier would pin
        // the case to something that can never verify (and `.verify` on an EOA returns
        // empty data, which would decode as false anyway).
        if (verifier.code.length == 0) revert VerifierNotContract(verifier);
        if (fraudProofId == 0) revert InvalidProposalId();
        GuardianSlashCase storage slashCase = guardianSlashCases[fraudProofId];
        if (slashCase.status != 0) revert GuardianSlashCaseAlreadyOpened(fraudProofId);
        bytes32 guardiansHash = _validateGuardianSet(guiltyGuardians);
        if (
            !IFraudProofVerifier(verifier).verify(
                fraudProofDigest(fraudProofId, guiltyGuardians), fraudProofId, guiltyGuardians, fraudProof
            )
        ) {
            revert InvalidFraudProof(fraudProofId);
        }

        uint64 deadline = uint64(block.timestamp + GUARDIAN_SLASH_CASE_WINDOW);
        slashCase.guardiansHash = guardiansHash;
        slashCase.deadline = deadline;
        slashCase.status = 1;
        slashCase.guardianCount = uint16(guiltyGuardians.length);
        // CC-48 round-3 HIGH-1: pin the verifier that authorized this case. Every later
        // execute/retry re-verifies against THIS address, so a verifier rotation — even
        // one that was proposed months earlier, matured, and is applied one block after
        // the queue — cannot retroactively invalidate a case that is already open.
        slashCase.verifier = verifier;
        for (uint256 i = 0; i < guiltyGuardians.length; ) {
            pendingGuardianSlashCount[guiltyGuardians[i]] += 1;
            unchecked { ++i; }
        }
        emit GuardianSlashQueued(fraudProofId, guardiansHash, deadline);
        emit GuardianSlashVerifierPinned(fraudProofId, verifier);
    }

    /// @notice Release an unexecuted case after its bounded pending window.
    function expireGuardianSlashCase(uint256 fraudProofId, address[] calldata guiltyGuardians)
        external
        nonReentrant
    {
        GuardianSlashCase storage slashCase = guardianSlashCases[fraudProofId];
        if (slashCase.status != 1) revert GuardianSlashCaseNotPending(fraudProofId);
        if (block.timestamp <= slashCase.deadline) {
            revert GuardianSlashCaseNotExpired(fraudProofId, slashCase.deadline);
        }
        if (_validateGuardianSet(guiltyGuardians) != slashCase.guardiansHash) {
            revert GuardianSetMismatch(fraudProofId);
        }
        slashCase.status = 3;
        // CC-48 HIGH-2: guardians already released by a successful (or no-op) partial
        // execution must not be decremented twice — expiry only frees the stragglers.
        for (uint256 i = 0; i < guiltyGuardians.length; ) {
            address guardian = guiltyGuardians[i];
            if (!guardianCaseResolved[fraudProofId][guardian]) {
                guardianCaseResolved[fraudProofId][guardian] = true;
                pendingGuardianSlashCount[guardian] -= 1;
            }
            unchecked { ++i; }
        }
        emit GuardianSlashCaseExpired(fraudProofId);
    }

    /// @notice Slash the FULL ROLE_DVT stake of guardians proven (by the external
    ///         fraud-proof verifier) to have co-signed a fraudulent proposal. This
    ///         is the thin SP execution entry for the paper's ρ·S_op collusion
    ///         deterrent (Protocol B stage 1). It complements _executeSlash, which
    ///         targets the operator's aPNTs — a DIFFERENT asset (guardian ROLE_DVT
    ///         stake ≠ operator aPNTs, even if the addresses coincide).
    ///
    /// @dev    - Guardians are addressed DIRECTLY, not via slot: validatorAtSlot is
    ///           reassignable (revokeBLSPublicKey frees a slot for reuse), so a slot
    ///           captured at fraud time could later resolve to an innocent validator
    ///           — slashing by slot would hit the wrong address. The verifier binds
    ///           the proof to stable addresses; the slash reads the accused's own
    ///           ROLE_DVT lock. This blocks the revoke-KEY/slot variant (a slashed
    ///           address's lock is independent of whether it still holds a slot).
    ///           Registry.exitRole(ROLE_DVT) calls consumeGuardianExit. A guardian
    ///           must first publish a bounded exit notice and is immediately excluded
    ///           from BLS signer masks; any queued slash case freezes consumption.
    ///           GuardianSlashSkipped remains for legacy/direct staking drift, but
    ///           the coordinated Registry path cannot release a queued guardian.
    ///         - Permissionless CALL, gated by the verifier: fraud validity — not
    ///           caller identity — authorizes the slash. This deliberately bypasses
    ///           the accused DVT quorum, which is the collusion set and would never
    ///           slash itself (the circular-dependency escape).
    ///         - FULL-lock slash → lock hits 0 < minStake → _reconstructPkAgg
    ///           auto-ejects the guardian on the next verify. No 30% cap: proven
    ///           collusion must lose eligibility, not merely pay a fee — but this
    ///           holds for a guardian whose case is queued inside the configured
    ///           exit-notice window. The operator-path cap protects honest operators
    ///           from one bad epoch — a different threat model.
    ///         - fail-closed: reverts until a verifier is wired.
    /// @param  fraudProofId    Unique id of the fraud proof (own id-space; replay-guarded).
    /// @param  guiltyGuardians Addresses proven to have colluded (bound by the verifier).
    /// @param  fraudProof      Opaque proof bytes interpreted solely by the verifier.
    function executeGuardianSlash(
        uint256 fraudProofId,
        address[] calldata guiltyGuardians,
        bytes calldata fraudProof
    ) external nonReentrant {
        // All fail-closed shape checks up front (fail-fast, before any external call).
        if (guiltyGuardians.length == 0) revert EmptyGuiltyGuardians();
        if (guiltyGuardians.length > MAX_VALIDATORS) revert InvalidParameter("guiltyGuardians");
        GuardianSlashCase storage slashCase = guardianSlashCases[fraudProofId];
        if (slashCase.status != 1) revert GuardianSlashCaseNotPending(fraudProofId);
        // CC-48 round-3 HIGH-1: the verifier is the one PINNED at queue time, NOT the
        // live `fraudProofVerifier`. Reading the live value made the case's fate depend
        // on whoever pressed `applyFraudProofVerifier` — permissionless, and satisfiable
        // by a rotation that had been sitting matured-but-unapplied since before the case
        // existed. `VERIFIER_ROTATION_DELAY` bounds propose->apply; nothing bounds
        // matured->apply, so the delay alone never gave the property it claimed.
        address verifier = slashCase.verifier;
        if (verifier == address(0)) revert FraudProofVerifierNotSet();
        // Fail CLOSED, and do NOT silently substitute the current verifier: if the pinned
        // one is gone the case must expire, not be re-judged by a different authority.
        if (verifier.code.length == 0) revert GuardianSlashVerifierGone(fraudProofId, verifier);
        if (block.timestamp > slashCase.deadline) {
            revert GuardianSlashCaseExpiredError(fraudProofId, slashCase.deadline);
        }
        if (_validateGuardianSet(guiltyGuardians) != slashCase.guardiansHash) {
            revert GuardianSetMismatch(fraudProofId);
        }
        IGTokenStaking staking = IRegistryStakingAwareBLS(address(REGISTRY)).GTOKEN_STAKING();
        if (address(staking) == address(0)) revert StakingNotConfigured();

        // Verify once (view): the verifier authorizes this (proof, guardians) set.
        // Consumption is tracked per guardian below, NOT by a single global id here —
        // so an already-exited co-signer can never burn the proof for the others.
        if (
            !IFraudProofVerifier(verifier).verify(
                fraudProofDigest(fraudProofId, guiltyGuardians), fraudProofId, guiltyGuardians, fraudProof
            )
        ) {
            revert InvalidFraudProof(fraudProofId);
        }

        bytes32 roleDvt = keccak256("DVT");

        // CC-48 HIGH-2: advance guardian-by-guardian. Pre-fix this loop marked the
        // whole case executed up front and let any single `slashByDVT` revert take the
        // entire transaction down; if that condition (staking paused, authorization
        // rotated, an odd lock state) simply outlasted the deadline, expiry then
        // released EVERY accused guardian at once. Now each guardian is settled on its
        // own: successes are banked, failures leave that guardian frozen and the case
        // pending, and the caller can retry until the deadline.
        uint256 released;
        for (uint256 i = 0; i < guiltyGuardians.length; ) {
            address guardian = guiltyGuardians[i];
            unchecked { ++i; }
            if (guardianCaseResolved[fraudProofId][guardian]) continue;

            (uint128 amount,,,, ) = staking.roleLocks(guardian, roleDvt);
            if (amount == 0) {
                // Exited / already-ejected: nothing left to take. Settle it so the
                // still-staked colluders are not held hostage by this entry.
                guardianCaseResolved[fraudProofId][guardian] = true;
                pendingGuardianSlashCount[guardian] -= 1;
                unchecked { ++released; }
                emit GuardianSlashSkipped(fraudProofId, guardian);
                continue;
            }

            // Effects deliberately AFTER the call here: `nonReentrant` already blocks
            // re-entry into this contract's guarded entry points, and leaving
            // `pendingGuardianSlashCount` untouched for the duration of the external
            // call keeps Registry.exitRole -> consumeGuardianExit closed against a
            // guardian that tries to walk out from inside its own slash.
            try IGTokenStakingSlash(address(staking)).slashByDVT(
                guardian, roleDvt, uint256(amount), "DVT collusion"
            ) {
                guardianSlashed[fraudProofId][guardian] = true;
                guardianCaseResolved[fraudProofId][guardian] = true;
                pendingGuardianSlashCount[guardian] -= 1;
                unchecked { ++released; }
                emit GuardianSlashed(fraudProofId, guardian, uint256(amount));
            } catch {
                // Stays unresolved and stays frozen — retryable until the deadline.
                emit GuardianSlashFailed(fraudProofId, guardian);
            }
        }

        if (released != 0) {
            uint16 resolved = slashCase.resolvedCount + uint16(released);
            slashCase.resolvedCount = resolved;
            if (resolved == slashCase.guardianCount) {
                slashCase.status = 2;
                emit GuardianSlashCaseResolved(fraudProofId);
            }
        }
    }

    function _validateGuardianSet(address[] calldata guiltyGuardians) internal pure returns (bytes32) {
        if (guiltyGuardians.length == 0) revert EmptyGuiltyGuardians();
        if (guiltyGuardians.length > MAX_VALIDATORS) revert InvalidParameter("guiltyGuardians");
        for (uint256 i = 0; i < guiltyGuardians.length; ) {
            if (guiltyGuardians[i] == address(0)) revert InvalidTarget(address(0));
            for (uint256 j = 0; j < i; ) {
                if (guiltyGuardians[j] == guiltyGuardians[i]) revert InvalidParameter("dup guardian");
                unchecked { ++j; }
            }
            unchecked { ++i; }
        }
        return keccak256(abi.encode(guiltyGuardians));
    }
}
