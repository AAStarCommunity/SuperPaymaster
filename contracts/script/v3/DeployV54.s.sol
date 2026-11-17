// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";

/**
 * @title DeployV54 (RETIRED)
 * @notice The v5.4 "god-split + DVT policy" Sepolia one-shot. Retired from 5.5.0: it created
 *         SuperPaymaster / Registry with a plain `new` from a file that imports Registry.sol,
 *         i.e. under the runs=200 "registry-size" compiler profile, so it would ship bytes the
 *         tests and size evidence never measured. `./deploy-core <env>` (DeployLive /
 *         UpgradeLive, DefaultArtifacts._deployDefault) covers everything it did. The old body
 *         is in git history (before this commit).
 */
contract DeployV54 is Script {
    function run() external pure {
        revert("DeployV54: retired since 5.5.0 (ships runs=200 bytecode); use DeployLive/UpgradeLive");
    }
}
