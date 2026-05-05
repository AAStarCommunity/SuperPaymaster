// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;
/**
 * @title IxPNTsFactory
 * @notice Interface for xPNTsFactory contract
 * @dev Used by PaymasterV4 to get aPNTs price
 */
interface IxPNTsFactory {
    /**
     * @notice Get current aPNTs USD price
     * @dev Used by PaymasterV4 and SuperPaymaster V2 for gas cost calculation
     * @return price aPNTs price in USD (18 decimals)
     */
    function getAPNTsPrice() external view returns (uint256 price);

    /**
     * @notice Get xPNTs token address for community
     * @param community Community address
     * @return token Token address
     */
    function getTokenAddress(address community) external view returns (address token);

    /**
     * @notice Check if community has deployed token
     * @param community Community address
     * @return exists True if token exists
     */
    function hasToken(address community) external view returns (bool exists);

    /**
     * @notice Check if `token` was deployed via this factory and is therefore
     *         a trusted xPNTs token (subject to firewall + per-tx caps).
     * @dev    P0-12a: SuperPaymaster `settleX402PaymentDirect` MUST gate on this
     *         check so that an attacker cannot drain a victim's standard
     *         `approve(facilitator, MAX)` on USDC / WETH / etc. via the Direct
     *         path. Only xPNTs tokens are protected by the autoApproved firewall.
     * @param token Token address to verify
     * @return True iff the factory deployed this token (xPNTs).
     */
    function isXPNTs(address token) external view returns (bool);
}
