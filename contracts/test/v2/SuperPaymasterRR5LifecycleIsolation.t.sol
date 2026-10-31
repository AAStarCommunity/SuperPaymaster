// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;
import {SelectedGasFixtures as GasFixture} from "../helpers/SelectedGasFixtures.sol";
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
abstract contract LifecycleIsolationBase is Test {
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

    LifecycleStorageHistory internal history;
    string internal variant;
    bool internal freshBase;
    bool internal snapshots;
    bool internal releaseAgain;
    bool internal guardProbe;
    bool internal rate;
    bool internal callGasFresh;
    bool internal calldataFresh;
    bool internal hashFresh;
    bytes32 internal operationHash;
    V55FuzzTarget internal target;

    function isVariant(string memory name) internal view returns (bool) {
        return keccak256(bytes(variant)) == keccak256(bytes(name));
    }

    function setUp() public {
        history = new LifecycleStorageHistory();
        variant = vm.envString("LIFECYCLE_VARIANT");
        freshBase = bytes(variant)[0] == bytes1("f");
        snapshots = !freshBase;
        releaseAgain = !freshBase;
        guardProbe = !freshBase;
        rate = freshBase;
        callGasFresh = freshBase;
        calldataFresh = freshBase;
        hashFresh = freshBase;
        if (isVariant("rr_no_snapshot")) snapshots = false;
        if (isVariant("fresh_snapshot")) snapshots = true;
        if (isVariant("rr_single_validation")) releaseAgain = false;
        if (isVariant("fresh_release")) releaseAgain = true;
        if (isVariant("rr_rate")) rate = true;
        if (isVariant("fresh_rate")) rate = false;
        if (isVariant("rr_callgas")) callGasFresh = true;
        if (isVariant("fresh_callgas")) callGasFresh = false;
        if (isVariant("rr_calldata")) calldataFresh = true;
        if (isVariant("fresh_calldata")) calldataFresh = false;
        if (isVariant("rr_hash")) hashFresh = true;
        if (isVariant("fresh_hash")) hashFresh = false;
        if (isVariant("rr_no_guard_probe")) guardProbe = false;
        if (isVariant("fresh_guard_probe")) guardProbe = true;

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
        if (rate) sp.setOperatorLimits(60);
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
        if (freshBase || calldataFresh || hashFresh) target = new V55FuzzTarget();
        // Preserve the fresh fixture's auxiliary real-account funding in setUp.
        if (freshBase) {
            SimpleAccountFactory af = new SimpleAccountFactory(IEntryPoint(EP));
            address account = address(af.createAccount(vm.addr(0xC001), 0));
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
            IEntryPoint(EP).depositTo{value: 1 ether}(address(sp));
        }
        if (releaseAgain || isVariant("fresh_split")) admit();

    }

    function admit() internal {
        beforeBalance = token.balanceOf(user);
        beforeSupply = token.totalSupply();
        beforeOperator = operatorBalance();
        beforeRevenue = sp.protocolRevenue();
        PackedUserOperation memory op;
        op.sender = user;
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(400_000), uint128(callGasFresh ? 300_000 : 200_000)));
        if (calldataFresh) op.callData = abi.encodeCall(SimpleAccount.execute,
            (address(target), 0, abi.encodeCall(V55FuzzTarget.hit, (keccak256("profile")))));
        op.preVerificationGas = 50_000;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei)));
        op.paymasterAndData = abi.encodePacked(address(sp), uint128(GasFixture.PM_VERIFICATION),
            uint128(GasFixture.MIN_POST()), operator, type(uint256).max, address(token), uint8(0));
        operationHash = hashFresh ? IEntryPoint(EP).getUserOpHash(op) : HASH;
        vm.prank(EP);
        uint256 vd;
        (storedContext, vd) = sp.validatePaymasterUserOp(op, operationHash, 1e16);
        assertEq(vd & 1, 0);
        assertEq(storedContext.length, 384);
        SuperPaymaster.OpCtx memory c = abi.decode(storedContext, (SuperPaymaster.OpCtx));
        assertEq(c.mode, creditMode() ? 2 : 1);
        reserved = c.a0;
        // A failed call in the validation transaction leaves the record for later recovery.
        if (guardProbe) (setupCallOK, setupReturn) = invoke(GasFixture.SETTLE() - 1);
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
        assertFalse(token.usedOpHashes(operationHash));
        assertEq(sp.protocolRevenue(), beforeRevenue);
        assertEq(token.balanceOf(user), beforeBalance);
        assertEq(token.totalSupply(), beforeSupply);
        assertEq(token.debts(user), 0);
        (address who, uint256 a0) = sp.inflightOf(operationHash);
        assertEq(who, operator);
        assertEq(a0, reserved);
        assertEq(operatorBalance(), beforeOperator - reserved);
        if (creditMode()) {
            assertEq(token.creditReservationOf(operationHash, user).locker, address(sp));
            assertEq(token.creditReservationOf(operationHash, user).amount, reserved);
            assertEq(token.creditReservedOf(user), reserved);
        } else {
            assertEq(token.lockOf(operationHash, user).locker, address(sp));
            assertEq(token.lockOf(operationHash, user).xLocked, reserved);
            assertEq(token.lockedOf(user), reserved);
        }
    }

    function assertSettled() internal view {
        assertTrue(token.usedOpHashes(operationHash));
        (address who,) = sp.inflightOf(operationHash);
        assertEq(who, address(0));
        assertEq(token.lockOf(operationHash, user).locker, address(0));
        assertEq(token.creditReservationOf(operationHash, user).locker, address(0));
        assertEq(token.lockedOf(user), 0);
        assertEq(token.creditReservedOf(user), 0);
        uint256 charge = sp.protocolRevenue() - beforeRevenue;
        assertGt(charge, 0);
        assertEq(beforeOperator - operatorBalance(), charge);
        if (creditMode()) assertEq(token.debts(user), charge);
        else assertEq(beforeBalance - token.balanceOf(user), charge);
    }

    function release() internal {
        if (creditMode()) token.releaseStaleCredit(user, operationHash);
        else token.releaseStaleLock(user, operationHash);
        sp.releaseStaleSponsorship(operationHash);
    }


    function prepare() internal {
        if (!isVariant("rr_split") && !isVariant("fresh_split")) {
            if (releaseAgain) release();
            admit();
        }
        if (isVariant("rr_roll") || isVariant("fresh_roll")) vm.roll(block.number + 1);
        if (isVariant("rr_storage") || isVariant("fresh_storage")) {
            // Real SSTORE opcodes, not vm.store: exercise transaction state-gas charges/credits.
            history.write(1);
            history.write(0);
            assertEq(history.value(), 0);
        }
    }

    // 0 = exact guard; 1 = empty failure; 2 = other failure; 3 = fully settled.
    function point(uint256 g, bool restore) internal returns (uint256 kind) {
        uint256 snap;
        if (restore) snap = vm.snapshot();
        (bool ok, bytes memory ret) = invoke(g);
        if (ok) { assertSettled(); kind = 3; }
        else {
            assertPending();
            kind = keccak256(ret) == keccak256(abi.encodeWithSelector(SuperPaymasterStorage.PostOpGasTooLow.selector))
                ? 0 : (ret.length == 0 ? 1 : 2);
        }
        emit log_named_uint("gas", g);
        emit log_named_uint("kind", kind);
        emit log_named_bytes("ret", ret);
        if (restore) assertTrue(vm.revertTo(snap));
    }

    function independentPoint(uint256 g) internal {
        prepare();
        point(g, false);
    }

    function test_scan_420000() public { independentPoint(420000); }
    function test_scan_422000() public { independentPoint(422000); }
    function test_scan_424000() public { independentPoint(424000); }
    function test_scan_426000() public { independentPoint(426000); }
    function test_scan_428000() public { independentPoint(428000); }
    function test_scan_430000() public { independentPoint(430000); }
    function test_scan_432000() public { independentPoint(432000); }
    function test_scan_434000() public { independentPoint(434000); }
    function test_scan_436000() public { independentPoint(436000); }
    function test_scan_438000() public { independentPoint(438000); }
    function test_scan_440000() public { independentPoint(440000); }
    function test_scan_442000() public { independentPoint(442000); }
    function test_scan_444000() public { independentPoint(444000); }
    function test_scan_446000() public { independentPoint(446000); }
    function test_scan_448000() public { independentPoint(448000); }
    function test_scan_450000() public { independentPoint(450000); }
    function test_scan_452000() public { independentPoint(452000); }
    function test_scan_454000() public { independentPoint(454000); }
    function test_scan_456000() public { independentPoint(456000); }
    function test_scan_458000() public { independentPoint(458000); }
    function test_scan_460000() public { independentPoint(460000); }
    function test_scan_462000() public { independentPoint(462000); }
    function test_scan_464000() public { independentPoint(464000); }
    function test_scan_466000() public { independentPoint(466000); }
    function test_scan_468000() public { independentPoint(468000); }
    function test_scan_470000() public { independentPoint(470000); }
    function test_scan_472000() public { independentPoint(472000); }
    function test_scan_474000() public { independentPoint(474000); }
    function test_scan_476000() public { independentPoint(476000); }
    function test_scan_478000() public { independentPoint(478000); }
    function test_scan_480000() public { independentPoint(480000); }
    function test_scan_482000() public { independentPoint(482000); }
    function test_scan_484000() public { independentPoint(484000); }
    function test_scan_486000() public { independentPoint(486000); }
    function test_scan_488000() public { independentPoint(488000); }
    function test_scan_490000() public { independentPoint(490000); }
    function test_scan_492000() public { independentPoint(492000); }
    function test_scan_494000() public { independentPoint(494000); }
    function test_scan_496000() public { independentPoint(496000); }
    function test_scan_498000() public { independentPoint(498000); }
    function test_scan_500000() public { independentPoint(500000); }
    function test_scan_502000() public { independentPoint(502000); }
    function test_scan_504000() public { independentPoint(504000); }
    function test_scan_506000() public { independentPoint(506000); }
    function test_scan_508000() public { independentPoint(508000); }
    function test_scan_510000() public { independentPoint(510000); }
    function test_scan_512000() public { independentPoint(512000); }
    function test_scan_514000() public { independentPoint(514000); }
    function test_scan_516000() public { independentPoint(516000); }
    function test_scan_518000() public { independentPoint(518000); }
    function test_scan_520000() public { independentPoint(520000); }
    function test_scan_522000() public { independentPoint(522000); }
    function test_scan_524000() public { independentPoint(524000); }
    function test_scan_526000() public { independentPoint(526000); }
    function test_scan_528000() public { independentPoint(528000); }
    function test_scan_530000() public { independentPoint(530000); }
    function test_scan_532000() public { independentPoint(532000); }
    function test_scan_534000() public { independentPoint(534000); }
    function test_scan_536000() public { independentPoint(536000); }
    function test_scan_538000() public { independentPoint(538000); }
    function test_scan_540000() public { independentPoint(540000); }
    function test_scan_542000() public { independentPoint(542000); }
    function test_scan_544000() public { independentPoint(544000); }
    function test_scan_546000() public { independentPoint(546000); }
    function test_scan_548000() public { independentPoint(548000); }
    function test_scan_550000() public { independentPoint(550000); }
    function test_scan_552000() public { independentPoint(552000); }
    function test_scan_554000() public { independentPoint(554000); }
    function test_scan_556000() public { independentPoint(556000); }
    function test_scan_558000() public { independentPoint(558000); }
    function test_scan_560000() public { independentPoint(560000); }
    function test_scan_562000() public { independentPoint(562000); }
    function test_scan_564000() public { independentPoint(564000); }
    function test_scan_566000() public { independentPoint(566000); }
    function test_scan_568000() public { independentPoint(568000); }
    function test_scan_570000() public { independentPoint(570000); }
    function test_scan_572000() public { independentPoint(572000); }
    function test_scan_574000() public { independentPoint(574000); }
    function test_scan_576000() public { independentPoint(576000); }
    function test_scan_578000() public { independentPoint(578000); }
    function test_scan_580000() public { independentPoint(580000); }
    function test_scan_582000() public { independentPoint(582000); }
    function test_scan_584000() public { independentPoint(584000); }
    function test_scan_586000() public { independentPoint(586000); }
    function test_scan_588000() public { independentPoint(588000); }
    function test_scan_590000() public { independentPoint(590000); }
    function test_scan_592000() public { independentPoint(592000); }
    function test_scan_594000() public { independentPoint(594000); }
    function test_scan_596000() public { independentPoint(596000); }
    function test_scan_598000() public { independentPoint(598000); }
    function test_scan_600000() public { independentPoint(600000); }
    function test_scan_602000() public { independentPoint(602000); }
    function test_scan_604000() public { independentPoint(604000); }
    function test_scan_606000() public { independentPoint(606000); }
    function test_scan_608000() public { independentPoint(608000); }
    function test_scan_610000() public { independentPoint(610000); }
    function test_scan_612000() public { independentPoint(612000); }
    function test_scan_614000() public { independentPoint(614000); }
    function test_scan_616000() public { independentPoint(616000); }
    function test_scan_618000() public { independentPoint(618000); }
    function test_scan_620000() public { independentPoint(620000); }
    function test_scan_622000() public { independentPoint(622000); }
    function test_scan_624000() public { independentPoint(624000); }
    function test_scan_626000() public { independentPoint(626000); }
    function test_scan_628000() public { independentPoint(628000); }
    function test_scan_630000() public { independentPoint(630000); }
    function test_scan_632000() public { independentPoint(632000); }
    function test_scan_634000() public { independentPoint(634000); }
    function test_scan_636000() public { independentPoint(636000); }
    function test_scan_638000() public { independentPoint(638000); }
    function test_scan_640000() public { independentPoint(640000); }
    function test_scan_642000() public { independentPoint(642000); }
    function test_scan_644000() public { independentPoint(644000); }
    function test_scan_646000() public { independentPoint(646000); }
    function test_scan_648000() public { independentPoint(648000); }
    function test_scan_650000() public { independentPoint(650000); }
    function test_scan_652000() public { independentPoint(652000); }
    function test_scan_654000() public { independentPoint(654000); }
    function test_scan_656000() public { independentPoint(656000); }
    function test_scan_658000() public { independentPoint(658000); }
    function test_scan_660000() public { independentPoint(660000); }
    function test_scan_662000() public { independentPoint(662000); }
    function test_scan_664000() public { independentPoint(664000); }
    function test_scan_666000() public { independentPoint(666000); }
    function test_scan_668000() public { independentPoint(668000); }
    function test_scan_670000() public { independentPoint(670000); }
    function test_scan_672000() public { independentPoint(672000); }
    function test_scan_674000() public { independentPoint(674000); }
    function test_scan_676000() public { independentPoint(676000); }
    function test_scan_678000() public { independentPoint(678000); }
    function test_scan_680000() public { independentPoint(680000); }
    function test_scan_682000() public { independentPoint(682000); }
    function test_scan_684000() public { independentPoint(684000); }
    function test_scan_686000() public { independentPoint(686000); }
    function test_scan_688000() public { independentPoint(688000); }
    function test_scan_690000() public { independentPoint(690000); }
    function test_scan_692000() public { independentPoint(692000); }
    function test_scan_694000() public { independentPoint(694000); }
    function test_scan_696000() public { independentPoint(696000); }
    function test_scan_698000() public { independentPoint(698000); }
    function test_scan_700000() public { independentPoint(700000); }
    function test_scan_702000() public { independentPoint(702000); }
    function test_scan_704000() public { independentPoint(704000); }
    function test_scan_706000() public { independentPoint(706000); }
    function test_scan_708000() public { independentPoint(708000); }
    function test_scan_710000() public { independentPoint(710000); }
    function test_scan_712000() public { independentPoint(712000); }
    function test_scan_714000() public { independentPoint(714000); }
    function test_scan_716000() public { independentPoint(716000); }
    function test_scan_718000() public { independentPoint(718000); }
    function test_scan_720000() public { independentPoint(720000); }
    function test_scan_722000() public { independentPoint(722000); }
    function test_scan_724000() public { independentPoint(724000); }
    function test_scan_726000() public { independentPoint(726000); }
    function test_scan_728000() public { independentPoint(728000); }
    function test_scan_730000() public { independentPoint(730000); }
    function test_scan_732000() public { independentPoint(732000); }
    function test_scan_734000() public { independentPoint(734000); }
    function test_scan_736000() public { independentPoint(736000); }
    function test_scan_738000() public { independentPoint(738000); }
    function test_scan_740000() public { independentPoint(740000); }
    function test_scan_742000() public { independentPoint(742000); }
    function test_scan_744000() public { independentPoint(744000); }
    function test_scan_746000() public { independentPoint(746000); }
    function test_scan_748000() public { independentPoint(748000); }
    function test_scan_750000() public { independentPoint(750000); }
    function test_scan_752000() public { independentPoint(752000); }
    function test_scan_754000() public { independentPoint(754000); }
    function test_scan_756000() public { independentPoint(756000); }
    function test_scan_758000() public { independentPoint(758000); }
    function test_scan_760000() public { independentPoint(760000); }
    function test_scan_762000() public { independentPoint(762000); }
    function test_scan_764000() public { independentPoint(764000); }
    function test_scan_766000() public { independentPoint(766000); }
    function test_scan_768000() public { independentPoint(768000); }
    function test_scan_770000() public { independentPoint(770000); }
    function test_scan_772000() public { independentPoint(772000); }
    function test_scan_774000() public { independentPoint(774000); }
    function test_scan_776000() public { independentPoint(776000); }
    function test_scan_778000() public { independentPoint(778000); }
    function test_scan_780000() public { independentPoint(780000); }
    function test_scan_782000() public { independentPoint(782000); }
    function test_scan_784000() public { independentPoint(784000); }
    function test_scan_786000() public { independentPoint(786000); }
    function test_scan_788000() public { independentPoint(788000); }
    function test_scan_790000() public { independentPoint(790000); }
    function test_scan_792000() public { independentPoint(792000); }
    function test_scan_794000() public { independentPoint(794000); }
    function test_scan_796000() public { independentPoint(796000); }
    function test_scan_798000() public { independentPoint(798000); }
    function test_scan_800000() public { independentPoint(800000); }
    function test_scan_802000() public { independentPoint(802000); }
    function test_scan_804000() public { independentPoint(804000); }
    function test_scan_806000() public { independentPoint(806000); }
    function test_scan_808000() public { independentPoint(808000); }
    function test_scan_810000() public { independentPoint(810000); }
    function test_scan_812000() public { independentPoint(812000); }
    function test_scan_814000() public { independentPoint(814000); }
    function test_scan_816000() public { independentPoint(816000); }
    function test_scan_818000() public { independentPoint(818000); }
    function test_scan_820000() public { independentPoint(820000); }
    function test_scan_822000() public { independentPoint(822000); }
    function test_scan_824000() public { independentPoint(824000); }
    function test_scan_826000() public { independentPoint(826000); }
    function test_scan_828000() public { independentPoint(828000); }
    function test_scan_830000() public { independentPoint(830000); }
    function test_scan_832000() public { independentPoint(832000); }
    function test_scan_834000() public { independentPoint(834000); }
    function test_scan_836000() public { independentPoint(836000); }
    function test_scan_838000() public { independentPoint(838000); }
    function test_scan_840000() public { independentPoint(840000); }
    function test_scan_842000() public { independentPoint(842000); }
    function test_scan_844000() public { independentPoint(844000); }
    function test_scan_846000() public { independentPoint(846000); }
    function test_scan_848000() public { independentPoint(848000); }
    function test_scan_850000() public { independentPoint(850000); }
    function test_scan_852000() public { independentPoint(852000); }
    function test_scan_854000() public { independentPoint(854000); }
    function test_scan_856000() public { independentPoint(856000); }
    function test_scan_858000() public { independentPoint(858000); }
    function test_scan_860000() public { independentPoint(860000); }
    function test_scan_862000() public { independentPoint(862000); }
    function test_scan_864000() public { independentPoint(864000); }
    function test_scan_866000() public { independentPoint(866000); }
    function test_scan_868000() public { independentPoint(868000); }
    function test_scan_870000() public { independentPoint(870000); }
    function test_scan_872000() public { independentPoint(872000); }
    function test_scan_874000() public { independentPoint(874000); }
    function test_scan_876000() public { independentPoint(876000); }
    function test_scan_878000() public { independentPoint(878000); }
    function test_scan_880000() public { independentPoint(880000); }
    function test_scan_882000() public { independentPoint(882000); }
    function test_scan_884000() public { independentPoint(884000); }
    function test_scan_886000() public { independentPoint(886000); }
    function test_scan_888000() public { independentPoint(888000); }
    function test_scan_890000() public { independentPoint(890000); }
    function test_scan_892000() public { independentPoint(892000); }
    function test_scan_894000() public { independentPoint(894000); }
    function test_scan_896000() public { independentPoint(896000); }
    function test_scan_898000() public { independentPoint(898000); }
    function test_scan_900000() public { independentPoint(900000); }
    function test_lifecycle() public {
        prepare();
        uint256 budget = vm.envOr("LIFECYCLE_BUDGET", uint256(0));
        if (budget != 0) {
            // A preceding guard sample isolates restore while preserving logical state.
            if (snapshots) point(420000, true);
            point(budget, false);
            return;
        }
        assertTrue(snapshots, "non-snapshot points require separate processes");
        uint256 lastGuard;
        uint256 firstComplete;
        for (uint256 g = 420000; g <= 900000; g += 2000) {
            uint256 k = point(g, true);
            if (k == 0) lastGuard = g;
            if (k == 3 && firstComplete == 0) firstComplete = g;
        }
        assertGt(firstComplete, 0);
        uint256 lo = lastGuard;
        uint256 hi = lastGuard + 2000;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (point(mid, true) == 0) lo = mid; else hi = mid;
        }
        emit log_named_uint("guard_edge", lo);
        lo = firstComplete - 2000;
        hi = firstComplete;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (point(mid, true) == 3) hi = mid; else lo = mid;
        }
        emit log_named_uint("complete_edge", hi);
    }

}

contract LifecycleBalanceTest is LifecycleIsolationBase {
    function creditMode() internal pure override returns (bool) { return false; }
}
contract LifecycleCreditTest is LifecycleIsolationBase {
    function creditMode() internal pure override returns (bool) { return true; }
}

contract LifecycleStorageHistory {
    uint256 public value;
    function write(uint256 next) external { value = next; }
}
