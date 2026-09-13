// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import { xPNTsTokenV2 } from "src/tokens/v2/xPNTsTokenV2.sol";
import { V2TokenDeployer, IxPNTsV2Admin } from "../helpers/V2TokenDeployer.sol";
import { MockRegistryV2 } from "../helpers/V2TestFixtures.sol";

/**
 * @title Lemma M (mint auto-repay never lowers the recipient's balance).
 * @notice xPNTsV2Base._update (mint with debt): mintedA = m*1e18/r (floor), repayA = min(mintedA, debt),
 *         repayX = ceil(repayA*r/1e18), the recipient gains m and loses repayX. Lemma: repayX <= m,
 *         i.e. the recipient's balance never decreases. The mint partitions of the A-3 / I2 / I6
 *         checks time out on exactly this non-linear fact (D5c-1-halmos.md §3.2); it is discharged
 *         here (1) symbolically on the isolated arithmetic, with r in the proven range R, and
 *         (2) by a forge fuzz test on the REAL token code path.
 */
contract MintRepayLemmaHalmosTest is Test {
    /// Halmos: the arithmetic in isolation (same operations and rounding as xPNTsV2Base.sol:240-247).
    function check_LEMMA_M_repayNeverExceedsMint(uint256 m, uint256 r, uint256 debt) public pure {
        vm.assume(r >= 1e14 && r <= 1e22);           // invariant R
        vm.assume(m <= type(uint256).max / 1e18);    // else the contract's checked m*1e18 reverts
        uint256 mintedA = (m * 1e18) / r;
        vm.assume(mintedA > 0 && debt > 0);          // the repay branch
        uint256 repayA = mintedA > debt ? debt : mintedA;
        vm.assume(repayA <= type(uint256).max / r);  // else the contract's checked repayA*r reverts
        vm.assume(repayA * r <= type(uint256).max - 1e18); // else its checked `+ 1e18` reverts
        uint256 repayX = (repayA * r + 1e18 - 1) / 1e18;
        assert(repayX <= m);
    }

    // The same lemma split into three standard bit-vector facts (modular proof: each step is a
    // separate check, and the next one only assumes what the previous one proved).
    //   M1  q = n / r            ==>  q * r <= n                   (floor division)
    //   M2  a <= q, q*r no ovf   ==>  a * r <= q * r               (monotone product)
    //   M3  x <= m * 1e18        ==>  ceil(x / 1e18) <= m          (division by a constant)
    // With n = m*1e18, q = mintedA, a = repayA, x = repayA*r:  repayX = ceil(x/1e18) <= m.
    function check_LEMMA_M1_floorDivTimesDivisor(uint256 n, uint256 r) public pure {
        vm.assume(r >= 1e14 && r <= 1e22);
        uint256 q = n / r;
        uint256 p;
        unchecked { p = q * r; }
        assert(q <= type(uint256).max / r && p <= n);
    }

    function check_LEMMA_M2_monotoneProduct(uint256 a, uint256 q, uint256 r) public pure {
        vm.assume(r >= 1e14 && r <= 1e22);
        vm.assume(a <= q && q <= type(uint256).max / r);
        uint256 pa;
        uint256 pq;
        unchecked { pa = a * r; pq = q * r; }
        assert(pa <= pq);
    }

    function check_LEMMA_M3_ceilDivByConstant(uint256 x, uint256 m) public pure {
        vm.assume(m <= type(uint256).max / 1e18);
        vm.assume(x <= m * 1e18);
        vm.assume(x <= type(uint256).max - 1e18); // the contract evaluates (x + 1e18) - 1, checked
        assert((x + 1e18 - 1) / 1e18 <= m);
    }
}

contract MintRepayLemmaFuzzTest is Test {
    address internal sp = address(0x5B);
    address internal owner_ = address(0xC0);
    address internal user = address(0xB0B);
    MockRegistryV2 internal registry;
    V2TokenDeployer.Stack internal st;

    function setUp() public {
        registry = new MockRegistryV2();
        st = V2TokenDeployer.deployStack(sp, address(registry));
    }

    /// Real token path: build a debt through the credit flow, then mint; the balance never drops.
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_D5c1_lemmaM_mintWithDebtNeverLowersBalance(uint256 rate, uint256 debtA, uint256 m) public {
        rate = bound(rate, 1e14, 1e22);
        debtA = bound(debtA, 1, 5_000 ether);
        m = bound(m, 1, 1e30);
        xPNTsTokenV2 t = V2TokenDeployer.newToken(st, owner_, address(0xC1), sp, rate);
        registry.setCreditLimit(user, 50_000 ether);
        vm.prank(owner_);
        IxPNTsV2Admin(address(t)).queueCreditPolicy(2);
        vm.warp(block.timestamp + 48 hours);
        IxPNTsV2Admin(address(t)).executeCreditPolicy();
        vm.prank(user);
        IxPNTsV2Admin(address(t)).requestCredit(debtA);
        vm.startPrank(sp);
        t.tryReserveCredit(user, keccak256("d"), debtA);
        t.settleCredit(user, keccak256("d"), debtA);
        vm.stopPrank();
        assertEq(t.debts(user), debtA);
        uint256 b0 = t.balanceOf(user);
        IxPNTsV2Admin(address(t)).mint(user, m); // test contract = FACTORY
        assertGe(t.balanceOf(user), b0, "lemma M: mint never lowers the recipient's balance");
        assertLe(t.debts(user), debtA, "debt only falls");
    }
}
