// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import "../../interfaces/v3/IRegistry.sol";
import "src/interfaces/IVersioned.sol";
import "forge-std/console.sol";
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
        return "BLSAggregator-3.1.4";
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
        
        // ✅ 1. Construct expected message binding to specific action
        // This ensures the BLS signature actually authorizes THIS specific proposal/slash
        bytes32 expectedMessageHash = keccak256(abi.encode(
            proposalId,
            operator,
            slashLevel,
            repUsers,
            newScores,
            epoch,
            block.chainid  // Prevent cross-chain replay
        ));
        
        // ✅ 2. Verify BLS Signatures and message binding
        _checkSignatures(proposalId, proof, expectedMessageHash);

        // 2. Update Global Reputation in Registry
        if (repUsers.length > 0) {
            REGISTRY.batchUpdateGlobalReputation(proposalId, repUsers, newScores, epoch, proof);
            emit ReputationEpochTriggered(epoch, repUsers.length);
        }

        // 3. Execute Slash if operator is provided
        if (operator != address(0)) {
            _executeSlash(proposalId, operator, slashLevel, proof);
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


    /// @dev Compare two G2 points for equality
    function _g2Equal(BLS.G2Point memory a, BLS.G2Point memory b) internal pure returns (bool) {
        return a.x_c0_a == b.x_c0_a && a.x_c0_b == b.x_c0_b &&
               a.x_c1_a == b.x_c1_a && a.x_c1_b == b.x_c1_b &&
               a.y_c0_a == b.y_c0_a && a.y_c0_b == b.y_c0_b &&
               a.y_c1_a == b.y_c1_a && a.y_c1_b == b.y_c1_b;
    }

    function _checkSignatures(uint256 proposalId, bytes calldata proof, bytes32 expectedMessageHash) internal view {
        (bytes memory pkG1Bytes, bytes memory sigG2Bytes, bytes memory msgG2Bytes, uint256 signerMask) 
            = abi.decode(proof, (bytes, bytes, bytes, uint256));
        
        // ✅ Verify proof signs the expected message 
        // Note: Hash comparison is handled by BLS pairing (e(G1, Sig) == e(PK, msgG2))
        // where msgG2 MUST match the expectedMessageHash for binding to valid.
        // We rely on honest behavior of this function to construct valid G1/G2 points.
        // But crucially, we must ensure msgG2 IS the hash of expectedMessageHash.
        
        // However, BLSValidator logic is: verifyProof(proof, message)
        // BLSValidator checks: hashToG2(message) == providedMsgG2
        
        // Here in Aggregator, we decode msgG2 directly.
        // To be safe, we should re-derive msgG2 from expectedMessageHash and compare.
        
        BLS.G2Point memory derivedMsgG2 = BLS.hashToG2(abi.encodePacked(expectedMessageHash));
        BLS.G2Point memory providedMsgG2 = abi.decode(msgG2Bytes, (BLS.G2Point));
        
        if (!_g2Equal(derivedMsgG2, providedMsgG2)) revert SignatureVerificationFailed();
        
        uint256 count = _countSetBits(signerMask);
        if (count < threshold) revert InvalidSignatureCount(count, threshold);

        // ✅ Use BLS.pairing() instead of direct precompile call
        BLS.G1Point memory pk = abi.decode(pkG1Bytes, (BLS.G1Point));
        BLS.G2Point memory sig = abi.decode(sigG2Bytes, (BLS.G2Point));
        BLS.G2Point memory msgG2 = abi.decode(msgG2Bytes, (BLS.G2Point));
        
        // Pairing Check: e(G1_GEN, Sig) == e(PK, msgG2)
        BLS.G1Point[] memory g1s = new BLS.G1Point[](2);
        BLS.G2Point[] memory g2s = new BLS.G2Point[](2);
        
        g1s[0] = _getG1Generator();
        g2s[0] = sig;
        g1s[1] = _negateG1Point(pk);
        g2s[1] = msgG2;
        
        if (!BLS.pairing(g1s, g2s)) {
            revert SignatureVerificationFailed();
        }
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

    function _executeSlash(uint256 proposalId, address operator, uint8 level, bytes calldata proof) internal {
        ISuperPaymasterSlash.SlashLevel sLevel = ISuperPaymasterSlash.SlashLevel(level);
        // ✅ Pass full proof for audit traceability (hash will be stored in SuperPaymaster)
        ISuperPaymasterSlash(SUPERPAYMASTER).executeSlashWithBLS(operator, sLevel, proof);
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
