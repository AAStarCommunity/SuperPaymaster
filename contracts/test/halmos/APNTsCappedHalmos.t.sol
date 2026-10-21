// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import { APNTsCapped } from "src/tokens/APNTsCapped.sol";
import { HalmosBase } from "./HalmosSVM.sol";

/**
 * @title D5c-1 CAP-1 — bounded symbolic verification of APNTsCapped's supply cap (Halmos).
 * @notice Formal statement (inductive step, docs/design/aoa-balance-mode/D5c-1-halmos.md §CAP-1):
 *         for EVERY storage state of the token (all slots symbolic) in which the sender's balance
 *         does not exceed totalSupply (the ERC20 well-formedness that OZ's unchecked burn relies
 *         on), and for ONE arbitrary call (every selector of APNTsCapped, views included, plus the
 *         empty / fallback-shaped calldata) from an arbitrary sender:
 *           (a) supplyAfter <= supplyBefore  OR  supplyAfter <= capAfter;
 *           (b) supplyAfter > supplyBefore  ==>  selector == mint  AND  sender == minterBefore;
 *           (c) supplyAfter > supplyBefore  ==>  capAfter == capBefore (a mint never moves the cap).
 *         lowerCap may leave cap < supply; (a) then forces supply not to increase.
 * @dev    `check_*` functions are run by Halmos only; forge ignores them (not `test*`).
 *         Each assertion is its own `check_` so a red result names the assertion unambiguously.
 */
abstract contract APNTsCappedHalmosBase is Test, HalmosBase {
    APNTsCapped internal token;

    function setUp() public {
        // Concrete deployment only fixes code + immutables (EIP-712 domain); every storage slot is
        // made symbolic inside each check, so the constructor values below do not constrain it.
        token = new APNTsCapped("AAStar PNTs", "aPNTs", 300_000 ether, address(0xA11CE), address(0xB0B), address(0xCAFE));
    }

    struct Snap {
        uint256 supply;
        uint256 cap;
        address minter;
    }

    function _snap() internal view returns (Snap memory s) {
        s.supply = token.totalSupply();
        s.cap = token.cap();
        s.minter = token.minter();
    }

    /// @dev One arbitrary call from an arbitrary sender against an arbitrary pre-state.
    function _step() internal returns (Snap memory pre, Snap memory post, address sender, bytes4 sel) {
        svm.enableSymbolicStorage(address(token));
        sender = svm.createAddress("sender");
        bytes memory data = svm.createCalldata("APNTsCapped", true);
        sel = _sel(data);

        pre = _snap();
        // Well-formedness of the pre-state: OZ ERC20 burns with `unchecked { _totalSupply -= v }`
        // after checking only the balance, so a state with balance > totalSupply is unreachable
        // and must be excluded (the only balance a single call can burn is the sender's own).
        vm.assume(token.balanceOf(sender) <= pre.supply);

        vm.prank(sender);
        (bool ok, ) = address(token).call(data);
        ok; // success or revert are both fine: a revert leaves the state unchanged
        post = _snap();
    }

}

contract APNTsCappedHalmosTest is APNTsCappedHalmosBase {
    /// CAP-1 (a): supply never ends above the cap unless it did not grow.
    function check_CAP1_a_supplyIncreaseStaysUnderCap() public {
        (Snap memory pre, Snap memory post, , ) = _step();
        assert(post.supply <= pre.supply || post.supply <= post.cap);
    }

    /// CAP-1 (b): supply grows only through mint, called by the minter.
    function check_CAP1_b_onlyMinterMintIncreasesSupply() public {
        (Snap memory pre, Snap memory post, address sender, bytes4 sel) = _step();
        if (post.supply > pre.supply) {
            assert(sel == APNTsCapped.mint.selector && sender == pre.minter);
        }
    }

    /// CAP-1 (c): a supply-increasing call never moves the cap in the same step.
    function check_CAP1_c_mintDoesNotMoveCap() public {
        (Snap memory pre, Snap memory post, , ) = _step();
        if (post.supply > pre.supply) {
            assert(post.cap == pre.cap);
        }
    }
}

/// Reachability witness for CAP-1 (expected to be REFUTED by Halmos): a supply increase is
/// reachable in this harness, so the antecedents of CAP-1 (b) / (c) are not vacuous.
contract APNTsCappedWitnessHalmosTest is APNTsCappedHalmosBase {
    function check_witness_CAP1_supplyCanIncrease() public {
        (Snap memory pre, Snap memory post, , ) = _step();
        assert(!(post.supply > pre.supply));
    }
}
