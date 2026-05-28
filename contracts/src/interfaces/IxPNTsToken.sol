// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;
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
     * @notice Record user debt (only SuperPaymaster). Amount in aPNTs.
     * @param user User address
     * @param amountAPNTs Debt amount in aPNTs (protocol unit)
     */
    function recordDebt(address user, uint256 amountAPNTs) external;

    /**
     * @notice Record user debt with opHash replay protection (P1-17). Amount in aPNTs.
     * @dev Preferred over recordDebt; reverts if the same opHash was already processed
     * @param user User address
     * @param amountAPNTs Debt amount in aPNTs (protocol unit)
     * @param opHash UserOperation hash — used as replay guard key
     */
    function recordDebtWithOpHash(address user, uint256 amountAPNTs, bytes32 opHash) external;

    /**
     * @notice Get user debt amount in aPNTs (protocol unit)
     * @param user User address
     * @return debt Debt amount in aPNTs
     */
    function getDebt(address user) external view returns (uint256 debt);

    /**
     * @notice Secure burn by Paymaster with replay protection. Amount in aPNTs;
     *         xPNTs burned = amountAPNTs * exchangeRate / 1e18 (ceil).
     * @param from User address
     * @param amountAPNTs aPNTs amount to settle (converted to xPNTs internally)
     * @param userOpHash UserOperation hash for replay protection
     */
    function burnFromWithOpHash(address from, uint256 amountAPNTs, bytes32 userOpHash) external;
    
    /**
     * @notice Get factory address that created this token
     * @dev Used by PaymasterV4 to verify token origin
     * @return factory Factory contract address
     */
    function FACTORY() external view returns (address factory);

    /**
     * @notice Check whether a facilitator is authorized by this community to
     *         settle x402 Direct payments against this xPNTs token.
     * @dev    P0-12b (D4): community-controlled whitelist. SuperPaymaster
     *         consults this in `settleX402PaymentDirect` so that a compromised
     *         or untrusted facilitator with a valid global role still cannot
     *         touch a community's xPNTs.
     * @param facilitator Facilitator address to check.
     * @return True iff this xPNTs has authorized `facilitator`.
     */
    function approvedFacilitators(address facilitator) external view returns (bool);
}
