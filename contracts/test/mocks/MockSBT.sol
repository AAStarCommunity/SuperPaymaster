// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ISBT} from "../../../src/interfaces/ISBT.sol";

/**
 * @title MockSBT - Mock Soul-Bound Token for Testing
 * @notice Simple SBT implementation for testing SuperPaymaster V3
 * @dev Non-transferable token, one per address
 */
contract MockSBT is ISBT {
    string public name = "Mock Soul-Bound Token";
    string public symbol = "MSBT";

    // Mapping from owner to token ID
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _owners;

    uint256 private _tokenIdCounter;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    /**
     * @notice Mint an SBT to an address
     * @param to Recipient address
     * @param tokenId Token ID to mint
     */
    function mint(address to, uint256 tokenId) external {
        require(to != address(0), "MockSBT: mint to zero address");
        require(_balances[to] == 0, "MockSBT: already owns SBT");
        require(_owners[tokenId] == address(0), "MockSBT: token already minted");

        _balances[to] = 1;
        _owners[tokenId] = to;

        emit Transfer(address(0), to, tokenId);
    }

    /**
     * @notice Mint auto-incremented SBT
     * @param to Recipient address
     */
    function safeMint(address to) external {
        uint256 tokenId = _tokenIdCounter++;
        require(to != address(0), "MockSBT: mint to zero address");
        require(_balances[to] == 0, "MockSBT: already owns SBT");

        _balances[to] = 1;
        _owners[tokenId] = to;

        emit Transfer(address(0), to, tokenId);
    }

    /**
     * @notice Burn an SBT (for testing)
     * @param tokenId Token ID to burn
     */
    function burn(uint256 tokenId) external {
        address owner = _owners[tokenId];
        require(owner != address(0), "MockSBT: token doesn't exist");

        _balances[owner] = 0;
        delete _owners[tokenId];

        emit Transfer(owner, address(0), tokenId);
    }

    // ============ ISBT Implementation ============

    /**
     * @inheritdoc ISBT
     */
    function balanceOf(address account) external view override returns (uint256) {
        return _balances[account];
    }

    /**
     * @inheritdoc ISBT
     */
    function ownerOf(uint256 tokenId) external view override returns (address) {
        address owner = _owners[tokenId];
        require(owner != address(0), "MockSBT: token doesn't exist");
        return owner;
    }

    /**
     * @inheritdoc ISBT
     */
    function exists(uint256 tokenId) external view override returns (bool) {
        return _owners[tokenId] != address(0);
    }

    /**
     * @notice Get total supply
     * @return Total number of minted tokens
     */
    function totalSupply() external view returns (uint256) {
        return _tokenIdCounter;
    }
}
