// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "../interfaces/Interfaces.sol";

/**
 * @title DVTValidator
 * @notice Distributed Validator Technology for operator monitoring
 * @dev 13 independent validators monitor operator health and generate slash proposals
 *
 * Architecture:
 * - 13 DVT Nodes (off-chain monitoring services)
 * - On-chain validator registration and proposal management
 * - Slash proposal creation when operators violate thresholds
 * - BLSAggregator collects 7/13 signatures for execution
 *
 * Monitoring Rules:
 * 1. Low aPNTs Balance: balance < minThreshold (100 aPNTs)
 * 2. Consecutive Failures: > 10 failed transactions
 * 3. Inactivity: no transactions for 7+ days
 *
 * Slash Levels:
 * - WARNING: First violation, reputation -10
 * - MINOR: Second violation, 5% stake slash, reputation -20
 * - MAJOR: Third violation, 10% stake slash, pause operator, reputation -50
 */
contract DVTValidator is Ownable {

    // ====================================
    // Structs
    // ====================================

    /// @notice DVT validator node info
    struct ValidatorInfo {
        address validatorAddress;   // Validator node address
        bytes blsPublicKey;         // BLS public key (48 bytes)
        string nodeURI;             // Node endpoint (e.g., https://dvt1.example.com)
        uint256 registeredAt;       // Registration timestamp
        uint256 lastCheckTime;      // Last check timestamp
        uint256 totalChecks;        // Total check count
        uint256 totalProposals;     // Total proposals submitted
        bool isActive;              // Active status
    }

    /// @notice Slash proposal
    struct SlashProposal {
        uint256 proposalId;         // Proposal ID
        address operator;           // Operator to slash
        uint8 slashLevel;           // 0=WARNING, 1=MINOR, 2=MAJOR
        string reason;              // Slash reason
        uint256 timestamp;          // Proposal timestamp
        uint256 expiresAt;          // Expiration timestamp (24h)

        // Validator signatures
        address[] validators;       // Validators who signed
        bytes[] signatures;         // BLS signatures
        bool executed;              // Execution status
        bool expired;               // Expiration status
    }

    // ====================================
    // Storage
    // ====================================

    /// @notice SuperPaymaster address
    address public SUPERPAYMASTER;

    /// @notice BLS Aggregator address
    address public BLS_AGGREGATOR;

    /// @notice Registered validators (max 13)
    ValidatorInfo[13] public validators;

    /// @notice Current validator count
    uint256 public validatorCount;

    /// @notice Slash proposals mapping
    mapping(uint256 => SlashProposal) public proposals;

    /// @notice Next proposal ID
    uint256 public nextProposalId = 1;

    /// @notice Operator slash history (operator => proposal IDs)
    mapping(address => uint256[]) public operatorProposals;

    /// @notice Validator address => index mapping
    mapping(address => uint256) public validatorIndex;

    /// @notice Proposal expiration time: 24 hours
    uint256 public constant PROPOSAL_EXPIRATION = 24 hours;

    /// @notice Minimum validators required: 7 (for 7/13 threshold)
    uint256 public constant MIN_VALIDATORS = 7;

    // ====================================
    // Events
    // ====================================

    event ValidatorRegistered(
        address indexed validator,
        bytes blsPublicKey,
        uint256 index
    );

    event ValidatorDeactivated(
        address indexed validator,
        uint256 index
    );

    event SlashProposalCreated(
        uint256 indexed proposalId,
        address indexed operator,
        uint8 slashLevel,
        string reason
    );

    event ProposalSigned(
        uint256 indexed proposalId,
        address indexed validator,
        bytes signature
    );

    event ProposalExecuted(
        uint256 indexed proposalId,
        address indexed operator,
        bytes aggregatedProof
    );

    event ProposalExpired(
        uint256 indexed proposalId
    );

    event SuperPaymasterUpdated(
        address indexed oldAddress,
        address indexed newAddress
    );

    event BLSAggregatorUpdated(
        address indexed oldAddress,
        address indexed newAddress
    );

    // ====================================
    // Errors
    // ====================================

    error MaxValidatorsReached();
    error ValidatorNotRegistered(address validator);
    error ValidatorAlreadyRegistered(address validator);
    error ProposalNotFound(uint256 proposalId);
    error ProposalAlreadyExpired(uint256 proposalId);
    error ProposalAlreadyExecuted(uint256 proposalId);
    error AlreadySigned(address validator);
    error UnauthorizedValidator(address caller);
    error InvalidAddress(address addr);
    error InvalidBLSKey();

    // ====================================
    // Constructor
    // ====================================

    /**
     * @notice Initialize DVT Validator
     * @param _superPaymaster SuperPaymaster address
     */
    constructor(address _superPaymaster) Ownable(msg.sender) {
        if (_superPaymaster == address(0)) {
            revert InvalidAddress(_superPaymaster);
        }
        SUPERPAYMASTER = _superPaymaster;
    }

    // ====================================
    // Core Functions
    // ====================================

    /**
     * @notice Register new validator (only owner)
     * @param validatorAddress Validator node address
     * @param blsPublicKey BLS public key (48 bytes)
     * @param nodeURI Node endpoint
     */
    function registerValidator(
        address validatorAddress,
        bytes memory blsPublicKey,
        string memory nodeURI
    ) external onlyOwner {
        if (validatorCount >= 13) {
            revert MaxValidatorsReached();
        }

        if (validatorIndex[validatorAddress] != 0) {
            revert ValidatorAlreadyRegistered(validatorAddress);
        }

        if (blsPublicKey.length != 48) {
            revert InvalidBLSKey();
        }

        uint256 index = validatorCount;

        validators[index] = ValidatorInfo({
            validatorAddress: validatorAddress,
            blsPublicKey: blsPublicKey,
            nodeURI: nodeURI,
            registeredAt: block.timestamp,
            lastCheckTime: block.timestamp,
            totalChecks: 0,
            totalProposals: 0,
            isActive: true
        });

        validatorIndex[validatorAddress] = index + 1; // +1 to distinguish from 0
        validatorCount++;

        emit ValidatorRegistered(validatorAddress, blsPublicKey, index);
    }

    /**
     * @notice Create slash proposal (only validators)
     * @param operator Operator to slash
     * @param slashLevel 0=WARNING, 1=MINOR, 2=MAJOR
     * @param reason Slash reason
     * @return proposalId Created proposal ID
     */
    function createSlashProposal(
        address operator,
        uint8 slashLevel,
        string memory reason
    ) external returns (uint256 proposalId) {
        uint256 index = validatorIndex[msg.sender];
        if (index == 0) {
            revert ValidatorNotRegistered(msg.sender);
        }

        ValidatorInfo storage validator = validators[index - 1];
        if (!validator.isActive) {
            revert UnauthorizedValidator(msg.sender);
        }

        require(slashLevel <= 2, "Invalid slash level");

        proposalId = nextProposalId++;

        proposals[proposalId] = SlashProposal({
            proposalId: proposalId,
            operator: operator,
            slashLevel: slashLevel,
            reason: reason,
            timestamp: block.timestamp,
            expiresAt: block.timestamp + PROPOSAL_EXPIRATION,
            validators: new address[](0),
            signatures: new bytes[](0),
            executed: false,
            expired: false
        });

        operatorProposals[operator].push(proposalId);
        validator.totalProposals++;

        emit SlashProposalCreated(proposalId, operator, slashLevel, reason);
    }

    /**
     * @notice Sign slash proposal (only validators)
     * @param proposalId Proposal ID
     * @param signature BLS signature
     */
    function signProposal(uint256 proposalId, bytes memory signature) external {
        uint256 index = validatorIndex[msg.sender];
        if (index == 0) {
            revert ValidatorNotRegistered(msg.sender);
        }

        ValidatorInfo storage validator = validators[index - 1];
        if (!validator.isActive) {
            revert UnauthorizedValidator(msg.sender);
        }

        SlashProposal storage proposal = proposals[proposalId];
        if (proposal.proposalId == 0) {
            revert ProposalNotFound(proposalId);
        }

        if (proposal.executed) {
            revert ProposalAlreadyExecuted(proposalId);
        }

        if (block.timestamp > proposal.expiresAt) {
            proposal.expired = true;
            emit ProposalExpired(proposalId);
            revert ProposalAlreadyExpired(proposalId);
        }

        // Check if already signed
        for (uint i = 0; i < proposal.validators.length; i++) {
            if (proposal.validators[i] == msg.sender) {
                revert AlreadySigned(msg.sender);
            }
        }

        proposal.validators.push(msg.sender);
        proposal.signatures.push(signature);

        emit ProposalSigned(proposalId, msg.sender, signature);

        // If threshold reached (7/13), forward to BLS Aggregator
        if (proposal.validators.length >= MIN_VALIDATORS) {
            _forwardToBLSAggregator(proposalId);
        }
    }

    /**
     * @notice Mark proposal as executed (only BLS Aggregator)
     * @param proposalId Proposal ID
     */
    function markProposalExecuted(uint256 proposalId) external {
        require(msg.sender == BLS_AGGREGATOR, "Only BLS Aggregator");

        SlashProposal storage proposal = proposals[proposalId];
        if (proposal.proposalId == 0) {
            revert ProposalNotFound(proposalId);
        }

        proposal.executed = true;
    }

    // ====================================
    // Internal Functions
    // ====================================

    /**
     * @notice Forward proposal to BLS Aggregator
     * @param proposalId Proposal ID
     */
    function _forwardToBLSAggregator(uint256 proposalId) internal {
        if (BLS_AGGREGATOR == address(0)) return;

        SlashProposal memory proposal = proposals[proposalId];

        // Call BLS Aggregator to verify and execute
        IBLSAggregator(BLS_AGGREGATOR).verifyAndExecute(
            proposalId,
            proposal.operator,
            proposal.slashLevel,
            proposal.validators,
            proposal.signatures
        );
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
     * @notice Set BLS Aggregator address
     * @param _blsAggregator BLS Aggregator address
     */
    function setBLSAggregator(address _blsAggregator) external onlyOwner {
        if (_blsAggregator == address(0)) {
            revert InvalidAddress(_blsAggregator);
        }

        address oldAddress = BLS_AGGREGATOR;
        BLS_AGGREGATOR = _blsAggregator;

        emit BLSAggregatorUpdated(oldAddress, _blsAggregator);
    }

    /**
     * @notice Deactivate validator (only owner)
     * @param validatorAddress Validator address
     */
    function deactivateValidator(address validatorAddress) external onlyOwner {
        uint256 index = validatorIndex[validatorAddress];
        if (index == 0) {
            revert ValidatorNotRegistered(validatorAddress);
        }

        validators[index - 1].isActive = false;

        emit ValidatorDeactivated(validatorAddress, index - 1);
    }

    /**
     * @notice Expire old proposal (anyone can call)
     * @param proposalId Proposal ID
     */
    function expireProposal(uint256 proposalId) external {
        SlashProposal storage proposal = proposals[proposalId];
        if (proposal.proposalId == 0) {
            revert ProposalNotFound(proposalId);
        }

        if (block.timestamp > proposal.expiresAt && !proposal.executed) {
            proposal.expired = true;
            emit ProposalExpired(proposalId);
        }
    }

    // ====================================
    // View Functions
    // ====================================

    /**
     * @notice Get validator info
     * @param index Validator index (0-12)
     * @return info Validator info
     */
    function getValidator(uint256 index)
        external
        view
        returns (ValidatorInfo memory info)
    {
        require(index < validatorCount, "Invalid index");
        return validators[index];
    }

    /**
     * @notice Get all active validators
     * @return activeValidators Array of active validator addresses
     */
    function getActiveValidators()
        external
        view
        returns (address[] memory activeValidators)
    {
        uint256 activeCount = 0;
        for (uint i = 0; i < validatorCount; i++) {
            if (validators[i].isActive) {
                activeCount++;
            }
        }

        activeValidators = new address[](activeCount);
        uint256 currentIndex = 0;
        for (uint i = 0; i < validatorCount; i++) {
            if (validators[i].isActive) {
                activeValidators[currentIndex] = validators[i].validatorAddress;
                currentIndex++;
            }
        }
    }

    /**
     * @notice Get proposal details
     * @param proposalId Proposal ID
     * @return proposal Proposal details
     */
    function getProposal(uint256 proposalId)
        external
        view
        returns (SlashProposal memory proposal)
    {
        return proposals[proposalId];
    }

    /**
     * @notice Get operator's slash proposals
     * @param operator Operator address
     * @return proposalIds Array of proposal IDs
     */
    function getOperatorProposals(address operator)
        external
        view
        returns (uint256[] memory proposalIds)
    {
        return operatorProposals[operator];
    }

    /**
     * @notice Check if proposal has enough signatures
     * @param proposalId Proposal ID
     * @return hasEnoughSigs True if >= 7 signatures
     */
    function hasEnoughSignatures(uint256 proposalId)
        external
        view
        returns (bool hasEnoughSigs)
    {
        SlashProposal memory proposal = proposals[proposalId];
        return proposal.validators.length >= MIN_VALIDATORS;
    }

    /**
     * @notice Get proposal signature count
     * @param proposalId Proposal ID
     * @return count Signature count
     */
    function getSignatureCount(uint256 proposalId)
        external
        view
        returns (uint256 count)
    {
        return proposals[proposalId].validators.length;
    }
}
