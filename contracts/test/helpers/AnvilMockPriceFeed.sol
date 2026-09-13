// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

// T-4 ("tested == deployed"): DeployAnvil deploys every contract from its profile.default
// artifact by explicit path. `forge build` only emits a profile.default artifact for sources
// reachable from src/ or test/ WITHOUT going through Registry.sol; the anvil-only infrastructure
// below is otherwise compiled solely inside the deploy script's closure, i.e. under the runs=200
// "registry-size" profile. This file exists so that `forge build` produces the default builds.
import { EntryPoint } from "@account-abstraction-v7/core/EntryPoint.sol";
import { SimpleAccountFactory } from "@account-abstraction-v7/samples/SimpleAccountFactory.sol";

/// @notice Local-chain ETH/USD feed ($2,000, always fresh). Moved here from DeployAnvil.s.sol so it
///         has a profile.default artifact (out/AnvilMockPriceFeed.sol/AnvilMockPriceFeed.json).
contract AnvilMockPriceFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000 * 1e8, 0, block.timestamp, 1);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

/// @dev Referencing the two imports keeps them in this compilation unit (no runtime use).
abstract contract AnvilInfraArtifacts {
    function _anvilInfraTypes() internal pure returns (bytes4, bytes4) {
        return (EntryPoint.handleOps.selector, SimpleAccountFactory.createAccount.selector);
    }
}
