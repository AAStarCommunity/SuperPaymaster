// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/paymasters/v4/Paymaster.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";

/// @notice Targeted tests for P0-6 — confirm the new pause/unpause setters
///         actually toggle the `paused` flag and emit the originally-defined
///         events. The original code had the field, the modifier, and the
///         events but no setter, so paused could never become true.
contract MockEntryPoint {
    function depositTo(address) external payable {}
    function balanceOf(address) external pure returns (uint256) { return 0; }
    function addStake(uint32) external payable {}
    function unlockStake() external {}
    function withdrawStake(address payable) external {}
    function withdrawTo(address payable, uint256) external {}
}

contract MockOracle {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

contract MockRegistry {
    function ROLE_PAYMASTER_AOA() external pure returns (bytes32) { return keccak256("PAYMASTER_AOA"); }
    function hasRole(bytes32, address) external pure returns (bool) { return true; }
}

contract PaymasterV4_PauseTest is Test {
    Paymaster paymaster;
    address owner = address(0xABCD);

    // Mirror events to use vm.expectEmit
    event Paused(address indexed account);
    event Unpaused(address indexed account);

    function setUp() public {
        MockEntryPoint ep = new MockEntryPoint();
        MockOracle oracle = new MockOracle();
        MockRegistry registry = new MockRegistry();

        Paymaster impl = new Paymaster(address(registry));
        paymaster = Paymaster(payable(Clones.clone(address(impl))));
        paymaster.initialize(
            address(ep),                 // entryPoint
            owner,                       // owner
            owner,                       // treasury
            address(oracle),             // priceFeed
            200,                         // serviceFeeRate (2%)
            10 ether,                    // maxGasCostCap
            3600                         // priceStalenessThreshold
        );
    }

    function test_PauseUnpause_DefaultsToFalse() public view {
        assertFalse(paymaster.paused(), "should start unpaused");
    }

    function test_Pause_SetsFlagAndEmits() public {
        vm.expectEmit(true, false, false, false);
        emit Paused(owner);
        vm.prank(owner);
        paymaster.pause();
        assertTrue(paymaster.paused());
    }

    function test_Unpause_SetsFlagAndEmits() public {
        vm.prank(owner);
        paymaster.pause();
        assertTrue(paymaster.paused());

        vm.expectEmit(true, false, false, false);
        emit Unpaused(owner);
        vm.prank(owner);
        paymaster.unpause();
        assertFalse(paymaster.paused());
    }

    function test_Pause_OnlyOwner() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        paymaster.pause();
    }

    function test_Unpause_OnlyOwner() public {
        vm.prank(owner);
        paymaster.pause();

        vm.prank(address(0xBEEF));
        vm.expectRevert();
        paymaster.unpause();
    }

    function test_Pause_Idempotent() public {
        vm.prank(owner);
        paymaster.pause();
        // Calling again must not revert and must keep paused == true.
        vm.prank(owner);
        paymaster.pause();
        assertTrue(paymaster.paused());
    }

    function test_Unpause_Idempotent() public {
        // Already unpaused; call should be a no-op.
        vm.prank(owner);
        paymaster.unpause();
        assertFalse(paymaster.paused());
    }
}
