// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import {Ownable} from "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import {ILivenessRegistry} from "../interfaces/v3/ILivenessRegistry.sol";

/// @title LivenessRegistry — objective on-chain operator liveness oracle (CC-29)
/// @notice Reference implementation of {ILivenessRegistry}. Operators self-attest; DVT reads the
///         resulting {isOffline}/{lastLive} (pinned to a finalized epoch block) to compute the
///         live-set / quorum denominator for the real malicious-slash paths. Offline is never
///         slashed by consensus — it auto-jails by exclusion (see the interface for the full model).
///
/// @dev UPGRADEABILITY DECISION — NON-UPGRADEABLE, single instance (mirrors {PolicyRegistry}).
///      This is a peripheral, read-only-from-DVT oracle with zero SuperPaymaster-core coupling.
///      Immutability removes a proxy-admin key as an attack surface and keeps the storage layout
///      permanently auditable. It deliberately does NOT touch the SuperPaymaster `OperatorConfig`
///      struct (a hot, UUPS-storage-sensitive slot). If a future hard requirement appears (e.g. a
///      BLS-aggregated batch attest), deploy v2 and re-point DVT — operators re-attest cheaply
///      (self-healing), so no state migration is needed.
///
/// @dev LIVENESS SEMANTIC (what "live" proves, and what it does NOT). {attestLiveness} proves the
///      operator's signing key produced a transaction within the last `MAX_ATTEST_ANCHOR_AGE` blocks
///      (enforced by the freshness binding — the caller must echo a recent, unpredictable
///      `blockhash`, so the tx cannot be pre-signed for the future). This ties "live" to RECENT
///      signing capability, defeating a keeper that replays a batch of stale pre-authorized
///      attestations to keep an abandoned-key operator counted in the live-set (quorum denominator) —
///      a denominator-inflation vector that could otherwise suppress a legitimate slash against a
///      colluder (CC-29 review M-01). It does NOT prove the full DVT stack is online: an operator
///      whose key is genuinely online but which refuses to co-sign slashes still attests fine; that
///      residual griefer is caught at the DVT layer by excluding recent non-participants from quorum,
///      NOT here. Offline itself carries NO slash — it only shrinks the live-set.
///
/// @dev GOVERNANCE — the window IS the definition of offline, so changing {livenessWindow}
///      deterministically RE-PARTITIONS the live-set at the next block, in BOTH directions and with
///      immediate effect: shrinking can mass-exclude live operators (quorum collapse); expanding
///      revives long-idle operators into the live-set WITHOUT a fresh attestation. Both are intended
///      governance actions, not bugs — which is exactly why the owner MUST be a TimelockController /
///      multisig (a sudden unilateral change is fleet-critical). {renounceOwnership} is disabled so
///      an adverse window can never be frozen in permanently; hand control over via {transferOwnership}.
contract LivenessRegistry is Ownable, ILivenessRegistry {
    /// @notice {renounceOwnership} is permanently disabled (see GOVERNANCE note).
    error RenounceDisabled();

    // ─────────────────────────────────────────────────────────────────────────
    // Bounds (fat-finger guards, NOT policy — ops pick the real value per target chain)
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc ILivenessRegistry
    /// @dev 100 blocks ≈ a few minutes on most chains; below this a single missed ping / RPC hiccup
    ///      could mass-jail the fleet.
    uint256 public constant MIN_LIVENESS_WINDOW = 100;

    /// @inheritdoc ILivenessRegistry
    /// @dev ~10M blocks: generous enough to effectively disable liveness on any chain if governance
    ///      chooses, while still bounding the field to an auditable magnitude.
    uint256 public constant MAX_LIVENESS_WINDOW = 10_000_000;

    /// @inheritdoc ILivenessRegistry
    /// @dev Fixed at the EVM's `blockhash` availability window (256). An attestation must anchor to a
    ///      block no older than this; older/current/future anchors have no readable `blockhash`.
    uint256 public constant MAX_ATTEST_ANCHOR_AGE = 256;

    // ─────────────────────────────────────────────────────────────────────────
    // Storage
    // ─────────────────────────────────────────────────────────────────────────

    /// @dev Fleet-wide window, in blocks. Read via {livenessWindow}.
    uint256 private _livenessWindow;

    /// @dev operator ⇒ block number of last attestation (0 = never attested).
    mapping(address => uint256) private _lastLive;

    // ─────────────────────────────────────────────────────────────────────────
    // Construction
    // ─────────────────────────────────────────────────────────────────────────

    /// @param governance owner authorized to change the window; SHOULD be a TimelockController /
    ///        multisig (shrinking the window is fleet-sensitive). Ownable reverts on the zero owner.
    /// @param initialWindow starting fleet-wide window in blocks; must be within bounds.
    constructor(address governance, uint256 initialWindow) Ownable(governance) {
        _setWindow(initialWindow);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Operator write
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc ILivenessRegistry
    function attestLiveness(uint256 anchorBlock, bytes32 anchorHash) external {
        // Freshness binding (M-01): anchor must be a recent PAST block whose hash the caller echoes.
        // `anchorBlock >= block.number` covers both the current block (hash not yet known) and any
        // future block. The subtraction is then safe (anchorBlock < block.number).
        if (anchorBlock >= block.number || block.number - anchorBlock > MAX_ATTEST_ANCHOR_AGE) {
            revert StaleAnchor(anchorBlock);
        }
        // In-range blocks always have a nonzero blockhash; the `== 0` guard is belt-and-suspenders and
        // also rejects a caller passing anchorHash == 0 for an out-of-window block (which returns 0).
        bytes32 h = blockhash(anchorBlock);
        if (h == bytes32(0) || h != anchorHash) revert BadAnchorHash(anchorBlock);

        _lastLive[msg.sender] = block.number;
        emit LivenessAttested(msg.sender, block.number);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Reads
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc ILivenessRegistry
    function lastLive(address operator) external view returns (uint256) {
        return _lastLive[operator];
    }

    /// @inheritdoc ILivenessRegistry
    /// @dev Uses `block.number` (the executing block) so an archival `eth_call` pinned to a finalized
    ///      epoch reproduces the exact live-set for that epoch. Written as `block.number - last` (NOT
    ///      `last + _livenessWindow`) so the arithmetic is overflow-proof for ALL inputs: `last <=
    ///      block.number` makes the subtraction safe, whereas `last + window` could in principle
    ///      overflow near `uint256.max`.
    function isOffline(address operator) public view returns (bool) {
        uint256 last = _lastLive[operator];
        if (last == 0) return true; // never attested ⇒ offline (must prove liveness before counting)
        return block.number - last > _livenessWindow;
    }

    /// @inheritdoc ILivenessRegistry
    function areOffline(address[] calldata operators) external view returns (bool[] memory out) {
        uint256 len = operators.length;
        out = new bool[](len);
        for (uint256 i; i < len; ++i) {
            out[i] = isOffline(operators[i]);
        }
    }

    /// @inheritdoc ILivenessRegistry
    function livenessWindow() external view returns (uint256) {
        return _livenessWindow;
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Governance
    // ─────────────────────────────────────────────────────────────────────────

    /// @inheritdoc ILivenessRegistry
    function setLivenessWindow(uint256 newWindow) external onlyOwner {
        _setWindow(newWindow);
    }

    /// @notice Disabled: renouncing ownership would freeze {livenessWindow} at its current value
    ///         forever, permanently locking the live-set partition — a governance footgun. Transfer
    ///         to a new timelock / multisig via {transferOwnership} instead. Always reverts.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @dev Shared bounds check + event; used by the constructor and {setLivenessWindow}.
    function _setWindow(uint256 newWindow) private {
        if (newWindow < MIN_LIVENESS_WINDOW || newWindow > MAX_LIVENESS_WINDOW) {
            revert InvalidWindow(newWindow);
        }
        uint256 old = _livenessWindow;
        _livenessWindow = newWindow;
        emit LivenessWindowUpdated(old, newWindow);
    }

    /// @notice Contract version (see CLAUDE.md versioning convention).
    function version() external pure returns (string memory) {
        return "LivenessRegistry-1.0.0";
    }
}
