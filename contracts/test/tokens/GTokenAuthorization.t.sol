// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import { GTokenAuthorization } from "src/tokens/GTokenAuthorization.sol";

// ─── Mocks ───────────────────────────────────────────────────────────────────

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
    mapping(address => bool) private _reg;
    function registerToken(address t) external { _reg[t] = true; }
    function isXPNTs(address t) external view returns (bool) { return _reg[t]; }
    function getAPNTsPrice() external pure returns (uint256) { return 0; }
    function getTokenAddress(address) external pure returns (address) { return address(0); }
    function hasToken(address) external pure returns (bool) { return false; }
}

// ─── Test suite ──────────────────────────────────────────────────────────────

contract GTokenAuthorizationTest is Test {
    GTokenAuthorization token;
    MockSBT        sbt;
    MockFactory    factory;
    MockXPNTsToken pntsA;  // community A token (factory-registered)
    MockXPNTsToken pntsB;  // community B token (factory-registered)
    MockXPNTsToken rogue;  // NOT registered

    uint256 constant CAP    = 21_000_000e18;
    uint256 constant AMOUNT = 100e18;
    uint256 constant WINDOW = 4 minutes;

    uint256 alicePk = 0xA11CE;
    address alice;
    address bob;    // SBT holder
    address carol;  // pntsA holder
    address dave;   // pntsB holder
    address eve;    // rogue token only
    address frank;  // nothing

    bytes32 domainSeparator;

    bytes32 constant TRANSFER_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,"
        "uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 constant RECEIVE_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,"
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

        token = new GTokenAuthorization(CAP, address(factory));
        token.setMySBT(address(sbt));
        token.mint(alice, AMOUNT);

        sbt.setBalance(bob, 1);
        pntsA.setBalance(carol, 1);
        pntsB.setBalance(dave, 1);
        rogue.setBalance(eve, 1);

        domainSeparator = token.DOMAIN_SEPARATOR();
    }

    // ─── helpers ─────────────────────────────────────────────────────────

    function _sign(
        bytes32 typehash,
        address from, address to, uint256 value,
        uint256 va, uint256 vb, bytes32 nonce,
        uint256 pk
    ) internal view returns (bytes memory) {
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01", domainSeparator,
            keccak256(abi.encode(typehash, from, to, value, va, vb, nonce))
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signCancel(address authorizer, bytes32 nonce, uint256 pk)
        internal view returns (bytes memory)
    {
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01", domainSeparator,
            keccak256(abi.encode(CANCEL_TYPEHASH, authorizer, nonce))
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _w() internal view returns (uint256 va, uint256 vb) {
        va = block.timestamp - 1;
        vb = block.timestamp + WINDOW;
    }

    // ─── transferWithAuthorization ────────────────────────────────────────

    function test_transfer_SBT() public {
        (uint256 va, uint256 vb) = _w();
        bytes32 n = bytes32(uint256(1));
        token.transferWithAuthorization(
            alice, bob, AMOUNT, va, vb, n, address(0),
            _sign(TRANSFER_TYPEHASH, alice, bob, AMOUNT, va, vb, n, alicePk)
        );
        assertEq(token.balanceOf(bob), AMOUNT);
        assertEq(uint8(token.authorizationState(alice, n)), uint8(GTokenAuthorization.AuthorizationState.Used));
    }

    function test_transfer_pntsA() public {
        (uint256 va, uint256 vb) = _w();
        bytes32 n = bytes32(uint256(2));
        token.transferWithAuthorization(
            alice, carol, AMOUNT, va, vb, n, address(pntsA),
            _sign(TRANSFER_TYPEHASH, alice, carol, AMOUNT, va, vb, n, alicePk)
        );
        assertEq(token.balanceOf(carol), AMOUNT);
    }

    function test_transfer_pntsB_differentCommunity() public {
        (uint256 va, uint256 vb) = _w();
        bytes32 n = bytes32(uint256(3));
        token.transferWithAuthorization(
            alice, dave, AMOUNT, va, vb, n, address(pntsB),
            _sign(TRANSFER_TYPEHASH, alice, dave, AMOUNT, va, vb, n, alicePk)
        );
        assertEq(token.balanceOf(dave), AMOUNT);
    }

    // ─── receiveWithAuthorization ─────────────────────────────────────────

    function test_receive_byRecipient() public {
        (uint256 va, uint256 vb) = _w();
        bytes32 n = bytes32(uint256(10));
        vm.prank(bob); // bob calls, bob is `to`
        token.receiveWithAuthorization(
            alice, bob, AMOUNT, va, vb, n, address(0),
            _sign(RECEIVE_TYPEHASH, alice, bob, AMOUNT, va, vb, n, alicePk)
        );
        assertEq(token.balanceOf(bob), AMOUNT);
    }

    function test_revert_receive_callerNotRecipient() public {
        (uint256 va, uint256 vb) = _w();
        bytes32 n = bytes32(uint256(11));
        bytes memory sig = _sign(RECEIVE_TYPEHASH, alice, bob, AMOUNT, va, vb, n, alicePk);
        // carol tries to submit a sig meant for bob
        vm.prank(carol);
        vm.expectRevert(GTokenAuthorization.CallerMustBeRecipient.selector);
        token.receiveWithAuthorization(alice, bob, AMOUNT, va, vb, n, address(0), sig);
    }

    function test_revert_receiveTypehash_cannotBeUsedInTransfer() public {
        // A sig made for receiveWithAuthorization must not work in transferWithAuthorization
        (uint256 va, uint256 vb) = _w();
        bytes32 n = bytes32(uint256(12));
        bytes memory sig = _sign(RECEIVE_TYPEHASH, alice, bob, AMOUNT, va, vb, n, alicePk);
        vm.expectRevert(GTokenAuthorization.InvalidSignature.selector);
        token.transferWithAuthorization(alice, bob, AMOUNT, va, vb, n, address(0), sig);
    }

    // ─── RC-2: ecosystem coverage ─────────────────────────────────────────

    function test_revert_rogueToken() public {
        (uint256 va, uint256 vb) = _w();
        bytes32 n = bytes32(uint256(20));
        vm.expectRevert(GTokenAuthorization.RecipientNotInProtocol.selector);
        token.transferWithAuthorization(
            alice, eve, AMOUNT, va, vb, n, address(rogue),
            _sign(TRANSFER_TYPEHASH, alice, eve, AMOUNT, va, vb, n, alicePk)
        );
    }

    function test_revert_noCredentials() public {
        (uint256 va, uint256 vb) = _w();
        bytes32 n = bytes32(uint256(21));
        vm.expectRevert(GTokenAuthorization.RecipientNotInProtocol.selector);
        token.transferWithAuthorization(
            alice, frank, AMOUNT, va, vb, n, address(0),
            _sign(TRANSFER_TYPEHASH, alice, frank, AMOUNT, va, vb, n, alicePk)
        );
    }

    function test_revert_wrongCommunityToken() public {
        // dave holds pntsB but relay passes pntsA — dave has no pntsA balance
        (uint256 va, uint256 vb) = _w();
        bytes32 n = bytes32(uint256(22));
        vm.expectRevert(GTokenAuthorization.RecipientNotInProtocol.selector);
        token.transferWithAuthorization(
            alice, dave, AMOUNT, va, vb, n, address(pntsA),
            _sign(TRANSFER_TYPEHASH, alice, dave, AMOUNT, va, vb, n, alicePk)
        );
    }

    function test_revert_validFactoryTokenButZeroBalance() public {
        // factory knows pntsA but carol has 0 pntsA balance
        pntsA.setBalance(carol, 0);
        (uint256 va, uint256 vb) = _w();
        bytes32 n = bytes32(uint256(23));
        vm.expectRevert(GTokenAuthorization.RecipientNotInProtocol.selector);
        token.transferWithAuthorization(
            alice, carol, AMOUNT, va, vb, n, address(pntsA),
            _sign(TRANSFER_TYPEHASH, alice, carol, AMOUNT, va, vb, n, alicePk)
        );
    }

    function test_SBTShortCircuit_skipsFactoryCalls() public {
        // bob has SBT — passing xPNTsToken=address(rogue) should still pass
        // because SBT check short-circuits before factory.isXPNTs is called
        (uint256 va, uint256 vb) = _w();
        bytes32 n = bytes32(uint256(24));
        token.transferWithAuthorization(
            alice, bob, AMOUNT, va, vb, n, address(rogue),
            _sign(TRANSFER_TYPEHASH, alice, bob, AMOUNT, va, vb, n, alicePk)
        );
        assertEq(token.balanceOf(bob), AMOUNT);
    }

    // ─── RC-1: 5-minute window ────────────────────────────────────────────

    function test_revert_windowTooLong() public {
        bytes32 n = bytes32(uint256(30));
        uint256 va = block.timestamp - 1;
        uint256 vb = block.timestamp + 6 minutes;
        vm.expectRevert(GTokenAuthorization.AuthorizationWindowTooLong.selector);
        token.transferWithAuthorization(
            alice, bob, AMOUNT, va, vb, n, address(0),
            _sign(TRANSFER_TYPEHASH, alice, bob, AMOUNT, va, vb, n, alicePk)
        );
    }

    function test_exactFiveMinutes() public {
        uint256 va = block.timestamp - 1;
        uint256 vb = va + 5 minutes;
        bytes32 n = bytes32(uint256(31));
        token.transferWithAuthorization(
            alice, bob, AMOUNT, va, vb, n, address(0),
            _sign(TRANSFER_TYPEHASH, alice, bob, AMOUNT, va, vb, n, alicePk)
        );
        assertEq(token.balanceOf(bob), AMOUNT);
    }

    function test_revert_notYetValid() public {
        uint256 va = block.timestamp + 60;
        uint256 vb = va + WINDOW;
        bytes32 n = bytes32(uint256(32));
        vm.expectRevert(GTokenAuthorization.AuthorizationNotYetValid.selector);
        token.transferWithAuthorization(
            alice, bob, AMOUNT, va, vb, n, address(0),
            _sign(TRANSFER_TYPEHASH, alice, bob, AMOUNT, va, vb, n, alicePk)
        );
    }

    function test_revert_expired() public {
        uint256 va = block.timestamp - 4 minutes + 2;
        uint256 vb = block.timestamp - 1;
        bytes32 n = bytes32(uint256(33));
        vm.expectRevert(GTokenAuthorization.AuthorizationExpired.selector);
        token.transferWithAuthorization(
            alice, bob, AMOUNT, va, vb, n, address(0),
            _sign(TRANSFER_TYPEHASH, alice, bob, AMOUNT, va, vb, n, alicePk)
        );
    }

    function test_revert_validAfterEqualsValidBefore() public {
        uint256 va = block.timestamp + 10;
        bytes32 n = bytes32(uint256(34));
        vm.expectRevert(GTokenAuthorization.AuthorizationExpired.selector);
        token.transferWithAuthorization(
            alice, bob, AMOUNT, va, va, n, address(0),
            _sign(TRANSFER_TYPEHASH, alice, bob, AMOUNT, va, va, n, alicePk)
        );
    }

    // ─── Nonce replay ─────────────────────────────────────────────────────

    function test_revert_nonceReuse() public {
        (uint256 va, uint256 vb) = _w();
        bytes32 n = bytes32(uint256(40));
        bytes memory sig = _sign(TRANSFER_TYPEHASH, alice, bob, AMOUNT / 2, va, vb, n, alicePk);
        token.transferWithAuthorization(alice, bob, AMOUNT / 2, va, vb, n, address(0), sig);
        token.mint(alice, AMOUNT);
        vm.expectRevert(GTokenAuthorization.AuthorizationUsedOrCanceled.selector);
        token.transferWithAuthorization(alice, bob, AMOUNT / 2, va, vb, n, address(0), sig);
    }

    // ─── cancelAuthorization ──────────────────────────────────────────────

    function test_cancel() public {
        bytes32 n = bytes32(uint256(50));
        token.cancelAuthorization(alice, n, _signCancel(alice, n, alicePk));
        assertEq(
            uint8(token.authorizationState(alice, n)),
            uint8(GTokenAuthorization.AuthorizationState.Canceled)
        );
    }

    function test_revert_useAfterCancel() public {
        bytes32 n = bytes32(uint256(51));
        token.cancelAuthorization(alice, n, _signCancel(alice, n, alicePk));
        (uint256 va, uint256 vb) = _w();
        vm.expectRevert(GTokenAuthorization.AuthorizationUsedOrCanceled.selector);
        token.transferWithAuthorization(
            alice, bob, AMOUNT, va, vb, n, address(0),
            _sign(TRANSFER_TYPEHASH, alice, bob, AMOUNT, va, vb, n, alicePk)
        );
    }

    function test_revert_cancelAlreadyUsed() public {
        (uint256 va, uint256 vb) = _w();
        bytes32 n = bytes32(uint256(52));
        token.transferWithAuthorization(
            alice, bob, AMOUNT, va, vb, n, address(0),
            _sign(TRANSFER_TYPEHASH, alice, bob, AMOUNT, va, vb, n, alicePk)
        );
        vm.expectRevert(GTokenAuthorization.AuthorizationUsedOrCanceled.selector);
        token.cancelAuthorization(alice, n, _signCancel(alice, n, alicePk));
    }

    function test_revert_cancelWrongSigner() public {
        bytes32 n = bytes32(uint256(53));
        bytes memory sig = _signCancel(alice, n, 0xBAD);
        vm.expectRevert(GTokenAuthorization.InvalidSignature.selector);
        token.cancelAuthorization(alice, n, sig);
    }

    // ─── Signature integrity ──────────────────────────────────────────────

    function test_revert_tamperedRecipient() public {
        (uint256 va, uint256 vb) = _w();
        bytes32 n = bytes32(uint256(60));
        bytes memory sig = _sign(TRANSFER_TYPEHASH, alice, bob, AMOUNT, va, vb, n, alicePk);
        vm.expectRevert(GTokenAuthorization.InvalidSignature.selector);
        token.transferWithAuthorization(alice, carol, AMOUNT, va, vb, n, address(pntsA), sig);
    }

    function test_revert_wrongSigner() public {
        (uint256 va, uint256 vb) = _w();
        bytes32 n = bytes32(uint256(61));
        bytes memory sig = _sign(TRANSFER_TYPEHASH, alice, bob, AMOUNT, va, vb, n, 0xBAD);
        vm.expectRevert(GTokenAuthorization.InvalidSignature.selector);
        token.transferWithAuthorization(alice, bob, AMOUNT, va, vb, n, address(0), sig);
    }

    // ─── Events ───────────────────────────────────────────────────────────

    function test_emits_AuthorizationUsed() public {
        (uint256 va, uint256 vb) = _w();
        bytes32 n = bytes32(uint256(70));
        vm.expectEmit(true, true, false, false, address(token));
        emit GTokenAuthorization.AuthorizationUsed(alice, n);
        token.transferWithAuthorization(
            alice, bob, AMOUNT, va, vb, n, address(0),
            _sign(TRANSFER_TYPEHASH, alice, bob, AMOUNT, va, vb, n, alicePk)
        );
    }

    function test_emits_AuthorizationCanceled() public {
        bytes32 n = bytes32(uint256(71));
        vm.expectEmit(true, true, false, false, address(token));
        emit GTokenAuthorization.AuthorizationCanceled(alice, n);
        token.cancelAuthorization(alice, n, _signCancel(alice, n, alicePk));
    }

    // ─── Metadata ─────────────────────────────────────────────────────────

    function test_version() public view {
        assertEq(token.version(), "GToken-2.2.0");
    }

    function test_immutables() public view {
        assertEq(address(token.mySBT()),    address(sbt));
        assertEq(address(token.factory()),  address(factory));
        assertEq(token.MAX_AUTH_VALIDITY(), 5 minutes);
    }

    function test_setMySBT_onlyOnce() public {
        GTokenAuthorization fresh = new GTokenAuthorization(CAP, address(factory));
        fresh.setMySBT(address(sbt));
        vm.expectRevert(GTokenAuthorization.SBTAlreadySet.selector);
        fresh.setMySBT(address(sbt));
    }

    function test_setMySBT_onlyOwner() public {
        GTokenAuthorization fresh = new GTokenAuthorization(CAP, address(factory));
        vm.prank(bob);
        vm.expectRevert();
        fresh.setMySBT(address(sbt));
    }

    function test_rc2_beforeSBTSet_xpntsPathWorks() public {
        // Deploy token without setting mySBT — RC-2 should still pass via xPNTs
        GTokenAuthorization fresh = new GTokenAuthorization(CAP, address(factory));
        fresh.mint(alice, AMOUNT);
        (uint256 va, uint256 vb) = _w();
        bytes32 n = bytes32(uint256(90));
        bytes32 ds = fresh.DOMAIN_SEPARATOR();
        bytes32 digest = keccak256(abi.encodePacked(
            "\x19\x01", ds,
            keccak256(abi.encode(TRANSFER_TYPEHASH, alice, carol, AMOUNT, va, vb, n))
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, digest);
        fresh.transferWithAuthorization(
            alice, carol, AMOUNT, va, vb, n, address(pntsA),
            abi.encodePacked(r, s, v)
        );
        assertEq(fresh.balanceOf(carol), AMOUNT);
    }
}
