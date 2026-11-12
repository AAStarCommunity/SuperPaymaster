// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Vm} from "forge-std/Vm.sol";
import {SuperPaymaster} from "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import {SuperPaymasterAdminCalls} from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";

import {DeploymentGasFixtures} from "./DeploymentGasFixtures.sol";

/// @notice Accepted 500k release default with explicit historical experiment selectors.
library SelectedGasFixtures {
    using SuperPaymasterAdminCalls for SuperPaymaster;
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    function candidate() internal view returns (bool) { return vm.envOr("TUPLE_CANDIDATE", false) || candidate480(); }
    function candidate480() internal view returns (bool) { return vm.envOr("TUPLE_480", false); }
    // Archived runs are bound to their recorded revisions; reproduce them by checking that revision out.
    function MIN_POST() internal view returns (uint32) { return candidate480() ? 480_000 : candidate() ? 470_000 : DeploymentGasFixtures.MIN_POST; }
    function SETTLE() internal view returns (uint32) { return candidate() ? 450_000 : DeploymentGasFixtures.SETTLE; }
    uint32 internal constant WRAP = 5_000;
    function POSTOP() internal view returns (uint32) { return candidate() ? 450_000 : DeploymentGasFixtures.POSTOP; }
    // Fresh SP + SP_RENEW: 998,865 gas, plus 15%, rounded up to 5,000 (R-AMS-F2 §1.1).
    uint128 internal constant PM_VERIFICATION = ((uint128(998_865) * 115 + 499_999) / 500_000) * 5_000;
    // Fresh hit through SimpleAccount: 114,957 charged gas (diagnostic-traces.log).
    // Account for two 63/64 forwards, add 15%, and round up to 5,000.
    uint128 internal constant FUZZ_SUCCESS_CALL_MIN =
        ((uint128(114_957) * 64 * 64 * 115 + 63 * 63 * 100 * 5_000 - 1)
            / (63 * 63 * 100 * 5_000)) * 5_000;
    // Sweep beyond the deployed floor by 15%; the lower endpoints remain fixed negative controls.
    function SWEEP_MAX() internal view returns (uint256) { return uint256(MIN_POST()) * 115 / 100; }

    /// @dev Caller must already be pranking the owner. Activate before price/time-sensitive setup.
    function configure(SuperPaymaster sp) internal {
        sp.queueGasParams(MIN_POST(), SETTLE(), WRAP, POSTOP());
        vm.warp(vm.getBlockTimestamp() + 48 hours + 1);
        sp.executeGasParams();
    }
}
