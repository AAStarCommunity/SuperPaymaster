// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import { xPNTsTokenV2 } from "src/tokens/v2/xPNTsTokenV2.sol";
import { IxPNTsTokenV2 } from "src/tokens/v2/IxPNTsTokenV2.sol";
import { V2TokenDeployer, IxPNTsV2Admin } from "../helpers/V2TokenDeployer.sol";
import { MockRegistryV2, DummySpender, IExt } from "../helpers/V2TestFixtures.sol";
import { XPNTsV2HalmosBase } from "./XPNTsV2Halmos.t.sol";
import { XPNTsV2HalmosProbe } from "./XPNTsV2HalmosProbe.sol";

/**
 * @title D5c-1 fuzz coverage of the partitions Halmos could not close within its bound.
 * @notice For each such partition (I2 core: tryLockForGas, settleLocked, transferFrom,
 *         burn(address,uint256); I2 ext: see D5c-1-halmos.md §3.3) this runs the REAL token code on
 *         fuzzed concrete states and evaluates the Halmos harness's OWN predicate bitmask
 *         (XPNTsV2HalmosProbe) on the step; it must be 0. This is "fuzz only" evidence for those
 *         partitions (10,000 runs each), not a symbolic proof.
 */
contract D5c1BoundedFuzzTest is Test {
    address internal sp = address(0x5B);
    address internal owner_ = address(0xC0);
    address internal user = address(0xB0B);
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

    function _token(uint256 rate, uint256 bal) internal {
        tok = V2TokenDeployer.newToken(st, owner_, address(0xC1), sp, rate);
        IxPNTsV2Admin(address(tok)).mint(user, bal);
        vm.prank(owner_);
        IExt(address(tok)).proposeSpender(address(spender));
        vm.warp(block.timestamp + 48 hours);
        IExt(address(tok)).activateSpender(address(spender));
    }

    function _ctx(address e, address sender, bytes32 h, bytes4 sel, address userArg, uint256 w1, uint256 w2, uint256 w3)
        internal view returns (XPNTsV2HalmosBase.Ctx memory c)
    {
        c.v = user; c.e = e; c.sender = sender; c.h = h; c.sel = sel; c.userArg = userArg;
        c.w1 = w1; c.w2 = w2; c.w3 = w3;
    }

    function _caps(uint256 capSp, uint256 capTotal) internal {
        vm.startPrank(user);
        IxPNTsV2Admin(address(tok)).setAutoAllowance(sp, bound(capSp, 250 ether, 50_000 ether));
        IxPNTsV2Admin(address(tok)).setUserTotalCap(bound(capTotal, 250 ether, 50_000 ether));
        vm.stopPrank();
    }

    /// I2 core / tryLockForGas (Halmos: solver TIMEOUT at 15 min, 960 paths)
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_D5c1_I2_tryLockForGas(uint256 rate, uint256 capSp, uint256 capTotal, uint256 pre, uint256 a, bool renew)
        public
    {
        _token(bound(rate, 1e14, 1e22), 1e30);
        _caps(capSp, capTotal);
        pre = bound(pre, 0, 6_000 ether);
        if (pre > 0) {
            vm.prank(sp);
            tok.tryLockForGas(user, keccak256("pre"), pre, false); // may be rejected; either way a real pre-state
        }
        a = bound(a, 0, 6_000 ether);
        bytes32 h = keccak256(abi.encode(a, renew));
        XPNTsV2HalmosBase.Ctx memory c =
            _ctx(sp, sp, h, xPNTsTokenV2.tryLockForGas.selector, user, uint256(h), a, renew ? 1 : 0);
        XPNTsV2HalmosBase.S memory s0 = probe.snapOf(address(tok), c);
        vm.prank(sp);
        (bool ok, ) = address(tok).call(abi.encodeCall(xPNTsTokenV2.tryLockForGas, (user, h, a, renew)));
        c.ok = ok;
        assertEq(probe.i2Bits(s0, probe.snapOf(address(tok), c), c), 0, "I2 bitmask on tryLockForGas");
    }

    /// I2 core / settleLocked (Halmos: solver TIMEOUT at 56 min, 575 paths); also A-3 / A3x bitmasks
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_D5c1_I2_settleLocked(uint256 rate, uint256 a, uint256 charge, bool renew) public {
        _token(bound(rate, 1e14, 1e22), 1e30);
        a = bound(a, 0, 5_000 ether);
        charge = bound(charge, 0, 10_000 ether);
        bytes32 h = keccak256(abi.encode(a, charge));
        vm.prank(sp);
        tok.tryLockForGas(user, h, a, renew);
        XPNTsV2HalmosBase.Ctx memory c =
            _ctx(sp, sp, h, xPNTsTokenV2.settleLocked.selector, user, uint256(h), charge, 0);
        XPNTsV2HalmosBase.S memory s0 = probe.snapOf(address(tok), c);
        vm.prank(sp);
        (bool ok, ) = address(tok).call(abi.encodeCall(xPNTsTokenV2.settleLocked, (user, h, charge)));
        c.ok = ok;
        XPNTsV2HalmosBase.S memory s1 = probe.snapOf(address(tok), c);
        assertEq(probe.i2Bits(s0, s1, c), 0, "I2 bitmask on settleLocked");
        assertEq(probe.a3Bits(s0, s1, c), 0, "A-3 bitmask on settleLocked");
        assertEq(probe.a3xBits(s0, s1, c), 0, "A3x exact bound on settleLocked");
    }

    /// I2 core+ext / transferFrom (Halmos: 60-min wall cap)
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_D5c1_I2_transferFrom(uint256 rate, uint256 cap, uint256 approved, uint256 value, uint256 preLock)
        public
    {
        _token(bound(rate, 1e14, 1e22), 1e27);
        vm.startPrank(user);
        IxPNTsV2Admin(address(tok)).setAutoAllowance(address(spender), bound(cap, 0, 50_000 ether) < 250 ether ? 0 : bound(cap, 250 ether, 50_000 ether));
        tok.approve(address(spender), bound(approved, 0, 1e24));
        vm.stopPrank();
        preLock = bound(preLock, 0, 5_000 ether);
        if (preLock > 0) {
            vm.prank(sp);
            tok.tryLockForGas(user, keccak256("pl"), preLock, false);
        }
        value = bound(value, 0, 6_000 ether); // around the caps and maxSingleTxLimit
        XPNTsV2HalmosBase.Ctx memory c = _ctx(address(spender), address(spender), bytes32(0),
            xPNTsTokenV2.transferFrom.selector, user, uint256(uint160(address(spender))), value, 0);
        XPNTsV2HalmosBase.S memory s0 = probe.snapOf(address(tok), c);
        vm.prank(address(spender));
        (bool ok, ) = address(tok).call(abi.encodeCall(xPNTsTokenV2.transferFrom, (user, address(spender), value)));
        c.ok = ok;
        assertEq(probe.i2Bits(s0, probe.snapOf(address(tok), c), c), 0, "I2 bitmask on transferFrom");
    }

    /// I2 core / burn(address,uint256) (Halmos: 60-min wall cap)
    /// forge-config: default.fuzz.runs = 10000
    function testFuzz_D5c1_I2_burnFrom(uint256 rate, uint256 cap, uint256 approved, uint256 value) public {
        _token(bound(rate, 1e14, 1e22), 1e27);
        vm.startPrank(user);
        IxPNTsV2Admin(address(tok)).setAutoAllowance(address(spender), bound(cap, 250 ether, 50_000 ether));
        tok.approve(address(spender), bound(approved, 0, 1e24));
        vm.stopPrank();
        value = bound(value, 0, 6_000 ether); // around the caps and maxSingleTxLimit
        XPNTsV2HalmosBase.Ctx memory c = _ctx(address(spender), address(spender), bytes32(0),
            bytes4(keccak256("burn(address,uint256)")), user, value, 0, 0);
        XPNTsV2HalmosBase.S memory s0 = probe.snapOf(address(tok), c);
        vm.prank(address(spender));
        (bool ok, ) = address(tok).call(abi.encodeWithSignature("burn(address,uint256)", user, value));
        c.ok = ok;
        assertEq(probe.i2Bits(s0, probe.snapOf(address(tok), c), c), 0, "I2 bitmask on burn(from)");
    }
}
