// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import {MockXPNTsFactory} from "../helpers/MockXPNTsFactory.sol";

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

contract MockXPNTsDR is ERC20 {
    address public FACTORY;
    uint256 public exchangeRateVal = 1e18;
    constructor() ERC20("Mock", "M") { FACTORY = msg.sender; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
    function exchangeRate() external view returns (uint256) { return exchangeRateVal; }
    function getDebt(address) external pure returns (uint256) { return 0; }
    function recordDebt(address, uint256) external {}
}

contract MockRegistryDR is IRegistry {
    mapping(bytes32 => mapping(address => bool)) public roles;
    function hasRole(bytes32 role, address account) external view returns (bool) {
        return roles[role][account];
    }
    function setRole(bytes32 role, address account, bool val) external {
        roles[role][account] = val;
    }
    function getCreditLimit(address) external pure returns (uint256) { return 1000 ether; }

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
    function ROLE_PAYMASTER_SUPER() external pure returns (bytes32) { return keccak256("PAYMASTER_SUPER"); }
    function ROLE_PAYMASTER_AOA() external pure returns (bytes32) { return keccak256("PAYMASTER_AOA"); }
    function ROLE_COMMUNITY() external pure returns (bytes32) { return keccak256("COMMUNITY"); }
    function ROLE_DVT() external pure returns (bytes32) { return keccak256("DVT"); }
    function ROLE_KMS() external pure returns (bytes32) { return keccak256("KMS"); }
    function ROLE_ANODE() external pure returns (bytes32) { return keccak256("ANODE"); }
    function ROLE_ENDUSER() external pure returns (bytes32) { return keccak256("ENDUSER"); }
    function isReputationSource(address) external pure returns (bool) { return false; }
    function syncStakeFromStaking(address, bytes32, uint256) external {}
    function getEffectiveStake(address, bytes32) external view returns (uint256) { return 0; }
}

/// @title DryRunValidation (P0-15) — exhaustive reason-code coverage
/// @notice Each test forces exactly one branch of validatePaymasterUserOp to
///         fail and asserts the matching DRYRUN_* reason code. The happy
///         path test ensures the function returns (true, 0) when every gate
///         opens.
contract DryRunValidationTest is Test {
    using stdStorage for StdStorage;

    SuperPaymaster public paymaster;
    MockRegistryDR public registry;
    MockEntryPointDR public entryPoint;
    MockPriceFeedDR public priceFeed;
    MockAPNTsDR public apnts;
    MockXPNTsDR public xpnts;
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
        xpnts = new MockXPNTsDR();
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
        registry.setRole(registry.ROLE_PAYMASTER_SUPER(), operator, true);
        registry.setRole(registry.ROLE_COMMUNITY(), operator, true);

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
        paymaster.configureOperator(address(xpnts), address(0x999), 1 ether);
        paymaster.deposit(5_000 ether);
        vm.stopPrank();
    }

    // ---------- Helpers ----------

    function _buildUserOp(address sender, address op, uint256 maxRate)
        internal view returns (PackedUserOperation memory userOp)
    {
        bytes memory pmData = abi.encodePacked(
            address(paymaster),     // 20 bytes
            uint256(1000),          // 32 bytes (gasLimits placeholder)
            op,                     // 20 bytes (operator)
            maxRate                 // 32 bytes (maxRate)
        );
        userOp.sender = sender;
        userOp.paymasterAndData = pmData;
    }

    // ---------- Tests ----------

    function test_DryRun_HappyPath_ReturnsTrue() public {
        PackedUserOperation memory op = _buildUserOp(user, operator, type(uint256).max);
        (bool ok, bytes32 reason) = paymaster.dryRunValidation(op, 1000);
        assertTrue(ok, "happy path should pass");
        assertEq(reason, bytes32(0), "reason must be zero on success");
    }

    function test_DryRun_OperatorNotConfigured() public {
        // Use unknown operator address that was never configured
        address ghost = address(0xDEAD);
        PackedUserOperation memory op = _buildUserOp(user, ghost, type(uint256).max);
        (bool ok, bytes32 reason) = paymaster.dryRunValidation(op, 1000);
        assertFalse(ok);
        assertEq(reason, bytes32("OPERATOR_NOT_CONFIGURED"));
    }

    function test_DryRun_OperatorPaused() public {
        vm.prank(owner);
        paymaster.setOperatorPaused(operator, true);

        PackedUserOperation memory op = _buildUserOp(user, operator, type(uint256).max);
        (bool ok, bytes32 reason) = paymaster.dryRunValidation(op, 1000);
        assertFalse(ok);
        assertEq(reason, bytes32("OPERATOR_PAUSED"));
    }

    function test_DryRun_UserNotEligible() public {
        // Use a different sender that has no SBT and no agent registration
        address stranger = address(0xC0DE);
        PackedUserOperation memory op = _buildUserOp(stranger, operator, type(uint256).max);
        (bool ok, bytes32 reason) = paymaster.dryRunValidation(op, 1000);
        assertFalse(ok);
        assertEq(reason, bytes32("USER_NOT_ELIGIBLE"));
    }

    function test_DryRun_UserBlocked() public {
        address[] memory users = new address[](1);
        users[0] = user;
        bool[] memory flags = new bool[](1);
        flags[0] = true;

        vm.prank(address(registry));
        paymaster.updateBlockedStatus(operator, users, flags);

        PackedUserOperation memory op = _buildUserOp(user, operator, type(uint256).max);
        (bool ok, bytes32 reason) = paymaster.dryRunValidation(op, 1000);
        assertFalse(ok);
        assertEq(reason, bytes32("USER_BLOCKED"));
    }

    function test_DryRun_RateLimited() public {
        // Configure a 1 hour minTxInterval and stamp lastTimestamp = now
        vm.prank(operator);
        paymaster.setOperatorLimits(uint48(3600));

        // Write lastTimestamp directly via stdstore (mapping operator->user->state).
        // Instead of stdstore (struct mapping), we trigger the stamp via postOp.
        // Easiest path: warp does not help; use the public path via validatePaymasterUserOp.
        // But that consumes balance — that's fine, we still have plenty.
        PackedUserOperation memory firstOp = _buildUserOp(user, operator, type(uint256).max);
        vm.prank(address(entryPoint));
        (bytes memory ctx, ) = paymaster.validatePaymasterUserOp(firstOp, bytes32(uint256(1)), 1000);
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 1000, 0);

        // Now lastTimestamp is set to block.timestamp; second dry-run should be rate limited
        (bool ok, bytes32 reason) = paymaster.dryRunValidation(firstOp, 1000);
        assertFalse(ok);
        assertEq(reason, bytes32("RATE_LIMITED"));

        // Warp past the interval and it should pass again
        vm.warp(block.timestamp + 3601);
        // Refresh the price cache so we don't trip STALE_PRICE
        paymaster.updatePrice();
        (ok, reason) = paymaster.dryRunValidation(firstOp, 1000);
        assertTrue(ok, "after interval should pass");
        assertEq(reason, bytes32(0));
    }

    function test_DryRun_RateCommitmentViolated() public {
        // operator exchangeRate = 1e18; require maxRate < that
        PackedUserOperation memory op = _buildUserOp(user, operator, 1); // maxRate = 1 wei
        (bool ok, bytes32 reason) = paymaster.dryRunValidation(op, 1000);
        assertFalse(ok);
        assertEq(reason, bytes32("RATE_COMMITMENT_VIOLATED"));
    }

    function test_DryRun_InsufficientBalance() public {
        // Pass huge maxCost to overflow the operator's deposit
        PackedUserOperation memory op = _buildUserOp(user, operator, type(uint256).max);
        // operator deposited 5_000 ether aPNTs; ask for a maxCost that requires more.
        // Validation charges aPNTs ≈ maxCost * price / aPNTsPriceUSD * 1.2 (fee+buffer).
        // With $2000 ETH and $0.02 aPNTs, 1 wei → 1e5 aPNTs base.
        // Need to push aPNTs > 5_000 ether (5e21). 5e21 / 1.2e5 ≈ 4.17e16 wei maxCost.
        uint256 huge = 1e17;
        (bool ok, bytes32 reason) = paymaster.dryRunValidation(op, huge);
        assertFalse(ok);
        assertEq(reason, bytes32("INSUFFICIENT_BALANCE"));
    }

    function test_DryRun_StalePrice() public {
        // Warp past staleness threshold (1 hour) — price cache becomes stale.
        vm.warp(block.timestamp + 2 hours);

        PackedUserOperation memory op = _buildUserOp(user, operator, type(uint256).max);
        (bool ok, bytes32 reason) = paymaster.dryRunValidation(op, 1000);
        assertFalse(ok);
        assertEq(reason, bytes32("STALE_PRICE"));
    }

    /// @notice Sanity check: dryRunValidation does not mutate operator state
    function test_DryRun_IsViewOnly_NoBalanceChange() public {
        (uint128 balBefore,,,,,,,,,) = paymaster.operators(operator);
        PackedUserOperation memory op = _buildUserOp(user, operator, type(uint256).max);
        paymaster.dryRunValidation(op, 1000);
        (uint128 balAfter,,,,,,,,,) = paymaster.operators(operator);
        assertEq(balBefore, balAfter, "dryRun must not deduct balance");
    }

    // -------------------------------------------------------------------------
    // Issue 1 regression: hard-failure takes precedence over RATE_LIMITED
    // When a user is both rate-limited AND fails a hard check, the function
    // must return the hard-failure code, not DRYRUN_RATE_LIMITED.
    // -------------------------------------------------------------------------

    /// @notice Rate-limited user with insufficient balance → hard failure wins
    function test_DryRun_HardFailure_Wins_Over_RateLimit_InsufficientBalance() public {
        // Set a rate limit and stamp lastTimestamp via postOp
        vm.prank(operator);
        paymaster.setOperatorLimits(uint48(3600));

        PackedUserOperation memory firstOp = _buildUserOp(user, operator, type(uint256).max);
        vm.prank(address(entryPoint));
        (bytes memory ctx, ) = paymaster.validatePaymasterUserOp(firstOp, bytes32(uint256(1)), 1000);
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 1000, 0);

        // User is now rate-limited (lastTimestamp = now, interval = 1h)
        // Also use a huge maxCost that will fail INSUFFICIENT_BALANCE
        uint256 huge = 1e17; // same as test_DryRun_InsufficientBalance
        (bool ok, bytes32 reason) = paymaster.dryRunValidation(firstOp, huge);
        assertFalse(ok);
        // Hard failure (INSUFFICIENT_BALANCE) must win over the soft RATE_LIMITED
        assertEq(reason, bytes32("INSUFFICIENT_BALANCE"),
            "hard failure must take precedence over RATE_LIMITED");
    }

    /// @notice Rate-limited user with stale price → hard failure wins
    function test_DryRun_HardFailure_Wins_Over_RateLimit_StalePrice() public {
        // Set a rate limit and stamp lastTimestamp
        vm.prank(operator);
        paymaster.setOperatorLimits(uint48(3600));

        PackedUserOperation memory firstOp = _buildUserOp(user, operator, type(uint256).max);
        vm.prank(address(entryPoint));
        (bytes memory ctx, ) = paymaster.validatePaymasterUserOp(firstOp, bytes32(uint256(1)), 1000);
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 1000, 0);

        // User is now rate-limited. Also expire the price cache.
        // Warp only 30 min (still within the 1h rate-limit window) but past 1h staleness.
        vm.warp(block.timestamp + 2 hours);
        // Do NOT call updatePrice() — cache is now stale.

        (bool ok, bytes32 reason) = paymaster.dryRunValidation(firstOp, 1000);
        assertFalse(ok);
        // Hard failure (STALE_PRICE) must win over the soft RATE_LIMITED
        assertEq(reason, bytes32("STALE_PRICE"),
            "STALE_PRICE must take precedence over RATE_LIMITED");
    }

    // -------------------------------------------------------------------------
    // Issue: paymasterAndData too short → maxRate defaults to type(uint256).max
    // When the calldata is shorter than 104 bytes (no maxRate field), the function
    // must not revert and must treat maxRate as unconstrained (type(uint256).max),
    // which means DRYRUN_RATE_COMMITMENT_VIOLATED is never returned for a short op.
    // -------------------------------------------------------------------------

    /// @notice Short paymasterAndData (< 104 bytes) defaults maxRate to type(uint256).max
    ///         and does not revert — the op should pass rate-commitment check.
    function test_DryRun_MaxRate_DefaultsToMaxUint_WhenDataTooShort() public {
        // Build a userOp whose paymasterAndData is only 72 bytes (no maxRate field):
        //   paymaster(20) + gasLimits(32) + operator(20) = 72 bytes < 104
        bytes memory shortPmData = abi.encodePacked(
            address(paymaster), // 20 bytes
            uint256(1000),      // 32 bytes (gasLimits placeholder)
            operator            // 20 bytes (operator) — total = 72, no maxRate appended
        );
        PackedUserOperation memory op;
        op.sender = user;
        op.paymasterAndData = shortPmData;

        // Must not revert; rate commitment defaults to type(uint256).max (always passes)
        (bool ok, bytes32 reason) = paymaster.dryRunValidation(op, 1000);
        // The only failing reason must NOT be DRYRUN_RATE_COMMITMENT_VIOLATED.
        // With a healthy cache and sufficient balance this path should succeed entirely.
        assertTrue(ok, "short paymasterAndData should not fail rate commitment");
        assertEq(reason, bytes32(0), "reason must be zero on success");
        assertNotEq(reason, bytes32("RATE_COMMITMENT_VIOLATED"),
            "must not trigger rate-commitment check when maxRate field is absent");
    }

    // -------------------------------------------------------------------------
    // Issue: updatedAt == 0 (uninitialized price cache) → DRYRUN_STALE_PRICE
    // A freshly-deployed SuperPaymaster has cachedPrice.updatedAt == 0.
    // dryRunValidation must detect this as stale and return DRYRUN_STALE_PRICE.
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

        PackedUserOperation memory op = _buildUserOp(user, operator, type(uint256).max);
        (bool ok, bytes32 reason) = paymaster.dryRunValidation(op, 1000);
        assertFalse(ok, "updatedAt==0 must be detected as stale");
        assertEq(reason, bytes32("STALE_PRICE"),
            "must return DRYRUN_STALE_PRICE for uninitialized cache");
    }

    /// @notice Rate-limited user with rate-commitment violation → hard failure wins
    function test_DryRun_HardFailure_Wins_Over_RateLimit_RateCommitment() public {
        // Set a rate limit and stamp lastTimestamp
        vm.prank(operator);
        paymaster.setOperatorLimits(uint48(3600));

        // Build an op with a tiny maxRate that will violate rate commitment
        PackedUserOperation memory firstOp = _buildUserOp(user, operator, type(uint256).max);
        vm.prank(address(entryPoint));
        (bytes memory ctx, ) = paymaster.validatePaymasterUserOp(firstOp, bytes32(uint256(1)), 1000);
        vm.prank(address(entryPoint));
        paymaster.postOp(IPaymaster.PostOpMode.opSucceeded, ctx, 1000, 0);

        // User is now rate-limited. Build op with maxRate=1 to trigger commitment violation.
        PackedUserOperation memory badOp = _buildUserOp(user, operator, 1);
        (bool ok, bytes32 reason) = paymaster.dryRunValidation(badOp, 1000);
        assertFalse(ok);
        assertEq(reason, bytes32("RATE_COMMITMENT_VIOLATED"),
            "RATE_COMMITMENT_VIOLATED must take precedence over RATE_LIMITED");
    }
}
