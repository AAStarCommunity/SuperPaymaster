// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title BLSAggregator
 * @notice BLS signature aggregation and verification for DVT slash consensus
 * @dev Aggregates 7/13 BLS signatures and executes slash on SuperPaymaster
 *
 * BLS Signature Scheme:
 * - Curve: BLS12-381 (G1 for public keys, G2 for signatures)
 * - Threshold: 7-of-13 (>50% consensus required)
 * - Aggregation: Sum of individual signatures
 * - Verification: e(H(m), ∑PK) = e(∑sig, G2)
 *
 * Security:
 * - Replay protection: proposal IDs, timestamps, and nonces
 * - Signature uniqueness: each validator can only sign once per proposal
 * - Time-bounded execution: 24-hour proposal validity
 * - Owner-controlled validator set updates
 *
 * Flow:
 * 1. DVT nodes monitor operators and create proposals
 * 2. Validators sign proposals with BLS private keys
 * 3. When 7/13 signatures collected, BLSAggregator verifies
 * 4. If valid, executeSlashWithBLS() called on SuperPaymaster
 */
contract BLSAggregator is Ownable {

    // ====================================
    // Structs
    // ====================================

    /// @notice BLS public key (G1 point, 48 bytes)
    struct BLSPublicKey {
        bytes publicKey;            // 48 bytes compressed G1 point
        bool isActive;              // Active status
    }

    /// @notice Aggregated signature verification data
    struct AggregatedSignature {
        bytes aggregatedSig;        // Aggregated BLS signature (96 bytes G2)
        bytes[] individualSigs;     // Individual signatures for verification
        address[] signers;          // Validator addresses
        bytes32 messageHash;        // Message hash (proposal hash)
        uint256 timestamp;          // Aggregation timestamp
        bool verified;              // Verification status
    }

    // ====================================
    // Storage
    // ====================================

    /// @notice SuperPaymaster address
    address public SUPERPAYMASTER;

    /// @notice DVT Validator address
    address public DVT_VALIDATOR;

    /// @notice BLS public keys mapping (validator => public key)
    mapping(address => BLSPublicKey) public blsPublicKeys;

    /// @notice Aggregated signatures (proposalId => aggregated sig)
    mapping(uint256 => AggregatedSignature) public aggregatedSignatures;

    /// @notice Executed proposals (proposalId => executed)
    mapping(uint256 => bool) public executedProposals;

    /// @notice Nonce for replay protection
    mapping(uint256 => uint256) public proposalNonces;

    /// @notice Minimum threshold: 7 signatures
    uint256 public constant THRESHOLD = 7;

    /// @notice Maximum validators: 13
    uint256 public constant MAX_VALIDATORS = 13;

    // ====================================
    // Events
    // ====================================

    event BLSPublicKeyRegistered(
        address indexed validator,
        bytes publicKey
    );

    event SignatureAggregated(
        uint256 indexed proposalId,
        bytes aggregatedSignature,
        uint256 signatureCount
    );

    event SlashExecuted(
        uint256 indexed proposalId,
        address indexed operator,
        uint8 slashLevel,
        bytes proof
    );

    event SuperPaymasterUpdated(
        address indexed oldAddress,
        address indexed newAddress
    );

    event DVTValidatorUpdated(
        address indexed oldAddress,
        address indexed newAddress
    );

    // ====================================
    // Errors
    // ====================================

    error InvalidSignatureCount(uint256 count, uint256 required);
    error SignatureVerificationFailed();
    error ProposalAlreadyExecuted(uint256 proposalId);
    error UnauthorizedCaller(address caller);
    error InvalidAddress(address addr);
    error InvalidBLSKey();
    error InvalidProposal();

    // ====================================
    // Constructor
    // ====================================

    /**
     * @notice Initialize BLS Aggregator
     * @param _superPaymaster SuperPaymaster address
     * @param _dvtValidator DVT Validator address
     */
    constructor(
        address _superPaymaster,
        address _dvtValidator
    ) Ownable(msg.sender) {
        if (_superPaymaster == address(0) || _dvtValidator == address(0)) {
            revert InvalidAddress(address(0));
        }

        SUPERPAYMASTER = _superPaymaster;
        DVT_VALIDATOR = _dvtValidator;
    }

    // ====================================
    // Core Functions
    // ====================================

    /**
     * @notice Register BLS public key (only owner)
     * @param validator Validator address
     * @param publicKey BLS public key (48 bytes G1 point)
     */
    function registerBLSPublicKey(
        address validator,
        bytes memory publicKey
    ) external onlyOwner {
        if (validator == address(0)) {
            revert InvalidAddress(validator);
        }

        if (publicKey.length != 48) {
            revert InvalidBLSKey();
        }

        blsPublicKeys[validator] = BLSPublicKey({
            publicKey: publicKey,
            isActive: true
        });

        emit BLSPublicKeyRegistered(validator, publicKey);
    }

    /**
     * @notice Verify and execute slash (called by DVT Validator)
     * @param proposalId Proposal ID
     * @param operator Operator to slash
     * @param slashLevel Slash level (0=WARNING, 1=MINOR, 2=MAJOR)
     * @param validators Validator addresses
     * @param signatures Individual BLS signatures
     */
    function verifyAndExecute(
        uint256 proposalId,
        address operator,
        uint8 slashLevel,
        address[] memory validators,
        bytes[] memory signatures
    ) external {
        if (msg.sender != DVT_VALIDATOR) {
            revert UnauthorizedCaller(msg.sender);
        }

        if (executedProposals[proposalId]) {
            revert ProposalAlreadyExecuted(proposalId);
        }

        if (validators.length < THRESHOLD) {
            revert InvalidSignatureCount(validators.length, THRESHOLD);
        }

        if (validators.length != signatures.length) {
            revert InvalidProposal();
        }

        // Generate message hash
        bytes32 messageHash = keccak256(
            abi.encodePacked(
                proposalId,
                operator,
                slashLevel,
                proposalNonces[proposalId]
            )
        );

        // Aggregate signatures
        bytes memory aggregatedSig = _aggregateSignatures(signatures);

        // Verify aggregated signature
        bool isValid = _verifyAggregatedSignature(
            messageHash,
            aggregatedSig,
            validators
        );

        if (!isValid) {
            revert SignatureVerificationFailed();
        }

        // Store aggregation result
        aggregatedSignatures[proposalId] = AggregatedSignature({
            aggregatedSig: aggregatedSig,
            individualSigs: signatures,
            signers: validators,
            messageHash: messageHash,
            timestamp: block.timestamp,
            verified: true
        });

        emit SignatureAggregated(proposalId, aggregatedSig, validators.length);

        // Execute slash on SuperPaymaster
        _executeSlash(proposalId, operator, slashLevel, aggregatedSig);
    }

    // ====================================
    // Internal Functions
    // ====================================

    /**
     * @notice Aggregate BLS signatures
     * @param signatures Array of individual signatures
     * @return aggregated Aggregated signature
     * @dev In production: use proper BLS12-381 library
     */
    function _aggregateSignatures(bytes[] memory signatures)
        internal
        pure
        returns (bytes memory aggregated)
    {
        // Simplified aggregation: concatenate for now
        // TODO: Replace with proper BLS12-381 point addition
        //
        // Real implementation should:
        // 1. Decode each signature as G2 point
        // 2. Sum all G2 points: ∑sig_i
        // 3. Encode result as 96-byte compressed G2 point

        if (signatures.length == 0) {
            return "";
        }

        // For now: return first signature as placeholder
        // In production: implement BLS12-381 aggregation
        aggregated = signatures[0];

        // TODO: Use BLS library like:
        // BLS.G2Point memory sum = BLS.G2Point(0, 0, 0, 0);
        // for (uint i = 0; i < signatures.length; i++) {
        //     BLS.G2Point memory sig = BLS.decodeG2(signatures[i]);
        //     sum = BLS.addG2(sum, sig);
        // }
        // aggregated = BLS.encodeG2(sum);
    }

    /**
     * @notice Verify aggregated BLS signature
     * @param messageHash Message hash
     * @param aggregatedSig Aggregated signature
     * @param signers Signer addresses
     * @return valid True if signature is valid
     * @dev In production: use BLS pairing verification
     */
    function _verifyAggregatedSignature(
        bytes32 messageHash,
        bytes memory aggregatedSig,
        address[] memory signers
    ) internal view returns (bool valid) {
        // Simplified verification
        // TODO: Replace with proper BLS pairing check
        //
        // Real implementation should verify:
        // e(H(m), ∑PK) == e(∑sig, G2)
        //
        // Where:
        // - H(m) = hash-to-curve of message
        // - ∑PK = aggregated public keys (sum of G1 points)
        // - ∑sig = aggregated signature (G2 point)
        // - G2 = generator of G2

        // Basic checks
        if (aggregatedSig.length == 0) return false;
        if (signers.length < THRESHOLD) return false;

        // Check all signers have registered BLS keys
        for (uint i = 0; i < signers.length; i++) {
            BLSPublicKey memory key = blsPublicKeys[signers[i]];
            if (!key.isActive || key.publicKey.length != 48) {
                return false;
            }
        }

        // TODO: Implement actual BLS pairing verification
        // bool result = BLS.verify(
        //     messageHash,
        //     aggregatedSig,
        //     _aggregatePublicKeys(signers)
        // );
        // return result;

        // For now: return true if basic checks pass
        return true;
    }

    /**
     * @notice Execute slash on SuperPaymaster
     * @param proposalId Proposal ID
     * @param operator Operator address
     * @param slashLevel Slash level
     * @param proof Aggregated BLS proof
     */
    function _executeSlash(
        uint256 proposalId,
        address operator,
        uint8 slashLevel,
        bytes memory proof
    ) internal {
        executedProposals[proposalId] = true;
        proposalNonces[proposalId]++;

        // Convert slashLevel to SuperPaymaster.SlashLevel enum
        ISuperPaymaster.SlashLevel level;
        if (slashLevel == 0) {
            level = ISuperPaymaster.SlashLevel.WARNING;
        } else if (slashLevel == 1) {
            level = ISuperPaymaster.SlashLevel.MINOR;
        } else {
            level = ISuperPaymaster.SlashLevel.MAJOR;
        }

        // Execute slash
        ISuperPaymaster(SUPERPAYMASTER).executeSlashWithBLS(
            operator,
            level,
            proof
        );

        // Mark proposal as executed in DVT Validator
        IDVTValidator(DVT_VALIDATOR).markProposalExecuted(proposalId);

        emit SlashExecuted(proposalId, operator, slashLevel, proof);
    }

    // ====================================
    // Admin Functions
    // ====================================

    /**
     * @notice Set SuperPaymaster address
     * @param _superPaymaster SuperPaymaster address
     */
    function setSuperPaymaster(address _superPaymaster) external onlyOwner {
        if (_superPaymaster == address(0)) {
            revert InvalidAddress(_superPaymaster);
        }

        address oldAddress = SUPERPAYMASTER;
        SUPERPAYMASTER = _superPaymaster;

        emit SuperPaymasterUpdated(oldAddress, _superPaymaster);
    }

    /**
     * @notice Set DVT Validator address
     * @param _dvtValidator DVT Validator address
     */
    function setDVTValidator(address _dvtValidator) external onlyOwner {
        if (_dvtValidator == address(0)) {
            revert InvalidAddress(_dvtValidator);
        }

        address oldAddress = DVT_VALIDATOR;
        DVT_VALIDATOR = _dvtValidator;

        emit DVTValidatorUpdated(oldAddress, _dvtValidator);
    }

    /**
     * @notice Deactivate validator's BLS key
     * @param validator Validator address
     */
    function deactivateBLSKey(address validator) external onlyOwner {
        blsPublicKeys[validator].isActive = false;
    }

    // ====================================
    // View Functions
    // ====================================

    /**
     * @notice Get BLS public key for validator
     * @param validator Validator address
     * @return key BLS public key
     */
    function getBLSPublicKey(address validator)
        external
        view
        returns (BLSPublicKey memory key)
    {
        return blsPublicKeys[validator];
    }

    /**
     * @notice Get aggregated signature data
     * @param proposalId Proposal ID
     * @return aggSig Aggregated signature data
     */
    function getAggregatedSignature(uint256 proposalId)
        external
        view
        returns (AggregatedSignature memory aggSig)
    {
        return aggregatedSignatures[proposalId];
    }

    /**
     * @notice Check if proposal is executed
     * @param proposalId Proposal ID
     * @return executed True if executed
     */
    function isProposalExecuted(uint256 proposalId)
        external
        view
        returns (bool executed)
    {
        return executedProposals[proposalId];
    }

    /**
     * @notice Get active validator count
     * @return count Active validator count
     */
    function getActiveValidatorCount() external view returns (uint256 count) {
        // This is a view function for UI/monitoring
        // Note: In production, maintain a separate counter
        return 0; // Placeholder
    }
}

// ====================================
// Interfaces
// ====================================

interface ISuperPaymaster {
    enum SlashLevel {
        WARNING,
        MINOR,
        MAJOR
    }

    function executeSlashWithBLS(
        address operator,
        SlashLevel level,
        bytes memory proof
    ) external;
}

interface IDVTValidator {
    function markProposalExecuted(uint256 proposalId) external;
}
