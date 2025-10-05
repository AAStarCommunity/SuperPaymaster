// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title ISettlement - Settlement Contract Interface
 * @notice Interface for batch gas fee settlement
 * @dev Used by SuperPaymaster to record fees for later batch settlement
 */
interface ISettlement {
    // ============ Events ============

    /**
     * @notice Emitted when a gas fee is recorded
     * @param user Address of the user who incurred the fee
     * @param token Token address used for payment
     * @param amount Amount of fee recorded (in wei)
     */
    event FeeRecorded(
        address indexed user,
        address indexed token,
        uint256 amount
    );

    /**
     * @notice Emitted when fees are settled
     * @param user Address of the user whose fees were settled
     * @param token Token address
     * @param amount Amount settled
     */
    event FeesSettled(
        address indexed user,
        address indexed token,
        uint256 amount
    );

    /**
     * @notice Emitted when a Paymaster is authorized or deauthorized
     * @param paymaster Address of the Paymaster
     * @param status True if authorized, false if deauthorized
     */
    event PaymasterAuthorized(
        address indexed paymaster,
        bool status
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

    // ============ State-Changing Functions ============

    /**
     * @notice Record gas fee for a user
     * @dev Only callable by authorized Paymaster contracts
     * @param user User address
     * @param token ERC20 token address
     * @param amount Fee amount in token (wei)
     */
    function recordGasFee(
        address user,
        address token,
        uint256 amount
    ) external;

    /**
     * @notice Batch settle fees for multiple users
     * @dev Only callable by owner/keeper
     * @param users Array of user addresses
     * @param token Token address to settle
     * @param treasury Address to receive the settled fees
     */
    function settleFees(
        address[] calldata users,
        address token,
        address treasury
    ) external;

    /**
     * @notice Authorize or deauthorize a Paymaster
     * @dev Only callable by owner
     * @param paymaster Paymaster contract address
     * @param status True to authorize, false to deauthorize
     */
    function setPaymasterAuthorization(
        address paymaster,
        bool status
    ) external;

    /**
     * @notice Update settlement threshold
     * @dev Only callable by owner
     * @param newThreshold New threshold value
     */
    function setSettlementThreshold(uint256 newThreshold) external;

    // ============ View Functions ============

    /**
     * @notice Get pending balance for a user
     * @param user User address
     * @param token Token address
     * @return pending Pending fee amount
     */
    function getPendingBalance(
        address user,
        address token
    ) external view returns (uint256 pending);

    /**
     * @notice Get total pending fees for a token
     * @param token Token address
     * @return total Total pending amount across all users
     */
    function getTotalPending(address token) external view returns (uint256 total);

    /**
     * @notice Check if a Paymaster is authorized
     * @param paymaster Paymaster address
     * @return authorized True if authorized
     */
    function isAuthorizedPaymaster(address paymaster) external view returns (bool authorized);

    /**
     * @notice Get settlement threshold
     * @return threshold Current threshold value
     */
    function getSettlementThreshold() external view returns (uint256 threshold);
}
