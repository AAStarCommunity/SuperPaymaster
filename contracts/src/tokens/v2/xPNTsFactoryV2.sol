// SPDX-License-Identifier: Apache-2.0
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;
import { xPNTsTokenV2 } from "./xPNTsTokenV2.sol";
import { AOAProtocolRegistry } from "./AOAProtocolRegistry.sol";
import "@openzeppelin-v5.0.2/contracts/access/Ownable.sol";
import "@openzeppelin-v5.0.2/contracts/proxy/Clones.sol";
import {IVersioned} from "src/interfaces/IVersioned.sol";
import "src/interfaces/v3/IRegistry.sol";

/**
 * @title xPNTsFactoryV2
 * @notice xPNTs v2 (XPNTs-4.0.0) factory for the AOA balance-mode stack.
 * @dev    Differences from 3.x (spec 03 A-9, A-10, R4-H5, §2.5):
 *         - the token template is deployed SEPARATELY and passed in (EIP-3860: core + extension
 *           creation code would not fit in this constructor);
 *         - the genesis SP is passed to `initialize` and is NOT made a spender (A-3);
 *         - `paymasterAOA` becomes a genesis spender with a per-user default cap of 0 (Q5);
 *         - a default credit tier source is passed to every new token (R4-H5);
 *         - `propagateSuperPaymaster` only PROPOSES (48 h, community-cancellable, S-1).
 *
 * (3.x description follows)
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
contract xPNTsFactoryV2 is Ownable, IVersioned {
    using Clones for address;

    // ====================================
    // Structs
    // ====================================

    /// @notice AI prediction parameters
    struct PredictionParams {
        uint256 avgDailyTx; // Average daily transactions
        uint256 avgGasCost; // Average gas cost in wei
        uint256 industryMultiplier; // Industry coefficient (scaled by 1e18)
        uint256 safetyFactor; // Safety factor (scaled by 1e18)
    }

    // ====================================
    // Storage
    // ====================================

    /// @notice SuperPaymaster contract address
    address public SUPERPAYMASTER;

    /// @notice Registry contract address
    address public immutable REGISTRY;

    /// @notice The xPNTsTokenV2 (core) implementation cloned for every community.
    address public immutable implementation;

    /// @notice Runtime hashes pinned when the factory is deployed. Product deployment fails
    ///         closed if either the core template or its delegated extension changes.
    bytes32 public immutable implementationCodehash;
    bytes32 public immutable extensionCodehash;

    /// @notice Credit tier source handed to each newly deployed token (R4-H5). Owner-settable
    ///         for FUTURE tokens only; an existing token changes its source via its own 48 h queue.
    address public defaultTierSource;

    /// @notice Mapping: community address => xPNTs token address
    mapping(address => address) public communityToToken;

    /// @notice Whitelist of tokens this factory has deployed.
    /// @dev    P0-12a: SuperPaymaster.settleX402PaymentDirect must reject any
    ///         asset that is not registered here, so an attacker cannot drain
    ///         a victim's standard approve(facilitator, MAX) on USDC / WETH /
    ///         etc. via the Direct path. xPNTs tokens carry the autoApproved
    ///         firewall + MAX_SINGLE_TX_LIMIT; arbitrary ERC20s do not.
    mapping(address => bool) public isXPNTs;

    /// @notice Mapping: community address => prediction parameters
    mapping(address => PredictionParams) public predictions;

    /// @notice List of all deployed tokens
    address[] public deployedTokens;

    /// @notice Industry multipliers (name => value in 1e18)
    mapping(string => uint256) public industryMultipliers;

    /// @notice aPNTs USD price (18 decimals, e.g., 0.02e18 = $0.02)
    /// @dev Used by PaymasterV4 and SuperPaymaster V2 for gas cost calculation
    uint256 public aPNTsPriceUSD;

    /// @notice CC-28 over-issue model: baseline issuance ceiling per industry category
    ///         (USD, 18 decimals). The non-staked credit floor a category is trusted with.
    ///         Governance-set. 0 => the category has no baseline (a community in it must back
    ///         its issuance entirely with staked aPNTs). Read by xPNTsToken.effectiveCapUSD().
    mapping(string => uint256) public industryScaleUSD;

    /// @notice CC-28: fraction of industryScaleUSD granted as the baseline cap, in basis points.
    /// @dev effectiveCap = industryScaleUSD[category] * capRatioBps / 10000 + stakedValueUSD.
    ///      0 < capRatioBps <= 10000. Governance knob to tighten/loosen the whole baseline.
    uint16 public capRatioBps;

    /// @notice CC-28: whether a category key has been governance-registered (via
    ///         setIndustryScaleUSD or constructor seeding). Distinguishes a DELIBERATE
    ///         zero-baseline category (registered, scale 0 → full stake-backing required)
    ///         from a typo'd category name (never registered) in setTokenCategory.
    mapping(string => bool) public categoryRegistered;

    /// @notice CC-28: governance-assigned industry category per xPNTs token.
    /// @dev    MUST be governance-set (not community-self-selected) — otherwise the audited
    ///         party could pick a higher-baseline category to evade over-issue detection.
    ///         Empty => xPNTsToken._categoryKey() falls back to "default". Read by the token.
    mapping(address => string) public tokenCategory;

    /// @notice CC-28: safety ceiling on a category's baseline (guards effectiveCapUSD overflow).
    uint256 public constant MAX_INDUSTRY_SCALE_USD = 1e12 ether; // $1 trillion

    // ====================================
    // Constants
    // ====================================

    /// @notice Default safety factor: 1.5x (50% buffer)
    uint256 public constant DEFAULT_SAFETY_FACTOR = 1.5 ether;

    /// @notice Minimum suggested amount: 100 aPNTs
    uint256 public constant MIN_SUGGESTED_AMOUNT = 100 ether;

    // P0-12: price bounds for updateAPNTsPrice (18-decimal, $0.001–$100 USD)
    uint256 public constant APNTS_PRICE_MIN = 0.001 ether;
    uint256 public constant APNTS_PRICE_MAX = 100 ether;
    uint256 public constant APNTS_PRICE_DELTA_BPS = 3000; // ±30% per update

    function version() external pure override returns (string memory) {
        return "xPNTsFactory-3.0.0-v2";
    }

    // ====================================
    // Events
    // ====================================

    event xPNTsTokenDeployed(address indexed community, address indexed tokenAddress, string name, string symbol);

    event PredictionUpdated(address indexed community, uint256 suggestedAmount);

    event IndustryMultiplierSet(string indexed industry, uint256 multiplier);

    event APNTsPriceUpdated(uint256 oldPrice, uint256 newPrice);

    /// @notice CC-28: emitted when a category's baseline issuance ceiling is set.
    event IndustryScaleSet(string indexed category, uint256 scaleUSD);
    /// @notice CC-28: emitted when the global baseline cap ratio is changed.
    event CapRatioBpsSet(uint16 oldBps, uint16 newBps);
    /// @notice CC-28: emitted when a token's governance-assigned category is set.
    event TokenCategorySet(address indexed token, string category);

    event SuperPaymasterAddressUpdated(address indexed oldAddr, address indexed newAddr);
    event SuperPaymasterPropagationFailed(address indexed token, address indexed newSP);
    event SuperPaymasterPropagated(address indexed token, address indexed newSP);

    // ====================================
    // Errors
    // ====================================

    error AlreadyDeployed(address community);
    error InvalidAddress(address addr);
    error InvalidParameters();
    error CallerNotCommunity();
    error InvalidPrice();
    error InvalidMultiplier();
    /// @notice CC-28: thrown when capRatioBps is set to 0 or > 10000.
    error InvalidCapRatio();
    /// @notice CC-28 L-1: thrown when setTokenCategory targets a non-factory token.
    error NotFactoryToken();
    /// @notice CC-28 L-2: thrown when assigning a non-empty category that has no seeded baseline.
    error CategoryNotSeeded();
    error InvalidTemplate();
    error TemplateCodehashChanged();
    error InitializationFailed();

    // ====================================
    // Constructor
    // ====================================

    /**
     * @notice Initialize factory
     * @param _superPaymaster SuperPaymaster v2.0 address
     * @param _registry Registry contract address
     */
    constructor(address _superPaymaster, address _registry, address _implementation, address _defaultTierSource)
        Ownable(msg.sender)
    {
        if (_registry == address(0) || _implementation == address(0) || _implementation.code.length == 0) {
            revert InvalidAddress(address(0));
        }

        address extension;
        AOAProtocolRegistry protocolRegistry;
        try xPNTsTokenV2(_implementation).BALANCE_MODE_VERSION() returns (uint16 v) {
            if (v != 1) revert InvalidTemplate();
        } catch {
            revert InvalidTemplate();
        }
        try xPNTsTokenV2(_implementation).version() returns (string memory v) {
            if (keccak256(bytes(v)) != keccak256("XPNTs-4.0.0")) revert InvalidTemplate();
        } catch {
            revert InvalidTemplate();
        }
        try xPNTsTokenV2(_implementation).EXTENSION() returns (address e) {
            extension = e;
        } catch {
            revert InvalidTemplate();
        }
        try xPNTsTokenV2(_implementation).PROTOCOL_REGISTRY() returns (AOAProtocolRegistry r) {
            protocolRegistry = r;
        } catch {
            revert InvalidTemplate();
        }
        if (extension.code.length == 0 || address(protocolRegistry) == address(0)) revert InvalidTemplate();
        try xPNTsTokenV2(extension).PROTOCOL_REGISTRY() returns (AOAProtocolRegistry r) {
            if (address(r) != address(protocolRegistry)) revert InvalidTemplate();
        } catch {
            revert InvalidTemplate();
        }
        if (_defaultTierSource == address(0)
            || !protocolRegistry.isApprovedImpl(protocolRegistry.KIND_TIER_SOURCE(), _defaultTierSource)) {
            revert InvalidAddress(_defaultTierSource);
        }

        implementation = _implementation;
        implementationCodehash = _implementation.codehash;
        extensionCodehash = extension.codehash;
        defaultTierSource = _defaultTierSource;

        SUPERPAYMASTER = _superPaymaster; // Can be address(0) initially
        REGISTRY = _registry;

        // Initialize aPNTs price (default: $0.02)
        aPNTsPriceUSD = 0.02 ether; // 0.02 * 1e18

        // Initialize default industry multipliers (scaled by 1e18)
        industryMultipliers["DeFi"] = 2.0 ether; // 2.0x
        industryMultipliers["Gaming"] = 1.5 ether; // 1.5x
        industryMultipliers["Social"] = 1.0 ether; // 1.0x
        industryMultipliers["DAO"] = 1.2 ether; // 1.2x
        industryMultipliers["NFT"] = 1.3 ether; // 1.3x

        // CC-28: over-issue baseline model. capRatioBps=10000 => baseline cap == full scale.
        // The baseline is the non-staked credit floor; staked aPNTs amplify it additively.
        capRatioBps = 10_000;
        _seedCategory("default", 10_000 ether); // $10,000 baseline credit floor
        _seedCategory("DeFi", 50_000 ether);
        _seedCategory("Gaming", 20_000 ether);
        _seedCategory("Social", 10_000 ether);
        _seedCategory("DAO", 15_000 ether);
        _seedCategory("NFT", 15_000 ether);
    }

    /// @dev CC-28: seed a category's baseline + mark it registered (constructor only).
    function _seedCategory(string memory category, uint256 scaleUSD) private {
        industryScaleUSD[category] = scaleUSD;
        categoryRegistered[category] = true;
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
        if (implementation.codehash != implementationCodehash
            || xPNTsTokenV2(implementation).EXTENSION().codehash != extensionCodehash) {
            revert TemplateCodehashChanged();
        }
        if (!IRegistry(REGISTRY).hasRole(keccak256("COMMUNITY"), msg.sender)) {
            revert CallerNotCommunity();
        }
        if (communityToToken[msg.sender] != address(0)) {
            revert AlreadyDeployed(msg.sender);
        }
        if (exchangeRate == 0) revert InvalidParameters();

        // Deploy new xPNTs token proxy using clone pattern
        address newTokenAddress = implementation.clone();
        token = newTokenAddress;
        xPNTsTokenV2 configuredToken = xPNTsTokenV2(newTokenAddress);
        configuredToken.initialize(xPNTsTokenV2.InitConfig({
            name: name,
            symbol: symbol,
            communityOwner: msg.sender,
            community: msg.sender,
            communityName: communityName,
            communityENS: communityENS,
            exchangeRate: exchangeRate,
            superPaymaster: SUPERPAYMASTER,   // S-0: genesis SP, NOT a spender (A-3)
            genesisSpender: paymasterAOA,     // A-10 ②: per-user default cap 0
            tierSource: defaultTierSource     // R4-H5
        }));
        if (configuredToken.FACTORY() != address(this)
            || configuredToken.communityOwner() != msg.sender
            || configuredToken.community() != msg.sender
            || configuredToken.exchangeRate() != exchangeRate
            || configuredToken.SUPERPAYMASTER_ADDRESS() != SUPERPAYMASTER
            || configuredToken.creditTierSource() != defaultTierSource
            || configuredToken.creditPolicy() != 0
            || (paymasterAOA != address(0) && !configuredToken.autoApprovedSpenders(paymasterAOA))) {
            revert InitializationFailed();
        }

        // Record deployment
        communityToToken[msg.sender] = token;
        deployedTokens.push(token);

        // P0-12a: register this token as an xPNTs in the factory whitelist so
        // SuperPaymaster.settleX402PaymentDirect can gate on it. Without this
        // gate, any ERC20 (e.g. USDC for which the user has done a standard
        // infinite approve to the facilitator) could be drained via Direct.
        isXPNTs[token] = true;

        emit xPNTsTokenDeployed(msg.sender, token, name, symbol);
    }

    /**
     * @notice AI-powered deposit amount prediction
     * @param community Community address
     * @return suggestedAmount Suggested deposit amount in aPNTs
     */
    function predictDepositAmount(address community) public view returns (uint256 suggestedAmount) {
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
    function updatePrediction(uint256 avgDailyTx, uint256 avgGasCost, string memory industry, uint256 safetyFactor)
        external
    {
        if (avgDailyTx > 1_000_000) revert InvalidParameters();
        address community = msg.sender;

        uint256 multiplier = industryMultipliers[industry];
        if (multiplier == 0) {
            multiplier = 1.0 ether; // Default to 1.0x if unknown industry
        }

        if (safetyFactor == 0) {
            safetyFactor = DEFAULT_SAFETY_FACTOR;
        }

        predictions[community] = PredictionParams({
            avgDailyTx: avgDailyTx, avgGasCost: avgGasCost, industryMultiplier: multiplier, safetyFactor: safetyFactor
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
        if (avgDailyTx > 1_000_000) revert InvalidParameters();
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
     * @param _superPaymaster The address of the deployed SuperPaymaster contract.
     */
    /// @notice Owner: set the tier source handed to FUTURE tokens.
    function setDefaultTierSource(address source) external onlyOwner {
        AOAProtocolRegistry protocolRegistry = xPNTsTokenV2(implementation).PROTOCOL_REGISTRY();
        if (source == address(0)
            || !protocolRegistry.isApprovedImpl(protocolRegistry.KIND_TIER_SOURCE(), source)) {
            revert InvalidAddress(source);
        }
        defaultTierSource = source;
    }

    /// @dev M-8: stores new SP address only; use propagateSuperPaymaster() to PROPOSE it to deployed tokens.
    function setSuperPaymasterAddress(address _superPaymaster) external onlyOwner {
        if (_superPaymaster == address(0)) revert InvalidAddress(_superPaymaster);
        emit SuperPaymasterAddressUpdated(SUPERPAYMASTER, _superPaymaster);
        SUPERPAYMASTER = _superPaymaster;
    }

    /**
     * @notice Propagate current SUPERPAYMASTER address to a batch of deployed tokens.
     * @dev Best-effort: failures emit SuperPaymasterPropagationFailed without reverting.
     *      Call repeatedly with increasing `start` to handle large deployedTokens arrays
     *      and to retry previously failed tokens.
     * @param start  Index in deployedTokens to start from (inclusive).
     * @param limit  Maximum number of tokens to process in this call.
     */
    function propagateSuperPaymaster(uint256 start, uint256 limit) external onlyOwner {
        uint256 len = deployedTokens.length;
        if (start >= len) return;
        // Safe: remaining = len - start (no underflow since start < len),
        //       count <= remaining, end = start + count <= len (no overflow).
        uint256 remaining = len - start;
        uint256 count = limit < remaining ? limit : remaining;
        uint256 end = start + count;
        address sp = SUPERPAYMASTER;
        for (uint256 i = start; i < end;) {
            address token = deployedTokens[i];
            // S-1: proposal only — 48 h delay, cancellable by the community, never instant.
            (bool ok, ) = token.call(abi.encodeWithSignature("proposeSP(address)", sp));
            if (ok) emit SuperPaymasterPropagated(token, sp);
            else emit SuperPaymasterPropagationFailed(token, sp);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Update aPNTs USD price (only owner)
    /// @param newPrice New price in USD (18 decimals, e.g., 0.02e18 = $0.02)
    /// @dev Price is updated off-chain periodically for dynamic pricing.
    /// @dev P0-12: absolute bounds + 30% per-tx delta to prevent price manipulation.
    ///
    /// @dev EXECUTION CHECKLIST — this number leaves the repo. `aPNTsPriceUSD` is the
    ///      denominator for anything that prices aPNTs in dollars, and at least one such
    ///      consumer bakes the result into storage it can never loosen again:
    ///      repo:airaccount's account guard fixes per-tier transfer limits in absolute
    ///      aPNTs at `initialize`, and `tier1Limit`/`tier2Limit` are then permanently
    ///      unchangeable (`addTokenConfig` reverts on an already-configured token);
    ///      `dailyLimit` can only be lowered. Raising the price therefore RELAXES a guard
    ///      that cannot be tightened back, on accounts that already exist.
    ///
    ///      The bounds here do not protect that: `APNTS_PRICE_MAX` is 100 ether, five
    ///      thousand times the $0.02 the token launches at, and the ±30% delta only makes
    ///      the walk take steps rather than preventing it.
    ///
    ///      So before calling this, check the new price against the limits already baked
    ///      by every downstream consumer, and tell them before it lands. Neither side's
    ///      tests can see this: the change happens here and the consequence lands in
    ///      their immutable storage, and nothing on either side reads the other.
    function updateAPNTsPrice(uint256 newPrice) external onlyOwner {
        if (newPrice < APNTS_PRICE_MIN || newPrice > APNTS_PRICE_MAX) revert InvalidPrice();
        uint256 oldPrice = aPNTsPriceUSD;
        if (oldPrice != 0) {
            uint256 lower = oldPrice * (10000 - APNTS_PRICE_DELTA_BPS) / 10000;
            uint256 upper = oldPrice * (10000 + APNTS_PRICE_DELTA_BPS) / 10000;
            if (newPrice < lower || newPrice > upper) revert InvalidPrice();
        }
        aPNTsPriceUSD = newPrice;
        emit APNTsPriceUpdated(oldPrice, newPrice);
    }

    /**
     * @notice Set industry multiplier (only owner)
     * @param industry Industry name
     * @param multiplier Multiplier value (scaled by 1e18)
     */
    function setIndustryMultiplier(string memory industry, uint256 multiplier) external onlyOwner {
        if (multiplier == 0 || multiplier > 10 ether) revert InvalidMultiplier();

        industryMultipliers[industry] = multiplier;

        emit IndustryMultiplierSet(industry, multiplier);
    }

    /**
     * @notice CC-28: set the baseline issuance ceiling (USD, 18 decimals) for a category.
     * @dev    0 is allowed — it means the category has no baseline credit and communities in
     *         it must back all issuance with staked aPNTs. Governance-controlled.
     */
    function setIndustryScaleUSD(string calldata category, uint256 scaleUSD) external onlyOwner {
        if (scaleUSD > MAX_INDUSTRY_SCALE_USD) revert InvalidParameters();
        industryScaleUSD[category] = scaleUSD;
        categoryRegistered[category] = true; // registering with scale 0 is a valid deliberate choice
        emit IndustryScaleSet(category, scaleUSD);
    }

    /**
     * @notice CC-28: assign the industry category for an xPNTs token. Governance-only so the
     *         audited community cannot self-select a higher-baseline category to evade
     *         over-issue detection. Empty string resets the token to the "default" baseline.
     * @dev    L-1: the token must be one this factory deployed (isXPNTs), so a typo'd address
     *         can't seed junk state. L-2: a non-empty category must already be REGISTERED (via
     *         setIndustryScaleUSD or constructor), so a governance typo can't silently assign an
     *         unknown zero-baseline category that forces 100% stake coverage. A deliberate
     *         zero-baseline category is still assignable — register it with setIndustryScaleUSD
     *         (any value, including 0). Pass "" to use the default baseline.
     */
    function setTokenCategory(address token, string calldata category) external onlyOwner {
        if (!isXPNTs[token]) revert NotFactoryToken();
        if (bytes(category).length != 0 && !categoryRegistered[category]) revert CategoryNotSeeded();
        tokenCategory[token] = category;
        emit TokenCategorySet(token, category);
    }

    /**
     * @notice CC-28: set the global baseline cap ratio in basis points (0 < bps <= 10000).
     */
    function setCapRatioBps(uint16 bps) external onlyOwner {
        if (bps == 0 || bps > 10_000) revert InvalidCapRatio();
        uint16 old = capRatioBps;
        capRatioBps = bps;
        emit CapRatioBpsSet(old, bps);
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
    function getTokenAddress(address community) external view returns (address token) {
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
    function getPredictionParams(address community) external view returns (PredictionParams memory params) {
        return predictions[community];
    }

    /**
     * @notice Get industry multiplier
     * @param industry Industry name
     * @return multiplier Multiplier value (scaled by 1e18)
     */
    function getIndustryMultiplier(string memory industry) external view returns (uint256 multiplier) {
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
