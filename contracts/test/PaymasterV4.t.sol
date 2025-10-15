// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import "../src/v3/PaymasterV4.sol";
import "../src/MySBT.sol";
import "../src/GasTokenV2.sol";
import { IEntryPoint } from "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import { PackedUserOperation } from "@account-abstraction-v7/interfaces/PackedUserOperation.sol";

contract PaymasterV4Test is Test {
    PaymasterV4 public paymaster;
    MySBT public sbt;
    GasTokenV2 public basePNT;
    GasTokenV2 public aPNT;

    address public owner;
    address public treasury;
    address public user;
    address public entryPoint;

    // Initial parameters
    uint256 constant INITIAL_GAS_TO_USD_RATE = 4500e18; // $4500/ETH
    uint256 constant INITIAL_PNT_PRICE_USD = 0.02e18; // $0.02/PNT
    uint256 constant INITIAL_SERVICE_FEE_RATE = 200; // 2%
    uint256 constant INITIAL_MAX_GAS_COST_CAP = 1e18; // 1 ETH
    uint256 constant INITIAL_MIN_TOKEN_BALANCE = 1000e18; // 1000 PNT

    function setUp() public {
        owner = makeAddr("owner");
        treasury = makeAddr("treasury");
        user = address(this); // Use test contract as user to receive SBT
        entryPoint = makeAddr("entryPoint");

        // Deploy contracts
        vm.startPrank(owner);

        sbt = new MySBT();

        paymaster = new PaymasterV4(
            entryPoint,
            owner,
            treasury,
            INITIAL_GAS_TO_USD_RATE,
            INITIAL_PNT_PRICE_USD,
            INITIAL_SERVICE_FEE_RATE,
            INITIAL_MAX_GAS_COST_CAP,
            INITIAL_MIN_TOKEN_BALANCE
        );

        basePNT = new GasTokenV2("Base PNT", "bPNT", address(paymaster), 1e18);
        aPNT = new GasTokenV2("Alpha PNT", "aPNT", address(paymaster), 1e18);

        // Add SBT and GasTokens
        paymaster.addSBT(address(sbt));
        paymaster.addGasToken(address(basePNT));
        paymaster.addGasToken(address(aPNT));

        vm.stopPrank();
    }

    function test_Constructor() public view {
        assertEq(paymaster.owner(), owner);
        assertEq(paymaster.treasury(), treasury);
        assertEq(paymaster.gasToUSDRate(), INITIAL_GAS_TO_USD_RATE);
        assertEq(paymaster.pntPriceUSD(), INITIAL_PNT_PRICE_USD);
        assertEq(paymaster.serviceFeeRate(), INITIAL_SERVICE_FEE_RATE);
        assertEq(paymaster.maxGasCostCap(), INITIAL_MAX_GAS_COST_CAP);
        assertEq(paymaster.minTokenBalance(), INITIAL_MIN_TOKEN_BALANCE);
        assertFalse(paymaster.paused());
    }

    function test_SBTConfiguration() public view {
        address[] memory sbts = paymaster.getSupportedSBTs();
        assertEq(sbts.length, 1);
        assertEq(sbts[0], address(sbt));
        assertTrue(paymaster.isSBTSupported(address(sbt)));
    }

    function test_GasTokenConfiguration() public view {
        address[] memory tokens = paymaster.getSupportedGasTokens();
        assertEq(tokens.length, 2);
        assertTrue(paymaster.isGasTokenSupported(address(basePNT)));
        assertTrue(paymaster.isGasTokenSupported(address(aPNT)));
    }

    function test_CalculatePNTAmount_Basic() public view {
        // Gas cost: 0.001 ETH
        uint256 gasCost = 0.001 ether;

        // Expected: gasCostUSD = 0.001 * 4500 = 4.5 USD
        //          totalCostUSD = 4.5 * 1.02 = 4.59 USD
        //          pntAmount = 4.59 / 0.02 = 229.5 PNT

        uint256 expected = 229.5e18;
        uint256 actual = paymaster.estimatePNTCost(gasCost);

        assertApproxEqRel(actual, expected, 0.001e18); // 0.1% tolerance
    }

    function test_CalculatePNTAmount_AfterPriceChange() public {
        uint256 gasCost = 0.001 ether;
        uint256 originalAmount = paymaster.estimatePNTCost(gasCost);

        // Change PNT price to $0.01 (half price)
        vm.prank(owner);
        paymaster.setPntPriceUSD(0.01e18);

        uint256 newAmount = paymaster.estimatePNTCost(gasCost);

        // Should be ~2x (double PNT needed)
        assertApproxEqRel(newAmount, originalAmount * 2, 0.001e18);
    }

    function test_SetGasToUSDRate() public {
        uint256 newRate = 5000e18;

        vm.prank(owner);
        paymaster.setGasToUSDRate(newRate);

        assertEq(paymaster.gasToUSDRate(), newRate);
    }

    function test_SetPntPriceUSD() public {
        uint256 newPrice = 0.03e18;

        vm.prank(owner);
        paymaster.setPntPriceUSD(newPrice);

        assertEq(paymaster.pntPriceUSD(), newPrice);
    }

    function test_AddSBT() public {
        MySBT newSBT = new MySBT();

        vm.prank(owner);
        paymaster.addSBT(address(newSBT));

        assertTrue(paymaster.isSBTSupported(address(newSBT)));
        assertEq(paymaster.getSupportedSBTs().length, 2);
    }

    function test_AddSBT_RevertMaxLimit() public {
        vm.startPrank(owner);

        // Add SBTs until limit
        for (uint256 i = 1; i < paymaster.MAX_SBTS(); i++) {
            MySBT newSBT = new MySBT();
            paymaster.addSBT(address(newSBT));
        }

        // Try to add one more
        MySBT extraSBT = new MySBT();
        vm.expectRevert(PaymasterV4.PaymasterV4__MaxLimitReached.selector);
        paymaster.addSBT(address(extraSBT));

        vm.stopPrank();
    }

    function test_AddGasToken_RevertMaxLimit() public {
        vm.startPrank(owner);

        // Add tokens until limit (already have 2)
        for (uint256 i = 2; i < paymaster.MAX_GAS_TOKENS(); i++) {
            GasTokenV2 newToken = new GasTokenV2("Token", "TKN", address(paymaster), 1e18);
            paymaster.addGasToken(address(newToken));
        }

        // Try to add one more
        GasTokenV2 extraToken = new GasTokenV2("Extra", "EXT", address(paymaster), 1e18);
        vm.expectRevert(PaymasterV4.PaymasterV4__MaxLimitReached.selector);
        paymaster.addGasToken(address(extraToken));

        vm.stopPrank();
    }

    function test_RemoveSBT() public {
        vm.prank(owner);
        paymaster.removeSBT(address(sbt));

        assertFalse(paymaster.isSBTSupported(address(sbt)));
        assertEq(paymaster.getSupportedSBTs().length, 0);
    }

    function test_RemoveGasToken() public {
        vm.prank(owner);
        paymaster.removeGasToken(address(basePNT));

        assertFalse(paymaster.isGasTokenSupported(address(basePNT)));
        assertEq(paymaster.getSupportedGasTokens().length, 1);
    }

    function test_PauseUnpause() public {
        vm.startPrank(owner);

        paymaster.pause();
        assertTrue(paymaster.paused());

        paymaster.unpause();
        assertFalse(paymaster.paused());

        vm.stopPrank();
    }

    function test_CheckUserQualification_UndeployedSuccess() public {
        address undeployedUser = makeAddr("undeployed");

        vm.prank(owner);
        basePNT.mint(undeployedUser, 10000e18);

        vm.prank(undeployedUser);
        basePNT.approve(address(paymaster), type(uint256).max);

        (bool qualified, string memory reason) = paymaster.checkUserQualification(
            undeployedUser,
            0.01 ether
        );

        assertTrue(qualified);
        assertEq(bytes(reason).length, 0);
    }

    // Helper to implement ERC721Receiver
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
