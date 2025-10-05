// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title ISuperPaymasterV3 - SuperPaymaster V3 Interface
 * @notice Interface for SuperPaymaster V3 with SBT + PNT validation
 * @dev Extends ERC-4337 Paymaster functionality with on-chain qualification checks
 */
interface ISuperPaymasterV3 {
    // ============ Events ============

    /**
     * @notice Emitted when SBT contract is updated
     * @param oldSBT Previous SBT contract address
     * @param newSBT New SBT contract address
     */
    event SBTContractUpdated(
        address indexed oldSBT,
        address indexed newSBT
    );

    /**
     * @notice Emitted when gas token is updated
     * @param oldToken Previous gas token address
     * @param newToken New gas token address
     */
    event GasTokenUpdated(
        address indexed oldToken,
        address indexed newToken
    );

    /**
     * @notice Emitted when settlement contract is updated
     * @param oldSettlement Previous settlement contract
     * @param newSettlement New settlement contract
     */
    event SettlementContractUpdated(
        address indexed oldSettlement,
        address indexed newSettlement
    );

    /**
     * @notice Emitted when minimum token balance is updated
     * @param oldBalance Previous minimum balance
     * @param newBalance New minimum balance
     */
    event MinTokenBalanceUpdated(
        uint256 oldBalance,
        uint256 newBalance
    );

    /**
     * @notice Emitted when gas is sponsored for a user
     * @param user User address
     * @param amount Gas cost amount
     * @param token Token used for payment
     */
    event GasSponsored(
        address indexed user,
        uint256 amount,
        address indexed token
    );

    /**
     * @notice Emitted when gas fee is recorded in settlement
     * @param user User address
     * @param amount Fee amount
     * @param token Token address
     */
    event GasRecorded(
        address indexed user,
        uint256 amount,
        address indexed token
    );

    /**
     * @notice Emitted when user qualification check fails
     * @param user User address
     * @param reason Failure reason (0: No SBT, 1: Insufficient balance)
     */
    event QualificationCheckFailed(
        address indexed user,
        uint8 reason
    );

    // ============ Configuration Functions ============

    /**
     * @notice Set SBT contract address
     * @dev Only callable by owner
     * @param sbt SBT contract address
     */
    function setSBTContract(address sbt) external;

    /**
     * @notice Set gas token address
     * @dev Only callable by owner
     * @param token ERC20 token address
     */
    function setGasToken(address token) external;

    /**
     * @notice Set settlement contract address
     * @dev Only callable by owner
     * @param settlement Settlement contract address
     */
    function setSettlementContract(address settlement) external;

    /**
     * @notice Set minimum token balance requirement
     * @dev Only callable by owner
     * @param minBalance Minimum balance in wei
     */
    function setMinTokenBalance(uint256 minBalance) external;

    // ============ View Functions ============

    /**
     * @notice Get SBT contract address
     * @return sbt SBT contract address
     */
    function sbtContract() external view returns (address sbt);

    /**
     * @notice Get gas token address
     * @return token Gas token address
     */
    function gasToken() external view returns (address token);

    /**
     * @notice Get settlement contract address
     * @return settlement Settlement contract address
     */
    function settlementContract() external view returns (address settlement);

    /**
     * @notice Get minimum token balance requirement
     * @return minBalance Minimum balance in wei
     */
    function minTokenBalance() external view returns (uint256 minBalance);

    /**
     * @notice Check if a user is qualified for gas sponsorship
     * @param user User address to check
     * @return qualified True if user meets all requirements
     * @return reason Failure reason if not qualified (0: No SBT, 1: Low balance)
     */
    function isUserQualified(address user) external view returns (
        bool qualified,
        uint8 reason
    );
}
