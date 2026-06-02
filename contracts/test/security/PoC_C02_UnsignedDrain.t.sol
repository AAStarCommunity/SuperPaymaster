// PoC_C02 regression — direct settlement requires payer authorization.
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
    address public facilitator = address(0xC0203);
    address public legitimatePayee = address(0xC0205);
    uint256 public victimKey = 0xC0204;
    address public victim = vm.addr(victimKey);

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
        xpnts.addApprovedFacilitator(facilitator);
        xpnts.mint(victim, 1_000 ether);

        MockXPNTsFactory mockFactory = new MockXPNTsFactory();
        paymaster.setXPNTsFactory(address(mockFactory));
        paymaster.setOperatorFacilitatorFee(facilitator, 100);
        registry.setRole(C02_ROLE_PAYMASTER_SUPER, facilitator, true);

        vm.stopPrank();
    }

    function _signX402Direct(
        uint256 privateKey,
        address from,
        address to,
        address asset,
        uint256 amount,
        uint256 maxFee,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (bytes memory) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("SuperPaymaster"),
                keccak256("1"),
                block.chainid,
                address(paymaster)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "X402PaymentAuthorization(address from,address to,address asset,uint256 amount,uint256 maxFee,uint256 validBefore,bytes32 nonce)"
                ),
                from,
                to,
                asset,
                amount,
                maxFee,
                validBefore,
                nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_Regression_directSettlementRejectsMissingVictimSignature() public {
        uint256 amount = 100 ether;
        uint256 maxFee = (amount * 100) / 10_000;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = bytes32(uint256(0xC02));

        uint256 victimBefore = xpnts.balanceOf(victim);
        uint256 payeeBefore = xpnts.balanceOf(legitimatePayee);

        vm.prank(facilitator);
        vm.expectRevert(SuperPaymaster.InvalidX402Signature.selector);
        paymaster.settleX402PaymentDirect(
            victim, legitimatePayee, address(xpnts), amount, maxFee, validBefore, nonce, ""
        );

        assertEq(xpnts.balanceOf(victim), victimBefore, "victim balance must be unchanged");
        assertEq(xpnts.balanceOf(legitimatePayee), payeeBefore, "payee balance must be unchanged");
    }

    function test_Regression_directSettlementSucceedsWithVictimSignature() public {
        uint256 amount = 100 ether;
        uint256 fee = (amount * 100) / 10_000;
        uint256 maxFee = fee;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = bytes32(uint256(0xC0202));
        bytes memory signature =
            _signX402Direct(victimKey, victim, legitimatePayee, address(xpnts), amount, maxFee, validBefore, nonce);

        uint256 victimBefore = xpnts.balanceOf(victim);

        vm.prank(facilitator);
        bytes32 settlementId = paymaster.settleX402PaymentDirect(
            victim, legitimatePayee, address(xpnts), amount, maxFee, validBefore, nonce, signature
        );

        assertTrue(settlementId != bytes32(0), "settlement should succeed");
        assertEq(xpnts.balanceOf(victim), victimBefore - amount, "victim pays amount");
        assertEq(xpnts.balanceOf(legitimatePayee), amount - fee, "payee receives amount minus fee");
    }
}
