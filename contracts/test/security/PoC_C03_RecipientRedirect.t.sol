// PoC_C03 regression — final recipient is bound into the EIP-3009 nonce.
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

    mapping(address => mapping(bytes32 => bool)) public authorizationUsed;

    constructor() ERC20("Mock USDC", "mUSDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _authDigest(
        bytes32 typeHash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name())),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
        bytes32 structHash = keccak256(
            abi.encode(typeHash, from, to, value, validAfter, validBefore, nonce)
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    function authorizationDigest(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) public view returns (bytes32) {
        return _authDigest(
            keccak256(
                "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
            ),
            from, to, value, validAfter, validBefore, nonce
        );
    }

    function receiveAuthorizationDigest(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) public view returns (bytes32) {
        return _authDigest(
            keccak256(
                "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
            ),
            from, to, value, validAfter, validBefore, nonce
        );
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
        require(!authorizationUsed[from][nonce], "authorization used");

        bytes32 digest = authorizationDigest(from, to, value, validAfter, validBefore, nonce);
        require(digest.recover(signature) == from, "bad signature");

        authorizationUsed[from][nonce] = true;
        _transfer(from, to, value);
    }

    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        // EIP-3009 receive semantics: only the payee may submit the authorization.
        require(msg.sender == to, "caller must be the payee");
        require(block.timestamp > validAfter, "authorization not yet valid");
        require(block.timestamp < validBefore, "authorization expired");
        require(!authorizationUsed[from][nonce], "authorization used");

        bytes32 digest = receiveAuthorizationDigest(from, to, value, validAfter, validBefore, nonce);
        require(digest.recover(signature) == from, "bad signature");

        authorizationUsed[from][nonce] = true;
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

    function _signEIP3009(
        uint256 privateKey,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) internal view returns (bytes memory) {
        bytes32 digest = asset.receiveAuthorizationDigest(from, to, value, validAfter, validBefore, nonce);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    function test_Regression_redirectedRecipientInvalidatesAuthorization() public {
        uint256 amount = 100 ether;
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        uint256 maxFee = amount;
        bytes32 salt = bytes32(uint256(0xC03));
        bytes32 expectedNonce = keccak256(abi.encode(expectedRecipient, maxFee, salt));
        bytes memory signature =
            _signEIP3009(victimKey, victim, address(paymaster), amount, validAfter, validBefore, expectedNonce);

        vm.prank(facilitator);
        vm.expectRevert("bad signature");
        paymaster.settleX402Payment(
            victim,
            attackerRecipient,
            address(asset),
            amount,
            maxFee,
            validAfter,
            validBefore,
            salt,
            signature
        );

        assertEq(asset.balanceOf(victim), 1_000 ether, "victim balance must be unchanged");
        assertEq(asset.balanceOf(attackerRecipient), 0, "attacker recipient receives nothing");
        assertEq(asset.balanceOf(expectedRecipient), 0, "expected recipient receives nothing on failed redirect");
    }

    function test_Regression_expectedRecipientSettlementSucceeds() public {
        uint256 amount = 100 ether;
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;
        uint256 maxFee = amount;
        bytes32 salt = bytes32(uint256(0xC0302));
        bytes32 expectedNonce = keccak256(abi.encode(expectedRecipient, maxFee, salt));
        bytes memory signature =
            _signEIP3009(victimKey, victim, address(paymaster), amount, validAfter, validBefore, expectedNonce);

        vm.prank(facilitator);
        bytes32 settlementId = paymaster.settleX402Payment(
            victim,
            expectedRecipient,
            address(asset),
            amount,
            maxFee,
            validAfter,
            validBefore,
            salt,
            signature
        );

        assertTrue(settlementId != bytes32(0), "settlement should succeed");
        assertEq(asset.balanceOf(expectedRecipient), amount, "expected recipient receives funds");
        assertEq(asset.balanceOf(attackerRecipient), 0, "attacker recipient receives nothing");
        assertEq(asset.balanceOf(victim), 900 ether, "victim paid amount");
    }
}
