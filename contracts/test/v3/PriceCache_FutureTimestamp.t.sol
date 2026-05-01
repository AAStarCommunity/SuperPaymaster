// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import "src/paymasters/v4/Paymaster.sol";

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
}
