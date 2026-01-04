// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

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
        address[] validators;
        bytes[] signatures;
        bool executed;
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
        return "DVTValidator-0.3.1";
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

    function signProposal(uint256 id, bytes calldata signature) external {
        if (!isValidator[msg.sender]) revert NotValidator();
        SlashProposal storage p = proposals[id];
        if (p.executed) revert ProposalExecutedAlready();

        for (uint i = 0; i < p.validators.length; i++) {
            if (p.validators[i] == msg.sender) revert AlreadySigned();
        }

        p.validators.push(msg.sender);
        p.signatures.push(signature);
        emit ProposalSigned(id, msg.sender);

        if (p.validators.length >= 7) {
            _forward(id);
        }
    }

    function markProposalExecuted(uint256 id) external {
        require(msg.sender == BLS_AGGREGATOR, "Only BLS Aggregator");
        proposals[id].executed = true;
        emit ProposalExecuted(id);
    }

    function _forward(uint256 id) internal {
        // NOTE: In the new BLS-hardened V3, we expect an aggregated proof.
        // The individual signatures collection is preserved for compatibility,
        // but real execution should use executeWithProof for the final aggregated result.
    }

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
