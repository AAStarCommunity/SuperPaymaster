// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "@openzeppelin-v5.0.2/contracts/token/ERC721/ERC721.sol";

/**
 * @title MockSBT
 * @notice Simple mock SBT for testing only - DO NOT deploy to production
 * @dev Used only in unit tests, not in deployment scripts
 */
contract MockSBT is ERC721 {
    uint256 private _tokenIdCounter;

    constructor() ERC721("Mock SBT", "mSBT") {}

    function safeMint(address to) public returns (uint256) {
        uint256 tokenId = _tokenIdCounter++;
        _safeMint(to, tokenId);
        return tokenId;
    }

    function mintTo(address to) public returns (uint256) {
        return safeMint(to);
    }
}
