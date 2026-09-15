// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import { xPNTsTokenV2 } from "src/tokens/v2/xPNTsTokenV2.sol";
import { IxPNTsTokenV2 } from "src/tokens/v2/IxPNTsTokenV2.sol";
import { V2TokenDeployer, IxPNTsV2Admin } from "../helpers/V2TokenDeployer.sol";
import { MockRegistryV2, DummySpender, IExt } from "../helpers/V2TestFixtures.sol";
import { XPNTsV2HalmosBase } from "./XPNTsV2Halmos.t.sol";
import { XPNTsV2HalmosProbe } from "./XPNTsV2HalmosProbe.sol";

interface IxPNTsDailyCap {
    function setSpenderDailyCapFor(address spender, uint256 newCap) external;
}

/**
 * @title D5c-1 fuzz coverage of the partitions Halmos could not close within its bound.
 * @notice For each such partition (I2 core: tryLockForGas, settleLocked, transferFrom,
 *         burn(address,uint256); I2 ext: transferFrom; I4-B: the lock / settle / mint-with-debt
 *         paths; see D5c-1-halmos.md §3) this runs the REAL token code on fuzzed concrete states and
 *         evaluates the Halmos harness's OWN predicate bitmasks (XPNTsV2HalmosProbe) on the step;
 *         they must be 0. "Fuzz only" evidence for those partitions (10,000 runs each), not a proof.
 *
 *         Input domains (Codex M5): the rate stays inside the PROVEN range R = [1e14, 1e22]; every
 *         other input spans its whole type. maxSingleTxLimit is set to its maximum 50,000e18 and the
 *         spender's daily cap to type(uint128).max, so neither narrows the admitted amounts. Caps are
 *         drawn over the domain the setters accept (a value outside it is rejected by the setter, so
 *         it is not a reachable cap). `_wide` only SHAPES the distribution of a full-width input
 *         (full uint256 / the neighbourhood of the 50,000e18 limit / uint128 boundaries / the top
 *         of uint256), so the fuzzer visits the limits instead of spending its runs on values that
 *         all revert the same way; every value remains reachable. The explicit boundary tests below
 *         pin the exact limit values.
 */
contract D5c1BoundedFuzzTest is Test {
    address internal sp = address(0x5B);
    address internal owner_ = address(0xC0);
    address internal user = address(0xB0B);
    uint256 internal constant LIMIT = 50_000 ether;   // MAX_SINGLE_TX_LIMIT_CAP = PROTOCOL_MAX_CAP
    MockRegistryV2 internal registry;
    V2TokenDeployer.Stack internal st;
    xPNTsTokenV2 internal tok;
    XPNTsV2HalmosProbe internal probe;
    DummySpender internal spender;

    function setUp() public {
        registry = new MockRegistryV2();
        st = V2TokenDeployer.deployStack(sp, address(registry));
        spender = new DummySpender();
        st.aoa.bootstrapApprove(st.aoa.KIND_SPENDER(), address(spender).codehash);
        probe = new XPNTsV2HalmosProbe();
    }

    /// shape a full-width input: mode 0 full uint256; 1 around the 50,000e18 limit (in aPNTs, or in
    /// xPNTs at `rate`); 2 a boundary value; 3 below 2^129. Every value stays reachable.
    function _wide(uint256 x, uint256 mode, uint256 rate) internal pure returns (uint256) {
        mode %= 4;
        if (mode == 0) return x;
        if (mode == 1) {
            uint256 top = (LIMIT + 2) * rate / 1e18 + 2;
            return x % (top + 1);
        }
        if (mode == 2) {
            uint256[10] memory b = [uint256(0), 1, LIMIT - 1, LIMIT, LIMIT + 1, type(uint128).max - 1,
                type(uint128).max, uint256(type(uint128).max) + 1, type(uint256).max - 1, type(uint256).max];
            return b[x % 10];
        }
        return x % (uint256(1) << 129);
    }

    function _token(uint256 rate, uint256 bal) internal {
        tok = V2TokenDeployer.newToken(st, owner_, address(0xC1), sp, rate);
        vm.startPrank(owner_);
        IxPNTsV2Admin(address(tok)).setMaxSingleTxLimit(LIMIT);
        IxPNTsDailyCap(address(tok)).setSpenderDailyCapFor(address(spender), type(uint128).max);
        IExt(address(tok)).proposeSpender(address(spender));
        vm.stopPrank();
        if (bal > 0) IxPNTsV2Admin(address(tok)).mint(user, bal);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        IExt(address(tok)).activateSpender(address(spender));
    }

    function _ctx(address e, address sender, bytes32 h, bytes4 sel, address userArg, uint256 w1, uint256 w2, uint256 w3)
        internal view returns (XPNTsV2HalmosBase.Ctx memory c)
    {
        c.v = user; c.e = e; c.sender = sender; c.h = h; c.sel = sel; c.userArg = userArg;
        c.w1 = w1; c.w2 = w2; c.w3 = w3;
    }

    function _caps(address who, uint256 capSp, uint256 capTotal) internal {
        vm.startPrank(user);
        IxPNTsV2Admin(address(tok)).setAutoAllowance(who, bound(capSp, who == sp ? 250 ether : 0, LIMIT));
        IxPNTsV2Admin(address(tok)).setUserTotalCap(bound(capTotal, 250 ether, LIMIT));
        vm.stopPrank();
    }

    function _bits(XPNTsV2HalmosBase.S memory s0, XPNTsV2HalmosBase.Ctx memory c) internal returns (XPNTsV2HalmosBase.S memory s1) {
        s1 = probe.snapOf(address(tok), c);
        assertEq(probe.i2Bits(s0, s1, c), 0, "I2 bitmask");
        if (s0.bal >= s0.locked) assertEq(probe.i4bBits(s1), 0, "I4-B bitmask");
    }

    /// I2 / I4-B core / tryLockForGas (Halmos: bounded partition)
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_D5c1_I2_tryLockForGas(uint256 rate, uint256 bal, uint256 capSp, uint256 capTotal, uint256 pre,
        uint256 a, uint256 mode, bool renew) public
    {
        rate = bound(rate, 1e14, 1e22);
        bal = _wide(bal, mode >> 8, rate) % (uint256(1) << 255); // leave room for the pre-lock mint below
        _token(rate, bal);
        _caps(sp, capSp, capTotal);
        pre = _wide(pre, mode >> 16, 1e18);
        if (pre > 0) {
            vm.prank(sp);
            tok.tryLockForGas(user, keccak256("pre"), pre, false); // may be rejected; either way a real pre-state
        }
        a = _wide(a, mode, 1e18);
        bytes32 h = keccak256(abi.encode(a, renew));
        XPNTsV2HalmosBase.Ctx memory c =
            _ctx(sp, sp, h, xPNTsTokenV2.tryLockForGas.selector, user, uint256(h), a, renew ? 1 : 0);
        XPNTsV2HalmosBase.S memory s0 = probe.snapOf(address(tok), c);
        vm.prank(sp);
        (bool ok, ) = address(tok).call(abi.encodeCall(xPNTsTokenV2.tryLockForGas, (user, h, a, renew)));
        c.ok = ok;
        _bits(s0, c);
    }

    /// I2 / A-3 / A3x / I4-B core / settleLocked (Halmos: bounded partition)
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_D5c1_I2_settleLocked(uint256 rate, uint256 bal, uint256 a, uint256 charge, uint256 mode, bool renew) public {
        rate = bound(rate, 1e14, 1e22);
        _token(rate, _wide(bal, mode >> 8, rate));
        vm.startPrank(user);
        IxPNTsV2Admin(address(tok)).setAutoAllowance(sp, LIMIT);
        IxPNTsV2Admin(address(tok)).setUserTotalCap(LIMIT);
        vm.stopPrank();
        a = _wide(a, mode, 1e18);
        charge = _wide(charge, mode >> 16, 1e18);
        bytes32 h = keccak256(abi.encode(a, charge));
        vm.prank(sp);
        tok.tryLockForGas(user, h, a, renew);
        XPNTsV2HalmosBase.Ctx memory c =
            _ctx(sp, sp, h, xPNTsTokenV2.settleLocked.selector, user, uint256(h), charge, 0);
        XPNTsV2HalmosBase.S memory s0 = probe.snapOf(address(tok), c);
        vm.prank(sp);
        (bool ok, ) = address(tok).call(abi.encodeCall(xPNTsTokenV2.settleLocked, (user, h, charge)));
        c.ok = ok;
        XPNTsV2HalmosBase.S memory s1 = _bits(s0, c);
        assertEq(probe.a3Bits(s0, s1, c), 0, "A-3 bitmask on settleLocked");
        assertEq(probe.a3xBits(s0, s1, c), 0, "A3x exact bound on settleLocked");
    }

    /// I2 core+ext / transferFrom (Halmos: bounded partition): explicit half, auto half, both
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_D5c1_I2_transferFrom(uint256 rate, uint256 bal, uint256 cap, uint256 approved, uint256 value,
        uint256 preLock, uint256 mode) public
    {
        rate = bound(rate, 1e14, 1e22);
        _token(rate, _wide(bal, mode >> 8, rate));
        _caps(address(spender), cap, LIMIT);
        vm.prank(user);
        tok.approve(address(spender), _wide(approved, mode >> 16, rate));
        preLock = _wide(preLock, mode >> 24, 1e18);
        if (preLock > 0) {
            vm.prank(sp);
            tok.tryLockForGas(user, keccak256("pl"), preLock, false);
        }
        value = _wide(value, mode, rate);
        XPNTsV2HalmosBase.Ctx memory c = _ctx(address(spender), address(spender), bytes32(0),
            xPNTsTokenV2.transferFrom.selector, user, uint256(uint160(address(spender))), value, 0);
        XPNTsV2HalmosBase.S memory s0 = probe.snapOf(address(tok), c);
        vm.prank(address(spender));
        (bool ok, ) = address(tok).call(abi.encodeCall(xPNTsTokenV2.transferFrom, (user, address(spender), value)));
        c.ok = ok;
        _bits(s0, c);
    }

    /// I2 core / burn(address,uint256) (Halmos: bounded partition)
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_D5c1_I2_burnFrom(uint256 rate, uint256 bal, uint256 cap, uint256 approved, uint256 value, uint256 mode) public {
        rate = bound(rate, 1e14, 1e22);
        _token(rate, _wide(bal, mode >> 8, rate));
        _caps(address(spender), cap, LIMIT);
        vm.prank(user);
        tok.approve(address(spender), _wide(approved, mode >> 16, rate));
        value = _wide(value, mode, rate);
        XPNTsV2HalmosBase.Ctx memory c = _ctx(address(spender), address(spender), bytes32(0),
            bytes4(keccak256("burn(address,uint256)")), user, value, 0, 0);
        XPNTsV2HalmosBase.S memory s0 = probe.snapOf(address(tok), c);
        vm.prank(address(spender));
        (bool ok, ) = address(tok).call(abi.encodeWithSignature("burn(address,uint256)", user, value));
        c.ok = ok;
        _bits(s0, c);
    }

    /// I4-B ext / mint with automatic debt repayment while the recipient's balance is FULLY locked
    /// (balance == lockedOf): the tightest case for the lock check of the repay burn.
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_D5c1_I4B_mintWithDebt(uint256 rate, uint256 reserve, uint256 debtA, uint256 m, uint256 mode) public {
        rate = bound(rate, 1e14, 1e22);
        _token(rate, 0);
        reserve = bound(reserve, 1, LIMIT);
        uint256 x = (reserve * rate + 1e18 - 1) / 1e18;           // the lock's escrow at this rate
        IxPNTsV2Admin(address(tok)).mint(user, x);                 // no debt yet: plain mint
        vm.startPrank(user);
        IxPNTsV2Admin(address(tok)).setAutoAllowance(sp, LIMIT);
        IxPNTsV2Admin(address(tok)).setUserTotalCap(LIMIT);
        vm.stopPrank();
        vm.prank(sp);
        tok.tryLockForGas(user, keccak256("lk"), reserve, false);
        assertEq(tok.lockedOf(user), tok.balanceOf(user), "fully locked");
        debtA = bound(debtA, 1, LIMIT);
        registry.setCreditLimit(user, LIMIT);
        vm.prank(owner_);
        IxPNTsV2Admin(address(tok)).queueCreditPolicy(2);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        IxPNTsV2Admin(address(tok)).executeCreditPolicy();
        vm.prank(user);
        IxPNTsV2Admin(address(tok)).requestCredit(debtA);
        vm.startPrank(sp);
        tok.tryReserveCredit(user, keccak256("d"), debtA);
        tok.settleCredit(user, keccak256("d"), debtA);
        vm.stopPrank();
        m = _wide(m, mode, rate);
        XPNTsV2HalmosBase.Ctx memory c = _ctx(sp, address(this), bytes32(0), bytes4(keccak256("mint(address,uint256)")),
            user, m, 0, 0);
        XPNTsV2HalmosBase.S memory s0 = probe.snapOf(address(tok), c);
        (bool ok, ) = address(tok).call(abi.encodeWithSignature("mint(address,uint256)", user, m));
        c.ok = ok;
        XPNTsV2HalmosBase.S memory s1 = probe.snapOf(address(tok), c);
        assertEq(probe.i4bBits(s1), 0, "I4-B bitmask on mint with debt");
        assertGe(s1.bal, s0.bal, "lemma M: the recipient's balance never drops");
        if (!ok) assertEq(abi.encode(s0), abi.encode(s1), "a failed mint changes nothing");
    }

    // ---------------------------------------------------------------- explicit boundary cases

    /// the 50,000e18 single-tx limit at the maximum rate: the largest lock is exact (5e26 < 2^128),
    /// one wei above the limit is rejected; I2 / I4-B bitmasks are 0 on every step
    function test_D5c1_boundary_lockAtTheLimitMaxRate() public {
        _token(1e22, 5e26 + 10);
        _caps(sp, LIMIT, LIMIT);
        for (uint256 i = 0; i < 2; i++) {
            uint256 a = LIMIT + i;
            bytes32 h = keccak256(abi.encode("b", i));
            XPNTsV2HalmosBase.Ctx memory c = _ctx(sp, sp, h, xPNTsTokenV2.tryLockForGas.selector, user, uint256(h), a, 0);
            XPNTsV2HalmosBase.S memory s0 = probe.snapOf(address(tok), c);
            vm.prank(sp);
            (IxPNTsTokenV2.LockResult r, uint256 x) = tok.tryLockForGas(user, h, a, false);
            c.ok = true;
            _bits(s0, c);
            if (i == 0) {
                assertEq(uint8(r), uint8(IxPNTsTokenV2.LockResult.OK));
                assertEq(x, 5e26);
                assertEq(uint256(tok.lockOf(h, user).xLocked), 5e26, "no truncation at the limit");
                c = _ctx(sp, sp, h, xPNTsTokenV2.settleLocked.selector, user, uint256(h), type(uint256).max, 0);
                s0 = probe.snapOf(address(tok), c);
                vm.prank(sp);
                tok.settleLocked(user, h, type(uint256).max);   // charge clamped to a0
                c.ok = true;
                XPNTsV2HalmosBase.S memory s1 = _bits(s0, c);
                assertEq(probe.a3xBits(s0, s1, c), 0);
                assertEq(tok.lockedOf(user), 0);
            } else {
                assertEq(uint8(r), uint8(IxPNTsTokenV2.LockResult.SINGLE_TX_LIMIT), "limit + 1 rejected");
            }
        }
    }

    /// uint128 boundaries of the counters / records: amounts at 2^128 - 1, 2^128, 2^128 + 1 are
    /// rejected by the single-tx limit (locks, reservations) or by the auto cap (pulls) — they can never
    /// reach a uint128 cast; bitmasks 0
    function test_D5c1_boundary_uint128Amounts() public {
        _token(1e14, type(uint256).max / 2);
        _caps(address(spender), LIMIT, LIMIT);
        uint256[3] memory v = [uint256(type(uint128).max), uint256(type(uint128).max) + 1, uint256(type(uint128).max) + 2];
        for (uint256 i = 0; i < 3; i++) {
            bytes32 h = keccak256(abi.encode("u128", i));
            XPNTsV2HalmosBase.Ctx memory c = _ctx(sp, sp, h, xPNTsTokenV2.tryLockForGas.selector, user, uint256(h), v[i], 0);
            XPNTsV2HalmosBase.S memory s0 = probe.snapOf(address(tok), c);
            vm.prank(sp);
            (IxPNTsTokenV2.LockResult r, ) = tok.tryLockForGas(user, h, v[i], false);
            c.ok = true;
            _bits(s0, c);
            assertEq(uint8(r), uint8(IxPNTsTokenV2.LockResult.SINGLE_TX_LIMIT));
            c = _ctx(address(spender), address(spender), bytes32(0), xPNTsTokenV2.transferFrom.selector, user,
                uint256(uint160(address(spender))), v[i], 0);
            s0 = probe.snapOf(address(tok), c);
            vm.prank(address(spender));
            (c.ok, ) = address(tok).call(abi.encodeCall(xPNTsTokenV2.transferFrom, (user, address(spender), v[i])));
            _bits(s0, c);
            assertFalse(c.ok, "an auto pull of >= 2^128 xPNTs at rate 1e14 exceeds every cap");
        }
    }

    /// near-uint256 balance and allowances: balance = 2^256 - 2; an infinite approval is never
    /// debited, a (2^256 - 2) approval is debited exactly; the auto counters never move; bitmasks 0
    function test_D5c1_boundary_nearMaxBalanceAndAllowance() public {
        uint256 big = type(uint256).max - 1;
        _token(1e18, big);
        uint256[2] memory appr = [type(uint256).max, big];
        for (uint256 i = 0; i < 2; i++) {
            vm.prank(user);
            tok.approve(address(spender), appr[i]);
            uint256 val = i == 0 ? big / 2 : tok.balanceOf(user);
            XPNTsV2HalmosBase.Ctx memory c = _ctx(address(spender), address(spender), bytes32(0),
                xPNTsTokenV2.transferFrom.selector, user, uint256(uint160(address(0xDEAD))), val, 0);
            XPNTsV2HalmosBase.S memory s0 = probe.snapOf(address(tok), c);
            vm.prank(address(spender));
            (c.ok, ) = address(tok).call(abi.encodeCall(xPNTsTokenV2.transferFrom, (user, address(0xDEAD), val)));
            _bits(s0, c);
            assertTrue(c.ok, "explicit pull succeeds");
            assertEq(tok.allowance(user, address(spender)), i == 0 ? type(uint256).max : big - val);
        }
        // minting on top of a near-max supply reverts (checked totalSupply), nothing changes
        XPNTsV2HalmosBase.Ctx memory c2 = _ctx(sp, address(this), bytes32(0), bytes4(keccak256("mint(address,uint256)")), user, 2, 0, 0);
        XPNTsV2HalmosBase.S memory t0 = probe.snapOf(address(tok), c2);
        (c2.ok, ) = address(tok).call(abi.encodeWithSignature("mint(address,uint256)", user, 2));
        assertFalse(c2.ok);
        assertEq(abi.encode(t0), abi.encode(probe.snapOf(address(tok), c2)));
    }

    /// the largest successful mint with a debt (m * 1e18 must not overflow): floor(max / 1e18)
    /// succeeds and never lowers the balance; one more reverts and changes nothing
    function test_D5c1_boundary_largestMintWithDebt() public {
        uint256 rate = 1e14;
        _token(rate, 0);
        registry.setCreditLimit(user, LIMIT);
        vm.prank(owner_);
        IxPNTsV2Admin(address(tok)).queueCreditPolicy(2);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        IxPNTsV2Admin(address(tok)).executeCreditPolicy();
        vm.prank(user);
        IxPNTsV2Admin(address(tok)).requestCredit(LIMIT);
        vm.startPrank(sp);
        tok.tryReserveCredit(user, keccak256("d"), LIMIT);
        tok.settleCredit(user, keccak256("d"), LIMIT);
        vm.stopPrank();
        uint256 mMax = type(uint256).max / 1e18;
        (bool bad, ) = address(tok).call(abi.encodeWithSignature("mint(address,uint256)", user, mMax + 1));
        assertFalse(bad, "m * 1e18 overflows: the mint reverts");
        assertEq(tok.balanceOf(user), 0);
        (bool ok, ) = address(tok).call(abi.encodeWithSignature("mint(address,uint256)", user, mMax));
        assertTrue(ok, "the largest mint with debt succeeds");
        assertEq(tok.debts(user), 0, "the whole debt is repaid");
        assertEq(tok.balanceOf(user), mMax - LIMIT * rate / 1e18, "repayX = ceil(debt * rate / 1e18)");
    }
}
