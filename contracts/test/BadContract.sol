// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

contract BadContract {
    receive() external payable {
        revert("BadContract: Receive Revert");
    }

    fallback() external payable {
        revert("BadContract: Fallback Revert");
    }
    
    function exchangeRate() external pure returns (uint256) {
        revert("BadContract: ExchangeRate Revert");
    }

    function balanceOf(address) external pure returns (uint256) {
        revert("BadContract: BalanceOf Revert");
    }
}
