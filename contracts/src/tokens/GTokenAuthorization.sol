// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "./GToken.sol";
import "@openzeppelin-v5.0.2/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin-v5.0.2/contracts/utils/cryptography/EIP712.sol";
import { ISBT } from "src/interfaces/ISBT.sol";
import { IxPNTsFactory } from "src/interfaces/IxPNTsFactory.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";

/**
 * @title GTokenAuthorization v2.2.0 — GToken with EIP-3009 gasless transfers
 * @notice Extends GToken with transferWithAuthorization (EIP-3009 style).
 *         Two risk controls applied on every authorization:
 *           1. Validity window capped at MAX_AUTH_VALIDITY (5 min) — limits
 *              the attack surface when a signature is intercepted.
 *           2. Recipient must hold mySBT or any xPNTs token issued by the
 *              registered factory — covers the entire protocol ecosystem
 *              (all communities, not just a single aPNTs address).
 *
 * RC-2 detail: relay passes `xPNTsToken` (the specific community token the
 * recipient holds). The contract verifies factory.isXPNTs(xPNTsToken) and
 * balanceOf(to) > 0. `xPNTsToken` is NOT included in the EIP-712 signature
 * because it is only a gate-check parameter — it cannot redirect funds or
 * change the transfer beneficiary (to/value are signature-bound).
 *
 * @dev Inherits GToken; compiled into a single contract — no cross-contract
 *      call overhead vs. writing the logic directly in GToken.sol.
 *
 * EIP-712 domain: name="GToken", version="1"
 *
 * Deployment: use GTokenAuthorization in place of GToken for new deployments.
 *             Existing GToken deployments cannot be upgraded in-place (no proxy).
 */
contract GTokenAuthorization is GToken, EIP712 {
    using ECDSA for bytes32;

    // ─── EIP-3009 type hashes ───────────────────────────────────────────────
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,"
        "uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 public constant CANCEL_AUTHORIZATION_TYPEHASH = keccak256(
        "CancelAuthorization(address authorizer,bytes32 nonce)"
    );

    // ─── Risk Control 1 ────────────────────────────────────────────────────
    uint256 public constant MAX_AUTH_VALIDITY = 5 minutes;

    // ─── Risk Control 2 ────────────────────────────────────────────────────
    ISBT          public immutable mySBT;
    IxPNTsFactory public immutable factory;  // all xPNTs tokens issued by this factory qualify

    // ─── Nonce state ───────────────────────────────────────────────────────
    enum AuthorizationState { Unused, Used, Canceled }
    mapping(address => mapping(bytes32 => AuthorizationState)) private _authStates;

    // ─── Events ────────────────────────────────────────────────────────────
    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);
    event AuthorizationCanceled(address indexed authorizer, bytes32 indexed nonce);

    // ─── Errors ────────────────────────────────────────────────────────────
    error AuthorizationNotYetValid();
    error AuthorizationExpired();
    error AuthorizationWindowTooLong();
    error AuthorizationUsedOrCanceled();
    error InvalidSignature();
    error RecipientNotInProtocol();

    // ─── Constructor ───────────────────────────────────────────────────────
    /**
     * @param cap_      Token hard cap (e.g. 21_000_000 * 1e18)
     * @param mySBT_    MySBT contract — balanceOf(to) > 0 satisfies RC-2
     * @param factory_  xPNTsFactory — any token where factory.isXPNTs(token)
     *                  and balanceOf(to) > 0 satisfies RC-2
     */
    constructor(uint256 cap_, address mySBT_, address factory_)
        GToken(cap_)
        EIP712("GToken", "1")
    {
        require(mySBT_ != address(0) && factory_ != address(0), "GTokenAuth: zero addr");
        mySBT   = ISBT(mySBT_);
        factory = IxPNTsFactory(factory_);
    }

    function version() external pure override returns (string memory) {
        return "GToken-2.2.0";
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32) {
        return _domainSeparatorV4();
    }

    // ─── EIP-3009 Public API ───────────────────────────────────────────────

    /**
     * @notice Transfer tokens via an EIP-712 authorization signed by `from`.
     *         Can be called by any relay — `from` never pays gas.
     *
     * @param from        Token owner (signer)
     * @param to          Recipient — must hold mySBT or a factory-issued xPNTs (RC-2)
     * @param value       Amount to transfer
     * @param validAfter  Unix timestamp: not valid before this (0 = immediate)
     * @param validBefore Unix timestamp: expires at this time
     *                    (validBefore - validAfter <= 5 min enforced by RC-1)
     * @param nonce       Random bytes32 chosen by the signer (single-use)
     * @param xPNTsToken  The specific xPNTs token the relay claims `to` holds.
     *                    Pass address(0) to skip the xPNTs path (SBT path only).
     *                    Not included in the EIP-712 signature — see contract docs.
     * @param signature   EIP-712 signature over (from,to,value,validAfter,validBefore,nonce)
     */
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        address xPNTsToken,
        bytes calldata signature
    ) external {
        _requireValidAuthorization(from, to, validAfter, validBefore, nonce, xPNTsToken);
        _requireValidSignature(
            TRANSFER_WITH_AUTHORIZATION_TYPEHASH,
            from, to, value, validAfter, validBefore, nonce, signature
        );

        _authStates[from][nonce] = AuthorizationState.Used;
        emit AuthorizationUsed(from, nonce);
        _transfer(from, to, value);
    }

    /**
     * @notice Cancel an unused authorization so the nonce can never be used.
     *         Must be signed by `authorizer`.
     */
    function cancelAuthorization(
        address authorizer,
        bytes32 nonce,
        bytes calldata signature
    ) external {
        if (_authStates[authorizer][nonce] != AuthorizationState.Unused)
            revert AuthorizationUsedOrCanceled();

        bytes32 digest = _hashTypedDataV4(
            keccak256(abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, authorizer, nonce))
        );
        if (digest.recover(signature) != authorizer) revert InvalidSignature();

        _authStates[authorizer][nonce] = AuthorizationState.Canceled;
        emit AuthorizationCanceled(authorizer, nonce);
    }

    /**
     * @notice Read nonce state for a given authorizer.
     */
    function authorizationState(address authorizer, bytes32 nonce)
        external view
        returns (AuthorizationState)
    {
        return _authStates[authorizer][nonce];
    }

    // ─── Internal helpers ─────────────────────────────────────────────────

    function _requireValidAuthorization(
        address from,
        address to,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        address xPNTsToken
    ) internal view {
        // RC-1: window must be > 0 and <= 5 minutes
        if (validBefore <= validAfter) revert AuthorizationExpired();
        if (validBefore - validAfter > MAX_AUTH_VALIDITY) revert AuthorizationWindowTooLong();
        if (block.timestamp <= validAfter)  revert AuthorizationNotYetValid();
        if (block.timestamp >= validBefore) revert AuthorizationExpired();

        // RC-2: recipient holds mySBT OR a factory-issued xPNTs token
        bool hasSBT     = mySBT.balanceOf(to) > 0;
        bool hasXPNTs   = xPNTsToken != address(0)
                          && factory.isXPNTs(xPNTsToken)
                          && IERC20(xPNTsToken).balanceOf(to) > 0;
        if (!hasSBT && !hasXPNTs) revert RecipientNotInProtocol();

        // nonce must be unused
        if (_authStates[from][nonce] != AuthorizationState.Unused)
            revert AuthorizationUsedOrCanceled();
    }

    function _requireValidSignature(
        bytes32 typeHash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) internal view {
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
            typeHash, from, to, value, validAfter, validBefore, nonce
        )));
        if (digest.recover(signature) != from) revert InvalidSignature();
    }
}
