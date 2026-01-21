// SPDX-License-Identifier: MIT
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
}
