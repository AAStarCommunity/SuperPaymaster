// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import { APNTsCapped } from "src/tokens/APNTsCapped.sol";
import { xPNTsTokenV2 } from "src/tokens/v2/xPNTsTokenV2.sol";
import { xPNTsV2Base } from "src/tokens/v2/xPNTsV2Base.sol";
import { IxPNTsTokenV2 } from "src/tokens/v2/IxPNTsTokenV2.sol";
import { V2TokenDeployer, IxPNTsV2Admin } from "../helpers/V2TokenDeployer.sol";
import { MockRegistryV2, DummySpender, IExt } from "../helpers/V2TestFixtures.sol";
import { XPNTsV2HalmosBase, SymTierSource } from "./XPNTsV2Halmos.t.sol";
import { XPNTsV2HalmosProbe } from "./XPNTsV2HalmosProbe.sol";
import { xPNTsFactoryV2 } from "src/tokens/v2/xPNTsFactoryV2.sol";
import { XPNTsV2Selectors } from "./XPNTsV2Selectors.sol";

/**
 * @title D5c-1 concrete companions of the Halmos harnesses (plain forge tests).
 * @notice Three jobs (docs/design/aoa-balance-mode/D5c-1-halmos.md §4–§5):
 *   1. SCENARIO tests — one per property, exercising exactly the behaviour each source mutation
 *      targets. Green on the real source; each goes red under its mutation, which proves the
 *      mutation really changes behaviour in the targeted scenario (a red Halmos check under a
 *      mutation is then not an artefact of the abstraction).
 *   2. LAYOUT tests — the raw storage slots the Halmos harness reads with vm.load (ERC20
 *      `_allowances` = slot 1, the ERC-7201 Initializable slot) are the ones the token uses.
 *   3. REPLAYS — every Halmos counterexample (including the reachability witnesses) replayed
 *      with concrete values.
 */
contract D5c1ReplayTest is Test {
    // ---------------------------------------------------------------- xPNTs v2 fixture
    address internal sp = address(0x5B);
    address internal owner_ = address(0xC0);
    address internal community = address(0xC1);
    address internal user = address(0xB0B);
    MockRegistryV2 internal registry;
    V2TokenDeployer.Stack internal st;
    xPNTsTokenV2 internal tok;

    bytes32 internal constant H = keccak256("d5c1.op");

    function setUp() public {
        registry = new MockRegistryV2();
        st = V2TokenDeployer.deployStack(sp, address(registry));
        tok = V2TokenDeployer.newToken(st, owner_, community, sp, 1 ether);
        IxPNTsV2Admin(address(tok)).mint(user, 10_000 ether); // test contract = FACTORY
    }

    function _ext() internal view returns (IxPNTsV2Admin) {
        return IxPNTsV2Admin(address(tok));
    }

    // ================================================================ 1. scenarios

    /// CAP-1 scenario (mutation M-CAP1 removes the cap check in APNTsCapped.mint).
    function test_D5c1_CAP1_scenario_mintBeyondCapReverts() public {
        address minter = address(0xB0B1);
        APNTsCapped a = new APNTsCapped("A", "A", 1_000 ether, address(this), minter, address(0xCAFE));
        vm.prank(minter);
        a.mint(user, 1_000 ether);
        vm.prank(minter);
        vm.expectRevert(abi.encodeWithSelector(APNTsCapped.CapExceeded.selector, 1_000 ether, 1, 1_000 ether));
        a.mint(user, 1);
        assertEq(a.totalSupply(), 1_000 ether, "CAP-1: supply stays at the cap");
        // lowerCap below supply: no mint at all afterwards
        vm.prank(address(0xCAFE));
        a.lowerCap(500 ether);
        vm.prank(minter);
        vm.expectRevert();
        a.mint(user, 1);
        assertEq(a.totalSupply(), 1_000 ether, "CAP-1: cap below supply freezes supply");
    }

    // Each xPNTs scenario first evaluates the Halmos harness's OWN predicate bitmask on the targeted
    // step (via XPNTsV2HalmosProbe) and asserts it is 0; under the matching mutation that assertion
    // is the first to fail and its message shows the bitmask, i.e. WHICH predicate went red.

    function _c(address sender, bytes4 sel, address userArg, bytes32 h, uint256 w2, uint256 w3)
        internal view returns (XPNTsV2HalmosBase.Ctx memory c)
    {
        c.v = user; c.e = sender; c.sender = sender; c.h = h; c.sel = sel; c.userArg = userArg;
        c.w1 = uint256(h); c.w2 = w2; c.w3 = w3;
    }

    /// A-3 scenario (mutation M-A3 adds an SP-callable `spPull(address,uint256)` to the extension).
    function test_D5c1_A3_scenario_spCannotMoveUserTokens() public {
        XPNTsV2HalmosProbe probe = new XPNTsV2HalmosProbe();
        uint256 bal0 = tok.balanceOf(user);
        vm.prank(user);
        tok.approve(sp, type(uint256).max); // even an explicit approval does not help (A-3)
        XPNTsV2HalmosBase.Ctx memory c = _c(sp, bytes4(keccak256("spPull(address,uint256)")), user, bytes32(0), 0, 0);
        XPNTsV2HalmosBase.S memory a = probe.snapOf(address(tok), c);
        vm.prank(sp);
        (c.ok, ) = address(tok).call(abi.encodeWithSignature("spPull(address,uint256)", user, 1 ether));
        XPNTsV2HalmosBase.S memory b = probe.snapOf(address(tok), c);
        assertEq(probe.a3Bits(a, b, c), 0, "A-3 predicate bitmask on the SP pull attempt");
        assertFalse(c.ok, "A-3: no SP pull path exists (extension)");
        vm.startPrank(sp);
        vm.expectRevert(xPNTsV2Base.SPCannotTransfer.selector);
        tok.transferFrom(user, sp, 1 ether);
        vm.expectRevert(xPNTsV2Base.SPCannotTransfer.selector);
        tok.burn(user, 1 ether);
        vm.stopPrank();
        assertEq(tok.balanceOf(user), bal0, "A-3: victim balance untouched");
    }

    /// A-3 bits 0 and 1 separately (mutations M-A3TF / M-A3BF remove the SP firewall from
    /// transferFrom only / burn(address,uint256) only). The SP holds an explicit, unlimited approval,
    /// so without the firewall both calls would succeed. The assertion prints (bits of both attempts)
    /// & 3: M-A3TF must give exactly 1 (bit 0), M-A3BF exactly 2 (bit 1).
    function test_D5c1_A3_scenario_spFirewallBits() public {
        XPNTsV2HalmosProbe probe = new XPNTsV2HalmosProbe();
        vm.prank(user);
        tok.approve(sp, type(uint256).max);
        XPNTsV2HalmosBase.Ctx memory c = _c(sp, xPNTsTokenV2.transferFrom.selector, user, bytes32(0), 1 ether, 0);
        c.w1 = uint256(uint160(address(0xDEAD)));
        XPNTsV2HalmosBase.S memory a = probe.snapOf(address(tok), c);
        vm.prank(sp);
        (c.ok, ) = address(tok).call(abi.encodeCall(xPNTsTokenV2.transferFrom, (user, address(0xDEAD), 1 ether)));
        uint256 bits = probe.a3Bits(a, probe.snapOf(address(tok), c), c);
        c = _c(sp, bytes4(keccak256("burn(address,uint256)")), user, bytes32(0), 0, 0);
        c.w1 = 1 ether;
        a = probe.snapOf(address(tok), c);
        vm.prank(sp);
        (c.ok, ) = address(tok).call(abi.encodeWithSignature("burn(address,uint256)", user, 1 ether));
        bits |= probe.a3Bits(a, probe.snapOf(address(tok), c), c);
        assertEq(bits & 3, 0, "A-3 firewall bits (bit0 transferFrom, bit1 burn(from))");
    }

    /// Spec-vs-code discrepancy D-A3-2 (D5c-1-halmos.md §F), replayed concretely. Spec 03 §2.3 A-3:
    /// burn(address,uint256) is rejected for a current or historical SP caller, always. The code
    /// (xPNTsTokenV2.sol:134, `if (msg.sender != from) _spendV2(...)`) lets an SP burn its OWN
    /// balance through burn(from == itself) — the same as burn(uint256). This test is GREEN on the
    /// code as it is: it documents the behaviour and that the literal A-3 bit 1 is the one violated
    /// (a user's tokens are not affected: the NoSelfBurn bitmask is 0).
    function test_D5c1_DISCREPANCY_A3_2_spBurnsOwnBalance() public {
        XPNTsV2HalmosProbe probe = new XPNTsV2HalmosProbe();
        vm.prank(user);
        tok.transfer(sp, 5 ether);              // an SP can hold xPNTs like anyone else
        assertTrue(tok.historicalSP(sp), "the genesis SP is current and historical");
        XPNTsV2HalmosBase.Ctx memory c = _c(sp, bytes4(keccak256("burn(address,uint256)")), sp, bytes32(0), 0, 0);
        c.w1 = 1 ether;
        XPNTsV2HalmosBase.S memory a = probe.snapOf(address(tok), c);
        uint256 supply0 = tok.totalSupply();
        vm.prank(sp);
        (c.ok, ) = address(tok).call(abi.encodeWithSignature("burn(address,uint256)", sp, 1 ether));
        XPNTsV2HalmosBase.S memory b = probe.snapOf(address(tok), c);
        assertTrue(c.ok, "D-A3-2: burn(address,uint256) by the SP with from == SP succeeds");
        assertEq(tok.balanceOf(sp), 4 ether);
        assertEq(tok.totalSupply(), supply0 - 1 ether);
        assertEq(probe.a3Bits(a, b, c), 2, "exactly the literal A3-2 (bit 1) is violated");
        assertEq(probe.a3BitsNoSelf(a, b, c), 0, "every other A-3 predicate holds (no third party touched)");
        // and a historical (rotated-out) SP likewise
        address sp2 = address(0x5C);
        V2TokenDeployer.approveSP(st, sp2);
        vm.prank(owner_);
        _ext().proposeSP(sp2);
        vm.warp(block.timestamp + 48 hours);
        _ext().activateSP();
        assertTrue(tok.historicalSP(sp) && tok.SUPERPAYMASTER_ADDRESS() == sp2, "sp is now historical only");
        vm.prank(sp);
        (bool ok2, ) = address(tok).call(abi.encodeWithSignature("burn(address,uint256)", sp, 1 ether));
        assertTrue(ok2, "D-A3-2: a historical SP can burn its own balance too");
        vm.prank(sp);
        vm.expectRevert(xPNTsV2Base.SPCannotTransfer.selector);
        tok.burn(user, 1 ether);                // a third party's tokens stay protected
    }

    /// I4 balance conjunct (mutation M-I4B removes the A-1 lock check in _update): with 5,000 xPNTs
    /// locked out of 10,000, a transfer of 6,000 must be rejected (balance would fall below lockedOf).
    function test_D5c1_I4B_scenario_transferBelowLockedRejected() public {
        XPNTsV2HalmosProbe probe = new XPNTsV2HalmosProbe();
        vm.prank(sp);
        tok.tryLockForGas(user, H, 5_000 ether, false);
        assertEq(tok.lockedOf(user), 5_000 ether);
        XPNTsV2HalmosBase.Ctx memory c = _c(user, bytes4(keccak256("transfer(address,uint256)")), address(0xDEAD), bytes32(0), 0, 0);
        vm.prank(user);
        (c.ok, ) = address(tok).call(abi.encodeWithSignature("transfer(address,uint256)", address(0xDEAD), 6_000 ether));
        assertEq(probe.i4bBits(probe.snapOf(address(tok), c)), 0, "I4-B predicate bitmask on the over-lock transfer");
        assertFalse(c.ok, "A-1: the transfer is rejected");
    }

    /// I2 scenario (mutation M-I2 drops the per-(spender,user) remaining-cap check in _lockDecision).
    function test_D5c1_I2_scenario_lockBeyondSpCapRejected() public {
        XPNTsV2HalmosProbe probe = new XPNTsV2HalmosProbe();
        vm.prank(user);
        IxPNTsV2Admin(address(tok)).setAutoAllowance(sp, 250 ether); // SP cap floor
        XPNTsV2HalmosBase.Ctx memory c = _c(sp, xPNTsTokenV2.tryLockForGas.selector, user, H, 251 ether, 0);
        XPNTsV2HalmosBase.S memory a = probe.snapOf(address(tok), c);
        vm.prank(sp);
        (IxPNTsTokenV2.LockResult r, ) = tok.tryLockForGas(user, H, 251 ether, false);
        c.ok = true;
        XPNTsV2HalmosBase.S memory b = probe.snapOf(address(tok), c);
        assertEq(probe.i2Bits(a, b, c), 0, "I2 predicate bitmask on the over-cap lock attempt");
        assertEq(uint8(r), uint8(IxPNTsTokenV2.LockResult.INSUFFICIENT), "I2: admission beyond cap rejected");
        (, uint256 used) = tok.autoAllowance(user, sp);
        assertEq(used, 0, "I2: rejected admission writes nothing (L-1)");
    }

    /// I6 scenario (mutation M-I6 ignores the user's requestedCap in effectiveCreditCap).
    function test_D5c1_I6_scenario_reservationBoundedByRequestedCap() public {
        XPNTsV2HalmosProbe probe = new XPNTsV2HalmosProbe();
        registry.setCreditLimit(user, 1_000 ether);
        vm.prank(owner_);
        _ext().queueCreditPolicy(2); // AUTO
        vm.warp(block.timestamp + 48 hours);
        _ext().executeCreditPolicy();
        vm.prank(user);
        _ext().requestCredit(100 ether);
        XPNTsV2HalmosBase.Ctx memory c = _c(sp, xPNTsTokenV2.tryReserveCredit.selector, user, H, 200 ether, 0);
        XPNTsV2HalmosBase.S memory a = probe.snapOf(address(tok), c);
        vm.prank(sp);
        IxPNTsTokenV2.CreditResult r = tok.tryReserveCredit(user, H, 200 ether);
        c.ok = true;
        XPNTsV2HalmosBase.S memory b = probe.snapOf(address(tok), c);
        assertEq(probe.i6Bits(a, b, c), 0, "I6 predicate bitmask on the over-request reservation");
        assertEq(probe.i6jBits(b, 100 ether), 0, "I6-J bitmask with B = requestedCap");
        assertEq(uint8(r), uint8(IxPNTsTokenV2.CreditResult.EXCEEDS_CAP), "I6: reservation > requestedCap rejected");
        vm.prank(sp);
        r = tok.tryReserveCredit(user, H, 100 ether);
        assertEq(uint8(r), uint8(IxPNTsTokenV2.CreditResult.OK), "I6: reservation == requestedCap admitted");
    }

    // ================================================================ 2. layout facts used by the harness

    function test_D5c1_layout_allowancesSlotAndInitSlot() public {
        vm.prank(user);
        tok.approve(address(0xE1), 12345);
        bytes32 slot = keccak256(abi.encode(address(0xE1), keccak256(abi.encode(user, uint256(1)))));
        assertEq(uint256(vm.load(address(tok), slot)), 12345, "ERC20._allowances is slot 1");
        bytes32 init = 0xf0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00;
        assertEq(uint64(uint256(vm.load(address(tok), init))), 1, "ERC-7201 Initializable slot");
    }

    /// Every raw-slot formula the Halmos harness uses (XPNTsV2HalmosBase._snap) equals the public
    /// getter on a concrete token in a state where every field is non-zero and distinct.
    function test_D5c1_layout_snapshotMatchesGetters() public {
        XPNTsV2HalmosProbe probe = new XPNTsV2HalmosProbe();
        address e = sp;
        // non-trivial state: caps set, SP renewal used, a live lock and a live reservation, debt
        vm.startPrank(user);
        _ext().setAutoAllowance(sp, 3_000 ether);
        _ext().setUserTotalCap(4_000 ether);
        tok.approve(address(0xE1), 777);
        vm.stopPrank();
        registry.setCreditLimit(user, 1_000 ether);
        vm.prank(owner_);
        _ext().queueCreditPolicy(2);
        vm.warp(block.timestamp + 48 hours);
        _ext().executeCreditPolicy();
        vm.prank(user);
        _ext().requestCredit(300 ether);
        vm.startPrank(sp);
        tok.tryReserveCredit(user, keccak256("c0"), 40 ether);
        tok.settleCredit(user, keccak256("c0"), 25 ether); // debt 25
        tok.tryLockForGas(user, H, 120 ether, true);        // SP renewal: autoRenewUsed = 1
        tok.tryReserveCredit(user, H, 60 ether);
        vm.stopPrank();

        XPNTsV2HalmosBase.Ctx memory c;
        c.v = user; c.e = e; c.sender = address(0xE1); c.h = H;
        XPNTsV2HalmosBase.S memory s = probe.snapOf(address(tok), c);
        assertEq(s.bal, tok.balanceOf(user), "bal");
        assertEq(s.supply, tok.totalSupply(), "supply");
        assertEq(s.locked, tok.lockedOf(user), "lockedOf");
        assertGt(s.locked, 0);
        assertEq(s.debt, tok.debts(user), "debts");
        assertEq(s.debt, 25 ether);
        assertEq(s.reserved, tok.creditReservedOf(user), "creditReservedOf");
        (uint256 capA, uint256 usedA) = tok.autoAllowance(user, e);
        assertEq(s.capA, capA, "capA");
        assertEq(s.usedA, usedA, "usedA");
        assertEq(usedA, 120 ether);
        (uint256 capB, uint256 usedB) = tok.userTotal(user);
        assertEq(s.capB, capB, "capB");
        assertEq(s.usedB, usedB, "usedB");
        assertEq(s.renewUsed, tok.autoRenewUsed(user), "autoRenewUsed");
        assertEq(s.renewUsed, 1);
        assertEq(s.sp, tok.SUPERPAYMASTER_ADDRESS(), "SP");
        assertEq(s.policy, tok.creditPolicy(), "policy");
        assertEq(s.epoch, tok.policyEpoch(), "epoch");
        (uint112 rq, , uint32 ep) = tok.creditReq(user);
        assertEq(s.reqCap, rq, "requestedCap");
        assertEq(s.reqEpoch, ep, "request epoch");
        xPNTsV2Base.LockRec memory lk = tok.lockOf(H, user);
        assertEq(s.lkX0, lk.xLocked, "xLocked");
        assertEq(s.lkA0, lk.aReserved, "aReserved");
        assertEq(s.lkLocker, lk.locker, "lock locker");
        xPNTsV2Base.CreditRes memory cr = tok.creditReservationOf(H, user);
        assertEq(s.crAmount, cr.amount, "credit amount");
        assertEq(s.crLocker, cr.locker, "credit locker");
        assertEq(s.explicitAllow, 777, "raw _allowances[user][sender]");
        assertEq(s.rate, tok.exchangeRate(), "exchangeRate");
        c.e = address(0xE1);
        assertEq(probe.snapOf(address(tok), c).explicitAllowE, 777, "raw _allowances[user][e]");
        // default-cap branch of capA: a spender cell that was never set
        c.e = address(0xE2);
        s = probe.snapOf(address(tok), c);
        (capA, ) = tok.autoAllowance(user, address(0xE2));
        assertEq(s.capA, capA, "capA default (non-SP)");
    }

    // ================================================================ 3. replays (filled from the Halmos logs)

    /// The generated selector list used by the harness's "OTHER" partition equals the union of the
    /// core and extension ABIs in the current build (fails if XPNTsV2Selectors.sol is stale).
    function test_D5c1_selectorListMatchesArtifacts() public view {
        bytes4[] memory listed = XPNTsV2Selectors.all();
        bytes4[] memory seen = new bytes4[](400);
        uint256 n;
        string[2] memory files = ["out/xPNTsTokenV2.sol/xPNTsTokenV2.json", "out/xPNTsTokenV2Ext.sol/xPNTsTokenV2Ext.json"];
        for (uint256 f = 0; f < 2; f++) {
            string[] memory sigs = vm.parseJsonKeys(vm.readFile(files[f]), ".methodIdentifiers");
            for (uint256 i = 0; i < sigs.length; i++) {
                bytes4 s = bytes4(keccak256(bytes(sigs[i])));
                assertEq(XPNTsV2Selectors.isKnown(s), 1, sigs[i]);
                bool dup;
                for (uint256 j = 0; j < n; j++) if (seen[j] == s) dup = true;
                if (!dup) seen[n++] = s;
            }
        }
        assertEq(n, listed.length, "list size == |core ABI U ext ABI|");
        assertEq(XPNTsV2Selectors.isKnown(bytes4(0xdeadbeef)), 0, "negative control");
    }

    // ---------------------------------------------------------------- witness replays
    // Each Halmos reachability witness (XPNTsV2WitnessHalmosTest) is replayed as a concrete step:
    // the antecedent really happens, AND the harness's own predicate bitmask for that step is 0
    // (so the predicates accept real behaviour — they are not trivially false either).

    function _ctx(address v, address e, address sender, bytes32 h, bytes4 sel, address userArg, uint256 w2, uint256 w3)
        internal pure returns (XPNTsV2HalmosBase.Ctx memory c)
    {
        c.v = v; c.e = e; c.sender = sender; c.h = h; c.sel = sel; c.ok = true; c.userArg = userArg;
        c.w1 = uint256(h); c.w2 = w2; c.w3 = w3;
    }

    function _policyAuto(uint256 requested) internal {
        registry.setCreditLimit(user, 1_000 ether);
        vm.prank(owner_);
        _ext().queueCreditPolicy(2);
        vm.warp(block.timestamp + 48 hours);
        _ext().executeCreditPolicy();
        vm.prank(user);
        _ext().requestCredit(requested);
    }

    /// witness_A3_spSettleBurnsVictim + witness_I2_spRenewIncrements (the same concrete op pair)
    function test_D5c1_witness_spRenewLockThenSettle() public {
        XPNTsV2HalmosProbe probe = new XPNTsV2HalmosProbe();
        // step 1 (the harness's priming): SP renewal lock
        XPNTsV2HalmosBase.Ctx memory c = _ctx(user, sp, sp, H, xPNTsTokenV2.tryLockForGas.selector, user, 100 ether, 1);
        XPNTsV2HalmosBase.S memory a = probe.snapOf(address(tok), c);
        vm.prank(sp);
        tok.tryLockForGas(user, H, 100 ether, true);
        XPNTsV2HalmosBase.S memory b = probe.snapOf(address(tok), c);
        assertGt(b.renewUsed, a.renewUsed, "witness I2-3: SP renewal increments autoRenewUsed");
        assertEq(probe.i2Bits(a, b, c), 0, "I2 predicates hold on a real SP-renewal lock");
        // step 2: settle in the same transaction
        c = _ctx(user, sp, sp, H, xPNTsTokenV2.settleLocked.selector, user, 60 ether, 0);
        a = probe.snapOf(address(tok), c);
        vm.prank(sp);
        tok.settleLocked(user, H, 60 ether);
        b = probe.snapOf(address(tok), c);
        assertLt(b.bal, a.bal, "witness A3: an SP settle burns the victim");
        assertEq(probe.a3Bits(a, b, c), 0, "A3 predicates hold on a real settle");
        assertEq(probe.a3xBits(a, b, c), 0, "A3x exact bound holds on a real settle");
        assertEq(probe.i2Bits(a, b, c), 0, "I2 predicates hold on a real settle");
    }

    /// witness_I2_meteredPull
    function test_D5c1_witness_meteredPull() public {
        XPNTsV2HalmosProbe probe = new XPNTsV2HalmosProbe();
        DummySpender spender = new DummySpender();
        st.aoa.bootstrapApprove(st.aoa.KIND_SPENDER(), address(spender).codehash);
        vm.prank(owner_);
        IExt(address(tok)).proposeSpender(address(spender));
        vm.warp(block.timestamp + 48 hours);
        IExt(address(tok)).activateSpender(address(spender));
        vm.prank(user);
        _ext().setAutoAllowance(address(spender), 100 ether);
        XPNTsV2HalmosBase.Ctx memory c = _ctx(user, address(spender), address(spender), bytes32(0),
            xPNTsTokenV2.transferFrom.selector, user, 60 ether, 0);
        XPNTsV2HalmosBase.S memory a = probe.snapOf(address(tok), c);
        spender.pull(address(tok), user, 60 ether);
        XPNTsV2HalmosBase.S memory b = probe.snapOf(address(tok), c);
        assertLt(b.bal, a.bal, "witness I2-7: third-party pull");
        assertGt(b.usedA, a.usedA, "metered in the puller's cell");
        assertEq(probe.i2Bits(a, b, c), 0, "I2 predicates hold on a real metered pull");
    }

    /// witness_I6_reservationAdmitted + witness_I6_debtGrows
    function test_D5c1_witness_creditReserveThenSettle() public {
        XPNTsV2HalmosProbe probe = new XPNTsV2HalmosProbe();
        _policyAuto(300 ether);
        XPNTsV2HalmosBase.Ctx memory c = _ctx(user, sp, sp, H, xPNTsTokenV2.tryReserveCredit.selector, user, 120 ether, 0);
        XPNTsV2HalmosBase.S memory a = probe.snapOf(address(tok), c);
        vm.prank(sp);
        tok.tryReserveCredit(user, H, 120 ether);
        XPNTsV2HalmosBase.S memory b = probe.snapOf(address(tok), c);
        assertGt(b.reserved, a.reserved, "witness I6-1: reservation admitted");
        assertEq(probe.i6Bits(a, b, c), 0, "I6 predicates hold on a real admission");
        assertEq(probe.i6jBits(b, 300 ether), 0, "J(requestedCap) holds");
        c = _ctx(user, sp, sp, H, xPNTsTokenV2.settleCredit.selector, user, 80 ether, 0);
        a = probe.snapOf(address(tok), c);
        vm.prank(sp);
        tok.settleCredit(user, H, 80 ether);
        b = probe.snapOf(address(tok), c);
        assertGt(b.debt, a.debt, "witness I6-2: debt grows");
        assertEq(probe.i6Bits(a, b, c), 0, "I6 predicates hold on a real settleCredit");
        assertEq(probe.i6jBits(b, 300 ether), 0, "J(requestedCap) holds after settle");
    }

    /// Replay of the counterexample Halmos reported for check_I2_extAbi, partition transferFrom
    /// (first full run, data/halmos/spurious/): transferFrom(from = F, to = victim) where F and the
    /// victim together hold more than totalSupply. OZ credits the receiver with an UNCHECKED add, so
    /// the victim's balance wraps and "decreases" -> I2-7 (bit 6) goes red. The state is
    /// UNREACHABLE (ERC20 conservation: the sum of all balances equals totalSupply, and mint's
    /// `_totalSupply += value` is checked), so the counterexample is spurious; the harness's
    /// well-formedness assumption W3 was strengthened to every pair of {victim, sender, first
    /// address argument, second address argument}. This test shows both halves concretely.
    function test_D5c1_replay_I2_transferFrom_wrapNeedsUnreachableState() public {
        XPNTsV2HalmosProbe probe = new XPNTsV2HalmosProbe();
        address from = address(0xF0);
        address victim = address(0x7E);
        address spender = address(0xE5);
        vm.prank(from);
        tok.approve(spender, type(uint256).max);
        // forge the unreachable state: bal(from) = bal(victim) = supply = 2^255
        uint256 half = uint256(1) << 255;
        vm.store(address(tok), keccak256(abi.encode(from, uint256(0))), bytes32(half));
        vm.store(address(tok), keccak256(abi.encode(victim, uint256(0))), bytes32(half));
        vm.store(address(tok), bytes32(uint256(2)), bytes32(half));
        assertGt(tok.balanceOf(victim), tok.totalSupply() - tok.balanceOf(from), "bal(from) + bal(victim) > supply: unreachable");

        XPNTsV2HalmosBase.Ctx memory c;
        c.v = victim; c.e = spender; c.sender = spender; c.sel = xPNTsTokenV2.transferFrom.selector;
        c.userArg = from; c.w1 = uint256(uint160(victim)); c.w2 = half; c.ok = true;
        XPNTsV2HalmosBase.S memory a = probe.snapOf(address(tok), c);
        vm.prank(spender);
        tok.transferFrom(from, victim, half);
        XPNTsV2HalmosBase.S memory b = probe.snapOf(address(tok), c);
        assertEq(b.bal, 0, "the receiver's balance wrapped");
        assertEq(probe.i2Bits(a, b, c), 1 << 6, "exactly I2-7 is red, as in the Halmos counterexample");
    }

    /// REGRESSION for finding F-D5c1-1 (D5c-1-halmos.md §F; fix 3c28ec21). Before the fix,
    /// xPNTsFactoryV2 accepted any non-zero initial exchangeRate, and a lock with x >= 2^128 stored
    /// `uint128(x)` while adding the full x to lockedOf, orphaning a lockedOf residue after settle
    /// (I4 violated; pre-fix replay log: data/halmos/finding-F-D5c1-1-prefix-275abaef-replay.log).
    /// Now initialize range-checks the rate, so the same real-factory path reverts, and at the
    /// maximum admissible rate the largest possible lock is recorded exactly and settles to zero.
    function test_D5c1_REGRESSION_F1_rateOutOfRangeRejectedAtInit() public {
        xPNTsFactoryV2 factory = new xPNTsFactoryV2(sp, address(registry), address(st.impl), address(st.tier));
        vm.prank(community);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.ExchangeRateOutOfRange.selector, 1e40, 1e14, 1e22));
        factory.deployxPNTsToken("Big", "xBIG", "Big", "big.eth", 1e40, address(0));
    }

    function test_D5c1_REGRESSION_F1_maxRateMaxLockIsExact() public {
        xPNTsTokenV2 t = V2TokenDeployer.newToken(st, owner_, community, sp, 1e22); // _RATE_MAX
        IxPNTsV2Admin(address(t)).mint(user, 1e27);
        vm.startPrank(sp);
        (IxPNTsTokenV2.LockResult r, uint256 x) = t.tryLockForGas(user, H, 5_000 ether, false); // = maxSingleTxLimit
        assertEq(uint8(r), uint8(IxPNTsTokenV2.LockResult.OK));
        assertEq(x, 5e25, "x = 5000e18 * 1e22 / 1e18");
        assertEq(uint256(t.lockOf(H, user).xLocked), x, "no truncation");
        assertEq(t.lockedOf(user), x);
        t.settleLocked(user, H, 5_000 ether);
        vm.stopPrank();
        assertEq(t.lockedOf(user), 0, "I4: nothing orphaned");
    }
}

/**
 * @title The harness's priming, checked concretely.
 * @notice setUp (its own transaction) creates a lock and a credit reservation for (user, H); in the
 *         test transaction they are NOT live, so settling them reverts NotLive (control). The
 *         harness's _primeLock / _primeCredit must then (1) leave every snapshot field unchanged
 *         (storage fully restored) and (2) make exactly that record live, so the settle succeeds.
 */
contract D5c1PrimingTest is Test {
    address internal sp = address(0x5B);
    address internal owner_ = address(0xC0);
    address internal user = address(0xB0B);
    bytes32 internal constant H = keccak256("d5c1.prime");
    MockRegistryV2 internal registry;
    xPNTsTokenV2 internal tok;
    XPNTsV2HalmosProbe internal probe;

    function setUp() public {
        registry = new MockRegistryV2();
        V2TokenDeployer.Stack memory st = V2TokenDeployer.deployStack(sp, address(registry));
        tok = V2TokenDeployer.newToken(st, owner_, address(0xC1), sp, 1 ether);
        IxPNTsV2Admin(address(tok)).mint(user, 10_000 ether);
        registry.setCreditLimit(user, 1_000 ether);
        vm.prank(owner_);
        IxPNTsV2Admin(address(tok)).queueCreditPolicy(2);
        vm.warp(block.timestamp + 48 hours);
        IxPNTsV2Admin(address(tok)).executeCreditPolicy();
        vm.prank(user);
        IxPNTsV2Admin(address(tok)).requestCredit(300 ether);
        vm.startPrank(sp);
        tok.tryLockForGas(user, H, 100 ether, false);
        tok.tryReserveCredit(user, H, 50 ether);
        vm.stopPrank();
        probe = new XPNTsV2HalmosProbe();
    }

    function _same(XPNTsV2HalmosBase.S memory a, XPNTsV2HalmosBase.S memory b) internal pure {
        assertEq(abi.encode(a), abi.encode(b), "priming left storage unchanged");
    }

    function test_D5c1_priming_lockMakesExactlyTheRecordLive() public {
        XPNTsV2HalmosBase.Ctx memory c;
        c.v = user; c.e = sp; c.sender = sp; c.h = H;
        vm.prank(sp);
        vm.expectRevert(xPNTsV2Base.NotLive.selector);
        tok.settleLocked(user, H, 10 ether); // control: not live in this transaction
        XPNTsV2HalmosBase.S memory s0 = probe.snapOf(address(tok), c);
        probe.primeLockOn(address(tok), c, sp);
        _same(s0, probe.snapOf(address(tok), c));
        vm.prank(sp);
        tok.settleLocked(user, H, 10 ether); // now live
        assertEq(tok.lockedOf(user), 0);
    }

    function test_D5c1_priming_creditMakesExactlyTheRecordLive() public {
        XPNTsV2HalmosBase.Ctx memory c;
        c.v = user; c.e = sp; c.sender = sp; c.h = H;
        vm.prank(sp);
        vm.expectRevert(xPNTsV2Base.NotLive.selector);
        tok.settleCredit(user, H, 10 ether);
        XPNTsV2HalmosBase.S memory s0 = probe.snapOf(address(tok), c);
        SymTierSource ts = new SymTierSource();
        probe.primeCreditOn(address(tok), address(ts), c, sp);
        _same(s0, probe.snapOf(address(tok), c));
        vm.prank(sp);
        tok.settleCredit(user, H, 10 ether);
        assertEq(tok.debts(user), 10 ether);
    }
}
