// SPDX-License-Identifier: MIT
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;
import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "../../interfaces/v3/IRegistry.sol";
import "src/interfaces/IVersioned.sol";
import { BLS } from "../../utils/BLS.sol";

interface ISuperPaymasterSlash {
    enum SlashLevel { WARNING, MINOR, MAJOR }
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

    uint256 public minThreshold = 3;    // Global minimum (safety floor)
    uint256 public defaultThreshold = 7; // Default for legacy calls
    uint256 public constant MAX_VALIDATORS = 13;

    function version() external pure override returns (string memory) {
        return "BLSAggregator-4.0.0";
    }


    // ====================================
    // Events
    // ====================================
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    event BLSPublicKeyRegistered(address indexed validator, uint8 indexed slot);
    event BLSPublicKeyRevoked(address indexed validator, uint8 indexed slot);
    event SignatureAggregated(uint256 indexed proposalId, bytes aggregatedSignature, uint256 count);
    event SlashExecuted(uint256 indexed proposalId, address indexed operator, uint8 level);
    event ReputationEpochTriggered(uint256 epoch, uint256 userCount);
    event BLSVerificationStatus(uint256 indexed proposalId, bool success);
    event ProposalExecuted(uint256 indexed proposalId, address indexed target, bytes32 callDataHash);

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
    /// @notice signerMask references a slot whose validator key is not registered/active.
    error UnknownValidatorSlot(uint8 slot);
    /// @notice signerMask references a slot index outside [1..MAX_VALIDATORS].
    error SlotOutOfRange(uint8 slot);
    /// @notice The provided slot is already bound to another validator.
    error SlotAlreadyTaken(uint8 slot);
    /// @notice signerMask is zero (no signers selected).
    error EmptySignerMask();

    // ====================================
    // Constructor
    // ====================================

    constructor(
        address _registry,
        address _superPaymaster,
        address _dvtValidator
    ) Ownable(msg.sender) {
        if (_registry == address(0)) revert InvalidAddress(address(0));
        REGISTRY = IRegistry(_registry);
        SUPERPAYMASTER = _superPaymaster;
        DVT_VALIDATOR = _dvtValidator;
    }

    // ====================================
    // Core Functions
    // ====================================

    /// @notice Register a BLS validator's public key into a deterministic slot.
    /// @dev    P0-1: keys are stored uncompressed so `_reconstructPkAgg` can
    ///         feed them straight into the G1ADD precompile. The slot encodes
    ///         the validator's bit position in `signerMask` and is fixed at
    ///         registration to make the bitmap → key mapping unambiguous.
    /// @param  validator  validator address (used for events / dedup).
    /// @param  publicKey  uncompressed EIP-2537 G1 point (4×32 bytes).
    /// @param  slot       1-indexed slot in [1..MAX_VALIDATORS]. Must not collide
    ///                    with another validator's already-bound slot.
    function registerBLSPublicKey(
        address validator,
        BLS.G1Point calldata publicKey,
        uint8 slot
    ) external onlyOwner {
        if (validator == address(0)) revert InvalidAddress(address(0));
        if (slot == 0 || slot > MAX_VALIDATORS) revert SlotOutOfRange(slot);

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

    /// @notice Revoke a previously registered BLS validator key. Idempotent.
    function revokeBLSPublicKey(address validator) external onlyOwner {
        BLSValidatorKey storage existing = _blsKeys[validator];
        if (!existing.isActive) return;
        uint8 slot = existing.index;
        delete _blsKeys[validator];
        delete validatorAtSlot[slot];
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

    function verifyAndExecute(
        uint256 proposalId,
        address operator,
        uint8 slashLevel,
        address[] calldata repUsers,
        uint256[] calldata newScores,
        uint256 epoch,
        bytes calldata proof
    ) external nonReentrant {
        if (msg.sender != DVT_VALIDATOR && msg.sender != owner()) {
            revert UnauthorizedCaller(msg.sender);
        }
        if (proposalId == 0) revert InvalidProposalId();
        if (executedProposals[proposalId]) {
            revert ProposalAlreadyExecuted(proposalId);
        }

        // 1. Construct expected message binding to specific action.
        // The signed message MUST commit to chainid to prevent cross-chain replay.
        bytes32 expectedMessageHash = keccak256(abi.encode(
            proposalId,
            operator,
            slashLevel,
            repUsers,
            newScores,
            epoch,
            block.chainid
        ));

        // 2. Verify BLS pairing using on-chain reconstructed pkAgg (P0-1).
        _checkSignatures(proof, expectedMessageHash, defaultThreshold);

        // 3. Update Global Reputation in Registry
        if (repUsers.length > 0) {
            REGISTRY.batchUpdateGlobalReputation(proposalId, repUsers, newScores, epoch, proof);
            emit ReputationEpochTriggered(epoch, repUsers.length);
        } else {
            // Slash-only proposal: mark proposalId in Registry to prevent cross-path replay
            // (attacker holding valid proof cannot reuse proposalId via direct Registry call)
            REGISTRY.markProposalExecuted(proposalId);
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

    /// @dev Reconstruct the aggregate public key from `signerMask` by accumulating
    ///      every selected validator's stored G1 point with the EIP-2537 G1ADD
    ///      precompile. Reverts if any selected slot is empty/inactive — this is
    ///      the gate that closes P0-1: the caller cannot inject an unrelated
    ///      pkAgg, every contributing key is read straight from on-chain state.
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

        bool initialized = false;
        for (uint8 slot = 1; slot <= MAX_VALIDATORS; slot++) {
            if ((signerMask >> uint256(slot - 1)) & 1 == 0) continue;

            address v = validatorAtSlot[slot];
            if (v == address(0)) revert UnknownValidatorSlot(slot);
            BLSValidatorKey storage k = _blsKeys[v];
            if (!k.isActive) revert UnknownValidatorSlot(slot);

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

        if (requiredThreshold < minThreshold) revert InvalidParameter("Threshold below minimum");
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

    function _countSetBits(uint256 n) internal pure returns (uint256 count) {
        while (n != 0) {
            n &= (n - 1);
            count++;
        }
    }

    function _executeSlash(uint256 proposalId, address operator, uint8 level, bytes calldata proof) internal {
        ISuperPaymasterSlash.SlashLevel sLevel = ISuperPaymasterSlash.SlashLevel(level);
        ISuperPaymasterSlash(SUPERPAYMASTER).executeSlashWithBLS(operator, sLevel, proof);
        emit SlashExecuted(proposalId, operator, level);
    }

    // ====================================
    // Admin Functions
    // ====================================

    function setSuperPaymaster(address _sp) external onlyOwner { SUPERPAYMASTER = _sp; }
    function setDVTValidator(address _dv) external onlyOwner { DVT_VALIDATOR = _dv; }

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
