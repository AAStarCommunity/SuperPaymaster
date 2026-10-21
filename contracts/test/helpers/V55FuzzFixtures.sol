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

/// @dev TEST-ONLY permissionless forwarder. It is made the SuperPaymaster owner so that a user
///      operation's EXECUTION (which runs between that bundle's validations and postOps) can move
///      owner-controlled pricing (`setAPNTSPrice`). Never a pattern for production.
contract V55OwnerRelay {
    function exec(address to, bytes calldata data) external returns (bytes memory r) {
        bool ok;
        (ok, r) = to.call(data);
        if (!ok) assembly { revert(add(r, 32), mload(r)) }
    }
}

interface IFuzzSP {
    function updatePrice() external;
    function aPNTsPriceUSD() external view returns (uint256);
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

    /// @dev Records the effect and moves prices INSIDE the bundle, i.e. after every validation of the
    ///      bundle and before this op's (and later ops') postOp: the ETH/USD answer (+ permissionless
    ///      `updatePrice`) when `newAnswer != 0`, and aPNTs/USD by `aSteps` owner steps of exactly
    ///      ±10% (the SP delta guard's bound) through the owner relay. SP must still charge at each
    ///      op's VALIDATION-time snapshot (R10-M3).
    function hitMovePrice(bytes32 id, address feed, address sp, address relay, int256 newAnswer, uint8 aSteps, bool aUp)
        external
    {
        hits[id] += 1;
        if (newAnswer != 0) {
            V55MutablePriceFeed(feed).setAnswer(newAnswer);
            IFuzzSP(sp).updatePrice();
        }
        for (uint256 i; i < aSteps; i++) {
            uint256 cur = IFuzzSP(sp).aPNTsPriceUSD();
            uint256 np = aUp ? cur * 11_000 / 10_000 : cur * 9_000 / 10_000;
            V55OwnerRelay(relay).exec(sp, abi.encodeWithSignature("setAPNTSPrice(uint256)", np));
        }
    }
}
