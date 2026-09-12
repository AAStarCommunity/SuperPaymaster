// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

// Shared fixtures for the D5 G2 EntryPoint-level fuzz (SuperPaymasterV55Fuzz.t.sol). Kept out of
// any *.t.sol file for the reason given in V2TestFixtures.sol.

/// @dev Chainlink-shaped ETH/USD feed whose answer the test (or a user op) can move. Always fresh
///      (updatedAt = block.timestamp), 8 decimals.
contract V55MutablePriceFeed {
    int256 public answer = 2000 * 1e8;
    function setAnswer(int256 a) external { answer = a; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

interface IPriceUpdatable {
    function updatePrice() external;
}

/// @dev Target of every fuzzed user operation. `hits[id]` is the op's observable execution effect
///      (I8): it survives only if the op's execution frame is kept.
contract V55FuzzTarget {
    mapping(bytes32 => uint256) public hits;

    function hit(bytes32 id) external { hits[id] += 1; }

    function hitRevert(bytes32 id) external {
        hits[id] += 1;
        revert("fuzz: user call reverts");
    }

    /// @dev Records the effect, then burns every remaining gas unit -> out-of-gas revert.
    function hitBurn(bytes32 id) external {
        hits[id] += 1;
        while (true) {}
    }

    /// @dev Records the effect and moves the ETH/USD price mid-bundle (permissionless
    ///      `updatePrice`), so later ops' postOps run after the live price changed: SP must still
    ///      charge at each op's VALIDATION-time snapshot (R10-M3).
    function hitMovePrice(bytes32 id, address feed, address sp, int256 newAnswer) external {
        hits[id] += 1;
        V55MutablePriceFeed(feed).setAnswer(newAnswer);
        IPriceUpdatable(sp).updatePrice();
    }
}
