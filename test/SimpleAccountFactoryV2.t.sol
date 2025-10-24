// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "../src/accounts/SimpleAccountFactoryV2.sol";
import "../src/accounts/SimpleAccountV2.sol";
import "../contracts/src/interfaces/IEntryPoint.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

contract SimpleAccountFactoryV2Test is Test {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    SimpleAccountFactoryV2 public factory;
    IEntryPoint public entryPoint;
    address public owner;
    uint256 public ownerPrivateKey;

    address constant ENTRYPOINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;

    function setUp() public {
        // Use the same EntryPoint as in production
        entryPoint = IEntryPoint(ENTRYPOINT_V07);

        // Create a test owner with private key
        ownerPrivateKey = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
        owner = vm.addr(ownerPrivateKey);

        // Deploy factory
        factory = new SimpleAccountFactoryV2(entryPoint);

        console.log("Factory deployed at:", address(factory));
        console.log("Implementation at:", address(factory.accountImplementation()));
        console.log("Owner address:", owner);
    }

    function test_CreateAccountV2() public {
        // Create account
        SimpleAccountV2 account = factory.createAccount(owner, 0);

        console.log("Account created at:", address(account));

        // Verify account version
        string memory version = account.version();
        assertEq(version, "2.0.0", "Account should be version 2.0.0");

        // Verify owner
        address accountOwner = account.owner();
        assertEq(accountOwner, owner, "Owner should match");
    }

    function test_SignatureVerificationWithPersonalSign() public {
        // Create account
        SimpleAccountV2 account = factory.createAccount(owner, 0);

        // Create a test userOpHash
        bytes32 userOpHash = keccak256("test user operation");

        // Simulate personal_sign by adding Ethereum signed message prefix
        bytes32 ethSignedMessageHash = userOpHash.toEthSignedMessageHash();

        // Sign with owner's private key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, ethSignedMessageHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Create a PackedUserOperation (minimal version for testing)
        PackedUserOperation memory userOp = PackedUserOperation({
            sender: address(account),
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: signature
        });

        // Verify signature through the account contract
        // We need to call _validateSignature indirectly through validateUserOp
        vm.prank(address(entryPoint));
        uint256 validationData = account.validateUserOp(userOp, userOpHash, 0);

        assertEq(validationData, 0, "Signature should be valid (personal_sign format)");

        console.log("Personal sign signature verified successfully");
    }

    function test_SignatureVerificationWithRawSign() public {
        // Create account
        SimpleAccountV2 account = factory.createAccount(owner, 1);

        // Create a test userOpHash
        bytes32 userOpHash = keccak256("test user operation raw");

        // Sign directly without prefix (raw signature)
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerPrivateKey, userOpHash);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Create a PackedUserOperation
        PackedUserOperation memory userOp = PackedUserOperation({
            sender: address(account),
            nonce: 0,
            initCode: "",
            callData: "",
            accountGasLimits: bytes32(0),
            preVerificationGas: 0,
            gasFees: bytes32(0),
            paymasterAndData: "",
            signature: signature
        });

        // Verify signature
        vm.prank(address(entryPoint));
        uint256 validationData = account.validateUserOp(userOp, userOpHash, 0);

        assertEq(validationData, 0, "Signature should be valid (raw format)");

        console.log("Raw signature verified successfully");
    }

    function test_CreateAccountDeterministic() public {
        // Create account with salt 123
        address predicted = factory.getAddress(owner, 123);
        SimpleAccountV2 account = factory.createAccount(owner, 123);

        assertEq(address(account), predicted, "Account address should match predicted address");

        // Try creating again with same salt - should return existing account
        SimpleAccountV2 accountAgain = factory.createAccount(owner, 123);
        assertEq(address(account), address(accountAgain), "Should return existing account");
    }
}
