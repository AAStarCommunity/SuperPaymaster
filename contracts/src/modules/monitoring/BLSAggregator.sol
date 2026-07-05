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

    function version() external pure override returns (string memory) {
        return "BLSAggregator-4.1.0";
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
    event SignatureAggregated(uint256 indexed proposalId, bytes aggregatedSignature, uint256 count);
    event SlashExecuted(uint256 indexed proposalId, address indexed operator, uint8 level);
    event ReputationEpochTriggered(uint256 epoch, uint256 userCount);
    event BLSVerificationStatus(uint256 indexed proposalId, bool success);
    event ProposalExecuted(uint256 indexed proposalId, address indexed target, bytes32 callDataHash);
    /// @notice Emitted when the SuperPaymaster address is updated by the owner.
    event SuperPaymasterUpdated(address indexed oldAddr, address indexed newAddr);
    /// @notice Emitted when the DVTValidator address is updated by the owner.
    event DVTValidatorUpdated(address indexed oldAddr, address indexed newAddr);

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
    ///                    their own public key. Ignored on the owner path; REQUIRED and
    ///                    verified on the permissionless self-registration path.
    ///
    /// @dev    SECURITY / TRUST ASSUMPTION — owner path deliberately skips PoP.
    ///         There are exactly two registration paths and only ONE of them omits the
    ///         proof-of-possession check:
    ///           • Owner path (`msg.sender == owner()`): PoP is NOT verified. This is
    ///             intentional and safe under the protocol trust model. `owner` is the
    ///             trusted bootstrap authority (deployer → DAO / governance multisig /
    ///             timelock) that curates the known-good validator set during onboarding
    ///             and vets each key's proof-of-possession OFF-CHAIN before calling. A
    ///             compromised owner is already game-over for BLS consensus by design —
    ///             it can register/revoke ANY key at ANY slot, move `setSuperPaymaster`,
    ///             `setDVTValidator`, and the thresholds — so skipping PoP grants it NO
    ///             extra power it doesn't already hold. The rogue-key attack
    ///             (`Pm = xG − Σ pk_honest`) is therefore NOT reachable by an untrusted
    ///             party through this path: an attacker cannot satisfy the `owner()` gate.
    ///           • Permissionless path (`permissionlessBLSRegistration == true`, off by
    ///             default): an untrusted staked ROLE_DVT validator self-registers its OWN
    ///             key, and PoP IS enforced here precisely because the caller is untrusted.
    ///         Defense-in-depth: even a key inserted via the owner path can only contribute
    ///         to an aggregate if its validator address still holds ROLE_DVT with locked
    ///         stake >= minStake at verification time (re-checked live in
    ///         `_reconstructPkAgg`); a key registered for an address lacking the role/stake
    ///         can never enter a slash/reputation proof.
    ///         Deploy runbook: after launch, transfer ownership to the governance
    ///         multisig/timelock and onboard validators owner-side (off-chain PoP vetting)
    ///         OR flip `setPermissionlessBLSRegistration(true)` to require on-chain PoP for
    ///         self-service onboarding. See docs/architecture/dvt-validator-workflow.md.
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
        if (msg.sender != owner()) {
            if (!permissionlessBLSRegistration) revert PermissionlessRegistrationDisabled();
            if (msg.sender != validator) revert UnauthorizedCaller(msg.sender);
            _requireDVTStake(validator, slot);
            _validateG1Point(publicKey);
            if (!_verifyPoP(publicKey, popSignature)) revert InvalidPoP();
            // Permissionless callers do NOT choose their slot: the contract assigns the
            // lowest free slot deterministically (re-registration keeps the prior slot).
            // This removes the slot-squatting / front-running vector where a caller could
            // grab or deny a specific slot. (Filling the whole capped set still costs
            // minStake per identity and remains owner-revocable.)
            slot = _assignSlot(validator);
        } else {
            // Owner (trusted bootstrap authority) path: PoP is intentionally NOT verified —
            // see the SECURITY / TRUST ASSUMPTION note on this function. The owner vets each
            // key's proof-of-possession off-chain; a compromised owner already controls the
            // whole validator set, so on-chain PoP here would add no security. On-curve +
            // prime-order subgroup membership is still validated to block small-subgroup /
            // key-cancellation contamination of the reconstructed pkAgg.
            _validateG1Point(publicKey);
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
            keccak256("QUEUE_SLASH"), operator, slashLevel, epoch, block.chainid
        ));
        _checkSignatures(proof, expectedMessageHash, requiredThreshold);
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
                proposalId, operator, slashLevel, repUsers, newScores, epoch, block.chainid, evidenceHash
            ));
        } else {
            // Reputation (or combined) path: unchanged 7-field encoding +
            // defaultThreshold, so Registry.batchUpdateGlobalReputation's
            // re-verification reconstructs the identical hash.
            requiredThreshold = defaultThreshold;
            expectedMessageHash = keccak256(abi.encode(
                proposalId, operator, slashLevel, repUsers, newScores, epoch, block.chainid
            ));
        }

        // 2. Verify BLS pairing using on-chain reconstructed pkAgg (P0-1).
        _checkSignatures(proof, expectedMessageHash, requiredThreshold);

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
            proposalId,
            target,
            keccak256(callData),
            requiredThreshold,
            block.chainid
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
    function _verifyPoP(BLS.G1Point calldata publicKey, BLS.G2Point calldata popSignature)
        internal
        view
        returns (bool)
    {
        BLS.G2Point memory msgG2 = BLS.hashToG2(
            abi.encodePacked(
                "BLS12381G1_XMD:SHA-256_POP_v1:",
                publicKey.x_a, publicKey.x_b, publicKey.y_a, publicKey.y_b
            )
        );
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
        // SEPARATE, earlier consensus tx (the generic executeProposal queueSlash path,
        // which is intentionally NOT selector-blocked — see executeProposal). That
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
}
