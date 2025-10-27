// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./GasTokenV2.sol";
import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";

/**
 * @title GasTokenFactoryV2
 * @notice Factory contract for deploying GasTokenV2 instances
 * @dev Enhanced version supporting updatable paymaster addresses
 *
 * Features:
 * - Deploy new GasTokenV2 with custom paymaster contract
 * - Track all deployed tokens
 * - Configurable exchange rates
 * - Paymaster can be updated after deployment
 */
contract GasTokenFactoryV2 is Ownable {
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
        address indexed paymaster,
        address basePriceToken,
        uint256 exchangeRate,
        uint256 priceUSD,
        address indexed deployer
    );

    constructor() Ownable(msg.sender) {}

    /**
     * @notice Deploy a new GasTokenV2
     * @param name Token name (e.g., "Points Token")
     * @param symbol Token symbol (e.g., "PNT")
     * @param paymaster Initial Paymaster contract address for this token
     * @param basePriceToken Base token address (address(0) for base tokens like aPNTs)
     * @param exchangeRate Exchange rate (18 decimals), 1e18 for base tokens, 4e18 for 1:4 ratio
     * @param priceUSD Price in USD (18 decimals), only for base tokens, e.g., 0.02e18
     * @return token Address of deployed GasTokenV2
     *
     * @dev Example use cases:
     *   - Deploy aPNT (base): createToken("Alpha Points", "aPNT", paymasterV4, address(0), 1e18, 0.02e18)
     *   - Deploy xPNT (derived): createToken("X Points", "xPNT", paymasterV4, aPNTAddress, 4e18, 0)
     */
    function createToken(
        string memory name,
        string memory symbol,
        address paymaster,
        address basePriceToken,
        uint256 exchangeRate,
        uint256 priceUSD
    ) external returns (address token) {
        require(paymaster != address(0), "Factory: zero paymaster");
        require(exchangeRate > 0, "Factory: zero rate");
        require(tokenBySymbol[symbol] == address(0), "Factory: symbol exists");

        // Deploy new GasTokenV2
        GasTokenV2 newToken = new GasTokenV2(name, symbol, paymaster, basePriceToken, exchangeRate, priceUSD);

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
            paymaster,
            basePriceToken,
            exchangeRate,
            priceUSD,
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
     * @param token GasTokenV2 address
     * @return name Token name
     * @return symbol Token symbol
     * @return paymaster Current Paymaster contract address
     * @return exchangeRate Exchange rate
     * @return totalSupply Total supply
     */
    function getTokenInfo(address token) external view returns (
        string memory name,
        string memory symbol,
        address paymaster,
        uint256 exchangeRate,
        uint256 totalSupply
    ) {
        require(isDeployedToken[token], "Factory: invalid token");

        GasTokenV2 gasToken = GasTokenV2(token);

        name = gasToken.name();
        symbol = gasToken.symbol();
        (paymaster, exchangeRate, totalSupply) = gasToken.getInfo();
    }
}
