// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * @title IERC3009 - EIP-3009 Transfer With Authorization Interface
 * @notice Minimal interface for EIP-3009 compliant tokens (e.g., USDC v2.2+)
 * @dev Used by SuperPaymaster for x402 payment settlement.
 *      Some implementations use (v, r, s) instead of bytes signature.
 *      For v5.2, we use the bytes version supported by USDC v2.2+.
 */
interface IERC3009 {
    /**
     * @notice Execute a transfer with a signed authorization
     * @param from     Payer's address (authorizer)
     * @param to       Payee's address
     * @param value    Amount to transfer
     * @param validAfter  Earliest timestamp the authorization is valid
     * @param validBefore Latest timestamp the authorization is valid
     * @param nonce    Unique nonce to prevent replay
     * @param signature  Packed (v, r, s) or EIP-2098 compact signature
     */
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes calldata signature
    ) external;
}
