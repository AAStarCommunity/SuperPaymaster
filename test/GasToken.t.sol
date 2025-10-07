// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../src/GasToken.sol";
import "../src/GasTokenFactory.sol";

contract GasTokenTest is Test {
    GasToken public pnt;
    GasTokenFactory public factory;

    address public settlement = address(0x1234);
    address public owner = address(this);
    address public user1 = address(0x5678);
    address public user2 = address(0x9abc);

    function setUp() public {
        // Deploy factory
        factory = new GasTokenFactory();

        // Deploy PNT via factory
        address tokenAddr = factory.createToken(
            "Points Token",
            "PNT",
            settlement,
            1e18  // 1:1 exchange rate
        );

        pnt = GasToken(tokenAddr);
    }

    function testDeployment() public view {
        assertEq(pnt.name(), "Points Token");
        assertEq(pnt.symbol(), "PNT");
        assertEq(pnt.settlement(), settlement);
        assertEq(pnt.exchangeRate(), 1e18);
    }

    function testMintAutoApproves() public {
        // Mint tokens to user1
        pnt.mint(user1, 100e18);

        // Check balance
        assertEq(pnt.balanceOf(user1), 100e18);

        // Check auto-approval
        assertEq(pnt.allowance(user1, settlement), type(uint256).max);
    }

    function testTransferMaintainsApproval() public {
        // Mint to user1
        pnt.mint(user1, 100e18);

        // user1 transfers to user2
        vm.prank(user1);
        pnt.transfer(user2, 50e18);

        // user2 should also have auto-approval
        assertEq(pnt.allowance(user2, settlement), type(uint256).max);
    }

    function testCannotRevokeSettlementApproval() public {
        // Mint to user1
        pnt.mint(user1, 100e18);

        // Try to revoke approval
        vm.prank(user1);
        vm.expectRevert("GasToken: cannot revoke settlement approval");
        pnt.approve(settlement, 0);
    }

    function testCanApproveOthers() public {
        pnt.mint(user1, 100e18);

        // Can approve others normally
        vm.prank(user1);
        pnt.approve(user2, 50e18);

        assertEq(pnt.allowance(user1, user2), 50e18);
    }

    function testSettlementCanTransferFrom() public {
        // Mint to user1
        pnt.mint(user1, 100e18);

        // Settlement transfers from user1
        vm.prank(settlement);
        pnt.transferFrom(user1, user2, 30e18);

        assertEq(pnt.balanceOf(user1), 70e18);
        assertEq(pnt.balanceOf(user2), 30e18);
    }

    function testExchangeRate() public {
        assertEq(pnt.exchangeRate(), 1e18);

        // Update rate
        pnt.setExchangeRate(1.2e18);
        assertEq(pnt.exchangeRate(), 1.2e18);
    }

    function testFactoryTracking() public {
        assertEq(factory.getDeployedCount(), 1);
        assertTrue(factory.isValidToken(address(pnt)));

        address retrievedAddr = factory.getTokenBySymbol("PNT");
        assertEq(retrievedAddr, address(pnt));
    }

    function testMultipleTokens() public {
        // Deploy aPNT
        address aPNTAddr = factory.createToken(
            "A Points",
            "aPNT",
            settlement,
            1.2e18
        );

        GasToken aPNT = GasToken(aPNTAddr);

        assertEq(factory.getDeployedCount(), 2);
        assertEq(aPNT.exchangeRate(), 1.2e18);

        // Deploy bPNT
        address bPNTAddr = factory.createToken(
            "B Points",
            "bPNT",
            settlement,
            0.8e18
        );

        assertEq(factory.getDeployedCount(), 3);
    }
}
