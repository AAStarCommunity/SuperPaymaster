// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin-v5.0.2/contracts/token/ERC721/ERC721.sol";

/**
 * @title FaucetSBT
 * @dev Soul-Bound Token (SBT) for faucet - anyone can mint once
 */
contract FaucetSBT is ERC721 {
    uint256 private _nextTokenId;

    constructor() ERC721("Faucet Soul-Bound Token", "FSBT") {}

    /**
     * @dev Mint a new SBT to the caller
     * Each address can only mint once
     */
    function mint() public {
        require(balanceOf(msg.sender) == 0, "Already owns an SBT");

        uint256 tokenId = _nextTokenId++;
        _safeMint(msg.sender, tokenId);
    }

    /**
     * @dev Mint SBT to a specific address (for faucet backend)
     */
    function mintTo(address to) public {
        require(balanceOf(to) == 0, "Address already owns an SBT");

        uint256 tokenId = _nextTokenId++;
        _safeMint(to, tokenId);
    }

    /**
     * @dev Hook that is called before any token transfer.
     * This override prevents tokens from being transferred between accounts.
     * It allows minting (when `from` is the zero address) and burning (when `to` is the zero address).
     */
    function _update(address to, uint256 tokenId, address auth)
        internal
        override
        returns (address)
    {
        address from = _ownerOf(tokenId);

        // If token exists (from != address(0)) and this is not a burn (to != address(0))
        // then it's a transfer, which should be blocked for SBTs
        if (from != address(0) && to != address(0)) {
            revert("SBTs are not transferable");
        }

        return super._update(to, tokenId, auth);
    }
}
