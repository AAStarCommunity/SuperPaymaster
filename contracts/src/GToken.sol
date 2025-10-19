// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/extensions/ERC20Capped.sol";
import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";

/**
 * @title GovernanceToken
 * @dev An ERC20 token with a fixed cap of 21 million for governance purposes.
 * The owner can mint tokens up to the cap.
 */
contract GovernanceToken is ERC20, ERC20Capped, Ownable {
    /**
     * @dev Sets the values for {name}, {symbol}, and {cap}.
     * The owner is set to the deploying account.
     */
    constructor()
        ERC20("Governance Token", "GToken")
        ERC20Capped(21_000_000 * (10**18))
        Ownable(msg.sender)
    {}

    /**
     * @dev Creates `amount` tokens and assigns them to `to`, increasing
     * the total supply.
     *
     * Requirements:
     *
     * - `to` cannot be the zero address.
     * - The caller must be the owner.
     * - The minting must not exceed the cap.
     */
    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }

    /**
     * @dev Overrides the internal _update function to enforce the cap.
     */
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Capped)
    {
        super._update(from, to, value);
    }
}
