// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

/**
 * @title Interfaces
 * @notice Shared interfaces for SuperPaymaster v2.0 system
 */

// ====================================
// GToken Staking Interface
// ====================================

interface IGTokenStaking {
    function lockStake(address operator, uint256 amount) external;
    function slash(address operator, uint256 amount, string memory reason) external;
    function stake(uint256 amount) external returns (uint256 shares);
}

// ====================================
// GToken Interface
// ====================================

interface IGToken {
    function burn(uint256 amount) external;
}

// ====================================
// xPNTs Token Interface
// ====================================

interface IxPNTsToken {
    function burn(address from, uint256 amount) external;
}

// ====================================
// SuperPaymaster Interface
// ====================================

interface ISuperPaymaster {
    enum SlashLevel {
        WARNING,
        MINOR,
        MAJOR
    }

    function executeSlashWithBLS(
        address operator,
        SlashLevel level,
        bytes memory proof
    ) external;
}

// ====================================
// DVT Validator Interface
// ====================================

interface IDVTValidator {
    function markProposalExecuted(uint256 proposalId) external;
}

// ====================================
// BLS Aggregator Interface
// ====================================

interface IBLSAggregator {
    function verifyAndExecute(
        uint256 proposalId,
        address operator,
        uint8 slashLevel,
        address[] memory validators,
        bytes[] memory signatures
    ) external;
}
