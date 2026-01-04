// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "../../interfaces/v3/IRegistry.sol";
import "src/interfaces/IVersioned.sol";

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
 */
contract BLSAggregator is Ownable, ReentrancyGuard, IVersioned {

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

    IRegistry public immutable REGISTRY;
    address public SUPERPAYMASTER;
    address public DVT_VALIDATOR;

    mapping(address => BLSPublicKey) public blsPublicKeys;
    mapping(uint256 => AggregatedSignature) public aggregatedSignatures;
    mapping(uint256 => bool) public executedProposals;
    mapping(uint256 => uint256) public proposalNonces;

    uint256 public threshold = 7;
    uint256 public constant MAX_VALIDATORS = 13;

    function version() external pure override returns (string memory) {
        return "BLSAggregator-3.1.3";
    }


    // ====================================
    // Events
    // ====================================
    event ThresholdUpdated(uint256 oldThreshold, uint256 newThreshold);

    event BLSPublicKeyRegistered(address indexed validator, bytes publicKey);
    event SignatureAggregated(uint256 indexed proposalId, bytes aggregatedSignature, uint256 count);
    event SlashExecuted(uint256 indexed proposalId, address indexed operator, uint8 level);
    event ReputationEpochTriggered(uint256 epoch, uint256 userCount);
    event BLSVerificationStatus(uint256 indexed proposalId, bool success);

    // ====================================
    // Constants (BLS12-381 Math)
    // ====================================
    
    bytes constant G1_X_BYTES = hex"17f1d3a73197d7942695638c4fa9ac0fc3688c4f9774b905a14e3a3f171bac586c55e83ff97a1aeffb3af00adb22c6bb";
    bytes constant G1_Y_BYTES = hex"08b3f481e3aaa9a12174adfa9d9e00912180f1482c0bcd3b0ff955a6d051029441c4a4f147cc520556770e0a5c483a27";
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

    function registerBLSPublicKey(address validator, bytes calldata publicKey) external onlyOwner {
        if (publicKey.length != 48) revert InvalidBLSKey();
        blsPublicKeys[validator] = BLSPublicKey(publicKey, true);
        emit BLSPublicKeyRegistered(validator, publicKey);
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
        if (executedProposals[proposalId] && proposalId != 0) {
            revert ProposalAlreadyExecuted(proposalId);
        }
        
        // 1. Verify BLS Signatures (pairing check)
        _checkSignatures(proposalId, proof);

        // 2. Update Global Reputation in Registry
        if (repUsers.length > 0) {
            REGISTRY.batchUpdateGlobalReputation(repUsers, newScores, epoch, proof);
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

    function _checkSignatures(uint256 proposalId, bytes calldata proof) internal view {
        (bytes memory pkG1, bytes memory sigG2, bytes memory msgG2, uint256 signerMask) = abi.decode(proof, (bytes, bytes, bytes, uint256));
        
        uint256 count = _countSetBits(signerMask);
        if (count < threshold) revert InvalidSignatureCount(count, threshold);

        // Pairing Check: e(G1, Sig) * e(-Pk, Msg) == 1
        bytes memory input = abi.encodePacked(
            G1_X_BYTES, sigG2,
            _negateG1(pkG1), msgG2
        );
        
        (bool success, bytes memory result) = address(0x11).staticcall(input);
        if (!success || abi.decode(result, (uint256)) != 1) {
            revert SignatureVerificationFailed();
        }
        // Emit success via internal logic if needed, but staticcall just returns
    }

    function _negateG1(bytes memory pkG1) internal pure returns (bytes memory) {
        bytes memory x = new bytes(48);
        bytes memory y = new bytes(48);
        for(uint i=0; i<48; i++) {
            x[i] = pkG1[i];
            y[i] = pkG1[i+48];
        }
        
        uint256 y_lo;
        uint256 y_hi;
        assembly {
            y_lo := mload(add(y, 48))
            y_hi := mload(add(y, 32))
            y_hi := shr(128, y_hi)
        }

        uint256 new_y_lo;
        uint256 new_y_hi;

        if (P_LO >= y_lo) {
            new_y_lo = P_LO - y_lo;
            new_y_hi = P_HI - y_hi;
        } else {
            new_y_lo = (type(uint256).max - y_lo + 1) + P_LO;
            new_y_hi = P_HI - y_hi - 1;
        }

        bytes memory new_y = abi.encodePacked(uint128(new_y_hi), new_y_lo);
        return abi.encodePacked(x, new_y);
    }

    function _countSetBits(uint256 n) internal pure returns (uint256 count) {
        while (n != 0) {
            n &= (n - 1);
            count++;
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

    /**
     * @notice Set min consensus threshold (e.g. 3)
     */
    function setThreshold(uint256 _newThreshold) external onlyOwner {
        if (_newThreshold < 3) revert InvalidParameter("Threshold too low");
        if (_newThreshold > MAX_VALIDATORS) revert InvalidParameter("Threshold > Max");
        emit ThresholdUpdated(threshold, _newThreshold);
        threshold = _newThreshold;
    }
}
