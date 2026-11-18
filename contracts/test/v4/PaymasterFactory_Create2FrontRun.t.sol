// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "src/paymasters/v4/Paymaster.sol";
import "src/paymasters/v4/core/PaymasterFactory.sol";
import {EntryPoint} from "@account-abstraction-v7/core/EntryPoint.sol";

contract FrontRunOracle {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000e8, 0, block.timestamp, 1);
    }
    function decimals() external pure returns (uint8) { return 8; }
}

contract FrontRunRegistry {
    function hasRole(bytes32, address) external pure returns (bool) { return true; }
}

/// @notice Daybreak 053117cc DB-d-M3: the CREATE2 salt of deployPaymasterDeterministic was not
///         bound to the deploying operator, so a copied salt landed an attacker-owned clone at
///         the victim's predicted address and the attacker withdrew the victim's prefund.
///         Real EntryPoint v0.7.
contract PaymasterFactory_Create2FrontRunTest is Test {
    PaymasterFactory private factory;
    EntryPoint private entryPoint;
    FrontRunOracle private oracle;
    address private constant VICTIM = address(0xA11CE);
    address private constant ATTACKER = address(0xBAD);
    string private constant V1 = "v1.0";
    bytes32 private constant SALT = keccak256("victim salt");

    function setUp() public {
        vm.warp(1_700_000_000);
        entryPoint = new EntryPoint();
        oracle = new FrontRunOracle();
        Paymaster impl = new Paymaster(address(new FrontRunRegistry()));
        factory = new PaymasterFactory();
        factory.addImplementation(V1, address(impl));
        vm.deal(VICTIM, 10 ether);
    }

    function _initData(address owner_) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            Paymaster.initialize.selector, address(entryPoint), owner_, owner_, address(oracle), 200, 10 ether, 3600
        );
    }

    /// Regression for the front-run: the victim's predicted address cannot be taken by anyone else,
    /// and the prefund stays with the victim.
    function test_CopiedSaltCannotTakeVictimsPredictedAddress() public {
        address predicted = factory.predictPaymasterAddress(V1, VICTIM, SALT);
        vm.prank(VICTIM);
        entryPoint.depositTo{value: 1 ether}(predicted);

        vm.prank(ATTACKER);
        address attackers = factory.deployPaymasterDeterministic(V1, SALT, _initData(ATTACKER));
        assertTrue(attackers != predicted, "attacker's clone lands elsewhere");
        assertEq(attackers, factory.predictPaymasterAddress(V1, ATTACKER, SALT));

        vm.prank(VICTIM);
        address victims = factory.deployPaymasterDeterministic(V1, SALT, _initData(VICTIM));
        assertEq(victims, predicted, "victim still gets the predicted address");
        assertEq(Paymaster(payable(victims)).owner(), VICTIM);

        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSignature("OwnableUnauthorizedAccount(address)", ATTACKER));
        Paymaster(payable(victims)).withdrawTo(payable(ATTACKER), 1 ether);
        assertEq(entryPoint.balanceOf(predicted), 1 ether, "prefund intact");
    }

    /// A prediction pins (version label, operator, salt), not code: replacing the implementation
    /// between prediction and deployment changes the address, so integrators use the receipt.
    function test_ImplementationReplacementChangesPredictedAddress() public {
        address before = factory.predictPaymasterAddress(V1, VICTIM, SALT);
        Paymaster replacement = new Paymaster(address(new FrontRunRegistry()));
        factory.upgradeImplementation(V1, address(replacement));
        address afterUpgrade = factory.predictPaymasterAddress(V1, VICTIM, SALT);
        assertTrue(before != afterUpgrade);
        vm.prank(VICTIM);
        assertEq(factory.deployPaymasterDeterministic(V1, SALT, _initData(VICTIM)), afterUpgrade);
    }

    /// Existing clones keep their owner: it is fixed in the deploying transaction (_initAndVerify) and
    /// no factory function touches a clone's owner afterwards; a later deploy by the same operator
    /// is refused, and another operator's deploy with the same salt lands at a different address.
    function test_ExistingCloneOwnerCannotBeDisplaced() public {
        vm.prank(VICTIM);
        address deployed = factory.deployPaymasterDeterministic(V1, SALT, _initData(VICTIM));
        vm.prank(VICTIM);
        vm.expectRevert(abi.encodeWithSelector(PaymasterFactory.OperatorAlreadyHasPaymaster.selector, VICTIM));
        factory.deployPaymasterDeterministic(V1, SALT, _initData(VICTIM));
        vm.prank(ATTACKER);
        address other = factory.deployPaymasterDeterministic(V1, SALT, _initData(ATTACKER));
        assertTrue(other != deployed);
        assertEq(Paymaster(payable(deployed)).owner(), VICTIM, "existing clone owner unchanged");
    }
}
