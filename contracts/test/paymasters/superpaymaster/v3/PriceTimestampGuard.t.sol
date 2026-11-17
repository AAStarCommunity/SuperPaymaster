// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymasterAdmin.sol";
import {SuperPaymasterAdminCalls} from "src/paymasters/superpaymaster/v3/SuperPaymasterAdminCalls.sol";
import {UUPSDeployHelper} from "../../../helpers/UUPSDeployHelper.sol";
import {V55Registry, V55PriceFeed} from "../../../helpers/V55TestFixtures.sol";

contract PriceTimestampGuardTest is Test {
    using SuperPaymasterAdminCalls for SuperPaymaster;
    SuperPaymaster sp;
    V55PriceFeed feed;

    function setUp() public {
        vm.warp(1_700_000_000);
        feed = new V55PriceFeed();
        sp = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(0x123)), IRegistry(address(new V55Registry())),
            address(feed), address(this), address(0x456), address(this), 3600
        );
    }

    function _round(uint256 timestamp) internal {
        vm.mockCall(address(feed), abi.encodeWithSelector(feed.latestRoundData.selector),
            abi.encode(uint80(1), int256(2000e8), uint256(0), timestamp, uint80(1)));
    }

    function test_GraceBoundaryAccepted() public {
        _round(block.timestamp + 300);
        sp.updatePrice();
        (, uint256 timestamp,,) = sp.cachedPrice();
        assertEq(timestamp, block.timestamp, "accepted at the boundary and cached as now");
    }

    /// A round up to the grace ahead is cached as "now", so DVT updates are not blocked by a future
    /// cached timestamp (updatePriceDVT requires updatedAt > cached updatedAt).
    function test_FutureRoundIsCachedAsNow() public {
        _round(block.timestamp + 200);
        sp.updatePrice();
        (, uint256 cached,,) = sp.cachedPrice();
        assertEq(cached, block.timestamp);
    }

    function test_BeyondGraceRejected() public {
        uint256 timestamp = block.timestamp + 301;
        _round(timestamp);
        vm.expectRevert(abi.encodeWithSelector(SuperPaymasterAdmin.InvalidOracleTimestamp.selector, timestamp, block.timestamp));
        sp.updatePrice();
    }

    function test_ZeroTimestampRejected() public {
        _round(0);
        vm.expectRevert(abi.encodeWithSelector(SuperPaymasterAdmin.InvalidOracleTimestamp.selector, 0, block.timestamp));
        sp.updatePrice();
    }

    function _assertFallback(uint256 timestamp) internal {
        _round(timestamp);
        assertTrue(sp.isChainlinkStale());
        // 50% deviation would fail against a fresh feed; an invalid timestamp must not gate fallback.
        sp.updatePriceDVT(3000e8, block.timestamp, "", 0);
        (int256 price, uint256 stored,,) = sp.cachedPrice();
        assertEq(price, 3000e8);
        assertEq(stored, block.timestamp);
    }

    function test_FutureChainlinkAllowsDVTFallback() public { _assertFallback(block.timestamp + 1); }
    function test_ZeroChainlinkAllowsDVTFallback() public { _assertFallback(0); }
    function test_MaxTimestampAllowsDVTFallback() public { _assertFallback(type(uint256).max); }

    function test_FreshChainlinkStillEnforcesDeviation() public {
        _round(block.timestamp);
        assertFalse(sp.isChainlinkStale());
        vm.expectRevert(SuperPaymasterStorage.OracleError.selector);
        sp.updatePriceDVT(3000e8, block.timestamp, "", 0);
    }
}
