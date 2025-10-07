// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./GasToken.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title GasTokenFactory
 * @notice Factory contract for deploying GasToken instances
 * @dev Allows creating multiple gas tokens (PNT, aPNT, bPNT, etc.) with different settlement contracts
 *
 * Features:
 * - Deploy new GasToken with custom settlement contract
 * - Track all deployed tokens
 * - Configurable exchange rates
 * - Simple management interface for issuers
 */
contract GasTokenFactory is Ownable {
    /// @notice Array of all deployed gas tokens
    address[] public deployedTokens;

    /// @notice Mapping: token symbol => deployed address
    mapping(string => address) public tokenBySymbol;

    /// @notice Mapping: deployed address => is valid
    mapping(address => bool) public isDeployedToken;

    /// @notice Event emitted when new token is deployed
    event TokenDeployed(
        address indexed token,
        string name,
        string symbol,
        address indexed settlement,
        uint256 exchangeRate,
        address indexed deployer
    );

    constructor() Ownable(msg.sender) {}

    /**
     * @notice Deploy a new GasToken
     * @param name Token name (e.g., "Points Token")
     * @param symbol Token symbol (e.g., "PNT")
     * @param settlement Settlement contract address for this token
     * @param exchangeRate Exchange rate relative to base (1e18 = 1:1)
     * @return token Address of deployed GasToken
     *
     * @dev Example use cases:
     *   - Deploy PNT (base): createToken("Points", "PNT", settlement, 1e18)
     *   - Deploy aPNT: createToken("A Points", "aPNT", settlement, 1.2e18)
     *   - Deploy bPNT: createToken("B Points", "bPNT", settlement, 0.8e18)
     */
    function createToken(
        string memory name,
        string memory symbol,
        address settlement,
        uint256 exchangeRate
    ) external returns (address token) {
        require(settlement != address(0), "Factory: zero settlement");
        require(exchangeRate > 0, "Factory: zero rate");
        require(tokenBySymbol[symbol] == address(0), "Factory: symbol exists");

        // Deploy new GasToken
        GasToken newToken = new GasToken(name, symbol, settlement, exchangeRate);

        // Transfer ownership to caller (issuer)
        newToken.transferOwnership(msg.sender);

        token = address(newToken);

        // Track deployment
        deployedTokens.push(token);
        tokenBySymbol[symbol] = token;
        isDeployedToken[token] = true;

        emit TokenDeployed(
            token,
            name,
            symbol,
            settlement,
            exchangeRate,
            msg.sender
        );

        return token;
    }

    /**
     * @notice Get total number of deployed tokens
     */
    function getDeployedCount() external view returns (uint256) {
        return deployedTokens.length;
    }

    /**
     * @notice Get all deployed token addresses
     */
    function getAllTokens() external view returns (address[] memory) {
        return deployedTokens;
    }

    /**
     * @notice Get token address by symbol
     * @param symbol Token symbol
     * @return Token address (0x0 if not found)
     */
    function getTokenBySymbol(string memory symbol) external view returns (address) {
        return tokenBySymbol[symbol];
    }

    /**
     * @notice Check if an address is a deployed GasToken
     * @param token Address to check
     */
    function isValidToken(address token) external view returns (bool) {
        return isDeployedToken[token];
    }

    /**
     * @notice Get token information
     * @param token GasToken address
     * @return name Token name
     * @return symbol Token symbol
     * @return settlement Settlement contract address
     * @return exchangeRate Exchange rate
     * @return totalSupply Total supply
     */
    function getTokenInfo(address token) external view returns (
        string memory name,
        string memory symbol,
        address settlement,
        uint256 exchangeRate,
        uint256 totalSupply
    ) {
        require(isDeployedToken[token], "Factory: invalid token");

        GasToken gasToken = GasToken(token);

        name = gasToken.name();
        symbol = gasToken.symbol();
        (settlement, exchangeRate, totalSupply) = gasToken.getInfo();
    }
}
