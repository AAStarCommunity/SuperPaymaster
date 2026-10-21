// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";

// G-layer probes shared by SuperPaymasterV55Gas.t.sol and SuperPaymasterV55PostOpBound.t.sol
// (kept out of *.t.sol files, see V2TestFixtures.sol).

/// @dev Paymaster whose postOp records the actualGasCost EntryPoint passed it, then burns its
///      frame down to <= BURN_FLOOR gas. The frame therefore consumes (limit - returned) with
///      0 <= returned <= BURN_FLOOR, which pins the postOp frame's own gas and leaves only the
///      EntryPoint's wrapping overhead unknown. Its context has the same length as SP's OpCtx.
contract PostOpProbePaymaster is IPaymaster {
    uint256 public constant BURN_FLOOR = 300;
    uint256 public constant CTX_WORDS = 12; // == SuperPaymaster context: 11 OpCtx words + 1 gas-snapshot word (exp/params)
    uint256 public lastPassedGas;
    uint256 public calls;

    function validatePaymasterUserOp(PackedUserOperation calldata, bytes32, uint256)
        external pure returns (bytes memory context, uint256 validationData)
    {
        context = new bytes(CTX_WORDS * 32);
        context[0] = 0x01; // non-empty so EntryPoint calls postOp
        validationData = 0;
    }

    function postOp(PostOpMode, bytes calldata, uint256 actualGasCost, uint256 feePerGas) external {
        lastPassedGas = actualGasCost / feePerGas;
        calls += 1;
        while (gasleft() > BURN_FLOOR) {}
    }
}

contract GasBurner {
    function burn() external view { while (true) { gasleft(); } }
}

