// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Solidity counterpart of scanLogs/replay in script/governance/check-timelock-roles.mjs:
///      scan from the verified deployment block through the fork head, replay grants/revokes,
///      require exact holder sets and cross-check live state. RPC errors fail closed.
///      Exclusivity is proven from event history: a non-standard constructor could write roles
///      without emitting events, even with the default runtime. This procedure therefore requires
///      deployment by this runbook using the default artifact (docs/release/a3a-precheck/README.md).
///      Runtime equality does not bind creation code or exclude such silent constructor writes.
abstract contract TimelockRoleHistory is Script {
    bytes32 internal constant ROLE_GRANTED = keccak256("RoleGranted(bytes32,address,address)");
    bytes32 internal constant ROLE_REVOKED = keccak256("RoleRevoked(bytes32,address,address)");

    struct RoleHolder {
        bytes32 role;
        address account;
        bool active;
    }

    function _readTimelockRoleLogs(address timelock) internal virtual returns (Vm.Log[] memory logs) {
        uint256 from = _timelockDeploymentBlock();
        uint256 head = block.number;
        require(from > 0 && from <= head, "timelock: invalid deployment block");
        // As in the existing JS scanner, prove the range starts at creation, not at a later
        // grant chosen to omit an initial holder. Requires historical code access from the RPC.
        require(
            _historicalCode(timelock, from).length > 0 && _historicalCode(timelock, from - 1).length == 0,
            "timelock: deployment block depth probe failed"
        );

        logs = new Vm.Log[](0);
        uint256 constructorGrants;
        for (uint256 start = from; start <= head;) {
            uint256 end = start + 9999 < head ? start + 9999 : head;
            Vm.EthGetLogs[] memory batch = _timelockLogBatch(start, end, timelock);
            Vm.Log[] memory combined = new Vm.Log[](logs.length + batch.length);
            for (uint256 i; i < logs.length; ++i) {
                combined[i] = logs[i];
            }
            for (uint256 i; i < batch.length; ++i) {
                Vm.EthGetLogs memory entry = batch[i];
                require(
                    !entry.removed && entry.emitter == timelock && entry.blockNumber >= start
                        && entry.blockNumber <= end,
                    "timelock: invalid history log"
                );
                if (i > 0) {
                    require(
                        entry.blockNumber > batch[i - 1].blockNumber
                            || (entry.blockNumber == batch[i - 1].blockNumber
                                && entry.logIndex > batch[i - 1].logIndex),
                        "timelock: unordered history"
                    );
                }
                Vm.Log memory log;
                log.topics = entry.topics;
                log.data = entry.data;
                log.emitter = entry.emitter;
                combined[logs.length + i] = log;
                if (entry.blockNumber == from) constructorGrants |= _expectedGrant(log, timelock, _governanceSafe());
            }
            logs = combined;
            if (end == head) break;
            start = end + 1;
        }
        require(constructorGrants == 15, "timelock: constructor grants missing from history");
    }

    function _timelockDeploymentBlock() internal view virtual returns (uint256) {
        return vm.envUint("TIMELOCK_DEPLOYMENT_BLOCK");
    }

    function _timelockLogBatch(uint256 start, uint256 end, address timelock)
        internal
        virtual
        returns (Vm.EthGetLogs[] memory)
    {
        return vm.eth_getLogs(start, end, timelock, new bytes32[](0));
    }

    function _historicalCode(address target, uint256 height) internal virtual returns (bytes memory) {
        return vm.rpc("eth_getCode", string.concat('["', vm.toString(target), '","', _blockQuantity(height), '"]'));
    }

    function _blockQuantity(uint256 height) internal pure returns (string memory) {
        bytes memory padded = bytes(vm.toString(bytes32(height)));
        uint256 start = 2;
        while (start < padded.length - 1 && padded[start] == "0") ++start;
        bytes memory quantity = new bytes(2 + padded.length - start);
        quantity[0] = "0";
        quantity[1] = "x";
        for (uint256 i = start; i < padded.length; ++i) {
            quantity[2 + i - start] = padded[i];
        }
        return string(quantity);
    }

    function _governanceSafe() internal pure virtual returns (address);

    function _expectedGrant(Vm.Log memory log, address timelock, address safe) internal pure returns (uint256) {
        if (log.emitter != timelock || log.topics.length != 4 || log.topics[0] != ROLE_GRANTED) return 0;
        bytes32 role = log.topics[1];
        address account = address(uint160(uint256(log.topics[2])));
        if (role == bytes32(0) && account == timelock) return 1;
        if (account != safe) return 0;
        if (role == keccak256("PROPOSER_ROLE")) return 2;
        if (role == keccak256("CANCELLER_ROLE")) return 4;
        if (role == keccak256("EXECUTOR_ROLE")) return 8;
        return 0;
    }

    function _requireExclusiveTimelockRoles(address timelock, address safe, Vm.Log[] memory logs) internal view {
        RoleHolder[] memory holders = new RoleHolder[](logs.length);
        uint256 count;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory log = logs[i];
            if (log.emitter != timelock || log.topics.length == 0) continue;
            if (log.topics[0] != ROLE_GRANTED && log.topics[0] != ROLE_REVOKED) continue;
            require(log.topics.length == 4, "timelock: malformed role log");
            bytes32 role = log.topics[1];
            require(
                role == bytes32(0) || role == keccak256("PROPOSER_ROLE") || role == keccak256("CANCELLER_ROLE")
                    || role == keccak256("EXECUTOR_ROLE"),
                "timelock: unknown role in history"
            );
            address account = address(uint160(uint256(log.topics[2])));
            uint256 slot;
            while (slot < count && (holders[slot].role != role || holders[slot].account != account)) ++slot;
            if (slot == count) holders[count++] = RoleHolder(role, account, false);
            holders[slot].active = log.topics[0] == ROLE_GRANTED;
        }
        uint256 active;
        for (uint256 i; i < count; ++i) {
            RoleHolder memory holder = holders[i];
            (bool ok, bytes memory result) =
                timelock.staticcall(abi.encodeWithSignature("hasRole(bytes32,address)", holder.role, holder.account));
            require(
                ok && result.length == 32 && abi.decode(result, (bool)) == holder.active,
                "timelock: history != live role state"
            );
            if (!holder.active) continue;
            require(holder.account == (holder.role == bytes32(0) ? timelock : safe), "timelock: unexpected role holder");
            ++active;
        }
        require(active == 4, "timelock: history must establish all four exclusive roles");
    }
}
