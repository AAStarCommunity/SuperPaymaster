// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockPNT - Mock PNT Token for Testing
 * @notice Simple ERC20 implementation for testing SuperPaymaster V3
 * @dev Standard ERC20 with mint/burn for testing
 */
contract MockPNT is ERC20 {
    uint8 private _decimals;

    /**
     * @notice Create MockPNT with 18 decimals by default
     */
    constructor() ERC20("Mock PNT Token", "MPNT") {
        _decimals = 18;
    }

    /**
     * @notice Mint tokens to an address
     * @param to Recipient address
     * @param amount Amount to mint (in wei)
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @notice Burn tokens from caller
     * @param amount Amount to burn
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    /**
     * @notice Burn tokens from an address (for testing)
     * @param from Address to burn from
     * @param amount Amount to burn
     */
    function burnFrom(address from, uint256 amount) external {
        _burn(from, amount);
    }

    /**
     * @notice Override decimals
     */
    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}
