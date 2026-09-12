// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.33;

import "@account-abstraction-v7/interfaces/IPaymaster.sol";
import "@account-abstraction-v7/interfaces/PackedUserOperation.sol";

/**
 * D5 gate G1 / B0 — counter-examples that prove the bundler's ERC-7562 tracer actually runs
 * on the chain used for the B layer (docs/design/aoa-balance-mode/D5-plan.md §3.2).
 * A bundler in safe mode MUST reject each violator with the named rule and MUST accept the
 * compliant control. If any violator is accepted, the tracer on that chain is not trustworthy.
 * These contracts are harness fixtures only; nothing here is deployed outside a local node.
 */

interface IStakeManagerLike {
    function addStake(uint32 unstakeDelaySec) external payable;
}

abstract contract B0PaymasterBase is IPaymaster {
    function postOp(PostOpMode, bytes calldata, uint256, uint256) external virtual {}
}

/// @notice Control: touches no storage, no banned opcode, empty context (needs no stake).
contract B0PmCompliant is B0PaymasterBase {
    function validatePaymasterUserOp(PackedUserOperation calldata, bytes32, uint256)
        external pure returns (bytes memory, uint256)
    {
        return ("", 0);
    }
}

/// @notice OP-011: banned opcode TIMESTAMP in validation.
contract B0PmTimestamp is B0PaymasterBase {
    function validatePaymasterUserOp(PackedUserOperation calldata, bytes32, uint256)
        external view returns (bytes memory, uint256)
    {
        return ("", block.timestamp == 0 ? 1 : 0);
    }
}

/// @notice STO-031: an UNSTAKED paymaster writing its own (entity) storage in validation.
contract B0PmUnstakedOwnStorage is B0PaymasterBase {
    uint256 public counter;
    function validatePaymasterUserOp(PackedUserOperation calldata, bytes32, uint256)
        external returns (bytes memory, uint256)
    {
        counter += 1;
        return ("", 0);
    }
}

/// @notice OP-070 (transient storage treated as storage): an UNSTAKED paymaster using TSTORE.
contract B0PmUnstakedTstore is B0PaymasterBase {
    function validatePaymasterUserOp(PackedUserOperation calldata, bytes32, uint256)
        external returns (bytes memory, uint256)
    {
        assembly { tstore(0, 1) }
        return ("", 0);
    }
}

/// @notice External contract whose storage the next violator writes.
contract B0Sink {
    mapping(bytes32 => uint256) public cell;
    function poke(bytes32 k) external { cell[k] = 1; }
}

/// @notice STO-021/032: even a STAKED paymaster may only touch slots associated with the sender
///         (or itself) in a non-entity contract; writing an unrelated slot must be rejected.
contract B0PmStakedExternalWrite is B0PaymasterBase {
    B0Sink public immutable SINK;
    constructor(B0Sink sink) { SINK = sink; }
    /// @notice Stake from this contract (the staked entity must be msg.sender of addStake).
    function stake(IStakeManagerLike ep, uint32 unstakeDelaySec) external payable {
        ep.addStake{value: msg.value}(unstakeDelaySec);
    }
    function validatePaymasterUserOp(PackedUserOperation calldata, bytes32, uint256)
        external returns (bytes memory, uint256)
    {
        SINK.poke(keccak256("b0.unassociated.slot"));
        return ("", 0);
    }
}
