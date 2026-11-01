// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "./SuperPaymasterPostOpGasProfile.t.sol";

/// @dev One fresh deployment per sample; no snapshot/release/re-admit lifecycle.
abstract contract TupleBoundary is PostOpProfileFixture {
    using SuperPaymasterAdminCalls for SuperPaymaster;
    function test_tuple_boundary() public {
        uint256 budget = vm.envOr("TUPLE_DIRECT_GAS", uint256(470000));
        bool expected = vm.envOr("TUPLE_EXPECT_SUCCESS", true);
        bool realEP = vm.envOr("TUPLE_REAL_EP", false);
        (SuperPaymasterStorage.GasParams memory g,) = sp.gasParams();
        assertEq(g.minPostOpGas, GasFixture.MIN_POST());
        assertEq(g.settleGasBound, GasFixture.SETTLE());
        assertEq(g.cPostop, GasFixture.POSTOP());
        bool ok = sample(budget, creditMode(), realEP, false);
        assertEq(ok, expected, "fresh boundary completion");
        if (!ok && !realEP) {
            assertEq(lastDirectRet, abi.encodeWithSelector(SuperPaymasterStorage.PostOpGasTooLow.selector), "guard, not OOG");
        }
        emit log_named_uint("boundary budget", budget);
        emit log_named_uint("boundary complete", ok ? 1 : 0);
    }
}

contract TupleBalanceTest is TupleBoundary {
    function creditMode() internal pure override returns (bool) { return false; }
}
contract TupleCreditTest is TupleBoundary {
    function creditMode() internal pure override returns (bool) { return true; }
}
