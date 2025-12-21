// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

contract MockSBT {
    function airdropMint(address to, bytes32 roleId, bytes calldata data) external returns (uint256, uint256) {
        return (1, 1);
    }
    function mintForRole(address to, bytes32 roleId, bytes calldata data) external returns (uint256, uint256) {
        return (1, 1);
    }
    function deactivateMembership(address user, address community) external {}
}
