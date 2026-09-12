// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/interfaces/v3/IRegistry.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import "@account-abstraction-v7/samples/SimpleAccountFactory.sol";
import "@openzeppelin-v5.0.2/contracts/utils/cryptography/MessageHashUtils.sol";
import { Math } from "@openzeppelin-v5.0.2/contracts/utils/math/Math.sol";
import { UUPSDeployHelper } from "../helpers/UUPSDeployHelper.sol";
import { AOAProtocolRegistry } from "src/tokens/v2/AOAProtocolRegistry.sol";
import { GlobalTierSource } from "src/tokens/v2/GlobalTierSource.sol";
import { xPNTsTokenV2 } from "src/tokens/v2/xPNTsTokenV2.sol";
import { xPNTsTokenV2Ext } from "src/tokens/v2/xPNTsTokenV2Ext.sol";
import { xPNTsFactoryV2 } from "src/tokens/v2/xPNTsFactoryV2.sol";
import { IxPNTsTokenV2 } from "src/tokens/v2/IxPNTsTokenV2.sol";
import { V55Registry, V55APNTs } from "../helpers/V55TestFixtures.sol";
import { V55MutablePriceFeed, V55FuzzTarget } from "../helpers/V55FuzzFixtures.sol";

/// @dev Typed view of the xPNTs v2 extension functions this suite drives (through the core's fallback).
interface IG2Tok {
    function mint(address to, uint256 amount) external;
    function updateExchangeRate(uint256 newRate) external;
    function queueCreditPolicy(uint8 p) external;
    function executeCreditPolicy() external;
    function requestCredit(uint256 maxCap) external;
    function approveCredit(address user, uint256 cap) external;
    function setAutoAllowance(address spender, uint256 capAPNTs) external;
    function setUserTotalCap(uint256 capAPNTs) external;
    function disableSpenderForSelf(address spender) external;
    function enableSpenderForSelf(address spender) external;
    function emergencyRevokePaymaster() external;
    function unsetEmergencyDisabled() external;
}

/// @dev forge >= 1.0 state-snapshot cheatcodes (the vendored forge-std Vm predates the rename).
interface IVmStateG2 {
    function snapshotState() external returns (uint256);
    function revertToStateAndDelete(uint256 id) external returns (bool);
}

/**
 * @title SuperPaymasterV55FuzzTest — D5.1 gate G2 (D5-plan §2): I8 / I9 / I10 + conservation,
 *        randomized, through the CANONICAL EntryPoint v0.7 runtime (codehash 0x8db5ff69…).
 *
 * @notice One campaign = 2–3 bundles, seeded. Per bundle:
 *   - 1–6 ops; sender ∈ 3 SimpleAccounts (repeats allowed, each op on a fresh nonce key);
 *     community/operator ∈ 2 (each with its own v2 token) → "per operator" is a real dimension.
 *   - Per (sender, token) group the ops are split, in bundle order, into an intended BALANCE prefix,
 *     CREDIT middle and NEITHER tail: the free balance is set to cover exactly the BALANCE prefix
 *     (+ a random remainder < the next x0) and the credit request to cover exactly the CREDIT middle
 *     (+ a remainder < the next a0). The ORACLE is not the intent but a model of SP/token validation
 *     evaluated on the live state (blacklist, pause, emergency, E-1 disable, policy/epoch, tier,
 *     allowance, balance, credit headroom, operator solvency, postOp floor); the test asserts the
 *     model's mode for every op against SP's actual LockCreated / CreditReserved and every predicted
 *     rejection against EntryPoint's FailedOp(index, "AA34 signature error") ("k-th op rejected").
 *   - paymasterPostOpGasLimit ∈ {MIN−1, MIN, MIN+δ (δ ≤ 50k), 1.0–1.5M}; callGasLimit random;
 *     execution = success | success + mid-bundle ETH price move | revert | out-of-gas.
 *   - Settlement failure injected on ~15% of admitted ops by vm.mockCallRevert on the token's
 *     settleLocked/settleCredit for (user, opHash) calldata — only that op's settlement reverts.
 *   - Between bundles: blacklist (SBT / isBlocked), credit-policy switch (queue, +48 h, execute,
 *     updatePrice), tier change, operator pause/unpause (SP), E-1 disable/enable, token emergency
 *     stop (S-4; S-7 unset is asserted to be impossible for the same SP), exchange-rate change
 *     (cooldown + ±20%), ETH and aPNTs price moves.
 *
 * @dev Transaction boundary (I10): every test that submits bundles runs with `isolate = true`.
 *      Verified empirically on forge 1.7.1 (probe, see D5 report): under isolate, EVERY top-level
 *      call from the test contract is its own transaction — also inside fuzz runs — so transient
 *      storage written by `handleOps` is gone in the next call (TLOAD reads 0); `snapshotState` /
 *      `revertToStateAndDelete` still work; `mockCallRevert` persists across isolated calls and
 *      matches only the given calldata prefix. So the stale releases run AFTER the bundle's tx, as
 *      in production. Without isolate the whole test is one tx and the releases revert StillLive.
 */
contract SuperPaymasterV55FuzzTest is Test {
    IVmStateG2 constant vmx = IVmStateG2(address(uint160(uint256(keccak256("hevm cheat code")))));

    address constant EP = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address constant SENDER_CREATOR = 0xEFC2c1444eBCC4Db75e7613d20C6a62fF67A167C;
    bytes32 constant EP_CODEHASH = 0x8db5ff695839d655407cc8490bb7a5d82337a86a6b39c3f0258aa6c3b582fc58;

    uint256 constant MIN_POST_OP_GAS = 200_000; // SuperPaymaster.MIN_POST_OP_GAS
    uint256 constant VERIF_GAS = 400_000;
    uint256 constant PM_VERIF_GAS = 700_000;
    uint256 constant PVG = 50_000;
    uint256 constant BPS = 10_000;
    uint256 constant VALIDATION_BUFFER_BPS = 1_000; // SuperPaymaster.VALIDATION_BUFFER_BPS
    uint256 constant BIG_CAP = 50_000 ether;
    uint256 constant COVERAGE_SEEDS = 1_000;
    uint256 constant RATIO_CAP = 20_000;

    uint8 constant EX_OK = 0;
    uint8 constant EX_MOVE = 1;
    uint8 constant EX_REVERT = 2;
    uint8 constant EX_OOG = 3;

    uint8 constant MODE_NONE = 0;
    uint8 constant MODE_BALANCE = 1;
    uint8 constant MODE_CREDIT = 2;

    bytes32 constant T_USEROP = keccak256("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)");
    bytes32 constant T_POSTOP_REVERT = keccak256("PostOpRevertReason(bytes32,address,uint256,bytes)");
    bytes32 constant T_BEFORE_EXEC = keccak256("BeforeExecution()");
    bytes32 constant T_LOCK_CREATED = keccak256("LockCreated(address,bytes32,address,uint256,uint256)");
    bytes32 constant T_CREDIT_RESERVED = keccak256("CreditReserved(address,bytes32,address,uint256)");
    bytes32 constant T_LOCK_SETTLED = keccak256("LockSettled(address,bytes32,uint256,uint256)");
    bytes32 constant T_CREDIT_SETTLED = keccak256("CreditSettled(address,bytes32,uint256)");
    bytes32 constant T_TX_SPONSORED = keccak256("TransactionSponsored(address,address,uint256,uint256)");

    IEntryPoint entryPoint = IEntryPoint(EP);
    SimpleAccountFactory accountFactory;
    SuperPaymaster sp;
    V55Registry registry;
    V55APNTs apnts;
    V55MutablePriceFeed feed;
    V55FuzzTarget target;
    xPNTsTokenV2[2] tok;
    address[2] opr = [address(0x0BE), address(0x0BF)];
    address[3] usr;
    uint256[3] pk = [uint256(0xA001), 0xA002, 0xA003];

    address owner = address(0x0A11);
    address treasury = address(0x7EA);
    address beneficiary = address(0xBEEF);
    address sink = address(0x5111C);

    uint256 private _rs;    // campaign RNG state (reset from the seed per campaign)
    uint256[3] private _nk; // next nonce key per account

    // ------------------------------------------------------------------
    // data
    // ------------------------------------------------------------------

    struct Op {
        // plan
        uint8 u;
        uint8 t;
        uint8 exec;
        bool inject;
        bool hard;       // rejected by a check that does not depend on funding
        uint128 callGas;
        uint128 postGas;
        uint256 fee;
        uint256 maxCost;
        uint256 a0;      // model: aPNTs reserved
        uint256 x0;      // model: xPNTs locked (BALANCE)
        uint8 expMode;   // model: 0 rejected / 1 BALANCE / 2 CREDIT
        int256 moveTo;
        bytes32 id;
        bytes32 h;
        PackedUserOperation op;
        // observed
        bool rejected;
        uint8 mode;
        uint256 aRes;
        uint256 xLocked;
        bool seen;       // UserOperationEvent found
        bool success;
        uint256 G;       // UserOperationEvent.actualGasCost (taken from SP's EntryPoint deposit)
        bool postReverted;
        uint256 nTS;
        uint256 spCharge;
        bool settleEvt;
        uint256 tokCharge;
        uint256 xBurned;
        bool kept;
        bool settled;
    }

    struct B {
        Op[] os;
        uint256 price;
        uint8 dec;
        uint256 aPrice;
        uint256 feeBps;
        uint256[2] rate;
        uint256[2] opBal0;
        uint256[2] supply0;
        uint256 rev0;
        uint256 dep0;
        uint256[2][3] bal0;
        uint256[2][3] debt0;
    }

    struct Ghost {
        uint256[2] unbCnt; // I9 per operator
        uint256[2] unbAmt;
    }

    struct Stats {
        uint256 runs;
        uint256 bundles;
        uint256 planned;
        uint256 rejected;
        uint256 rejMinMinus1;
        uint256 settledB;
        uint256 settledC;
        uint256 injected;
        uint256 injB;
        uint256 injC;
        uint256 repeatBundles;
        uint256 atMinIncluded;
        uint256 atMinSettled;
        uint256 opReverted;
        uint256 oogSettled;
        uint256 kept;
        uint256 priceMoves;
        uint256 evBlacklist;
        uint256 evPolicy;
        uint256 evTier;
        uint256 evPause;
        uint256 evDisable;
        uint256 evEmergency;
        uint256 evRate;
        uint256 evPrice;
        uint256 unbCnt;
        uint256 unbAmt;
        uint256[] ratioPpm; // (chargeEthNet − G) / G, per settled op, ppm
        uint256 nRatio;
        uint256 sumRatioPpm;
        uint256[] tightPpm; // same, only ops with postOpGasLimit <= MIN + 50k
        uint256 nTight;
        uint256 sumTightPpm;
        uint256 sumChargeEth;
        uint256 sumGSettled;
        uint256 sumGInjected;
        uint256 sumDepDelta;
    }

    // ------------------------------------------------------------------
    // setUp
    // ------------------------------------------------------------------

    function setUp() public {
        vm.etch(EP, vm.parseBytes(vm.readFile("contracts/test/fixtures/entrypoint-v0.7.runtime.hex")));
        vm.etch(SENDER_CREATOR, vm.parseBytes(vm.readFile("contracts/test/fixtures/sendercreator-v0.7.runtime.hex")));
        assertEq(EP.codehash, EP_CODEHASH, "canonical EntryPoint v0.7 bytecode");
        accountFactory = new SimpleAccountFactory(entryPoint);
        target = new V55FuzzTarget();

        vm.deal(owner, 200 ether);
        vm.startPrank(owner);
        registry = new V55Registry();
        apnts = new V55APNTs();
        feed = new V55MutablePriceFeed();
        sp = UUPSDeployHelper.deploySuperPaymasterProxy(
            entryPoint, IRegistry(address(registry)), address(feed), owner, address(apnts), treasury, 3600
        );
        AOAProtocolRegistry aoa = new AOAProtocolRegistry(owner);
        GlobalTierSource tier = new GlobalTierSource(address(registry));
        aoa.bootstrapApprove(aoa.KIND_SP(), aoa.spKey(address(sp)));
        aoa.bootstrapApprove(aoa.KIND_TIER_SOURCE(), address(tier).codehash);
        aoa.seal();
        xPNTsTokenV2Ext ext = new xPNTsTokenV2Ext(address(aoa));
        xPNTsTokenV2 impl = new xPNTsTokenV2(address(aoa), address(ext));
        xPNTsFactoryV2 factory = new xPNTsFactoryV2(address(sp), address(registry), address(impl), address(tier));
        sp.setXPNTsFactory(address(factory));
        vm.warp(vm.getBlockTimestamp() + 2 hours);
        sp.updatePrice();
        sp.deposit{value: 100 ether}();
        vm.stopPrank();

        for (uint256 t; t < 2; t++) {
            registry.setRole(keccak256("PAYMASTER_SUPER"), opr[t], true);
            registry.setRole(keccak256("COMMUNITY"), opr[t], true);
            apnts.mint(opr[t], 2_000_000 ether);
            vm.startPrank(opr[t]);
            tok[t] = xPNTsTokenV2(factory.deployxPNTsToken("Comm", "xC", "Comm", "c.eth", 1 ether, address(0)));
            apnts.approve(address(sp), type(uint256).max);
            sp.configureOperator(address(tok[t]), treasury);
            sp.deposit(1_000_000 ether);
            sp.setOperatorLimits(60); // worst postOp path: fresh lastTimestamp write every bundle
            IG2Tok(address(tok[t])).queueCreditPolicy(2);
            vm.stopPrank();
        }
        vm.warp(vm.getBlockTimestamp() + 48 hours + 1);
        for (uint256 t; t < 2; t++) IG2Tok(address(tok[t])).executeCreditPolicy();
        sp.updatePrice();

        for (uint256 u; u < 3; u++) {
            usr[u] = address(accountFactory.createAccount(vm.addr(pk[u]), 0));
            vm.prank(address(registry));
            sp.updateSBTStatus(usr[u], true);
            registry.setCreditLimit(usr[u], BIG_CAP);
            for (uint256 t; t < 2; t++) {
                vm.startPrank(usr[u]);
                IG2Tok(address(tok[t])).setAutoAllowance(address(sp), BIG_CAP);
                IG2Tok(address(tok[t])).setUserTotalCap(BIG_CAP);
                IG2Tok(address(tok[t])).requestCredit(BIG_CAP);
                vm.stopPrank();
            }
        }
    }

    // ==================================================================
    // Tests
    // ==================================================================

    /// @notice G2 inline fuzz: every run is one seeded campaign; all per-op / per-bundle /
    ///         per-operator assertions run inside. Fixed seed for reproducibility.
    /// forge-config: default.isolate = true
    /// forge-config: default.fuzz.runs = 1000
    /// forge-config: default.fuzz.seed = "0xd5c2"
    /// forge-config: default.fuzz.dictionary.dictionary_weight = 0
    function testFuzz_G2_I8_I9_I10_conservation(uint256 seed) public {
        Stats memory st = _newStats(64);
        _campaign(seed, st);
    }

    /// @notice G2 coverage gate: replays COVERAGE_SEEDS fixed seeds through the SAME campaign body
    ///         (state restored between seeds) and asserts the D5-plan §2 floors over the whole
    ///         campaign, plus the DSR "no subsidy" overcharge distribution (R1-8 first data).
    /// @dev forge's per-test gas budget (default 2^30) is shared by every isolated call of the test;
    ///      1000 campaigns need ~9e9 gas, and `gas_limit` is NOT honoured as inline config on forge
    ///      1.7.1 (verified: the run still stopped at 2^30 with AA95). `resetGasMetering` at each seed
    ///      resets only the test frame's own counter; every isolated handleOps tx is metered normally.
    /// forge-config: default.isolate = true
    function test_G2_coverage_replay_fixed_seeds() public {
        Stats memory st = _newStats(RATIO_CAP);
        uint256 fmp;
        assembly ("memory-safe") { fmp := mload(0x40) }
        for (uint256 i; i < COVERAGE_SEEDS; i++) {
            vm.resetGasMetering();
            uint256 sid = vmx.snapshotState();
            _campaign(uint256(keccak256(abi.encode("G2-coverage", i))), st);
            vmx.revertToStateAndDelete(sid);
            // everything allocated by the campaign is dead; `st` lives below `fmp`
            assembly ("memory-safe") { mstore(0x40, fmp) }
        }
        _report(st);

        assertGe(st.settledB, 200, "coverage: >= 200 settled BALANCE ops");
        assertGe(st.settledC, 200, "coverage: >= 200 settled CREDIT ops");
        assertGe(st.injected, 50, "coverage: >= 50 injected settle failures");
        assertGt(st.injB, 0, "coverage: injected failures in BALANCE mode");
        assertGt(st.injC, 0, "coverage: injected failures in CREDIT mode");
        assertGe(st.repeatBundles, 50, "coverage: >= 50 bundles with one sender appearing several times");
        assertGe(st.atMinSettled, 50, "coverage: >= 50 settled ops at postOpGasLimit == MIN");
        assertGe(st.opReverted, 50, "coverage: >= 50 opReverted ops settled");
        assertGt(st.oogSettled, 0, "coverage: out-of-gas executions settled");
        assertGt(st.rejMinMinus1, 0, "coverage: postOpGasLimit == MIN-1 rejected");
        assertGt(st.rejected, st.rejMinMinus1, "coverage: other validation rejections (k-th op) observed");
        assertGt(st.priceMoves, 0, "coverage: mid-bundle price moves");
        assertGt(st.evBlacklist, 0, "coverage: blacklist events");
        assertGt(st.evPolicy, 0, "coverage: policy switches");
        assertGt(st.evTier, 0, "coverage: tier changes");
        assertGt(st.evPause, 0, "coverage: operator pause/unpause");
        assertGt(st.evDisable, 0, "coverage: E-1 disable/enable");
        assertGt(st.evEmergency, 0, "coverage: token emergency stops");
        assertGt(st.evRate, 0, "coverage: exchange-rate changes");
        assertGt(st.evPrice, 0, "coverage: price changes");
        assertEq(st.unbCnt, 0, "I9: unbacked sponsorship count over the campaign == 0");
        assertEq(st.unbAmt, 0, "I9: unbacked sponsorship amount over the campaign == 0");
    }

    /// @notice The OOG band of mutation (2) is unreachable through EntryPoint (the validation floor
    ///         MIN_POST_OP_GAS = 200k keeps postOp's gas well above SETTLE_GAS_BOUND), so the fuzz
    ///         also drives postOp directly with a random gas budget: every call either stops at the
    ///         entry guard (PostOpGasTooLow) or settles completely — never an OOG half-way.
    /// forge-config: default.fuzz.runs = 1000
    /// forge-config: default.fuzz.seed = "0xd5c3"
    function testFuzz_G2_noOOGBand_direct_postOp(uint256 gasSeed, bool credit) public {
        uint256 g = _bound(gasSeed, 60_000, 260_000);
        address u = usr[0];
        if (credit) {
            vm.prank(u);
            tok[0].transfer(sink, tok[0].balanceOf(u)); // empty -> INSUFFICIENT -> credit
        } else {
            vm.prank(opr[0]);
            IG2Tok(address(tok[0])).mint(u, 5_000 ether);
        }
        PackedUserOperation memory op;
        op.sender = u;
        op.nonce = 0;
        op.accountGasLimits = bytes32(abi.encodePacked(uint128(VERIF_GAS), uint128(100_000)));
        op.preVerificationGas = PVG;
        op.gasFees = bytes32(abi.encodePacked(uint128(1 gwei), uint128(1 gwei)));
        op.paymasterAndData = abi.encodePacked(
            address(sp), uint128(PM_VERIF_GAS), uint128(MIN_POST_OP_GAS), opr[0], type(uint256).max, address(tok[0]), uint8(0)
        );
        bytes32 h = keccak256(abi.encode("no-oog", gasSeed, credit));
        vm.prank(EP);
        (bytes memory ctx, uint256 vd) = sp.validatePaymasterUserOp(op, h, 1e15);
        assertEq(vd & 1, 0, "validated");
        assertEq(abi.decode(ctx, (SuperPaymaster.OpCtx)).mode, credit ? MODE_CREDIT : MODE_BALANCE, "precondition: mode");
        vm.prank(EP);
        (bool ok, bytes memory ret) = address(sp).call{gas: g}(
            abi.encodeCall(sp.postOp, (IPaymaster.PostOpMode.opSucceeded, ctx, 1e14, 1 gwei))
        );
        if (ok) {
            (address f, ) = sp.inflightOf(h);
            assertEq(f, address(0), "no-OOG: success -> in-flight cleared");
            assertTrue(tok[0].usedOpHashes(h), "no-OOG: success -> token recorded the settlement");
            assertEq(tok[0].lockOf(h, u).locker, address(0), "no-OOG: success -> lock settled");
            assertEq(tok[0].creditReservationOf(h, u).locker, address(0), "no-OOG: success -> reservation settled");
        } else {
            assertEq(ret, abi.encodeWithSelector(SuperPaymaster.PostOpGasTooLow.selector),
                "no-OOG band: a postOp that passed the SETTLE_GAS_BOUND entry check must complete");
        }
    }

    // ==================================================================
    // Campaign body
    // ==================================================================

    function _campaign(uint256 seed, Stats memory st) internal {
        _rs = seed;
        Ghost memory gh;
        uint256 nb = 2 + _r(2);
        for (uint256 b; b < nb; b++) _bundle(st, gh, b);
        for (uint256 t; t < 2; t++) {
            assertEq(gh.unbCnt[t], 0, "I9: unbacked sponsorship count per operator == 0");
            assertEq(gh.unbAmt[t], 0, "I9: unbacked sponsorship amount per operator == 0");
        }
        st.runs++;
    }

    function _bundle(Stats memory st, Ghost memory gh, uint256 b) internal {
        if (b > 0) _events(st);
        vm.warp(vm.getBlockTimestamp() + 61 + _r(540)); // past minTxInterval (validAfter)
        sp.updatePrice();                               // fresh validUntil
        B memory x = _plan(st);
        _build(x);
        _pre(x);
        bool executed = _submit(x, st);
        vm.clearMockedCalls();
        if (!executed) return; // every op predicted (and verified) rejected
        _checkOps(x, st, gh);
        _release(x);
        _conservation(x, st);
        st.bundles++;
    }

    // ------------------------------------------------------------------
    // plan + funding + model
    // ------------------------------------------------------------------

    function _plan(Stats memory st) internal returns (B memory x) {
        uint256 n = 1 + _r(6);
        x.os = new Op[](n);
        (int256 p, , , uint8 d) = sp.cachedPrice();
        x.price = uint256(p);
        x.dec = d;
        x.aPrice = sp.aPNTsPriceUSD();
        x.feeBps = sp.protocolFeeBPS();
        for (uint256 t; t < 2; t++) x.rate[t] = tok[t].exchangeRate();
        for (uint256 i; i < n; i++) {
            Op memory o = x.os[i];
            o.u = uint8(_r(3));
            o.t = uint8(_r(2));
            uint256 e = _r(100);
            o.exec = e < 55 ? EX_OK : e < 63 ? EX_MOVE : e < 82 ? EX_REVERT : EX_OOG;
            uint256 pkd = _r(100);
            o.postGas = uint128(
                pkd < 8 ? MIN_POST_OP_GAS - 1
                : pkd < 38 ? MIN_POST_OP_GAS
                : pkd < 80 ? MIN_POST_OP_GAS + _r(50_001)
                : 1_000_000 + _r(500_001)
            );
            o.callGas = uint128(
                o.exec == EX_OK ? 100_000 + _r(400_000)
                : o.exec == EX_MOVE ? 300_000 + _r(200_000)
                : o.exec == EX_REVERT ? 60_000 + _r(440_000)
                : 40_000 + _r(160_000)
            );
            o.fee = 1 gwei + _r(2 gwei);
            o.inject = _r(100) < 15;
            o.maxCost = (VERIF_GAS + o.callGas + PM_VERIF_GAS + o.postGas + PVG) * o.fee;
            uint256 aGas = Math.mulDiv(o.maxCost * x.price, 1e18, (10 ** uint256(x.dec)) * x.aPrice, Math.Rounding.Ceil);
            o.a0 = Math.mulDiv(aGas, BPS + x.feeBps + VALIDATION_BUFFER_BPS, BPS, Math.Rounding.Ceil);
            o.x0 = Math.mulDiv(o.a0, x.rate[o.t], 1e18, Math.Rounding.Ceil);
            o.hard = _hardReject(o);
            st.planned++;
        }
        _fund(x);
        _model(x);
    }

    function _hardReject(Op memory o) internal view returns (bool) {
        address u = usr[o.u];
        xPNTsTokenV2 k = tok[o.t];
        (, , bool paused, , , , , , ) = sp.operators(opr[o.t]);
        (, bool blocked) = sp.userOpState(opr[o.t], u);
        return o.postGas < MIN_POST_OP_GAS || !sp.sbtHolders(u) || blocked || paused || k.emergencyDisabled()
            || k.spenderDisabled(address(sp), u) || o.a0 > k.maxSingleTxLimit();
    }

    /// @dev Per (sender, token): intended BALANCE prefix / CREDIT middle / NEITHER tail.
    function _fund(B memory x) internal {
        uint256 n = x.os.length;
        uint256[] memory idx = new uint256[](n);
        for (uint256 u; u < 3; u++) {
            for (uint256 t; t < 2; t++) {
                uint256 L;
                for (uint256 i; i < n; i++) {
                    if (x.os[i].u == u && x.os[i].t == t && !x.os[i].hard) idx[L++] = i;
                }
                if (L == 0) continue;
                uint256 kB = _r(L + 1);
                uint256 kC = _r(L - kB + 1);
                uint256 F;
                for (uint256 j; j < kB; j++) F += x.os[idx[j]].x0;
                F += L > kB ? _r(x.os[idx[kB]].x0) : _r(50 ether);
                _setBalance(t, usr[u], F);
                if (L > kB && _r(100) < 85) {
                    uint256 need = tok[t].debts(usr[u]);
                    for (uint256 j = kB; j < kB + kC; j++) need += x.os[idx[j]].a0;
                    need += L > kB + kC ? _r(x.os[idx[kB + kC]].a0) : _r(100 ether);
                    if (need > BIG_CAP) need = BIG_CAP;
                    vm.prank(usr[u]);
                    IG2Tok(address(tok[t])).requestCredit(need);
                    if (tok[t].creditPolicy() == 1 && _r(100) < 80) {
                        vm.prank(opr[t]);
                        IG2Tok(address(tok[t])).approveCredit(usr[u], need);
                    }
                }
            }
        }
    }

    /// @dev Exact funding through a debt-free bank account (`sink`): a direct mint to the user would
    ///      auto-repay its debt first (B:238–249) and silently erase the credit dimension.
    function _setBalance(uint256 t, address u, uint256 target_) internal {
        uint256 bal = tok[t].balanceOf(u);
        if (bal > target_) {
            vm.prank(u);
            tok[t].transfer(sink, bal - target_);
        } else if (bal < target_) {
            uint256 need = target_ - bal;
            if (tok[t].balanceOf(sink) < need) {
                vm.prank(opr[t]);
                IG2Tok(address(tok[t])).mint(sink, need + 100_000 ether);
            }
            vm.prank(sink);
            tok[t].transfer(u, need);
        }
        assertEq(tok[t].balanceOf(u), target_, "setup: funding exact");
    }

    /// @dev Oracle: SP validation + token lock/credit decision, sequential in bundle order.
    function _model(B memory x) internal view {
        uint256[2][3] memory free;
        uint256[2][3] memory rem;
        uint256[2][3] memory dr;
        uint256[2][3] memory cap;
        bool[2][3] memory init;
        uint256[2] memory opRun;
        for (uint256 t; t < 2; t++) opRun[t] = _opBal(t);
        for (uint256 i; i < x.os.length; i++) {
            Op memory o = x.os[i];
            if (o.hard) continue; // expMode = NONE
            (uint256 u, uint256 t) = (o.u, o.t);
            if (!init[u][t]) {
                address a = usr[u];
                free[u][t] = tok[t].balanceOf(a) - tok[t].lockedOf(a);
                (uint256 capA, uint256 usedA) = tok[t].autoAllowance(a, address(sp));
                (uint256 capB, uint256 usedB) = tok[t].userTotal(a);
                uint256 r1 = capA > usedA ? capA - usedA : 0;
                uint256 r2 = capB > usedB ? capB - usedB : 0;
                rem[u][t] = r1 < r2 ? r1 : r2;
                dr[u][t] = tok[t].debts(a) + tok[t].creditReservedOf(a);
                cap[u][t] = tok[t].effectiveCreditCap(a);
                init[u][t] = true;
            }
            if (opRun[t] < o.a0) continue; // operator solvency is checked before the token
            if (rem[u][t] >= o.a0 && free[u][t] >= o.x0) {
                o.expMode = MODE_BALANCE;
                free[u][t] -= o.x0;
                rem[u][t] -= o.a0;
            } else if (cap[u][t] > 0 && dr[u][t] + o.a0 <= cap[u][t]) {
                o.expMode = MODE_CREDIT;
                dr[u][t] += o.a0;
            }
            if (o.expMode != MODE_NONE) opRun[t] -= o.a0;
        }
    }

    function _build(B memory x) internal {
        for (uint256 i; i < x.os.length; i++) {
            Op memory o = x.os[i];
            o.id = keccak256(abi.encode(_rs, i, "hit"));
            bytes memory inner;
            if (o.exec == EX_OK) {
                inner = abi.encodeCall(V55FuzzTarget.hit, (o.id));
            } else if (o.exec == EX_MOVE) {
                int256 cur = feed.answer();
                int256 nv = cur * int256(9_000 + _r(2_001)) / 10_000;
                if (nv < 1_000e8) nv = 1_000e8;
                if (nv > 4_000e8) nv = 4_000e8;
                o.moveTo = nv;
                inner = abi.encodeCall(V55FuzzTarget.hitMovePrice, (o.id, address(feed), address(sp), nv));
            } else if (o.exec == EX_REVERT) {
                inner = abi.encodeCall(V55FuzzTarget.hitRevert, (o.id));
            } else {
                inner = abi.encodeCall(V55FuzzTarget.hitBurn, (o.id));
            }
            o.op.sender = usr[o.u];
            o.op.nonce = (++_nk[o.u]) << 64; // fresh nonce key per op (sequence 0)
            o.op.callData = abi.encodeWithSignature("execute(address,uint256,bytes)", address(target), 0, inner);
            o.op.accountGasLimits = bytes32(abi.encodePacked(uint128(VERIF_GAS), o.callGas));
            o.op.preVerificationGas = PVG;
            o.op.gasFees = bytes32(abi.encodePacked(uint128(o.fee), uint128(o.fee)));
            o.op.paymasterAndData = abi.encodePacked(
                address(sp), uint128(PM_VERIF_GAS), o.postGas, opr[o.t], type(uint256).max, address(tok[o.t]), uint8(0)
            );
            o.h = entryPoint.getUserOpHash(o.op);
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk[o.u], MessageHashUtils.toEthSignedMessageHash(o.h));
            o.op.signature = abi.encodePacked(r, s, v);
            if (o.inject && o.expMode != MODE_NONE) {
                // only THIS op's settlement reverts (calldata prefix = selector ‖ user ‖ opHash)
                vm.mockCallRevert(address(tok[o.t]),
                    abi.encodeWithSelector(IxPNTsTokenV2.settleLocked.selector, usr[o.u], o.h), "G2: injected settle failure");
                vm.mockCallRevert(address(tok[o.t]),
                    abi.encodeWithSelector(IxPNTsTokenV2.settleCredit.selector, usr[o.u], o.h), "G2: injected settle failure");
            }
        }
    }

    function _pre(B memory x) internal view {
        for (uint256 t; t < 2; t++) {
            x.opBal0[t] = _opBal(t);
            x.supply0[t] = tok[t].totalSupply();
            for (uint256 u; u < 3; u++) {
                x.bal0[u][t] = tok[t].balanceOf(usr[u]);
                x.debt0[u][t] = tok[t].debts(usr[u]);
                require(tok[t].lockedOf(usr[u]) == 0 && tok[t].creditReservedOf(usr[u]) == 0,
                    "I10: no residual escrow / reservation at bundle start");
            }
        }
        x.rev0 = sp.protocolRevenue();
        x.dep0 = entryPoint.balanceOf(address(sp));
    }

    // ------------------------------------------------------------------
    // submission (predicted rejections verified one by one) + log parsing
    // ------------------------------------------------------------------

    /// @return executed false if every op was (correctly) rejected
    function _submit(B memory x, Stats memory st) internal returns (bool executed) {
        uint256 n = x.os.length;
        while (true) {
            uint256 m;
            for (uint256 i; i < n; i++) if (!x.os[i].rejected) m++;
            if (m == 0) return false;
            PackedUserOperation[] memory ops = new PackedUserOperation[](m);
            uint256 k;
            uint256 firstN = type(uint256).max;
            uint256 firstNi;
            for (uint256 i; i < n; i++) {
                if (x.os[i].rejected) continue;
                if (x.os[i].expMode == MODE_NONE && firstN == type(uint256).max) { firstN = k; firstNi = i; }
                ops[k++] = x.os[i].op;
            }
            vm.recordLogs();
            bool ok;
            bytes memory err;
            try entryPoint.handleOps(ops, payable(beneficiary)) { ok = true; } catch (bytes memory e) { err = e; }
            Vm.Log[] memory logs = vm.getRecordedLogs();
            if (!ok) {
                if (firstN == type(uint256).max) {
                    console.log("unexpected handleOps revert; seed state", _rs);
                    console.logBytes(err);
                }
                assertTrue(firstN != type(uint256).max, "model: bundle rejected although every op was predicted valid");
                assertEq(err, abi.encodeWithSelector(IEntryPoint.FailedOp.selector, firstN, "AA34 signature error"),
                    "model: the first predicted-invalid op is rejected by SP (AA34) at its index (k-th op rejected)");
                x.os[firstNi].rejected = true;
                st.rejected++;
                if (x.os[firstNi].postGas < MIN_POST_OP_GAS) st.rejMinMinus1++;
                continue;
            }
            assertEq(firstN, type(uint256).max, "model: an op predicted invalid was admitted");
            _parse(x, logs);
            return true;
        }
    }

    function _find(B memory x, bytes32 h) internal pure returns (uint256) {
        for (uint256 i; i < x.os.length; i++) if (x.os[i].h == h) return i;
        return type(uint256).max;
    }

    function _parse(B memory x, Vm.Log[] memory logs) internal view {
        uint256 j;
        // validation phase: everything before BeforeExecution
        for (; j < logs.length; j++) {
            Vm.Log memory l = logs[j];
            if (l.topics.length == 0) continue;
            if (l.emitter == EP && l.topics[0] == T_BEFORE_EXEC) break;
            if (l.topics.length < 3) continue;
            if (l.topics[0] == T_LOCK_CREATED || l.topics[0] == T_CREDIT_RESERVED) {
                uint256 i = _find(x, l.topics[2]);
                require(i != type(uint256).max, "log: validation event for an unknown op");
                Op memory o = x.os[i];
                assertEq(l.emitter, address(tok[o.t]), "log: reservation on the op's own token");
                assertEq(o.mode, MODE_NONE, "log: one reservation per op");
                if (l.topics[0] == T_LOCK_CREATED) {
                    o.mode = MODE_BALANCE;
                    (o.xLocked, o.aRes) = abi.decode(l.data, (uint256, uint256));
                } else {
                    o.mode = MODE_CREDIT;
                    o.aRes = abi.decode(l.data, (uint256));
                }
            }
        }
        require(j < logs.length, "log: BeforeExecution missing");
        // execution phase: each op's logs end with its UserOperationEvent
        uint256 segStart = j + 1;
        for (j = segStart; j < logs.length; j++) {
            Vm.Log memory l = logs[j];
            if (l.topics.length == 0 || !(l.emitter == EP && l.topics[0] == T_USEROP)) continue;
            uint256 i = _find(x, l.topics[1]);
            require(i != type(uint256).max, "log: UserOperationEvent for an unknown op");
            Op memory o = x.os[i];
            assertFalse(o.seen, "log: one UserOperationEvent per op");
            o.seen = true;
            (, o.success, o.G, ) = abi.decode(l.data, (uint256, bool, uint256, uint256));
            for (uint256 m = segStart; m < j; m++) {
                Vm.Log memory s = logs[m];
                if (s.topics.length == 0) continue;
                bytes32 t0 = s.topics[0];
                if (s.emitter == EP && t0 == T_POSTOP_REVERT) {
                    assertEq(s.topics[1], o.h, "log: PostOpRevertReason belongs to the op");
                    o.postReverted = true;
                } else if (s.emitter == address(sp) && t0 == T_TX_SPONSORED) {
                    (, uint256 c) = abi.decode(s.data, (uint256, uint256));
                    o.nTS++;
                    o.spCharge += c;
                } else if (s.emitter == address(tok[o.t]) && t0 == T_LOCK_SETTLED && s.topics[2] == o.h) {
                    (uint256 xb, uint256 ac) = abi.decode(s.data, (uint256, uint256));
                    o.settleEvt = true;
                    o.xBurned += xb;
                    o.tokCharge += ac;
                } else if (s.emitter == address(tok[o.t]) && t0 == T_CREDIT_SETTLED && s.topics[2] == o.h) {
                    o.settleEvt = true;
                    o.tokCharge += abi.decode(s.data, (uint256));
                }
            }
            segStart = j + 1;
        }
    }

    // ------------------------------------------------------------------
    // per-op assertions (I9, I8, B-1, model, DSR no-subsidy)
    // ------------------------------------------------------------------

    function _checkOps(B memory x, Stats memory st, Ghost memory gh) internal {
        uint256[3] memory perSender;
        uint256 bUnbCnt;
        uint256 bUnbAmt;
        for (uint256 i; i < x.os.length; i++) {
            Op memory o = x.os[i];
            address u = usr[o.u];
            if (o.rejected) {
                // L-1: a rejected op leaves no record anywhere
                assertEq(tok[o.t].lockOf(o.h, u).locker, address(0), "L-1: rejected op left no lock");
                assertEq(tok[o.t].creditReservationOf(o.h, u).locker, address(0), "L-1: rejected op left no reservation");
                (address rf, ) = sp.inflightOf(o.h);
                assertEq(rf, address(0), "L-1: rejected op left no in-flight sponsorship");
                continue;
            }
            perSender[o.u]++;
            assertTrue(o.seen, "every admitted op has a UserOperationEvent");
            assertEq(o.mode, o.expMode, "model: validation mode (1=BALANCE, 2=CREDIT) as predicted");
            assertEq(o.aRes, o.a0, "model: a0 == ceil(ceil(maxCost@cachedPrice) x (1 + fee + buffer))");
            if (o.mode == MODE_BALANCE) assertEq(o.xLocked, o.x0, "model: x0 == ceil(a0 x rate / 1e18)");

            o.kept = target.hits(o.id) > 0;
            o.settled = tok[o.t].usedOpHashes(o.h) && o.settleEvt;

            // ---- I9: no unbacked sponsorship (per op; accumulated per bundle / operator / campaign)
            uint256 unb = o.spCharge > o.tokCharge ? o.spCharge - o.tokCharge : 0;
            bool unbacked = unb > 0 || ((o.kept || o.nTS > 0) && !o.settleEvt);
            if (unbacked) {
                uint256 amt = unb > 0 ? unb : o.a0;
                gh.unbCnt[o.t]++;
                gh.unbAmt[o.t] += amt;
                bUnbCnt++;
                bUnbAmt += amt;
                st.unbCnt++;
                st.unbAmt += amt;
            }
            assertFalse(unbacked, "I9: unbacked sponsorship per op == 0 (SP charged / execution kept without burn or debt)");
            assertEq(o.spCharge, o.tokCharge, "I9: SP charge == token-side charge (burn-equivalent aPNTs or debt)");
            assertLe(o.nTS, 1, "I9: at most one sponsorship record per op");

            // ---- I8 / B-1
            if (o.kept) assertTrue(o.settled, "I8: user execution effect kept => op settled (usedOpHashes + Lock/CreditSettled)");
            assertEq(o.settled, !o.inject, "I8/B-1: op settled iff its settlement was not made to fail");
            assertEq(o.postReverted, o.inject,
                "B-1: postOp reverts only on an injected settle failure (no OOG, incl. postOpGasLimit == MIN)");
            bool execOk = o.exec == EX_OK || o.exec == EX_MOVE;
            assertEq(o.kept, o.settled && execOk, "I8: effect kept iff settled and the execution succeeded");
            assertEq(o.success, o.settled && execOk, "EntryPoint success flag == kept");
            assertEq(tok[o.t].usedOpHashes(o.h), o.settled, "usedOpHashes set only by a real settlement");

            if (o.settled) {
                assertLe(o.tokCharge, o.a0, "charge <= a0");
                if (o.mode == MODE_BALANCE) {
                    uint256 xc = Math.mulDiv(o.tokCharge, o.x0, o.a0, Math.Rounding.Ceil);
                    if (xc > o.x0) xc = o.x0;
                    assertEq(o.xBurned, xc, "conservation: xPNTs burned == xc = min(x0, ceil(c x x0 / a0))");
                    st.settledB++;
                } else {
                    assertEq(o.xBurned, 0, "CREDIT burns nothing");
                    st.settledC++;
                }
                if (!o.success) st.opReverted++;
                if (o.exec == EX_OOG) st.oogSettled++;
                if (o.exec == EX_MOVE) st.priceMoves++;
                if (o.kept) st.kept++;
                if (o.postGas == MIN_POST_OP_GAS) st.atMinSettled++;
                // ---- DSR: the user's (net-of-fee) charge covers what EntryPoint took from SP's deposit
                uint256 eth = _chargeEthNet(x, o.spCharge);
                assertGe(eth, o.G, "DSR no-subsidy: net-of-fee charge (ETH @ validation snapshot) >= op's actualGasCost");
                uint256 ppm = (eth - o.G) * 1e6 / o.G;
                if (st.nRatio < st.ratioPpm.length) {
                    st.ratioPpm[st.nRatio++] = ppm;
                    st.sumRatioPpm += ppm;
                }
                if (o.postGas <= MIN_POST_OP_GAS + 50_000 && st.nTight < st.tightPpm.length) {
                    st.tightPpm[st.nTight++] = ppm;
                    st.sumTightPpm += ppm;
                }
                st.sumChargeEth += eth;
                st.sumGSettled += o.G;
            } else {
                // ---- I10 (inside the tx): nothing charged, escrow / reservation and a0 still parked
                st.injected++;
                if (o.mode == MODE_BALANCE) st.injB++; else st.injC++;
                assertEq(o.xBurned, 0, "I10: failed postOp -> nothing burned");
                assertEq(o.tokCharge, 0, "I10: failed postOp -> no debt");
                assertLe(o.G, o.maxCost, "I10: EntryPoint cost of a failed-postOp op <= its prefund (borne by SP's deposit)");
                if (o.mode == MODE_BALANCE) {
                    assertEq(tok[o.t].lockOf(o.h, u).xLocked, o.x0, "I10: lock left for stale release");
                } else {
                    assertEq(tok[o.t].creditReservationOf(o.h, u).amount, o.a0, "I10: reservation left for stale release");
                }
                (address f, uint256 fa) = sp.inflightOf(o.h);
                assertEq(f, opr[o.t], "I10: operator a0 still in flight");
                assertEq(fa, o.a0, "I10: in-flight amount == a0");
                st.sumGInjected += o.G;
            }
            if (o.postGas == MIN_POST_OP_GAS) st.atMinIncluded++;
        }
        assertEq(bUnbCnt, 0, "I9: unbacked sponsorship count per bundle == 0");
        assertEq(bUnbAmt, 0, "I9: unbacked sponsorship amount per bundle == 0");
        for (uint256 u; u < 3; u++) {
            if (perSender[u] > 1) { st.repeatBundles++; break; }
        }
    }

    /// @dev charge (aPNTs, incl. protocol fee) -> ETH at the op's validation snapshot, fee removed:
    ///      eth = floor( floor(charge x BPS / (BPS + fee)) x 10^dec x aPriceUSD / (price x 1e18) ).
    ///      Both floors make the result a LOWER bound of what the user paid for gas.
    function _chargeEthNet(B memory x, uint256 charge) internal pure returns (uint256) {
        uint256 net = Math.mulDiv(charge, BPS, BPS + x.feeBps);
        return Math.mulDiv(net, (10 ** uint256(x.dec)) * x.aPrice, x.price * 1e18);
    }

    // ------------------------------------------------------------------
    // I10 after the transaction boundary
    // ------------------------------------------------------------------

    function _release(B memory x) internal {
        for (uint256 i; i < x.os.length; i++) {
            Op memory o = x.os[i];
            if (o.rejected || o.settled) continue;
            address u = usr[o.u];
            uint256 before = _opBal(o.t);
            if (o.mode == MODE_BALANCE) tok[o.t].releaseStaleLock(u, o.h);
            else tok[o.t].releaseStaleCredit(u, o.h);
            sp.releaseStaleSponsorship(o.h);
            assertEq(_opBal(o.t) - before, o.a0,
                "I10: releaseStaleSponsorship restores the operator's in-flight a0 after the tx boundary");
            (address f, ) = sp.inflightOf(o.h);
            assertEq(f, address(0), "I10: in-flight record deleted");
            assertEq(tok[o.t].lockOf(o.h, u).locker, address(0), "I10: stale lock released");
            assertEq(tok[o.t].creditReservationOf(o.h, u).locker, address(0), "I10: stale reservation released");
            sp.releaseStaleSponsorship(o.h); // idempotent
            assertEq(_opBal(o.t) - before, o.a0, "I10: release is idempotent");
        }
    }

    // ------------------------------------------------------------------
    // conservation (per bundle, after the releases)
    // ------------------------------------------------------------------

    function _conservation(B memory x, Stats memory st) internal {
        uint256[2] memory sumC;
        uint256[2] memory sumX;
        uint256[2][3] memory burnUT;
        uint256[2][3] memory debtUT;
        uint256 sumAll;
        uint256 gAll;
        uint256 gSettled;
        uint256 ethSettled;
        for (uint256 i; i < x.os.length; i++) {
            Op memory o = x.os[i];
            if (o.rejected) continue;
            gAll += o.G;
            if (!o.settled) continue;
            sumC[o.t] += o.spCharge;
            sumAll += o.spCharge;
            sumX[o.t] += o.xBurned;
            burnUT[o.u][o.t] += o.xBurned;
            if (o.mode == MODE_CREDIT) debtUT[o.u][o.t] += o.tokCharge;
            gSettled += o.G;
            ethSettled += _chargeEthNet(x, o.spCharge);
        }
        for (uint256 t; t < 2; t++) {
            assertEq(x.opBal0[t] - _opBal(t), sumC[t],
                "conservation: operator aPNTs delta == -sum(charge of its settled ops) (a0 - c refunded, failed ops restored)");
            assertEq(x.supply0[t] - tok[t].totalSupply(), sumX[t], "conservation: xPNTs burned (supply) == sum(xc)");
            for (uint256 u; u < 3; u++) {
                address a = usr[u];
                assertEq(x.bal0[u][t] - tok[t].balanceOf(a), burnUT[u][t],
                    "I10/conservation: user pays exactly the xc of its settled ops (net 0 for a failed postOp)");
                assertEq(tok[t].debts(a) - x.debt0[u][t], debtUT[u][t], "conservation: debt delta == sum(settleCredit)");
                assertEq(tok[t].lockedOf(a), 0, "I10: lockedOf back to its pre-bundle value");
                assertEq(tok[t].creditReservedOf(a), 0, "I10: creditReservedOf back to its pre-bundle value");
            }
        }
        assertEq(sp.protocolRevenue() - x.rev0, sumAll, "conservation: protocolRevenue delta == +sum(charge)");
        uint256 depDelta = x.dep0 - entryPoint.balanceOf(address(sp));
        assertEq(depDelta, gAll, "EP: SP deposit delta == sum(UserOperationEvent.actualGasCost) over the bundle");
        assertGe(ethSettled, gSettled, "DSR no-subsidy: bundle sum(net charge in ETH) >= sum(actualGasCost) of settled ops");
        st.sumDepDelta += depDelta;
    }

    // ------------------------------------------------------------------
    // external events between bundles
    // ------------------------------------------------------------------

    function _events(Stats memory st) internal {
        // blacklist: SBT eligibility or SP isBlocked (both written by the Registry)
        if (_r(100) < 25) {
            address a = usr[_r(3)];
            if (_r(2) == 0) {
                bool cur = sp.sbtHolders(a);
                bool nv = cur ? _r(100) >= 60 : true; // blacklisted -> restore; else blacklist w.p. 60%
                vm.prank(address(registry));
                sp.updateSBTStatus(a, nv);
            } else {
                uint256 t = _r(2);
                (, bool blocked) = sp.userOpState(opr[t], a);
                address[] memory us = new address[](1);
                bool[] memory bs = new bool[](1);
                us[0] = a;
                bs[0] = blocked ? false : _r(100) < 60;
                vm.prank(address(registry));
                sp.updateBlockedStatus(opr[t], us, bs);
            }
            st.evBlacklist++;
        }
        for (uint256 t; t < 2; t++) {
            // credit policy switch: queue -> 48 h -> execute (epoch++ invalidates requests), refresh price
            if (_r(100) < 10) {
                uint8 cur = tok[t].creditPolicy();
                uint8 np = cur == 2 ? uint8(_r(2)) : (_r(10) < 7 ? 2 : (cur == 0 ? 1 : 0));
                vm.prank(opr[t]);
                IG2Tok(address(tok[t])).queueCreditPolicy(np);
                vm.warp(vm.getBlockTimestamp() + 48 hours + 1);
                IG2Tok(address(tok[t])).executeCreditPolicy();
                assertEq(tok[t].creditPolicy(), np, "event: policy switched");
                sp.updatePrice();
                st.evPolicy++;
            }
            // operator pause / unpause (SP owner)
            (, , bool paused, , , , , , ) = sp.operators(opr[t]);
            if (paused ? _r(100) < 60 : _r(100) < 6) {
                vm.prank(owner);
                sp.setOperatorPaused(opr[t], !paused);
                st.evPause++;
            }
            // exchange rate (cooldown 1 h, +-20%)
            if (_r(100) < 20) {
                vm.warp(vm.getBlockTimestamp() + 1 hours + 1);
                uint256 old = tok[t].exchangeRate();
                uint256 nr = old * (8_000 + _r(4_001)) / 10_000;
                if (nr >= 1e14 && nr <= 1e22) {
                    vm.prank(opr[t]);
                    IG2Tok(address(tok[t])).updateExchangeRate(nr);
                    st.evRate++;
                }
            }
            // token emergency stop (S-4). Terminal for this SP: S-7 needs current != revoked.
            if (!tok[t].emergencyDisabled() && _r(1000) < 10) {
                vm.prank(opr[t]);
                IG2Tok(address(tok[t])).emergencyRevokePaymaster();
                vm.prank(opr[t]);
                vm.expectRevert(abi.encodeWithSignature("RecoveryNotComplete()"));
                IG2Tok(address(tok[t])).unsetEmergencyDisabled();
                st.evEmergency++;
            }
        }
        // tier change (GLOBAL tier source reads Registry.getCreditLimit)
        if (_r(100) < 25) {
            uint256 w = _r(10);
            registry.setCreditLimit(usr[_r(3)], w < 1 ? 0 : w < 3 ? _r(500 ether) : BIG_CAP);
            st.evTier++;
        }
        // E-1 user disable / enable of the SP
        for (uint256 u; u < 3; u++) {
            for (uint256 t; t < 2; t++) {
                bool d = tok[t].spenderDisabled(address(sp), usr[u]);
                if (d ? _r(100) < 60 : _r(100) < 3) {
                    vm.prank(usr[u]);
                    if (d) IG2Tok(address(tok[t])).enableSpenderForSelf(address(sp));
                    else IG2Tok(address(tok[t])).disableSpenderForSelf(address(sp));
                    st.evDisable++;
                }
            }
        }
        // ETH/USD and aPNTs/USD price moves (the bundle refreshes cachedPrice right after)
        if (_r(100) < 20) {
            int256 na = feed.answer() * int256(9_000 + _r(2_001)) / 10_000;
            if (na < 1_000e8) na = 1_000e8;
            if (na > 4_000e8) na = 4_000e8;
            feed.setAnswer(na);
            st.evPrice++;
        }
        if (_r(100) < 15) {
            uint256 np = sp.aPNTsPriceUSD() * (9_500 + _r(1_001)) / 10_000;
            if (np < 0.01 ether) np = 0.01 ether;
            if (np > 0.05 ether) np = 0.05 ether;
            vm.prank(owner);
            sp.setAPNTSPrice(np);
            st.evPrice++;
        }
    }

    // ------------------------------------------------------------------
    // utils
    // ------------------------------------------------------------------

    function _r(uint256 n) internal returns (uint256) {
        _rs = uint256(keccak256(abi.encode(_rs, "G2")));
        return n == 0 ? 0 : _rs % n;
    }

    function _opBal(uint256 t) internal view returns (uint256 b) {
        (b, , , , , , , , ) = sp.operators(opr[t]);
    }

    function _newStats(uint256 cap) internal pure returns (Stats memory st) {
        st.ratioPpm = new uint256[](cap);
        st.tightPpm = new uint256[](cap);
    }

    function _report(Stats memory st) internal pure {
        console.log("G2 campaign: seeds", st.runs, "bundles executed", st.bundles);
        console.log("  ops planned / rejected (AA34, verified one by one)", st.planned, st.rejected);
        console.log("  rejected at postOpGasLimit == MIN-1", st.rejMinMinus1);
        console.log("  settled BALANCE / CREDIT", st.settledB, st.settledC);
        console.log("  injected settle failures (BALANCE / CREDIT)", st.injB, st.injC);
        console.log("  bundles with a repeated sender", st.repeatBundles);
        console.log("  ops at postOpGasLimit == MIN: admitted / settled", st.atMinIncluded, st.atMinSettled);
        console.log("  opReverted settled (of which OOG)", st.opReverted, st.oogSettled);
        console.log("  executions kept / mid-bundle price moves", st.kept, st.priceMoves);
        console.log("  events: blacklist / policy / tier", st.evBlacklist, st.evPolicy, st.evTier);
        console.log("  events: pause / E-1 disable / emergency", st.evPause, st.evDisable, st.evEmergency);
        console.log("  events: rate / price", st.evRate, st.evPrice);
        console.log("  I9 unbacked count / amount", st.unbCnt, st.unbAmt);
        console.log("  EP deposit delta (wei) / sum G settled / sum G injected", st.sumDepDelta, st.sumGSettled, st.sumGInjected);
        console.log("  sum net charge (ETH wei) over settled ops", st.sumChargeEth);

        _dist("  R1-8 overcharge (chargeEthNet - G)/G, all settled ops, ppm; n =", st.ratioPpm, st.nRatio, st.sumRatioPpm);
        _dist("  R1-8 overcharge, settled ops with postOpGasLimit <= MIN+50k, ppm; n =", st.tightPpm, st.nTight, st.sumTightPpm);
    }

    function _dist(string memory title, uint256[] memory a, uint256 n, uint256 sum) internal pure {
        console.log(title, n);
        if (n == 0) return;
        _qsort(a, 0, int256(n) - 1);
        console.log("    mean ppm", sum / n);
        console.log("    p95  ppm", a[(n * 95 + 99) / 100 - 1]);
        console.log("    max  ppm", a[n - 1]);
        console.log("    min  ppm", a[0]);
        console.log("    median ppm", a[(n - 1) / 2]);
    }

    function _qsort(uint256[] memory a, int256 lo, int256 hi) internal pure {
        while (lo < hi) {
            uint256 pivot = a[uint256(lo + (hi - lo) / 2)];
            int256 i = lo;
            int256 j = hi;
            while (i <= j) {
                while (a[uint256(i)] < pivot) i++;
                while (a[uint256(j)] > pivot) j--;
                if (i <= j) {
                    (a[uint256(i)], a[uint256(j)]) = (a[uint256(j)], a[uint256(i)]);
                    i++;
                    j--;
                }
            }
            // recurse into the smaller half, loop on the larger (bounded depth)
            if (j - lo < hi - i) {
                if (lo < j) _qsort(a, lo, j);
                lo = i;
            } else {
                if (i < hi) _qsort(a, i, hi);
                hi = j;
            }
        }
    }
}
