// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title ISBT - Soul-Bound Token Interface
 * @notice Interface for checking SBT (non-transferable NFT) ownership
 * @dev Designed to work with standard ERC721 SBT implementations
 */
interface ISBT {
    /**
     * @notice Check if an address holds at least one SBT
     * @param account Address to check
     * @return balance Number of SBTs held by the account
     * @dev For SBTs, this should typically return 0 or 1
     */
    function balanceOf(address account) external view returns (uint256 balance);

    /**
     * @notice Get the owner of a specific token ID (optional, for ERC721 compatibility)
     * @param tokenId The token ID to query
     * @return owner Address of the token owner
     */
    function ownerOf(uint256 tokenId) external view returns (address owner);

    /**
     * @notice Check if a token exists (optional)
     * @param tokenId The token ID to check
     * @return exists True if token exists
     */
    function exists(uint256 tokenId) external view returns (bool exists);
}
