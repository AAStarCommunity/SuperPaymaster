// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import { SuperPaymasterAdminCalls } from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
import { SuperPaymasterLens } from "src/paymasters/superpaymaster/v3/SuperPaymasterLens.sol";
import { Ownable2StepNamespaced } from "src/utils/Ownable2StepNamespaced.sol";
import "src/core/Registry.sol";
import "src/interfaces/v3/IRegistry.sol";
import "@account-abstraction-v7/core/EntryPoint.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import "@account-abstraction-v7/samples/SimpleAccountFactory.sol";
import "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import { TimelockController } from "@openzeppelin-v5.0.2/contracts/governance/TimelockController.sol";
import { UUPSDeployHelper } from "../helpers/UUPSDeployHelper.sol";
import { AOAProtocolRegistry } from "src/tokens/v2/AOAProtocolRegistry.sol";
import { GlobalTierSource } from "src/tokens/v2/GlobalTierSource.sol";
import { xPNTsTokenV2 } from "src/tokens/v2/xPNTsTokenV2.sol";
import { xPNTsTokenV2Ext } from "src/tokens/v2/xPNTsTokenV2Ext.sol";
import { xPNTsFactoryV2 } from "src/tokens/v2/xPNTsFactoryV2.sol";
import { IxPNTsTokenV2 } from "src/tokens/v2/IxPNTsTokenV2.sol";
import { MockAgentIdentityRegistry } from "src/mocks/MockAgentIdentityRegistry.sol";
import { V55Registry, V55PriceFeed, V55APNTs, IV2Ext } from "../helpers/V55TestFixtures.sol";

using SuperPaymasterAdminCalls for SuperPaymaster;

/**
 * @title SuperPaymasterD5bGov2Test — D5b acceptance (D5b-design §5; spec 03 §10.7b GOV-2 v3 B / D)
 * @notice Core + SuperPaymasterAdmin split and GOV-2 (two-step ownership, guardian, global pause) on
 *         SuperPaymaster, and two-step ownership on Registry. Every call below goes through the PROXY,
 *         i.e. through the same routing (core selectors vs fallback → extension) production uses.
 *
 *         Named red assertions for the spec's negative controls / mutations:
 *           (b) transferOwnership override without onlyOwner  → test_gov2_sp_transferOwnership_requires_owner
 *               "non-owner nomination must revert"
 *           (c) core two-step override deleted (OZ single-step) → test_gov2_sp_transferOwnership_via_proxy_is_two_step
 *               "owner unchanged after transferOwnership (two-step)"
 *           (d) guardian allowed to unpause                    → test_gov2_guardian_cannot_unpause_operator /
 *               test_gov2_guardian_cannot_lift_global_pause "guardian cannot unpause"
 *           (e) global pause check moved after parsing        → test_gov2_global_pause_sigFails_before_parsing
 *               "paused validation must not call the token" / "... must not reach the price math"
 */
contract SuperPaymasterD5bGov2Test is Test {
    EntryPoint entryPoint;
    SimpleAccountFactory accountFactory;
    SuperPaymaster sp;
    SuperPaymasterLens lens;
    V55Registry registry;
    V55APNTs apnts;
    xPNTsFactoryV2 factory;
    xPNTsTokenV2 token;
    V55PriceFeed feed;

    uint256 constant OWNER_PK = 0xA0A0;
    address owner = address(0x0A11);
    address treasury = address(0x7EA);
    address operator = address(0x0BE);
    address guardian = address(0x6A2D);
    address stranger = address(0xBAD);
    address newOwner = address(0x0A12);
    address user;

    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    /// @dev guardian (20 B) + paused (1 B) share this sequential slot (allowed append, storage-layout/).
    uint256 constant GOV2_SLOT = 40;
    uint256 constant SP_LAYOUT_END = 65;       // first slot after SP's __gap (unchanged by D5b)
    uint256 constant REGISTRY_LAYOUT_END = 74; // first slot after Registry's __gap
    uint256 constant CACHED_PRICE_SLOT = 10;

    function setUp() public {
        vm.deal(owner, 10 ether);
        entryPoint = new EntryPoint();
        accountFactory = new SimpleAccountFactory(IEntryPoint(address(entryPoint)));
        user = address(accountFactory.createAccount(vm.addr(OWNER_PK), 0));

        vm.startPrank(owner);
        registry = new V55Registry();
        registry.setRole(keccak256("PAYMASTER_SUPER"), operator, true);
        registry.setRole(keccak256("COMMUNITY"), operator, true);
        apnts = new V55APNTs();
        feed = new V55PriceFeed();
        sp = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(entryPoint)), IRegistry(address(registry)), address(feed), owner, address(apnts), treasury, 3600
        );
        AOAProtocolRegistry aoa = new AOAProtocolRegistry(owner);
        GlobalTierSource tier = new GlobalTierSource(address(registry));
        aoa.bootstrapApprove(aoa.KIND_SP(), aoa.spKey(address(sp)));
        aoa.bootstrapApprove(aoa.KIND_TIER_SOURCE(), address(tier).codehash);
        aoa.seal();
        xPNTsTokenV2Ext text = new xPNTsTokenV2Ext(address(aoa));
        factory = new xPNTsFactoryV2(address(sp), address(registry), address(new xPNTsTokenV2(address(aoa), address(text))), address(tier));
        sp.setXPNTsFactory(address(factory));
        lens = new SuperPaymasterLens();
        vm.warp(block.timestamp + 2 hours);
        sp.updatePrice();
        sp.deposit{value: 1 ether}();
        apnts.mint(operator, 1_000_000 ether);
        vm.stopPrank();

        vm.prank(address(registry));
        sp.updateSBTStatus(user, true);

        vm.startPrank(operator);
        token = xPNTsTokenV2(factory.deployxPNTsToken("Comm", "xC", "Comm", "c.eth", 1 ether, address(0)));
        IV2Ext(address(token)).mint(user, 10_000 ether);
        apnts.approve(address(sp), type(uint256).max);
        sp.configureOperator(address(token), treasury);
        sp.deposit(100_000 ether);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ helpers

    function _op(uint256 nonce) internal view returns (PackedUserOperation memory op) {
        op.sender = user;
        op.nonce = nonce;
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(350_000), uint128(200_000)));
        op.preVerificationGas = 50_000;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei)));
        op.paymasterAndData = abi.encodePacked(
            address(sp), uint128(700_000), uint128(300_000), operator, type(uint256).max, address(token), uint8(0)
        );
        bytes32 h = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(OWNER_PK, MessageHashUtils.toEthSignedMessageHash(h));
        op.signature = abi.encodePacked(r, s, v);
    }

    function _validate(PackedUserOperation memory op, bytes32 h) internal returns (bytes memory ctx, uint256 vd) {
        vm.prank(address(entryPoint));
        (ctx, vd) = sp.validatePaymasterUserOp(op, h, 1e15);
    }

    function _erc7201(string memory ns) internal pure returns (bytes32) {
        return keccak256(abi.encode(uint256(keccak256(bytes(ns))) - 1)) & ~bytes32(uint256(0xff));
    }

    function _pendingSlot() internal pure returns (bytes32) {
        return _erc7201("aastar.storage.Ownership2Step");
    }

    function _rawSlots(address a, uint256 n) internal view returns (bytes32[] memory out) {
        out = new bytes32[](n);
        for (uint256 i; i < n; i++) out[i] = vm.load(a, bytes32(i));
    }

    function _registryProxy(address o) internal returns (Registry r) {
        r = UUPSDeployHelper.deployRegistryProxy(o, address(0x5701), address(0x5B7));
    }

    // =====================================================================
    // GOV-2 B.1–B.4: two-step ownership on the SP proxy (§2.1: overrides live in the core chain)
    // =====================================================================

    /// @notice §2.1 negative control: through the PROXY, transferOwnership only nominates.
    function test_gov2_sp_transferOwnership_via_proxy_is_two_step() public {
        vm.expectEmit(true, true, false, false, address(sp));
        emit Ownable2StepNamespaced.OwnershipTransferStarted(owner, newOwner);
        vm.prank(owner);
        sp.transferOwnership(newOwner);
        assertEq(sp.owner(), owner, "owner unchanged after transferOwnership (two-step)");
        assertEq(sp.pendingOwner(), newOwner, "pendingOwner() == nominee");
    }

    function test_gov2_sp_transferOwnership_requires_owner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sp.transferOwnership(stranger); // "non-owner nomination must revert"
        assertEq(sp.pendingOwner(), address(0), "no nomination recorded");
        assertEq(sp.owner(), owner);
    }

    function test_gov2_sp_nomination_replace_and_cancel() public {
        vm.startPrank(owner);
        sp.transferOwnership(newOwner);
        sp.transferOwnership(stranger); // replaces
        assertEq(sp.pendingOwner(), stranger, "second nomination replaces the first");
        sp.transferOwnership(address(0)); // cancels
        assertEq(sp.pendingOwner(), address(0), "address(0) cancels");
        vm.stopPrank();
        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        sp.acceptOwnership();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sp.acceptOwnership();
        assertEq(sp.owner(), owner);
    }

    function test_gov2_sp_accept_only_by_pending_and_clears_it() public {
        vm.prank(owner);
        sp.transferOwnership(newOwner);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sp.acceptOwnership();
        vm.prank(owner); // the current owner is not the nominee either
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        sp.acceptOwnership();

        vm.expectEmit(true, true, false, false, address(sp));
        emit Ownable.OwnershipTransferred(owner, newOwner);
        vm.prank(newOwner);
        sp.acceptOwnership();
        assertEq(sp.owner(), newOwner);
        assertEq(sp.pendingOwner(), address(0), "accept clears the nomination");
        // the old owner lost every owner power, including the upgrade
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        sp.setGuardian(owner);
    }

    /// @notice B.3: `initialize` goes through _transferOwnership → a nomination planted before
    ///         initialisation is cleared (every owner-changing path voids a stale nomination).
    function test_gov2_sp_initialize_clears_stale_nomination() public {
        SuperPaymaster impl = new SuperPaymaster(IEntryPoint(address(entryPoint)), IRegistry(address(registry)), address(feed));
        address proxy = address(new ERC1967Proxy(address(impl), ""));
        vm.store(proxy, _pendingSlot(), bytes32(uint256(uint160(stranger))));
        assertEq(SuperPaymaster(payable(proxy)).pendingOwner(), stranger, "precondition: stale nomination");
        SuperPaymaster(payable(proxy)).initialize(owner, address(apnts), treasury, 3600);
        assertEq(SuperPaymaster(payable(proxy)).pendingOwner(), address(0), "initialize cleared it");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        SuperPaymaster(payable(proxy)).acceptOwnership();
    }

    function test_gov2_sp_initialize_rejects_zero_owner() public {
        SuperPaymaster impl = new SuperPaymaster(IEntryPoint(address(entryPoint)), IRegistry(address(registry)), address(feed));
        vm.expectRevert(SuperPaymasterStorage.InvalidOwner.selector);
        new ERC1967Proxy(address(impl), abi.encodeCall(SuperPaymaster.initialize, (address(0), address(apnts), treasury, 3600)));
    }

    function test_gov2_sp_renounce_always_reverts() public {
        vm.prank(owner);
        vm.expectRevert(Ownable2StepNamespaced.OwnershipRenounceDisabled.selector);
        sp.renounceOwnership();
        vm.prank(stranger);
        vm.expectRevert(Ownable2StepNamespaced.OwnershipRenounceDisabled.selector);
        sp.renounceOwnership();
        assertEq(sp.owner(), owner);
    }

    /// @notice GOV-2 D: the ERC-7201 slot's POSITION (derived here from the namespace string) and
    ///         CONTENT, and that a nomination writes nothing in the sequential layout [0, end).
    function test_gov2_sp_pendingOwner_erc7201_slot() public {
        assertEq(_pendingSlot(), bytes32(0xdb5a3168abaa6147a9f3a4cb66016161119d4d50b6393344d27120286f742a00), "slot constant == formula");
        bytes32[] memory before = _rawSlots(address(sp), SP_LAYOUT_END);
        vm.prank(owner);
        sp.transferOwnership(newOwner);
        assertEq(vm.load(address(sp), _pendingSlot()), bytes32(uint256(uint160(newOwner))), "nominee stored in the ERC-7201 slot");
        bytes32[] memory after_ = _rawSlots(address(sp), SP_LAYOUT_END);
        for (uint256 i; i < SP_LAYOUT_END; i++) assertEq(after_[i], before[i], "sequential slot untouched by a nomination");
        assertEq(vm.load(address(sp), bytes32(0)), bytes32(uint256(uint160(owner))), "_owner still at slot 0");
    }

    // =====================================================================
    // GOV-2 B.6: guardian (SP only)
    // =====================================================================

    function test_gov2_setGuardian_only_owner_and_slot_packing() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        sp.setGuardian(stranger);

        vm.expectEmit(true, true, false, false, address(sp)); // emitter is the PROXY (DELEGATECALL)
        emit SuperPaymasterStorage.GuardianSet(address(0), guardian);
        vm.prank(owner);
        sp.setGuardian(guardian);
        assertEq(sp.guardian(), guardian);

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        sp.setGuardian(stranger); // the guardian cannot re-point itself

        vm.prank(guardian);
        sp.setGlobalPaused(true);
        assertEq(vm.load(address(sp), bytes32(GOV2_SLOT)), bytes32(uint256(uint160(guardian)) | (uint256(1) << 160)),
            "guardian + paused packed in ONE appended slot");
        assertEq(vm.load(address(sp), bytes32(GOV2_SLOT + 1)), bytes32(0), "gap starts right after");
    }

    function test_gov2_guardian_pauses_operator() public {
        vm.prank(owner);
        sp.setGuardian(guardian);
        vm.expectEmit(true, false, false, false, address(sp));
        emit SuperPaymasterStorage.OperatorPaused(operator);
        vm.prank(guardian);
        sp.setOperatorPaused(operator, true);
        (, , bool isPaused, , , , , , ) = sp.operators(operator);
        assertTrue(isPaused);
        PackedUserOperation memory op = _op(0);
        (bytes memory ctx, uint256 vd) = _validate(op, entryPoint.getUserOpHash(op));
        assertEq(vd & 1, 1, "paused operator -> SIG_FAILURE");
        assertEq(ctx.length, 0);
    }

    function test_gov2_guardian_cannot_unpause_operator() public {
        vm.prank(owner);
        sp.setGuardian(guardian);
        vm.prank(guardian);
        sp.setOperatorPaused(operator, true);
        vm.prank(guardian);
        vm.expectRevert(SuperPaymasterStorage.Unauthorized.selector);
        sp.setOperatorPaused(operator, false); // "guardian cannot unpause"
        (, , bool isPaused, , , , , , ) = sp.operators(operator);
        assertTrue(isPaused, "guardian cannot unpause: still paused");
        vm.prank(owner);
        sp.setOperatorPaused(operator, false);
        (, , isPaused, , , , , , ) = sp.operators(operator);
        assertFalse(isPaused, "owner (timelock) unpauses");
    }

    function test_gov2_guardian_cannot_lift_global_pause() public {
        vm.prank(owner);
        sp.setGuardian(guardian);
        vm.expectEmit(true, false, false, true, address(sp));
        emit SuperPaymasterStorage.GlobalPauseSet(guardian, true);
        vm.prank(guardian);
        sp.setGlobalPaused(true);
        assertTrue(sp.paused());
        vm.prank(guardian);
        vm.expectRevert(SuperPaymasterStorage.Unauthorized.selector);
        sp.setGlobalPaused(false); // "guardian cannot unpause"
        assertTrue(sp.paused(), "guardian cannot unpause: still paused");
        vm.prank(owner);
        sp.setGlobalPaused(false);
        assertFalse(sp.paused(), "owner (timelock) resumes");
    }

    function test_gov2_strangers_cannot_pause() public {
        vm.prank(stranger);
        vm.expectRevert(SuperPaymasterStorage.Unauthorized.selector);
        sp.setGlobalPaused(true);
        vm.prank(stranger);
        vm.expectRevert(SuperPaymasterStorage.Unauthorized.selector);
        sp.setOperatorPaused(operator, true);
        // guardian unset (address(0)) grants nothing either
        vm.prank(address(0));
        vm.expectRevert(SuperPaymasterStorage.Unauthorized.selector);
        sp.setGlobalPaused(true);
    }

    /// @notice The guardian can ONLY pause: no upgrade, no funds, no parameters, no ownership.
    function test_gov2_guardian_has_no_other_power() public {
        vm.prank(owner);
        sp.setGuardian(guardian);
        address newImpl = address(new SuperPaymaster(IEntryPoint(address(entryPoint)), IRegistry(address(registry)), address(feed)));
        bytes memory unauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian);
        vm.startPrank(guardian);
        vm.expectRevert(unauthorized);
        sp.upgradeToAndCall(newImpl, "");
        vm.expectRevert(unauthorized);
        sp.withdrawTo(payable(guardian), 1);
        vm.expectRevert(unauthorized);
        sp.unlockStake();
        vm.expectRevert(unauthorized);
        sp.withdrawProtocolRevenue(guardian, 1);
        vm.expectRevert(unauthorized);
        sp.queueGasParams(200_000, 160_000, 5_000, 175_000);
        vm.expectRevert(unauthorized);
        sp.setAPNTSPrice(0.021 ether);
        vm.expectRevert(unauthorized);
        sp.transferOwnership(guardian);
        vm.expectRevert(unauthorized);
        sp.setTreasury(guardian);
        vm.expectRevert(unauthorized);
        sp.slashOperator(operator, ISuperPaymaster.SlashLevel.MINOR, 1, "x");
        vm.stopPrank();
    }

    // =====================================================================
    // GOV-2 B.6: global pause in validation — before ANY parsing; postOp / release unaffected
    // =====================================================================

    /// forge-config: default.isolate = true
    function test_gov2_global_pause_sigFails_before_parsing() public {
        MockAgentIdentityRegistry agents = new MockAgentIdentityRegistry();
        vm.prank(owner);
        sp.setAgentRegistries(address(agents), address(0));
        vm.prank(owner);
        sp.setGlobalPaused(true);

        // (a) malformed paymasterAndData (20 bytes: no gas limits, no operator)
        PackedUserOperation memory bad = _op(0);
        bad.paymasterAndData = abi.encodePacked(address(sp));
        (bytes memory ctx, uint256 vd) = _validate(bad, keccak256("malformed"));
        assertEq(vd & 1, 1, "malformed op under global pause -> SIG_FAILURE");
        assertEq(ctx.length, 0);

        // (b) a well-formed op of an ELIGIBLE (SBT) sender with the price cache zeroed: unpaused, the
        //     reservation math reverts OracleError (= AA33, control below). Paused: SIG_FAILURE.
        vm.store(address(sp), bytes32(CACHED_PRICE_SLOT), bytes32(0));
        vm.expectCall(address(token), abi.encodeCall(IxPNTsTokenV2.exchangeRate, ()), 0);
        PackedUserOperation memory op = _op(0);
        (ctx, vd) = _validate(op, keccak256("wellformed"));
        // reaching this line = no revert: "paused validation must not reach the price math"
        assertEq(vd & 1, 1, "well-formed op under global pause -> SIG_FAILURE");
        assertEq(ctx.length, 0);

        // (c) a NON-SBT sender: unpaused, eligibility consults the agent registry (control below).
        PackedUserOperation memory stranger_ = _op(0);
        stranger_.sender = address(0xC0FFEE);
        vm.expectCall(address(agents), abi.encodeWithSignature("isRegisteredAgent(address)", stranger_.sender), 0);
        (ctx, vd) = _validate(stranger_, keccak256("stranger"));
        assertEq(vd & 1, 1);
        // the expectCall(…, 0) pair: "paused validation must not call the token" / the agent registry
    }

    /// @notice Positive controls for the instruments of the test above (same ops, NOT paused): the
    ///         zeroed price really reverts, the token and the agent registry really are called.
    function test_gov2_global_pause_controls_unpaused() public {
        MockAgentIdentityRegistry agents = new MockAgentIdentityRegistry();
        vm.prank(owner);
        sp.setAgentRegistries(address(agents), address(0));
        PackedUserOperation memory op = _op(0);
        PackedUserOperation memory stranger_ = _op(0);
        stranger_.sender = address(0xC0FFEE);

        vm.expectCall(address(token), abi.encodeCall(IxPNTsTokenV2.exchangeRate, ()), 1);
        vm.expectCall(address(agents), abi.encodeWithSignature("isRegisteredAgent(address)", stranger_.sender), 1);
        (, uint256 vd) = _validate(stranger_, keccak256("stranger"));
        assertEq(vd & 1, 1, "control: a non-SBT, non-agent sender is refused (after asking the registry)");
        (, vd) = _validate(op, keccak256("good"));
        assertEq(vd & 1, 0, "control: sponsorship works when not paused");
    }

    function test_gov2_global_pause_control_zero_price_reverts_unpaused() public {
        vm.store(address(sp), bytes32(CACHED_PRICE_SLOT), bytes32(0));
        PackedUserOperation memory op = _op(0);
        vm.prank(address(entryPoint));
        vm.expectRevert(SuperPaymasterStorage.OracleError.selector);
        sp.validatePaymasterUserOp(op, keccak256("zero-price"), 1e15);
    }

    /// @dev NOT isolated: validation and postOp must share one transaction (the token's transient
    ///      liveness marker), exactly as inside handleOps. The EntryPoint-level version of this —
    ///      a guardian pause executed mid-bundle — is in SuperPaymasterD5bUpgradeRace.t.sol.
    function test_gov2_pause_does_not_block_postOp_settlement() public {
        vm.prank(owner);
        sp.setGuardian(guardian);
        PackedUserOperation memory op = _op(0);
        bytes32 h = entryPoint.getUserOpHash(op);
        (bytes memory ctx, uint256 vd) = _validate(op, h);
        assertEq(vd & 1, 0);
        uint256 revBefore = sp.protocolRevenue();
        // guardian stops everything between validation and postOp (e.g. mid-bundle)
        vm.startPrank(guardian);
        sp.setGlobalPaused(true);
        sp.setOperatorPaused(operator, true);
        vm.stopPrank();
        vm.prank(address(entryPoint));
        sp.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 1e14, 1 gwei);
        assertTrue(token.usedOpHashes(h), "settled while paused");
        (address f, ) = sp.inflightOf(h);
        assertEq(f, address(0), "in-flight cleared while paused");
        assertGt(sp.protocolRevenue(), revBefore, "revenue booked while paused");
        assertEq(token.lockedOf(user), 0, "escrow consumed");
    }

    /// forge-config: default.isolate = true
    function test_gov2_pause_does_not_block_stale_release() public {
        vm.prank(owner);
        sp.setGuardian(guardian);
        PackedUserOperation memory op = _op(0);
        bytes32 h = entryPoint.getUserOpHash(op);
        (uint128 opBefore, , , , , , , , ) = sp.operators(operator);
        _validate(op, h); // postOp never runs
        vm.prank(guardian);
        sp.setGlobalPaused(true);
        sp.releaseStaleSponsorship(h); // new transaction (isolate): permissionless
        (uint128 opAfter, , , , , , , , ) = sp.operators(operator);
        assertEq(opAfter, opBefore, "operator a0 restored while paused");
        token.releaseStaleLock(user, h);
        assertEq(token.lockedOf(user), 0, "token-side stale release works while paused");
    }

    // =====================================================================
    // Split mechanics (D5b-design §2 items 2 and 4, §2.2, §2.3)
    // =====================================================================

    function test_d5b_fallback_is_non_payable() public {
        vm.deal(address(this), 1 ether);
        (bool ok, ) = address(sp).call{value: 1}("");
        assertFalse(ok, "plain ETH transfer still rejected (no receive, non-payable fallback)");
        (ok, ) = address(sp).call{value: 1}(abi.encodeCall(SuperPaymasterAdmin.updatePrice, ()));
        assertFalse(ok, "value on a routed (extension) selector rejected");
        (ok, ) = address(sp).call(abi.encodeWithSelector(bytes4(0xdeadbeef)));
        assertFalse(ok, "unknown selector reverts (extension has no fallback)");
        (ok, ) = address(sp).call(abi.encodeCall(SuperPaymasterAdmin.updatePrice, ()));
        assertTrue(ok, "control: the same routed call without value succeeds");
    }

    function test_d5b_extension_direct_calls_are_inert() public {
        SuperPaymaster impl = SuperPaymaster(payable(address(uint160(uint256(vm.load(address(sp), IMPL_SLOT))))));
        SuperPaymasterAdmin ext = SuperPaymasterAdmin(sp.EXTENSION());
        assertEq(address(ext), impl.EXTENSION(), "proxy reads the core implementation's immutable");
        assertEq(ext.owner(), address(0), "extension has no owner of its own");

        // no initializer on the extension
        (bool ok, ) = address(ext).call(abi.encodeCall(SuperPaymaster.initialize, (address(this), address(apnts), treasury, 3600)));
        assertFalse(ok, "extension exposes no initializer");

        // privileged functions fail against the extension's own (empty) storage
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        ext.setGuardian(owner);
        vm.prank(guardian);
        vm.expectRevert(SuperPaymasterStorage.Unauthorized.selector);
        ext.setGlobalPaused(true);
        vm.expectRevert(); // UUPS onlyProxy
        ext.upgradeToAndCall(address(impl), "");
        PackedUserOperation memory op0 = _op(0); // built BEFORE the prank (it calls the EntryPoint)
        vm.prank(address(entryPoint));
        vm.expectRevert(SuperPaymasterStorage.Unauthorized.selector);
        ext.validatePaymasterUserOp(op0, bytes32(0), 1);

        // a write that passes its check (the Registry is an immutable of the extension) lands in the
        // extension's own storage only — the proxy is untouched
        address someone = address(0x5011);
        vm.prank(address(registry));
        ext.updateSBTStatus(someone, true);
        assertTrue(ext.sbtHolders(someone), "written to the extension's own storage");
        assertFalse(sp.sbtHolders(someone), "proxy state untouched by a direct extension call");
        vm.prank(stranger);
        ext.updatePrice(); // permissionless keeper call: extension storage only
        (, uint256 extUpdatedAt, , ) = ext.cachedPrice();
        assertGt(extUpdatedAt, 0);
        assertEq(sp.paused(), false);

        // the core implementation itself is equally inert
        vm.expectRevert();
        impl.initialize(stranger, address(apnts), treasury, 3600);
    }

    /// @notice §2.2: the extension's immutables equal the core's (the deploy script re-checks this).
    function test_d5b_immutable_binding() public view {
        SuperPaymaster impl = SuperPaymaster(payable(address(uint160(uint256(vm.load(address(sp), IMPL_SLOT))))));
        SuperPaymasterAdmin ext = SuperPaymasterAdmin(impl.EXTENSION());
        assertEq(address(ext.entryPoint()), address(impl.entryPoint()), "entryPoint");
        assertEq(address(ext.REGISTRY()), address(impl.REGISTRY()), "REGISTRY");
        assertEq(address(ext.ETH_USD_PRICE_FEED()), address(impl.ETH_USD_PRICE_FEED()), "ETH_USD_PRICE_FEED");
        assertEq(address(impl.entryPoint()), address(entryPoint));
        assertGt(address(ext).code.length, 0);
    }

    /// @notice §2.3: the lens reads gasParams() and paused() — both extension selectors — through the
    ///         core's fallback, and still agrees with validation, including under a global pause.
    function test_d5b_lens_through_fallback_agrees_with_validation() public {
        PackedUserOperation memory op = _op(0);
        bytes32 h = entryPoint.getUserOpHash(op);
        (bool ok, bytes32 reason) = lens.dryRunValidation(address(sp), op, 1e15);
        assertTrue(ok, string(abi.encodePacked(reason)));
        (, uint256 vd) = _validate(op, h);
        assertEq(vd & 1, 0);

        vm.prank(owner);
        sp.setGlobalPaused(true);
        (ok, reason) = lens.dryRunValidation(address(sp), op, 1e15);
        assertFalse(ok, "lens reports the global pause");
        assertEq(reason, lens.DRYRUN_SPONSORSHIP_PAUSED());
        (, vd) = _validate(_op(1), keccak256("p"));
        assertEq(vd & 1, 1, "validation agrees: SIG_FAILURE");
    }

    // =====================================================================
    // Registry: GOV-2 two-step ownership only (spec B.5; no guardian)
    // =====================================================================

    function test_gov2_registry_two_step() public {
        Registry r = _registryProxy(owner);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        r.transferOwnership(stranger);

        bytes32[] memory before = _rawSlots(address(r), REGISTRY_LAYOUT_END);
        vm.prank(owner);
        r.transferOwnership(newOwner);
        assertEq(r.owner(), owner, "Registry: owner unchanged after transferOwnership");
        assertEq(r.pendingOwner(), newOwner);
        assertEq(vm.load(address(r), _pendingSlot()), bytes32(uint256(uint160(newOwner))), "Registry: ERC-7201 slot");
        bytes32[] memory after_ = _rawSlots(address(r), REGISTRY_LAYOUT_END);
        for (uint256 i; i < REGISTRY_LAYOUT_END; i++) assertEq(after_[i], before[i], "Registry sequential slot untouched");

        vm.prank(owner);
        r.transferOwnership(stranger);
        assertEq(r.pendingOwner(), stranger, "replace");
        vm.prank(newOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, newOwner));
        r.acceptOwnership();
        vm.prank(stranger);
        r.acceptOwnership();
        assertEq(r.owner(), stranger);
        assertEq(r.pendingOwner(), address(0), "accept clears");
        vm.prank(stranger);
        vm.expectRevert(Ownable2StepNamespaced.OwnershipRenounceDisabled.selector);
        r.renounceOwnership();
        vm.prank(stranger);
        r.transferOwnership(owner);
        vm.prank(stranger);
        r.transferOwnership(address(0));
        assertEq(r.pendingOwner(), address(0), "cancel");
    }

    function test_gov2_registry_initialize_rejects_zero_owner_and_clears_nomination() public {
        Registry impl = new Registry();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new ERC1967Proxy(address(impl), abi.encodeCall(Registry.initialize, (address(0), address(0x5701), address(0x5B7))));

        address proxy = address(new ERC1967Proxy(address(impl), ""));
        vm.store(proxy, _pendingSlot(), bytes32(uint256(uint160(stranger))));
        Registry(proxy).initialize(owner, address(0x5701), address(0x5B7));
        assertEq(Registry(proxy).pendingOwner(), address(0), "Registry initialize cleared a stale nomination");
        assertEq(Registry(proxy).owner(), owner);
        assertEq(Registry(proxy).version(), "Registry-5.9.0");
    }

    // =====================================================================
    // In-place upgrade from the previous release (c30854f9 fixtures) — state read-back unchanged
    // =====================================================================

    function _deployFixture(string memory file, bytes memory args) internal returns (address impl) {
        bytes memory init = abi.encodePacked(vm.parseBytes(vm.readFile(file)), args);
        assembly { impl := create(0, add(init, 32), mload(init)) }
        require(impl != address(0), "fixture deploy");
    }

    function test_d5b_sp_inplace_upgrade_from_previous_release_preserves_state() public {
        address oldImpl = _deployFixture("contracts/test/fixtures/superpaymaster-5.5.0-c30854f9-impl.creation.hex",
            abi.encode(address(entryPoint), address(registry), address(feed)));
        vm.startPrank(owner);
        SuperPaymaster p = SuperPaymaster(payable(address(new ERC1967Proxy(oldImpl,
            abi.encodeCall(SuperPaymaster.initialize, (owner, address(apnts), treasury, 3600))))));
        // populate state through the OLD implementation (its own selectors, no extension yet)
        p.setXPNTsFactory(address(factory));
        p.updatePrice();
        p.setProtocolFee(1500);
        p.queueGasParams(210_000, 170_000, 6_000, 180_000);
        p.queueBLSAggregator(address(0xB15));
        vm.stopPrank();
        vm.prank(address(registry));
        p.updateSBTStatus(user, true);

        bytes32[] memory before = _rawSlots(address(p), SP_LAYOUT_END);
        bytes32 sbt = vm.load(address(p), keccak256(abi.encode(user, uint256(7))));
        address newImpl = address(new SuperPaymaster(IEntryPoint(address(entryPoint)), IRegistry(address(registry)), address(feed)));
        vm.prank(owner);
        p.upgradeToAndCall(newImpl, "");
        assertEq(address(uint160(uint256(vm.load(address(p), IMPL_SLOT)))), newImpl, "impl slot");
        bytes32[] memory after_ = _rawSlots(address(p), SP_LAYOUT_END);
        for (uint256 i; i < SP_LAYOUT_END; i++) assertEq(after_[i], before[i], "raw sequential slot unchanged by the upgrade");
        assertEq(vm.load(address(p), keccak256(abi.encode(user, uint256(7)))), sbt, "sbtHolders sample");
        assertEq(p.owner(), owner);
        assertEq(p.pendingOwner(), address(0));
        assertEq(p.guardian(), address(0));
        assertFalse(p.paused());
        assertEq(p.protocolFeeBPS(), 1500);
        (, SuperPaymasterStorage.PendingGasParams memory pend) = p.gasParams();
        assertEq(pend.minPostOpGas, 210_000, "queued gas params readable through the extension");
        assertEq(p.pendingBLSAgg(), address(0xB15));
        // the upgraded proxy now has the two-step transfer
        vm.prank(owner);
        p.transferOwnership(newOwner);
        assertEq(p.owner(), owner);
    }

    function test_d5b_registry_inplace_upgrade_from_5_8_0_preserves_state() public {
        address oldImpl = _deployFixture("contracts/test/fixtures/registry-5.8.0-c30854f9-impl.creation.hex", "");
        Registry r = Registry(address(new ERC1967Proxy(oldImpl,
            abi.encodeCall(Registry.initialize, (owner, address(0x5701), address(0x5B7))))));
        assertEq(r.version(), "Registry-5.8.0", "precondition: previous release");
        vm.prank(owner);
        r.setSuperPaymaster(address(sp));
        bytes32[] memory before = _rawSlots(address(r), REGISTRY_LAYOUT_END);
        address newImpl = address(new Registry());
        vm.prank(owner);
        r.upgradeToAndCall(newImpl, "");
        assertEq(address(uint160(uint256(vm.load(address(r), IMPL_SLOT)))), newImpl);
        assertEq(r.version(), "Registry-5.9.0");
        bytes32[] memory after_ = _rawSlots(address(r), REGISTRY_LAYOUT_END);
        for (uint256 i; i < REGISTRY_LAYOUT_END; i++) assertEq(after_[i], before[i], "Registry raw slot unchanged by the upgrade");
        assertEq(r.owner(), owner);
        assertEq(r.pendingOwner(), address(0));
        assertEq(r.SUPER_PAYMASTER(), address(sp));
    }

    // =====================================================================
    // M1 / A5s rehearsal: real 48h TimelockController accepts BOTH proxies + setGuardian in ONE batch
    // =====================================================================

    function test_gov2_timelock_scheduleBatch_accepts_both_and_sets_guardian() public {
        Registry r = _registryProxy(owner);
        address multisig = address(0x51eD);
        address safe = multisig;
        address[] memory prop = new address[](1);
        prop[0] = multisig;
        address[] memory exec = new address[](1);
        exec[0] = multisig; // executor = multisig only (spec M1)
        TimelockController tl = new TimelockController(48 hours, prop, exec, address(0));

        vm.startPrank(owner);
        sp.transferOwnership(address(tl));
        r.transferOwnership(address(tl));
        vm.stopPrank();
        assertEq(sp.owner(), owner, "EOA still owner after step 1 (nomination only)");

        address[] memory targets = new address[](3);
        targets[0] = address(sp);
        targets[1] = address(r);
        targets[2] = address(sp);
        uint256[] memory values = new uint256[](3);
        bytes[] memory payloads = new bytes[](3);
        payloads[0] = abi.encodeCall(Ownable2StepNamespaced.acceptOwnership, ());
        payloads[1] = abi.encodeCall(Ownable2StepNamespaced.acceptOwnership, ());
        payloads[2] = abi.encodeCall(SuperPaymasterAdmin.setGuardian, (safe));
        bytes32 salt = keccak256("A5s");
        vm.prank(multisig);
        tl.scheduleBatch(targets, values, payloads, bytes32(0), salt, 48 hours);

        vm.warp(block.timestamp + 48 hours - 1);
        vm.prank(multisig);
        vm.expectRevert(); // TimelockUnexpectedOperationState: not ready
        tl.executeBatch(targets, values, payloads, bytes32(0), salt);
        vm.warp(block.timestamp + 1);
        vm.prank(stranger);
        vm.expectRevert(); // AccessControlUnauthorizedAccount: executor is the multisig only
        tl.executeBatch(targets, values, payloads, bytes32(0), salt);
        vm.prank(multisig);
        tl.executeBatch(targets, values, payloads, bytes32(0), salt);

        assertEq(sp.owner(), address(tl), "SP owner == timelock");
        assertEq(r.owner(), address(tl), "Registry owner == timelock");
        assertEq(sp.pendingOwner(), address(0));
        assertEq(r.pendingOwner(), address(0));
        assertEq(sp.guardian(), safe, "guardian set in the same batch");
        assertEq(tl.getMinDelay(), 48 hours);
        // negative: the former EOA owner lost upgrade power
        address newImpl = address(new SuperPaymaster(IEntryPoint(address(entryPoint)), IRegistry(address(registry)), address(feed)));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        sp.upgradeToAndCall(newImpl, "");
    }

    /// @notice The natural abort point: a timelock that is not the nominee cannot accept; the EOA stays owner.
    function test_gov2_misconfigured_timelock_cannot_accept() public {
        address multisig = address(0x51eD);
        address[] memory prop = new address[](1);
        prop[0] = multisig;
        TimelockController right = new TimelockController(48 hours, prop, prop, address(0));
        TimelockController wrong = new TimelockController(48 hours, prop, prop, address(0));
        vm.prank(owner);
        sp.transferOwnership(address(right));
        bytes memory data = abi.encodeCall(Ownable2StepNamespaced.acceptOwnership, ());
        vm.prank(multisig);
        wrong.schedule(address(sp), 0, data, bytes32(0), bytes32(0), 48 hours);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(wrong)));
        wrong.execute(address(sp), 0, data, bytes32(0), bytes32(0));
        assertEq(sp.owner(), owner, "EOA still owner: misconfigured timelock is a natural abort point");
    }
}
