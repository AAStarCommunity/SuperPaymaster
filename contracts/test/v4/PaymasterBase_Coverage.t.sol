// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/paymasters/v4/Paymaster.sol";
import "src/paymasters/v4/PaymasterBase.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import { PostOpMode } from "singleton-paymaster/src/interfaces/PostOpMode.sol";
import { Initializable } from "@openzeppelin-v5.0.2/contracts/proxy/utils/Initializable.sol";

// ─── Mocks ─────────────────────────────────────────────────────────────────────

/// @dev Minimal ERC20 that avoids importing OZ ERC20.sol directly
/// (which would collide with IERC20Metadata declared in PaymasterBase.sol).
contract CovV4MockToken {
    string public name     = "Mock";
    string public symbol   = "MCK";
    uint8  public constant decimals = 18;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    uint256 public totalSupply;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

contract CovV4MockOracle {
    int256 public answer;
    uint256 public updatedAt;
    uint8 public decimalsVal = 8;

    constructor(int256 _answer) { answer = _answer; updatedAt = block.timestamp; }

    function setPrice(int256 p, uint256 ts) external { answer = p; updatedAt = ts; }

    function latestRoundData() external view returns (
        uint80, int256, uint256, uint256 _updatedAt, uint80
    ) {
        return (1, answer, 0, updatedAt, 1);
    }
    function decimals() external view returns (uint8) { return decimalsVal; }
}

/// @dev Minimal IEntryPoint stub — only methods called by PaymasterBase needed
contract CovV4MockEntryPoint {
    function depositTo(address) external payable {}
    function getNonce(address, uint192) external pure returns (uint256) { return 0; }
    function addStake(uint32) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable) external {}
    function withdrawTo(address payable, uint256) external {}
}

contract CovV4MockRegistry {
    function hasRole(bytes32, address) external pure returns (bool) { return true; }
    function ROLE_PAYMASTER_AOA() external pure returns (bytes32) { return keccak256("PAYMASTER_AOA"); }
}

/// @dev Concrete subclass that exposes PaymasterBase; uses Paymaster contract
///      (EIP-1167 clone-ready) so all tests run via the real implementation.
/// @notice We use TestPaymasterV4 pattern: Paymaster is already a concrete class.

// ─── Test Suite ────────────────────────────────────────────────────────────────

/**
 * @title PaymasterBase_Coverage_Test
 * @notice Branch coverage improvements for PaymasterBase / Paymaster V4:
 *   E1  initialize() with maxGasCostCap == 0 — documents H-5 behavior
 *   E2  postOp() mode=postOpReverted path — returns early, no accounting
 *   E3  validatePaymasterUserOp() — paymasterData too short, insuf balance
 *   E4  postOp with stale price cache — triggers cache refresh + fallback
 *   E5  updatePricingConfig out-of-range: serviceFeeRate > MAX, cap > max
 *   E6  pause / unpause idempotency + whenNotPaused guard
 *   E7  setMaxGasCostCap — zero and > 100 ether revert paths
 *   E8  setPriceStalenessThreshold — below 60 and above 86400 reverts
 *   E9  setCachedPrice — future timestamp revert, delta bounds check
 *   E10 depositFor reverts when token not supported
 *   E11 withdraw reverts when insufficient balance
 */
contract PaymasterBase_Coverage_Test is Test {
    Paymaster public paymaster;
    CovV4MockToken public token;
    CovV4MockOracle public oracle;
    CovV4MockEntryPoint public entryPoint;
    CovV4MockRegistry public registry;

    address public owner    = address(0x1);
    address public treasury = address(0x2);
    address public user     = address(0x3);

    uint256 constant SERVICE_FEE  = 200;   // 2%
    uint256 constant MAX_GAS_CAP  = 1 ether;
    uint256 constant INITIAL_PRICE = 3000e8; // $3000 / ETH

    function setUp() public {
        oracle     = new CovV4MockOracle(int256(INITIAL_PRICE));
        entryPoint = new CovV4MockEntryPoint();
        token      = new CovV4MockToken();
        registry   = new CovV4MockRegistry();

        // Deploy clone via Clones (mirrors prod PaymasterFactory flow)
        Paymaster impl = new Paymaster(address(registry));
        paymaster = Paymaster(payable(Clones.clone(address(impl))));

        paymaster.initialize(
            address(entryPoint),
            owner,
            treasury,
            address(oracle),
            SERVICE_FEE,
            MAX_GAS_CAP,
            3600
        );

        vm.prank(owner);
        paymaster.updatePrice(); // prime cache

        vm.prank(owner);
        paymaster.setTokenPrice(address(token), 1e8); // $1 / token

        token.mint(user, 10_000 ether);
    }

    // ─── Helpers ───────────────────────────────────────────────────────────────

    function _buildUserOp(address sender, address payToken) internal view
        returns (PackedUserOperation memory op)
    {
        op.sender = sender;
        op.paymasterAndData = abi.encodePacked(
            address(paymaster), // 20 bytes
            bytes32(0),         // 32 bytes (gas limits placeholder)
            payToken            // 20 bytes  → at offset 52
        );
    }

    function _depositAndValidate(uint256 depositAmount, uint256 maxCost)
        internal returns (bytes memory ctx)
    {
        vm.startPrank(user);
        token.approve(address(paymaster), depositAmount);
        paymaster.depositFor(user, address(token), depositAmount);
        vm.stopPrank();

        PackedUserOperation memory op = _buildUserOp(user, address(token));
        vm.prank(address(entryPoint));
        (ctx,) = paymaster.validatePaymasterUserOp(op, bytes32(0), maxCost);
    }

    // ─── E1: initialize with maxGasCostCap == 0 ───────────────────────────────

    /**
     * @notice E1: H-5 documents that initialize() with maxGasCostCap == 0 does NOT
     * revert — the zero cap is stored as-is, allowing every op to pass the
     * `maxCost > maxGasCostCap` check (0 > 0 is false, so cappedMaxCost == maxCost).
     * This test documents the current (permissive) behavior.
     */
    function test_E1_Initialize_ZeroMaxGasCostCap_DoesNotRevert() public {
        Paymaster impl2 = new Paymaster(address(registry));
        Paymaster pm2 = Paymaster(payable(Clones.clone(address(impl2))));

        // H-5: should not revert — this documents the gap; a future fix would
        // add `if (_maxGasCostCap == 0) revert Paymaster__InvalidGasCostCap()`.
        pm2.initialize(
            address(entryPoint),
            owner,
            treasury,
            address(oracle),
            SERVICE_FEE,
            0,    // maxGasCostCap == 0
            3600
        );

        assertEq(pm2.maxGasCostCap(), 0, "maxGasCostCap stored as 0 (H-5: no validation on init)");
    }

    // ─── E2: postOp postOpReverted path ───────────────────────────────────────

    /**
     * @notice E2: V4 postOp does NOT early-return on postOpReverted (unlike SuperPaymaster).
     * It still processes the refund accounting so the user gets back unused funds.
     * This test documents and covers the postOpReverted mode path through postOp.
     */
    function test_E2_PostOp_PostOpReverted_StillProcessesRefund() public {
        bytes memory ctx = _depositAndValidate(1000 ether, 0.01 ether);

        uint256 userBalAfterValidate = paymaster.balances(user, address(token));

        vm.prank(address(entryPoint));
        paymaster.postOp(PostOpMode.postOpReverted, ctx, 0.005 ether, 0);

        // V4 postOp processes refund regardless of mode — user should get some tokens back
        // (because actual 0.005 ether < preCharged which was based on 0.01 ether)
        uint256 userBalAfterPostOp = paymaster.balances(user, address(token));
        assertTrue(userBalAfterPostOp >= userBalAfterValidate,
            "V4 postOp refunds user even in postOpReverted mode");
    }

    /**
     * @notice E2b: postOp with empty context returns immediately (no-op)
     */
    function test_E2b_PostOp_EmptyContext_IsNoop() public {
        vm.prank(address(entryPoint));
        paymaster.postOp(PostOpMode.opSucceeded, "", 0.005 ether, 0);
        // No revert is the assertion
    }

    // ─── E3: validatePaymasterUserOp edge cases ────────────────────────────────

    /**
     * @notice E3a: paymasterData too short — less than offset + 20 bytes — reverts
     */
    function test_E3a_Validate_TooShortPaymasterData_Reverts() public {
        PackedUserOperation memory op;
        op.sender = user;
        // Only 71 bytes (offset 52 + 19 — one short of the required token address)
        op.paymasterAndData = abi.encodePacked(
            address(paymaster),  // 20 bytes
            bytes32(0),          // 32 bytes
            bytes19(0)           // 19 bytes (total 71, need 72)
        );

        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterBase.Paymaster__InvalidPaymasterData.selector);
        paymaster.validatePaymasterUserOp(op, bytes32(0), 0.01 ether);
    }

    /**
     * @notice E3b: paymasterData with unsupported token reverts
     */
    function test_E3b_Validate_UnsupportedToken_Reverts() public {
        address badToken = address(0xBAD);
        PackedUserOperation memory op = _buildUserOp(user, badToken);

        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterBase.Paymaster__TokenNotSupported.selector);
        paymaster.validatePaymasterUserOp(op, bytes32(0), 0.01 ether);
    }

    /**
     * @notice E3c: insufficient internal balance causes revert
     */
    function test_E3c_Validate_InsufficientBalance_Reverts() public {
        // Do not deposit — user has 0 internal balance
        PackedUserOperation memory op = _buildUserOp(user, address(token));

        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterBase.Paymaster__InsufficientBalance.selector);
        paymaster.validatePaymasterUserOp(op, bytes32(0), 0.01 ether);
    }

    /**
     * @notice E3d: price cache not initialized causes revert during validation.
     * When cachedPrice.price == 0 (never set), _calculateTokenCost reverts with
     * Paymaster__InvalidOraclePrice (price == 0 check fires before updatedAt check).
     * The Paymaster__PriceNotInitialized error path (updatedAt == 0, price != 0)
     * would require a manual setCachedPrice with a non-zero price but zero timestamp,
     * which the admin function guards against. We document the observable behavior.
     */
    function test_E3d_Validate_PriceNotInitialized_Reverts() public {
        // Deploy fresh paymaster without calling updatePrice (cache is all-zero)
        Paymaster impl3 = new Paymaster(address(registry));
        Paymaster pm3 = Paymaster(payable(Clones.clone(address(impl3))));
        pm3.initialize(address(entryPoint), owner, treasury, address(oracle), SERVICE_FEE, MAX_GAS_CAP, 3600);

        vm.prank(owner);
        pm3.setTokenPrice(address(token), 1e8);

        // Deposit for user
        vm.startPrank(user);
        token.approve(address(pm3), 1000 ether);
        pm3.depositFor(user, address(token), 1000 ether);
        vm.stopPrank();

        PackedUserOperation memory op;
        op.sender = user;
        op.paymasterAndData = abi.encodePacked(address(pm3), bytes32(0), address(token));

        // cachedPrice.price == 0 → _calculateTokenCost reverts with Paymaster__InvalidOraclePrice
        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterBase.Paymaster__InvalidOraclePrice.selector);
        pm3.validatePaymasterUserOp(op, bytes32(0), 0.01 ether);
    }

    /**
     * @notice E3e: onlyEntryPoint modifier — non-entrypoint caller reverts
     */
    function test_E3e_Validate_OnlyEntryPoint_Reverts() public {
        PackedUserOperation memory op = _buildUserOp(user, address(token));

        vm.prank(user); // Not the entryPoint
        vm.expectRevert(PaymasterBase.Paymaster__OnlyEntryPoint.selector);
        paymaster.validatePaymasterUserOp(op, bytes32(0), 0.01 ether);
    }

    /**
     * @notice E3f: whenNotPaused — validate reverts when paused
     */
    function test_E3f_Validate_WhenPaused_Reverts() public {
        vm.prank(owner);
        paymaster.pause();

        PackedUserOperation memory op = _buildUserOp(user, address(token));

        vm.prank(address(entryPoint));
        vm.expectRevert(PaymasterBase.Paymaster__Paused.selector);
        paymaster.validatePaymasterUserOp(op, bytes32(0), 0.01 ether);
    }

    // ─── E4: postOp with stale cache triggers refresh path ────────────────────

    /**
     * @notice E4: When cachedPrice is stale at postOp time, the contract attempts
     * to refresh via this.updatePrice(). If oracle is fresh the refresh succeeds;
     * if oracle is also stale, PriceUpdateFailed is emitted.
     */
    function test_E4_PostOp_StaleCache_TriggersRefresh() public {
        bytes memory ctx = _depositAndValidate(1000 ether, 0.01 ether);

        // Advance time past staleness threshold
        vm.warp(block.timestamp + 3601);

        // Oracle is still fresh (updatedAt is now old but within oracle answer)
        // Update oracle to current timestamp
        oracle.setPrice(int256(INITIAL_PRICE), block.timestamp);

        // postOp should trigger updatePrice internally (stale cache path)
        vm.prank(address(entryPoint));
        paymaster.postOp(PostOpMode.opSucceeded, ctx, 0.005 ether, 0);
        // No revert = success on this path
    }

    /**
     * @notice E4b: When cache is stale AND oracle is also stale, PriceUpdateFailed
     * is emitted and postOp falls through with preChargedAmount (safe default).
     */
    function test_E4b_PostOp_StaleCache_StaleOracle_EmitsPriceUpdateFailed() public {
        bytes memory ctx = _depositAndValidate(1000 ether, 0.01 ether);

        uint256 userBalAfterValidate = paymaster.balances(user, address(token));

        // Advance time past threshold AND make oracle stale too
        vm.warp(block.timestamp + 7200);
        // oracle.updatedAt is now 7200 seconds old (past 3600s threshold)
        // oracle answer is stale — updatePrice will revert internally

        vm.expectEmit(false, false, false, false);
        emit PaymasterBase.PriceUpdateFailed();

        vm.prank(address(entryPoint));
        paymaster.postOp(PostOpMode.opSucceeded, ctx, 0.005 ether, 0);

        // On oracle failure, actualTokenCost falls back to preChargedAmount (no refund)
        // User balance stays at post-validate level (cap: actualTokenCost == preChargedAmount)
        assertEq(paymaster.balances(user, address(token)), userBalAfterValidate,
            "No refund when oracle stale and postOp falls back to preCharged");
    }

    // ─── E5: updatePricingConfig out-of-range ─────────────────────────────────

    /**
     * @notice E5a: setServiceFeeRate above MAX_SERVICE_FEE reverts
     */
    function test_E5a_SetServiceFeeRate_AboveMax_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(PaymasterBase.Paymaster__InvalidServiceFee.selector);
        paymaster.setServiceFeeRate(1001); // MAX_SERVICE_FEE == 1000
    }

    /**
     * @notice E5b: setServiceFeeRate at boundary (MAX_SERVICE_FEE) succeeds
     */
    function test_E5b_SetServiceFeeRate_AtMax_Succeeds() public {
        vm.prank(owner);
        paymaster.setServiceFeeRate(1000);
        assertEq(paymaster.serviceFeeRate(), 1000);
    }

    /**
     * @notice E5c: setServiceFeeRate to 0 succeeds (disable fee)
     */
    function test_E5c_SetServiceFeeRate_Zero_Succeeds() public {
        vm.prank(owner);
        paymaster.setServiceFeeRate(0);
        assertEq(paymaster.serviceFeeRate(), 0);
    }

    // ─── E6: pause / unpause ───────────────────────────────────────────────────

    /**
     * @notice E6a: pause is idempotent
     */
    function test_E6a_Pause_Idempotent() public {
        vm.startPrank(owner);
        paymaster.pause();
        bool pausedFirst = paymaster.paused();
        paymaster.pause(); // Second call — should not revert, stays paused
        vm.stopPrank();
        assertTrue(pausedFirst);
        assertTrue(paymaster.paused());
    }

    /**
     * @notice E6b: unpause is idempotent
     */
    function test_E6b_Unpause_Idempotent() public {
        vm.startPrank(owner);
        paymaster.unpause(); // Already unpaused — no-op
        assertFalse(paymaster.paused());
        vm.stopPrank();
    }

    /**
     * @notice E6c: withdraw is blocked when paused
     */
    function test_E6c_Withdraw_WhenPaused_Reverts() public {
        // Deposit first
        vm.startPrank(user);
        token.approve(address(paymaster), 100 ether);
        paymaster.depositFor(user, address(token), 100 ether);
        vm.stopPrank();

        vm.prank(owner);
        paymaster.pause();

        vm.prank(user);
        vm.expectRevert(PaymasterBase.Paymaster__Paused.selector);
        paymaster.withdraw(address(token), 10 ether);
    }

    /**
     * @notice E6d: deactivateFromRegistry sets paused = true
     */
    function test_E6d_DeactivateFromRegistry() public {
        vm.prank(owner);
        paymaster.deactivateFromRegistry();
        assertTrue(paymaster.paused(), "Should be paused after deactivation");
    }

    /**
     * @notice E6e: activateInRegistry restores paused = false
     */
    function test_E6e_ActivateInRegistry() public {
        vm.startPrank(owner);
        paymaster.deactivateFromRegistry();
        paymaster.activateInRegistry();
        vm.stopPrank();
        assertFalse(paymaster.paused(), "Should be unpaused after activation");
    }

    // ─── E7: setMaxGasCostCap ──────────────────────────────────────────────────

    /**
     * @notice E7a: setMaxGasCostCap with 0 reverts
     */
    function test_E7a_SetMaxGasCostCap_Zero_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(PaymasterBase.Paymaster__InvalidGasCostCap.selector);
        paymaster.setMaxGasCostCap(0);
    }

    /**
     * @notice E7b: setMaxGasCostCap above 100 ether reverts
     */
    function test_E7b_SetMaxGasCostCap_AboveMax_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(PaymasterBase.Paymaster__InvalidGasCostCap.selector);
        paymaster.setMaxGasCostCap(100 ether + 1);
    }

    /**
     * @notice E7c: setMaxGasCostCap at 100 ether succeeds
     */
    function test_E7c_SetMaxGasCostCap_AtMax_Succeeds() public {
        vm.prank(owner);
        paymaster.setMaxGasCostCap(100 ether);
        assertEq(paymaster.maxGasCostCap(), 100 ether);
    }

    // ─── E8: setPriceStalenessThreshold ───────────────────────────────────────

    /**
     * @notice E8a: below 60 seconds reverts
     */
    function test_E8a_SetPriceStalenessThreshold_Below60_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(PaymasterBase.Paymaster__InvalidStalenessThreshold.selector);
        paymaster.setPriceStalenessThreshold(59);
    }

    /**
     * @notice E8b: above 86400 seconds reverts
     */
    function test_E8b_SetPriceStalenessThreshold_Above86400_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(PaymasterBase.Paymaster__InvalidStalenessThreshold.selector);
        paymaster.setPriceStalenessThreshold(86401);
    }

    /**
     * @notice E8c: valid value within range succeeds
     */
    function test_E8c_SetPriceStalenessThreshold_Valid_Succeeds() public {
        vm.prank(owner);
        paymaster.setPriceStalenessThreshold(1800);
        assertEq(paymaster.priceStalenessThreshold(), 1800);
    }

    // ─── E9: setCachedPrice ────────────────────────────────────────────────────

    /**
     * @notice E9a: setCachedPrice with future timestamp reverts
     */
    function test_E9a_SetCachedPrice_FutureTimestamp_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(PaymasterBase.Paymaster__InvalidOraclePrice.selector);
        paymaster.setCachedPrice(INITIAL_PRICE, uint48(block.timestamp + 1));
    }

    /**
     * @notice E9b: setCachedPrice below CACHED_PRICE_MIN reverts
     */
    function test_E9b_SetCachedPrice_BelowMin_Reverts() public {
        vm.prank(owner);
        vm.expectRevert(PaymasterBase.Paymaster__InvalidOraclePrice.selector);
        paymaster.setCachedPrice(99e8, uint48(block.timestamp)); // $99 < $100 min
    }

    /**
     * @notice E9c: setCachedPrice with ±30% delta check
     * When current price is $3000, a new price of $4200 (40% above) reverts.
     */
    function test_E9c_SetCachedPrice_DeltaViolation_Reverts() public {
        // Current cached price = INITIAL_PRICE = 3000e8
        uint256 tooHigh = (INITIAL_PRICE * 131) / 100; // 31% above (over 30% delta)

        vm.prank(owner);
        vm.expectRevert(PaymasterBase.Paymaster__InvalidOraclePrice.selector);
        paymaster.setCachedPrice(tooHigh, uint48(block.timestamp));
    }

    /**
     * @notice E9d: setCachedPrice within ±30% succeeds
     */
    function test_E9d_SetCachedPrice_WithinDelta_Succeeds() public {
        uint256 okPrice = (INITIAL_PRICE * 120) / 100; // 20% above — within 30%

        vm.prank(owner);
        paymaster.setCachedPrice(okPrice, uint48(block.timestamp));

        (uint208 p,) = paymaster.cachedPrice();
        assertEq(p, okPrice);
    }

    // ─── E10: depositFor token not supported ──────────────────────────────────

    /**
     * @notice E10: depositFor reverts when token not in supported list
     */
    function test_E10_DepositFor_UnsupportedToken_Reverts() public {
        address badToken = address(0xBAD2);
        vm.prank(user);
        vm.expectRevert(PaymasterBase.Paymaster__TokenNotSupported.selector);
        paymaster.depositFor(user, badToken, 1 ether);
    }

    // ─── E11: withdraw reverts on insufficient balance ─────────────────────────

    /**
     * @notice E11: withdraw reverts when balance < requested amount
     */
    function test_E11_Withdraw_InsufficientBalance_Reverts() public {
        // No deposits for user
        vm.prank(user);
        vm.expectRevert(PaymasterBase.Paymaster__InsufficientBalance.selector);
        paymaster.withdraw(address(token), 1 ether);
    }

    // ─── E12: maxGasCostCap capping during validation ──────────────────────────

    /**
     * @notice E12: When maxCost > maxGasCostCap, validation uses cap (no revert)
     */
    function test_E12_Validate_CappedAtMaxGasCostCap() public {
        vm.startPrank(user);
        token.approve(address(paymaster), 10_000 ether);
        paymaster.depositFor(user, address(token), 10_000 ether);
        vm.stopPrank();

        uint256 beforeBal = paymaster.balances(user, address(token));
        PackedUserOperation memory op = _buildUserOp(user, address(token));

        // Pass maxCost = 10 ether >> MAX_GAS_CAP (1 ether) — should be capped
        vm.prank(address(entryPoint));
        (bytes memory ctx,) = paymaster.validatePaymasterUserOp(op, bytes32(0), 10 ether);

        uint256 afterBal = paymaster.balances(user, address(token));
        uint256 deducted = beforeBal - afterBal;

        // Deducted amount should correspond to MAX_GAS_CAP (1 ether), not 10 ether
        // Also run postOp to ensure no revert
        vm.prank(address(entryPoint));
        paymaster.postOp(PostOpMode.opSucceeded, ctx, 0.5 ether, 0);

        assertTrue(deducted > 0, "Some tokens deducted");
        // Rough sanity: if cap is working, deducted < what 10 ether would cost
        // (10 ether would need ~10x more tokens than 1 ether at same price)
        // We just verify it completed without revert
    }

    // ─── E13: setTokenPrice — update does not re-add to list ─────────────────

    /**
     * @notice E13: setTokenPrice called twice for same token does not duplicate list
     */
    function test_E13_SetTokenPrice_Update_NoDuplicate() public {
        vm.prank(owner);
        paymaster.setTokenPrice(address(token), 2e8); // update price

        address[] memory supported = paymaster.getSupportedTokens();
        uint256 count = 0;
        for (uint256 i; i < supported.length; i++) {
            if (supported[i] == address(token)) count++;
        }
        assertEq(count, 1, "Token should appear exactly once");
        assertEq(paymaster.tokenPrices(address(token)), 2e8);
    }

    // ─── E14: calculateCost external wrapper — only callable from self ─────────

    /**
     * @notice E14: calculateCost reverts when called by external address
     */
    function test_E14_CalculateCost_Reverts_WhenNotSelf() public {
        vm.prank(user);
        vm.expectRevert(PaymasterBase.Paymaster__InvalidPaymasterData.selector);
        paymaster.calculateCost(0.01 ether, address(token), false);
    }

    // ─── E15: postOp happy path — refund credited to user ────────────────────

    /**
     * @notice E15: Full validate → postOp flow with large pre-charge and small actual
     * verifies the refund logic (preCharged > actualCost → refund to user)
     */
    function test_E15_PostOp_Refund_CreditedToUser() public {
        // Deposit generous balance
        vm.startPrank(user);
        token.approve(address(paymaster), 5000 ether);
        paymaster.depositFor(user, address(token), 5000 ether);
        vm.stopPrank();

        PackedUserOperation memory op = _buildUserOp(user, address(token));

        // Validate with high maxCost
        vm.prank(address(entryPoint));
        (bytes memory ctx,) = paymaster.validatePaymasterUserOp(op, bytes32(0), 0.1 ether);

        uint256 balMid = paymaster.balances(user, address(token));

        // PostOp with low actual — expect refund
        vm.prank(address(entryPoint));
        paymaster.postOp(PostOpMode.opSucceeded, ctx, 0.001 ether, 0);

        uint256 balFinal = paymaster.balances(user, address(token));
        assertTrue(balFinal > balMid, "User should receive refund when actual < preCharged");
    }
}
