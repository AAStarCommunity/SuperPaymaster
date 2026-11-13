// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {BLSAggregator} from "src/modules/monitoring/BLSAggregator.sol";
import {BLS} from "src/utils/BLS.sol";

/// @dev Aggregator-only suites impersonate their configured DVT at the key-verification
///      boundary. DVT_BLS and BLSPermissionlessRegistration exercise the real gateway,
///      including caller authorization and suspension. Preserve recurrent test pranks.
abstract contract BLSRegistrationTestHelper is Test {
    function _registerKey(
        BLSAggregator aggregator,
        address dvtCaller,
        address validator,
        BLS.G1Point memory key,
        uint8 slot,
        BLS.G2Point memory pop
    ) internal {
        (VmSafe.CallerMode mode, address sender, address origin) = vm.readCallers();
        vm.stopPrank();
        vm.prank(dvtCaller);
        aggregator.registerBLSPublicKey(validator, key, slot, pop);
        if (mode == VmSafe.CallerMode.RecurrentPrank) vm.startPrank(sender, origin);
    }
}
