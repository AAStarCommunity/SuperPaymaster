// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
contract StateGasProbe {
    event Checkpoint(uint256 beforeGas, uint256 afterGas);
    function test_stateGasClear() public {
        uint256 a;
        uint256 b;
        assembly {
            sstore(0, 1)
            a := gas()
            sstore(0, 0)
            b := gas()
        }
        emit Checkpoint(a, b);
    }
}
