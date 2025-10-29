// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title MockChainlinkAggregator
 * @notice Simple mock for Chainlink price feeds in tests
 */
contract MockChainlinkAggregator is AggregatorV3Interface {
    uint8 public immutable override decimals;
    int256 public latestPrice;
    uint256 public latestUpdateTime;
    uint80 public latestRoundId;

    constructor(uint8 _decimals, int256 _initialPrice) {
        decimals = _decimals;
        latestPrice = _initialPrice;
        latestUpdateTime = block.timestamp;
        latestRoundId = 1;
    }

    function updatePrice(int256 _price) external {
        latestPrice = _price;
        latestUpdateTime = block.timestamp;
        latestRoundId++;
    }

    function latestRoundData()
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (
            latestRoundId,
            latestPrice,
            latestUpdateTime,
            latestUpdateTime,
            latestRoundId
        );
    }

    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (_roundId, latestPrice, latestUpdateTime, latestUpdateTime, _roundId);
    }

    function description() external pure override returns (string memory) {
        return "MockChainlinkAggregator";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }
}
