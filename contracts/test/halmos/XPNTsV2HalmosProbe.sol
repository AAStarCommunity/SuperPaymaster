// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import { xPNTsTokenV2 } from "src/tokens/v2/xPNTsTokenV2.sol";
import { XPNTsV2HalmosBase, SymTierSource } from "./XPNTsV2Halmos.t.sol";

/**
 * @dev Concrete companion of the Halmos harness: evaluates the harness's OWN raw-slot snapshot and
 *      OWN predicate bitmasks on a real (concrete) token, so D5c1ReplayTest can (1) cross-check every
 *      storage-slot formula against the public getters and (2) replay a counterexample concretely and
 *      read which predicate bit is violated. Not a test contract: it has no test_/check_ function.
 */
contract XPNTsV2HalmosProbe is XPNTsV2HalmosBase {
    function snapOf(address token, Ctx memory c) external returns (S memory) {
        tok = xPNTsTokenV2(token);
        return _snap(c);
    }

    /// The harness's priming, run on a concrete token (used by D5c1PrimingTest).
    function primeLockOn(address token, Ctx memory c, address sp0) external {
        tok = xPNTsTokenV2(token);
        _primeLock(c, sp0);
    }

    function primeCreditOn(address token, address tierSrc, Ctx memory c, address sp0) external {
        tok = xPNTsTokenV2(token);
        tier = SymTierSource(tierSrc);
        _primeCredit(c, sp0);
    }

    function a3Bits(S memory a, S memory b, Ctx memory c) external pure returns (uint256) {
        return _a3bits(a, b, c);
    }

    function a3xBits(S memory a, S memory b, Ctx memory c) external pure returns (uint256) {
        return _a3xbits(a, b, c);
    }

    function i2Bits(S memory a, S memory b, Ctx memory c) external pure returns (uint256) {
        F memory f = _flags(a, c);
        return _i2counters(a, b, c, f) | _i2pull(a, b, c, f) | _i2create(a, b, c, f) | _i2reset(a, b, f);
    }

    function i6Bits(S memory a, S memory b, Ctx memory c) external pure returns (uint256) {
        return _i6bits(a, b, c);
    }

    function i6jBits(S memory b, uint256 bnd) external pure returns (uint256) {
        return _i6jbits(b, bnd);
    }
}
