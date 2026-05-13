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
 * @notice Extends GToken with two EIP-3009 transfer paths and two risk controls.
 *
 * Transfer paths
 * ──────────────
 * transferWithAuthorization  — any relay can call; suitable for simple gasless sends.
 * receiveWithAuthorization   — only msg.sender == to may call; prevents front-running
 *                              for atomic deposit/wrapper flows (e.g. UI-driven UIDC
 *                              purchases where the contract must be the caller).
 *
 * Risk controls
 * ─────────────
 * RC-1  Validity window hard-capped at MAX_AUTH_VALIDITY (5 min).
 *       Limits the attack surface if a signature is intercepted.
 * RC-2  Recipient must hold mySBT OR any xPNTs token issued by `factory`.
 *       Covers the entire protocol ecosystem — all past and future communities —
 *       without redeployment. `xPNTsToken` is a relay-supplied calldata hint
 *       (not EIP-712 signed) because it only gates access; funds always flow to
 *       the signature-bound `to` address.
 *       Note: balanceOf is an at-execution snapshot; a recipient that briefly
 *       holds xPNTs will pass RC-2. Persistent membership enforcement requires
 *       a registry/lock mechanism (out of scope for this contract).
 *
 * Execution order (gas-optimal)
 * ─────────────────────────────
 * 1. Time-window checks  (pure arithmetic, cheapest)
 * 2. Nonce state check   (1 SLOAD)
 * 3. Signature recovery  (ecrecover, ~3k gas)
 * 4. RC-2 eligibility    (≤3 external calls, most expensive — runs only on valid sigs)
 *
 * Deployment dependency
 * ─────────────────────
 * Deploy order: Registry → xPNTsFactory → MySBT → GTokenAuthorization
 * xPNTsFactory has no dependency on GToken/GTokenAuthorization — no circular dep.
 *
 * @dev EIP-712 domain: name="GToken", version="1"
 */
contract GTokenAuthorization is GToken, EIP712 {

    // ─── Type hashes ───────────────────────────────────────────────────────
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,"
        "uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    // Distinct typehash prevents replaying a receiveWith sig as a transferWith
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,"
        "uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );
    bytes32 public constant CANCEL_AUTHORIZATION_TYPEHASH = keccak256(
        "CancelAuthorization(address authorizer,bytes32 nonce)"
    );

    // ─── RC-1 ──────────────────────────────────────────────────────────────
    uint256 public constant MAX_AUTH_VALIDITY = 5 minutes;

    // ─── RC-2 ──────────────────────────────────────────────────────────────
    ISBT          public immutable mySBT;
    IxPNTsFactory public immutable factory;

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
    error CallerMustBeRecipient();

    // ─── Constructor ───────────────────────────────────────────────────────
    /**
     * @param cap_      Token hard cap (e.g. 21_000_000 * 1e18)
     * @param mySBT_    MySBT contract — balanceOf(to) > 0 satisfies RC-2
     * @param factory_  xPNTsFactory — factory.isXPNTs(token) && balanceOf(to) > 0 satisfies RC-2
     *                  Deploy order: xPNTsFactory must exist before GTokenAuthorization.
     *                  Passing a wrong address here is permanent (immutable).
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

    // ─── EIP-3009 public API ───────────────────────────────────────────────

    /**
     * @notice Gasless transfer: any relay may call on behalf of `from`.
     * @param xPNTsToken  Factory-issued xPNTs token the relay asserts `to` holds.
     *                    Pass address(0) to rely on SBT path alone.
     *                    Not included in the EIP-712 signature (gate-check only).
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
        _execute(
            TRANSFER_WITH_AUTHORIZATION_TYPEHASH,
            from, to, value, validAfter, validBefore, nonce, xPNTsToken, signature
        );
    }

    /**
     * @notice Gasless transfer where only the recipient may submit the authorization.
     *         Prevents front-running for atomic contract flows (deposit, wrap, etc.).
     *         msg.sender must equal `to`.
     */
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        address xPNTsToken,
        bytes calldata signature
    ) external {
        if (msg.sender != to) revert CallerMustBeRecipient();
        _execute(
            RECEIVE_WITH_AUTHORIZATION_TYPEHASH,
            from, to, value, validAfter, validBefore, nonce, xPNTsToken, signature
        );
    }

    /**
     * @notice Permanently cancel an unused nonce so it can never be executed.
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
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError || recovered != authorizer)
            revert InvalidSignature();

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

    // ─── Internal ─────────────────────────────────────────────────────────

    /**
     * @dev Shared execution path for both transfer and receive variants.
     *      Gas-optimal check order:
     *        1. time window  (arithmetic only)
     *        2. nonce        (1 SLOAD)
     *        3. signature    (ecrecover, ~3k gas)
     *        4. RC-2         (≤3 external calls — only reached on valid sigs)
     */
    function _execute(
        bytes32 typeHash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        address xPNTsToken,
        bytes calldata signature
    ) internal {
        // 1. RC-1: time window
        if (validBefore <= validAfter)                      revert AuthorizationExpired();
        if (validBefore - validAfter > MAX_AUTH_VALIDITY)   revert AuthorizationWindowTooLong();
        if (block.timestamp <= validAfter)                  revert AuthorizationNotYetValid();
        if (block.timestamp >= validBefore)                 revert AuthorizationExpired();

        // 2. Nonce
        if (_authStates[from][nonce] != AuthorizationState.Unused)
            revert AuthorizationUsedOrCanceled();

        // 3. Signature — tryRecover unifies all ECDSA failures under InvalidSignature()
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(
            typeHash, from, to, value, validAfter, validBefore, nonce
        )));
        (address recovered, ECDSA.RecoverError err,) = ECDSA.tryRecover(digest, signature);
        if (err != ECDSA.RecoverError.NoError || recovered != from) revert InvalidSignature();

        // 4. RC-2: short-circuit on SBT to avoid unnecessary factory/token calls
        if (mySBT.balanceOf(to) == 0) {
            if (
                xPNTsToken == address(0) ||
                !factory.isXPNTs(xPNTsToken) ||
                IERC20(xPNTsToken).balanceOf(to) == 0
            ) revert RecipientNotInProtocol();
        }

        _authStates[from][nonce] = AuthorizationState.Used;
        emit AuthorizationUsed(from, nonce);
        _transfer(from, to, value);
    }
}
