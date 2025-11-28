// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title Shared Configuration for Mycelium Protocol v3
 * @notice Central configuration for all v3 contracts
 * @dev Shared constants and configuration across Registry, MySBT, GTokenStaking
 */

contract SharedConfig {
    // ====================================
    // Version Information
    // ====================================

    string public constant PROTOCOL_VERSION = "3.0.0";
    uint256 public constant PROTOCOL_VERSION_CODE = 30000;

    // ====================================
    // Protocol Constants
    // ====================================

    /// @notice Burn address for token destruction
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Minimum stake requirement
    uint256 public constant MIN_STAKE = 0.01 ether;

    /// @notice Unstake delay (7 days)
    uint256 public constant UNSTAKE_DELAY = 7 days;

    // ====================================
    // Default Role Configuration
    // ====================================

    /// @notice ENDUSER role identifier
    bytes32 public constant ROLE_ENDUSER = keccak256("ENDUSER");

    /// @notice COMMUNITY role identifier
    bytes32 public constant ROLE_COMMUNITY = keccak256("COMMUNITY");

    /// @notice PAYMASTER role identifier
    bytes32 public constant ROLE_PAYMASTER = keccak256("PAYMASTER");

    /// @notice SUPER role identifier
    bytes32 public constant ROLE_SUPER = keccak256("SUPER");

    // ====================================
    // Role Configuration: ENDUSER
    // ====================================

    uint256 public constant ENDUSER_MIN_STAKE = 0.3 ether;
    uint256 public constant ENDUSER_ENTRY_BURN = 0.1 ether;
    uint256 public constant ENDUSER_EXIT_FEE_PERCENT = 17;
    uint256 public constant ENDUSER_MIN_EXIT_FEE = 0.05 ether;

    // ====================================
    // Role Configuration: COMMUNITY
    // ====================================

    uint256 public constant COMMUNITY_MIN_STAKE = 30 ether;
    uint256 public constant COMMUNITY_ENTRY_BURN = 3 ether;
    uint256 public constant COMMUNITY_EXIT_FEE_PERCENT = 10;
    uint256 public constant COMMUNITY_MIN_EXIT_FEE = 0.3 ether;

    // ====================================
    // Role Configuration: PAYMASTER
    // ====================================

    uint256 public constant PAYMASTER_MIN_STAKE = 30 ether;
    uint256 public constant PAYMASTER_ENTRY_BURN = 3 ether;
    uint256 public constant PAYMASTER_EXIT_FEE_PERCENT = 10;
    uint256 public constant PAYMASTER_MIN_EXIT_FEE = 0.3 ether;

    // ====================================
    // Role Configuration: SUPER
    // ====================================

    uint256 public constant SUPER_MIN_STAKE = 50 ether;
    uint256 public constant SUPER_ENTRY_BURN = 5 ether;
    uint256 public constant SUPER_EXIT_FEE_PERCENT = 10;
    uint256 public constant SUPER_MIN_EXIT_FEE = 0.5 ether;

    // ====================================
    // Reputation Configuration
    // ====================================

    /// @notice Base reputation score
    uint256 public constant BASE_REPUTATION = 20;

    /// @notice Reputation points per 0.01 GT burned
    uint256 public constant BURN_REPUTATION_MULTIPLIER = 100; // 1 point per 0.01 ether

    /// @notice Activity bonus multiplier
    uint256 public constant ACTIVITY_BONUS_MULTIPLIER = 1;

    // ====================================
    // Gas Optimization Constants
    // ====================================

    /// @notice Target gas usage for registerRole (< 150k)
    uint256 public constant TARGET_REGISTER_GAS = 150000;

    /// @notice Target gas usage for exitRole
    uint256 public constant TARGET_EXIT_GAS = 100000;

    // ====================================
    // Helper Functions
    // ====================================

    /**
     * @notice Get role configuration by role ID
     * @param roleId Role identifier
     * @return minStake Minimum stake amount
     * @return entryBurn Entry burn amount
     * @return exitFeePercent Exit fee percentage
     * @return minExitFee Minimum exit fee
     */
    function getRoleConfig(bytes32 roleId)
        public
        pure
        returns (
            uint256 minStake,
            uint256 entryBurn,
            uint256 exitFeePercent,
            uint256 minExitFee
        )
    {
        if (roleId == ROLE_ENDUSER) {
            return (
                ENDUSER_MIN_STAKE,
                ENDUSER_ENTRY_BURN,
                ENDUSER_EXIT_FEE_PERCENT,
                ENDUSER_MIN_EXIT_FEE
            );
        } else if (roleId == ROLE_COMMUNITY) {
            return (
                COMMUNITY_MIN_STAKE,
                COMMUNITY_ENTRY_BURN,
                COMMUNITY_EXIT_FEE_PERCENT,
                COMMUNITY_MIN_EXIT_FEE
            );
        } else if (roleId == ROLE_PAYMASTER) {
            return (
                PAYMASTER_MIN_STAKE,
                PAYMASTER_ENTRY_BURN,
                PAYMASTER_EXIT_FEE_PERCENT,
                PAYMASTER_MIN_EXIT_FEE
            );
        } else if (roleId == ROLE_SUPER) {
            return (
                SUPER_MIN_STAKE,
                SUPER_ENTRY_BURN,
                SUPER_EXIT_FEE_PERCENT,
                SUPER_MIN_EXIT_FEE
            );
        } else {
            revert("Unknown role");
        }
    }

    /**
     * @notice Calculate exit fee for a role
     * @param roleId Role identifier
     * @param lockedAmount Amount being unlocked
     * @return exitFee Calculated exit fee
     */
    function calculateExitFee(bytes32 roleId, uint256 lockedAmount)
        public
        pure
        returns (uint256 exitFee)
    {
        (, , uint256 feePercent, uint256 minFee) = getRoleConfig(roleId);

        uint256 percentageFee = (lockedAmount * feePercent) / 100;
        return percentageFee < minFee ? minFee : percentageFee;
    }

    /**
     * @notice Calculate reputation score for a user
     * @param burnAmount Total amount burned by user
     * @return reputation Calculated reputation score
     */
    function calculateReputation(uint256 burnAmount) public pure returns (uint256 reputation) {
        return BASE_REPUTATION + (burnAmount * BURN_REPUTATION_MULTIPLIER) / (0.01 ether);
    }

    /**
     * @notice Check if an address is a valid role ID
     * @param roleId Role identifier
     * @return isValid True if valid role ID
     */
    function isValidRole(bytes32 roleId) public pure returns (bool isValid) {
        return roleId == ROLE_ENDUSER || roleId == ROLE_COMMUNITY || roleId == ROLE_PAYMASTER
            || roleId == ROLE_SUPER;
    }
}
