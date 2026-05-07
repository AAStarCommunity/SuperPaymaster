// SPDX-License-Identifier: Apache-2.0
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;

import { EIP712 } from "solady/utils/EIP712.sol";
import { SignatureCheckerLib } from "solady/utils/SignatureCheckerLib.sol";
import { IERC20 } from "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin-v5.0.2/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";

/**
 * @title MicroPaymentChannel
 * @notice Unidirectional payment channel for streaming micropayments.
 *         Uses cumulative vouchers signed by the payer (or a delegated signer)
 *         that the payee submits on-chain to settle accrued amounts.
 *
 * @dev Key design decisions:
 *      - Cumulative voucher pattern: each voucher states the *total* amount owed,
 *        so natural replay protection is achieved without nonces.
 *      - authorizedSigner delegation allows AirAccount Session Keys to sign
 *        vouchers on behalf of the payer.
 *      - channelId is bound to (contract address, chainId) to prevent
 *        cross-chain and cross-contract replay attacks.
 *      - closeTimeout gives the payee a window to submit final vouchers
 *        before the payer can unilaterally withdraw remaining funds.
 */
contract MicroPaymentChannel is EIP712, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ====================================
    // Constants
    // ====================================

    /// @notice Minimum allowed closeTimeout (5 minutes).
    uint64 public constant MIN_CLOSE_TIMEOUT = 300;
    /// @notice Maximum allowed closeTimeout (24 hours).
    uint64 public constant MAX_CLOSE_TIMEOUT = 86400;

    /// @dev EIP-712 type hash for voucher signatures.
    bytes32 public constant VOUCHER_TYPEHASH =
        keccak256("Voucher(bytes32 channelId,uint128 cumulativeAmount)");

    // ====================================
    // Storage
    // ====================================

    /// @notice Dispute window (in seconds) after a close request before the payer can withdraw.
    ///         Owner-configurable between MIN_CLOSE_TIMEOUT and MAX_CLOSE_TIMEOUT.
    uint64 public closeTimeout = 900; // 15 minutes default

    /// @dev channelId => Channel
    mapping(bytes32 => Channel) private _channels;

    /// @dev Tracks channelIds that have been finalized. Persists after struct deletion
    ///      to block voucher replay via same-salt channel reopening (B4-N5 fix).
    mapping(bytes32 => bool) public closedChannels;

    // ====================================
    // Types
    // ====================================

    /// @notice On-chain state of a payment channel.
    struct Channel {
        address payer;              // Agent (depositor)
        address payee;              // Service provider
        address token;              // Payment token (USDC, aPNTs, etc.)
        address authorizedSigner;   // Delegated signer (AirAccount Session Key)
        uint128 deposit;            // Total deposited amount
        uint128 settled;            // Total settled amount (cumulative)
        uint64  closeRequestedAt;   // Dispute window start (0 = open)
        bool    finalized;          // Channel closed
    }

    // ====================================
    // Errors
    // ====================================

    error ChannelAlreadyExists();
    error ChannelAlreadyClosed();
    error ChannelNotFound();
    error ChannelFinalized();
    error OnlyPayer();
    error OnlyPayee();
    error InvalidAmount();
    error InvalidSignature();
    error CloseNotRequested();
    error CloseTimeoutNotElapsed();
    error SettlementExceedsDeposit();
    error NonDecreasingSettlement();
    error SelfChannel();
    error InvalidParameter(string reason);

    // ====================================
    // Events
    // ====================================

    event ChannelOpened(
        bytes32 indexed channelId,
        address indexed payer,
        address indexed payee,
        address token,
        uint128 deposit
    );

    event ChannelSettled(
        bytes32 indexed channelId,
        uint128 cumulativeAmount,
        uint128 delta
    );

    event ChannelTopUp(
        bytes32 indexed channelId,
        uint128 amount,
        uint128 newDeposit
    );

    event CloseRequested(
        bytes32 indexed channelId,
        uint64 requestedAt
    );

    event ChannelClosed(
        bytes32 indexed channelId,
        uint128 finalSettled,
        uint128 refund
    );

    event ChannelWithdrawn(
        bytes32 indexed channelId,
        uint128 refund
    );

    event CloseTimeoutUpdated(uint64 oldTimeout, uint64 newTimeout);

    // ====================================
    // Modifiers
    // ====================================

    /// @dev Ensures the channel exists and has not been finalized.
    modifier channelActive(bytes32 channelId) {
        Channel storage ch = _channels[channelId];
        if (ch.payer == address(0)) revert ChannelNotFound();
        if (ch.finalized) revert ChannelFinalized();
        _;
    }

    // ====================================
    // Constructor
    // ====================================

    constructor(address initialOwner) Ownable(initialOwner) {}

    // ====================================
    // EIP-712 Configuration
    // ====================================

    /// @inheritdoc EIP712
    function _domainNameAndVersion()
        internal
        pure
        override
        returns (string memory name, string memory ver)
    {
        name = "MicroPaymentChannel";
        ver = "1.0.0";
    }

    // ====================================
    // External / Public Functions
    // ====================================

    /**
     * @notice Open a new unidirectional payment channel.
     * @param payee      Recipient of payments (service provider).
     * @param token      ERC-20 token used for payments.
     * @param deposit    Initial deposit amount (transferred from msg.sender).
     * @param salt       User-provided salt for channelId uniqueness.
     * @param authorizedSigner  Delegated signer (e.g. AirAccount Session Key).
     *                          Set to address(0) to require payer's own signature.
     * @return channelId Deterministic identifier for this channel.
     */
    function openChannel(
        address payee,
        address token,
        uint128 deposit,
        bytes32 salt,
        address authorizedSigner
    ) external nonReentrant returns (bytes32 channelId) {
        if (deposit == 0) revert InvalidAmount();
        if (payee == address(0)) revert InvalidAmount();
        if (token == address(0)) revert InvalidAmount();
        if (payee == msg.sender) revert SelfChannel(); // B4-N8: prevent self-payment channel

        channelId = _computeChannelId(msg.sender, payee, token, salt, authorizedSigner);

        if (_channels[channelId].payer != address(0)) revert ChannelAlreadyExists();
        if (closedChannels[channelId]) revert ChannelAlreadyClosed();

        _channels[channelId] = Channel({
            payer: msg.sender,
            payee: payee,
            token: token,
            authorizedSigner: authorizedSigner,
            deposit: deposit,
            settled: 0,
            closeRequestedAt: 0,
            finalized: false
        });

        IERC20(token).safeTransferFrom(msg.sender, address(this), deposit);

        emit ChannelOpened(channelId, msg.sender, payee, token, deposit);
    }

    /**
     * @notice Settle accrued payment using a cumulative voucher.
     * @dev Only the payee can call. The voucher must be signed by the payer
     *      or the channel's authorizedSigner.
     * @param channelId        Channel identifier.
     * @param cumulativeAmount Total cumulative amount owed (must exceed previous settled).
     * @param signature        EIP-712 voucher signature.
     */
    function settleChannel(
        bytes32 channelId,
        uint128 cumulativeAmount,
        bytes calldata signature
    ) external nonReentrant channelActive(channelId) {
        Channel storage ch = _channels[channelId];

        if (msg.sender != ch.payee) revert OnlyPayee();
        if (cumulativeAmount <= ch.settled) revert NonDecreasingSettlement();
        if (cumulativeAmount > ch.deposit) revert SettlementExceedsDeposit();

        _verifyVoucher(ch, channelId, cumulativeAmount, signature);

        uint128 delta = cumulativeAmount - ch.settled;
        ch.settled = cumulativeAmount;

        IERC20(ch.token).safeTransfer(ch.payee, delta);

        emit ChannelSettled(channelId, cumulativeAmount, delta);
    }

    /**
     * @notice Top up an existing channel with additional funds.
     * @dev Only the payer can call.
     * @param channelId Channel identifier.
     * @param amount    Additional deposit amount.
     */
    function topUpChannel(
        bytes32 channelId,
        uint128 amount
    ) external nonReentrant channelActive(channelId) {
        Channel storage ch = _channels[channelId];

        if (msg.sender != ch.payer) revert OnlyPayer();
        if (amount == 0) revert InvalidAmount();

        ch.deposit += amount;

        IERC20(ch.token).safeTransferFrom(msg.sender, address(this), amount);

        emit ChannelTopUp(channelId, amount, ch.deposit);
    }

    /**
     * @notice Request channel closure. Starts the dispute window.
     * @dev Only the payer can call. The payee has closeTimeout seconds
     *      to submit any remaining vouchers before the payer can withdraw.
     * @param channelId Channel identifier.
     */
    function requestCloseChannel(
        bytes32 channelId
    ) external nonReentrant channelActive(channelId) {
        Channel storage ch = _channels[channelId];

        if (msg.sender != ch.payer) revert OnlyPayer();
        if (ch.closeRequestedAt != 0) return; // B4-N6: already requested, noop to prevent timer reset

        ch.closeRequestedAt = uint64(block.timestamp);

        emit CloseRequested(channelId, uint64(block.timestamp));
    }

    /**
     * @notice Cooperatively close a channel. Payee submits final voucher,
     *         receives settled amount, and payer gets the refund.
     * @dev Only the payee can call. Finalizes the channel.
     * @param channelId        Channel identifier.
     * @param cumulativeAmount Final cumulative amount owed.
     * @param signature        EIP-712 voucher signature for the final amount.
     */
    function closeChannel(
        bytes32 channelId,
        uint128 cumulativeAmount,
        bytes calldata signature
    ) external nonReentrant channelActive(channelId) {
        Channel storage ch = _channels[channelId];

        if (msg.sender != ch.payee) revert OnlyPayee();

        // Allow cumulativeAmount == ch.settled (no new payment, just closing)
        if (cumulativeAmount < ch.settled) revert NonDecreasingSettlement();
        if (cumulativeAmount > ch.deposit) revert SettlementExceedsDeposit();

        // Verify signature only if there is a new settlement
        if (cumulativeAmount > ch.settled) {
            _verifyVoucher(ch, channelId, cumulativeAmount, signature);
        }

        uint128 delta = cumulativeAmount - ch.settled;
        ch.settled = cumulativeAmount;
        ch.finalized = true;

        // Transfer remaining settlement to payee
        if (delta > 0) {
            IERC20(ch.token).safeTransfer(ch.payee, delta);
        }

        // Refund remaining deposit to payer
        uint128 refund = ch.deposit - ch.settled;
        if (refund > 0) {
            IERC20(ch.token).safeTransfer(ch.payer, refund);
        }

        emit ChannelClosed(channelId, ch.settled, refund);
        closedChannels[channelId] = true;
        delete _channels[channelId];
    }

    /**
     * @notice Unilaterally withdraw remaining funds after the dispute window.
     * @dev Only the payer can call. Requires that a close was requested and
     *      the timeout has elapsed.
     * @param channelId Channel identifier.
     */
    function withdrawChannel(
        bytes32 channelId
    ) external nonReentrant channelActive(channelId) {
        Channel storage ch = _channels[channelId];

        if (msg.sender != ch.payer) revert OnlyPayer();
        if (ch.closeRequestedAt == 0) revert CloseNotRequested();
        if (block.timestamp <= uint256(ch.closeRequestedAt) + closeTimeout) {
            revert CloseTimeoutNotElapsed();
        }

        ch.finalized = true;

        uint128 refund = ch.deposit - ch.settled;
        if (refund > 0) {
            IERC20(ch.token).safeTransfer(ch.payer, refund);
        }

        emit ChannelWithdrawn(channelId, refund);
        closedChannels[channelId] = true;
        delete _channels[channelId];
    }

    /**
     * @notice Update the dispute window duration.
     * @dev Only the owner can call. The new value must be within
     *      [MIN_CLOSE_TIMEOUT, MAX_CLOSE_TIMEOUT].
     * @param _timeout New timeout in seconds.
     */
    function setCloseTimeout(uint64 _timeout) external onlyOwner {
        if (_timeout < MIN_CLOSE_TIMEOUT || _timeout > MAX_CLOSE_TIMEOUT) {
            revert InvalidParameter("closeTimeout out of range");
        }
        emit CloseTimeoutUpdated(closeTimeout, _timeout);
        closeTimeout = _timeout;
    }

    /**
     * @notice View function to retrieve channel state.
     * @param channelId Channel identifier.
     * @return channel  The Channel struct.
     */
    function getChannel(bytes32 channelId) external view returns (Channel memory) {
        return _channels[channelId];
    }

    /**
     * @notice Returns the contract version string.
     * @return Version identifier.
     */
    function version() external pure returns (string memory) {
        return "MicroPaymentChannel-1.2.0";
    }

    // ====================================
    // Internal Functions
    // ====================================

    /**
     * @dev Compute deterministic channel ID from parameters.
     *      Bound to contract address and chain ID to prevent replay.
     */
    function _computeChannelId(
        address payer,
        address payee,
        address token,
        bytes32 salt,
        address authorizedSigner
    ) internal view returns (bytes32) {
        return keccak256(
            abi.encode(payer, payee, token, salt, authorizedSigner, address(this), block.chainid)
        );
    }

    /**
     * @dev Verify an EIP-712 voucher signature.
     *      Accepts signatures from the payer or the channel's authorizedSigner.
     */
    function _verifyVoucher(
        Channel storage ch,
        bytes32 channelId,
        uint128 cumulativeAmount,
        bytes calldata signature
    ) internal view {
        bytes32 structHash = keccak256(
            abi.encode(VOUCHER_TYPEHASH, channelId, cumulativeAmount)
        );
        bytes32 digest = _hashTypedData(structHash);

        // Check payer's signature first
        bool valid = SignatureCheckerLib.isValidSignatureNowCalldata(
            ch.payer, digest, signature
        );

        // If payer sig invalid and there is an authorizedSigner, try that
        if (!valid && ch.authorizedSigner != address(0)) {
            valid = SignatureCheckerLib.isValidSignatureNowCalldata(
                ch.authorizedSigner, digest, signature
            );
        }

        if (!valid) revert InvalidSignature();
    }
}
