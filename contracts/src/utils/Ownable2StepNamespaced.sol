// SPDX-License-Identifier: Apache-2.0
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;

import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";

/**
 * @title Ownable2StepNamespaced
 * @notice GOV-2 (spec 03 §10.7b, "GOV-2 规范（第 3 版）" A/B): two-step ownership transfer for the
 *         UUPS proxies SuperPaymaster and Registry, WITHOUT touching their sequential storage.
 * @dev    Both proxies inherit OZ v5.0.2's non-upgradeable `Ownable`: `_owner` is sequential slot 0
 *         and the next contract's state starts at slot 1. OZ `Ownable2Step` would insert
 *         `_pendingOwner` right after `_owner` and shift every later slot — FORBIDDEN (spec A).
 *         The pending owner therefore lives in an ERC-7201 namespaced slot:
 *           keccak256(abi.encode(uint256(keccak256("aastar.storage.Ownership2Step")) - 1)) & ~bytes32(uint256(0xff))
 *         This contract declares NO state variable, so the inheriting contract's sequential layout
 *         is byte-identical to the `Ownable` one (checked by scripts/check_storage_layout.py).
 *
 *         Behaviour (spec B.1–B.4):
 *           - transferOwnership(newOwner): owner only; records the nomination and emits
 *             OwnershipTransferStarted. newOwner == address(0) cancels. A second call replaces it.
 *           - acceptOwnership(): only the pending owner.
 *           - _transferOwnership: clears the nomination BEFORE changing the owner, so every path
 *             that changes the owner (accept, initialize, a future reinitializer) voids a stale
 *             nomination.
 *           - renounceOwnership(): always reverts.
 *
 *         SELECTOR SHADOWING (D5b-design §2.1): SuperPaymaster reaches its admin extension through
 *         fallback DELEGATECALL; a selector the core has is ALWAYS answered by the core. These
 *         overrides must therefore live in the core's inheritance chain (here), never only in the
 *         extension — otherwise the inherited single-step OZ `transferOwnership` would stay live.
 */
abstract contract Ownable2StepNamespaced is Ownable {
    /// @dev ERC-7201 slot of the pending owner (see contract NatSpec for the derivation).
    bytes32 internal constant OWNERSHIP_2STEP_SLOT =
        0xdb5a3168abaa6147a9f3a4cb66016161119d4d50b6393344d27120286f742a00;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);

    /// @notice renounceOwnership is disabled (GOV-2 B.4): an ownerless proxy can never be upgraded.
    error OwnershipRenounceDisabled();

    /// @notice The nominated owner; address(0) when there is no pending transfer.
    function pendingOwner() public view virtual returns (address p) {
        bytes32 slot = OWNERSHIP_2STEP_SLOT;
        assembly ("memory-safe") { p := sload(slot) }
    }

    /// @notice Start (or replace, or with address(0) cancel) a two-step ownership transfer.
    /// @dev    `onlyOwner` is written out explicitly: an override does NOT inherit modifiers.
    function transferOwnership(address newOwner) public virtual override onlyOwner {
        _setPendingOwner(newOwner);
        emit OwnershipTransferStarted(owner(), newOwner);
    }

    /// @notice Complete a transfer started by `transferOwnership`; callable only by the nominee.
    function acceptOwnership() public virtual {
        address sender = _msgSender();
        if (pendingOwner() != sender) revert OwnableUnauthorizedAccount(sender);
        _transferOwnership(sender);
    }

    /// @notice Always reverts (GOV-2 B.4).
    function renounceOwnership() public virtual override {
        revert OwnershipRenounceDisabled();
    }

    /// @dev Clears the nomination first, then changes the owner (GOV-2 B.3).
    function _transferOwnership(address newOwner) internal virtual override {
        _setPendingOwner(address(0));
        super._transferOwnership(newOwner);
    }

    function _setPendingOwner(address p) private {
        bytes32 slot = OWNERSHIP_2STEP_SLOT;
        assembly ("memory-safe") { sstore(slot, p) }
    }
}
