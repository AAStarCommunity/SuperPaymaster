// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

/**
 * @title IERC3009 - EIP-3009 Transfer With Authorization Interface
 * @notice Minimal interface for EIP-3009 compliant tokens (e.g., USDC v2.2+)
 * @dev Used by SuperPaymaster for x402 payment settlement.
 */
interface IERC3009 {
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
