// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import "src/modules/monitoring/BLSAggregator.sol";
import "src/modules/monitoring/DVTValidator.sol";
import {GovernanceOwnerGate} from "../checks/GovernanceOwnerGate.sol";

/// @notice RETIRED (5.5.0): formerly redeployed the two non-upgradeable BLS modules after
///         the slash-consensus unification (PR #329); `run()` now reverts. Only the
///         governance hand-off helper remains (contracts/test/scripts/DeployLiveGovernance.t.sol).
contract DeployNewBLSModules is Script {
    /// @notice Retired from 5.5.0. A plain `new` in a script ships whatever profile compiled
    ///         that script, and this file was compiled under the runs=200 "registry-size"
    ///         profile: it would deploy the .registry-size BLSAggregator/DVTValidator, not
    ///         the profile.default (runs=500) bytes the tests and size evidence measure.
    ///         Deploy through DeployLive / UpgradeLive (DefaultArtifacts._deployDefault).
    function run() external pure {
        revert("DeployNewBLSModules: retired since 5.5.0 (ships runs=200 bytecode); use DeployLive/UpgradeLive");
    }

    /// @dev The governance owner to hand BLSAggregator + DVTValidator to. Reads the
    ///      GOVERNANCE_OWNER gate; virtual only so a test harness can supply it without
    ///      mutating the process environment (vm.setEnv races other suites under parallel forge).
    function _governanceOwner() internal view virtual returns (address) {
        return GovernanceOwnerGate.declaredGovernanceOwner();
    }

    function _settleGovernance(BLSAggregator bls, DVTValidator dvt) internal {
        address gov = _governanceOwner();
        if (gov == address(0)) return;

        bls.transferOwnership(gov);
        dvt.transferOwnership(gov);
        require(dvt.owner() == bls.owner(), "DeployNewBLSModules: DVT owner != BLS owner");
    }
}
