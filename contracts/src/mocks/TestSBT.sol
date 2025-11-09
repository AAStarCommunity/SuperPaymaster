// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin-v5.0.2/contracts/token/ERC721/ERC721.sol";

/**
 * @title TestSBT
 * @notice Simple SBT for testing - anyone can mint
 */
contract TestSBT is ERC721 {
    uint256 private _nextTokenId;

    constructor() ERC721("Test SBT", "TSBT") {}

    /**
     * @notice Mint SBT to any address (for testing only)
     */
    function mint(address to) external returns (uint256) {
        uint256 tokenId = _nextTokenId++;
        _safeMint(to, tokenId);
        return tokenId;
    }

    /**
     * @notice Check if address has any SBT
     */
    function hasToken(address user) external view returns (bool) {
        return balanceOf(user) > 0;
    }
}
