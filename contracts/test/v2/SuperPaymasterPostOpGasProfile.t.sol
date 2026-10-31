// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import {SelectedGasFixtures as GasFixture} from "../helpers/SelectedGasFixtures.sol";
import {SuperPaymasterAdminCalls} from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
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
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import {AOAProtocolRegistry} from "src/tokens/v2/AOAProtocolRegistry.sol";
import {GlobalTierSource} from "src/tokens/v2/GlobalTierSource.sol";
import {xPNTsTokenV2} from "src/tokens/v2/xPNTsTokenV2.sol";
import {xPNTsTokenV2Ext} from "src/tokens/v2/xPNTsTokenV2Ext.sol";
import {xPNTsFactoryV2} from "src/tokens/v2/xPNTsFactoryV2.sol";
import {V55Registry, V55PriceFeed, V55APNTs, IV2Ext} from "../helpers/V55TestFixtures.sol";

import {ProfilePaymaster} from "../helpers/ProfilePaymaster.sol";

/// @dev Every Forge invocation deploys in setUp; no snapshot/revertTo.
/// Validation and settlement share the test transaction. One sponsored op per bundle.
abstract contract PostOpProfileFixture is Test {
    /// @dev Revert data of the most recent direct postOp call, so a failure can be classified.
    bytes internal lastDirectRet;

    address constant EP = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    SuperPaymaster sp;
    xPNTsTokenV2 token;
    V55Registry registry;
    address owner = address(0x0A11);
    address operator = address(0x0BE);
    address user = address(0xA11CE);
    address stranger = address(0xBAD);
    bytes32 constant HASH = keccak256("profile");

    function fresh(bool credit, bool probe) internal {
        vm.etch(EP, vm.parseBytes(vm.readFile("contracts/test/fixtures/entrypoint-v0.7.runtime.hex")));
        vm.deal(owner, 10 ether);
        vm.startPrank(owner);
        registry = new V55Registry();
        registry.setRole(keccak256("PAYMASTER_SUPER"), operator, true);
        registry.setRole(keccak256("COMMUNITY"), operator, true);
        V55APNTs apnts = new V55APNTs();
        sp = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(EP),
            IRegistry(address(registry)),
            address(new V55PriceFeed()),
            owner,
            address(apnts),
            owner,
            3600
        );
        if (probe) {
            ProfilePaymaster impl =
                new ProfilePaymaster(IEntryPoint(EP), IRegistry(address(registry)), address(new V55PriceFeed()));
            sp.upgradeToAndCall(address(impl), "");
        }
        GasFixture.configure(sp);
        AOAProtocolRegistry aoa = new AOAProtocolRegistry(owner);
        GlobalTierSource tier = new GlobalTierSource(address(registry));
        aoa.bootstrapApprove(aoa.KIND_SP(), aoa.spKey(address(sp)));
        aoa.bootstrapApprove(aoa.KIND_TIER_SOURCE(), address(tier).codehash);
        aoa.seal();
        xPNTsTokenV2Ext ext = new xPNTsTokenV2Ext(address(aoa));
        xPNTsFactoryV2 factory = new xPNTsFactoryV2(
            address(sp), address(registry), address(new xPNTsTokenV2(address(aoa), address(ext))), address(tier)
        );
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
        sp.setOperatorLimits(60);
        IV2Ext(address(token)).mint(user, 10_000 ether);
        vm.stopPrank();
        vm.prank(address(registry));
        sp.updateSBTStatus(user, true);
        if (credit) {
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
    }

    IEntryPoint ep = IEntryPoint(EP);
    address account;
    address realAccount;
    V55FuzzTarget target;
    function creditMode() internal pure virtual returns (bool);

    function probeMode() internal pure virtual returns (bool) {
        return false;
    }

    function setUp() public virtual {
        fresh(creditMode(), probeMode());

        account = user;
        target = new V55FuzzTarget();
        {
            SimpleAccountFactory factory = new SimpleAccountFactory(ep);
            account = address(factory.createAccount(vm.addr(0xC001), 0));
            vm.prank(address(registry));
            sp.updateSBTStatus(account, true);
            if (creditMode()) {
                registry.setCreditLimit(account, 50_000 ether);
                vm.prank(account);
                IV2Ext(address(token)).requestCredit(50_000 ether);
            } else {
                vm.prank(operator);
                IV2Ext(address(token)).mint(account, 10_000 ether);
            }
            vm.deal(address(this), 1 ether);
            ep.depositTo{value: 1 ether}(address(sp));
        }
        realAccount = account;
        assertEq(sp.protocolRevenue(), 0);
        assertEq(token.debts(account), 0);
    }

    function sample(uint256 budget, bool credit, bool realEP, bool probe) public returns (bool ok) {
        address account = realEP ? realAccount : user;
        PackedUserOperation memory op;
        op.sender = account;
        op.callData =
            abi.encodeCall(SimpleAccount.execute, (address(target), 0, abi.encodeCall(V55FuzzTarget.hit, (HASH))));
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(400_000), uint128(300_000)));
        op.preVerificationGas = 50_000;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei)));
        op.paymasterAndData = abi.encodePacked(
            address(sp),
            uint128(GasFixture.PM_VERIFICATION),
            uint128(realEP ? budget : GasFixture.MIN_POST()),
            operator,
            type(uint256).max,
            address(token),
            uint8(0)
        );
        bytes32 hash = ep.getUserOpHash(op);
        if (realEP) {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xC001, MessageHashUtils.toEthSignedMessageHash(hash));
            op.signature = abi.encodePacked(r, s, v);
            PackedUserOperation[] memory ops = new PackedUserOperation[](1);
            ops[0] = op;
            vm.recordLogs();
            try ep.handleOps(ops, payable(stranger)) {}
            catch (bytes memory reason) {
                assertLt(budget, GasFixture.MIN_POST(), "unexpected handleOps rejection");
                assertEq(
                    reason, abi.encodeWithSelector(IEntryPoint.FailedOp.selector, uint256(0), "AA34 signature error")
                );
                return false;
            }
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 completed;
            uint256 failures;
            uint256 trajectories;
            for (uint256 i; i < logs.length; i++) {
                if (logs[i].emitter == address(sp) && logs[i].topics[0] == keccak256("Trajectory(uint256[8])")) {
                    trajectories++;
                    uint256[8] memory g = abi.decode(logs[i].data, (uint256[8]));
                    uint256[8] memory expected;
                    if (vm.envOr("PROFILE_AMSTERDAM", false)) {
                        expected = credit
                            ? [uint256(421153), 420876, 311132, 90305, 157476, 255195, 143896, 141720]
                            : [uint256(421153), 420876, 311132, 90305, 237508, 335227, 223928, 221752];
                    } else {
                        expected = credit
                            ? [uint256(428353), 428076, 406352, 361565, 311016, 310815, 287536, 285360]
                            : [uint256(428353), 428076, 406352, 361565, 317428, 317227, 293948, 291772];
                    }
                    uint256 low = g[0];
                    for (uint256 j; j < 8; j++) {
                        assertEq(g[j], expected[j], "frozen gasleft checkpoint");
                        emit log_named_uint("checkpoint gasleft", g[j]);
                        if (g[j] < low) low = g[j];
                    }
                    emit log_named_uint("checkpoint peak", g[0] - low);
                    emit log_named_uint("checkpoint net", g[0] - g[7]);
                }
                if (logs[i].emitter != EP) continue;
                if (logs[i].topics[0] == keccak256("PostOpRevertReason(bytes32,address,uint256,bytes)")) failures++;
                if (
                    logs[i].topics[0]
                        == keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)")
                ) completed++;
            }
            assertEq(trajectories, probe ? 1 : 0);
            assertEq(completed, 1);
            ok = failures == 0;
            assertEq(target.hits(HASH), ok ? 1 : 0);
        } else {
            vm.prank(EP);
            (bytes memory context, uint256 vd) = sp.validatePaymasterUserOp(op, hash, 1e16);
            assertEq(vd & 1, 0);
            assertEq(abi.decode(context, (SuperPaymaster.OpCtx)).mode, credit ? 2 : 1);
            vm.prank(EP);
            (ok, lastDirectRet) = address(sp).call{gas: budget}(
                abi.encodeCall(IPaymaster.postOp, (IPaymaster.PostOpMode.opSucceeded, context, 1e14, 1 gwei))
            );
        }
        assertEq(token.usedOpHashes(hash), ok);
        if (ok) {
            assertGt(sp.protocolRevenue(), 0);
            assertEq(token.creditReservedOf(account), 0);
            assertEq(token.lockedOf(account), 0);
            if (credit) assertGt(token.debts(account), 0);
            else assertEq(token.debts(account), 0);
        }
    }
}

abstract contract PostOpProfileBoundary is PostOpProfileFixture {
    function directMinimum() internal returns (uint256) {
        return vm.envOr("PROFILE_AMSTERDAM", false) ? 438828 : 431514;
    }

    function test_entrypoint_minimum() public {
        assertTrue(sample(440000, creditMode(), true, false));
    }

    function test_entrypoint_minimum_minus_one() public {
        assertFalse(sample(439999, creditMode(), true, false));
    }

    function test_direct_minimum() public {
        assertTrue(sample(directMinimum(), creditMode(), false, false));
    }

    function test_direct_minimum_minus_one() public {
        assertFalse(sample(directMinimum() - 1, creditMode(), false, false));
        // The failure just below the minimum is the entry guard itself, not an out-of-gas past it.
        assertEq(lastDirectRet, abi.encodeWithSelector(SuperPaymasterStorage.PostOpGasTooLow.selector), "guard, not OOG");
    }

    /// @dev Amsterdam only: the stable-engine guard boundary (431,514) is still rejected by the guard,
    ///      so the window up to the Amsterdam minimum is guard-fail at both ends, not a non-guard band.
    function test_direct_stable_boundary_is_guard_on_amsterdam() public {
        if (!vm.envOr("PROFILE_AMSTERDAM", false)) return;
        assertFalse(sample(431514, creditMode(), false, false));
        assertEq(lastDirectRet, abi.encodeWithSelector(SuperPaymasterStorage.PostOpGasTooLow.selector), "guard, not OOG");
    }

    function test_search_sample() public {
        uint256 budget = vm.envOr("PROFILE_BUDGET", uint256(440000));
        bool realEP = vm.envOr("PROFILE_REAL_EP", true);
        bool ok = sample(budget, creditMode(), realEP, false);
        assertEq(ok, budget >= (realEP ? 440000 : directMinimum()), "frozen completion threshold");
        emit log_named_uint("sample budget", budget);
        emit log_named_uint("sample completed", ok ? 1 : 0);
    }
}

contract PostOpProfileBalanceTest is PostOpProfileBoundary {
    function creditMode() internal pure override returns (bool) {
        return false;
    }
}

contract PostOpProfileCreditTest is PostOpProfileBoundary {
    function creditMode() internal pure override returns (bool) {
        return true;
    }
}

abstract contract PostOpProfileTrajectory is PostOpProfileFixture {
    function probeMode() internal pure override returns (bool) {
        return true;
    }

    function test_trajectory() public {
        assertTrue(sample(440000, creditMode(), true, true));
    }
}

contract PostOpProfileBalanceTrajectoryTest is PostOpProfileTrajectory {
    function creditMode() internal pure override returns (bool) {
        return false;
    }
}

contract PostOpProfileCreditTrajectoryTest is PostOpProfileTrajectory {
    function creditMode() internal pure override returns (bool) {
        return true;
    }
}
