// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./xPNTsToken.sol";
import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import { IVersioned } from "src/interfaces/IVersioned.sol";

/**
 * @title xPNTsFactory
 * @notice Factory for deploying xPNTs tokens with AI-powered deposit predictions
 * @dev Provides standardized deployment and intelligent deposit recommendations
 *
 * Key Features:
 * - One-click xPNTs token deployment
 * - Automatic pre-authorization setup (SuperPaymaster, Factory)
 * - AI prediction for optimal aPNTs deposit amounts
 * - Industry-specific multipliers (DeFi=2.0, Gaming=1.5, Social=1.0)
 * - Safety factor adjustments
 *
 * Prediction Formula:
 * suggestedAmount = avgDailyTx * avgGasCost * 30 days * industryMultiplier * safetyFactor / 1e18
 *
 * Example:
 * - DeFi community: 100 tx/day * 0.001 ETH * 30 * 2.0 * 1.5 = 9 ETH
 * - Gaming: 200 tx/day * 0.0005 ETH * 30 * 1.5 * 1.5 = 6.75 ETH
 * - Social: 50 tx/day * 0.0003 ETH * 30 * 1.0 * 1.5 = 0.675 ETH
 */
contract xPNTsFactory is Ownable, IVersioned {

    // ====================================
    // Structs
    // ====================================

    /// @notice AI prediction parameters
    struct PredictionParams {
        uint256 avgDailyTx;         // Average daily transactions
        uint256 avgGasCost;         // Average gas cost in wei
        uint256 industryMultiplier; // Industry coefficient (scaled by 1e18)
        uint256 safetyFactor;       // Safety factor (scaled by 1e18)
    }

    // ====================================
    // Storage
    // ====================================

    /// @notice SuperPaymaster contract address
    address public SUPERPAYMASTER;

    /// @notice Registry contract address
    address public immutable REGISTRY;

    /// @notice Mapping: community address => xPNTs token address
    mapping(address => address) public communityToToken;

    /// @notice Mapping: community address => prediction parameters
    mapping(address => PredictionParams) public predictions;

    /// @notice List of all deployed tokens
    address[] public deployedTokens;

    /// @notice Industry multipliers (name => value in 1e18)
    mapping(string => uint256) public industryMultipliers;

    /// @notice aPNTs USD price (18 decimals, e.g., 0.02e18 = $0.02)
    /// @dev Used by PaymasterV4 and SuperPaymaster V2 for gas cost calculation
    uint256 public aPNTsPriceUSD;

    // ====================================
    // Constants
    // ====================================

    /// @notice Default safety factor: 1.5x (50% buffer)
    uint256 public constant DEFAULT_SAFETY_FACTOR = 1.5 ether;

    /// @notice Minimum suggested amount: 100 aPNTs
    uint256 public constant MIN_SUGGESTED_AMOUNT = 100 ether;



    function version() external pure override returns (string memory) {
        return "xPNTsFactory-2.0.0";
    }

    // ====================================
    // Events
    // ====================================

    event xPNTsTokenDeployed(
        address indexed community,
        address indexed tokenAddress,
        string name,
        string symbol
    );

    event PredictionUpdated(
        address indexed community,
        uint256 suggestedAmount
    );

    event IndustryMultiplierSet(
        string indexed industry,
        uint256 multiplier
    );

    event APNTsPriceUpdated(
        uint256 oldPrice,
        uint256 newPrice
    );

    // ====================================
    // Errors
    // ====================================

    error AlreadyDeployed(address community);
    error InvalidAddress(address addr);
    error InvalidParameters();

    // ====================================
    // Constructor
    // ====================================

    /**
     * @notice Initialize factory
     * @param _superPaymaster SuperPaymaster v2.0 address
     * @param _registry Registry contract address
     */
    constructor(address _superPaymaster, address _registry) Ownable(msg.sender) {
        if (_registry == address(0)) {
            revert InvalidAddress(address(0));
        }

        SUPERPAYMASTER = _superPaymaster; // Can be address(0) initially
        REGISTRY = _registry;

        // Initialize aPNTs price (default: $0.02)
        aPNTsPriceUSD = 0.02 ether; // 0.02 * 1e18

        // Initialize default industry multipliers (scaled by 1e18)
        industryMultipliers["DeFi"] = 2.0 ether;      // 2.0x
        industryMultipliers["Gaming"] = 1.5 ether;    // 1.5x
        industryMultipliers["Social"] = 1.0 ether;    // 1.0x
        industryMultipliers["DAO"] = 1.2 ether;       // 1.2x
        industryMultipliers["NFT"] = 1.3 ether;       // 1.3x
    }

    // ====================================
    // Core Functions
    // ====================================

    /**
     * @notice Deploy new xPNTs token
     * @param name Token name (e.g., "MyDAO Points")
     * @param symbol Token symbol (e.g., "xMDAO")
     * @param communityName Community display name
     * @param communityENS Community ENS domain
     * @param exchangeRate Exchange rate with aPNTs (18 decimals, e.g., 1e18 = 1:1)
     * @param paymasterAOA Paymaster address for AOA mode (optional, use address(0) for AOA+ only)
     * @return token Deployed token address
     */
    function deployxPNTsToken(
        string memory name,
        string memory symbol,
        string memory communityName,
        string memory communityENS,
        uint256 exchangeRate,
        address paymasterAOA
    ) external returns (address token) {
        if (communityToToken[msg.sender] != address(0)) {
            revert AlreadyDeployed(msg.sender);
        }

        // Deploy new xPNTs token with exchangeRate
        xPNTsToken newToken = new xPNTsToken(
            name,
            symbol,
            msg.sender,
            communityName,
            communityENS,
            exchangeRate
        );

        token = address(newToken);

        // Auto-configure pre-authorization
        // AOA+ mode: Always approve SuperPaymaster, if the address has been set.
        if (SUPERPAYMASTER != address(0)) {
            newToken.setSuperPaymasterAddress(SUPERPAYMASTER);
            newToken.addAutoApprovedSpender(SUPERPAYMASTER);
        }

        // AOA mode: Approve operator's specific paymaster (if provided)
        if (paymasterAOA != address(0)) {
            newToken.addAutoApprovedSpender(paymasterAOA);
        }

        // Record deployment
        communityToToken[msg.sender] = token;
        deployedTokens.push(token);

        emit xPNTsTokenDeployed(msg.sender, token, name, symbol);
    }

    /**
     * @notice AI-powered deposit amount prediction
     * @param community Community address
     * @return suggestedAmount Suggested deposit amount in aPNTs
     */
    function predictDepositAmount(address community)
        public
        view
        returns (uint256 suggestedAmount)
    {
        PredictionParams memory params = predictions[community];

        // New community: return default
        if (params.avgDailyTx == 0) {
            return MIN_SUGGESTED_AMOUNT;
        }

        // Formula: dailyTx * avgGasCost * 30 days * industryMultiplier * safetyFactor / 1e36
        uint256 dailyCost = params.avgDailyTx * params.avgGasCost;
        uint256 monthlyCost = dailyCost * 30;

        suggestedAmount = monthlyCost * params.industryMultiplier * params.safetyFactor / 1e36;

        // Minimum threshold
        if (suggestedAmount < MIN_SUGGESTED_AMOUNT) {
            suggestedAmount = MIN_SUGGESTED_AMOUNT;
        }
    }

    /**
     * @notice Update prediction parameters
     * @param avgDailyTx Average daily transactions
     * @param avgGasCost Average gas cost in wei
     * @param industry Industry type (e.g., "DeFi", "Gaming")
     * @param safetyFactor Safety factor (scaled by 1e18, default 1.5e18)
     */
    function updatePrediction(
        uint256 avgDailyTx,
        uint256 avgGasCost,
        string memory industry,
        uint256 safetyFactor
    ) external {
        address community = msg.sender;

        uint256 multiplier = industryMultipliers[industry];
        if (multiplier == 0) {
            multiplier = 1.0 ether; // Default to 1.0x if unknown industry
        }

        if (safetyFactor == 0) {
            safetyFactor = DEFAULT_SAFETY_FACTOR;
        }

        predictions[community] = PredictionParams({
            avgDailyTx: avgDailyTx,
            avgGasCost: avgGasCost,
            industryMultiplier: multiplier,
            safetyFactor: safetyFactor
        });

        emit PredictionUpdated(community, predictDepositAmount(community));
    }

    /**
     * @notice Update prediction with custom multiplier
     * @param avgDailyTx Average daily transactions
     * @param avgGasCost Average gas cost in wei
     * @param customMultiplier Custom industry multiplier (scaled by 1e18)
     * @param safetyFactor Safety factor (scaled by 1e18)
     */
    function updatePredictionCustom(
        uint256 avgDailyTx,
        uint256 avgGasCost,
        uint256 customMultiplier,
        uint256 safetyFactor
    ) external {
        address community = msg.sender;

        if (customMultiplier == 0) {
            customMultiplier = 1.0 ether;
        }

        if (safetyFactor == 0) {
            safetyFactor = DEFAULT_SAFETY_FACTOR;
        }

        predictions[community] = PredictionParams({
            avgDailyTx: avgDailyTx,
            avgGasCost: avgGasCost,
            industryMultiplier: customMultiplier,
            safetyFactor: safetyFactor
        });

        emit PredictionUpdated(community, predictDepositAmount(community));
    }

    // ====================================
    // Admin Functions
    // ====================================
    
    /**
     * @notice Sets the SuperPaymaster address after deployment
     * @dev Breaks the circular dependency between Factory and SuperPaymaster. Only owner.
     * @param _superPaymaster The address of the deployed SuperPaymasterV3 contract.
     */
    function setSuperPaymasterAddress(address _superPaymaster) external onlyOwner {
        require(_superPaymaster != address(0), "Invalid address");
        SUPERPAYMASTER = _superPaymaster;
    }

    /**
     * @notice Update aPNTs USD price (only owner)
     * @dev Price is updated off-chain periodically for dynamic pricing
     * @param newPrice New price in USD (18 decimals, e.g., 0.02e18 = $0.02)
     */
    function updateAPNTsPrice(uint256 newPrice) external onlyOwner {
        require(newPrice > 0, "Price must be positive");

        uint256 oldPrice = aPNTsPriceUSD;
        aPNTsPriceUSD = newPrice;

        emit APNTsPriceUpdated(oldPrice, newPrice);
    }

    /**
     * @notice Set industry multiplier (only owner)
     * @param industry Industry name
     * @param multiplier Multiplier value (scaled by 1e18)
     */
    function setIndustryMultiplier(string memory industry, uint256 multiplier)
        external
        onlyOwner
    {
        require(multiplier > 0 && multiplier <= 10 ether, "Invalid multiplier");

        industryMultipliers[industry] = multiplier;

        emit IndustryMultiplierSet(industry, multiplier);
    }

    // ====================================
    // View Functions
    // ====================================

    /**
     * @notice Get current aPNTs USD price
     * @dev Used by PaymasterV4 and SuperPaymaster V2 for gas cost calculation
     * @return price aPNTs price in USD (18 decimals)
     */
    function getAPNTsPrice() external view returns (uint256 price) {
        return aPNTsPriceUSD;
    }

    /**
     * @notice Get xPNTs token address for community
     * @param community Community address
     * @return token Token address (address(0) if not deployed)
     */
    function getTokenAddress(address community)
        external
        view
        returns (address token)
    {
        return communityToToken[community];
    }

    /**
     * @notice Check if community has deployed token
     * @param community Community address
     * @return hasToken True if token deployed
     */
    function hasToken(address community) external view returns (bool) {
        return communityToToken[community] != address(0);
    }

    /**
     * @notice Get all deployed tokens
     * @return tokens Array of token addresses
     */
    function getAllTokens() external view returns (address[] memory tokens) {
        return deployedTokens;
    }

    /**
     * @notice Get total deployed tokens count
     * @return count Total count
     */
    function getDeployedCount() external view returns (uint256 count) {
        return deployedTokens.length;
    }

    /**
     * @notice Get prediction parameters for community
     * @param community Community address
     * @return params Prediction parameters
     */
    function getPredictionParams(address community)
        external
        view
        returns (PredictionParams memory params)
    {
        return predictions[community];
    }

    /**
     * @notice Get industry multiplier
     * @param industry Industry name
     * @return multiplier Multiplier value (scaled by 1e18)
     */
    function getIndustryMultiplier(string memory industry)
        external
        view
        returns (uint256 multiplier)
    {
        return industryMultipliers[industry];
    }

    /**
     * @notice Calculate deposit breakdown
     * @param community Community address
     * @return dailyCost Daily cost estimate
     * @return monthlyCost Monthly cost estimate
     * @return suggestedAmount Suggested deposit with safety factor
     * @return multiplierUsed Industry multiplier used
     * @return safetyFactorUsed Safety factor used
     */
    function getDepositBreakdown(address community)
        external
        view
        returns (
            uint256 dailyCost,
            uint256 monthlyCost,
            uint256 suggestedAmount,
            uint256 multiplierUsed,
            uint256 safetyFactorUsed
        )
    {
        PredictionParams memory params = predictions[community];

        dailyCost = params.avgDailyTx * params.avgGasCost;
        monthlyCost = dailyCost * 30;
        suggestedAmount = predictDepositAmount(community);
        multiplierUsed = params.industryMultiplier;
        safetyFactorUsed = params.safetyFactor;
    }
}
