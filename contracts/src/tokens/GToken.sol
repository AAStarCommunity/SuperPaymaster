// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/extensions/ERC20Capped.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import { IVersioned } from "src/interfaces/IVersioned.sol";

/**
 * @title GToken v2.1.0 - Governance Token with Burnable Support
 * @notice ERC20 governance token with minting cap, burn capability, and version() interface
 * @dev Extends ERC20Capped and ERC20Burnable for complete lifecycle management
 *
 * Version: 2.1.0
 * Deployment Date: 2025-12-31
 * 
 * Key Features:
 * - Hard Cap: 21,000,000 GToken maximum supply
 * - Burnable: True token destruction (totalSupply decreases)
 * - Auto-Remint Space: burn() creates new minting capacity
 * - Governance: DAO-controlled minting
 */
contract GToken is ERC20Capped, ERC20Burnable, Ownable, IVersioned {

    function version() external pure override returns (string memory) {
        return "GToken-2.1.2";
    }

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

    /**
     * @notice Get remaining mintable supply
     * @return Amount of tokens that can still be minted before reaching cap
     * @dev This value increases when tokens are burned
     */
    function remainingMintableSupply() external view returns (uint256) {
        return cap() - totalSupply();
    }

    /**
     * @dev Override required by Solidity for multiple inheritance
     * @notice Handles token transfers with cap enforcement
     */
    function _update(address from, address to, uint256 value) 
        internal 
        virtual 
        override(ERC20, ERC20Capped) 
    {
        super._update(from, to, value);
    }
}
