// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ISettlement} from "../interfaces/ISettlement.sol";
import {ISuperPaymasterRegistry} from "../interfaces/ISuperPaymasterRegistry.sol";

/**
 * @title Settlement - Batch Gas Fee Settlement Contract with Status Tracking
 * @notice Accumulates gas fees from registered Paymasters and enables batch settlement
 * @dev Security-first design with Hash-based key for gas optimization and replay protection
 *
 * Key Design:
 * - Record Key = keccak256(abi.encodePacked(paymaster, userOpHash))
 * - Natural replay protection (same userOp cannot be recorded twice)
 * - Saves ~10k gas per record (no counter increment)
 * - Each record has full lifecycle tracking (Pending → Settled)
 *
 * Security Features:
 * - ✅ Only Paymasters registered in SuperPaymaster Registry can record fees
 * - ✅ ReentrancyGuard on all state-changing functions
 * - ✅ State changes before external calls (CEI pattern)
 * - ✅ Comprehensive event logging
 * - ✅ Emergency pause mechanism
 *
 * @custom:security-contact security@aastar.community
 */
contract Settlement is ISettlement, Ownable, ReentrancyGuard {
    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice SuperPaymaster Registry contract (immutable for security)
    ISuperPaymasterRegistry public immutable registry;

    /// @notice Main storage: recordKey => FeeRecord
    /// @dev Key = keccak256(abi.encodePacked(paymaster, userOpHash))
    mapping(bytes32 => FeeRecord) private _feeRecords;

    /// @notice Index: user => array of record keys
    /// @dev Allows querying all records for a user
    mapping(address => bytes32[]) private _userRecordKeys;

    /// @notice Index: user => token => total pending amount
    /// @dev Fast O(1) lookup for pending balance
    mapping(address => mapping(address => uint256)) private _pendingAmounts;

    /// @notice Index: token => total pending across all users
    mapping(address => uint256) private _totalPending;

    /// @notice Settlement threshold for triggering batch settlements
    uint256 private _settlementThreshold;

    /// @notice Emergency pause status
    bool private _paused;

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Only registered Paymasters can call
     * @dev Checks SuperPaymaster Registry for active status
     */
    modifier onlyRegisteredPaymaster() {
        require(
            registry.isPaymasterActive(msg.sender),
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
        // Input validation
        require(user != address(0), "Settlement: zero user");
        require(token != address(0), "Settlement: zero token");
        require(amount > 0, "Settlement: zero amount");
        require(userOpHash != bytes32(0), "Settlement: zero hash");

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
            user: user,
            token: token,
            amount: amount,
            timestamp: block.timestamp,
            status: FeeStatus.Pending,
            userOpHash: userOpHash,
            settlementHash: bytes32(0)
        });

        // Update indexes
        _userRecordKeys[user].push(recordKey);
        _pendingAmounts[user][token] += amount;
        _totalPending[token] += amount;

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
            record.settlementHash = settlementHash;

            // Update indexes
            _pendingAmounts[record.user][record.token] -= record.amount;
            _totalPending[record.token] -= record.amount;

            totalSettled += record.amount;

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

    /**
     * @inheritdoc ISettlement
     * @dev Settle all pending fees for specific users and token
     */
    function settleFeesByUsers(
        address[] calldata users,
        address token,
        bytes32 settlementHash
    )
        external
        override
        nonReentrant
        whenNotPaused
        onlyOwner
    {
        require(users.length > 0, "Settlement: empty users");
        require(token != address(0), "Settlement: zero token");

        uint256 totalSettled = 0;
        uint256 recordCount = 0;

        for (uint256 i = 0; i < users.length; i++) {
            address user = users[i];
            bytes32[] memory keys = _userRecordKeys[user];

            for (uint256 j = 0; j < keys.length; j++) {
                bytes32 key = keys[j];
                FeeRecord storage record = _feeRecords[key];

                // Only settle pending records for this token
                if (
                    record.status == FeeStatus.Pending &&
                    record.token == token
                ) {
                    // Update record
                    FeeStatus oldStatus = record.status;
                    record.status = FeeStatus.Settled;
                    record.settlementHash = settlementHash;

                    // Update indexes
                    _pendingAmounts[user][token] -= record.amount;
                    _totalPending[token] -= record.amount;

                    totalSettled += record.amount;
                    recordCount++;

                    emit FeeSettled(
                        key,
                        user,
                        token,
                        record.amount,
                        settlementHash
                    );
                    emit FeeStatusChanged(key, oldStatus, FeeStatus.Settled);
                }
            }
        }

        require(recordCount > 0, "Settlement: no pending records");
        emit BatchSettled(recordCount, totalSettled, settlementHash);
    }

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

    /// @inheritdoc ISettlement
    function getUserRecordKeys(address user)
        external
        view
        override
        returns (bytes32[] memory keys)
    {
        return _userRecordKeys[user];
    }

    /// @inheritdoc ISettlement
    function getUserPendingRecords(address user, address token)
        external
        view
        override
        returns (FeeRecord[] memory records)
    {
        bytes32[] memory keys = _userRecordKeys[user];
        uint256 pendingCount = 0;

        // First pass: count pending records for this token
        for (uint256 i = 0; i < keys.length; i++) {
            FeeRecord storage record = _feeRecords[keys[i]];
            if (record.status == FeeStatus.Pending && record.token == token) {
                pendingCount++;
            }
        }

        // Second pass: collect pending records
        records = new FeeRecord[](pendingCount);
        uint256 index = 0;
        for (uint256 i = 0; i < keys.length; i++) {
            FeeRecord storage record = _feeRecords[keys[i]];
            if (record.status == FeeStatus.Pending && record.token == token) {
                records[index++] = record;
            }
        }

        return records;
    }

    /// @inheritdoc ISettlement
    function getPendingBalance(address user, address token)
        external
        view
        override
        returns (uint256 balance)
    {
        return _pendingAmounts[user][token];
    }

    /// @inheritdoc ISettlement
    function getTotalPending(address token)
        external
        view
        override
        returns (uint256 total)
    {
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
