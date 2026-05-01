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
    error OnlyBLSAggregator();
    /// @notice Reverted when an action references a proposalId that has not been
    ///         created via createProposal. Defense against pre-poison attacks
    ///         where an adversary tricks the BLS aggregator path into marking
    ///         an unborn proposalId as executed.
    error ProposalDoesNotExist();
    error NotAuthorizedExecutor();

    constructor(address _registry) Ownable(msg.sender) {
        REGISTRY = IRegistry(_registry);
    }

    function version() external pure override returns (string memory) {
        return "DVTValidator-0.4.0";
    }

    /// @notice Restrict to BLS aggregator or registered DVT validators (P0-4)
    modifier onlyAuthorizedExecutor() {
        if (msg.sender != BLS_AGGREGATOR && !isValidator[msg.sender]) {
            revert NotAuthorizedExecutor();
        }
        _;
    }

    function addValidator(address _v) external onlyOwner {
        isValidator[_v] = true;
    }

    /// @dev Proposal creation is gated by isValidator[msg.sender]. isValidator is
    ///      managed by addValidator (onlyOwner). For complete security, P0-2 fix
    ///      (addValidator requires Registry role + GTokenStaking stake check) must
    ///      also be deployed — without P0-2, owner can add zero-stake validators.
    function createProposal(address operator, uint8 level, string calldata reason) external returns (uint256 id) {
        if (!isValidator[msg.sender]) revert NotValidator();
        id = nextProposalId++;
        SlashProposal storage p = proposals[id];
        p.operator = operator;
        p.slashLevel = level;
        p.reason = reason;
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
        if (p.operator == address(0)) revert ProposalDoesNotExist();
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
        SlashProposal storage p = proposals[id];
        // P0-17: reject ids that were never created. An unborn id has
        // operator == address(0) and would otherwise be silently forwarded to
        // the aggregator with bogus operator, slashLevel and reason fields.
        if (p.operator == address(0)) revert ProposalDoesNotExist();
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
