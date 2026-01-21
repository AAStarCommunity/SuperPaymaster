// SPDX-License-Identifier: MIT
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;
import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "src/interfaces/v3/IRegistry.sol";
import "src/interfaces/v3/IBLSAggregator.sol";
import "src/interfaces/IVersioned.sol";

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

    error NotValidator();
    error AlreadySigned();
    error ProposalExecutedAlready();

    constructor(address _registry) Ownable(msg.sender) {
        REGISTRY = IRegistry(_registry);
    }

    function version() external pure override returns (string memory) {
        return "DVTValidator-0.3.2";
    }

    function addValidator(address _v) external onlyOwner {
        isValidator[_v] = true;
    }

    function createProposal(address operator, uint8 level, string calldata reason) external returns (uint256 id) {
        if (!isValidator[msg.sender]) revert NotValidator();
        id = nextProposalId++;
        SlashProposal storage p = proposals[id];
        p.operator = operator;
        p.slashLevel = level;
        p.reason = reason;
        emit ProposalCreated(id, operator, level);
    }

    /**
     * @notice Mark proposal as executed (called by BLSAggregator after successful execution)
     * @dev This is called after BLS proof verification succeeds
     */
    function markProposalExecuted(uint256 id) external {
        require(msg.sender == BLS_AGGREGATOR, "Only BLS Aggregator");
        proposals[id].executed = true;
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
    ) external {
        SlashProposal storage p = proposals[id];
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
}
