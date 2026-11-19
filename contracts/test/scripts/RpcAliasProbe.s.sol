// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/// @notice Test-only probe: proves forge script reaches the node through the foundry.toml
///         `deploylive` rpc_endpoints alias (script/rehearsal/test_ddf7.py).
contract RpcAliasProbe {
    function run() external view returns (uint256 chainId) {
        chainId = block.chainid;
    }
}
