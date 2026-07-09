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
contract LivenessRegistry is Ownable, ILivenessRegistry {
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
    function attestLiveness() external {
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
    ///      epoch reproduces the exact live-set for that epoch. `last + _livenessWindow` cannot
    ///      overflow: `last <= block.number` and `_livenessWindow <= MAX_LIVENESS_WINDOW`.
    function isOffline(address operator) public view returns (bool) {
        uint256 last = _lastLive[operator];
        if (last == 0) return true; // never attested ⇒ offline (must prove liveness before counting)
        return block.number > last + _livenessWindow;
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
