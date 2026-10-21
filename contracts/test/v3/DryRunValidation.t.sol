// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;
import { SuperPaymasterAdminCalls } from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
using SuperPaymasterAdminCalls for SuperPaymaster; // D5b: extension functions on a SuperPaymaster reference

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import {SuperPaymasterLens} from "src/paymasters/superpaymaster/v3/SuperPaymasterLens.sol";
import "src/interfaces/v3/IRegistry.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import {MockXPNTsFactory} from "../helpers/MockXPNTsFactory.sol";
import {V2TokenDeployer, IxPNTsV2Admin} from "../helpers/V2TokenDeployer.sol";
import {xPNTsTokenV2} from "src/tokens/v2/xPNTsTokenV2.sol";
import {IxPNTsTokenV2} from "src/tokens/v2/IxPNTsTokenV2.sol";

// --- Mocks (mirror SuperPaymasterV3_Pricing.t.sol) ---

contract MockEntryPointDR is IEntryPoint {
    function depositTo(address) external payable {}
    function addStake(uint32) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable) external {}
    function getSenderAddress(bytes memory) external {}
    function handleOps(PackedUserOperation[] calldata, address payable) external {}
    function handleAggregatedOps(UserOpsPerAggregator[] calldata, address payable) external {}
    function getUserOpHash(PackedUserOperation calldata userOp) external pure returns (bytes32) {
        return keccak256(abi.encode(userOp));
    }
    function getNonce(address, uint192) external pure returns (uint256) { return 0; }
    function balanceOf(address) external pure returns (uint256) { return 0; }
    function getDepositInfo(address) external pure returns (DepositInfo memory info) {}
    function incrementNonce(uint192) external {}
    function delegateAndRevert(address, bytes calldata) external {}
    function withdrawTo(address payable, uint256) external {}
}

contract MockPriceFeedDR {
    int256 public price = 2000 * 1e8;
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
    function setPrice(int256 _p) external { price = _p; }
}

contract MockAPNTsDR is ERC20 {
    constructor() ERC20("aPNTs", "aPNTs") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MockRegistryDR is IRegistry {
    mapping(bytes32 => mapping(address => bool)) public roles;
    mapping(address => uint256) public creditLimit;
    function hasRole(bytes32 role, address account) external view returns (bool) {
        return roles[role][account];
    }
    function setRole(bytes32 role, address account, bool val) external {
        roles[role][account] = val;
    }
    function setCreditLimit(address user, uint256 v) external { creditLimit[user] = v; }
    /// @dev GLOBAL tier source for the v2 token (GlobalTierSource.tierOf).
    function getCreditLimit(address user) external view returns (uint256) { return creditLimit[user]; }

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
    function setBLSValidator(address) external {}
    function setCreditTier(uint256, uint256) external {}
    function getRoleConfig(bytes32) external view returns (IRegistry.RoleConfig memory) {}
    function getUserRoles(address) external view returns (bytes32[] memory) {}
    function getRoleMembers(bytes32) external view returns (address[] memory) {}
    function getRoleUserCount(bytes32) external pure returns (uint256) { return 0; }

    function version() external pure returns (string memory) { return "Mock"; }
    function isReputationSource(address) external pure returns (bool) { return false; }
    function syncStakeFromStaking(address, bytes32, uint256) external {}
    function getEffectiveStake(address, bytes32) external view returns (uint256) { return 0; }
}

/// @title DryRunValidation (P0-15) — exhaustive reason-code coverage, migrated to 5.5.0
/// @notice In SuperPaymaster 5.5.0 `dryRunValidation` moved out of SP into the stateless
///         `SuperPaymasterLens.dryRunValidation(sp, userOp, maxCost)` (spec §3.3 / F1). Each test
///         forces exactly one branch to fail and asserts the matching DRYRUN_* reason code; where
///         validation reports a SIG_FAILURE the test also checks the real `validatePaymasterUserOp`
///         agrees (D-layer consistency, spec §9).
contract DryRunValidationTest is Test {
    using stdStorage for StdStorage;

    SuperPaymaster public paymaster;
    SuperPaymasterLens public lens;
    MockRegistryDR public registry;
    MockEntryPointDR public entryPoint;
    MockPriceFeedDR public priceFeed;
    MockAPNTsDR public apnts;
    xPNTsTokenV2 public xpnts;
    MockXPNTsFactory public mockFactory;

    address public owner    = address(0x1);
    address public treasury = address(0x2);
    address public operator = address(0xA);
    address public user     = address(0xB);

    function setUp() public {
        vm.startPrank(owner);
        entryPoint = new MockEntryPointDR();
        priceFeed = new MockPriceFeedDR();
        apnts = new MockAPNTsDR();
        registry = new MockRegistryDR();

        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(registry)),
            address(priceFeed),
            owner,
            address(apnts),
            treasury,
            3600 // priceStalenessThreshold = 1 hour
        );

        // Initialize price cache (warp first so cachedPrice.updatedAt is fresh)
        vm.warp(block.timestamp + 2 hours);
        paymaster.updatePrice();

        // Grant roles to operator
        registry.setRole(keccak256("PAYMASTER_SUPER"), operator, true);
        registry.setRole(keccak256("COMMUNITY"), operator, true);
        vm.stopPrank();

        // xPNTs v2 token (this test contract is its FACTORY; `owner` is communityOwner)
        V2TokenDeployer.Stack memory st = V2TokenDeployer.deployStack(address(paymaster), address(registry));
        xpnts = V2TokenDeployer.newToken(st, owner, operator, address(paymaster), 1e18);
        IxPNTsV2Admin(address(xpnts)).mint(user, 1_000 ether);
        lens = new SuperPaymasterLens();

        vm.startPrank(owner);
        // Deploy mock factory and register operator token (P1-4 fix)
        mockFactory = new MockXPNTsFactory();
        paymaster.setXPNTsFactory(address(mockFactory));
        mockFactory.setToken(operator, address(xpnts));

        apnts.mint(operator, 10_000 ether);
        vm.stopPrank();

        // Mark user as SBT holder (must be called by registry per access check)
        vm.prank(address(registry));
        paymaster.updateSBTStatus(user, true);

        // Operator: configure + deposit
        vm.startPrank(operator);
        apnts.approve(address(paymaster), type(uint256).max);
        paymaster.configureOperator(address(xpnts), address(0x999));
        paymaster.deposit(5_000 ether);
        vm.stopPrank();
    }

    // ---------- Helpers ----------

    function _buildUserOp(address sender, address op, uint256 maxRate)
        internal view returns (PackedUserOperation memory userOp)
    {
        userOp.sender = sender;
        userOp.paymasterAndData = V2TokenDeployer.pmd(
            address(paymaster), uint128(0), uint128(200000), op, maxRate, address(xpnts), 0
        );
    }

    /// @dev D3-M: staticcall so a lens that REVERTS (instead of returning a reason) is a named failure.
    function _dry(PackedUserOperation memory op, uint256 maxCost) internal view returns (bool, bytes32) {
        (bool ok, bytes memory ret) =
            address(lens).staticcall(abi.encodeCall(lens.dryRunValidation, (address(paymaster), op, maxCost)));
        require(ok, "lens must return a reason code, never revert");
        return abi.decode(ret, (bool, bytes32));
    }

    /// @dev Real validation on a throw-away state fork; returns true iff it did NOT sigFail.
    function _validates(PackedUserOperation memory op, uint256 maxCost) internal returns (bool) {
        uint256 snap = vm.snapshot();
        vm.prank(address(entryPoint));
        // D3-M: low-level call so a validation that REVERTS (instead of failing closed with
        // sigFail) is reported by a named assertion rather than an anonymous EvmError.
        (bool ok, bytes memory ret) = address(paymaster).call(abi.encodeCall(
            paymaster.validatePaymasterUserOp, (op, keccak256(abi.encode("probe", op.sender, maxCost)), maxCost)
        ));
        vm.revertTo(snap);
        assertTrue(ok, "validatePaymasterUserOp must not revert (fail closed with sigFail)");
        (, uint256 vd) = abi.decode(ret, (bytes, uint256));
        return uint160(vd) == 0;
    }

    /// @dev Lens rejects with `expected` AND real validation sigFails (D-layer agreement).
    function _assertRejectAgrees(PackedUserOperation memory op, uint256 maxCost, bytes32 expected) internal {
        (bool ok, bytes32 reason) = _dry(op, maxCost);
        assertFalse(ok, "lens must reject");
        assertEq(reason, expected, "lens reason code");
        assertFalse(_validates(op, maxCost), "validatePaymasterUserOp must agree (sigFail)");
    }

    function _stampRateLimit() internal returns (PackedUserOperation memory firstOp) {
        vm.prank(operator);
        paymaster.setOperatorLimits(uint48(3600));
        firstOp = _buildUserOp(user, operator, type(uint256).max);
        vm.prank(address(entryPoint));
        (bytes memory ctx, ) = paymaster.validatePaymasterUserOp(firstOp, bytes32(uint256(1)), 1000);
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 1000, 0);
    }

    // ---------- Tests ----------

    function test_DryRun_HappyPath_ReturnsTrue() public {
        PackedUserOperation memory op = _buildUserOp(user, operator, type(uint256).max);
        (bool ok, bytes32 reason) = _dry(op, 1000);
        assertTrue(ok, "happy path should pass");
        assertEq(reason, bytes32(0), "reason must be zero on success");
        assertTrue(_validates(op, 1000), "validation agrees on the happy path");
    }

    function test_DryRun_OperatorNotConfigured() public {
        // Use unknown operator address that was never configured
        address ghost = address(0xDEAD);
        _assertRejectAgrees(_buildUserOp(user, ghost, type(uint256).max), 1000, bytes32("OPERATOR_NOT_CONFIGURED"));
    }

    function test_DryRun_OperatorPaused() public {
        vm.prank(owner);
        paymaster.setOperatorPaused(operator, true);
        _assertRejectAgrees(_buildUserOp(user, operator, type(uint256).max), 1000, bytes32("OPERATOR_PAUSED"));
    }

    function test_DryRun_UserNotEligible() public {
        // Use a different sender that has no SBT and no agent registration
        address stranger = address(0xC0DE);
        _assertRejectAgrees(_buildUserOp(stranger, operator, type(uint256).max), 1000, bytes32("USER_NOT_ELIGIBLE"));
    }

    function test_DryRun_UserBlocked() public {
        address[] memory users = new address[](1);
        users[0] = user;
        bool[] memory flags = new bool[](1);
        flags[0] = true;

        vm.prank(address(registry));
        paymaster.updateBlockedStatus(operator, users, flags);

        _assertRejectAgrees(_buildUserOp(user, operator, type(uint256).max), 1000, bytes32("USER_BLOCKED"));
    }

    function test_DryRun_RateLimited() public {
        // Stamp lastTimestamp through the real validate -> postOp path (5.5.0: escrow then settle)
        PackedUserOperation memory firstOp = _stampRateLimit();

        // Now lastTimestamp is set to block.timestamp; second dry-run should be rate limited
        (bool ok, bytes32 reason) = _dry(firstOp, 1000);
        assertFalse(ok, "rate-limited op must not dry-run OK");
        assertEq(reason, bytes32("RATE_LIMITED"), "reason: RATE_LIMITED");

        // Warp past the interval and it should pass again
        vm.warp(block.timestamp + 3601);
        // Refresh the price cache so we don't trip STALE_PRICE
        paymaster.updatePrice();
        (ok, reason) = _dry(firstOp, 1000);
        assertTrue(ok, "after interval should pass");
        assertEq(reason, bytes32(0), "after the interval: reason OK");
    }

    function test_DryRun_RateCommitmentViolated() public {
        // operator exchangeRate = 1e18; require maxRate < that
        _assertRejectAgrees(_buildUserOp(user, operator, 1), 1000, bytes32("RATE_COMMITMENT_VIOLATED"));
    }

    function test_DryRun_InsufficientBalance() public {
        // Pass huge maxCost to overflow the operator's deposit
        // operator deposited 5_000 ether aPNTs; ask for a maxCost that requires more.
        // Validation reserves aPNTs ≈ maxCost * price / aPNTsPriceUSD * 1.2 (fee+buffer).
        // With $2000 ETH and $0.02 aPNTs, 1 wei → 1e5 aPNTs base.
        // Need to push aPNTs > 5_000 ether (5e21). 5e21 / 1.2e5 ≈ 4.17e16 wei maxCost.
        uint256 huge = 1e17;
        _assertRejectAgrees(_buildUserOp(user, operator, type(uint256).max), huge, bytes32("INSUFFICIENT_BALANCE"));
    }

    /// @notice D3-M: `huge` above is 2.4x over the deposit, so it cannot tell whether the lens
    ///         mirrors the full a0 (fee + 10% validation buffer). Near the boundary it can:
    ///         maxCost 4.3e16 -> a0 = 5.16e21 > 5e21 deposit (1.1x would be 4.73e21 <= 5e21);
    ///         maxCost 4.1e16 -> a0 = 4.92e21 <= 5e21, so the balance gate must NOT be the reason.
    function test_DryRun_InsufficientBalance_BufferBoundary() public {
        PackedUserOperation memory op = _buildUserOp(user, operator, type(uint256).max);
        _assertRejectAgrees(op, 4.3e16, bytes32("INSUFFICIENT_BALANCE"));
        (, bytes32 reason) = _dry(op, 4.1e16);
        assertTrue(reason != bytes32("INSUFFICIENT_BALANCE"), "control: a0 = 4.92e21 fits the 5e21 deposit");
    }

    function test_DryRun_StalePrice() public {
        // Warp past staleness threshold (1 hour) — price cache becomes stale.
        vm.warp(block.timestamp + 2 hours);

        PackedUserOperation memory op = _buildUserOp(user, operator, type(uint256).max);
        (bool ok, bytes32 reason) = _dry(op, 1000);
        assertFalse(ok, "stale cache must not dry-run OK");
        assertEq(reason, bytes32("STALE_PRICE"), "reason: STALE_PRICE");
    }

    /// @notice Sanity check: the lens does not mutate operator or token state
    function test_DryRun_IsViewOnly_NoBalanceChange() public {
        (uint128 balBefore,,,,,,,,) = paymaster.operators(operator);
        uint256 lockedBefore = xpnts.lockedOf(user);
        PackedUserOperation memory op = _buildUserOp(user, operator, type(uint256).max);
        _dry(op, 1000);
        (uint128 balAfter,,,,,,,,) = paymaster.operators(operator);
        assertEq(balBefore, balAfter, "dryRun must not deduct balance");
        assertEq(xpnts.lockedOf(user), lockedBefore, "dryRun must not lock the user's xPNTs");
        assertEq(xpnts.creditReservedOf(user), 0, "dryRun must not reserve credit");
    }

    /// @notice 5.5.0: SP no longer exposes dryRunValidation (moved to the lens for EIP-170).
    function test_DryRun_RemovedFromSuperPaymaster() public {
        PackedUserOperation memory op = _buildUserOp(user, operator, type(uint256).max);
        (bool success, ) = address(paymaster).call(
            abi.encodeWithSignature("dryRunValidation((address,uint256,bytes,bytes,bytes32,uint256,bytes32,bytes,bytes),uint256)", op, 1000)
        );
        assertFalse(success, "SP 5.5.0 has no dryRunValidation selector");
    }

    // -------------------------------------------------------------------------
    // Issue 1 regression: hard-failure takes precedence over RATE_LIMITED
    // When a user is both rate-limited AND fails a hard check, the function
    // must return the hard-failure code, not DRYRUN_RATE_LIMITED.
    // -------------------------------------------------------------------------

    /// @notice Rate-limited user with insufficient balance → hard failure wins
    function test_DryRun_HardFailure_Wins_Over_RateLimit_InsufficientBalance() public {
        PackedUserOperation memory firstOp = _stampRateLimit();

        // User is now rate-limited (lastTimestamp = now, interval = 1h)
        // Also use a huge maxCost that will fail INSUFFICIENT_BALANCE
        uint256 huge = 1e17; // same as test_DryRun_InsufficientBalance
        (bool ok, bytes32 reason) = _dry(firstOp, huge);
        assertFalse(ok, "hard failure: not OK");
        // Hard failure (INSUFFICIENT_BALANCE) must win over the soft RATE_LIMITED
        assertEq(reason, bytes32("INSUFFICIENT_BALANCE"),
            "hard failure must take precedence over RATE_LIMITED");
    }

    /// @notice Rate-limited user with stale price → hard failure wins
    function test_DryRun_HardFailure_Wins_Over_RateLimit_StalePrice() public {
        PackedUserOperation memory firstOp = _stampRateLimit();

        // User is now rate-limited. Also expire the price cache (past the 1h staleness).
        vm.warp(block.timestamp + 2 hours);
        // Do NOT call updatePrice() — cache is now stale.

        (bool ok, bytes32 reason) = _dry(firstOp, 1000);
        assertFalse(ok, "hard failure: not OK");
        // Hard failure (STALE_PRICE) must win over the soft RATE_LIMITED
        assertEq(reason, bytes32("STALE_PRICE"),
            "STALE_PRICE must take precedence over RATE_LIMITED");
    }

    // -------------------------------------------------------------------------
    // 5.5.0 BEHAVIOUR CHANGE (R4-H1): the token field is REQUIRED.
    // Legacy: paymasterAndData shorter than 104 bytes (no maxRate) defaulted maxRate to
    // type(uint256).max and passed. In 5.5.0 the layout is
    //   [pm 20][verif 16][postOp 16][operator 20][maxRate 32][token 20][flags 1]
    // and anything without the signed token field is rejected by validation, so the lens
    // must report TOKEN_MISMATCH (never RATE_COMMITMENT_VIOLATED, never OK) and must not revert.
    // -------------------------------------------------------------------------

    function test_DryRun_ShortPaymasterData_RejectedAsTokenMismatch() public {
        // 72 bytes: paymaster(20) + gasLimits(32) + operator(20) — no maxRate, no token
        bytes memory shortPmData = abi.encodePacked(address(paymaster), uint128(0), uint128(200000), operator);
        PackedUserOperation memory op;
        op.sender = user;
        op.paymasterAndData = shortPmData;

        (bool ok, bytes32 reason) = _dry(op, 1000);
        assertFalse(ok, "short paymasterAndData cannot be sponsored in 5.5.0");
        assertEq(reason, bytes32("TOKEN_MISMATCH"), "missing token field -> TOKEN_MISMATCH");
        assertNotEq(reason, bytes32("RATE_COMMITMENT_VIOLATED"),
            "must not trigger rate-commitment check when maxRate field is absent");
        assertFalse(_validates(op, 1000), "validation agrees (sigFail)");

        // 104 bytes (maxRate present, token absent) — the legacy full layout — is rejected too
        op.paymasterAndData = abi.encodePacked(address(paymaster), uint128(0), uint128(200000), operator, type(uint256).max);
        _assertRejectAgrees(op, 1000, bytes32("TOKEN_MISMATCH"));
    }

    // -------------------------------------------------------------------------
    // Issue: updatedAt == 0 (uninitialized price cache) → DRYRUN_STALE_PRICE
    // -------------------------------------------------------------------------

    /// @notice Uninitialized price cache (updatedAt == 0) triggers DRYRUN_STALE_PRICE
    function test_DryRun_StalePrice_WhenUpdatedAtZero() public {
        // Reset the price cache to an uninitialized state by writing updatedAt = 0
        // directly via stdstore.  PriceCache is a public struct; we target the
        // storage slot of the `updatedAt` field.
        stdstore
            .target(address(paymaster))
            .sig("cachedPrice()")
            .depth(1)           // PriceCache { price, updatedAt } — depth 1 = updatedAt
            .checked_write(uint256(0));
        // D3-M: at the setUp timestamp, `block.timestamp > 0 + threshold` is ALSO true, which would
        // mask the explicit updatedAt == 0 clause. Rewind to t = 100 (< threshold) so only that
        // clause can report STALE_PRICE.
        vm.warp(100);
        assertLt(block.timestamp, paymaster.priceStalenessThreshold(), "time clause alone would not fire");

        PackedUserOperation memory op = _buildUserOp(user, operator, type(uint256).max);
        (bool ok, bytes32 reason) = _dry(op, 1000);
        assertFalse(ok, "updatedAt==0 must be detected as stale");
        assertEq(reason, bytes32("STALE_PRICE"),
            "must return DRYRUN_STALE_PRICE for uninitialized cache");
    }

    /// @notice Rate-limited user with rate-commitment violation → hard failure wins
    function test_DryRun_HardFailure_Wins_Over_RateLimit_RateCommitment() public {
        _stampRateLimit();

        // User is now rate-limited. Build op with maxRate=1 to trigger commitment violation.
        PackedUserOperation memory badOp = _buildUserOp(user, operator, 1);
        (bool ok, bytes32 reason) = _dry(badOp, 1000);
        assertFalse(ok, "hard failure: not OK");
        assertEq(reason, bytes32("RATE_COMMITMENT_VIOLATED"),
            "RATE_COMMITMENT_VIOLATED must take precedence over RATE_LIMITED");
    }

    // -------------------------------------------------------------------------
    // 5.5.0 reason codes (new branches of validatePaymasterUserOp)
    // -------------------------------------------------------------------------

    function test_DryRun_VersionMismatch() public {
        vm.mockCall(address(paymaster), abi.encodeWithSignature("version()"), abi.encode("SuperPaymaster-5.4.2"));
        (bool ok, bytes32 reason) = _dry(_buildUserOp(user, operator, type(uint256).max), 1000);
        assertFalse(ok, "other SP version: not OK");
        assertEq(reason, lens.DRYRUN_VERSION_MISMATCH(), "lens refuses to guess for another SP version");
    }

    function test_DryRun_PostOpGasTooLow() public {
        PackedUserOperation memory op = _buildUserOp(user, operator, type(uint256).max);
        op.paymasterAndData = V2TokenDeployer.pmd(address(paymaster), 0, uint128(200_000 - 1), operator, type(uint256).max, address(xpnts), 0);
        _assertRejectAgrees(op, 1000, bytes32("POSTOP_GAS_TOO_LOW"));
    }

    function test_DryRun_TokenMismatch_WrongToken() public {
        PackedUserOperation memory op = _buildUserOp(user, operator, type(uint256).max);

        // D3-M: first a REAL v2 token of another community, bound to this SP and funded for the
        // user, so the binding check is the only thing that can reject it — without the check
        // validation would ADMIT it (0xBAD below has no code, so an unbound validation would only
        // revert, which is weaker evidence).
        V2TokenDeployer.Stack memory st2 = V2TokenDeployer.deployStack(address(paymaster), address(registry));
        xPNTsTokenV2 foreign = V2TokenDeployer.newToken(st2, address(0xF0F0), address(0xF0F0), address(paymaster), 1e18);
        IxPNTsV2Admin(address(foreign)).mint(user, 1_000 ether);
        op.paymasterAndData = V2TokenDeployer.pmd(address(paymaster), 0, 200_000, operator, type(uint256).max, address(foreign), 0);
        _assertRejectAgrees(op, 1000, bytes32("TOKEN_MISMATCH"));

        op.paymasterAndData = V2TokenDeployer.pmd(address(paymaster), 0, 200_000, operator, type(uint256).max, address(0xBAD), 0);
        _assertRejectAgrees(op, 1000, bytes32("TOKEN_MISMATCH"));
    }

    function test_DryRun_BothRenewFlags_Rejected() public {
        PackedUserOperation memory op = _buildUserOp(user, operator, type(uint256).max);
        op.paymasterAndData = V2TokenDeployer.pmd(address(paymaster), 0, 200_000, operator, type(uint256).max, address(xpnts), 3);
        _assertRejectAgrees(op, 1000, bytes32("TOKEN_MISMATCH"));
    }

    /// @notice User disabled the SP (D-19) → LOCK_REJECTED with LockResult.DISABLED in the low byte.
    function test_DryRun_LockRejected_Disabled() public {
        vm.prank(user);
        IxPNTsV2Admin(address(xpnts)).disableSpenderForSelf(address(paymaster));
        bytes32 expected = lens.DRYRUN_LOCK_REJECTED() | bytes32(uint256(uint8(IxPNTsTokenV2.LockResult.DISABLED)));
        _assertRejectAgrees(_buildUserOp(user, operator, type(uint256).max), 1000, expected);
    }

    /// @notice a0 above the token's maxSingleTxLimit → LOCK_REJECTED | SINGLE_TX_LIMIT (never credit).
    function test_DryRun_LockRejected_SingleTxLimit() public {
        vm.prank(owner); // communityOwner
        IxPNTsV2Admin(address(xpnts)).setMaxSingleTxLimit(1);
        bytes32 expected = lens.DRYRUN_LOCK_REJECTED() | bytes32(uint256(uint8(IxPNTsTokenV2.LockResult.SINGLE_TX_LIMIT)));
        _assertRejectAgrees(_buildUserOp(user, operator, type(uint256).max), 1000, expected);
    }

    /// @notice Empty balance + credit OFF (v2 default) → CREDIT_REJECTED | NO_CREDIT.
    function test_DryRun_CreditRejected_NoCredit() public {
        address poor = address(0xB0B);
        vm.prank(address(registry));
        paymaster.updateSBTStatus(poor, true);
        bytes32 expected = lens.DRYRUN_CREDIT_REJECTED() | bytes32(uint256(uint8(IxPNTsTokenV2.CreditResult.NO_CREDIT)));
        _assertRejectAgrees(_buildUserOp(poor, operator, type(uint256).max), 1000, expected);
    }

    /// @notice Empty balance + AUTO credit + request + tier → lens OK and validation admits on credit.
    function test_DryRun_CreditPath_OK() public {
        address poor = address(0xB0B);
        vm.prank(address(registry));
        paymaster.updateSBTStatus(poor, true);
        registry.setCreditLimit(poor, 1_000 ether);
        vm.prank(owner);
        IxPNTsV2Admin(address(xpnts)).queueCreditPolicy(2);
        vm.warp(block.timestamp + 48 hours);
        IxPNTsV2Admin(address(xpnts)).executeCreditPolicy();
        paymaster.updatePrice();
        vm.prank(poor);
        IxPNTsV2Admin(address(xpnts)).requestCredit(1_000 ether);

        PackedUserOperation memory op = _buildUserOp(poor, operator, type(uint256).max);
        (bool ok, bytes32 reason) = _dry(op, 1000);
        assertTrue(ok, "credit path sponsorable");
        assertEq(reason, bytes32(0), "credit path: reason OK");
        assertTrue(_validates(op, 1000), "validation agrees (CREDIT)");
    }
}
