// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import { Clones } from "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import { ERC1967Proxy } from "@openzeppelin-v5.0.2/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { ECDSA } from "@openzeppelin-v5.0.2/contracts/utils/cryptography/ECDSA.sol";
import { AOAProtocolRegistry } from "src/tokens/v2/AOAProtocolRegistry.sol";
import { GlobalTierSource } from "src/tokens/v2/GlobalTierSource.sol";
import { xPNTsTokenV2 } from "src/tokens/v2/xPNTsTokenV2.sol";
import { xPNTsTokenV2Ext } from "src/tokens/v2/xPNTsTokenV2Ext.sol";
import { xPNTsV2Base } from "src/tokens/v2/xPNTsV2Base.sol";
import { xPNTsFactoryV2 } from "src/tokens/v2/xPNTsFactoryV2.sol";
import { IxPNTsTokenV2 } from "src/tokens/v2/IxPNTsTokenV2.sol";
import { MockRegistryV2, DummySpender, IExt } from "../helpers/V2TestFixtures.sol";

// ---------------------------------------------------------------------------
// Tier sources with deliberately broken behaviour (§9 / C-0: any failure → 0)
// ---------------------------------------------------------------------------

contract RevertingTier {
    function tierOf(address, address) external pure returns (uint256) { revert("nope"); }
}

/// @dev Returns 64 bytes: well-formed ABI for a (uint256,uint256), malformed for tierOf.
contract WideTier {
    function tierOf(address, address) external pure returns (uint256, uint256) { return (1_000 ether, 1); }
}

/// @dev Returns 31 bytes.
contract ShortTier {
    fallback() external {
        assembly {
            mstore(0, not(0))
            return(0, 31)
        }
    }
}

/// @dev Returns nothing at all.
contract EmptyTier {
    fallback() external {}
}

/// @dev Burns every unit of forwarded gas.
contract GasBurnerTier {
    function tierOf(address, address) external view returns (uint256 x) {
        while (gasleft() > 0) { x += 1; }
    }
}

contract MaxTier {
    function tierOf(address, address) external pure returns (uint256) { return type(uint256).max; }
}

// ---------------------------------------------------------------------------
// ERC-1271 wallet: accepts ECDSA signatures from its owner key
// ---------------------------------------------------------------------------

contract Wallet1271 {
    address public immutable owner;
    bool public reject;
    constructor(address o) { owner = o; }
    function setReject(bool r) external { reject = r; }
    function isValidSignature(bytes32 h, bytes calldata sig) external view returns (bytes4) {
        if (reject) return 0xffffffff;
        return ECDSA.recover(h, sig) == owner ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}

interface IExtD3 {
    function queueTierSource(address s) external;
    function executeTierSource() external;
    function cancelCreditPolicy() external;
}

/**
 * @title xPNTsTokenV2D3Test
 * @notice D3 test matrix — the O1 rows left open at D2 acceptance:
 *         A-7, A-10 (propagate + genesis spender), E-3, E-4, C-4, C-5, tierOf failure modes,
 *         X5 rejection paths, ERC-1271 R2 signatures, S-2 / S-3 edges.
 */
contract xPNTsTokenV2D3Test is Test {
    AOAProtocolRegistry reg;
    MockRegistryV2 registry;
    GlobalTierSource tier;
    xPNTsTokenV2Ext ext;
    xPNTsTokenV2 impl;
    xPNTsFactoryV2 factory;
    xPNTsTokenV2 t;

    RevertingTier revTier;
    WideTier wideTier;
    ShortTier shortTier;
    EmptyTier emptyTier;
    GasBurnerTier burnTier;
    MaxTier maxTier;

    address governance = address(0xA11CE);
    address community = address(0xC0);
    address sp = address(0x5B);
    address sp2 = address(0x5B2);
    address sp3 = address(0x5B3);
    address user = address(0xB0B);
    address stranger = address(0xDEAD);
    uint256 walletKey = 0xA11E7;
    DummySpender spender;

    bytes32 constant OP1 = keccak256("op1");
    bytes32 constant OP2 = keccak256("op2");
    bytes32 constant OP3 = keccak256("op3");

    function setUp() public {
        reg = new AOAProtocolRegistry(governance);
        registry = new MockRegistryV2();
        tier = new GlobalTierSource(address(registry));
        ext = new xPNTsTokenV2Ext(address(reg));
        impl = new xPNTsTokenV2(address(reg), address(ext));
        spender = new DummySpender();
        revTier = new RevertingTier();
        wideTier = new WideTier();
        shortTier = new ShortTier();
        emptyTier = new EmptyTier();
        burnTier = new GasBurnerTier();
        maxTier = new MaxTier();

        vm.startPrank(governance);
        reg.bootstrapApprove(reg.KIND_SP(), reg.spKey(sp));
        reg.bootstrapApprove(reg.KIND_SP(), reg.spKey(sp2));
        reg.bootstrapApprove(reg.KIND_SP(), reg.spKey(sp3));
        reg.bootstrapApprove(reg.KIND_TIER_SOURCE(), address(tier).codehash);
        reg.bootstrapApprove(reg.KIND_TIER_SOURCE(), address(revTier).codehash);
        reg.bootstrapApprove(reg.KIND_TIER_SOURCE(), address(wideTier).codehash);
        reg.bootstrapApprove(reg.KIND_TIER_SOURCE(), address(shortTier).codehash);
        reg.bootstrapApprove(reg.KIND_TIER_SOURCE(), address(emptyTier).codehash);
        reg.bootstrapApprove(reg.KIND_TIER_SOURCE(), address(burnTier).codehash);
        reg.bootstrapApprove(reg.KIND_TIER_SOURCE(), address(maxTier).codehash);
        reg.bootstrapApprove(reg.KIND_SPENDER(), address(spender).codehash);
        reg.seal();
        vm.stopPrank();

        factory = new xPNTsFactoryV2(sp, address(registry), address(impl), address(tier));
        vm.prank(community);
        t = xPNTsTokenV2(factory.deployxPNTsToken("Comm", "xC", "Comm", "comm.eth", 1 ether, address(0)));
        vm.prank(community);
        _ext().mint(user, 10_000 ether);
    }

    function _ext() internal view returns (IExt) { return IExt(address(t)); }
    function _ext3() internal view returns (IExtD3) { return IExtD3(address(t)); }
    function _now() internal view returns (uint256) { return vm.getBlockTimestamp(); }

    function _lock(address u, bytes32 h, uint256 a, bool renew) internal returns (IxPNTsTokenV2.LockResult r) {
        vm.prank(sp);
        (r, ) = t.tryLockForGas(u, h, a, renew);
    }

    function _reserve(address u, bytes32 h, uint256 a) internal returns (IxPNTsTokenV2.CreditResult r) {
        vm.prank(sp);
        r = t.tryReserveCredit(u, h, a);
    }

    function _policy(uint8 p) internal {
        vm.prank(community);
        _ext().queueCreditPolicy(p);
        vm.warp(_now() + 48 hours);
        _ext().executeCreditPolicy();
    }

    function _switchTier(address s) internal {
        vm.prank(community);
        _ext3().queueTierSource(s);
        vm.warp(_now() + 48 hours);
        _ext3().executeTierSource();
    }

    // ==================================================================
    // A-7: one renewal per sender per bundle, and it must be validated first
    // (a bundle validates every op before executing any, so a later op in the
    //  same bundle sees the earlier op's lock)
    // ==================================================================

    function test_A7_renewal_after_a_lock_in_same_bundle_is_rejected_and_writes_nothing() public {
        assertEq(uint8(_lock(user, OP1, 10 ether, false)), uint8(IxPNTsTokenV2.LockResult.OK));
        (, uint256 usedBefore) = t.autoAllowance(user, sp);
        assertEq(uint8(_lock(user, OP2, 10 ether, true)), uint8(IxPNTsTokenV2.LockResult.INVALID_RENEWAL),
            "renewal not first in the bundle");
        (, uint256 usedAfter) = t.autoAllowance(user, sp);
        assertEq(t.autoRenewUsed(user), 0, "failed renewal not committed");
        assertEq(usedAfter, usedBefore, "counters untouched");
        assertEq(t.lockOf(OP2, user).locker, address(0), "no lock record");
    }

    function test_A7_renewal_first_then_plain_ops_ok_second_renewal_rejected() public {
        assertEq(uint8(_lock(user, OP1, 10 ether, true)), uint8(IxPNTsTokenV2.LockResult.OK), "renewal first");
        assertEq(uint8(_lock(user, OP2, 10 ether, false)), uint8(IxPNTsTokenV2.LockResult.OK), "then plain op");
        assertEq(uint8(_lock(user, OP3, 10 ether, true)), uint8(IxPNTsTokenV2.LockResult.INVALID_RENEWAL),
            "second renewal in the same bundle");
        assertEq(t.autoRenewUsed(user), 1);
    }

    function test_A7_renewal_after_credit_reservation_is_rejected() public {
        registry.setCreditLimit(user, 1_000 ether);
        _policy(2);
        vm.prank(user);
        _ext().requestCredit(1_000 ether);
        assertEq(uint8(_reserve(user, OP1, 10 ether)), uint8(IxPNTsTokenV2.CreditResult.OK));
        assertEq(uint8(_lock(user, OP2, 10 ether, true)), uint8(IxPNTsTokenV2.LockResult.INVALID_RENEWAL),
            "outstanding credit reservation blocks renewal");
        assertEq(t.autoRenewUsed(user), 0);
    }

    // ==================================================================
    // A-10: factory propagation only proposes; genesis spender has default cap 0
    // ==================================================================

    function test_A10_propagate_only_proposes_and_community_can_cancel() public {
        factory.setSuperPaymasterAddress(sp2);
        vm.expectEmit(true, true, false, false, address(factory));
        emit xPNTsFactoryV2.SuperPaymasterPropagated(address(t), sp2);
        factory.propagateSuperPaymaster(0, 10);

        assertEq(t.SUPERPAYMASTER_ADDRESS(), sp, "not effective immediately");
        assertEq(t.pendingSP(), sp2);
        assertTrue(t.pendingSPByFactory());
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.TimelockActive.selector, t.pendingSPEta()));
        _ext().activateSP();

        vm.prank(community);
        _ext().cancelSP();
        assertEq(t.pendingSP(), address(0));
        vm.warp(_now() + 48 hours);
        vm.expectRevert(xPNTsV2Base.NothingPending.selector);
        _ext().activateSP();
        assertEq(t.SUPERPAYMASTER_ADDRESS(), sp);
    }

    function test_A10_propagate_does_not_override_community_proposal() public {
        vm.prank(community);
        _ext().proposeSP(sp3);
        factory.setSuperPaymasterAddress(sp2);
        vm.expectEmit(true, true, false, false, address(factory));
        emit xPNTsFactoryV2.SuperPaymasterPropagationFailed(address(t), sp2);
        factory.propagateSuperPaymaster(0, 10);
        assertEq(t.pendingSP(), sp3, "community proposal intact");
        assertFalse(t.pendingSPByFactory());
    }

    function test_A10_propagated_proposal_activates_after_timelock() public {
        factory.setSuperPaymasterAddress(sp2);
        factory.propagateSuperPaymaster(0, 10);
        vm.warp(_now() + 48 hours);
        _ext().activateSP();
        assertEq(t.SUPERPAYMASTER_ADDRESS(), sp2);
        assertEq(t.allowance(user, sp2), 0, "new SP is never a spender");
    }

    function test_A10_genesis_spender_default_cap_zero_until_user_opts_in() public {
        address clone = Clones.clone(address(spender));
        address c2 = address(0xC2);
        vm.prank(c2);
        xPNTsTokenV2 t2 = xPNTsTokenV2(factory.deployxPNTsToken("C2", "x2", "C2", "c2.eth", 1 ether, clone));
        assertTrue(t2.autoApprovedSpenders(clone), "registered at genesis without timelock");
        vm.prank(c2);
        IExt(address(t2)).mint(user, 1_000 ether);
        assertEq(t2.allowance(user, clone), 0, "Q5: per-user default cap 0");
        vm.prank(user);
        IExt(address(t2)).setAutoAllowance(clone, 300 ether);
        assertEq(t2.allowance(user, clone), 300 ether);
    }

    function test_A10_genesis_spender_must_be_on_allowlist() public {
        DummySpender unlisted = new DummySpender();
        // different codehash from `spender`? No: same code. Use an upgradeable proxy instead.
        ERC1967Proxy proxy = new ERC1967Proxy(address(unlisted), "");
        address c2 = address(0xC2);
        vm.prank(c2);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.NotApproved.selector, address(proxy)));
        factory.deployxPNTsToken("C2", "x2", "C2", "c2.eth", 1 ether, address(proxy));
    }

    // ==================================================================
    // E-3 / E-4
    // ==================================================================

    function test_E3_reenable_does_not_reset_used() public {
        _lock(user, OP1, 1_000 ether, false);
        vm.prank(sp);
        t.settleLocked(user, OP1, 1_000 ether);
        vm.prank(user);
        _ext().disableSpenderForSelf(sp);
        assertEq(uint8(_lock(user, OP2, 1 ether, false)), uint8(IxPNTsTokenV2.LockResult.DISABLED));
        vm.prank(user);
        _ext().enableSpenderForSelf(sp);
        (, uint256 used) = t.autoAllowance(user, sp);
        (, uint256 usedTotal) = t.userTotal(user);
        assertEq(used, 1_000 ether, "E-3: enable keeps per-spender used");
        assertEq(usedTotal, 1_000 ether, "E-3: enable keeps total used");
        assertEq(uint8(_lock(user, OP2, 1 ether, false)), uint8(IxPNTsTokenV2.LockResult.OK));
    }

    function test_E3_reenable_by_signature_does_not_reset_used() public {
        Wallet1271 w = new Wallet1271(vm.addr(walletKey));
        vm.prank(community);
        _ext().mint(address(w), 5_000 ether);
        _lock(address(w), OP1, 700 ether, false);
        vm.prank(sp);
        t.settleLocked(address(w), OP1, 700 ether);
        vm.prank(address(w));
        _ext().disableSpenderForSelf(sp);
        _sigAction(address(w), 6, abi.encode(sp)); // ACT_ENABLE
        assertFalse(t.spenderDisabled(sp, address(w)));
        (, uint256 used) = t.autoAllowance(address(w), sp);
        assertEq(used, 700 ether);
    }

    /// forge-config: default.isolate = true
    function test_E4_releaseAndDisable_atomic_after_tx() public {
        _lock(user, OP1, 100 ether, false);          // tx 1
        vm.prank(user);
        _ext().releaseAndDisable(sp, OP1);           // tx 2
        assertTrue(t.spenderDisabled(sp, user), "disabled");
        assertEq(t.lockedOf(user), 0, "released");
        (, uint256 used) = t.autoAllowance(user, sp);
        assertEq(used, 0, "full refund to the originating cell");
        assertEq(uint8(_lock(user, OP2, 1 ether, false)), uint8(IxPNTsTokenV2.LockResult.DISABLED),
            "no re-lock window");
    }

    function test_E4_releaseAndDisable_reverts_whole_while_live() public {
        _lock(user, OP1, 100 ether, false);          // same transaction → still live
        vm.prank(user);
        vm.expectRevert(xPNTsV2Base.StillLive.selector);
        _ext().releaseAndDisable(sp, OP1);
        assertFalse(t.spenderDisabled(sp, user), "disable rolled back with the release");
        assertEq(t.lockedOf(user), 100 ether);
    }

    function test_E4_releaseAndDisable_without_record_just_disables() public {
        vm.prank(user);
        _ext().releaseAndDisable(sp, OP1);
        assertTrue(t.spenderDisabled(sp, user));
        assertEq(t.effectiveCreditCap(user), 0);
    }

    // ==================================================================
    // C-4: revocation affects only NEW reservations
    // ==================================================================

    function test_C4_user_revoke_keeps_admitted_reservation() public {
        registry.setCreditLimit(user, 1_000 ether);
        _policy(2);
        vm.prank(user);
        _ext().requestCredit(500 ether);
        assertEq(uint8(_reserve(user, OP1, 400 ether)), uint8(IxPNTsTokenV2.CreditResult.OK));
        vm.prank(user);
        _ext().revokeCredit();
        assertEq(t.effectiveCreditCap(user), 0);
        vm.prank(sp);
        assertEq(t.settleCredit(user, OP1, 300 ether), 300 ether, "admitted reservation settles");
        assertEq(t.debts(user), 300 ether);
        assertEq(uint8(_reserve(user, OP2, 1 ether)), uint8(IxPNTsTokenV2.CreditResult.NO_CREDIT), "new ones blocked");
    }

    function test_C4_owner_lowers_approval_keeps_admitted_reservation() public {
        registry.setCreditLimit(user, 1_000 ether);
        _policy(1);
        vm.prank(user);
        _ext().requestCredit(500 ether);
        vm.prank(community);
        _ext().approveCredit(user, 500 ether);
        assertEq(uint8(_reserve(user, OP1, 400 ether)), uint8(IxPNTsTokenV2.CreditResult.OK));
        vm.prank(community);
        _ext().approveCredit(user, 100 ether);
        vm.prank(sp);
        assertEq(t.settleCredit(user, OP1, 400 ether), 400 ether);
        assertEq(t.debts(user), 400 ether, "debt may exceed the lowered cap (I3)");
        assertEq(uint8(_reserve(user, OP2, 1 ether)), uint8(IxPNTsTokenV2.CreditResult.EXCEEDS_CAP));
    }

    function test_C4_tier_drop_keeps_admitted_reservation() public {
        registry.setCreditLimit(user, 1_000 ether);
        _policy(2);
        vm.prank(user);
        _ext().requestCredit(500 ether);
        assertEq(uint8(_reserve(user, OP1, 400 ether)), uint8(IxPNTsTokenV2.CreditResult.OK));
        registry.setCreditLimit(user, 0);
        vm.prank(sp);
        assertEq(t.settleCredit(user, OP1, 400 ether), 400 ether, "settle never rereads the tier");
        assertEq(uint8(_reserve(user, OP2, 1 ether)), uint8(IxPNTsTokenV2.CreditResult.NO_CREDIT));
    }

    function test_C4_policy_off_keeps_admitted_reservation() public {
        registry.setCreditLimit(user, 1_000 ether);
        _policy(2);
        vm.prank(user);
        _ext().requestCredit(500 ether);
        assertEq(uint8(_reserve(user, OP1, 100 ether)), uint8(IxPNTsTokenV2.CreditResult.OK));
        // the 48 h switch cannot land inside one transaction; settle the same record after the
        // switch by warping in the same (non-isolated) test transaction
        _policy(0);
        assertEq(t.effectiveCreditCap(user), 0);
        vm.prank(sp);
        assertEq(t.settleCredit(user, OP1, 100 ether), 100 ether);
        assertEq(uint8(_reserve(user, OP2, 1 ether)), uint8(IxPNTsTokenV2.CreditResult.NO_CREDIT));
    }

    // ==================================================================
    // C-5: tier-source switch
    // ==================================================================

    function test_C5_switch_timelocked_and_bumps_epoch() public {
        _policy(2);
        registry.setCreditLimit(user, 700 ether);
        vm.prank(user);
        _ext().requestCredit(1_000 ether);
        assertEq(t.effectiveCreditCap(user), 700 ether);

        vm.prank(community);
        _ext3().queueTierSource(address(maxTier));
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.TimelockActive.selector, t.pendingTierSourceEta()));
        _ext3().executeTierSource();
        vm.warp(_now() + 48 hours);
        uint32 e0 = t.policyEpoch();
        _ext3().executeTierSource();
        assertEq(t.creditTierSource(), address(maxTier));
        assertEq(t.policyEpoch(), e0 + 1);
        assertEq(t.effectiveCreditCap(user), 0, "fresh consent required after a source switch");
        vm.prank(user);
        _ext().requestCredit(1_000 ether);
        assertEq(t.effectiveCreditCap(user), 1_000 ether, "min(request, huge tier)");
    }

    function test_C5_queue_rejects_unlisted_and_nonowner() public {
        GlobalTierSource fresh = new GlobalTierSource(address(0xBEEF)); // same code, different immutable
        vm.prank(community);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.NotApproved.selector, address(fresh)));
        _ext3().queueTierSource(address(fresh));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.Unauthorized.selector, stranger));
        _ext3().queueTierSource(address(maxTier));

        vm.prank(community);
        vm.expectRevert(xPNTsV2Base.InvalidParam.selector);
        _ext3().queueTierSource(address(tier)); // already current
    }

    function test_C5_execute_rechecks_allowlist() public {
        vm.prank(community);
        _ext3().queueTierSource(address(maxTier));
        uint8 kTier = reg.KIND_TIER_SOURCE();
        vm.prank(governance);
        reg.revokeApproval(kTier, address(maxTier).codehash);
        vm.warp(_now() + 48 hours);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.NotApproved.selector, address(maxTier)));
        _ext3().executeTierSource();
        assertEq(t.creditTierSource(), address(tier));
    }

    // ==================================================================
    // C-0 / §9: tierOf failure modes all fail closed to 0
    // ==================================================================

    function _capWith(address src) internal returns (uint256) {
        _switchTier(src);
        vm.prank(user);
        _ext().requestCredit(1_000 ether);
        return t.effectiveCreditCap(user);
    }

    function test_tierOf_revert_is_zero() public {
        _policy(2);
        assertEq(_capWith(address(revTier)), 0);
        assertEq(uint8(_reserve(user, OP1, 1 ether)), uint8(IxPNTsTokenV2.CreditResult.NO_CREDIT));
    }

    function test_tierOf_wide_return_is_zero() public {
        _policy(2);
        assertEq(_capWith(address(wideTier)), 0);
    }

    function test_tierOf_short_return_is_zero() public {
        _policy(2);
        assertEq(_capWith(address(shortTier)), 0);
    }

    function test_tierOf_empty_return_is_zero() public {
        _policy(2);
        assertEq(_capWith(address(emptyTier)), 0);
    }

    function test_tierOf_gas_exhaustion_is_zero_and_bounded() public {
        _policy(2);
        _switchTier(address(burnTier));
        vm.prank(user);
        _ext().requestCredit(1_000 ether);
        uint256 g = gasleft();
        uint256 cap = t.effectiveCreditCap(user);
        uint256 spent = g - gasleft();
        assertEq(cap, 0);
        assertLt(spent, t.TIER_SOURCE_GAS() + 30_000, "forwarded gas is capped");
        assertEq(uint8(_reserve(user, OP1, 1 ether)), uint8(IxPNTsTokenV2.CreditResult.NO_CREDIT));
    }

    function test_tierOf_positive_control_huge_tier_is_clipped_by_request() public {
        _policy(2);
        assertEq(_capWith(address(maxTier)), 1_000 ether, "positive control: well-formed source works");
    }

    // ==================================================================
    // X5: spender allowlist rejection paths
    // ==================================================================

    function test_X5_unlisted_code_rejected() public {
        GlobalTierSource notASpender = new GlobalTierSource(address(registry));
        vm.prank(community);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.NotApproved.selector, address(notASpender)));
        _ext().proposeSpender(address(notASpender));
    }

    function test_X5_upgradeable_proxy_to_listed_impl_rejected() public {
        ERC1967Proxy proxy = new ERC1967Proxy(address(spender), "");
        assertFalse(reg.isApprovedImpl(reg.KIND_SPENDER(), address(proxy)));
        vm.prank(community);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.NotApproved.selector, address(proxy)));
        _ext().proposeSpender(address(proxy));
    }

    function test_X5_noncanonical_45_byte_lookalike_rejected() public {
        address clone = Clones.clone(address(spender));
        bytes memory code = clone.code;
        assertEq(code.length, 45);
        code[44] = 0xfe; // last byte of the canonical suffix (0xf3 → 0xfe)
        address fake = address(0xFA4E);
        vm.etch(fake, code);
        assertEq(reg.implCodehash(fake), fake.codehash, "not resolved");
        vm.prank(community);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.NotApproved.selector, fake));
        _ext().proposeSpender(fake);
    }

    function test_X5_eoa_and_sp_rejected() public {
        vm.prank(community);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.NotApproved.selector, stranger));
        _ext().proposeSpender(stranger);
        vm.prank(community);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.InvalidAddress.selector, sp));
        _ext().proposeSpender(sp);
    }

    function test_X5_canonical_clone_accepted_and_activation_rechecks() public {
        address clone = Clones.clone(address(spender));
        vm.prank(community);
        _ext().proposeSpender(clone);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.TimelockActive.selector, t.spenderActivatesAt(clone)));
        _ext().activateSpender(clone);

        address clone2 = Clones.clone(address(spender));
        vm.prank(community);
        _ext().proposeSpender(clone2);

        vm.warp(_now() + 48 hours);
        _ext().activateSpender(clone);
        assertTrue(t.autoApprovedSpenders(clone), "positive control");

        uint8 kSpender = reg.KIND_SPENDER();
        vm.prank(governance);
        reg.revokeApproval(kSpender, address(spender).codehash);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.NotApproved.selector, clone2));
        _ext().activateSpender(clone2);
        assertTrue(t.autoApprovedSpenders(clone), "O2: revocation does not unwind an activated spender");
    }

    function test_X5_spender_becoming_sp_cannot_be_activated() public {
        // a spender proposal pending while the same address is made SP → activation refused
        address clone = Clones.clone(address(spender));
        (uint8 kSP, bytes32 key) = (reg.KIND_SP(), reg.spKey(clone));
        vm.prank(governance);
        vm.expectRevert(AOAProtocolRegistry.AlreadySealed.selector); // sealed: SP additions go through the time-lock
        reg.bootstrapApprove(kSP, key);
        vm.prank(community);
        _ext().proposeSpender(clone);
        vm.prank(governance);
        reg.proposeApproval(kSP, key);
        vm.warp(_now() + 48 hours);
        reg.executeApproval(kSP, key);
        vm.prank(community);
        _ext().proposeSP(clone);
        vm.warp(_now() + 48 hours);
        _ext().activateSP();
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.InvalidAddress.selector, clone));
        _ext().activateSpender(clone);
    }

    // ==================================================================
    // R2 via ERC-1271
    // ==================================================================

    function _sigAction(address w, uint8 kind, bytes memory params) internal {
        uint256 deadline = _now() + 1 hours;
        bytes32 digest = _ext().actionDigest(w, kind, params, t.actionNonce(w), deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(walletKey, digest);
        vm.prank(stranger); // any relayer
        _ext().executeBySig(w, kind, params, deadline, abi.encodePacked(r, s, v));
    }

    function test_1271_wallet_action_by_relayer() public {
        Wallet1271 w = new Wallet1271(vm.addr(walletKey));
        _sigAction(address(w), 2, abi.encode(sp, 400 ether)); // ACT_SET_ALLOWANCE
        (uint256 cap, ) = t.autoAllowance(address(w), sp);
        assertEq(cap, 400 ether);
        assertEq(t.actionNonce(address(w)), 1);
    }

    function test_1271_wallet_rejection_reverts_and_keeps_nonce() public {
        Wallet1271 w = new Wallet1271(vm.addr(walletKey));
        w.setReject(true);
        uint256 deadline = _now() + 1 hours;
        bytes memory params = abi.encode(sp);
        bytes32 digest = _ext().actionDigest(address(w), 5, params, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(walletKey, digest);
        vm.expectRevert(xPNTsV2Base.InvalidSignature.selector);
        _ext().executeBySig(address(w), 5, params, deadline, abi.encodePacked(r, s, v));
        assertEq(t.actionNonce(address(w)), 0);
        assertFalse(t.spenderDisabled(sp, address(w)));
    }

    function test_1271_wrong_key_and_expired_rejected() public {
        Wallet1271 w = new Wallet1271(vm.addr(walletKey));
        uint256 deadline = _now() + 1 hours;
        bytes memory params = abi.encode(sp);
        bytes32 digest = _ext().actionDigest(address(w), 5, params, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, digest);
        vm.expectRevert(xPNTsV2Base.InvalidSignature.selector);
        _ext().executeBySig(address(w), 5, params, deadline, abi.encodePacked(r, s, v));

        (v, r, s) = vm.sign(walletKey, digest);
        vm.warp(deadline + 1);
        vm.expectRevert(xPNTsV2Base.SignatureExpired.selector);
        _ext().executeBySig(address(w), 5, params, deadline, abi.encodePacked(r, s, v));
    }

    function test_1271_signature_bound_to_token_domain() public {
        // the same signature replayed on another v2 token (different EIP-712 domain) fails
        Wallet1271 w = new Wallet1271(vm.addr(walletKey));
        address c2 = address(0xC2);
        vm.prank(c2);
        xPNTsTokenV2 t2 = xPNTsTokenV2(factory.deployxPNTsToken("C2", "x2", "C2", "c2.eth", 1 ether, address(0)));
        uint256 deadline = _now() + 1 hours;
        bytes memory params = abi.encode(sp);
        bytes32 digest = _ext().actionDigest(address(w), 5, params, 0, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(walletKey, digest);
        vm.expectRevert(xPNTsV2Base.InvalidSignature.selector);
        IExt(address(t2)).executeBySig(address(w), 5, params, deadline, abi.encodePacked(r, s, v));
        _ext().executeBySig(address(w), 5, params, deadline, abi.encodePacked(r, s, v)); // positive control
        assertTrue(t.spenderDisabled(sp, address(w)));
    }

    // ==================================================================
    // S-2 / S-3 edges
    // ==================================================================

    function test_S2_cancel_authority() public {
        vm.prank(stranger);
        vm.expectRevert(xPNTsV2Base.NothingPending.selector);
        _ext().cancelSP();

        vm.prank(community);
        _ext().proposeSP(sp2);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.Unauthorized.selector, stranger));
        _ext().cancelSP();
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.Unauthorized.selector, address(factory)));
        _ext().cancelSP(); // factory may cancel only its own proposal

        vm.prank(community);
        _ext().cancelSP();
        assertEq(t.pendingSP(), address(0));

        vm.prank(address(factory));
        _ext().proposeSP(sp2);
        vm.prank(address(factory));
        _ext().cancelSP();
        assertEq(t.pendingSP(), address(0), "factory cancels its own");
    }

    function test_S3_timelock_boundary() public {
        vm.prank(community);
        _ext().proposeSP(sp2);
        uint64 eta = t.pendingSPEta();
        vm.warp(eta - 1);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.TimelockActive.selector, eta));
        _ext().activateSP();
        vm.warp(eta);
        vm.prank(stranger);
        _ext().activateSP(); // anyone, exactly at eta
        assertEq(t.SUPERPAYMASTER_ADDRESS(), sp2);
        assertEq(t.pendingSP(), address(0));
    }

    function test_S3_rechecks_registry_at_activation() public {
        vm.prank(community);
        _ext().proposeSP(sp2);
        (uint8 kSP, bytes32 key) = (reg.KIND_SP(), reg.spKey(sp2));
        vm.prank(governance);
        reg.revokeApproval(kSP, key);
        vm.warp(_now() + 48 hours);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.NotApproved.selector, sp2));
        _ext().activateSP();
        assertEq(t.SUPERPAYMASTER_ADDRESS(), sp);
    }

    function test_S3_community_proposal_activates_during_emergency_without_clearing_it() public {
        vm.prank(community);
        _ext().proposeSP(sp2);
        vm.prank(community);
        _ext().emergencyRevokePaymaster();
        assertEq(t.pendingSP(), sp2, "community proposal survives S-4");
        vm.warp(_now() + 48 hours);
        _ext().activateSP();
        assertEq(t.SUPERPAYMASTER_ADDRESS(), sp2);
        assertTrue(t.emergencyDisabled(), "S-3 never clears the emergency");
        vm.prank(sp2);
        (IxPNTsTokenV2.LockResult r, ) = t.tryLockForGas(user, OP1, 1 ether, false);
        assertEq(uint8(r), uint8(IxPNTsTokenV2.LockResult.EMERGENCY));

        vm.prank(community);
        _ext().unsetEmergencyDisabled(); // S-7: current != revoked
        vm.prank(sp2);
        (r, ) = t.tryLockForGas(user, OP1, 1 ether, false);
        assertEq(uint8(r), uint8(IxPNTsTokenV2.LockResult.OK));

        vm.prank(community);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.InvalidAddress.selector, sp));
        _ext().proposeSP(sp); // the revoked address can never come back
    }

    function test_S3_old_sp_cannot_act_after_rotation() public {
        vm.prank(community);
        _ext().proposeSP(sp2);
        vm.warp(_now() + 48 hours);
        _ext().activateSP();
        vm.prank(sp);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.Unauthorized.selector, sp));
        t.tryLockForGas(user, OP1, 1 ether, false);
        vm.prank(sp);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.Unauthorized.selector, sp));
        t.tryReserveCredit(user, OP1, 1 ether);
        assertEq(t.allowance(user, sp), 0, "historical SP still reads 0");
    }

    // ==================================================================
    // I4 / D5c-1 finding: exchangeRate is range-checked at initialize, so a lock's x
    // always fits LockRec.xLocked (uint128) and settle leaves no orphaned lockedOf.
    // ==================================================================

    function test_I4_initialize_rejects_rate_out_of_range() public {
        address c3 = address(0xC3);
        uint256 hi = 1e22 + 1;
        uint256 lo = 1e14 - 1;
        vm.prank(c3);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.ExchangeRateOutOfRange.selector, hi, 1e14, 1e22));
        factory.deployxPNTsToken("C3", "x3", "C3", "c3.eth", hi, address(0));
        vm.prank(c3);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.ExchangeRateOutOfRange.selector, lo, 1e14, 1e22));
        factory.deployxPNTsToken("C3", "x3", "C3", "c3.eth", lo, address(0));
        // positive controls: both inclusive bounds deploy
        vm.prank(c3);
        assertEq(xPNTsTokenV2(factory.deployxPNTsToken("C3", "x3", "C3", "c3.eth", 1e22, address(0))).exchangeRate(), 1e22);
        address c4 = address(0xC4);
        vm.prank(c4);
        assertEq(xPNTsTokenV2(factory.deployxPNTsToken("C4", "x4", "C4", "c4.eth", 1e14, address(0))).exchangeRate(), 1e14);
    }

    function test_I4_max_rate_lock_records_exact_x_and_settle_clears_lockedOf() public {
        address c3 = address(0xC3);
        vm.prank(c3);
        xPNTsTokenV2 t3 = xPNTsTokenV2(factory.deployxPNTsToken("C3", "x3", "C3", "c3.eth", 1e22, address(0)));
        uint256 a0 = 5_000 ether;                   // default single-tx limit and default caps
        uint256 x = a0 * 1e22 / 1e18;               // exact (no rounding at this rate)
        vm.prank(c3);
        IExt(address(t3)).mint(user, x);
        vm.prank(sp);
        (IxPNTsTokenV2.LockResult r, uint256 xl) = t3.tryLockForGas(user, OP1, a0, false);
        assertEq(uint8(r), uint8(IxPNTsTokenV2.LockResult.OK));
        assertEq(xl, x);
        assertEq(uint256(t3.lockOf(OP1, user).xLocked), x, "recorded xLocked == locked x (no truncation)");
        assertEq(t3.lockedOf(user), x);
        vm.prank(sp);
        t3.settleLocked(user, OP1, a0 / 2);
        assertEq(t3.lockedOf(user), 0, "no orphaned lockedOf after settle");
        assertEq(t3.balanceOf(user), x - x / 2, "burn == charge share of the exact x");
        // the structural bound behind the fix: max x = PROTOCOL_MAX_CAP-sized reserve at the max rate
        assertLt(uint256(50_000 ether) * 1e22 / 1e18, uint256(type(uint128).max));
    }
}
