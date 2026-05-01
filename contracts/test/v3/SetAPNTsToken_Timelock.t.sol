// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "forge-std/StdStorage.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/core/Registry.sol";
import "src/tokens/GToken.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

/// @notice P0-9 (B2-N1): the original `setAPNTsToken` was a single instant
///         write that could strand every operator's deposit if the new token
///         held zero balances. The replacement queue/cancel/execute pattern
///         enforces a 7-day window plus a balance-zero invariant at execute
///         time, giving the owner a chance to abort and giving operators a
///         chance to drain before the swap actually lands.
contract MockEntryPoint {
    function depositTo(address) external payable {}
}

contract MockOracle {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

contract MockToken is ERC20 {
    constructor(string memory n) ERC20(n, n) {}
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract SetAPNTsToken_TimelockTest is Test {
    using stdStorage for StdStorage;

    SuperPaymaster paymaster;
    MockToken initialToken;
    MockToken newToken;
    address owner = address(0xABCD);
    address attacker = address(0xBAD);

    function setUp() public {
        Registry registry = UUPSDeployHelper.deployRegistryProxy(owner, address(0), address(0));
        initialToken = new MockToken("aPNTs-old");
        newToken = new MockToken("aPNTs-new");
        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(new MockEntryPoint())),
            registry,
            address(new MockOracle()),
            owner,
            address(initialToken),
            owner,
            4200
        );
    }

    // -----------------------------------------------------------------------
    // Queue path
    // -----------------------------------------------------------------------

    function test_SetAPNTsToken_QueuesPendingChange() public {
        vm.prank(owner);
        paymaster.setAPNTsToken(address(newToken));

        assertEq(paymaster.pendingAPNTsToken(), address(newToken));
        assertEq(paymaster.pendingAPNTsTokenEta(), block.timestamp + paymaster.APNTS_TOKEN_TIMELOCK());
        assertEq(paymaster.APNTS_TOKEN(), address(initialToken), "live token unchanged until execute");
    }

    function test_SetAPNTsToken_OnlyOwner() public {
        vm.prank(attacker);
        vm.expectRevert();
        paymaster.setAPNTsToken(address(newToken));
    }

    function test_SetAPNTsToken_RevertsOnZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.InvalidAddress.selector);
        paymaster.setAPNTsToken(address(0));
    }

    // -----------------------------------------------------------------------
    // Cancel path
    // -----------------------------------------------------------------------

    function test_CancelAPNTsTokenChange_ClearsPending() public {
        vm.prank(owner);
        paymaster.setAPNTsToken(address(newToken));

        vm.prank(owner);
        paymaster.cancelAPNTsTokenChange();

        assertEq(paymaster.pendingAPNTsToken(), address(0));
        assertEq(paymaster.pendingAPNTsTokenEta(), 0);
    }

    function test_CancelAPNTsTokenChange_IdempotentWhenNothingPending() public {
        vm.prank(owner);
        paymaster.cancelAPNTsTokenChange(); // should not revert
        assertEq(paymaster.pendingAPNTsToken(), address(0));
    }

    function test_CancelAPNTsTokenChange_OnlyOwner() public {
        vm.prank(owner);
        paymaster.setAPNTsToken(address(newToken));

        vm.prank(attacker);
        vm.expectRevert();
        paymaster.cancelAPNTsTokenChange();
    }

    // -----------------------------------------------------------------------
    // Execute path
    // -----------------------------------------------------------------------

    function test_ExecuteAPNTsTokenChange_RevertsBeforeEta() public {
        vm.prank(owner);
        paymaster.setAPNTsToken(address(newToken));

        // Just before the timelock elapses.
        vm.warp(block.timestamp + paymaster.APNTS_TOKEN_TIMELOCK() - 1);
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.InvalidConfiguration.selector);
        paymaster.executeAPNTsTokenChange();
    }

    function test_ExecuteAPNTsTokenChange_RevertsWhenNothingPending() public {
        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.InvalidConfiguration.selector);
        paymaster.executeAPNTsTokenChange();
    }

    function test_ExecuteAPNTsTokenChange_RevertsWhenBalancesNonZero() public {
        // Use stdstore to seed a non-zero totalTrackedBalance; mirrors what
        // would happen in production after any operator deposit.
        stdstore.target(address(paymaster)).sig("totalTrackedBalance()").checked_write(uint256(1));

        vm.prank(owner);
        paymaster.setAPNTsToken(address(newToken));
        vm.warp(block.timestamp + paymaster.APNTS_TOKEN_TIMELOCK());

        vm.prank(owner);
        vm.expectRevert(SuperPaymaster.InvalidConfiguration.selector);
        paymaster.executeAPNTsTokenChange();
    }

    function test_ExecuteAPNTsTokenChange_HappyPath() public {
        vm.prank(owner);
        paymaster.setAPNTsToken(address(newToken));

        vm.warp(block.timestamp + paymaster.APNTS_TOKEN_TIMELOCK());

        // Expect the dedicated timelock event (distinguishable from legacy APNTsTokenUpdated).
        vm.expectEmit(true, true, false, true, address(paymaster));
        emit SuperPaymaster.APNTsTokenChangeExecuted(address(initialToken), address(newToken), block.timestamp);

        // Also expect the backward-compatible event for existing listeners.
        vm.expectEmit(true, true, false, false, address(paymaster));
        emit SuperPaymaster.APNTsTokenUpdated(address(initialToken), address(newToken));

        // Only owner can execute after the timelock elapses.
        vm.prank(owner);
        paymaster.executeAPNTsTokenChange();

        assertEq(paymaster.APNTS_TOKEN(), address(newToken));
        assertEq(paymaster.pendingAPNTsToken(), address(0));
        assertEq(paymaster.pendingAPNTsTokenEta(), 0);
    }

    /// @notice Attacker cannot execute even after the timelock has elapsed.
    ///         executeAPNTsTokenChange is owner-only: unlike OZ TimelockController,
    ///         token migration requires explicit owner confirmation after the
    ///         7-day review window — third-party execution is not permitted.
    function test_ExecuteAPNTsTokenChange_OnlyOwner_AttackerReverts() public {
        vm.prank(owner);
        paymaster.setAPNTsToken(address(newToken));
        vm.warp(block.timestamp + paymaster.APNTS_TOKEN_TIMELOCK());

        vm.prank(attacker);
        vm.expectRevert();
        paymaster.executeAPNTsTokenChange();
        // Token must remain unchanged — the attacker's call reverted.
        assertEq(paymaster.APNTS_TOKEN(), address(initialToken));
    }

    // -----------------------------------------------------------------------
    // Re-queue refreshes the timer (intentional — owner abort + restart)
    // -----------------------------------------------------------------------

    function test_SetAPNTsToken_ReQueueRefreshesEta() public {
        vm.prank(owner);
        paymaster.setAPNTsToken(address(newToken));
        uint256 firstEta = paymaster.pendingAPNTsTokenEta();

        vm.warp(block.timestamp + 1 days);
        MockToken anotherToken = new MockToken("aPNTs-v3");
        vm.prank(owner);
        paymaster.setAPNTsToken(address(anotherToken));

        assertEq(paymaster.pendingAPNTsToken(), address(anotherToken));
        assertGt(paymaster.pendingAPNTsTokenEta(), firstEta, "eta must shift forward");
    }
}
