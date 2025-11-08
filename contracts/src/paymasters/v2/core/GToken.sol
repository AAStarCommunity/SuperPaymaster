// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/extensions/ERC20Capped.sol";
import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";

/**
 * @title GToken v2.0.0 - Governance Token with VERSION interface
 * @notice ERC20 governance token with minting cap and VERSION tracking
 * @dev Extends ERC20Capped with VERSION interface for V2 compatibility
 *
 * Version: 2.0.0
 * Deployment Date: 2025-11-01
 */
contract GToken is ERC20Capped, Ownable {

    /// @notice Contract version string
    string public constant VERSION = "2.0.0";

    /// @notice Contract version code (major * 10000 + minor * 100 + patch)
    uint256 public constant VERSION_CODE = 20000;

    /**
     * @notice Initialize GToken with cap
     * @param cap_ Maximum supply (21,000,000 * 10^18)
     */
    constructor(uint256 cap_)
        ERC20("Governance Token", "GToken")
        ERC20Capped(cap_)
        Ownable(msg.sender)
    {
        // Constructor is empty, all initialization done in parent contracts
    }

    /**
     * @notice Mint new tokens (only owner)
     * @param to Recipient address
     * @param amount Amount to mint
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
