// SPDX-License-Identifier: Apache-2.0
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;

import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import { IVersioned } from "src/interfaces/IVersioned.sol";

/**
 * @title AOAProtocolRegistry
 * @notice Protocol-governed allowlists consulted by xPNTs v2 tokens when a community
 *         activates a SuperPaymaster, an auto-approved spender, or a credit tier source.
 * @dev    Spec: docs/design/aoa-balance-mode/03-final-spec.md §2.5, §9, §10.5.
 *         - KIND_SP: keyed by the proxy ADDRESS. SP is a UUPS proxy, so a codehash says
 *           nothing about its implementation; the implementation risk belongs to SP's
 *           upgrade governance (§10.5), not to this list.
 *         - KIND_SPENDER / KIND_TIER_SOURCE: governance must approve reviewed IMPLEMENTATION
 *           codehashes. A canonical EIP-1167 minimal proxy is resolved to its embedded
 *           implementation, because it cannot be upgraded (§9). Other targets are matched by
 *           their own runtime codehash, so governance MUST NOT approve an upgradeable proxy's
 *           runtime codehash: the registry accepts raw keys and cannot infer what bytecode a
 *           hash represents.
 *         Approval is only a NECESSARY condition. Genesis configuration checks it during token
 *         initialization; subsequent token changes also require their own 48 h propose/activate
 *         and re-check membership at activation time.
 *         Additions are time-locked after `seal()`; revocation is always immediate.
 */
contract AOAProtocolRegistry is Ownable, IVersioned {
    uint8 public constant KIND_SP = 0;
    uint8 public constant KIND_SPENDER = 1;
    uint8 public constant KIND_TIER_SOURCE = 2;
    uint256 public constant TIMELOCK = 48 hours;
    bytes32 private constant _EMPTY_CODE_HASH = keccak256("");

    /// @notice kind => key => approved
    mapping(uint8 => mapping(bytes32 => bool)) public approved;
    /// @notice kind => key => earliest execution time of a pending addition (0 = none)
    mapping(uint8 => mapping(bytes32 => uint64)) public pendingAt;
    /// @notice Before sealing, the owner may approve instantly (deployment bootstrap).
    bool public sealed_;

    event ApprovalProposed(uint8 indexed kind, bytes32 indexed key, uint64 eta);
    event ApprovalExecuted(uint8 indexed kind, bytes32 indexed key);
    event ApprovalRevoked(uint8 indexed kind, bytes32 indexed key);
    event Sealed();

    error InvalidKind();
    error InvalidKey();
    error AlreadySealed();
    error NotPending();
    error TimelockActive(uint64 eta);
    error TimelockTimestampOverflow(uint256 timestamp);

    constructor(address owner_) Ownable(owner_) {}

    function version() external pure override returns (string memory) {
        return "AOAProtocolRegistry-1.0.0";
    }

    /// @notice Bootstrap-only instant approval; unavailable once sealed.
    function bootstrapApprove(uint8 kind, bytes32 key) external onlyOwner {
        if (sealed_) revert AlreadySealed();
        _checkKind(kind);
        _checkApprovalKey(kind, key);
        approved[kind][key] = true;
        emit ApprovalExecuted(kind, key);
    }

    /// @notice Irreversibly turn on the addition time-lock.
    function seal() external onlyOwner {
        sealed_ = true;
        emit Sealed();
    }

    function proposeApproval(uint8 kind, bytes32 key) external onlyOwner {
        _checkKind(kind);
        _checkApprovalKey(kind, key);
        // `pendingAt` is uint64. Reject rather than truncate: wrapping the ETA would make a
        // nominally time-locked approval immediately executable at sufficiently large timestamps.
        if (block.timestamp > type(uint64).max - TIMELOCK) {
            revert TimelockTimestampOverflow(block.timestamp);
        }
        uint64 eta = uint64(block.timestamp + TIMELOCK);
        pendingAt[kind][key] = eta;
        emit ApprovalProposed(kind, key, eta);
    }

    function executeApproval(uint8 kind, bytes32 key) external {
        uint64 eta = pendingAt[kind][key];
        if (eta == 0) revert NotPending();
        if (block.timestamp < eta) revert TimelockActive(eta);
        delete pendingAt[kind][key];
        approved[kind][key] = true;
        emit ApprovalExecuted(kind, key);
    }

    function revokeApproval(uint8 kind, bytes32 key) external onlyOwner {
        _checkKind(kind);
        delete pendingAt[kind][key];
        approved[kind][key] = false;
        emit ApprovalRevoked(kind, key);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function spKey(address sp) public pure returns (bytes32) {
        return bytes32(uint256(uint160(sp)));
    }

    function isApprovedSP(address sp) external view returns (bool) {
        return approved[KIND_SP][spKey(sp)];
    }

    /// @notice True when the codehash resolved by `implCodehash(target)` is approved for `kind`.
    function isApprovedImpl(uint8 kind, address target) external view returns (bool) {
        if (kind == KIND_SP) return false; // SP is address-keyed, never codehash-keyed
        return approved[kind][implCodehash(target)];
    }

    /// @notice Codehash of `target`, resolving a canonical EIP-1167 minimal proxy to the
    ///         codehash of its embedded implementation. Any other target, including any other
    ///         proxy form, is NOT resolved and is checked by its own runtime codehash. Governance
    ///         must therefore never approve an upgradeable proxy's runtime codehash.
    function implCodehash(address target) public view returns (bytes32) {
        bytes memory c = target.code;
        if (c.length == 45) {
            bytes32 w0;
            bytes32 w1;
            assembly {
                w0 := mload(add(c, 0x20)) // bytes [0, 32)
                w1 := mload(add(c, 0x40)) // bytes [32, 45) in the high 13 bytes
            }
            // prefix 363d3d373d3d3d363d73 (10 bytes), suffix 5af43d82803e903d91602b57fd5bf3 (15 bytes)
            bool prefixOk = bytes10(w0) == bytes10(0x363d3d373d3d3d363d73);
            // suffix starts at byte 30: last 2 bytes of w0 + first 13 bytes of w1
            bool suffixOk = bytes2(w0 << 240) == bytes2(0x5af4)
                && bytes13(w1) == bytes13(0x3d82803e903d91602b57fd5bf3);
            if (prefixOk && suffixOk) {
                address impl = address(uint160(uint256(w0 >> 16)));
                return impl.codehash;
            }
        }
        return target.codehash;
    }

    function _checkKind(uint8 kind) private pure {
        if (kind > KIND_TIER_SOURCE) revert InvalidKind();
    }

    function _checkApprovalKey(uint8 kind, bytes32 key) private pure {
        // A zero implementation hash authorizes every not-yet-created account. The empty-code
        // hash authorizes every existing EOA and empty-runtime contract. Either can become a
        // malicious contract after activation at a deterministic address, so reject both.
        if (key == bytes32(0) || (kind != KIND_SP && key == _EMPTY_CODE_HASH)) revert InvalidKey();

        // SP keys are canonical left-zero-padded addresses. Reject unreachable/non-canonical
        // values so an approval cannot look populated while no address can actually match it.
        if (kind == KIND_SP && uint256(key) > type(uint160).max) revert InvalidKey();
    }
}
