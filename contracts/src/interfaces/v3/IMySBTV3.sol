// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title IMySBTV3
 * @notice Interface for MySBT v3.0.0 - Minimal role-based SBT minting
 * @dev Single responsibility: Mint SBTs for Registry role system
 *      All financial operations (staking/burning) handled by Registry
 */
interface IMySBTV3 {
    // ====================================
    // Core Minting Functions (v3.0.0)
    // ====================================

    /**
     * @notice Mint SBT for role registration (called by Registry only)
     * @dev Self-service registration: user registers via Registry.registerRole()
     * @param user User address to receive SBT
     * @param roleId Role identifier (bytes32)
     * @param roleData Role-specific metadata (ABI-encoded)
     * @return tokenId Token ID (new or existing)
     * @return isNewMint True if new SBT was minted
     */
    function mintForRole(address user, bytes32 roleId, bytes calldata roleData)
        external
        returns (uint256 tokenId, bool isNewMint);

    /**
     * @notice Admin airdrop (called by Registry only)
     * @dev DAO-paid minting: Registry.safeMintForRole() → this function
     *      Registry handles all financial operations (staking/burning)
     * @param user User address to receive SBT
     * @param roleId Role identifier
     * @param roleData Role-specific metadata
     * @return tokenId Token ID (new or existing)
     * @return isNewMint True if new SBT was minted
     */
    function airdropMint(address user, bytes32 roleId, bytes calldata roleData)
        external
        returns (uint256 tokenId, bool isNewMint);

    // ====================================
    // View Functions
    // ====================================

    /**
     * @notice Get user's SBT token ID
     * @param user User address
     * @return tokenId Token ID (0 if no SBT)
     */
    function getUserSBT(address user) external view returns (uint256 tokenId);

    /**
     * @notice Verify user has active membership in community
     * @param user User address
     * @param community Community address
     * @return isValid True if user has active membership
     */
    function verifyCommunityMembership(address user, address community)
        external
        view
        returns (bool isValid);

    /**
     * @notice Record user activity (called by Paymaster)
     * @param user User address
     */
    function recordActivity(address user) external;

    /**
     * @notice Deactivate user membership in community (called by Registry only)
     * @param user User address
     * @param community Community address
     */
    function deactivateMembership(address user, address community) external;
}
