// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title ISettlement - Gas Fee Settlement Interface
 * @notice Interface for batch settlement of gas fees with status tracking
 * @dev Uses Hash(paymaster, userOpHash) as unique record key
 */
interface ISettlement {
    // ============ Enums ============

    /**
     * @notice Fee record status
     * @dev Tracks lifecycle of each fee record
     */
    enum FeeStatus {
        Pending,   // 0 - Recorded, awaiting settlement
        Settled,   // 1 - Off-chain payment confirmed
        Disputed,  // 2 - Under dispute (future)
        Cancelled  // 3 - Cancelled/refunded (future)
    }

    // ============ Structs ============

    /**
     * @notice Complete fee record with status tracking
     * @dev Stored with key = keccak256(abi.encodePacked(paymaster, userOpHash))
     */
    struct FeeRecord {
        address paymaster;       // Paymaster that recorded this fee
        address user;            // User who owes the fee
        address token;           // Token used for payment (e.g., PNT)
        uint256 amount;          // Fee amount in wei
        uint256 timestamp;       // Block timestamp when recorded
        FeeStatus status;        // Current status
        bytes32 userOpHash;      // UserOperation hash from EntryPoint
        bytes32 settlementHash;  // Off-chain settlement proof (optional)
    }

    // ============ Events ============

    /**
     * @notice Emitted when a Paymaster records a new fee
     * @param recordKey Unique key: keccak256(paymaster, userOpHash)
     * @param paymaster Paymaster contract address
     * @param user User address
     * @param token Token address
     * @param amount Fee amount
     * @param userOpHash UserOperation hash
     */
    event FeeRecorded(
        bytes32 indexed recordKey,
        address indexed paymaster,
        address indexed user,
        address token,
        uint256 amount,
        bytes32 userOpHash
    );

    /**
     * @notice Emitted when a fee is settled
     * @param recordKey Record key
     * @param user User address
     * @param token Token address
     * @param amount Amount settled
     * @param settlementHash Off-chain payment proof
     */
    event FeeSettled(
        bytes32 indexed recordKey,
        address indexed user,
        address indexed token,
        uint256 amount,
        bytes32 settlementHash
    );

    /**
     * @notice Emitted when fees are batch settled
     * @param recordCount Number of records settled
     * @param totalAmount Total amount settled
     * @param settlementHash Batch settlement proof
     */
    event BatchSettled(
        uint256 recordCount,
        uint256 totalAmount,
        bytes32 indexed settlementHash
    );

    /**
     * @notice Emitted when fee status changes
     * @param recordKey Record key
     * @param oldStatus Previous status
     * @param newStatus New status
     */
    event FeeStatusChanged(
        bytes32 indexed recordKey,
        FeeStatus oldStatus,
        FeeStatus newStatus
    );

    /**
     * @notice Emitted when settlement threshold is updated
     * @param oldThreshold Previous threshold
     * @param newThreshold New threshold
     */
    event SettlementThresholdUpdated(
        uint256 oldThreshold,
        uint256 newThreshold
    );

    /**
     * @notice Emitted when contract is paused
     */
    event Paused(address account);

    /**
     * @notice Emitted when contract is unpaused
     */
    event Unpaused(address account);

    /**
     * @notice Emitted when fee rate is updated
     */
    event FeeRateUpdated(uint256 oldRate, uint256 newRate);

    /**
     * @notice Emitted when treasury address is updated
     */
    event TreasuryUpdated(address oldTreasury, address newTreasury);

    // ============ Paymaster Functions ============

    /**
     * @notice Record a gas fee (called by registered Paymaster only)
     * @dev CRITICAL: Only Paymasters registered in SuperPaymaster Registry can call
     * @param user User address who owes the fee
     * @param token Token address for payment
     * @param amount Fee amount in wei
     * @param userOpHash UserOperation hash from EntryPoint
     * @return recordKey Unique record key for this fee
     */
    function recordGasFee(
        address user,
        address token,
        uint256 amount,
        bytes32 userOpHash
    ) external returns (bytes32 recordKey);

    // ============ Settlement Functions ============

    /**
     * @notice Batch settle fees by record keys
     * @dev Only callable by owner after off-chain payment
     * @param recordKeys Array of record keys to settle
     * @param settlementHash Off-chain payment proof (optional)
     */
    function settleFees(
        bytes32[] calldata recordKeys,
        bytes32 settlementHash
    ) external;

    /**
     * @notice Settle all pending fees for specific users and token
     * @dev Only callable by owner after off-chain payment
     * @param users Array of user addresses
     * @param token Token address
     * @param settlementHash Off-chain payment proof
     */
    function settleFeesByUsers(
        address[] calldata users,
        address token,
        bytes32 settlementHash
    ) external;

    // ============ View Functions ============

    /**
     * @notice Get fee record by key
     * @param recordKey Record key
     * @return record Fee record struct
     */
    function getFeeRecord(bytes32 recordKey)
        external view returns (FeeRecord memory record);

    /**
     * @notice Get fee record by paymaster and userOpHash
     * @param paymaster Paymaster address
     * @param userOpHash UserOperation hash
     * @return record Fee record struct
     */
    function getRecordByUserOp(address paymaster, bytes32 userOpHash)
        external view returns (FeeRecord memory record);

    /**
     * @notice Get all record keys for a user
     * @param user User address
     * @return keys Array of record keys
     */
    function getUserRecordKeys(address user)
        external view returns (bytes32[] memory keys);

    /**
     * @notice Get all pending records for a user and token
     * @param user User address
     * @param token Token address
     * @return records Array of pending fee records
     */
    function getUserPendingRecords(address user, address token)
        external view returns (FeeRecord[] memory records);

    /**
     * @notice Get pending balance for user and token
     * @param user User address
     * @param token Token address
     * @return balance Total pending amount
     */
    function getPendingBalance(address user, address token)
        external view returns (uint256 balance);

    /**
     * @notice Get total pending amount for a token
     * @param token Token address
     * @return total Total pending across all users
     */
    function getTotalPending(address token)
        external view returns (uint256 total);

    /**
     * @notice Check if contract is paused
     * @return paused True if paused
     */
    function paused() external view returns (bool);

    /**
     * @notice Get settlement threshold
     * @return threshold Current threshold
     */
    function settlementThreshold() external view returns (uint256 threshold);

    // ============ Admin Functions ============

    /**
     * @notice Update settlement threshold
     * @param newThreshold New threshold value
     */
    function setSettlementThreshold(uint256 newThreshold) external;

    /**
     * @notice Pause contract operations
     */
    function pause() external;

    /**
     * @notice Unpause contract operations
     */
    function unpause() external;
}
