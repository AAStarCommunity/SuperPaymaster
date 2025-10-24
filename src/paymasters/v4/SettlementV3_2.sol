// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISettlement} from "../interfaces/ISettlement.sol";
import {ISuperPaymasterRegistry} from "../interfaces/ISuperPaymasterRegistry.sol";

/**
 * @title SettlementV3.2 - OP Mainnet Optimized Version
 * @notice L2-optimized version leveraging cheaper storage costs on OP Mainnet
 * @dev Retains _pendingAmounts mapping due to 40x cheaper SSTORE on L2 (~500 gas vs 20k)
 *
 * V3.2 L2 Optimizations:
 * - Base: Same as V3.1 optimizations (bit-packing, removed arrays)
 * - KEEPS _pendingAmounts mapping (cost acceptable on L2: 22k→550 gas)
 * - KEEPS _totalPending mapping (cost acceptable on L2: 5k→125 gas)
 * - Provides getPendingBalance() view function (useful on L2)
 * - Lower settlement threshold (cheaper to settle on L2)
 *
 * Gas Cost Comparison (L1 vs L2):
 * - L1 SSTORE: ~20,000 gas
 * - L2 SSTORE: ~500 gas (40x cheaper)
 * - Keeping mappings adds ~675 gas on L2 (vs 27k on L1)
 *
 * @custom:security-contact security@aastar.community
 */
contract SettlementV3_2 is ISettlement, Ownable, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice Contract version for tracking deployments
    string public constant VERSION = "SettlementV3.2-OP-Mainnet";

    /// @notice SuperPaymaster Registry contract (immutable for security)
    ISuperPaymasterRegistry public immutable registry;

    /// @notice Main storage: recordKey => FeeRecord
    /// @dev Key = keccak256(abi.encodePacked(paymaster, userOpHash))
    mapping(bytes32 => FeeRecord) private _feeRecords;

    /// @notice REMOVED in V3.0: _userRecordKeys mapping (use events for indexing)

    /// @notice V3.2: KEPT for L2 - User pending balances per token
    /// @dev Cost acceptable on L2 (~550 gas vs 22k on L1)
    mapping(address => mapping(address => uint256)) private _pendingAmounts;

    /// @notice V3.2: KEPT for L2 - Total pending per token
    /// @dev Cost acceptable on L2 (~125 gas vs 5k on L1)
    mapping(address => uint256) private _totalPending;

    /// @notice Settlement threshold for triggering batch settlements
    uint256 private _settlementThreshold;

    /// @notice Emergency pause status
    bool private _paused;

    /// @notice Fee rate in basis points (150 = 1.5%)
    /// @dev Used by off-chain keeper for calculating final PNT amount
    uint256 public feeRate;

    /// @notice Treasury address for receiving PNT payments
    /// @dev Used by off-chain keeper for transferFrom destination
    address public treasury;

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Only registered Paymasters can call
     * @dev Checks SuperPaymaster Registry for active status using getPaymasterInfo
     */
    modifier onlyRegisteredPaymaster() {
        (uint256 _feeRate, bool isActive, , , ) = registry.getPaymasterInfo(msg.sender);
        require(
            isActive && _feeRate > 0,
            "Settlement: paymaster not registered"
        );
        _;
    }

    /**
     * @notice Only when not paused
     */
    modifier whenNotPaused() {
        require(!_paused, "Settlement: paused");
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Initialize Settlement contract
     * @param initialOwner Address of the contract owner
     * @param registryAddress SuperPaymaster Registry contract address
     * @param initialThreshold Initial settlement threshold
     * @dev Registry address is immutable after deployment for security
     */
    constructor(
        address initialOwner,
        address registryAddress,
        uint256 initialThreshold
    ) Ownable(initialOwner) {
        require(initialOwner != address(0), "Settlement: zero owner");
        require(registryAddress != address(0), "Settlement: zero registry");
        require(initialThreshold > 0, "Settlement: zero threshold");

        registry = ISuperPaymasterRegistry(registryAddress);
        _settlementThreshold = initialThreshold;
    }

    /*//////////////////////////////////////////////////////////////
                          PAYMASTER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc ISettlement
     * @dev CRITICAL SECURITY:
     * - Only registered Paymasters can call
     * - Natural replay protection (duplicate key will revert)
     * - Saves ~10k gas vs counter-based approach
     */
    function recordGasFee(
        address user,
        address token,
        uint256 amount,
        bytes32 userOpHash
    )
        external
        override
        nonReentrant
        whenNotPaused
        onlyRegisteredPaymaster
        returns (bytes32 recordKey)
    {
        // Input validation (V3.1: short-circuit optimization)
        require(
            user != address(0) &&
            token != address(0) &&
            amount > 0 &&
            userOpHash != bytes32(0),
            "Settlement: invalid params"
        );

        // Generate unique key
        recordKey = keccak256(abi.encodePacked(msg.sender, userOpHash));

        // Replay protection: ensure this record doesn't exist
        require(
            _feeRecords[recordKey].amount == 0,
            "Settlement: duplicate record"
        );

        // CEI Pattern: Effects
        _feeRecords[recordKey] = FeeRecord({
            paymaster: msg.sender,
            amount: uint96(amount),
            user: user,
            timestamp: uint96(block.timestamp),
            token: token,
            status: FeeStatus.Pending,
            userOpHash: userOpHash
        });

        // V3.2: Update pending balances (cost acceptable on L2)
        // Unchecked: amount validated > 0, no overflow risk in practice
        unchecked {
            _pendingAmounts[user][token] += amount;
            _totalPending[token] += amount;
        }

        // CEI Pattern: Interactions (events)
        emit FeeRecorded(recordKey, msg.sender, user, token, amount, userOpHash);

        return recordKey;
    }

    /*//////////////////////////////////////////////////////////////
                          SETTLEMENT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @inheritdoc ISettlement
     * @dev Batch settle by record keys
     * Security:
     * - Only owner can call
     * - Validates all records before state changes
     * - Atomic operation (all or nothing)
     */
    function settleFees(
        bytes32[] calldata recordKeys,
        bytes32 settlementHash
    )
        external
        override
        nonReentrant
        whenNotPaused
        onlyOwner
    {
        require(recordKeys.length > 0, "Settlement: empty records");

        uint256 totalSettled = 0;

        for (uint256 i = 0; i < recordKeys.length; i++) {
            bytes32 key = recordKeys[i];
            FeeRecord storage record = _feeRecords[key];

            // Validate record exists and is pending
            require(record.amount > 0, "Settlement: record not found");
            require(
                record.status == FeeStatus.Pending,
                "Settlement: not pending"
            );

            // CEI Pattern: Effects
            FeeStatus oldStatus = record.status;
            record.status = FeeStatus.Settled;

            // V3.2: Update pending balances (subtract settled amount)
            unchecked {
                _pendingAmounts[record.user][record.token] -= record.amount;
                _totalPending[record.token] -= record.amount;
                totalSettled += record.amount;  // Safe: amount validated on record
            }

            // CEI Pattern: Interactions (events)
            emit FeeSettled(
                key,
                record.user,
                record.token,
                record.amount,
                settlementHash
            );
            emit FeeStatusChanged(key, oldStatus, FeeStatus.Settled);
        }

        emit BatchSettled(recordKeys.length, totalSettled, settlementHash);
    }

    // REMOVED: settleFeesByUsers() - Use settleFees() with off-chain indexed keys

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISettlement
    function getFeeRecord(bytes32 recordKey)
        external
        view
        override
        returns (FeeRecord memory record)
    {
        return _feeRecords[recordKey];
    }

    /// @inheritdoc ISettlement
    function getRecordByUserOp(address paymaster, bytes32 userOpHash)
        external
        view
        override
        returns (FeeRecord memory record)
    {
        bytes32 key = keccak256(abi.encodePacked(paymaster, userOpHash));
        return _feeRecords[key];
    }

    // REMOVED: getUserRecordKeys() - Use off-chain indexing via FeeRecorded events
    // REMOVED: getUserPendingRecords() - Use getPendingBalance() + off-chain indexing

    /// @inheritdoc ISettlement
    /// @dev V3.2: RESTORED - Mapping kept on L2 due to low SSTORE cost
    /// Returns actual pending balance from storage
    function getPendingBalance(address user, address token)
        external
        view
        override
        returns (uint256 balance)
    {
        // V3.2: Returns actual value from mapping
        return _pendingAmounts[user][token];
    }

    /// @inheritdoc ISettlement
    /// @dev V3.2: RESTORED - Mapping kept on L2 due to low SSTORE cost
    /// Returns actual total pending from storage
    function getTotalPending(address token)
        external
        view
        override
        returns (uint256 total)
    {
        // V3.2: Returns actual value from mapping
        return _totalPending[token];
    }

    /// @inheritdoc ISettlement
    function paused() external view override returns (bool) {
        return _paused;
    }

    /// @inheritdoc ISettlement
    function settlementThreshold()
        external
        view
        override
        returns (uint256 threshold)
    {
        return _settlementThreshold;
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISettlement
    function setSettlementThreshold(uint256 newThreshold)
        external
        override
        onlyOwner
    {
        require(newThreshold > 0, "Settlement: zero threshold");

        uint256 oldThreshold = _settlementThreshold;
        _settlementThreshold = newThreshold;

        emit SettlementThresholdUpdated(oldThreshold, newThreshold);
    }

    /// @inheritdoc ISettlement
    function pause() external override onlyOwner {
        _paused = true;
        emit Paused(msg.sender);
    }

    /// @inheritdoc ISettlement
    function unpause() external override onlyOwner {
        _paused = false;
        emit Unpaused(msg.sender);
    }

    /**
     * @notice Set fee rate for off-chain settlement
     * @param _feeRate New fee rate in basis points (150 = 1.5%)
     * @dev Maximum 10% (1000 basis points)
     */
    function setFeeRate(uint256 _feeRate) external onlyOwner {
        require(_feeRate <= 1000, "Settlement: fee rate too high");

        uint256 oldRate = feeRate;
        feeRate = _feeRate;

        emit FeeRateUpdated(oldRate, _feeRate);
    }

    /**
     * @notice Set treasury address for PNT payments
     * @param _treasury New treasury address
     */
    function setTreasury(address _treasury) external onlyOwner {
        require(_treasury != address(0), "Settlement: zero treasury");

        address oldTreasury = treasury;
        treasury = _treasury;

        emit TreasuryUpdated(oldTreasury, _treasury);
    }

    /*//////////////////////////////////////////////////////////////
                          HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Calculate record key for a paymaster and userOpHash
     * @param paymaster Paymaster address
     * @param userOpHash UserOperation hash
     * @return key Record key
     */
    function calculateRecordKey(address paymaster, bytes32 userOpHash)
        external
        pure
        returns (bytes32 key)
    {
        return keccak256(abi.encodePacked(paymaster, userOpHash));
    }
}
