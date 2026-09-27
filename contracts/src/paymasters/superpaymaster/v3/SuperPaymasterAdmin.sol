// SPDX-License-Identifier: Apache-2.0
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;
import "./SuperPaymasterStorage.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../../tokens/v2/IxPNTsTokenV2.sol";
import "../../../interfaces/IxPNTsFactory.sol";

/**
 * @title SuperPaymasterAdmin (EXTENSION)
 * @notice Governance, administration and non-hot-path views of SuperPaymaster 5.5.0 (D5b).
 * @dev    Reached ONLY via the SuperPaymaster core's fallback (DELEGATECALL): every function here
 *         runs against the proxy's storage, `msg.sender` is the original caller and events are
 *         emitted by the proxy. Nothing here is called from validatePaymasterUserOp / postOp.
 *
 *         - Shares the core's storage chain (SuperPaymasterStorage); layouts are checked identical
 *           by scripts/check-sp-layout.py.
 *         - Adds only selectors the core does NOT have (scripts/check-sp-selectors.py). Functions
 *           it inherits from the shared base (UUPS, EntryPoint stake, ownership, public getters)
 *           are never reached through the proxy — the core answers those selectors.
 *         - Created by the core's constructor with the core's immutables (D5b-design §2.2).
 *           Non-upgradeable, no initializer; its own owner is cleared at construction, so a
 *           direct call only ever touches this contract's own unused storage and grants nothing.
 */
contract SuperPaymasterAdmin is SuperPaymasterStorage {
    using SafeERC20 for IERC20;

    /// @notice Window between queueing a `setAPNTsToken` change and being allowed to execute it.
    /// @dev    P0-9: was a single instant write; could strand operator deposits.
    uint256 public constant APNTS_TOKEN_TIMELOCK = 7 days;
    uint256 public constant EMERGENCY_TIMELOCK = 1 hours;
    uint256 internal constant CHAINLINK_STALE_THRESHOLD = 1 hours;
    /// @notice Anti-double-slash cooldown for the BLS/DVT slash path (executeSlashWithBLS).
    uint48 internal constant SLASH_BLS_COOLDOWN = 1 hours;
    uint256 internal constant EMERGENCY_PRICE_DEVIATION_BPS = 2000; // 20%
    /// @notice Maximum duration for which EMERGENCY mode may remain active.
    uint256 internal constant EMERGENCY_EXPIRY = 7 days;
    /// @notice P0-11: bounds for `setAPNTSPrice`.
    uint256 internal constant APNTS_PRICE_MIN = 1e15;       // 0.001 ether per aPNTs
    uint256 internal constant APNTS_PRICE_MAX = 1e21;       // 1000 ether per aPNTs
    uint256 internal constant APNTS_PRICE_DELTA_BPS = 1000; // 10%

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(IEntryPoint _entryPoint, IRegistry _registry, address _ethUsdPriceFeed)
        SuperPaymasterStorage(_entryPoint, _registry, _ethUsdPriceFeed)
    {
        // Inert when called directly: no owner in this contract's own storage (initializers are
        // already disabled by BasePaymasterUpgradeable's constructor).
        _transferOwnership(address(0));
    }

    /// @dev Unreachable through the proxy (the core answers this selector); inert if called directly.
    function validatePaymasterUserOp(PackedUserOperation calldata, bytes32, uint256)
        external pure override returns (bytes memory, uint256)
    {
        revert Unauthorized();
    }

    /// @dev Unreachable through the proxy (the core answers this selector); inert if called directly.
    function postOp(PostOpMode, bytes calldata, uint256, uint256) external pure override {
        revert Unauthorized();
    }

    // ====================================
    // GOV-2: guardian + pauses (spec 03 §10.7b B.6)
    // ====================================

    /// @notice Set (or clear, with address(0)) the emergency guardian. Owner only.
    function setGuardian(address newGuardian) external onlyOwner {
        emit GuardianSet(guardian, newGuardian);
        guardian = newGuardian;
    }

    /// @dev Owner: any value. Guardian: ONLY `true` (pause). Everyone else — and the guardian
    ///      passing `false` — reverts.
    function _requirePauseAuthority(bool pausing) internal view {
        if (msg.sender == owner()) return;
        address g = guardian;
        // An unset guardian (address(0)) authorises nobody — explicit, not "no one can be msg.sender 0".
        if (pausing && g != address(0) && msg.sender == g) return;
        revert Unauthorized();
    }

    /**
     * @notice Pause / unpause an operator. Owner: both directions. Guardian: pause only.
     * @dev    GOV-2 B.6 ①: NOT a plain `onlyOwnerOrGuardian` bool setter — the guardian passing
     *         `false` reverts, so unpausing always goes through the owner (the timelock).
     */
    function setOperatorPaused(address operator, bool isPaused) external {
        _requirePauseAuthority(isPaused);
        operators[operator].isPaused = isPaused;
        if (isPaused) {
            emit OperatorPaused(operator);
        } else {
            emit OperatorUnpaused(operator);
        }
    }

    /**
     * @notice Stop (true) or resume (false) ALL sponsorship. Owner: both. Guardian: stop only.
     * @dev    GOV-2 B.6 ②. While set, validatePaymasterUserOp returns SIG_FAILURE for every op before
     *         parsing it; postOp, releaseStaleSponsorship and the token-side stale release keep
     *         working, so ops already in flight settle or are released normally.
     */
    function setGlobalPaused(bool isPaused) external {
        _requirePauseAuthority(isPaused);
        paused = isPaused;
        emit GlobalPauseSet(msg.sender, isPaused);
    }

    // ====================================
    // Operator Management
    // ====================================

    /// @notice Registers msg.sender as an operator with the given xPNTs token (must be the token the
    ///         wired factory issued for msg.sender, and a balance-mode v2 token).
    function configureOperator(address xPNTsToken, address _opTreasury) external {
        _requireSuperOperatorRoleFor(msg.sender);
        // BUS-RULE: Must be Community to be Paymaster
        if (!REGISTRY.hasRole(keccak256("COMMUNITY"), msg.sender)) {
            revert Unauthorized();
        }
        if (xPNTsToken == address(0) || _opTreasury == address(0)) {
            revert InvalidConfiguration();
        }

        // P1-4: Factory binding is always required.
        address factory = xpntsFactory;
        if (factory == address(0)) revert InvalidConfiguration();
        address validToken = IxPNTsFactory(factory).getTokenAddress(msg.sender);
        if (validToken != xPNTsToken) revert InvalidXPNTsToken();
        // 5.5.0: only balance-mode (xPNTs v2) tokens can back an operator.
        try IxPNTsTokenV2(xPNTsToken).BALANCE_MODE_VERSION() returns (uint16 v) {
            if (v != 1) revert InvalidXPNTsToken();
        } catch {
            revert InvalidXPNTsToken();
        }

        ISuperPaymaster.OperatorConfig storage config = operators[msg.sender];
        config.xPNTsToken = xPNTsToken;
        config.treasury = _opTreasury;
        config.isConfigured = true;

        emit ISuperPaymaster.OperatorConfigured(msg.sender, xPNTsToken, _opTreasury);
    }

    function setOperatorLimits(uint48 _minTxInterval) external {
        _requireSuperOperatorRoleFor(msg.sender);
        operators[msg.sender].minTxInterval = _minTxInterval;
        emit OperatorMinTxIntervalUpdated(msg.sender, _minTxInterval);
    }

    /**
     * @notice Batch update blocked status for users (Called by Registry via DVT)
     */
    function updateBlockedStatus(address operator, address[] calldata users, bool[] calldata statuses) external {
        if (msg.sender != address(REGISTRY)) revert Unauthorized();
        if (users.length != statuses.length) revert InvalidConfiguration();

        for (uint256 i = 0; i < users.length; i++) {
            userOpState[operator][users[i]].isBlocked = statuses[i];
            emit UserBlockedStatusUpdated(operator, users[i], statuses[i]);
        }
    }

    /**
     * @notice Update SBT holder status (Called by Registry)
     */
    function updateSBTStatus(address user, bool status) external {
        if (msg.sender != address(REGISTRY)) revert Unauthorized();
        sbtHolders[user] = status;
    }

    // ====================================
    // aPNTs token swap (P0-9)
    // ====================================

    /// @notice Queue a new APNTS_TOKEN (effective after APNTS_TOKEN_TIMELOCK via executeAPNTsTokenChange).
    ///         Re-queueing refreshes the timer.
    function setAPNTsToken(address newAPNTsToken) external onlyOwner {
        if (newAPNTsToken == address(0)) revert InvalidAddress();
        pendingAPNTsToken = newAPNTsToken;
        pendingAPNTsTokenEta = block.timestamp + APNTS_TOKEN_TIMELOCK;
        emit APNTsTokenChangeQueued(newAPNTsToken, pendingAPNTsTokenEta);
    }

    /// @notice Abort a queued APNTS_TOKEN swap before it executes.
    function cancelAPNTsTokenChange() external onlyOwner {
        address pending = pendingAPNTsToken;
        if (pending == address(0)) return; // idempotent
        pendingAPNTsToken = address(0);
        pendingAPNTsTokenEta = 0;
        emit APNTsTokenChangeCancelled(pending);
    }

    /// @notice Apply a previously queued APNTS_TOKEN swap. Owner only; requires the timelock to
    ///         have elapsed AND every operator balance drained (totalTrackedBalance ==
    ///         protocolRevenue <= PROTOCOL_REVENUE_BUFFER).
    function executeAPNTsTokenChange() external onlyOwner {
        address pending = pendingAPNTsToken;
        if (pending == address(0)) revert InvalidConfiguration();
        if (block.timestamp < pendingAPNTsTokenEta) revert InvalidConfiguration();
        if (totalTrackedBalance != protocolRevenue || protocolRevenue > PROTOCOL_REVENUE_BUFFER) revert InvalidConfiguration();

        address oldToken = APNTS_TOKEN;
        APNTS_TOKEN = pending;
        pendingAPNTsToken = address(0);
        pendingAPNTsTokenEta = 0;
        emit APNTsTokenChangeExecuted(oldToken, pending, block.timestamp);
        emit APNTsTokenUpdated(oldToken, pending);
    }

    // ====================================
    // Owner parameters
    // ====================================

    /**
     * @notice Set the APNTS Price in USD (Owner Only)
     * @dev P0-11: absolute MIN/MAX and a ±10% per-update delta (skipped when the old price is 0).
     *      Independent of the break-glass ±20% band of `emergencySetPrice` (different storage).
     */
    function setAPNTSPrice(uint256 newPrice) external onlyOwner {
        // APNTS_PRICE_MIN > 0, so this also rejects newPrice == 0.
        if (newPrice < APNTS_PRICE_MIN || newPrice > APNTS_PRICE_MAX) revert InvalidConfiguration();
        uint256 oldPrice = aPNTsPriceUSD;
        if (oldPrice != 0) {
            uint256 lower;
            uint256 upper;
            unchecked {
                lower = oldPrice * (BPS_DENOMINATOR - APNTS_PRICE_DELTA_BPS) / BPS_DENOMINATOR;
                upper = oldPrice * (BPS_DENOMINATOR + APNTS_PRICE_DELTA_BPS) / BPS_DENOMINATOR;
            }
            if (newPrice < lower || newPrice > upper) revert InvalidConfiguration();
        }
        aPNTsPriceUSD = newPrice;
        emit APNTsPriceUpdated(oldPrice, newPrice);
    }

    /// @notice Set the protocol fee basis points (Owner Only; hard cap MAX_PROTOCOL_FEE)
    function setProtocolFee(uint256 newFeeBPS) external onlyOwner {
        if (newFeeBPS > MAX_PROTOCOL_FEE) revert InvalidConfiguration();
        uint256 oldFee = protocolFeeBPS;
        protocolFeeBPS = newFeeBPS;
        emit ProtocolFeeUpdated(oldFee, newFeeBPS);
    }

    /// @notice Set the protocol treasury address (Owner Only)
    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert InvalidAddress();
        emit TreasuryUpdated(treasury, _treasury);
        treasury = _treasury;
    }

    function setXPNTsFactory(address _factory) external onlyOwner {
        if (_factory == address(0)) revert InvalidAddress();
        emit XPNTsFactoryUpdated(xpntsFactory, _factory);
        xpntsFactory = _factory;
    }

    /// @notice Set ERC-8004 agent registries (Owner only). The identity registry is called from
    ///         validation (`isRegisteredAgent`) and MUST be ERC-7562 compliant. address(0) disables.
    function setAgentRegistries(address _identity, address _reputation) external onlyOwner {
        if (_identity != address(0) && _identity.code.length == 0) revert InvalidAddress();
        if (_reputation != address(0) && _reputation.code.length == 0) revert InvalidAddress();
        agentIdentityRegistry = _identity;
        agentReputationRegistry = _reputation;
        emit AgentRegistriesUpdated(_identity, _reputation);
    }

    /**
     * @notice Withdraw accumulated Protocol Revenue (leaves PROTOCOL_REVENUE_BUFFER).
     */
    function withdrawProtocolRevenue(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        uint256 available = protocolRevenue > PROTOCOL_REVENUE_BUFFER
            ? protocolRevenue - PROTOCOL_REVENUE_BUFFER
            : 0;
        if (amount > available) revert InsufficientRevenue();

        protocolRevenue -= amount;
        totalTrackedBalance -= amount;
        IERC20(APNTS_TOKEN).safeTransfer(to, amount);

        emit ProtocolRevenueWithdrawn(to, amount);
    }

    // ====================================
    // GOV-5: governable gas parameters
    // ====================================

    function _gp() internal view returns (GasParams memory p) {
        uint256 r = _gpRaw();
        p = GasParams(uint32(r), uint32(r >> 32), uint32(r >> 64), uint32(r >> 96));
    }

    function _checkGasParams(uint256 minPost, uint256 settle, uint256 cWrap, uint256 cPostop) private pure {
        if (settle < GP_SETTLE_MIN || settle > GP_SETTLE_MAX
            || minPost < settle + GP_MINPOST_OVER_SETTLE || minPost > GP_MINPOST_MAX
            || cPostop < GP_CPOSTOP_MIN || cPostop > minPost
            || cWrap < GP_CWRAP_MIN || cWrap > GP_CWRAP_MAX) revert InvalidConfiguration();
    }

    /// @notice Queue new gas parameters; effective after GP_TIMELOCK via `executeGasParams`.
    function queueGasParams(uint32 minPostOpGas, uint32 settleGasBound, uint32 cWrap, uint32 cPostop) external onlyOwner {
        _checkGasParams(minPostOpGas, settleGasBound, cWrap, cPostop);
        uint64 eta = uint64(block.timestamp + GP_TIMELOCK);
        _pendingGasParams = PendingGasParams(minPostOpGas, settleGasBound, cWrap, cPostop, eta);
        emit GasParamsQueued(minPostOpGas, settleGasBound, cWrap, cPostop, eta);
    }

    /// @notice Owner-only. NOT relied upon for mid-bundle safety: an owner such as a
    ///         TimelockController with an open executor role can be driven from inside a user op.
    ///         Safety comes from the OpCtx snapshot (settleGasBound, cPostop, cWrap).
    function executeGasParams() external onlyOwner {
        PendingGasParams memory q = _pendingGasParams;
        if (q.eta == 0 || block.timestamp < q.eta) revert GasParamsTimelock();
        _checkGasParams(q.minPostOpGas, q.settleGasBound, q.cWrap, q.cPostop);
        _gasParams = GasParams(q.minPostOpGas, q.settleGasBound, q.cWrap, q.cPostop);
        delete _pendingGasParams;
        emit GasParamsExecuted(q.minPostOpGas, q.settleGasBound, q.cWrap, q.cPostop);
    }

    function cancelGasParams() external onlyOwner {
        if (_pendingGasParams.eta == 0) revert GasParamsTimelock();
        delete _pendingGasParams;
        emit GasParamsCancelled();
    }

    /// @notice Effective parameters (defaults when never set) and the pending proposal.
    function gasParams() external view returns (GasParams memory current, PendingGasParams memory pending) {
        return (_gp(), _pendingGasParams);
    }

    // ====================================
    // Price oracle (keeper / DVT / break-glass)
    // ====================================

    /// @notice True when Chainlink hasn't updated for at least CHAINLINK_STALE_THRESHOLD, or reverts.
    function _isChainlinkStale() internal view returns (bool) {
        try ETH_USD_PRICE_FEED.latestRoundData() returns (
            uint80, int256, uint256, uint256 chainlinkUpdatedAt, uint80
        ) {
            if (chainlinkUpdatedAt == 0) return true;
            return block.timestamp > chainlinkUpdatedAt + CHAINLINK_STALE_THRESHOLD;
        } catch {
            return true;
        }
    }

    function isChainlinkStale() external view returns (bool) { return _isChainlinkStale(); }

    /// @notice Returns the timestamp after which the cached price is considered stale (0 if never set).
    function priceValidUntil() external view returns (uint48) {
        if (cachedPrice.updatedAt == 0) return 0;
        return uint48(cachedPrice.updatedAt + priceStalenessThreshold);
    }

    function _checkEmergencyPrice(int256 newPrice) private view {
        if (newPrice <= 0) revert OracleError();
        if (!_isChainlinkStale()) revert ChainlinkNotStale();
        if (emergencyActivatedAt != 0 && block.timestamp > emergencyActivatedAt + EMERGENCY_EXPIRY) {
            revert EmergencyExpired();
        }

        int256 ref = cachedPrice.price;
        if (ref <= 0) revert OracleError();

        int256 lower = (ref * int256(int256(uint256(BPS_DENOMINATOR - EMERGENCY_PRICE_DEVIATION_BPS)))) / int256(uint256(BPS_DENOMINATOR));
        int256 upper = (ref * int256(int256(uint256(BPS_DENOMINATOR + EMERGENCY_PRICE_DEVIATION_BPS)))) / int256(uint256(BPS_DENOMINATOR));
        if (newPrice < lower || newPrice > upper) revert EmergencyPriceOutOfRange();
    }

    /// @notice Queue an emergency price update. Only honored when Chainlink is stale and the new
    ///         price stays within ±20% of the last cached price; executable after EMERGENCY_TIMELOCK.
    function emergencySetPrice(int256 newPrice) external onlyOwner {
        _checkEmergencyPrice(newPrice);

        emergencyPendingPrice = newPrice;
        emergencyQueuedAt = block.timestamp;
        emit EmergencyPriceQueued(newPrice, block.timestamp + EMERGENCY_TIMELOCK);
    }

    /// @notice Cancel a queued emergency price.
    function cancelEmergencyPrice() external onlyOwner {
        if (emergencyQueuedAt == 0) return; // idempotent
        int256 cancelled = emergencyPendingPrice;
        emergencyQueuedAt = 0;
        emergencyPendingPrice = 0;
        emit EmergencyPriceCancelled(cancelled);
    }

    /// @notice Apply a previously queued emergency price. Permissionless after the timelock, but
    ///         the stale-oracle, expiry and deviation gates are re-checked against execution-time state.
    function executeEmergencyPrice() external {
        if (emergencyQueuedAt == 0) revert NoEmergencyPending();
        if (block.timestamp < emergencyQueuedAt + EMERGENCY_TIMELOCK) {
            revert EmergencyTimelockNotElapsed();
        }

        int256 newPrice = emergencyPendingPrice;
        _checkEmergencyPrice(newPrice);
        cachedPrice.price = newPrice;
        cachedPrice.updatedAt = block.timestamp;
        cachedPrice.roundId = 0;
        cachedPrice.decimals = 8;

        if (priceMode != 1) {
            emit PriceModeChanged(priceMode, 1);
            priceMode = 1;
            emergencyActivatedAt = block.timestamp;
        }

        emergencyQueuedAt = 0;
        emergencyPendingPrice = 0;

        emit EmergencyPriceExecuted(newPrice);
        emit PriceUpdated(newPrice, block.timestamp);
    }

    /**
     * @notice Update price via DVT/BLS consensus (Chainlink fallback)
     * @param chainlinkRecovered 0 = Chainlink still unavailable; 1 = recovered (clears priceMode).
     */
    function updatePriceDVT(
        int256 price,
        uint256 updatedAt,
        bytes calldata proof,
        uint8 chainlinkRecovered
    ) external {
        proof; // verified by BLSAggregator before it calls this function
        // 1. Verify caller authority (owner path = emergency break-glass; Chainlink ±20% guard below)
        if (msg.sender != BLS_AGGREGATOR && msg.sender != owner()) revert Unauthorized();

        // V3.6 FIX: Prevent Replay & Staleness
        if (updatedAt <= cachedPrice.updatedAt) revert OracleError(); // Must be strictly increasing
        if (updatedAt < block.timestamp - 2 hours) revert OracleError(); // Must be recent
        // P0-16: reject future timestamps (15 s keeper clock-skew grace).
        if (updatedAt > block.timestamp + TIMESTAMP_GRACE_SECONDS) revert OracleError();

        // 3. Validate price bounds
        if (price < MIN_ETH_USD_PRICE || price > MAX_ETH_USD_PRICE) revert OracleError();

        // 4. Deviation from Chainlink (±20%) when Chainlink is recent
        try ETH_USD_PRICE_FEED.latestRoundData() returns (
            uint80, int256 chainlinkPrice, uint256, uint256 chainlinkUpdatedAt, uint80
        ) {
            // P1-42: guard chainlinkPrice <= 0 to prevent div-by-zero
            if (chainlinkPrice > 0 && block.timestamp - chainlinkUpdatedAt < 2 hours) {
                int256 deviation = price > chainlinkPrice
                    ? (price - chainlinkPrice) * 100 / chainlinkPrice
                    : (chainlinkPrice - price) * 100 / chainlinkPrice;
                if (deviation > 20) revert OracleError();
            }
        } catch {
            // Chainlink down: DVT price accepted without deviation check
        }

        // 5. Update cache
        cachedPrice = PriceCache({
            price: price,
            updatedAt: updatedAt,
            roundId: 0, // DVT doesn't have Chainlink RoundID
            decimals: 8 // DVT normalizes to 8 decimals
        });

        if (chainlinkRecovered == 1 && priceMode != 0) {
            emit PriceModeChanged(priceMode, 0);
            priceMode = 0;
            emergencyActivatedAt = 0;
        }

        emit PriceUpdated(price, updatedAt);
    }

    /// @notice Update price cache from Chainlink oracle (keeper-callable).
    function updatePrice() external {
        try ETH_USD_PRICE_FEED.latestRoundData() returns (
            uint80 roundId,
            int256 price,
            uint256,
            uint256 updatedAt,
            uint80 answeredInRound
        ) {
            if (price < MIN_ETH_USD_PRICE || price > MAX_ETH_USD_PRICE) revert OracleError();
            if (updatedAt < block.timestamp - priceStalenessThreshold) revert OracleError();
            if (answeredInRound < roundId) revert OracleError();

            cachedPrice = PriceCache({
                price: price,
                updatedAt: updatedAt,
                roundId: roundId,
                decimals: 8
            });

            // P0-10: Chainlink came back — leave EMERGENCY mode and drop any queued override.
            if (priceMode != 0) {
                emit PriceModeChanged(priceMode, 0);
                priceMode = 0;
                emergencyActivatedAt = 0;
            }
            if (emergencyQueuedAt != 0) {
                int256 cancelled = emergencyPendingPrice;
                emergencyQueuedAt = 0;
                emergencyPendingPrice = 0;
                emit EmergencyPriceCancelled(cancelled);
            }

            emit PriceUpdated(price, updatedAt);
        } catch {
            // Chainlink down: keeper should call updatePriceDVT() with BLS proof, or the owner can
            // use emergencySetPrice + executeEmergencyPrice.
            revert OracleError();
        }
    }

    // ====================================
    // Credit view
    // ====================================

    /// @notice Remaining credit headroom for `user` on `token` (saturating; spec §10.4 / R4-H4).
    function getAvailableCredit(address user, address token) external view returns (uint256) {
        IxPNTsTokenV2 t = IxPNTsTokenV2(token);
        uint256 cap = t.effectiveCreditCap(user);
        uint256 used = t.debts(user) + t.creditReservedOf(user);
        return cap > used ? cap - used : 0;
    }

    // ====================================
    // Reputation & Slash Management
    // ====================================

    /**
     * @notice Mark an operator as having a pending slash (owner or BLS aggregator only).
     * @dev M-5: withdraw() is blocked until the slash executes or is cancelled. CC-13: the BLS
     *      path may not re-arm during its cooldown. Idempotent.
     */
    function queueSlash(address operator) external {
        if (msg.sender != owner() && msg.sender != BLS_AGGREGATOR) revert Unauthorized();
        if (msg.sender == BLS_AGGREGATOR && uint48(block.timestamp) < _blsCooldownEnd(operator)) revert SlashCooldown();
        _pendingSlash[operator] = true;
        emit SlashQueued(operator);
    }

    /// @dev Effective end of the BLS-slash cooldown: max(per-operator cooldown, global floor).
    function _blsCooldownEnd(address operator) internal view returns (uint48) {
        uint48 cd = _blsSlashCd[operator];
        uint48 fl = _blsSlashCdFloor;
        return fl > cd ? fl : cd;
    }

    /// @notice One-shot prime of the global BLS-slash cooldown floor to `now + SLASH_BLS_COOLDOWN`.
    function primeBlsSlashCooldown() external onlyOwner {
        _blsSlashCdFloor = uint48(block.timestamp) + SLASH_BLS_COOLDOWN;
        emit BlsSlashCooldownPrimed(_blsSlashCdFloor);
    }

    /// @notice Cancel a previously queued slash (owner only). Idempotent.
    function cancelSlash(address operator) external onlyOwner {
        _pendingSlash[operator] = false;
        emit SlashCancelled(operator);
    }

    /// @notice Whether `operator` currently has a slash queued (withdraw-blocking flag set).
    function isSlashPending(address operator) external view returns (bool) {
        return _pendingSlash[operator];
    }

    /**
     * @notice Slash an operator (Admin/Governance only). Requires queueSlash first; 24h cooldown.
     */
    function slashOperator(address operator, ISuperPaymaster.SlashLevel level, uint256 penaltyAmount, string calldata reason) external onlyOwner {
        require(_pendingSlash[operator], "SP: must queueSlash first");
        if (uint48(block.timestamp) < _slashCd[operator]) revert SlashCooldown();
        _slashCd[operator] = uint48(block.timestamp) + 24 hours;
        _slash(operator, level, penaltyAmount, reason, true);
        _pendingSlash[operator] = false;
    }

    /// @notice Update Operator Reputation (External Credit Manager)
    function updateReputation(address operator, uint256 newScore) external onlyOwner {
        if (newScore > type(uint32).max) revert ScoreExceedsUint32();
        operators[operator].reputation = uint32(newScore);
        emit ISuperPaymaster.ReputationUpdated(operator, newScore);
    }

    /**
     * @notice Execute slash triggered by BLS consensus (DVT Module only)
     */
    function executeSlashWithBLS(address operator, ISuperPaymaster.SlashLevel level, bytes calldata proof) external {
        if (msg.sender != BLS_AGGREGATOR) revert Unauthorized();
        require(_pendingSlash[operator], "SP: must queueSlash first");
        if (uint48(block.timestamp) < _blsCooldownEnd(operator)) revert SlashCooldown();
        _blsSlashCd[operator] = uint48(block.timestamp) + SLASH_BLS_COOLDOWN;

        // Logical penalty before cap: Warning=0, Minor=10%, Major=full balance (capped at 30% in _slash).
        uint256 penalty = 0;
        if (level == ISuperPaymaster.SlashLevel.MINOR) {
            penalty = operators[operator].aPNTsBalance / 10;
        } else if (level == ISuperPaymaster.SlashLevel.MAJOR) {
            penalty = operators[operator].aPNTsBalance;
        }

        bytes32 proofHash = keccak256(proof);

        _slash(operator, level, penalty, "DVT BLS Slash", true);
        _pendingSlash[operator] = false;

        emit SlashExecutedWithProof(operator, level, penalty, proofHash, block.timestamp);
    }

    /// @param applyCap If true, enforce 30% slash hardcap.
    function _slash(address operator, ISuperPaymaster.SlashLevel level, uint256 penaltyAmount, string memory reason, bool applyCap) internal {
        ISuperPaymaster.OperatorConfig storage config = operators[operator];

        uint256 reputationLoss = level == ISuperPaymaster.SlashLevel.WARNING ? 10 : (level == ISuperPaymaster.SlashLevel.MINOR ? 20 : 50);
        if (level == ISuperPaymaster.SlashLevel.MAJOR) config.isPaused = true;

        if (config.isPaused) {
             emit OperatorPaused(operator);
        }

        if (config.reputation > reputationLoss) config.reputation -= uint32(reputationLoss);
        else config.reputation = 0;

        if (penaltyAmount > 0) {
            if (applyCap) {
                // V3.6 SECURITY: Enforce 30% Slash Hardcap
                uint256 maxSlash = (uint256(config.aPNTsBalance) * 3000) / BPS_DENOMINATOR;
                if (penaltyAmount > maxSlash) {
                    penaltyAmount = maxSlash;
                    reason = string(abi.encodePacked(reason, " (Capped at 30%)"));
                }
            }

            if (config.aPNTsBalance >= penaltyAmount) {
                config.aPNTsBalance -= uint128(penaltyAmount);
                protocolRevenue += penaltyAmount;
            } else {
                uint256 actualBurn = config.aPNTsBalance;
                config.aPNTsBalance = 0;
                protocolRevenue += actualBurn;
                penaltyAmount = actualBurn;
            }
        }

        slashHistory[operator].push(ISuperPaymaster.SlashRecord({
            timestamp: block.timestamp,
            amount: penaltyAmount,
            reputationLoss: reputationLoss,
            reason: reason,
            level: level
        }));

        emit ISuperPaymaster.OperatorSlashed(operator, penaltyAmount, level);
        emit ISuperPaymaster.ReputationUpdated(operator, config.reputation);
    }

    // P0-3 (initial-deploy path): one-time setter when BLS_AGGREGATOR == address(0).
    function initBLSAggregator(address _bls) external onlyOwner {
        if (BLS_AGGREGATOR != address(0)) revert InvalidConfiguration(); // already initialized — use queue/apply
        if (_bls == address(0)) revert InvalidAddress();
        BLS_AGGREGATOR = _bls;
        emit BLSAggregatorUpdated(address(0), _bls);
    }

    // P0-3: 24h timelock on BLSAggregator replacement.
    function queueBLSAggregator(address _bls) external onlyOwner {
        if (_bls == address(0)) revert InvalidAddress();
        pendingBLSAgg = _bls;
        pendingBLSAggEta = uint48(block.timestamp + 24 hours);
        emit BLSAggregatorQueued(_bls, pendingBLSAggEta);
    }

    function applyBLSAggregator() external onlyOwner {
        address p = pendingBLSAgg;
        if (p == address(0)) revert InvalidConfiguration();
        if (uint48(block.timestamp) < pendingBLSAggEta) revert InvalidConfiguration();
        address old = BLS_AGGREGATOR;
        BLS_AGGREGATOR = p;
        pendingBLSAgg = address(0);
        pendingBLSAggEta = 0;
        emit BLSAggregatorUpdated(old, p);
    }

    // ====================================
    // Slash Query Interfaces
    // ====================================

    function getSlashHistory(address operator) external view returns (ISuperPaymaster.SlashRecord[] memory) {
        return slashHistory[operator];
    }

    function getSlashCount(address operator) external view returns (uint256) {
        return slashHistory[operator].length;
    }

    function getLatestSlash(address operator) external view returns (ISuperPaymaster.SlashRecord memory) {
        if (slashHistory[operator].length == 0) revert NoSlashHistory();
        return slashHistory[operator][slashHistory[operator].length - 1];
    }
}
