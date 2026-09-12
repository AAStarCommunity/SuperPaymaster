// SPDX-License-Identifier: Apache-2.0
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;

import { IVersioned } from "src/interfaces/IVersioned.sol";
import { ICreditTierSource } from "./ICreditTierSource.sol";

interface IRegistryCreditLimit {
    function getCreditLimit(address user) external view returns (uint256);
}

/**
 * @title GlobalTierSource
 * @notice 5.5.0's only credit tier source: the protocol-wide reputation tier from Registry.
 * @dev    Spec §8.7 / §0. Non-upgradeable and stateless so its codehash binds its behaviour.
 *         Invoked by xPNTs v2 inside SuperPaymaster's validation frame via STATICCALL:
 *         `Registry.getCreditLimit` reads `globalReputation[user]` (sender-associated) and the
 *         global `creditTierConfig` table (read-only, allowed for a staked paymaster, STO-033).
 */
contract GlobalTierSource is ICreditTierSource, IVersioned {
    IRegistryCreditLimit public immutable REGISTRY;

    constructor(address registry) {
        require(registry != address(0), "registry=0");
        REGISTRY = IRegistryCreditLimit(registry);
    }

    function version() external pure override returns (string memory) {
        return "GlobalTierSource-1.0.0";
    }

    /// @inheritdoc ICreditTierSource
    function tierOf(address, address user) external view override returns (uint256) {
        return REGISTRY.getCreditLimit(user);
    }
}
