// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IxPNTsToken {
    function addAutoApprovedSpender(address spender) external;
}

interface IxPNTsFactory {
    function owner() external view returns (address);
}

/**
 * @title FactoryHelper
 * @notice Helper contract to add auto-approved spenders via factory
 * @dev Factory owner deploys this, then calls addAutoApprovedSpenderViaFactory
 */
contract FactoryHelper {
    address public immutable FACTORY;

    constructor(address _factory) {
        FACTORY = _factory;
    }

    /**
     * @notice Add auto-approved spender to xPNTs token via factory
     * @param token xPNTs token address
     * @param spender Address to approve (e.g., SuperPaymaster)
     */
    function addAutoApprovedSpenderViaFactory(address token, address spender) external {
        // Verify caller is factory owner
        require(msg.sender == IxPNTsFactory(FACTORY).owner(), "Only factory owner");

        // Call token's addAutoApprovedSpender from this contract
        // This won't work because msg.sender will be this contract, not factory

        // We need a different approach: factory needs to implement this function
        revert("Factory must implement proxy function");
    }
}
