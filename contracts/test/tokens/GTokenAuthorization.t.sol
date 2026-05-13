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

contract MockXPNTsToken {
    mapping(address => uint256) public balanceOf;
    function setBalance(address who, uint256 bal) external { balanceOf[who] = bal; }
}

contract MockFactory {
    mapping(address => bool) private _isXPNTs;
    function registerToken(address token) external { _isXPNTs[token] = true; }
    function isXPNTs(address token) external view returns (bool) { return _isXPNTs[token]; }
    // unused stubs to satisfy IxPNTsFactory
    function getAPNTsPrice() external pure returns (uint256) { return 0; }
    function getTokenAddress(address) external pure returns (address) { return address(0); }
    function hasToken(address) external pure returns (bool) { return false; }
}

// ─── Test suite ──────────────────────────────────────────────────────────────

contract GTokenAuthorizationTest is Test {
    GTokenAuthorization token;
    MockSBT       sbt;
    MockFactory   factory;
    MockXPNTsToken pntsA;   // Anni community token (registered in factory)
    MockXPNTsToken pntsB;   // another community token (registered)
    MockXPNTsToken rogue;   // NOT registered in factory

    uint256 constant CAP    = 21_000_000e18;
    uint256 constant AMOUNT = 100e18;
    uint256 constant WINDOW = 4 minutes;

    uint256 alicePk = 0xA11CE;
    address alice;
    address bob;    // holds SBT
    address carol;  // holds pntsA (factory token)
    address dave;   // holds pntsB (another factory token)
    address eve;    // holds rogue token (NOT in factory)
    address frank;  // nothing — outside protocol

    bytes32 domainSeparator;

    bytes32 constant TRANSFER_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,"
        "uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 constant CANCEL_TYPEHASH = keccak256(
        "CancelAuthorization(address authorizer,bytes32 nonce)"
    );

    function setUp() public {
        vm.warp(1_000_000);
        alice = vm.addr(alicePk);
        bob   = makeAddr("bob");
        carol = makeAddr("carol");
        dave  = makeAddr("dave");
        eve   = makeAddr("eve");
        frank = makeAddr("frank");

        sbt     = new MockSBT();
        factory = new MockFactory();
        pntsA   = new MockXPNTsToken();
        pntsB   = new MockXPNTsToken();
        rogue   = new MockXPNTsToken();

        factory.registerToken(address(pntsA));
        factory.registerToken(address(pntsB));
        // rogue NOT registered

        token = new GTokenAuthorization(CAP, address(sbt), address(factory));
        token.mint(alice, AMOUNT);

        sbt.setBalance(bob, 1);                // bob: SBT holder
        pntsA.setBalance(carol, 1);            // carol: pntsA holder
        pntsB.setBalance(dave, 1);             // dave: pntsB holder
        rogue.setBalance(eve, 1);              // eve: rogue token (not in factory)
        // frank: nothing

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

    function _window() internal view returns (uint256 after_, uint256 before_) {
        after_  = block.timestamp - 1;
        before_ = block.timestamp + WINDOW;
    }

    // ─── RC-2: ecosystem coverage ─────────────────────────────────────────

    function test_transfer_toBobWithSBT() public {
        (uint256 va, uint256 vb) = _window();
        bytes32 nonce = bytes32(uint256(1));
        token.transferWithAuthorization(
            alice, bob, AMOUNT, va, vb, nonce, address(0),
            _sign(alice, bob, AMOUNT, va, vb, nonce, alicePk)
        );
        assertEq(token.balanceOf(bob), AMOUNT);
    }

    function test_transfer_toCarolWithPntsA() public {
        (uint256 va, uint256 vb) = _window();
        bytes32 nonce = bytes32(uint256(2));
        token.transferWithAuthorization(
            alice, carol, AMOUNT, va, vb, nonce, address(pntsA),
            _sign(alice, carol, AMOUNT, va, vb, nonce, alicePk)
        );
        assertEq(token.balanceOf(carol), AMOUNT);
    }

    function test_transfer_toDaveWithPntsB() public {
        // different community token — still factory-issued, should pass
        (uint256 va, uint256 vb) = _window();
        bytes32 nonce = bytes32(uint256(3));
        token.transferWithAuthorization(
            alice, dave, AMOUNT, va, vb, nonce, address(pntsB),
            _sign(alice, dave, AMOUNT, va, vb, nonce, alicePk)
        );
        assertEq(token.balanceOf(dave), AMOUNT);
    }

    function test_revert_toEveWithRogueToken() public {
        // eve holds rogue token NOT registered in factory
        (uint256 va, uint256 vb) = _window();
        bytes32 nonce = bytes32(uint256(4));
        vm.expectRevert(GTokenAuthorization.RecipientNotInProtocol.selector);
        token.transferWithAuthorization(
            alice, eve, AMOUNT, va, vb, nonce, address(rogue),
            _sign(alice, eve, AMOUNT, va, vb, nonce, alicePk)
        );
    }

    function test_revert_toFrankNoCredentials() public {
        (uint256 va, uint256 vb) = _window();
        bytes32 nonce = bytes32(uint256(5));
        vm.expectRevert(GTokenAuthorization.RecipientNotInProtocol.selector);
        token.transferWithAuthorization(
            alice, frank, AMOUNT, va, vb, nonce, address(0),
            _sign(alice, frank, AMOUNT, va, vb, nonce, alicePk)
        );
    }

    function test_revert_xPNTsTokenNotInFactoryButCallerClaimsIt() public {
        // relay tries to pass pntsA address for dave who holds pntsB
        // dave doesn't hold pntsA → revert
        (uint256 va, uint256 vb) = _window();
        bytes32 nonce = bytes32(uint256(6));
        vm.expectRevert(GTokenAuthorization.RecipientNotInProtocol.selector);
        token.transferWithAuthorization(
            alice, dave, AMOUNT, va, vb, nonce, address(pntsA),
            _sign(alice, dave, AMOUNT, va, vb, nonce, alicePk)
        );
    }

    function test_allow_recipientWithSBTAndXPNTs() public {
        sbt.setBalance(carol, 1); // carol: now has both SBT and pntsA
        (uint256 va, uint256 vb) = _window();
        bytes32 nonce = bytes32(uint256(7));
        token.transferWithAuthorization(
            alice, carol, AMOUNT, va, vb, nonce, address(pntsA),
            _sign(alice, carol, AMOUNT, va, vb, nonce, alicePk)
        );
        assertEq(token.balanceOf(carol), AMOUNT);
    }

    // ─── RC-1: 5-minute window ────────────────────────────────────────────

    function test_revert_windowTooLong() public {
        uint256 va = block.timestamp - 1;
        uint256 vb = block.timestamp + 6 minutes;
        bytes32 nonce = bytes32(uint256(10));
        vm.expectRevert(GTokenAuthorization.AuthorizationWindowTooLong.selector);
        token.transferWithAuthorization(
            alice, bob, AMOUNT, va, vb, nonce, address(0),
            _sign(alice, bob, AMOUNT, va, vb, nonce, alicePk)
        );
    }

    function test_revert_notYetValid() public {
        uint256 va = block.timestamp + 60;
        uint256 vb = va + WINDOW;
        bytes32 nonce = bytes32(uint256(11));
        vm.expectRevert(GTokenAuthorization.AuthorizationNotYetValid.selector);
        token.transferWithAuthorization(
            alice, bob, AMOUNT, va, vb, nonce, address(0),
            _sign(alice, bob, AMOUNT, va, vb, nonce, alicePk)
        );
    }

    function test_revert_expired() public {
        uint256 va = block.timestamp - 4 minutes + 2;
        uint256 vb = block.timestamp - 1;
        bytes32 nonce = bytes32(uint256(12));
        vm.expectRevert(GTokenAuthorization.AuthorizationExpired.selector);
        token.transferWithAuthorization(
            alice, bob, AMOUNT, va, vb, nonce, address(0),
            _sign(alice, bob, AMOUNT, va, vb, nonce, alicePk)
        );
    }

    function test_exactFiveMinutesAllowed() public {
        uint256 va = block.timestamp - 1;
        uint256 vb = va + 5 minutes;
        bytes32 nonce = bytes32(uint256(13));
        token.transferWithAuthorization(
            alice, bob, AMOUNT, va, vb, nonce, address(0),
            _sign(alice, bob, AMOUNT, va, vb, nonce, alicePk)
        );
        assertEq(token.balanceOf(bob), AMOUNT);
    }

    // ─── Nonce replay ─────────────────────────────────────────────────────

    function test_revert_nonceReuse() public {
        (uint256 va, uint256 vb) = _window();
        bytes32 nonce = bytes32(uint256(20));
        bytes memory sig = _sign(alice, bob, AMOUNT / 2, va, vb, nonce, alicePk);
        token.transferWithAuthorization(alice, bob, AMOUNT / 2, va, vb, nonce, address(0), sig);
        token.mint(alice, AMOUNT);
        vm.expectRevert(GTokenAuthorization.AuthorizationUsedOrCanceled.selector);
        token.transferWithAuthorization(alice, bob, AMOUNT / 2, va, vb, nonce, address(0), sig);
    }

    // ─── cancelAuthorization ──────────────────────────────────────────────

    function test_cancelAuthorization() public {
        bytes32 nonce = bytes32(uint256(30));
        token.cancelAuthorization(alice, nonce, _signCancel(alice, nonce, alicePk));
        assertEq(
            uint8(token.authorizationState(alice, nonce)),
            uint8(GTokenAuthorization.AuthorizationState.Canceled)
        );
    }

    function test_revert_useAfterCancel() public {
        bytes32 nonce = bytes32(uint256(31));
        token.cancelAuthorization(alice, nonce, _signCancel(alice, nonce, alicePk));
        (uint256 va, uint256 vb) = _window();
        vm.expectRevert(GTokenAuthorization.AuthorizationUsedOrCanceled.selector);
        token.transferWithAuthorization(
            alice, bob, AMOUNT, va, vb, nonce, address(0),
            _sign(alice, bob, AMOUNT, va, vb, nonce, alicePk)
        );
    }

    function test_revert_cancelAlreadyUsedNonce() public {
        (uint256 va, uint256 vb) = _window();
        bytes32 nonce = bytes32(uint256(32));
        token.transferWithAuthorization(
            alice, bob, AMOUNT, va, vb, nonce, address(0),
            _sign(alice, bob, AMOUNT, va, vb, nonce, alicePk)
        );
        vm.expectRevert(GTokenAuthorization.AuthorizationUsedOrCanceled.selector);
        token.cancelAuthorization(alice, nonce, _signCancel(alice, nonce, alicePk));
    }

    // ─── Signature integrity ──────────────────────────────────────────────

    function test_revert_badSignature_tamperedRecipient() public {
        (uint256 va, uint256 vb) = _window();
        bytes32 nonce = bytes32(uint256(40));
        bytes memory sig = _sign(alice, bob, AMOUNT, va, vb, nonce, alicePk);
        vm.expectRevert(GTokenAuthorization.InvalidSignature.selector);
        token.transferWithAuthorization(alice, carol, AMOUNT, va, vb, nonce, address(pntsA), sig);
    }

    function test_revert_wrongSigner() public {
        (uint256 va, uint256 vb) = _window();
        bytes32 nonce = bytes32(uint256(41));
        bytes memory sig = _sign(alice, bob, AMOUNT, va, vb, nonce, 0xBAD);
        vm.expectRevert(GTokenAuthorization.InvalidSignature.selector);
        token.transferWithAuthorization(alice, bob, AMOUNT, va, vb, nonce, address(0), sig);
    }

    // ─── Metadata ─────────────────────────────────────────────────────────

    function test_version() public view {
        assertEq(token.version(), "GToken-2.2.0");
    }

    function test_immutables() public view {
        assertEq(address(token.mySBT()),   address(sbt));
        assertEq(address(token.factory()), address(factory));
        assertEq(token.MAX_AUTH_VALIDITY(), 5 minutes);
    }
}
