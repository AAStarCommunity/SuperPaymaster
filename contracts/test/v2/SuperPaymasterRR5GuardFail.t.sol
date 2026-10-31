// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import {DeploymentGasFixtures as GasFixture} from "../helpers/DeploymentGasFixtures.sol";
import { SuperPaymasterAdminCalls } from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
using SuperPaymasterAdminCalls for SuperPaymaster; // D5b: extension functions on a SuperPaymaster reference

import "forge-std/Test.sol";
import {SimpleAccount} from "@account-abstraction-v7/samples/SimpleAccount.sol";
import {SimpleAccountFactory} from "@account-abstraction-v7/samples/SimpleAccountFactory.sol";
import {MessageHashUtils} from "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";
import {V55FuzzTarget} from "../helpers/V55FuzzFixtures.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/interfaces/v3/IRegistry.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import { UUPSDeployHelper } from "../helpers/UUPSDeployHelper.sol";
import { AOAProtocolRegistry } from "src/tokens/v2/AOAProtocolRegistry.sol";
import { GlobalTierSource } from "src/tokens/v2/GlobalTierSource.sol";
import { xPNTsTokenV2 } from "src/tokens/v2/xPNTsTokenV2.sol";
import { xPNTsTokenV2Ext } from "src/tokens/v2/xPNTsTokenV2Ext.sol";
import { xPNTsFactoryV2 } from "src/tokens/v2/xPNTsFactoryV2.sol";
import { V55Registry, V55PriceFeed, V55APNTs, IV2Ext } from "../helpers/V55TestFixtures.sol";

/// @notice RR-5: exact entry-guard failures, adjacent success, snapshot isolation and recovery.
/// @dev Failure/rollback assertions here are DIRECT CALL ONLY. Deployment MIN_POST=440k
/// exceeds SETTLE=420k by 20k; mid-bundle changes cannot move the captured bound.
/// The previous-release 352-byte context uses LEGACY_SETTLE=160k, below the deployment
/// minimum as well. No real EntryPoint PostOpGasTooLow event/deposit/rollback claim is
/// made: lowering gas after validation or forging a context would fake reachability.
/// Recovery uses the real transaction boundary between setUp and each test, including
/// Amsterdam --no-isolate; neither transient slots nor production code are patched.
abstract contract RR5GuardBase is Test {
    address constant EP = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    SuperPaymaster sp;
    xPNTsTokenV2 token;
    V55Registry registry;
    address owner = address(0x0A11);
    address operator = address(0x0BE);
    address user = address(0xA11CE);
    address stranger = address(0xBAD);


    bytes storedContext;
    bytes32 constant HASH = keccak256("rr5-guard");
    uint256 beforeBalance;
    uint256 beforeOperator;
    uint256 beforeRevenue;
    uint256 beforeSupply;
    uint256 reserved;
    bool setupCallOK;
    bytes setupReturn;
    function creditMode() internal pure virtual returns (bool);

    function setUp() public {
        vm.etch(EP, vm.parseBytes(vm.readFile("contracts/test/fixtures/entrypoint-v0.7.runtime.hex")));
        vm.deal(owner, 10 ether);
        vm.startPrank(owner);
        registry = new V55Registry();
        registry.setRole(keccak256("PAYMASTER_SUPER"), operator, true);
        registry.setRole(keccak256("COMMUNITY"), operator, true);
        V55APNTs apnts = new V55APNTs();
        sp = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(EP), IRegistry(address(registry)), address(new V55PriceFeed()), owner, address(apnts), owner, 3600
        );
        GasFixture.configure(sp);
        AOAProtocolRegistry aoa = new AOAProtocolRegistry(owner);
        GlobalTierSource tier = new GlobalTierSource(address(registry));
        aoa.bootstrapApprove(aoa.KIND_SP(), aoa.spKey(address(sp)));
        aoa.bootstrapApprove(aoa.KIND_TIER_SOURCE(), address(tier).codehash);
        aoa.seal();
        xPNTsTokenV2Ext ext = new xPNTsTokenV2Ext(address(aoa));
        xPNTsFactoryV2 factory = new xPNTsFactoryV2(address(sp), address(registry), address(new xPNTsTokenV2(address(aoa), address(ext))), address(tier));
        sp.setXPNTsFactory(address(factory));
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        sp.updatePrice();
        apnts.mint(operator, 1_000_000 ether);
        vm.stopPrank();
        vm.startPrank(operator);
        token = xPNTsTokenV2(factory.deployxPNTsToken("Comm", "xC", "Comm", "c.eth", 1 ether, address(0)));
        apnts.approve(address(sp), type(uint256).max);
        sp.configureOperator(address(token), owner);
        sp.deposit(100_000 ether);
        IV2Ext(address(token)).mint(user, 10_000 ether);
        vm.stopPrank();
        vm.prank(address(registry));
        sp.updateSBTStatus(user, true);
        if (creditMode()) {
            uint256 balance = token.balanceOf(user);
            vm.prank(user);
            token.transfer(stranger, balance);
            registry.setCreditLimit(user, 50_000 ether);
            vm.prank(operator);
            IV2Ext(address(token)).queueCreditPolicy(2);
            vm.warp(vm.getBlockTimestamp() + 48 hours);
            IV2Ext(address(token)).executeCreditPolicy();
            sp.updatePrice();
            vm.prank(user);
            IV2Ext(address(token)).requestCredit(50_000 ether);
        }
        admit();
    }

    function admit() internal {
        beforeBalance = token.balanceOf(user);
        beforeSupply = token.totalSupply();
        beforeOperator = operatorBalance();
        beforeRevenue = sp.protocolRevenue();
        PackedUserOperation memory op;
        op.sender = user;
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(400_000), uint128(200_000)));
        op.preVerificationGas = 50_000;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei)));
        op.paymasterAndData = abi.encodePacked(address(sp), uint128(GasFixture.PM_VERIFICATION),
            uint128(GasFixture.MIN_POST), operator, type(uint256).max, address(token), uint8(0));
        vm.prank(EP);
        uint256 vd;
        (storedContext, vd) = sp.validatePaymasterUserOp(op, HASH, 1e16);
        assertEq(vd & 1, 0);
        assertEq(storedContext.length, 384);
        SuperPaymaster.OpCtx memory c = abi.decode(storedContext, (SuperPaymaster.OpCtx));
        assertEq(c.mode, creditMode() ? 2 : 1);
        reserved = c.a0;
        // A failed call in the validation transaction leaves the record for later recovery.
        (setupCallOK, setupReturn) = invoke(GasFixture.SETTLE - 1);
    }

    function operatorBalance() internal view returns (uint256) {
        (uint128 b,,,,,,,,) = sp.operators(operator);
        return b;
    }

    function invoke(uint256 gasBudget) internal returns (bool, bytes memory) {
        bytes memory data = abi.encodeCall(IPaymaster.postOp,
            (IPaymaster.PostOpMode.opSucceeded, storedContext, 1e14, 1 gwei));
        vm.prank(EP);
        return address(sp).call{gas: gasBudget}(data);
    }

    function exactGuard(bool ok, bytes memory ret) internal pure {
        assertFalse(ok, "must fail at guard");
        assertEq(ret, abi.encodeWithSelector(SuperPaymasterStorage.PostOpGasTooLow.selector), "exact guard, not OOG");
    }

    function assertPending() internal view {
        assertFalse(token.usedOpHashes(HASH));
        assertEq(sp.protocolRevenue(), beforeRevenue);
        assertEq(token.balanceOf(user), beforeBalance);
        assertEq(token.totalSupply(), beforeSupply);
        assertEq(token.debts(user), 0);
        (address who, uint256 a0) = sp.inflightOf(HASH);
        assertEq(who, operator);
        assertEq(a0, reserved);
        assertEq(operatorBalance(), beforeOperator - reserved);
        if (creditMode()) {
            assertEq(token.creditReservationOf(HASH, user).locker, address(sp));
            assertEq(token.creditReservationOf(HASH, user).amount, reserved);
            assertEq(token.creditReservedOf(user), reserved);
        } else {
            assertEq(token.lockOf(HASH, user).locker, address(sp));
            assertEq(token.lockOf(HASH, user).xLocked, reserved);
            assertEq(token.lockedOf(user), reserved);
        }
    }

    function assertSettled() internal view {
        assertTrue(token.usedOpHashes(HASH));
        (address who,) = sp.inflightOf(HASH);
        assertEq(who, address(0));
        assertEq(token.lockOf(HASH, user).locker, address(0));
        assertEq(token.creditReservationOf(HASH, user).locker, address(0));
        assertEq(token.lockedOf(user), 0);
        assertEq(token.creditReservedOf(user), 0);
        uint256 charge = sp.protocolRevenue() - beforeRevenue;
        assertGt(charge, 0);
        assertEq(beforeOperator - operatorBalance(), charge);
        if (creditMode()) assertEq(token.debts(user), charge);
        else assertEq(beforeBalance - token.balanceOf(user), charge);
    }

    function test_RR5_exactSelector_adjacentBoundary() public {
        exactGuard(setupCallOK, setupReturn);
        release();
        admit();
        exactGuard(setupCallOK, setupReturn);
        uint256 lo = GasFixture.SETTLE - 1;
        uint256 hi = GasFixture.MIN_POST + 100_000;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            uint256 snapshot = vm.snapshot();
            (bool ok, bytes memory ret) = invoke(mid);
            if (ok) { assertSettled(); hi = mid; }
            else { exactGuard(ok, ret); assertPending(); lo = mid; }
            assertTrue(vm.revertTo(snapshot));
        }
        emit log_named_uint("last guard-fail call gas", lo);
        emit log_named_uint("first complete settlement call gas", hi);
        (bool ok, bytes memory ret) = invoke(lo);
        exactGuard(ok, ret);
        assertPending();
        (ok, ret) = invoke(hi);
        assertTrue(ok, "adjacent upper boundary settles");
        assertEq(ret.length, 0);
        assertSettled();
    }

    function test_RR5_snapshot_not_live_bound() public {
        exactGuard(setupCallOK, setupReturn);
        release();
        admit();
        exactGuard(setupCallOK, setupReturn);
        vm.prank(owner);
        sp.queueGasParams(1_020_000, 1_000_000, GasFixture.WRAP, GasFixture.POSTOP);
        vm.warp(vm.getBlockTimestamp() + 48 hours);
        vm.prank(owner);
        sp.executeGasParams();
        (bool ok,) = invoke(600_000);
        assertTrue(ok, "validation snapshot wins over larger live bound");
        assertSettled();
    }

    /// @notice Real EntryPoint negative control: deployment minimum settles and exact ETH cost
    /// is charged. This does not claim to exercise the unreachable guard-failure event path.
    function test_RR5_realEntryPoint_minimum_negativeControl() public {
        IEntryPoint ep = IEntryPoint(EP);
        SimpleAccountFactory factory = new SimpleAccountFactory(ep);
        address account = address(factory.createAccount(vm.addr(0xC001), 0));
        V55FuzzTarget target = new V55FuzzTarget();
        vm.prank(address(registry));
        sp.updateSBTStatus(account, true);
        vm.prank(operator);
        IV2Ext(address(token)).mint(account, 10_000 ether);
        vm.deal(address(this), 1 ether);
        ep.depositTo{value: 1 ether}(address(sp));
        PackedUserOperation memory op;
        op.sender = account;
        op.callData = abi.encodeCall(SimpleAccount.execute,
            (address(target), 0, abi.encodeCall(V55FuzzTarget.hit, (HASH))));
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(400_000), uint128(300_000)));
        op.preVerificationGas = 50_000;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei)));
        op.paymasterAndData = abi.encodePacked(address(sp), uint128(GasFixture.PM_VERIFICATION),
            uint128(GasFixture.MIN_POST), operator, type(uint256).max, address(token), uint8(0));
        bytes32 hash = ep.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 sigS) = vm.sign(0xC001, MessageHashUtils.toEthSignedMessageHash(hash));
        op.signature = abi.encodePacked(r, sigS, v);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = op;
        uint256 depositBefore = ep.balanceOf(address(sp));
        vm.recordLogs();
        ep.handleOps(ops, payable(stranger));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 events;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != EP || logs[i].topics.length == 0) continue;
            assertTrue(logs[i].topics[0] != keccak256("PostOpRevertReason(bytes32,address,uint256,bytes)"));
            if (logs[i].topics[0] == keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)")) {
                assertEq(logs[i].topics[1], hash);
                (, bool success, uint256 cost,) = abi.decode(logs[i].data, (uint256, bool, uint256, uint256));
                assertTrue(success);
                assertGt(cost, 0);
                assertEq(depositBefore - ep.balanceOf(address(sp)), cost);
                events++;
            }
        }
        assertEq(events, 1);
        assertEq(target.hits(HASH), 1);
        assertTrue(token.usedOpHashes(hash));
        assertEq(token.lockedOf(account), 0);
    }

    function release() internal {
        if (creditMode()) token.releaseStaleCredit(user, HASH);
        else token.releaseStaleLock(user, HASH);
        sp.releaseStaleSponsorship(HASH);
    }

    function test_RR5_guardFail_staleRecovery() public {
        exactGuard(setupCallOK, setupReturn);
        assertPending();
        if (creditMode()) token.releaseStaleCredit(user, HASH);
        else token.releaseStaleLock(user, HASH);
        sp.releaseStaleSponsorship(HASH);
        assertEq(operatorBalance(), beforeOperator);
        assertEq(token.balanceOf(user), beforeBalance);
        assertEq(token.totalSupply(), beforeSupply);
        assertEq(token.debts(user), 0);
        assertEq(sp.protocolRevenue(), beforeRevenue);
        assertEq(token.lockedOf(user), 0);
        assertEq(token.creditReservedOf(user), 0);
        assertEq(token.lockOf(HASH, user).locker, address(0));
        assertEq(token.creditReservationOf(HASH, user).locker, address(0));
        (address who, uint256 a0) = sp.inflightOf(HASH);
        assertEq(who, address(0));
        assertEq(a0, 0);
        assertFalse(token.usedOpHashes(HASH));
        (, uint256 usedAllowance) = token.autoAllowance(user, address(sp));
        (, uint256 usedTotal) = token.userTotal(user);
        assertEq(usedAllowance, 0);
        assertEq(usedTotal, 0);
        sp.releaseStaleSponsorship(HASH);
        assertEq(operatorBalance(), beforeOperator, "idempotent recovery");
    }

    /// @notice Diagnostic only (no assertion): classify every call gas from SETTLE to 900k in 2k steps as
    ///         guard-fail (PostOpGasTooLow), other failure (OOG past the guard) or settled, and log the bands.
    function test_RR5_diag_scan_band() public {
        release();
        admit();
        uint256 lastGuard; uint256 firstOk; uint256 oogLo; uint256 oogHi; uint256 nOog;
        bytes32 guardRet = keccak256(abi.encodeWithSelector(SuperPaymasterStorage.PostOpGasTooLow.selector));
        for (uint256 g = GasFixture.SETTLE; g <= 900_000; g += 2_000) {
            uint256 snap = vm.snapshot();
            (bool ok, bytes memory ret) = invoke(g);
            if (ok) { if (firstOk == 0) firstOk = g; }
            else if (keccak256(ret) == guardRet) lastGuard = g;
            else { if (oogLo == 0) oogLo = g; oogHi = g; nOog++; }
            vm.revertTo(snap);
        }
        emit log_named_uint("scan last guard-fail call gas", lastGuard);
        emit log_named_uint("scan first non-guard failure call gas", oogLo);
        emit log_named_uint("scan last non-guard failure call gas", oogHi);
        emit log_named_uint("scan non-guard failures (2k steps)", nOog);
        emit log_named_uint("scan first settled call gas", firstOk);
    }
}

contract SuperPaymasterRR5GuardBalanceTest is RR5GuardBase {
    function creditMode() internal pure override returns (bool) { return false; }
}

contract SuperPaymasterRR5GuardCreditTest is RR5GuardBase {
    function creditMode() internal pure override returns (bool) { return true; }
}
