// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "src/interfaces/v3/IMySBT.sol";

contract MockSBT is IMySBT {
    function airdropMint(address to, bytes32 roleId, bytes calldata data) external override returns (uint256, bool) {
        return (1, true);
    }
    function mintForRole(address to, bytes32 roleId, bytes calldata data) external override returns (uint256, bool) {
        return (1, true);
    }
    function deactivateMembership(address user, address community) external override {}
    function burnSBT(address user) external override {}
    
    function getUserSBT(address user) external view override returns (uint256 tokenId) { return 0; }
    function getSBTData(uint256 tokenId) external view override returns (SBTData memory data) {
        return SBTData(address(0), address(0), 0, 0);
    }
    function verifyCommunityMembership(address user, address community) external view override returns (bool isValid) {
        return true;
    }
}
