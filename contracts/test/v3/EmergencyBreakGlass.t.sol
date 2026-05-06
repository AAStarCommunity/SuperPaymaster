// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

/// @notice P0-10 (B2-N2 + P3-H2): the original `updatePriceDVT` had an owner
///         break-glass path that skipped the Chainlink ±20% deviation check
///         whenever Chainlink itself was unavailable — exactly when the
///         check matters most. The new `emergencySetPrice` /
///         `executeEmergencyPrice` flow enforces:
///           1. Chainlink must actually be stale before the path opens;
///           2. New price within ±20% of last cachedPrice;
///           3. 1-hour timelock between queueing and applying;
///           4. Auto-revert to CHAINLINK mode when fresh Chainlink data lands.
contract MockEntryPointEBG {
    function depositTo(address) external payable {}
}

/// @dev Mock oracle whose `updatedAt` and `price` are owner-controlled so we
///      can simulate Chainlink going stale and recovering.
contract MockOracleEBG {
    int256 public price = 2000e8;
    uint256 public updatedAt;
    bool public reverts;
    constructor() { updatedAt = block.timestamp; }
    function setPrice(int256 p) external { price = p; }
    function setUpdatedAt(uint256 t) external { updatedAt = t; }
    function setReverts(bool r) external { reverts = r; }
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (reverts) revert("oracle down");
        return (1, price, 0, updatedAt, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

contract MockTokenEBG is ERC20 {
    constructor() ERC20("aPNTs", "aPNTs") {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract EmergencyBreakGlassTest is Test {
    SuperPaymaster paymaster;
    MockOracleEBG oracle;
    address owner = address(0xABCD);
    address attacker = address(0xBAD);

    function setUp() public {
        // Warp away from genesis so `block.timestamp - 2 hours` doesn't
        // underflow when we mark the oracle stale.
        vm.warp(1_700_000_000);

        Registry registry = UUPSDeployHelper.deployRegistryProxy(owner, address(0), address(0));
        oracle = new MockOracleEBG();
        oracle.setUpdatedAt(block.timestamp);
        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(new MockEntryPointEBG())),
            registry,
            address(oracle),
            owner,
            address(new MockTokenEBG()),
            owner,
            4200
        );
        // Seed cache so the ±20% band has a non-zero reference.
        vm.prank(owner);
        paymaster.updatePrice();
        // Make Chainlink stale by default so the break-glass path is open in
        // each test — individual tests warp / setUpdatedAt as needed.
        oracle.setUpdatedAt(block.timestamp - 2 hours);
    }

    // -----------------------------------------------------------------------
    // Queue path
    // -----------------------------------------------------------------------

    function test_EmergencySetPrice_QueuesPendingValue() public {
        int256 newPrice = 1900e8; // ~5% below cached
        vm.prank(owner);
        paymaster.emergencySetPrice(newPrice);

        assertEq(paymaster.emergencyPendingPrice(), newPrice);
        assertEq(paymaster.emergencyQueuedAt(), block.timestamp);
        // Live cache untouched until execute.
        (int256 cached,,,) = paymaster.cachedPrice();
        assertEq(cached, 2000e8);
    }

    function test_EmergencySetPrice_OnlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        paymaster.emergencySetPrice(1900e8);
    }

    function test_EmergencySetPrice_RevertsWhenChainlinkFresh() public {
        // Make Chainlink fresh again.
        oracle.setUpdatedAt(block.timestamp);
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.ChainlinkNotStale.selector);
        paymaster.emergencySetPrice(1900e8);
    }

    function test_EmergencySetPrice_RejectsAboveBand() public {
        // 2000 * 1.21 = 2420 — outside the ±20% upper bound (2400).
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.EmergencyPriceOutOfRange.selector);
        paymaster.emergencySetPrice(2420e8);
    }

    function test_EmergencySetPrice_RejectsBelowBand() public {
        // 2000 * 0.79 = 1580 — below the lower bound (1600).
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.EmergencyPriceOutOfRange.selector);
        paymaster.emergencySetPrice(1580e8);
    }

    function test_EmergencySetPrice_AcceptsExactBoundary() public {
        // 2000 * 1.20 = 2400 — exactly the upper bound, should pass.
        vm.prank(owner);
        paymaster.emergencySetPrice(2400e8);
        assertEq(paymaster.emergencyPendingPrice(), 2400e8);
    }

    function test_EmergencySetPrice_OpensWhenOracleReverts() public {
        // Even if Chainlink reverts, treat as stale.
        oracle.setReverts(true);
        vm.prank(owner);
        paymaster.emergencySetPrice(1900e8);
        assertEq(paymaster.emergencyPendingPrice(), 1900e8);
    }

    function test_EmergencySetPrice_RejectsZeroOrNegative() public {
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.OracleError.selector);
        paymaster.emergencySetPrice(0);

        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.OracleError.selector);
        paymaster.emergencySetPrice(-1);
    }

    // -----------------------------------------------------------------------
    // Cancel path
    // -----------------------------------------------------------------------

    function test_CancelEmergencyPrice_ClearsPending() public {
        vm.prank(owner);
        paymaster.emergencySetPrice(1900e8);
        vm.prank(owner);
        paymaster.cancelEmergencyPrice();
        assertEq(paymaster.emergencyQueuedAt(), 0);
        assertEq(paymaster.emergencyPendingPrice(), 0);
    }

    function test_CancelEmergencyPrice_IdempotentWithNoPending() public {
        vm.prank(owner);
        paymaster.cancelEmergencyPrice(); // no-op
        assertEq(paymaster.emergencyQueuedAt(), 0);
    }

    function test_CancelEmergencyPrice_OnlyOwner() public {
        vm.prank(owner);
        paymaster.emergencySetPrice(1900e8);

        vm.prank(attacker);
        vm.expectRevert();
        paymaster.cancelEmergencyPrice();
    }

    // -----------------------------------------------------------------------
    // Execute path
    // -----------------------------------------------------------------------

    function test_ExecuteEmergencyPrice_RevertsBeforeTimelock() public {
        vm.prank(owner);
        paymaster.emergencySetPrice(1900e8);
        vm.warp(block.timestamp + paymaster.EMERGENCY_TIMELOCK() - 1);
        vm.expectRevert(SuperPaymaster.EmergencyTimelockNotElapsed.selector);
        paymaster.executeEmergencyPrice();
    }

    function test_ExecuteEmergencyPrice_RevertsWithNothingPending() public {
        vm.expectRevert(SuperPaymaster.NoEmergencyPending.selector);
        paymaster.executeEmergencyPrice();
    }

    function test_ExecuteEmergencyPrice_HappyPath() public {
        vm.prank(owner);
        paymaster.emergencySetPrice(1900e8);
        vm.warp(block.timestamp + paymaster.EMERGENCY_TIMELOCK());

        // Permissionless: anyone can land it after timelock.
        vm.prank(attacker);
        paymaster.executeEmergencyPrice();

        (int256 price,,,) = paymaster.cachedPrice();
        assertEq(price, 1900e8);
        assertEq(paymaster.priceMode(), 1);
        assertEq(paymaster.emergencyQueuedAt(), 0);
        assertEq(paymaster.emergencyPendingPrice(), 0);
    }

    // -----------------------------------------------------------------------
    // Auto-recovery: Chainlink comes back → mode flips to CHAINLINK.
    // -----------------------------------------------------------------------

    function test_UpdatePrice_RestoresChainlinkModeAfterEmergency() public {
        // Land emergency price first.
        vm.prank(owner);
        paymaster.emergencySetPrice(1900e8);
        vm.warp(block.timestamp + paymaster.EMERGENCY_TIMELOCK());
        paymaster.executeEmergencyPrice();
        assertEq(paymaster.priceMode(), 1);

        // Chainlink resumes — fresh updatedAt.
        oracle.setUpdatedAt(block.timestamp);
        oracle.setPrice(2050e8);
        paymaster.updatePrice();

        assertEq(paymaster.priceMode(), 0, "should drop back to CHAINLINK mode");
        (int256 price,,,) = paymaster.cachedPrice();
        assertEq(price, 2050e8);
    }

    function test_UpdatePrice_ClearsPendingEmergencyOnRecovery() public {
        // Queue (don't execute) — leave a pending emergency price hanging.
        vm.prank(owner);
        paymaster.emergencySetPrice(1900e8);
        assertEq(paymaster.emergencyQueuedAt() != 0, true);

        // Chainlink recovers before timelock elapses; updatePrice should
        // discard the pending emergency value as no-longer-relevant.
        oracle.setUpdatedAt(block.timestamp);
        paymaster.updatePrice();

        assertEq(paymaster.emergencyQueuedAt(), 0);
        assertEq(paymaster.emergencyPendingPrice(), 0);
    }

    // -----------------------------------------------------------------------
    // isChainlinkStale view mirror
    // -----------------------------------------------------------------------

    function test_IsChainlinkStale_TrueWhenOldUpdatedAt() public view {
        assertTrue(paymaster.isChainlinkStale());
    }

    function test_IsChainlinkStale_FalseWhenFresh() public {
        oracle.setUpdatedAt(block.timestamp);
        assertFalse(paymaster.isChainlinkStale());
    }

    function test_IsChainlinkStale_TrueWhenOracleReverts() public {
        oracle.setReverts(true);
        assertTrue(paymaster.isChainlinkStale());
    }

    // -----------------------------------------------------------------------
    // EMERGENCY_EXPIRY: P0-10 reviewer request — prevent indefinite override
    // -----------------------------------------------------------------------

    function test_EmergencyActivatedAt_SetOnFirstExecute() public {
        assertEq(paymaster.emergencyActivatedAt(), 0, "should start at 0");

        vm.prank(owner);
        paymaster.emergencySetPrice(1900e8);
        vm.warp(block.timestamp + paymaster.EMERGENCY_TIMELOCK());
        paymaster.executeEmergencyPrice();

        assertEq(paymaster.emergencyActivatedAt(), block.timestamp, "should record activation time");
        assertEq(paymaster.priceMode(), 1);
    }

    function test_EmergencyActivatedAt_NotUpdatedOnSubsequentExecute() public {
        // First execute — records activationTime.
        vm.prank(owner);
        paymaster.emergencySetPrice(1900e8);
        vm.warp(block.timestamp + paymaster.EMERGENCY_TIMELOCK());
        paymaster.executeEmergencyPrice();
        uint256 firstActivated = paymaster.emergencyActivatedAt();

        // Second queue+execute while still in EMERGENCY mode.
        vm.warp(block.timestamp + 1 hours);
        oracle.setUpdatedAt(block.timestamp - 2 hours); // keep stale
        vm.prank(owner);
        paymaster.emergencySetPrice(1850e8);
        vm.warp(block.timestamp + paymaster.EMERGENCY_TIMELOCK());
        paymaster.executeEmergencyPrice();

        // priceMode already == 1, so the branch that sets emergencyActivatedAt
        // does NOT execute again — the timestamp should stay at first activation.
        assertEq(paymaster.emergencyActivatedAt(), firstActivated, "activation time must not change on re-execute");
    }

    function test_EmergencyExpiry_OkWithin7Days() public {
        // Activate EMERGENCY mode.
        vm.prank(owner);
        paymaster.emergencySetPrice(1900e8);
        vm.warp(block.timestamp + paymaster.EMERGENCY_TIMELOCK());
        paymaster.executeEmergencyPrice();

        // Warp to just before 7 days — should still be queueable.
        vm.warp(block.timestamp + 7 days - 1);
        oracle.setUpdatedAt(block.timestamp - 2 hours);
        vm.prank(owner);
        paymaster.emergencySetPrice(1910e8); // within ±20% of 1900e8
        assertEq(paymaster.emergencyPendingPrice(), 1910e8);
    }

    function test_EmergencyExpiry_RevertsAfter7Days() public {
        // Activate EMERGENCY mode.
        vm.prank(owner);
        paymaster.emergencySetPrice(1900e8);
        vm.warp(block.timestamp + paymaster.EMERGENCY_TIMELOCK());
        paymaster.executeEmergencyPrice();

        // Warp past 7 days expiry.
        vm.warp(block.timestamp + 7 days + 1);
        oracle.setUpdatedAt(block.timestamp - 2 hours);
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.EmergencyExpired.selector);
        paymaster.emergencySetPrice(1910e8);
    }

    function test_EmergencyActivatedAt_ClearedOnChainlinkRecovery() public {
        // Activate EMERGENCY mode.
        vm.prank(owner);
        paymaster.emergencySetPrice(1900e8);
        vm.warp(block.timestamp + paymaster.EMERGENCY_TIMELOCK());
        paymaster.executeEmergencyPrice();
        assertGt(paymaster.emergencyActivatedAt(), 0);

        // Chainlink recovers.
        oracle.setUpdatedAt(block.timestamp);
        oracle.setPrice(2050e8);
        paymaster.updatePrice();

        assertEq(paymaster.emergencyActivatedAt(), 0, "must be cleared on recovery");
        assertEq(paymaster.priceMode(), 0);
    }

    // -----------------------------------------------------------------------
    // updatePriceDVT with chainlinkRecovered=1 clears priceMode
    // -----------------------------------------------------------------------

    function test_UpdatePriceDVT_ChainlinkRecovered_ClearsPriceMode() public {
        // Step 1: Activate EMERGENCY mode via emergencySetPrice + executeEmergencyPrice.
        vm.prank(owner);
        paymaster.emergencySetPrice(1900e8);
        vm.warp(block.timestamp + paymaster.EMERGENCY_TIMELOCK());
        paymaster.executeEmergencyPrice();
        assertEq(paymaster.priceMode(), 1, "should be in EMERGENCY mode");
        assertGt(paymaster.emergencyActivatedAt(), 0, "emergencyActivatedAt should be set");

        // Step 2: BLS aggregator calls updatePriceDVT with chainlinkRecovered=1.
        // updatedAt must be strictly greater than the current cachedPrice.updatedAt,
        // so advance time by one second first.
        vm.warp(block.timestamp + 1);
        vm.prank(owner); // owner acts as BLS_AGGREGATOR for simplicity
        int256 newPrice = 1950e8;
        uint256 ts = block.timestamp;
        paymaster.updatePriceDVT(newPrice, ts, "", 1);

        // Step 3: priceMode must be cleared.
        assertEq(paymaster.priceMode(), 0, "priceMode should be cleared to 0 on Chainlink recovery");

        // Step 4: emergencyActivatedAt must be reset.
        assertEq(paymaster.emergencyActivatedAt(), 0, "emergencyActivatedAt should be reset to 0");
    }
}
