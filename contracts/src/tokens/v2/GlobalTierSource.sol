// SPDX-License-Identifier: Apache-2.0
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;

import { IVersioned } from "src/interfaces/IVersioned.sol";
import { ICreditTierSource } from "./ICreditTierSource.sol";

interface IRegistryCreditLimit {
    function getCreditLimit(address user) external view returns (uint256);
    function levelThresholds(uint256 index) external view returns (uint256);
    function creditTierConfig(uint256 level) external view returns (uint256);
}

/**
 * @title GlobalTierSource
 * @notice 5.5.0's only credit tier source: the protocol-wide reputation tier from Registry.
 * @dev    Spec §8.7 / §0. Non-upgradeable and stateless: its codehash binds the dispatch
 *         logic and the immutable Registry address. Registry is itself upgradeable, so its
 *         upgrade governance remains able to change the returned credit limits.
 *         Invoked by xPNTs v2 inside SuperPaymaster's validation frame via STATICCALL:
 *         `Registry.getCreditLimit` reads `globalReputation[user]` (sender-associated) and the
 *         global `levelThresholds` and `creditTierConfig` tables (read-only, allowed for a
 *         staked paymaster, STO-033). `creditFloor` reads those same global tables.
 */
contract GlobalTierSource is ICreditTierSource, IVersioned {
    IRegistryCreditLimit public immutable REGISTRY;

    constructor(address registry) {
        require(registry != address(0), "registry=0");
        REGISTRY = IRegistryCreditLimit(registry);
    }

    function version() external pure override returns (string memory) {
        return "GlobalTierSource-1.0.1";
    }

    /// @inheritdoc ICreditTierSource
    function tierOf(address, address user) external view override returns (uint256) {
        return REGISTRY.getCreditLimit(user);
    }

    /// @inheritdoc ICreditTierSource
    /// @dev The tier of a reputation-0 address. Registry thresholds are strictly ascending
    ///      (contracts/src/core/Registry.sol:918), so only the first can be zero: reputation 0 is at
    ///      level 2 iff levelThresholds[0] == 0, else level 1. Any failure, including an empty
    ///      schedule (the generated getter reverts out of bounds), propagates; the token then grants
    ///      AUTO 0. That is exact for an empty schedule (every address is level 1, so AUTO is
    ///      tier1 - tier1 = 0) and never mistakes an out-of-gas revert for an empty schedule.
    function creditFloor() external view override returns (uint256) {
        return REGISTRY.creditTierConfig(REGISTRY.levelThresholds(0) == 0 ? 2 : 1);
    }
}
