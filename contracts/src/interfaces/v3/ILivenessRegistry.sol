// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

/// @title ILivenessRegistry — objective, on-chain operator liveness signal (CC-29)
/// @author SuperPaymaster (DVT cross-repo program; hub CC-29, YetAnotherAA-Validator #202)
/// @notice On-chain source of truth for "is an operator live?". Operators self-attest by calling
///         {attestLiveness}; DVT nodes read {isOffline} / {lastLive} to compute the *live-set*
///         (the quorum denominator) for the real malicious-slash paths (credit ①, over-issue ③).
///
/// @dev WHY THIS EXISTS — offline is NOT slashed by consensus. #202 established that liveness-slash
///      based on gossip absence is a *subjective* fact (partition / clock skew / collusion can
///      wrongly convict a live node). This registry turns liveness into an *objective, globally
///      verifiable on-chain fact*: `isOffline(op) == blockNumber > lastLive[op] + livenessWindow`.
///      Because that is deterministic, it needs no BLS quorum to "convict" — an offline operator is
///      simply auto-jailed: excluded from the live-set (and thus from rewards / the quorum
///      denominator) until it attests again. There is NO offline stake-slash and NO offline
///      proof-of-consensus. The BLS-quorum slash pipeline stays reserved for provable malice.
///
/// @dev DETERMINISM CONTRACT (the reason {isOffline} takes no block argument): {isOffline} compares
///      against `block.number` — the block the call executes against. A DVT node pins its read to a
///      finalized epoch block (`eth_call ... blockTag=epoch`); the archive node then evaluates the
///      view with `block.number == epoch` and historical state, so every co-signer reads the SAME
///      live-set for that epoch. Passing a caller-supplied "finalizedBlock" argument would reopen a
///      subjective input; using `block.number` closes it. Consumers MUST read against a finalized
///      block for cross-node agreement.
interface ILivenessRegistry {
    // ─────────────────────────────────────────────────────────────────────────
    // Events
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Emitted whenever an operator proves liveness. `atBlock` == the recorded lastLive.
    event LivenessAttested(address indexed operator, uint256 atBlock);

    /// @notice Emitted when governance changes the fleet-wide liveness window (in blocks).
    event LivenessWindowUpdated(uint256 oldWindow, uint256 newWindow);

    // ─────────────────────────────────────────────────────────────────────────
    // Errors
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice The proposed window is outside [MIN_LIVENESS_WINDOW, MAX_LIVENESS_WINDOW].
    error InvalidWindow(uint256 window);

    /// @notice The freshness anchor is not in `[block.number - MAX_ATTEST_ANCHOR_AGE, block.number-1]`.
    error StaleAnchor(uint256 anchorBlock);

    /// @notice `anchorHash` does not equal `blockhash(anchorBlock)` (or the anchor hash is unavailable).
    error BadAnchorHash(uint256 anchorBlock);

    // ─────────────────────────────────────────────────────────────────────────
    // Operator write
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Prove the caller is live *now*. Records `lastLive[msg.sender] = block.number`.
    /// @param anchorBlock a recent block in `[block.number - MAX_ATTEST_ANCHOR_AGE, block.number - 1]`.
    /// @param anchorHash  must equal `blockhash(anchorBlock)`.
    /// @dev FRESHNESS BINDING (M-01): the caller must echo the hash of a recent block. A blockhash is
    ///      unpredictable until its block exists, and `blockhash()` only exposes the last 256 blocks,
    ///      so a transaction CANNOT be pre-signed to cover a future period — the signer must have
    ///      observed a block within the last `MAX_ATTEST_ANCHOR_AGE` blocks. This ties "live" to
    ///      recent signing capability and defeats a keeper replaying a batch of stale, pre-authorized
    ///      attestations to keep an abandoned-key operator in the live-set. (It does NOT, by itself,
    ///      stop an operator whose key is genuinely online but which refuses to co-sign slashes — that
    ///      residual griefer is caught at the DVT layer by excluding recent non-participants.)
    ///      Still cheap: one `blockhash` read + one warm SSTORE. Permissionless; consumers decide which
    ///      addresses count. A v2 MAY add a BLS-aggregated batch form.
    function attestLiveness(uint256 anchorBlock, bytes32 anchorHash) external;

    // ─────────────────────────────────────────────────────────────────────────
    // DVT / consumer reads (pin to a finalized block for cross-node determinism)
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Block number of `operator`'s most recent attestation (0 = never attested).
    /// @dev Exposed for forensics / alerting (who went offline, from which block) and to make the
    ///      live-set denominator auditable. Not part of any slash content-address (no offline slash).
    function lastLive(address operator) external view returns (uint256);

    /// @notice True iff `operator` is offline as of the block this call executes against.
    /// @dev `never attested (lastLive == 0)` ⇒ offline (must prove liveness before it counts).
    ///      Otherwise `block.number > lastLive[operator] + livenessWindow()`. See the DETERMINISM
    ///      CONTRACT above: pin `blockTag` to a finalized epoch for cross-node agreement.
    function isOffline(address operator) external view returns (bool);

    /// @notice Batch form of {isOffline} — one call to build a full live-set denominator.
    function areOffline(address[] calldata operators) external view returns (bool[] memory);

    /// @notice Fleet-wide liveness window, in blocks. offline ⇔ `blockNumber − lastLive > window`.
    /// @dev Governance-set and identical for the whole DVT fleet (NOT per-community) so every
    ///      co-signer computes the same live-set; DVT reads it (pinned to the same epoch block).
    function livenessWindow() external view returns (uint256);

    // ─────────────────────────────────────────────────────────────────────────
    // Governance
    // ─────────────────────────────────────────────────────────────────────────

    /// @notice Set the fleet-wide liveness window (blocks). Owner-only; owner SHOULD be a
    ///         TimelockController / multisig because SHRINKING the window is fleet-sensitive
    ///         (a sudden shrink can flip many operators to offline at once). Bounded to
    ///         [MIN_LIVENESS_WINDOW, MAX_LIVENESS_WINDOW] as a fat-finger guard.
    function setLivenessWindow(uint256 newWindow) external;

    /// @notice Lower bound on {livenessWindow} — blocks a value so small a single missed ping would
    ///         mass-jail the fleet.
    function MIN_LIVENESS_WINDOW() external view returns (uint256);

    /// @notice Upper bound on {livenessWindow} — fat-finger guard against an absurd value.
    function MAX_LIVENESS_WINDOW() external view returns (uint256);

    /// @notice Max age (in blocks) of the freshness anchor {attestLiveness} may reference. Bounded by
    ///         the EVM's 256-block `blockhash` window.
    function MAX_ATTEST_ANCHOR_AGE() external view returns (uint256);
}
