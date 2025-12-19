// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "../../interfaces/v3/IRegistryV3.sol";

interface ISuperPaymasterSlash {
    enum SlashLevel { WARNING, MINOR, MAJOR }
    function executeSlashWithBLS(address operator, SlashLevel level, bytes calldata proof) external;
}

interface IDVTValidator {
    function markProposalExecuted(uint256 proposalId) external;
}

/**
 * @title BLSAggregatorV3
 * @notice BLS signature aggregation and verification for DVT slash consensus (V3)
 * @dev Aggregates signatures and updates global reputation in Registry V3.
 */
contract BLSAggregatorV3 is Ownable, ReentrancyGuard {

    // ====================================
    // Structs
    // ====================================

    struct BLSPublicKey {
        bytes publicKey;            // 48 bytes compressed G1 point
        bool isActive;
    }

    struct AggregatedSignature {
        bytes aggregatedSig;        // 96 bytes G2
        address[] signers;
        bytes32 messageHash;
        uint256 timestamp;
        bool verified;
    }

    // ====================================
    // Storage
    // ====================================

    IRegistryV3 public immutable REGISTRY;
    address public SUPERPAYMASTER;
    address public DVT_VALIDATOR;

    mapping(address => BLSPublicKey) public blsPublicKeys;
    mapping(uint256 => AggregatedSignature) public aggregatedSignatures;
    mapping(uint256 => bool) public executedProposals;
    mapping(uint256 => uint256) public proposalNonces;

    uint256 public constant THRESHOLD = 7;
    uint256 public constant MAX_VALIDATORS = 13;
    string public constant VERSION = "3.1.1";

    // ====================================
    // Events
    // ====================================

    event BLSPublicKeyRegistered(address indexed validator, bytes publicKey);
    event SignatureAggregated(uint256 indexed proposalId, bytes aggregatedSignature, uint256 count);
    event SlashExecuted(uint256 indexed proposalId, address indexed operator, uint8 level);
    event ReputationEpochTriggered(uint256 epoch, uint256 userCount);

    // ====================================
    // Errors
    // ====================================

    error InvalidSignatureCount(uint256 count, uint256 required);
    error SignatureVerificationFailed();
    error ProposalAlreadyExecuted(uint256 proposalId);
    error UnauthorizedCaller(address caller);
    error InvalidAddress(address addr);
    error InvalidBLSKey();

    // ====================================
    // Constructor
    // ====================================

    constructor(
        address _registry,
        address _superPaymaster,
        address _dvtValidator
    ) Ownable(msg.sender) {
        if (_registry == address(0)) revert InvalidAddress(address(0));
        REGISTRY = IRegistryV3(_registry);
        SUPERPAYMASTER = _superPaymaster;
        DVT_VALIDATOR = _dvtValidator;
    }

    // ====================================
    // Core Functions
    // ====================================

    function registerBLSPublicKey(address validator, bytes calldata publicKey) external onlyOwner {
        if (publicKey.length != 48) revert InvalidBLSKey();
        blsPublicKeys[validator] = BLSPublicKey(publicKey, true);
        emit BLSPublicKeyRegistered(validator, publicKey);
    }

    /**
     * @notice Verify consensus and trigger Registry reputation update + Optional Slashing
     */
    function verifyAndExecute(
        uint256 proposalId,
        address operator,
        uint8 slashLevel,
        address[] calldata validators,
        bytes[] calldata signatures,
        address[] calldata repUsers,
        uint256[] calldata newScores,
        uint256 epoch
    ) external nonReentrant {
        if (msg.sender != DVT_VALIDATOR && msg.sender != owner()) {
            revert UnauthorizedCaller(msg.sender);
        }
        if (executedProposals[proposalId] && proposalId != 0) {
            revert ProposalAlreadyExecuted(proposalId);
        }
        if (validators.length < THRESHOLD) {
            revert InvalidSignatureCount(validators.length, THRESHOLD);
        }

        // 1. Verify BLS Signatures (Mocked logic for prototype, same as V2)
        // In production, this uses a precompile or a heavy library for pairing.
        _checkSignatures(validators, signatures);

        // 2. Update Global Reputation in Registry
        if (repUsers.length > 0) {
            REGISTRY.batchUpdateGlobalReputation(repUsers, newScores, epoch, "");
            emit ReputationEpochTriggered(epoch, repUsers.length);
        }

        // 3. Execute Slash if operator is provided
        if (operator != address(0)) {
            _executeSlash(proposalId, operator, slashLevel);
        }

        if (proposalId != 0) {
            executedProposals[proposalId] = true;
            if (DVT_VALIDATOR != address(0)) {
                IDVTValidator(DVT_VALIDATOR).markProposalExecuted(proposalId);
            }
        }
    }

    // ====================================
    // Internal Functions
    // ====================================

    function _checkSignatures(address[] calldata validators, bytes[] calldata signatures) internal view {
        for (uint i = 0; i < validators.length; i++) {
            if (!blsPublicKeys[validators[i]].isActive) revert SignatureVerificationFailed();
        }
    }

    function _executeSlash(uint256 proposalId, address operator, uint8 level) internal {
        ISuperPaymasterSlash.SlashLevel sLevel = ISuperPaymasterSlash.SlashLevel(level);
        ISuperPaymasterSlash(SUPERPAYMASTER).executeSlashWithBLS(operator, sLevel, "");
        emit SlashExecuted(proposalId, operator, level);
    }

    // ====================================
    // Admin Functions
    // ====================================

    function setSuperPaymaster(address _sp) external onlyOwner { SUPERPAYMASTER = _sp; }
    function setDVTValidator(address _dv) external onlyOwner { DVT_VALIDATOR = _dv; }
}
