// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;
import { SuperPaymasterAdminCalls } from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
using SuperPaymasterAdminCalls for SuperPaymaster; // D5b: extension functions on a SuperPaymaster reference

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import {MockXPNTsFactory} from "../helpers/MockXPNTsFactory.sol";
import {V2TokenDeployer, IxPNTsV2Admin} from "../helpers/V2TokenDeployer.sol";
import {xPNTsTokenV2} from "src/tokens/v2/xPNTsTokenV2.sol";
import {xPNTsV2Base} from "src/tokens/v2/xPNTsV2Base.sol";

// ─── Mocks ────────────────────────────────────────────────────────────────────

contract BurnMockEntryPoint is IEntryPoint {
    function depositTo(address) external payable {}
    function addStake(uint32) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable) external {}
    function getSenderAddress(bytes memory) external {}
    function handleOps(PackedUserOperation[] calldata, address payable) external {}
    function handleAggregatedOps(UserOpsPerAggregator[] calldata, address payable) external {}
    function getUserOpHash(PackedUserOperation calldata op) external view returns (bytes32) { return keccak256(abi.encode(op, block.chainid)); }
    function getNonce(address, uint192) external pure returns (uint256) { return 0; }
    function balanceOf(address) external pure returns (uint256) { return 0; }
    function getDepositInfo(address) external pure returns (DepositInfo memory) {}
    function incrementNonce(uint192) external {}
    function fail(bytes memory, uint256, uint256) external {}
    function delegateAndRevert(address, bytes calldata) external {}
    function withdrawTo(address payable, uint256) external {}
}

contract BurnMockPriceFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000 * 1e8, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

contract BurnMockAPNTs is ERC20 {
    constructor() ERC20("aPNTs", "aPNT") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract BurnMockRegistry is IRegistry {
    mapping(bytes32 => mapping(address => bool)) public roles;

    function hasRole(bytes32 role, address account) external view returns (bool) { return roles[role][account]; }
    function setRole(bytes32 role, address account, bool val) external { roles[role][account] = val; }
    uint256 public creditLimitOverride = 1000 ether;
    /// @dev GLOBAL credit tier (GlobalTierSource.tierOf) for the v2 token.
    function getCreditLimit(address) external view returns (uint256) { return creditLimitOverride; }
    function setCreditLimitOverride(uint256 v) external { creditLimitOverride = v; }

    function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external {}
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata) external {}
    function setReputationSource(address, bool) external {}
    function markProposalExecuted(uint256) external override {}
    function registerRole(bytes32, address, bytes calldata) external {}
    function exitRole(bytes32) external {}
    function safeMintForRole(bytes32, address, bytes calldata) external returns (uint256) { return 0; }
    function configureRole(bytes32, IRegistry.RoleConfig calldata) external {}
    function setStaking(address) external {}
    function setMySBT(address) external {}
    function setSuperPaymaster(address) external {}
    function queueBLSAggregator(address) external {}
    function setCreditTier(uint256, uint256) external {}
    function getRoleConfig(bytes32) external view returns (IRegistry.RoleConfig memory) {}
    function getUserRoles(address) external view returns (bytes32[] memory) {}
    function getRoleMembers(bytes32) external view returns (address[] memory) {}
    function getRoleUserCount(bytes32) external view returns (uint256) { return 0; }

    function version() external pure returns (string memory) { return "MockBurn"; }
    function isReputationSource(address) external view returns (bool) { return false; }
    function syncStakeFromStaking(address, bytes32, uint256) external {}
    function getEffectiveStake(address, bytes32) external view returns (uint256) { return 0; }
}

// ─── Test Contract ─────────────────────────────────────────────────────────────

/// @notice Legacy "burn, else recordDebt, else pendingDebts" postOp fallback, migrated to
///         SuperPaymaster 5.5.0 + xPNTs v2. The fallback chain no longer exists:
///           - validation escrows the user's xPNTs (BALANCE) or, only on INSUFFICIENT, reserves
///             credit (CREDIT, C-1); otherwise the op is not sponsored (R-2);
///           - postOp settles the admitted escrow/reservation WITHOUT try/catch (B-1): a failed
///             settlement reverts postOp (EntryPoint undoes the user's execution) — there is no
///             pendingDebts bucket and no retryPendingDebt/clearPendingDebt;
///           - the operator's a0 is in flight until postOp and restored by releaseStaleSponsorship
///             if postOp never completed (R10-M1b / I10).
contract SuperPaymaster_BurnRestore_Test is Test {
    SuperPaymaster public paymaster;
    BurnMockRegistry public registry;
    BurnMockEntryPoint public entryPoint;
    BurnMockPriceFeed public priceFeed;
    BurnMockAPNTs public apnts;
    xPNTsTokenV2 public xpnts;
    MockXPNTsFactory public mockFactory;

    address public owner     = address(0x1);
    address public treasury  = address(0x2);
    address public operator1 = address(0x3);
    address public user1     = address(0x5);

    bytes32 constant ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");
    bytes32 constant ROLE_COMMUNITY       = keccak256("COMMUNITY");

    uint256 constant MAX_COST = 1000; // wei — gives small but non-zero aPNTs charge
    uint8 constant MODE_BALANCE = 1;
    uint8 constant MODE_CREDIT = 2;

    function setUp() public {
        vm.startPrank(owner);

        entryPoint = new BurnMockEntryPoint();
        priceFeed  = new BurnMockPriceFeed();
        apnts      = new BurnMockAPNTs();
        registry   = new BurnMockRegistry();

        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(registry)),
            address(priceFeed),
            owner,
            address(apnts),
            treasury,
            3600
        );

        vm.warp(block.timestamp + 2 hours);
        paymaster.updatePrice();

        registry.setRole(ROLE_PAYMASTER_SUPER, operator1, true);
        registry.setRole(ROLE_COMMUNITY, operator1, true);
        vm.stopPrank();

        V2TokenDeployer.Stack memory st = V2TokenDeployer.deployStack(address(paymaster), address(registry));
        xpnts = V2TokenDeployer.newToken(st, owner, operator1, address(paymaster), 1e18);

        vm.startPrank(owner);
        // Deploy mock factory and register operator token (P1-4 fix)
        mockFactory = new MockXPNTsFactory();
        paymaster.setXPNTsFactory(address(mockFactory));
        mockFactory.setToken(operator1, address(xpnts));

        apnts.mint(operator1, 10_000 ether);
        vm.stopPrank();

        vm.prank(address(registry));
        paymaster.updateSBTStatus(user1, true);

        vm.startPrank(operator1);
        apnts.approve(address(paymaster), type(uint256).max);
        paymaster.configureOperator(address(xpnts), address(0x999));
        paymaster.deposit(5_000 ether);
        vm.stopPrank();
    }

    // Build a 5.5.0 paymasterAndData for operator1 (token field required, R4-H1).
    function _buildPaymasterData() internal view returns (bytes memory) {
        return V2TokenDeployer.pmd(address(paymaster), uint128(100000), uint128(200000), operator1, type(uint256).max, address(xpnts), 0);
    }

    function _validate(bytes32 opHash, uint256 maxCost) internal returns (bytes memory ctx, uint256 vd) {
        PackedUserOperation memory op;
        op.sender = user1;
        op.paymasterAndData = _buildPaymasterData();
        vm.prank(address(entryPoint));
        (ctx, vd) = paymaster.validatePaymasterUserOp(op, opHash, maxCost);
    }

    // Run validate and return context (asserts the op was admitted).
    function _runValidate() internal returns (bytes memory ctx) {
        uint256 vd;
        (ctx, vd) = _validate(bytes32(uint256(1)), MAX_COST);
        assertEq(uint160(vd), 0, "setup: op must be admitted");
    }

    /// @dev D3-M: low-level call so a postOp that reverts where it must settle (or, on a replay,
    ///      must be a silent no-op — P1-17) is reported by a named assertion.
    function _postOp(bytes memory ctx, uint256 actualGasCost) internal {
        vm.prank(address(entryPoint));
        (bool ok, bytes memory ret) = address(paymaster).call(
            abi.encodeCall(IPaymaster.postOp, (IPaymaster.PostOpMode.opSucceeded, ctx, actualGasCost, 0))
        );
        if (!ok) emit log_named_bytes("postOp revert data", ret);
        assertTrue(ok, "postOp must not revert here (settle, or no-op on replay)");
    }

    function _enableAutoCredit(uint256 tier) internal {
        registry.setCreditLimitOverride(tier);
        vm.prank(owner); // communityOwner
        IxPNTsV2Admin(address(xpnts)).queueCreditPolicy(2);
        vm.warp(block.timestamp + 48 hours);
        IxPNTsV2Admin(address(xpnts)).executeCreditPolicy();
        paymaster.updatePrice();
        vm.prank(user1);
        IxPNTsV2Admin(address(xpnts)).requestCredit(1_000 ether);
    }

    function _opBalance() internal view returns (uint128 b) { (b,,,,,,,,) = paymaster.operators(operator1); }

    function _mode(bytes memory ctx) internal pure returns (uint8) {
        return abi.decode(ctx, (SuperPaymaster.OpCtx)).mode;
    }

    // ── D3-M additions (make R-2 and the same-tx release guard decisive) ───────

    /// @notice R-2: credit is tried ONLY when the escrow lock answers INSUFFICIENT. An SP-renew
    ///         flag for a user who chose account-only renewal (MODE_ACCOUNT_ONLY) makes the lock
    ///         answer INVALID_RENEWAL; even with AUTO credit on file the op must NOT fall back to
    ///         credit. Positive control: same user, same credit, flags = 0 -> admitted on credit.
    function test_R2_NonInsufficientLockFailure_NeverFallsBackToCredit() public {
        _enableAutoCredit(1000 ether);
        vm.prank(user1);
        (bool setOk,) = address(xpnts).call(abi.encodeWithSignature("setRenewalMode(uint8)", uint8(1)));
        assertTrue(setOk, "setup: account-only renewal mode");
        PackedUserOperation memory op;
        op.sender = user1;
        op.paymasterAndData = V2TokenDeployer.pmd(
            address(paymaster), uint128(100000), uint128(200000), operator1, type(uint256).max, address(xpnts), 1
        );
        uint128 opBefore = _opBalance();
        vm.prank(address(entryPoint));
        (bytes memory ctx, uint256 vd) = paymaster.validatePaymasterUserOp(op, bytes32(uint256(0xA2)), MAX_COST);
        assertEq(uint160(vd), 1, "INVALID_RENEWAL lock result must not fall back to credit (R-2)");
        assertEq(ctx.length, 0, "no context");
        assertEq(xpnts.creditReservedOf(user1), 0, "no credit reservation");
        assertEq(_opBalance(), opBefore, "operator not debited");

        (bytes memory ctx2, uint256 vd2) = _validate(bytes32(uint256(0xA3)), MAX_COST);
        assertEq(uint160(vd2), 0, "control: flags = 0 -> INSUFFICIENT -> admitted on credit");
        assertEq(_mode(ctx2), MODE_CREDIT, "control: CREDIT mode");
    }

    /// @notice R10-M1b: inside the original transaction the in-flight a0 cannot be released
    ///         (postOp may still settle it). One test = one transaction here (not isolated).
    function test_ReleaseStaleSponsorship_SameTx_RevertsInFlight() public {
        IxPNTsV2Admin(address(xpnts)).mint(user1, 1_000 ether);
        bytes memory ctx = _runValidate();
        uint256 a0 = abi.decode(ctx, (SuperPaymaster.OpCtx)).a0;
        uint128 opMid = _opBalance();

        vm.expectRevert(SuperPaymasterStorage.SponsorshipInFlight.selector);
        paymaster.releaseStaleSponsorship(bytes32(uint256(1)));

        (address f, uint256 inflA0) = paymaster.inflightOf(bytes32(uint256(1)));
        assertEq(f, operator1, "still in flight");
        assertEq(inflA0, a0);
        assertEq(_opBalance(), opMid, "nothing restored while live");
        // and the live op still settles normally
        _postOp(ctx, MAX_COST);
        (f,) = paymaster.inflightOf(bytes32(uint256(1)));
        assertEq(f, address(0), "settled");
    }

    // ── Test 1: User has xPNTs → escrow at validation, burn at postOp, no debt ─

    function test_PostOp_Burns_WhenUserHasBalance() public {
        // Pre-fund user with enough xPNTs to cover the gas charge
        IxPNTsV2Admin(address(xpnts)).mint(user1, 1_000 ether);
        uint256 balBefore = xpnts.balanceOf(user1);

        bytes memory ctx = _runValidate();
        assertEq(_mode(ctx), MODE_BALANCE, "balance-funded user -> BALANCE mode");
        assertGt(xpnts.lockedOf(user1), 0, "xPNTs escrowed at validation");

        _postOp(ctx, MAX_COST);

        assertLt(xpnts.balanceOf(user1), balBefore, "User xPNTs balance must decrease after burn");
        assertEq(xpnts.lockedOf(user1), 0, "escrow cleared by settleLocked");
        assertEq(xpnts.debts(user1), 0, "no debt when the escrow pays (I3)");
        (address f,) = paymaster.inflightOf(bytes32(uint256(1)));
        assertEq(f, address(0), "in-flight sponsorship cleared");
    }

    // ── REMOVED legacy: test_PostOp_FallsBack_ToRecordDebt_WhenNoBalance ─────
    // 5.5.0 has no postOp burn->recordDebt fallback. An empty-balance user is either rejected at
    // validation (credit OFF, the v2 default) or admitted on a validation-time CREDIT reservation
    // that postOp turns into debt. Covered by the two tests below.

    function test_NoBalance_CreditOff_RejectedAtValidation() public {
        assertEq(xpnts.balanceOf(user1), 0);
        uint128 opBefore = _opBalance();
        (bytes memory ctx, uint256 vd) = _validate(bytes32(uint256(1)), MAX_COST);
        assertEq(uint160(vd), 1, "empty balance + credit OFF -> sigFail (R-2)");
        assertEq(ctx.length, 0, "no context");
        assertEq(_opBalance(), opBefore, "operator not debited");
        assertEq(xpnts.creditReservedOf(user1), 0, "no reservation (L-1)");
        assertEq(xpnts.debts(user1), 0, "no debt (T-R14-06)");
    }

    function test_NoBalance_AutoCredit_SettlesAsDebt() public {
        _enableAutoCredit(1000 ether);
        bytes memory ctx = _runValidate();
        assertEq(_mode(ctx), MODE_CREDIT, "empty balance + AUTO credit -> CREDIT mode");
        uint256 a0 = abi.decode(ctx, (SuperPaymaster.OpCtx)).a0;
        assertEq(xpnts.creditReservedOf(user1), a0, "reserved at validation (C-1)");

        _postOp(ctx, MAX_COST);

        assertGt(xpnts.debts(user1), 0, "settleCredit recorded the debt");
        assertLe(xpnts.debts(user1), a0, "debt <= admitted reservation (C-2)");
        assertEq(xpnts.creditReservedOf(user1), 0, "reservation consumed");
    }

    // ── AUDIT H-1 — 5.5.0 BEHAVIOUR CHANGE ───────────────────────────────────
    // Legacy (Plan A): a zero-credit user was rejected in validation EVEN WITH ample xPNTs, because
    // the user could drain its balance inside its own UserOp before the postOp burn. In 5.5.0 the
    // validation ESCROWS x0 of the user's xPNTs (A-1: balance - value >= lockedOf on every
    // transfer/burn), so the drain is impossible and a balance-funded op no longer needs credit.
    // New correct behaviour: admitted in BALANCE mode, the drain reverts, postOp is paid in full.
    function test_AuditH1_OverCeilingOp_RejectedInValidation() public {
        registry.setCreditLimitOverride(0); // zero-credit user
        IxPNTsV2Admin(address(xpnts)).mint(user1, 1_000 ether); // user HAS balance

        (bytes memory ctx, uint256 validationData) = _validate(bytes32(uint256(1)), MAX_COST);
        assertEq(uint160(validationData), 0, "5.5.0: balance-funded op admitted on escrow, credit irrelevant");
        assertEq(_mode(ctx), MODE_BALANCE, "BALANCE mode, not credit");
        uint256 locked = xpnts.lockedOf(user1);
        assertGt(locked, 0, "x0 escrowed");

        // H-1 drain attempt inside the user's own execution: move the whole balance away.
        uint256 bal = xpnts.balanceOf(user1);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(xPNTsV2Base.BalanceLocked.selector, user1, locked));
        xpnts.transfer(address(0xD7A1), bal);
        // Everything above the escrow stays freely transferable (the lock is exactly x0).
        vm.prank(user1);
        xpnts.transfer(address(0xD7A1), bal - locked);
        assertEq(xpnts.balanceOf(user1), locked, "only the escrow is left");

        _postOp(ctx, MAX_COST);
        assertEq(xpnts.debts(user1), 0, "H-1 tail closed: no over-ceiling debt ever booked");
        assertEq(xpnts.lockedOf(user1), 0, "escrow settled");
        assertLt(xpnts.balanceOf(user1), locked, "user paid from the escrow");
    }

    // ── AUDIT H-1: zero-credit user rejected on EVERY attempt when it cannot escrow ──
    // Legacy: rejected every attempt regardless of balance. 5.5.0: a funded user is escrowed (see
    // above); an UNFUNDED zero-credit user — even with credit switched ON and a request on file —
    // is rejected every attempt, never reserves, never debits the operator.
    function test_AuditH1_ZeroCredit_RejectedEveryAttempt() public {
        _enableAutoCredit(0); // AUTO + request, but GLOBAL tier 0 -> effectiveCreditCap 0
        assertEq(xpnts.effectiveCreditCap(user1), 0);
        uint128 opBefore = _opBalance();

        for (uint256 i = 1; i <= 2; i++) {
            (, uint256 validationData) = _validate(bytes32(i), MAX_COST);
            assertEq(uint160(validationData), 1, "zero-credit unfunded op rejected every attempt");
        }
        assertEq(xpnts.creditReservedOf(user1), 0, "never reserved");
        assertEq(_opBalance(), opBefore, "operator never debited");
    }

    // ── AUDIT H-1: no regression — within-ceiling debt is still recorded ───────
    // An honest user WITH credit and an empty balance gets normal token-level debt.
    function test_AuditH1_WithinCeilingDebt_RecordedNormally() public {
        _enableAutoCredit(1000 ether); // ample credit

        bytes memory ctx = _runValidate();
        _postOp(ctx, MAX_COST);

        assertGt(xpnts.debts(user1), 0, "within-ceiling debt still recorded normally");
        assertLe(xpnts.debts(user1), xpnts.effectiveCreditCap(user1), "debt within the ceiling");
    }

    // ── REMOVED legacy: test_PostOp_PendingDebts_WhenBothFail ────────────────
    // ── REMOVED legacy: test_RetryPendingDebt_Chunked ─────────────────────────
    // pendingDebts / retryPendingDebt / clearPendingDebt are gone (spec §3.3). B-1: a settlement
    // that fails reverts postOp — no silent bucket. Replacements:

    /// @notice B-1: settlement is not wrapped in try/catch. A context whose escrow does not exist
    ///         makes settleLocked revert and postOp bubbles it (no pendingDebts fallback).
    function test_B1_SettleFailure_RevertsPostOp_NoFallback() public {
        IxPNTsV2Admin(address(xpnts)).mint(user1, 1_000 ether);
        bytes memory ctx = _runValidate();
        SuperPaymaster.OpCtx memory c = abi.decode(ctx, (SuperPaymaster.OpCtx));
        c.opHash = bytes32(uint256(0xDEAD)); // no lock recorded under this hash
        uint256 revBefore = paymaster.protocolRevenue();

        vm.prank(address(entryPoint));
        vm.expectRevert(xPNTsV2Base.NoLock.selector);
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, abi.encode(c), MAX_COST, 0);

        assertEq(paymaster.protocolRevenue(), revBefore, "no revenue booked for a failed settlement");
    }

    /// @notice I10 / R10-M1b: postOp that never completes in the original transaction (here: the
    ///         next transaction, live markers gone) cannot settle; after the tx the operator's a0
    ///         and the user's escrow are both restored in full. No pendingDebts is ever written.
    /// forge-config: default.isolate = true
    function test_I10_PostOpOutsideOriginalTx_Reverts_ThenStaleReleaseRestores() public {
        IxPNTsV2Admin(address(xpnts)).mint(user1, 1_000 ether);
        uint256 balBefore = xpnts.balanceOf(user1);
        uint128 opBefore = _opBalance();
        uint256 revBefore = paymaster.protocolRevenue();
        bytes32 h = bytes32(uint256(1));

        (bytes memory ctx, uint256 vd) = _validate(h, MAX_COST); // tx 1: validation only
        assertEq(uint160(vd), 0);
        assertLt(_opBalance(), opBefore, "a0 in flight");

        vm.prank(address(entryPoint));
        (bool ok, bytes memory ret) = address(paymaster).call(
            abi.encodeCall(IPaymaster.postOp, (IPaymaster.PostOpMode.opSucceeded, ctx, MAX_COST, 0))
        );
        assertFalse(ok, "settlement outside the original transaction must revert");
        assertEq(bytes4(ret), xPNTsV2Base.NotLive.selector, "reverted for L-3 NotLive (not auth/other)");

        paymaster.releaseStaleSponsorship(h);
        xpnts.releaseStaleLock(user1, h);
        assertEq(_opBalance(), opBefore, "operator a0 fully restored");
        assertEq(xpnts.lockedOf(user1), 0, "user escrow fully released");
        assertEq(xpnts.balanceOf(user1), balBefore, "user charged nothing");
        assertEq(paymaster.protocolRevenue(), revBefore, "no revenue for an unsettled op");
        (address f,) = paymaster.inflightOf(h);
        assertEq(f, address(0), "in-flight record cleared");
    }

    /// @notice The removed legacy debt-management selectors are gone from the SP surface.
    function test_LegacyPendingDebtSelectorsRemoved() public {
        bytes[3] memory calls = [
            abi.encodeWithSignature("retryPendingDebt(address,address,uint256)", address(xpnts), user1, uint256(0)),
            abi.encodeWithSignature("clearPendingDebt(address,address)", address(xpnts), user1),
            abi.encodeWithSignature("pendingDebts(address,address)", address(xpnts), user1)
        ];
        for (uint256 i; i < calls.length; i++) {
            vm.prank(owner);
            (bool ok, ) = address(paymaster).call(calls[i]);
            assertFalse(ok, "legacy pendingDebts surface must not exist in 5.5.0");
        }
    }

    // ── Test 4: Two consecutive ops → two independent settlements (not replay) ─

    function test_PostOp_TwoOps_NoDuplicateReplay() public {
        IxPNTsV2Admin(address(xpnts)).mint(user1, 1_000 ether);
        uint256 bal0 = xpnts.balanceOf(user1);

        (bytes memory ctx1, uint256 vd1) = _validate(bytes32(uint256(1)), MAX_COST);
        assertEq(uint160(vd1), 0);
        _postOp(ctx1, MAX_COST);
        uint256 bal1 = xpnts.balanceOf(user1);
        assertLt(bal1, bal0, "First op must burn");

        // Op 2 — different userOpHash
        IxPNTsV2Admin(address(xpnts)).mint(user1, 1_000 ether);
        uint256 bal1b = xpnts.balanceOf(user1);
        (bytes memory ctx2, uint256 vd2) = _validate(bytes32(uint256(2)), MAX_COST);
        assertEq(uint160(vd2), 0);
        _postOp(ctx2, MAX_COST);

        assertLt(xpnts.balanceOf(user1), bal1b, "Second op must also burn (no replay collision)");
        assertEq(xpnts.debts(user1), 0, "No debt when balance sufficient");
        assertEq(xpnts.lockedOf(user1), 0, "both escrows cleared");
    }

    // ── Test 5 (was "overflow path burns"): actual > reservation → charge capped at a0 ──
    // Legacy crafted a context with a tiny initialAPNTs to force finalCharge > initialAPNTs. In
    // 5.5.0 postOp only settles a real escrow and charge = min(calc, a0) (§10.3): the user never
    // pays beyond what it committed at validation, and the operator refund is exactly zero.

    function test_PostOp_OverflowPath_BurnsXPNTs() public {
        IxPNTsV2Admin(address(xpnts)).mint(user1, 1_000 ether);
        uint256 balBefore = xpnts.balanceOf(user1);
        uint128 opBefore = _opBalance();
        uint256 revBefore = paymaster.protocolRevenue();

        bytes memory ctx = _runValidate();
        uint256 a0 = abi.decode(ctx, (SuperPaymaster.OpCtx)).a0;
        uint256 x0 = xpnts.lockedOf(user1);

        _postOp(ctx, MAX_COST * 1000); // actual cost far above the validated maxCost

        assertEq(balBefore - xpnts.balanceOf(user1), x0, "burn capped at the escrowed x0");
        assertEq(paymaster.protocolRevenue() - revBefore, a0, "revenue capped at a0");
        assertEq(uint256(opBefore) - _opBalance(), a0, "operator refund is zero at the cap");
        assertEq(xpnts.debts(user1), 0, "No debt when the escrow pays");
    }

    // ── Test 6 (was "overflow path falls back to recordDebt") — REMOVED legacy fallback.
    // Credit-mode equivalent: the debt booked is capped at the admitted reservation (C-2).

    function test_CreditPath_ChargeCappedAtReservation() public {
        _enableAutoCredit(1000 ether);
        bytes memory ctx = _runValidate();
        uint256 a0 = abi.decode(ctx, (SuperPaymaster.OpCtx)).a0;

        _postOp(ctx, MAX_COST * 1000);

        assertEq(xpnts.debts(user1), a0, "debt == min(charge, reservation) == a0");
        assertEq(xpnts.creditReservedOf(user1), 0);
    }

    // ── Test 7: Cross-path — escrow settled, same opHash postOp called again ──
    // P1-17: the SP-level _settledDebtOps guard makes a replayed postOp a no-op.

    function test_CrossPath_BurnSucceeds_SecondPostOpIdempotent() public {
        IxPNTsV2Admin(address(xpnts)).mint(user1, 1_000 ether);
        bytes memory ctx = _runValidate();

        // First postOp: settlement burns
        _postOp(ctx, MAX_COST);
        uint256 balAfterFirst = xpnts.balanceOf(user1);
        uint256 revAfterFirst = paymaster.protocolRevenue();
        assertEq(xpnts.debts(user1), 0, "No debt on first call");

        // Second postOp (same ctx/opHash): SP-level _settledDebtOps returns early
        _postOp(ctx, MAX_COST);
        assertEq(xpnts.balanceOf(user1), balAfterFirst, "Burn must not repeat on replay");
        assertEq(xpnts.debts(user1), 0, "Debt must stay 0 on replay");
        assertEq(paymaster.protocolRevenue(), revAfterFirst, "revenue must not repeat on replay");
    }

    // ── Test 8: Cross-path — debt recorded, same opHash would double-charge ──
    // P1-17: after a CREDIT settlement, a second postOp must not record debt or burn again.

    function test_CrossPath_DebtRecorded_SecondPostOpIdempotent() public {
        _enableAutoCredit(1000 ether);
        bytes memory ctx = _runValidate();
        assertEq(_mode(ctx), MODE_CREDIT);

        _postOp(ctx, MAX_COST);
        uint256 debt1 = xpnts.debts(user1);
        assertGt(debt1, 0, "First call must record debt");

        // Now give user balance — second postOp must still be a no-op.
        // (v2 mint auto-repays outstanding debt first, so snapshot AFTER the mint.)
        IxPNTsV2Admin(address(xpnts)).mint(user1, 1_000 ether);
        uint256 bal = xpnts.balanceOf(user1);
        uint256 debtAfterMint = xpnts.debts(user1);
        assertEq(debtAfterMint, 0, "mint auto-repaid the credit debt");
        uint256 revAfterFirst = paymaster.protocolRevenue();

        _postOp(ctx, MAX_COST);
        // SP-level guard fires — no burn, no additional debt, no extra revenue
        assertEq(xpnts.balanceOf(user1), bal, "Must not burn on replay");
        assertEq(xpnts.debts(user1), debtAfterMint, "Debt must not grow on replay");
        assertEq(paymaster.protocolRevenue(), revAfterFirst, "revenue must not repeat on replay");
    }

    // ── Test 9: Operator accounting is idempotent across postOp replays ─────────
    // _settledDebtOps must guard ALL accounting (operator.aPNTsBalance, protocolRevenue), not
    // just the token settlement: a replay must not double-refund the operator.

    function test_OperatorAccounting_Idempotent_OnReplay() public {
        IxPNTsV2Admin(address(xpnts)).mint(user1, 1_000 ether);

        // Over-estimated validation (large maxCost) so the settlement refunds the operator.
        (bytes memory ctx, uint256 vd) = _validate(bytes32(uint256(5555)), 1e12);
        assertEq(uint160(vd), 0);
        uint128 balBefore = _opBalance(); // after the a0 in-flight debit

        // First postOp — actualGasCost much smaller → refund (a0 - c) flows to operator
        _postOp(ctx, MAX_COST);
        uint128 balAfterFirst = _opBalance();
        assertGt(balAfterFirst, balBefore, "first settlement must refund the operator");

        // Second postOp with identical ctx — must be a complete no-op
        _postOp(ctx, MAX_COST);
        assertEq(_opBalance(), balAfterFirst,
            "Operator aPNTsBalance must not change on postOp replay: no double refund");
    }
}
