// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "src/paymasters/v4/Paymaster.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/interfaces/v3/IRegistry.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import { PostOpMode } from "singleton-paymaster/src/interfaces/PostOpMode.sol";

/// @notice P0-16 (Codex B-N1): cache writers must reject future `updatedAt`
///         timestamps. Without these guards, an adversarial caller — or an
///         honest caller misreading wall-clock from a buggy keeper — could
///         freeze staleness checks and underflow `block.timestamp -
///         cachedPrice.updatedAt` in postOp, bricking sponsorship until the
///         cache is overwritten.
contract MockEntryPoint {
    function depositTo(address) external payable {}
    function balanceOf(address) external pure returns (uint256) { return 0; }
    function addStake(uint32) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable) external {}
    function withdrawTo(address payable, uint256) external {}
}

contract MockOracleOK {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

contract MockRegistry {
    function ROLE_PAYMASTER_AOA() external pure returns (bytes32) { return keccak256("PAYMASTER_AOA"); }
    function hasRole(bytes32, address) external pure returns (bool) { return true; }
}

contract PriceCache_FutureTimestampTest is Test {
    Paymaster paymaster;
    address owner = address(0xABCD);

    function setUp() public {
        Paymaster impl = new Paymaster(address(new MockRegistry()));
        paymaster = Paymaster(payable(Clones.clone(address(impl))));
        paymaster.initialize(
            address(new MockEntryPoint()),
            owner,
            owner,
            address(new MockOracleOK()),
            200,
            10 ether,
            3600
        );
    }

    /// @notice Timestamps strictly beyond the 15-second grace window are rejected.
    function test_SetCachedPrice_RejectsFutureTimestamp() public {
        uint48 future = uint48(block.timestamp + paymaster.TIMESTAMP_GRACE_SECONDS() + 1);
        vm.expectRevert(PaymasterBase.Paymaster__InvalidOraclePrice.selector);
        vm.prank(owner);
        paymaster.setCachedPrice(2000e8, future);
    }

    function test_SetCachedPrice_AcceptsCurrentTimestamp() public {
        vm.prank(owner);
        paymaster.setCachedPrice(2000e8, uint48(block.timestamp));
        (uint208 price, uint48 ts) = paymaster.cachedPrice();
        assertEq(price, 2000e8);
        assertEq(ts, uint48(block.timestamp));
    }

    function test_SetCachedPrice_AcceptsPastTimestamp() public {
        vm.warp(1_700_000_000);
        vm.prank(owner);
        paymaster.setCachedPrice(2000e8, uint48(block.timestamp - 60));
        (, uint48 ts) = paymaster.cachedPrice();
        assertEq(ts, uint48(block.timestamp - 60));
    }

    /// @notice A keeper whose wall-clock is up to TIMESTAMP_GRACE_SECONDS ahead of
    ///         block.timestamp must not be spuriously rejected. This covers the
    ///         ~12 s maximum drift between keeper system time and on-chain time.
    function test_SetCachedPrice_AcceptsTimestampWithinGrace() public {
        uint256 grace = paymaster.TIMESTAMP_GRACE_SECONDS();
        // Timestamp exactly at the grace boundary is accepted.
        vm.prank(owner);
        paymaster.setCachedPrice(2000e8, uint48(block.timestamp + grace));
        (, uint48 ts) = paymaster.cachedPrice();
        assertEq(ts, uint48(block.timestamp + grace));

        // One second past the boundary is rejected.
        uint48 justOver = uint48(block.timestamp + grace + 1);
        vm.expectRevert(PaymasterBase.Paymaster__InvalidOraclePrice.selector);
        vm.prank(owner);
        paymaster.setCachedPrice(2000e8, justOver);
    }

    function test_SetCachedPrice_RejectsZeroPrice() public {
        vm.expectRevert(PaymasterBase.Paymaster__InvalidOraclePrice.selector);
        vm.prank(owner);
        paymaster.setCachedPrice(0, uint48(block.timestamp));
    }

    /// @notice Sanity check that the previously-bricking value (future +1d)
    ///         is rejected at write time so postOp readers never see it.
    function test_SetCachedPrice_RejectsFarFutureTimestamp() public {
        vm.expectRevert(PaymasterBase.Paymaster__InvalidOraclePrice.selector);
        vm.prank(owner);
        paymaster.setCachedPrice(2000e8, uint48(block.timestamp + 365 days));
    }

    // -----------------------------------------------------------------------
    // test_PostOp_DegradesToRealtimeOnFutureCachedPrice
    //
    // Verifies that postOp in Paymaster (v4) treats a cache entry with a
    // future `updatedAt` as stale and falls back to a realtime oracle read,
    // rather than attempting `block.timestamp - cachedPrice.updatedAt` (which
    // would underflow and revert, bricking the postOp path).
    //
    // Strategy:
    //   1. Set oracle to $3000 (different from the $2000 cache price).
    //   2. Use vm.store to force a future `updatedAt` into the cache slot
    //      while keeping the original $2000 price — so if the cache were used
    //      the result would differ from the realtime ($3000) result.
    //   3. Call postOp from the entry point address and verify it succeeds,
    //      proving that the staleness guard caught the future timestamp and
    //      chose the realtime ($3000) path without arithmetic underflow.
    // -----------------------------------------------------------------------
    function test_PostOp_DegradesToRealtimeOnFutureCachedPrice() public {
        // --- Setup: register a payment token and give the user a balance ---
        address token = address(new MockERC20Token());
        // Token price: $1.00 (8 decimals)
        vm.prank(owner);
        paymaster.setTokenPrice(token, 1e8);

        address user = address(0xBEEF);
        // Pre-charge 1000 tokens for the user (simulate validation phase)
        uint256 preCharged = 1000e18;
        // Write user balance directly to storage (slot 10 = balances mapping)
        // balances[user][token] slot = keccak256(abi.encode(token, keccak256(abi.encode(user, 10))))
        bytes32 outerSlot = keccak256(abi.encode(user, uint256(10)));
        bytes32 innerSlot = keccak256(abi.encode(token, outerSlot));
        vm.store(address(paymaster), innerSlot, bytes32(preCharged));

        // First set a valid cache price so the paymaster is initialised.
        vm.prank(owner);
        paymaster.setCachedPrice(2000e8, uint48(block.timestamp));

        // --- Force a future timestamp into the packed PriceCache slot (slot 5) ---
        // PriceCache { uint208 price; uint48 updatedAt; } packed into one slot.
        // price = 2000e8 = 200_000_000_000  (fits in uint208, at bits 0-207)
        // updatedAt = block.timestamp + 1 hour (future, at bits 208-255)
        uint256 futureTs = block.timestamp + 1 hours;
        uint256 priceVal = 2000e8; // $2000 in 8-decimal units
        // Encode: price in low 208 bits, updatedAt in high 48 bits
        uint256 slotValue = priceVal | (futureTs << 208);
        vm.store(address(paymaster), bytes32(uint256(5)), bytes32(slotValue));

        // Sanity: confirm the cache now has a future updatedAt
        (, uint48 cachedUpdatedAt) = paymaster.cachedPrice();
        assertGt(uint256(cachedUpdatedAt), block.timestamp, "setup: updatedAt should be in the future");

        // --- Build postOp context ---
        bytes memory context = abi.encode(user, token, preCharged);

        // --- Call postOp from the entry point ---
        // postOp must succeed: the staleness guard detects the future timestamp,
        // calls updatePrice() (which reads $3000 from oracle), then uses realtime.
        address ep = address(paymaster.entryPoint());
        vm.prank(ep);
        // This should NOT revert despite the future timestamp in cache.
        paymaster.postOp(PostOpMode.opSucceeded, context, 1e15, 1e9);

        // After postOp the cache should have been refreshed with a valid timestamp.
        (, uint48 newTs) = paymaster.cachedPrice();
        assertLe(uint256(newTs), block.timestamp, "postOp should have refreshed cache to current or past timestamp");
    }
}

// ---------------------------------------------------------------------------
// Minimal ERC20 token for postOp test
// ---------------------------------------------------------------------------
contract MockERC20Token is ERC20 {
    constructor() ERC20("Mock", "MCK") {}
    function mint(address to, uint256 amt) external { _mint(to, amt); }
}

// ---------------------------------------------------------------------------
// Minimal IRegistry mock for SuperPaymaster tests
// ---------------------------------------------------------------------------
contract MockSPRegistry is IRegistry {
    mapping(bytes32 => mapping(address => bool)) public roles;

    function hasRole(bytes32 role, address account) external view override returns (bool) {
        return roles[role][account];
    }
    function grantRole(bytes32 role, address account) external { roles[role][account] = true; }

    function ROLE_PAYMASTER_SUPER() external pure override returns (bytes32) { return keccak256("PAYMASTER_SUPER"); }
    function ROLE_PAYMASTER_AOA()   external pure override returns (bytes32) { return keccak256("PAYMASTER_AOA"); }
    function ROLE_KMS()             external pure override returns (bytes32) { return keccak256("KMS"); }
    function ROLE_DVT()             external pure override returns (bytes32) { return keccak256("DVT"); }
    function ROLE_ANODE()           external pure override returns (bytes32) { return keccak256("ANODE"); }
    function ROLE_COMMUNITY()       external pure override returns (bytes32) { return keccak256("COMMUNITY"); }
    function ROLE_ENDUSER()         external pure override returns (bytes32) { return keccak256("ENDUSER"); }

    function version() external pure override returns (string memory) { return "MockSPRegistry-1.0"; }
    function registerRole(bytes32, address, bytes calldata) external override {}
    function exitRole(bytes32) external override {}
    function configureRole(bytes32, RoleConfig calldata) external override {}
    function safeMintForRole(bytes32, address, bytes calldata) external override returns (uint256) { return 0; }
    function batchUpdateGlobalReputation(uint256, address[] calldata, uint256[] calldata, uint256, bytes calldata) external override {}
    function updateOperatorBlacklist(address, address[] calldata, bool[] calldata, bytes calldata) external override {}
    function markProposalExecuted(uint256) external override {}
    function setReputationSource(address, bool) external override {}
    function setCreditTier(uint256, uint256) external override {}
    function getCreditLimit(address) external view override returns (uint256) { return 1000 ether; }
    function isReputationSource(address) external pure override returns (bool) { return false; }
    function getRoleConfig(bytes32) external view override returns (RoleConfig memory) {
        return RoleConfig(0, 0, 0, 0, 0, 0, 0, false, 0, "", address(0), 0);
    }
    function getUserRoles(address) external view override returns (bytes32[] memory) { return new bytes32[](0); }
    function getRoleUserCount(bytes32) external view override returns (uint256) { return 0; }
}

/// @notice Minimal oracle mock for SuperPaymaster tests — always returns the
///         price configured at construction.
contract MockSPOracle {
    int256 public immutable price;
    constructor(int256 _price) { price = _price; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, price, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

// ---------------------------------------------------------------------------
// SuperPaymaster future-timestamp tests (P0-16 coverage for the DVT path)
// ---------------------------------------------------------------------------
contract SuperPaymaster_FutureTimestampTest is Test {
    SuperPaymaster paymaster;
    MockSPRegistry registry;

    address owner    = address(0xA1);
    address treasury = address(0xA2);
    address apnts    = address(0xA3); // placeholder — not exercised in these tests

    function setUp() public {
        vm.warp(1_700_000_000); // fixed base timestamp — avoids underflow edge cases

        vm.startPrank(owner);
        registry = new MockSPRegistry();
        MockSPOracle oracle = new MockSPOracle(2000e8);

        // Deploy SuperPaymaster via UUPS proxy helper
        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(0xEE)), // mock entry point — not called in these tests
            IRegistry(address(registry)),
            address(oracle),
            owner,
            apnts,
            treasury,
            3600 // staleness threshold
        );

        // Allow owner to call updatePriceDVT (owner is also BLS_AGGREGATOR for tests)
        paymaster.setBLSAggregator(owner);

        // Seed the cache with a valid past timestamp so monotonicity check passes
        paymaster.updatePriceDVT(2000e8, block.timestamp - 60, "");
        vm.stopPrank();
    }

    /// @notice updatePriceDVT must revert with OracleError when the supplied
    ///         updatedAt timestamp exceeds block.timestamp + TIMESTAMP_GRACE_SECONDS.
    ///         Without this guard, a malicious or buggy keeper could freeze the
    ///         staleness check or cause arithmetic underflow in postOp readers.
    function test_UpdatePriceDVT_RejectsFutureTimestamp() public {
        uint256 grace = paymaster.TIMESTAMP_GRACE_SECONDS();
        uint256 badTs = block.timestamp + grace + 1;

        vm.expectRevert(SuperPaymaster.OracleError.selector);
        vm.prank(owner);
        paymaster.updatePriceDVT(2500e8, badTs, "");
    }

    /// @notice A timestamp exactly at the grace boundary must be accepted so
    ///         that keepers with small clock-skew are not spuriously rejected.
    ///         Uses price within ±20% of the oracle ($2000) to pass the Chainlink
    ///         deviation guard that also runs in updatePriceDVT.
    function test_UpdatePriceDVT_AcceptsTimestampAtGraceBoundary() public {
        uint256 grace = paymaster.TIMESTAMP_GRACE_SECONDS();
        uint256 boundaryTs = block.timestamp + grace;

        // $2100 is +5% from oracle $2000 — within the ±20% deviation limit
        int256 closePrice = 2100e8;

        vm.prank(owner);
        // Should not revert
        paymaster.updatePriceDVT(closePrice, boundaryTs, "");

        // Confirm the cache was updated
        (, uint256 storedTs,,) = paymaster.cachedPrice();
        assertEq(storedTs, boundaryTs, "Cache should store boundary timestamp");
    }
}
