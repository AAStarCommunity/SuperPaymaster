// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MySBT is ERC721, Ownable {
    uint256 private _nextTokenId;

    constructor() ERC721("My Soul-Bound Token", "MYSBT") Ownable(msg.sender) {}

    function safeMint(address to) public onlyOwner {
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
            require(false, "SBTs are not transferable");
        }
        
        return super._update(to, tokenId, auth);
    }

    function withdraw() public onlyOwner {
        (bool success, ) = payable(owner()).call{value: address(this).balance}("");
        require(success, "Withdrawal failed");
    }
}