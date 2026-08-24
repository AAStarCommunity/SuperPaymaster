// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import {Vm} from "forge-std/Vm.sol";

/**
 * @title MockedPrecompiles
 * @notice CC-48 round-3 MEDIUM-5: one place that decides whether a test suite may
 *         inject fake EIP-2537 curve precompiles, and skips the suite when it may not.
 *
 * @dev Background. Most of this repo's BLS suites test bookkeeping around the curve —
 *      slot assignment, duplicate keys, exit state machines, slash accounting — and
 *      stub 0x0b/0x0c/0x0d/0x10/0x11 with `vm.etch` so synthetic keys validate. Under
 *      `forge test --evm-version prague` those addresses are REAL precompiles and
 *      `vm.etch` refuses to overwrite them, so every such suite failed at `setUp` with
 *      "cannot use precompile ... as an argument". Fifteen failures sat in the release
 *      gate, which made "the Prague command is green" an unavailable statement.
 *
 *      These are harness failures, not defects — but a failing gate cannot distinguish
 *      the two, so the suites now step aside on Prague and say why. What they cover is
 *      NOT lost: `contracts/test/paper7/` runs the same exit / cap / slash / domain
 *      paths against the genuine precompiles with genuine keys and signatures
 *      (RepCreditDomainReplay, RepCreditPragueE2E, CC48PragueStateMachine), so on
 *      Prague those paths are covered by real pairings rather than by a mock's opinion.
 *
 *      Usage — first line of `setUp()`:
 *          if (MockedPrecompiles.skipIfReal()) return;
 *          ... existing vm.etch calls ...
 */
library MockedPrecompiles {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant G1ADD = address(0x0b);
    address internal constant G1MSM = address(0x0c);
    address internal constant G2ADD = address(0x0d);
    address internal constant PAIRING = address(0x0f);
    address internal constant MAP_FP_TO_G1 = address(0x10);
    address internal constant MAP_FP2_TO_G2 = address(0x11);

    /// @notice True when the EVM under test really implements EIP-2537.
    /// @dev Probes G1ADD with two 128-byte identity points: a real precompile returns
    ///      128 bytes, an absent one returns empty.
    function praguePrecompilesAvailable() internal view returns (bool) {
        bytes memory twoIdentities = new bytes(256);
        (bool ok, bytes memory result) = G1ADD.staticcall(twoIdentities);
        return ok && result.length == 128;
    }

    /// @notice Skip the calling test (or the whole suite, when called from `setUp`)
    ///         if precompile injection is impossible here.
    /// @return skipped true when the caller should return immediately.
    function skipIfReal() internal returns (bool skipped) {
        if (!praguePrecompilesAvailable()) return false;
        VM.skip(true);
        return true;
    }
}
