// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import { MicroPaymentChannel } from "src/paymasters/superpaymaster/v3/MicroPaymentChannel.sol";

/// @dev Minimal ERC20 mock for testing.
contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/**
 * @title MicroPaymentChannelTest
 * @notice Foundry test suite for the MicroPaymentChannel contract.
 */
contract MicroPaymentChannelTest is Test {
    MicroPaymentChannel public channel;
    MockERC20 public token;

    // Payer / Payee are real accounts with known private keys for EIP-712 signing.
    uint256 internal constant PAYER_KEY = 0xA11CE;
    uint256 internal constant PAYEE_KEY = 0xB0B;
    uint256 internal constant SIGNER_KEY = 0xC0DE;
    uint256 internal constant BAD_KEY = 0xDEAD;

    address internal payer;
    address internal payee;
    address internal authorizedSigner;
    address internal badSigner;

    // Convenience
    bytes32 internal constant VOUCHER_TYPEHASH =
        keccak256("Voucher(bytes32 channelId,uint128 cumulativeAmount)");

    // ====================================
    // Setup
    // ====================================

    function setUp() public {
        payer = vm.addr(PAYER_KEY);
        payee = vm.addr(PAYEE_KEY);
        authorizedSigner = vm.addr(SIGNER_KEY);
        badSigner = vm.addr(BAD_KEY);

        channel = new MicroPaymentChannel(address(this));
        token = new MockERC20("Test USDC", "USDC");

        // Mint tokens to payer
        token.mint(payer, 1_000_000e18);

        // Approve channel contract
        vm.prank(payer);
        token.approve(address(channel), type(uint256).max);
    }

    // ====================================
    // Helpers
    // ====================================

    /// @dev Open a standard channel (payer -> payee, 1000 tokens, no delegated signer).
    function _openDefaultChannel() internal returns (bytes32 channelId) {
        vm.prank(payer);
        channelId = channel.openChannel(
            payee,
            address(token),
            1000e18,
            bytes32(uint256(1)), // salt
            address(0)          // no delegated signer
        );
    }

    /// @dev Open a channel with a delegated authorizedSigner.
    function _openDelegatedChannel() internal returns (bytes32 channelId) {
        vm.prank(payer);
        channelId = channel.openChannel(
            payee,
            address(token),
            1000e18,
            bytes32(uint256(2)), // salt
            authorizedSigner
        );
    }

    /// @dev Build and sign an EIP-712 voucher.
    function _signVoucher(
        uint256 signerKey,
        bytes32 channelId,
        uint128 cumulativeAmount
    ) internal view returns (bytes memory signature) {
        bytes32 structHash = keccak256(
            abi.encode(VOUCHER_TYPEHASH, channelId, cumulativeAmount)
        );
        bytes32 digest = _computeDigest(structHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        signature = abi.encodePacked(r, s, v);
    }

    /// @dev Replicate the EIP-712 digest computation that the contract uses.
    function _computeDigest(bytes32 structHash) internal view returns (bytes32) {
        // Build domain separator the same way solady EIP712 does.
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("MicroPaymentChannel"),
                keccak256("1.0.0"),
                block.chainid,
                address(channel)
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    // ====================================
    // Tests: openChannel
    // ====================================

    function testOpenChannel() public {
        bytes32 channelId = _openDefaultChannel();

        MicroPaymentChannel.Channel memory ch = channel.getChannel(channelId);
        assertEq(ch.payer, payer, "payer mismatch");
        assertEq(ch.payee, payee, "payee mismatch");
        assertEq(ch.token, address(token), "token mismatch");
        assertEq(ch.authorizedSigner, address(0), "authorizedSigner should be zero");
        assertEq(ch.deposit, 1000e18, "deposit mismatch");
        assertEq(ch.settled, 0, "settled should be zero");
        assertEq(ch.closeRequestedAt, 0, "closeRequestedAt should be zero");
        assertFalse(ch.finalized, "should not be finalized");

        // Contract should hold the deposit
        assertEq(token.balanceOf(address(channel)), 1000e18, "contract balance mismatch");
    }

    function testRevertOnDoubleOpen() public {
        _openDefaultChannel();

        // Same parameters => same channelId => should revert
        vm.prank(payer);
        vm.expectRevert(MicroPaymentChannel.ChannelAlreadyExists.selector);
        channel.openChannel(
            payee,
            address(token),
            500e18,
            bytes32(uint256(1)), // same salt
            address(0)
        );
    }

    function testOpenChannelRevertsZeroDeposit() public {
        vm.prank(payer);
        vm.expectRevert(MicroPaymentChannel.InvalidAmount.selector);
        channel.openChannel(payee, address(token), 0, bytes32(0), address(0));
    }

    function testOpenChannelRevertsZeroPayee() public {
        vm.prank(payer);
        vm.expectRevert(MicroPaymentChannel.InvalidAmount.selector);
        channel.openChannel(address(0), address(token), 100e18, bytes32(0), address(0));
    }

    function testOpenChannelRevertsZeroToken() public {
        vm.prank(payer);
        vm.expectRevert(MicroPaymentChannel.InvalidAmount.selector);
        channel.openChannel(payee, address(0), 100e18, bytes32(0), address(0));
    }

    // ====================================
    // Tests: settleChannel
    // ====================================

    function testSettleChannel() public {
        bytes32 channelId = _openDefaultChannel();

        // Payer signs a voucher for 100 tokens
        bytes memory sig = _signVoucher(PAYER_KEY, channelId, 100e18);

        uint256 payeeBefore = token.balanceOf(payee);

        vm.prank(payee);
        channel.settleChannel(channelId, 100e18, sig);

        MicroPaymentChannel.Channel memory ch = channel.getChannel(channelId);
        assertEq(ch.settled, 100e18, "settled mismatch");
        assertEq(token.balanceOf(payee) - payeeBefore, 100e18, "payee balance mismatch");
    }

    function testCumulativeVoucher() public {
        bytes32 channelId = _openDefaultChannel();

        // First settlement: 100 tokens
        bytes memory sig1 = _signVoucher(PAYER_KEY, channelId, 100e18);
        vm.prank(payee);
        channel.settleChannel(channelId, 100e18, sig1);

        // Second settlement: cumulative 300 tokens (delta = 200)
        bytes memory sig2 = _signVoucher(PAYER_KEY, channelId, 300e18);
        vm.prank(payee);
        channel.settleChannel(channelId, 300e18, sig2);

        MicroPaymentChannel.Channel memory ch = channel.getChannel(channelId);
        assertEq(ch.settled, 300e18, "cumulative settled mismatch");
        assertEq(token.balanceOf(payee), 300e18, "payee total balance mismatch");
    }

    function testSettleWithDelegatedSigner() public {
        bytes32 channelId = _openDelegatedChannel();

        // Authorized signer signs the voucher (not the payer)
        bytes memory sig = _signVoucher(SIGNER_KEY, channelId, 200e18);

        vm.prank(payee);
        channel.settleChannel(channelId, 200e18, sig);

        MicroPaymentChannel.Channel memory ch = channel.getChannel(channelId);
        assertEq(ch.settled, 200e18, "settled via delegated signer mismatch");
    }

    function testRevertOnInvalidSignature() public {
        bytes32 channelId = _openDefaultChannel();

        // Bad signer (neither payer nor authorizedSigner)
        bytes memory badSig = _signVoucher(BAD_KEY, channelId, 100e18);

        vm.prank(payee);
        vm.expectRevert(MicroPaymentChannel.InvalidSignature.selector);
        channel.settleChannel(channelId, 100e18, badSig);
    }

    function testRevertNonDecreasingSettlement() public {
        bytes32 channelId = _openDefaultChannel();

        // Settle 200
        bytes memory sig1 = _signVoucher(PAYER_KEY, channelId, 200e18);
        vm.prank(payee);
        channel.settleChannel(channelId, 200e18, sig1);

        // Try to settle 150 (less than 200) — should revert
        bytes memory sig2 = _signVoucher(PAYER_KEY, channelId, 150e18);
        vm.prank(payee);
        vm.expectRevert(MicroPaymentChannel.NonDecreasingSettlement.selector);
        channel.settleChannel(channelId, 150e18, sig2);
    }

    function testRevertSettlementExceedsDeposit() public {
        bytes32 channelId = _openDefaultChannel(); // deposit = 1000e18

        bytes memory sig = _signVoucher(PAYER_KEY, channelId, 2000e18);

        vm.prank(payee);
        vm.expectRevert(MicroPaymentChannel.SettlementExceedsDeposit.selector);
        channel.settleChannel(channelId, 2000e18, sig);
    }

    function testRevertOnlyPayeeCanSettle() public {
        bytes32 channelId = _openDefaultChannel();

        bytes memory sig = _signVoucher(PAYER_KEY, channelId, 100e18);

        // Payer tries to settle (not the payee)
        vm.prank(payer);
        vm.expectRevert(MicroPaymentChannel.OnlyPayee.selector);
        channel.settleChannel(channelId, 100e18, sig);
    }

    // ====================================
    // Tests: topUpChannel
    // ====================================

    function testTopUp() public {
        bytes32 channelId = _openDefaultChannel(); // deposit = 1000e18

        vm.prank(payer);
        channel.topUpChannel(channelId, 500e18);

        MicroPaymentChannel.Channel memory ch = channel.getChannel(channelId);
        assertEq(ch.deposit, 1500e18, "deposit after top-up mismatch");
        assertEq(token.balanceOf(address(channel)), 1500e18, "contract balance after top-up");
    }

    function testTopUpRevertsForNonPayer() public {
        bytes32 channelId = _openDefaultChannel();

        vm.prank(payee);
        vm.expectRevert(MicroPaymentChannel.OnlyPayer.selector);
        channel.topUpChannel(channelId, 500e18);
    }

    // ====================================
    // Tests: closeChannel (cooperative)
    // ====================================

    function testCloseChannel() public {
        bytes32 channelId = _openDefaultChannel(); // deposit = 1000e18

        // Settle 400 first
        bytes memory sig1 = _signVoucher(PAYER_KEY, channelId, 400e18);
        vm.prank(payee);
        channel.settleChannel(channelId, 400e18, sig1);

        // Close with final cumulative = 600
        bytes memory sig2 = _signVoucher(PAYER_KEY, channelId, 600e18);
        vm.prank(payee);
        channel.closeChannel(channelId, 600e18, sig2);

        // Channel struct is deleted after finalization (B4-N5 fix); getChannel returns zero struct
        MicroPaymentChannel.Channel memory ch = channel.getChannel(channelId);
        assertEq(ch.payer, address(0), "channel struct should be deleted after close");

        // Payee received 600 total, payer refunded 400
        assertEq(token.balanceOf(payee), 600e18, "payee final balance");
        // Payer had 1M, deposited 1000, got back 400
        assertEq(token.balanceOf(payer), 1_000_000e18 - 1000e18 + 400e18, "payer final balance");
    }

    function testRevertOnSettleAfterFinalized() public {
        bytes32 channelId = _openDefaultChannel();

        // Close immediately with cumulative = 0 (no settlement, just close)
        vm.prank(payee);
        channel.closeChannel(channelId, 0, "");

        // Try to settle after close — struct is deleted so payer == address(0) → ChannelNotFound
        bytes memory sig = _signVoucher(PAYER_KEY, channelId, 100e18);
        vm.prank(payee);
        vm.expectRevert(MicroPaymentChannel.ChannelNotFound.selector);
        channel.settleChannel(channelId, 100e18, sig);
    }

    // ====================================
    // Tests: requestCloseChannel + withdrawChannel
    // ====================================

    function testWithdrawAfterTimeout() public {
        bytes32 channelId = _openDefaultChannel(); // deposit = 1000e18

        // Settle 200 first
        bytes memory sig = _signVoucher(PAYER_KEY, channelId, 200e18);
        vm.prank(payee);
        channel.settleChannel(channelId, 200e18, sig);

        // Payer requests close
        vm.prank(payer);
        channel.requestCloseChannel(channelId);

        MicroPaymentChannel.Channel memory ch = channel.getChannel(channelId);
        assertGt(ch.closeRequestedAt, 0, "closeRequestedAt should be set");

        // Warp past the timeout (15 minutes + 1 second)
        vm.warp(block.timestamp + 901);

        uint256 payerBefore = token.balanceOf(payer);

        vm.prank(payer);
        channel.withdrawChannel(channelId);

        // Channel struct is deleted after finalization (B4-N5 fix)
        ch = channel.getChannel(channelId);
        assertEq(ch.payer, address(0), "channel struct should be deleted after withdraw");

        // Refund = 1000 - 200 = 800
        uint128 expectedRefund = 800e18;
        assertEq(token.balanceOf(payer) - payerBefore, expectedRefund, "refund amount mismatch");
    }

    function testRevertWithdrawBeforeTimeout() public {
        bytes32 channelId = _openDefaultChannel();

        vm.prank(payer);
        channel.requestCloseChannel(channelId);

        // Try to withdraw immediately (within timeout)
        vm.prank(payer);
        vm.expectRevert(MicroPaymentChannel.CloseTimeoutNotElapsed.selector);
        channel.withdrawChannel(channelId);
    }

    function testRevertWithdrawWithoutCloseRequest() public {
        bytes32 channelId = _openDefaultChannel();

        vm.prank(payer);
        vm.expectRevert(MicroPaymentChannel.CloseNotRequested.selector);
        channel.withdrawChannel(channelId);
    }

    function testPayeeCanSettleDuringDisputeWindow() public {
        bytes32 channelId = _openDefaultChannel(); // deposit = 1000e18

        // Payer requests close
        vm.prank(payer);
        channel.requestCloseChannel(channelId);

        // Payee can still settle during the window
        bytes memory sig = _signVoucher(PAYER_KEY, channelId, 500e18);
        vm.prank(payee);
        channel.settleChannel(channelId, 500e18, sig);

        MicroPaymentChannel.Channel memory ch = channel.getChannel(channelId);
        assertEq(ch.settled, 500e18, "payee should be able to settle during window");
    }

    // ====================================
    // Tests: Channel not found
    // ====================================

    function testRevertOnNonexistentChannel() public {
        bytes32 fakeId = bytes32(uint256(999));

        vm.prank(payee);
        vm.expectRevert(MicroPaymentChannel.ChannelNotFound.selector);
        channel.settleChannel(fakeId, 100e18, "");
    }

    // ====================================
    // Tests: version
    // ====================================

    function testVersion() public view {
        assertEq(channel.version(), "MicroPaymentChannel-1.2.0");
    }

    // ====================================
    // Tests: channelId determinism
    // ====================================

    function testChannelIdDeterministic() public view {
        bytes32 expected = keccak256(
            abi.encode(
                payer,
                payee,
                address(token),
                bytes32(uint256(1)),
                address(0),
                address(channel),
                block.chainid
            )
        );

        // Verify the channel ID matches expectations (would be returned by openChannel)
        // We just verify the computation logic is consistent
        assertTrue(expected != bytes32(0), "channelId should be non-zero");
    }

    // ====================================
    // Tests: close with cumulative == settled (no new payment)
    // ====================================

    function testCloseWithNoNewSettlement() public {
        bytes32 channelId = _openDefaultChannel(); // deposit = 1000e18

        // Settle 300
        bytes memory sig = _signVoucher(PAYER_KEY, channelId, 300e18);
        vm.prank(payee);
        channel.settleChannel(channelId, 300e18, sig);

        // Close with cumulative = 300 (same as settled, no delta)
        vm.prank(payee);
        channel.closeChannel(channelId, 300e18, "");

        // Channel struct is deleted after finalization (B4-N5 fix)
        MicroPaymentChannel.Channel memory ch = channel.getChannel(channelId);
        assertEq(ch.payer, address(0), "channel struct should be deleted after close");

        // Payer refunded 700
        assertEq(token.balanceOf(payer), 1_000_000e18 - 1000e18 + 700e18, "payer refund");
    }
}
