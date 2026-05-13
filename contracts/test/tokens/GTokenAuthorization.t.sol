// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import { GTokenAuthorization } from "src/tokens/GTokenAuthorization.sol";

// ─── Minimal mocks ───────────────────────────────────────────────────────────

contract MockSBT {
    mapping(address => uint256) public balanceOf;
    function setBalance(address who, uint256 bal) external { balanceOf[who] = bal; }
    function ownerOf(uint256) external pure returns (address) { return address(0); }
    function exists(uint256) external pure returns (bool) { return false; }
}

contract MockAPNTs {
    mapping(address => uint256) public balanceOf;
    function setBalance(address who, uint256 bal) external { balanceOf[who] = bal; }
}

// ─── Test suite ──────────────────────────────────────────────────────────────

contract GTokenAuthorizationTest is Test {
    GTokenAuthorization token;
    MockSBT  sbt;
    MockAPNTs apnts;

    uint256 constant CAP = 21_000_000e18;
    uint256 constant AMOUNT = 100e18;
    uint256 constant WINDOW = 4 minutes; // <= MAX_AUTH_VALIDITY

    // signers
    uint256 alicePk = 0xA11CE;
    address alice;
    address bob;    // recipient in protocol (has SBT)
    address carol;  // recipient in protocol (has aPNTs)
    address dave;   // outside protocol — no SBT, no aPNTs

    // EIP-712 domain separator (recomputed in setUp)
    bytes32 domainSeparator;

    bytes32 constant TRANSFER_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,"
        "uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 constant CANCEL_TYPEHASH = keccak256(
        "CancelAuthorization(address authorizer,bytes32 nonce)"
    );

    function setUp() public {
        vm.warp(1_000_000); // ensure block.timestamp is large enough for time arithmetic
        alice = vm.addr(alicePk);
        bob   = makeAddr("bob");
        carol = makeAddr("carol");
        dave  = makeAddr("dave");

        sbt   = new MockSBT();
        apnts = new MockAPNTs();

        token = new GTokenAuthorization(CAP, address(sbt), address(apnts));
        token.mint(alice, AMOUNT);

        // bob has SBT, carol has aPNTs, dave has neither
        sbt.setBalance(bob, 1);
        apnts.setBalance(carol, 1);

        domainSeparator = token.DOMAIN_SEPARATOR();
    }

    // ─── helpers ─────────────────────────────────────────────────────────

    function _sign(
        address from, address to, uint256 value,
        uint256 validAfter, uint256 validBefore, bytes32 nonce,
        uint256 pk
    ) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(
            TRANSFER_TYPEHASH, from, to, value, validAfter, validBefore, nonce
        ));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signCancel(address authorizer, bytes32 nonce, uint256 pk)
        internal view returns (bytes memory)
    {
        bytes32 structHash = keccak256(abi.encode(CANCEL_TYPEHASH, authorizer, nonce));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    // ─── happy path ──────────────────────────────────────────────────────

    function test_transferWithAuthorization_toBobWithSBT() public {
        uint256 validAfter  = block.timestamp - 1;
        uint256 validBefore = block.timestamp + WINDOW;
        bytes32 nonce = bytes32(uint256(1));
        bytes memory sig = _sign(alice, bob, AMOUNT, validAfter, validBefore, nonce, alicePk);

        token.transferWithAuthorization(alice, bob, AMOUNT, validAfter, validBefore, nonce, sig);

        assertEq(token.balanceOf(bob), AMOUNT);
        assertEq(token.balanceOf(alice), 0);
        assertEq(
            uint8(token.authorizationState(alice, nonce)),
            uint8(GTokenAuthorization.AuthorizationState.Used)
        );
    }

    function test_transferWithAuthorization_toCarolWithAPNTs() public {
        uint256 validAfter  = block.timestamp - 1;
        uint256 validBefore = block.timestamp + WINDOW;
        bytes32 nonce = bytes32(uint256(2));
        bytes memory sig = _sign(alice, carol, AMOUNT, validAfter, validBefore, nonce, alicePk);

        token.transferWithAuthorization(alice, carol, AMOUNT, validAfter, validBefore, nonce, sig);

        assertEq(token.balanceOf(carol), AMOUNT);
    }

    // ─── Risk Control 1: 5-minute window ─────────────────────────────────

    function test_revert_windowTooLong() public {
        uint256 validAfter  = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 6 minutes; // > 5 min
        bytes32 nonce = bytes32(uint256(3));
        bytes memory sig = _sign(alice, bob, AMOUNT, validAfter, validBefore, nonce, alicePk);

        vm.expectRevert(GTokenAuthorization.AuthorizationWindowTooLong.selector);
        token.transferWithAuthorization(alice, bob, AMOUNT, validAfter, validBefore, nonce, sig);
    }

    function test_revert_notYetValid() public {
        uint256 validAfter  = block.timestamp + 60;  // future
        uint256 validBefore = validAfter + WINDOW;
        bytes32 nonce = bytes32(uint256(4));
        bytes memory sig = _sign(alice, bob, AMOUNT, validAfter, validBefore, nonce, alicePk);

        vm.expectRevert(GTokenAuthorization.AuthorizationNotYetValid.selector);
        token.transferWithAuthorization(alice, bob, AMOUNT, validAfter, validBefore, nonce, sig);
    }

    function test_revert_expired() public {
        // window (4m58s) is <= MAX, but validBefore is in the past
        uint256 validAfter  = block.timestamp - 4 minutes + 2;
        uint256 validBefore = block.timestamp - 1; // already expired
        bytes32 nonce = bytes32(uint256(5));
        bytes memory sig = _sign(alice, bob, AMOUNT, validAfter, validBefore, nonce, alicePk);

        vm.expectRevert(GTokenAuthorization.AuthorizationExpired.selector);
        token.transferWithAuthorization(alice, bob, AMOUNT, validAfter, validBefore, nonce, sig);
    }

    function test_exactFiveMinutesAllowed() public {
        uint256 validAfter  = block.timestamp - 1;
        uint256 validBefore = validAfter + 5 minutes; // exactly MAX_AUTH_VALIDITY
        bytes32 nonce = bytes32(uint256(6));
        bytes memory sig = _sign(alice, bob, AMOUNT, validAfter, validBefore, nonce, alicePk);

        token.transferWithAuthorization(alice, bob, AMOUNT, validAfter, validBefore, nonce, sig);
        assertEq(token.balanceOf(bob), AMOUNT);
    }

    // ─── Risk Control 2: recipient must be in protocol ────────────────────

    function test_revert_recipientNotInProtocol() public {
        uint256 validAfter  = block.timestamp - 1;
        uint256 validBefore = block.timestamp + WINDOW;
        bytes32 nonce = bytes32(uint256(7));
        bytes memory sig = _sign(alice, dave, AMOUNT, validAfter, validBefore, nonce, alicePk);

        vm.expectRevert(GTokenAuthorization.RecipientNotInProtocol.selector);
        token.transferWithAuthorization(alice, dave, AMOUNT, validAfter, validBefore, nonce, sig);
    }

    function test_allow_recipientWithBothSBTAndAPNTs() public {
        // edge case: both qualifications — still allowed
        sbt.setBalance(carol, 1);   // carol already has aPNTs, now also SBT
        uint256 validAfter  = block.timestamp - 1;
        uint256 validBefore = block.timestamp + WINDOW;
        bytes32 nonce = bytes32(uint256(8));
        bytes memory sig = _sign(alice, carol, AMOUNT, validAfter, validBefore, nonce, alicePk);

        token.transferWithAuthorization(alice, carol, AMOUNT, validAfter, validBefore, nonce, sig);
        assertEq(token.balanceOf(carol), AMOUNT);
    }

    // ─── Nonce replay protection ──────────────────────────────────────────

    function test_revert_nonceReuse() public {
        uint256 validAfter  = block.timestamp - 1;
        uint256 validBefore = block.timestamp + WINDOW;
        bytes32 nonce = bytes32(uint256(9));
        bytes memory sig = _sign(alice, bob, AMOUNT / 2, validAfter, validBefore, nonce, alicePk);

        token.transferWithAuthorization(alice, bob, AMOUNT / 2, validAfter, validBefore, nonce, sig);

        // fund alice again and try to reuse nonce
        token.mint(alice, AMOUNT);
        vm.expectRevert(GTokenAuthorization.AuthorizationUsedOrCanceled.selector);
        token.transferWithAuthorization(alice, bob, AMOUNT / 2, validAfter, validBefore, nonce, sig);
    }

    // ─── cancelAuthorization ──────────────────────────────────────────────

    function test_cancelAuthorization() public {
        bytes32 nonce = bytes32(uint256(10));
        bytes memory sig = _signCancel(alice, nonce, alicePk);

        token.cancelAuthorization(alice, nonce, sig);

        assertEq(
            uint8(token.authorizationState(alice, nonce)),
            uint8(GTokenAuthorization.AuthorizationState.Canceled)
        );
    }

    function test_revert_useAfterCancel() public {
        bytes32 nonce = bytes32(uint256(11));
        token.cancelAuthorization(alice, nonce, _signCancel(alice, nonce, alicePk));

        uint256 validAfter  = block.timestamp - 1;
        uint256 validBefore = block.timestamp + WINDOW;
        bytes memory sig = _sign(alice, bob, AMOUNT, validAfter, validBefore, nonce, alicePk);

        vm.expectRevert(GTokenAuthorization.AuthorizationUsedOrCanceled.selector);
        token.transferWithAuthorization(alice, bob, AMOUNT, validAfter, validBefore, nonce, sig);
    }

    function test_revert_cancelAlreadyUsedNonce() public {
        uint256 validAfter  = block.timestamp - 1;
        uint256 validBefore = block.timestamp + WINDOW;
        bytes32 nonce = bytes32(uint256(12));
        token.transferWithAuthorization(
            alice, bob, AMOUNT, validAfter, validBefore, nonce,
            _sign(alice, bob, AMOUNT, validAfter, validBefore, nonce, alicePk)
        );

        vm.expectRevert(GTokenAuthorization.AuthorizationUsedOrCanceled.selector);
        token.cancelAuthorization(alice, nonce, _signCancel(alice, nonce, alicePk));
    }

    // ─── Signature integrity ──────────────────────────────────────────────

    function test_revert_badSignature() public {
        uint256 validAfter  = block.timestamp - 1;
        uint256 validBefore = block.timestamp + WINDOW;
        bytes32 nonce = bytes32(uint256(13));
        bytes memory sig = _sign(alice, bob, AMOUNT, validAfter, validBefore, nonce, alicePk);

        // tamper: change recipient
        vm.expectRevert(GTokenAuthorization.InvalidSignature.selector);
        token.transferWithAuthorization(alice, carol, AMOUNT, validAfter, validBefore, nonce, sig);
    }

    function test_revert_wrongSigner() public {
        uint256 wrongPk = 0xBAD;
        uint256 validAfter  = block.timestamp - 1;
        uint256 validBefore = block.timestamp + WINDOW;
        bytes32 nonce = bytes32(uint256(14));
        bytes memory sig = _sign(alice, bob, AMOUNT, validAfter, validBefore, nonce, wrongPk);

        vm.expectRevert(GTokenAuthorization.InvalidSignature.selector);
        token.transferWithAuthorization(alice, bob, AMOUNT, validAfter, validBefore, nonce, sig);
    }

    // ─── Metadata ─────────────────────────────────────────────────────────

    function test_version() public view {
        assertEq(token.version(), "GToken-2.2.0");
    }

    function test_immutables() public view {
        assertEq(address(token.mySBT()), address(sbt));
        assertEq(address(token.aPNTs()), address(apnts));
        assertEq(token.MAX_AUTH_VALIDITY(), 5 minutes);
    }
}
