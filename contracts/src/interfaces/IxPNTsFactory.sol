// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

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
}
