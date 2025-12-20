// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title IxPNTsToken
 * @notice Interface for xPNTsToken contract
 * @dev Used by PaymasterV4 to get exchange rate
 */
interface IxPNTsToken {
    /**
     * @notice Get exchange rate with aPNTs
     * @dev xPNTs amount = aPNTs amount * exchangeRate / 1e18
     * @return rate Exchange rate (18 decimals, 1e18 = 1:1)
     */
    function exchangeRate() external view returns (uint256 rate);

    /**
     * @notice Record user debt (only SuperPaymaster)
     * @param user User address
     * @param amountXPNTs Debt amount in xPNTs
     */
    function recordDebt(address user, uint256 amountXPNTs) external;

    /**
     * @notice Get user debt amount
     * @param user User address
     * @return debt Debt amount in xPNTs
     */
    function getDebt(address user) external view returns (uint256 debt);
}
