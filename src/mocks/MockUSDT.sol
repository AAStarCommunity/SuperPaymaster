// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { ERC20 } from "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import { Ownable } from "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";

/// @title MockUSDT
/// @notice Mock USDT token for testing (6 decimals like real USDT)
contract MockUSDT is ERC20, Ownable {
    constructor() ERC20("Mock USDT", "USDT") Ownable(msg.sender) {}

    /// @notice Returns 6 decimals to match real USDT
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /// @notice Mint tokens to any address (for testing)
    /// @param to Recipient address
    /// @param amount Amount to mint (in 6 decimals)
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @notice Public faucet function for testing
    /// @param to Recipient address
    function faucet(address to) external {
        _mint(to, 10 * 10**6); // 10 USDT
    }
}
