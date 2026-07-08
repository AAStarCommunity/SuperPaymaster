// SPDX-License-Identifier: Apache-2.0
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;
import "@openzeppelin-v5.0.2/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "../interfaces/IERC1363.sol";
import { IVersioned } from "src/interfaces/IVersioned.sol";
import { Math } from "@openzeppelin-v5.0.2/contracts/utils/math/Math.sol";

/// @dev CC-28: minimal view surface of xPNTsFactory used by the over-issue model.
interface IxPNTsFactoryCap {
    function aPNTsPriceUSD() external view returns (uint256);
    function industryScaleUSD(string calldata category) external view returns (uint256);
    function capRatioBps() external view returns (uint16);
    /// @dev Governance-assigned category for a token (community cannot self-select).
    function tokenCategory(address token) external view returns (string memory);
    /// @dev The canonical, governance-set SuperPaymaster — the ONLY trusted backing source.
    function SUPERPAYMASTER() external view returns (address);
}

/// @dev CC-28: minimal view of SuperPaymaster to read a community's staked aPNTs backing.
interface ISPStakeView {
    function operators(address operator) external view returns (
        uint128 aPNTsBalance,
        bool isConfigured,
        bool isPaused,
        address xPNTsToken,
        uint32 reputation,
        uint48 minTxInterval,
        address treasury,
        uint256 totalSpent,
        uint256 totalTxSponsored
    );
}


/**
 * @title xPNTsToken
 * @notice Community points token with pre-authorization mechanism
 * @dev ERC20 + EIP-2612 Permit + Auto-approval for trusted contracts
 *
 * Key Features:
 * - Override allowance() to return type(uint256).max for trusted spenders
 * - No need for users to approve() before using xPNTs
 * - EIP-2612 Permit for gasless approvals
 * - 1:1 conversion to aPNTs (Account Abstraction PNTs)
 *
 * Pre-Authorization:
 * - SuperPaymaster v2.0 (for depositing aPNTs)
 * - xPNTsFactory (for management)
 * - MySBT (for mint fees)
 *
 * Example Usage:
 * 1. User receives xPNTs from community
 * 2. User calls SuperPaymaster.depositAPNTs(100 ether)
 * 3. SuperPaymaster.burn() is called automatically (no approve needed!)
 * 4. User's aPNTs balance increases by 100
 */
contract xPNTsToken is Initializable, ERC20, ERC20Permit, IVersioned {

    // ====================================
    // Storage
    // ====================================

    /// @notice Factory contract that deployed this token
    address public FACTORY;

    /// @notice Community owner/admin address
    address public communityOwner;

    /// @notice The address of the trusted SuperPaymaster, which can call special functions.
    address public SUPERPAYMASTER_ADDRESS;

    /// @notice Pre-authorized spenders (no approve needed)
    mapping(address => bool) public autoApprovedSpenders;

    /// @notice One-shot emergency switch. While true, every burn path that
    ///         can affect another holder's balance is blocked, including the
    ///         SuperPaymaster `burnFromWithOpHash` / `recordDebt` paths and
    ///         the autoApproved-spender `burn(address,uint256)` path. Users
    ///         can still self-burn their own balance via `burn(uint256)`.
    /// @dev    P0-7 (B4-H1): the original `emergencyRevokePaymaster` only
    ///         cleared the `autoApprovedSpenders` flag for the current SP,
    ///         leaving `burnFromWithOpHash` (gated solely on
    ///         `msg.sender == SUPERPAYMASTER_ADDRESS`) wide open. A
    ///         compromised SP could keep draining holder balances at
    ///         MAX_SINGLE_TX_LIMIT per call until the community redeployed
    ///         the entire token. The flag-based design lets community owners
    ///         halt all dangerous paths in one transaction and re-enable
    ///         after rotating the SP via `setSuperPaymasterAddress`.
    bool public emergencyDisabled;
    /// @notice Community-controlled whitelist of x402 facilitators.
    /// @dev    P0-12b (D4): SuperPaymaster.settleX402PaymentDirect requires
    ///         `msg.sender` (the facilitator / operator) to be listed here in
    ///         addition to having `ROLE_PAYMASTER_SUPER`. This lets each
    ///         community decide which facilitators are trusted with their own
    ///         users' xPNTs balances, instead of trusting a single global
    ///         autoApproved spender across all communities. Distinct from
    ///         `autoApprovedSpenders` (ERC20 transferFrom firewall): this
    ///         mapping authorizes settle-time invocation, not transfer-time
    ///         allowance. The two are intentionally orthogonal.
    mapping(address => bool) public approvedFacilitators;

    /// @notice The SuperPaymaster address that was active when
    ///         `emergencyRevokePaymaster` was last called.
    /// @dev    Used by `unsetEmergencyDisabled` to enforce that
    ///         `setSuperPaymasterAddress` has been called with a *different*
    ///         address before the emergency flag can be cleared. Prevents
    ///         re-opening the drain path to the original compromised address.
    address public emergencyRevokedAddress;

    /// @notice Ensures a UserOperation hash is only used once for payment.
    mapping(bytes32 => bool) public usedOpHashes;

    /// @notice Community name
    string public communityName;

    /// @notice Community ENS domain
    string public communityENS;

    /// @notice Exchange rate with aPNTs (18 decimals, 1e18 = 1:1)
    /// @dev xPNTs amount = aPNTs amount * exchangeRate / 1e18
    uint256 public exchangeRate;

    /// @notice P1-14: timestamp of the last `updateExchangeRate` call.
    ///         0 means the rate has never been updated since initialization.
    ///         Used with `EXCHANGE_RATE_COOLDOWN` to enforce a minimum gap
    ///         between sequential rate updates.
    uint256 public exchangeRateUpdatedAt;

    // --- Added for Clone Compatibility ---
    string private _tokenName;
    string private _tokenSymbol;

    /// @notice User debt balance in aPNTs (protocol unit; converted to xPNTs at settlement)
    mapping(address => uint256) public debts;

    /// @dev Internal reentrancy status for clone-safe nonReentrant guard
    uint256 private _reentrancyStatus;

    /// @notice Maximum allowed single transaction amount in aPNTs (anti-bug safeguard)
    /// @dev Prevents catastrophic losses from code bugs while maintaining flexibility
    uint256 public maxSingleTxLimit = 5_000 ether;
    uint256 public constant MAX_SINGLE_TX_LIMIT_CAP = 50_000 ether; // $1000 safety ceiling

    // -----------------------------------------------------------------
    // P0-8 (B4-H2 / D8): per-spender daily burn cap
    // -----------------------------------------------------------------
    // Audit note (B4-H2): even with the $100 single-tx cap, a compromised
    // facilitator could call burn(victim_i, $100) in rapid sequence and drain
    // an unbounded number of holders before the community detects + revokes
    // the spender (P0-7). User decision D8 chose a per-spender daily cap
    // (not per-user) so that ordinary users have ZERO additional burden:
    // the cap travels with the spender, not the holder. Communities can
    // tune the cap via setSpenderDailyCap.
    struct SpenderRateLimit {
        uint128 dailyBurnTotal;  // cumulative xPNTs burned by this spender today
        uint64  windowStart;     // unix timestamp when the current 24h window opened
        uint64  reserved;        // packing slack for future use
    }
    mapping(address => SpenderRateLimit) public spenderRateLimit;

    /// @notice Maximum xPNTs that any non-self spender can burn per rolling 24h window.
    /// @dev    Default 50_000 ether (~$1000 at $0.02/xPNTs). Community owner can adjust.
    uint256 public spenderDailyCapTokens;

    /// @notice P0-12c: optional per-spender override of `spenderDailyCapTokens`.
    /// @dev    0 = no override (the spender falls back to the global cap). Lets a
    ///         community pin a TIGHTER daily cap on a specific autoApproved spender —
    ///         e.g. the standalone X402Facilitator, a newer / less-audited contract
    ///         than the core SuperPaymaster — without lowering the global cap the SP
    ///         burn path relies on. communityOwner-only. To fully disable a single
    ///         spender, use `removeAutoApprovedSpender` (0 here means "fall back",
    ///         not "disable", so the two semantics never collide).
    mapping(address => uint256) public spenderDailyCapOverride;

    /// @notice P1-17: opHash replay guard for the recordDebt fallback path.
    ///         Prevents double-debt when the burnFromWithOpHash path fails
    ///         (e.g. insufficient balance) and recordDebtWithOpHash is called
    ///         more than once for the same UserOp — which can happen if the
    ///         EntryPoint invariant is violated or a future code path retries.
    mapping(bytes32 => bool) public usedDebtHashes;

    /// @notice CC-28 tier-1: absolute hard cap on totalSupply (in xPNTs). 0 = disabled.
    /// @dev    A community-controlled circuit breaker (voluntary self-limit), NOT the auditor's
    ///         enforcement tool — a community can raise/clear it, so DVT relies on tier-2
    ///         (the value model), whose inputs are governance-controlled. tier-1 just lets a
    ///         community cap its own issuance defensively.
    uint256 public issuanceCap;

    function version() external pure override returns (string memory) {
        return "XPNTs-3.5.0"; // CC-28 over-issue model (issuanceCap + value-based cap)
    }

    /**
     * @dev Overridden to return storage variable
     */
    function name() public view virtual override returns (string memory) {
        return _tokenName;
    }

    /**
     * @dev Overridden to return storage variable
     */
    function symbol() public view virtual override returns (string memory) {
        return _tokenSymbol;
    }


    // ====================================
    // Events
    // ====================================

    event AutoApprovedSpenderAdded(address indexed spender);
    event AutoApprovedSpenderRemoved(address indexed spender);
    event CommunityOwnerUpdated(address indexed oldOwner, address indexed newOwner);
    event ExchangeRateUpdated(uint256 oldRate, uint256 newRate);
    event SuperPaymasterAddressUpdated(address indexed newSuperPaymaster);
    event DebtRecorded(address indexed user, uint256 amount);
    event DebtRepaid(address indexed user, uint256 amountRepaid, uint256 remainingDebt);
    event EmergencyDisabledSet(address indexed by);
    event EmergencyDisabledCleared(address indexed by);
    /// @notice P0-8: emitted when the per-spender daily burn cap is updated.
    event SpenderDailyCapUpdated(uint256 oldCap, uint256 newCap);
    event SpenderDailyCapForUpdated(address indexed spender, uint256 oldCap, uint256 newCap);
    /// @notice P0-8: emitted when a spender's daily window rolls over and counter resets.
    event SpenderRateLimitWindowReset(address indexed spender, uint64 newWindowStart);
    event FacilitatorApproved(address indexed facilitator);
    event FacilitatorRemoved(address indexed facilitator);
    /// @notice P1-16: emitted when the owner-configurable single-tx limit is updated.
    event MaxSingleTxLimitUpdated(uint256 oldLimit, uint256 newLimit);
    /// @notice CC-28: emitted when the absolute issuance hard cap is updated.
    event IssuanceCapUpdated(uint256 oldCap, uint256 newCap);


    // ====================================
    // Errors
    // ====================================

    error Unauthorized(address caller);
    error InvalidAddress(address addr);
    error OperationAlreadyProcessed(bytes32 userOpHash);
    /// @notice P1-17: thrown by recordDebtWithOpHash when the opHash was already processed
    error DebtAlreadyRecorded(bytes32 opHash);
    error UnauthorizedRecipient();
    error SingleTxLimitExceeded();
    error SuperPaymasterNotConfigured();
    error NoDebtToRepay();
    error RepayExceedsDebt();
    error BurnExceedsBalance();
    error MustUseBurnFromWithOpHash();
    error BurnExceedsAllowance();
    error ExchangeRateCannotBeZero();
    /// @notice P0-11: thrown when the new rate is outside [EXCHANGE_RATE_MIN, EXCHANGE_RATE_MAX].
    error ExchangeRateOutOfRange(uint256 rate, uint256 min, uint256 max);
    /// @notice P0-11: thrown when the per-call drift exceeds EXCHANGE_RATE_DELTA_BPS.
    error ExchangeRateDeltaTooLarge(uint256 newRate, uint256 oldRate, uint256 maxDeltaBPS);
    /// @notice P1-14: thrown when `updateExchangeRate` is called before the
    ///         1-hour cooldown since the last update has elapsed.
    error ExchangeRateCooldownActive();
    /// @notice P0-7: thrown when a burn-shaped path runs while the community
    ///         has flipped the emergency switch.
    error EmergencyStop();
    /// @notice P0-8: thrown when a spender's cumulative burn within a rolling
    ///         24h window would exceed `spenderDailyCapTokens`.
    error SpenderDailyCapExceeded(address spender, uint256 attempted, uint256 capRemaining);
    /// @notice P0-7 (P2): thrown when `unsetEmergencyDisabled` is called but
    ///         `setSuperPaymasterAddress` has not been called with a new address
    ///         since the emergency was declared. Clearing the flag while
    ///         `SUPERPAYMASTER_ADDRESS` still equals `emergencyRevokedAddress`
    ///         would immediately re-open the drain path to the compromised SP.
    error RecoveryNotComplete();
    /// @notice P1-16: thrown when `setMaxSingleTxLimit` receives an out-of-range value.
    error InvalidParam();

    /// @dev Only factory or community owner can call
    modifier onlyFactoryOrOwner() {
        if (msg.sender != FACTORY && msg.sender != communityOwner) revert Unauthorized(msg.sender);
        _;
    }

    // ====================================
    // Constructor
    // ====================================

    /**
     * @notice Deploy new xPNTs token
     * @param name Token name (e.g., "MyDAO Points")
     * @param symbol Token symbol (e.g., "xMDAO")
     * @param _communityOwner Community admin address
     * @param _communityName Community display name
     * @param _communityENS Community ENS domain
     * @param _exchangeRate Exchange rate with aPNTs (18 decimals, 0 = default 1:1)
     */
    // ====================================
    // IERC1363 Support (Push-based transfers)
    // ====================================

    /**
     * @dev Implementation contract constructor
     */
    constructor() ERC20("", "") ERC20Permit("") {
        _disableInitializers();
    }

    /**
     * @dev Clone-safe reentrancy guard modifier.
     * Since proxies (clones) have 0-initialized storage, we treat 0 and 1 as "not entered".
     */
    modifier nonReentrant() {
        require(_reentrancyStatus != 2, "ReentrancyGuard: reentrant call");
        _reentrancyStatus = 2;
        _;
        _reentrancyStatus = 1;
    }

    /**
     * @notice Transfer tokens to a contract and call onTransferReceived
     */
    function transferAndCall(address to, uint256 amount) external returns (bool) {
        return transferAndCall(to, amount, "");
    }

    /**
     * @notice Transfer tokens to a contract and call onTransferReceived with data
     */
    function transferAndCall(address to, uint256 amount, bytes memory data) public nonReentrant returns (bool) {
        transfer(to, amount);
        require(_checkOnTransferReceived(msg.sender, to, amount, data), "ERC1363: transfer to non-receiver");
        return true;
    }

    /**
     * @dev Internal function to invoke onTransferReceived on a target address.
     */
    function _checkOnTransferReceived(address from, address to, uint256 amount, bytes memory data) internal returns (bool) {
        if (to.code.length == 0) return true;
        try IERC1363Receiver(to).onTransferReceived(msg.sender, from, amount, data) returns (bytes4 retval) {
            return retval == IERC1363Receiver.onTransferReceived.selector;
        } catch {
            return false;
        }
    }

    /**
     * @notice Initialize token (replaces constructor for clone pattern)
     * @param name_ Token name
     * @param symbol_ Token symbol
     * @param _communityOwner Initial owner of the community
     * @param _communityName Display name
     * @param _communityENS ENS name
     * @param _exchangeRate aPNTs exchange rate
     */
    function initialize(
        string memory name_,
        string memory symbol_,
        address _communityOwner,
        string memory _communityName,
        string memory _communityENS,
        uint256 _exchangeRate
    ) external initializer {
        if (_communityOwner == address(0)) {
            revert InvalidAddress(_communityOwner);
        }

        FACTORY = msg.sender;
        communityOwner = _communityOwner;
        communityName = _communityName;
        communityENS = _communityENS;
        
        // Clone-specific metadata
        _tokenName = name_;
        _tokenSymbol = symbol_;

        // Set exchange rate (default 1:1 if not specified)
        exchangeRate = _exchangeRate > 0 ? _exchangeRate : 1 ether;

        // Auto-approve the factory
        autoApprovedSpenders[msg.sender] = true;

        // P0-8: default spender daily burn cap = 50_000 ether xPNTs (~$1000 @ $0.02).
        // Communities can tighten or loosen via setSpenderDailyCap.
        spenderDailyCapTokens = 50_000 ether;

        // P1-16: initialize configurable single-tx limit (clone-safe; storage default = 0).
        maxSingleTxLimit = 5_000 ether;
    }

    // ====================================
    // Pre-Authorization & Security Mechanism
    // ====================================

    /**
     * @notice Override allowance() to implement pre-authorization
     * @dev Auto-approved spenders have unlimited allowance, protected by firewall and single-tx limit
     */
    function allowance(address owner, address spender)
        public
        view
        override
        returns (uint256)
    {
        if (autoApprovedSpenders[spender]) {
            return type(uint256).max; // Unlimited allowance, protected by firewall
        }
        return super.allowance(owner, spender);
    }

    /**
     * @dev FIREWALL: Overrides the internal allowance spending mechanism.
     * This is the core security feature that prevents the SuperPaymaster from using
     * its infinite allowance with standard `transferFrom`.
     */
    /**
     * @notice Secure TransferFrom with firewall and single-tx limit
     * @dev Auto-approved spenders can only transfer to themselves or current SuperPaymaster
     */
    function transferFrom(address from, address to, uint256 value) public virtual override returns (bool) {
        // FIREWALL: Enforce destination rules for all auto-approved spenders
        if (autoApprovedSpenders[msg.sender]) {
            // Auto-approved members can ONLY move funds to themselves or the current SuperPaymaster
            if (to != msg.sender && to != SUPERPAYMASTER_ADDRESS) {
                 revert UnauthorizedRecipient();
            }

            // Single transaction limit in aPNTs — convert xPNTs → aPNTs before comparing
            if ((value * 1e18) / _requireRate() > maxSingleTxLimit) {
                revert SingleTxLimitExceeded();
            }

            // AUDIT H-2 (2026-06-11): pulling a holder's funds to oneself via
            // transferFrom is functionally equivalent to burn(victim, amount),
            // yet the P0-7 emergency halt and P0-8 daily rate limit were only
            // wired into the burn path — leaving this an unguarded drain route
            // for a compromised autoApproved spender. Apply the SAME two guards
            // to the self-pull case so emergencyDisabled is a true single-tx
            // kill switch.
            //
            // AUDIT 2026-07-04 (H-2 fix): the emergency kill switch was previously
            // keyed on the DESTINATION (guarded only `to == msg.sender && to != SP`),
            // so a *different* autoApproved spender (e.g. a compromised facilitator)
            // could set `to == SP` and keep moving every holder's balance into the SP
            // contract even AFTER emergencyRevokePaymaster() flipped the switch —
            // defeating the entire purpose of the kill switch (funds land in SP with
            // no profit to the attacker, i.e. griefing/forced-lock, but the halt must
            // still stop it). Fix: the emergency halt now applies to EVERY non-SP
            // caller regardless of destination; only the genuine `msg.sender == SP`
            // settle path is exempt.
            if (msg.sender != SUPERPAYMASTER_ADDRESS) {
                if (emergencyDisabled) revert EmergencyStop();
                // Daily cap intentionally exempts the settle path (to == SP) to
                // preserve legitimate settlement throughput (P0-8 design); self-pulls
                // (to == msg.sender) remain capped.
                if (to != SUPERPAYMASTER_ADDRESS) {
                    _checkAndConsumeRateLimit(msg.sender, value);
                }
            }
        }

        return super.transferFrom(from, to, value);
    }

    /**
     * @dev FIREWALL: Overrides the internal allowance spending mechanism.
     * This is the core security feature that prevents the SuperPaymaster from using
     * its infinite allowance with standard `transferFrom`.
     */
    function _spendAllowance(address owner, address spender, uint256 amount) internal virtual override {
        // Validation handled in transferFrom/burnFrom for auto-approved spenders
        if (autoApprovedSpenders[spender]) {
            return;
        }
        super._spendAllowance(owner, spender, amount);
    }

    /**
     * @notice The ONLY function the SuperPaymaster can call to deduct funds.
     * @param from The user's address to burn tokens from.
     * @param amountAPNTs The aPNTs amount to settle; converted to xPNTs internally
     *        using: xPNTs = ceil(amountAPNTs * exchangeRate / 1e18).
     * @param userOpHash The unique hash of the UserOperation, preventing replays.
     */
    function burnFromWithOpHash(address from, uint256 amountAPNTs, bytes32 userOpHash) external {
        // P0-7: gate before any state read so a compromised SP can't slip in
        // between revoke and rotation.
        if (emergencyDisabled) revert EmergencyStop();

        // 1. Identity Check: Only the registered SuperPaymaster can call this.
        if (msg.sender != SUPERPAYMASTER_ADDRESS) {
            revert Unauthorized(msg.sender);
        }

        // 2. Replay Protection: Ensure this UserOp hasn't been processed via EITHER path.
        // P1-17 cross-path: if the debt-recording fallback already settled this opHash
        // (usedDebtHashes), block the burn to prevent charging the user twice.
        if (usedOpHashes[userOpHash] || usedDebtHashes[userOpHash]) {
            revert OperationAlreadyProcessed(userOpHash);
        }

        // 3. Mark Hash as used
        usedOpHashes[userOpHash] = true;

        // 4. Single transaction limit in aPNTs (anti-bug safeguard)
        if (amountAPNTs > maxSingleTxLimit) {
            revert SingleTxLimitExceeded();
        }

        // 5. Convert aPNTs → xPNTs (ceil so protocol never under-collects)
        //    xPNTs = ceil(amountAPNTs * rate / 1e18)
        uint256 rate = _requireRate();
        uint256 xPNTsToBurn = (amountAPNTs * rate + 1e18 - 1) / 1e18;

        // 6. Execute Burn
        _burn(from, xPNTsToBurn);
    }


    
    // ====================================
    // Debt Management (V3.2)
    // ====================================

    /**
     * @notice Record user debt in aPNTs (only SuperPaymaster).
     *         All internal accounting uses aPNTs; xPNTs conversion happens at settlement.
     */
    function recordDebt(address user, uint256 amountAPNTs) external {
        // P0-7: emergency stop applies to debt accrual too — debts get auto-
        // repaid on next mint, so leaving this open during a compromise
        // would let the rogue SP create artificial liabilities.
        if (emergencyDisabled) revert EmergencyStop();

        if (SUPERPAYMASTER_ADDRESS == address(0)) revert SuperPaymasterNotConfigured();
        if (msg.sender != SUPERPAYMASTER_ADDRESS) {
            revert Unauthorized(msg.sender);
        }

        // Single transaction limit in aPNTs (anti-bug safeguard)
        if (amountAPNTs > maxSingleTxLimit) {
            revert SingleTxLimitExceeded();
        }

        debts[user] += amountAPNTs;
        emit DebtRecorded(user, amountAPNTs);
    }

    /**
     * @notice Record user debt in aPNTs with opHash replay protection (P1-17).
     * @dev    Preferred over recordDebt when the UserOp hash is available.
     *         Ensures that if postOp is somehow invoked twice for the same
     *         UserOp (EntryPoint invariant violation), the second call reverts
     *         rather than doubling the user's debt. The burnFromWithOpHash path
     *         already carries opHash replay protection via usedOpHashes; this
     *         function closes the same gap for the balance-insufficient fallback.
     *         SuperPaymaster._recordDebt calls this instead of recordDebt.
     */
    function recordDebtWithOpHash(address user, uint256 amountAPNTs, bytes32 opHash) external {
        if (emergencyDisabled) revert EmergencyStop();
        if (SUPERPAYMASTER_ADDRESS == address(0)) revert SuperPaymasterNotConfigured();
        if (msg.sender != SUPERPAYMASTER_ADDRESS) revert Unauthorized(msg.sender);
        if (amountAPNTs > maxSingleTxLimit) revert SingleTxLimitExceeded();
        // P1-17 cross-path: check BOTH hash maps so that a prior successful burn
        // (usedOpHashes set) blocks debt recording, and a prior debt record
        // (usedDebtHashes set) blocks a duplicate entry — regardless of which path
        // the first settlement used.
        if (usedOpHashes[opHash] || usedDebtHashes[opHash]) revert DebtAlreadyRecorded(opHash);
        usedDebtHashes[opHash] = true;
        debts[user] += amountAPNTs;
        emit DebtRecorded(user, amountAPNTs);
    }

    
    /**
     * @notice Manually repay debt by burning xPNTs.
     * @param amountXPNTs xPNTs to burn; converts to aPNTs = floor(amountXPNTs * 1e18 / rate).
     */
    function repayDebt(uint256 amountXPNTs) external {
        uint256 currentDebt = debts[msg.sender]; // aPNTs
        if (amountXPNTs == 0) return;
        if (currentDebt == 0) revert NoDebtToRepay();
        if (balanceOf(msg.sender) < amountXPNTs) revert BurnExceedsBalance();

        // Convert xPNTs → aPNTs (floor — user cannot over-repay via rounding)
        uint256 rate = _requireRate();
        uint256 repaidAPNTs = (amountXPNTs * 1e18) / rate;
        // If the xPNTs amount is too small to convert to ≥1 aPNTs, skip silently.
        if (repaidAPNTs == 0) return;
        if (repaidAPNTs > currentDebt) revert RepayExceedsDebt();

        debts[msg.sender] = currentDebt - repaidAPNTs;
        _burn(msg.sender, amountXPNTs);
        emit DebtRepaid(msg.sender, repaidAPNTs, debts[msg.sender]);
    }
    
    function getDebt(address user) external view returns (uint256) {
        return debts[user];
    }

    /// @dev Reads exchangeRate and reverts with ExchangeRateCannotBeZero if uninitialized.
    function _requireRate() private view returns (uint256 r) {
        r = exchangeRate;
        if (r == 0) revert ExchangeRateCannotBeZero();
    }

    /**
     * @notice Override _update to implement Auto-Repayment on mint.
     * @dev Debt is stored in aPNTs; value (minted xPNTs) is converted before comparing.
     *      repayXPNTs uses ceil so it is always ≥ 1 when repayAPNTs > 0 (no zero-burn).
     *      Invariant: ceil(floor(value/rate)×rate) ≤ value — proven safe, never burns more than minted.
     */
    function _update(address from, address to, uint256 value) internal virtual override {
        // Feature: Auto-Repayment ONLY on MINT (Income from Community/Protocol)
        // This preserves ERC20 standard behavior for regular user-to-user transfers.
        if (from == address(0) && to != address(0) && value > 0) {
            uint256 debt = debts[to]; // aPNTs
            if (debt > 0) {
                uint256 rate = _requireRate();
                // Convert minted xPNTs → aPNTs equivalent (floor)
                uint256 mintedAPNTs = (value * 1e18) / rate;
                if (mintedAPNTs > 0) {
                    uint256 repayAPNTs = mintedAPNTs > debt ? debt : mintedAPNTs;
                    // ceil: guarantees repayXPNTs ≥ 1 when repayAPNTs > 0; still ≤ value (proven)
                    uint256 repayXPNTs = (repayAPNTs * rate + 1e18 - 1) / 1e18;

                    // 1. Reduce Debt (aPNTs)
                    debts[to] -= repayAPNTs;

                    // 2. Process Mint (full amount for standard event)
                    super._update(from, to, value);

                    // 3. Immediately burn the xPNTs equivalent from 'to'
                    _burn(to, repayXPNTs);
                    emit DebtRepaid(to, repayAPNTs, debts[to]);
                    return;
                }
            }
        }

        super._update(from, to, value);
    }

    /**
     * @notice Sets or updates the trusted SuperPaymaster address.
     * @dev    Normal mode: factory or communityOwner may call this.
     *         Emergency mode (`emergencyDisabled == true`): only `communityOwner`
     *         may call. The factory is blocked because the emergency switch is
     *         designed to give the community — not the factory — exclusive control
     *         over recovery. Letting FACTORY rotate the SP during an active
     *         emergency would allow an entity that may itself be compromised to
     *         re-introduce a malicious paymaster while the community thinks the
     *         token is frozen.
     */
    function setSuperPaymasterAddress(address _spAddress) external {
        if (emergencyDisabled) {
            // Elevated restriction: only communityOwner during emergency
            if (msg.sender != communityOwner) revert Unauthorized(msg.sender);
        } else {
            // Normal mode: factory or communityOwner
            if (msg.sender != FACTORY && msg.sender != communityOwner) revert Unauthorized(msg.sender);
        }
        if (_spAddress == address(0)) {
            revert InvalidAddress(_spAddress);
        }

        // Security: Revoke privileges from the old SuperPaymaster to prevent "Privilege Retention"
        address oldSP = SUPERPAYMASTER_ADDRESS;
        if (oldSP != address(0) && oldSP != _spAddress) {
            if (autoApprovedSpenders[oldSP]) {
                autoApprovedSpenders[oldSP] = false;
                emit AutoApprovedSpenderRemoved(oldSP);
            }
        }

        SUPERPAYMASTER_ADDRESS = _spAddress;
        
        // Ensure new SuperPaymaster is auto-approved
        if (_spAddress != address(0)) {
            autoApprovedSpenders[_spAddress] = true;
            emit AutoApprovedSpenderAdded(_spAddress);
        }

        emit SuperPaymasterAddressUpdated(_spAddress);
    }

    /**
     * @notice Allow community owner to cut off Factory's management power
     * @dev Once renounced, FACTORY can no longer call restricted functions (mint, updateExchangeRate, etc.).
     *      B4-N2: also revokes the old factory's autoApprovedSpender privilege so a renounced or
     *      compromised factory address can no longer burn tokens via the autoApproved path.
     */
    function renounceFactory() external {
        if (msg.sender != communityOwner) revert Unauthorized(msg.sender);
        address oldFactory = FACTORY;
        if (oldFactory != address(0) && autoApprovedSpenders[oldFactory]) {
            autoApprovedSpenders[oldFactory] = false;
        }
        FACTORY = address(0);
    }

    /**
     * @notice Emergency function to revoke SuperPaymaster privileges
     * @dev Allows quick response to compromised or malicious Paymaster
     */
    /// @notice Halt every burn-shaped path that can touch another holder's
    ///         balance. Used when the SuperPaymaster (or an autoApproved
    ///         spender) is suspected of being compromised.
    /// @dev    P0-7: previously only cleared `autoApprovedSpenders[currentSP]`,
    ///         which left `burnFromWithOpHash` and `recordDebt` reachable from
    ///         the compromised SP because those gates check
    ///         `msg.sender == SUPERPAYMASTER_ADDRESS` directly. Flipping the
    ///         `emergencyDisabled` flag closes all dangerous paths in one tx.
    /// @dev SECURITY: communityOwner SHOULD be a multisig. A compromised EOA
    ///      communityOwner could call unsetEmergencyDisabled() immediately before
    ///      emergencyRevokePaymaster(), bypassing the emergency circuit breaker.
    ///      Deploy with communityOwner = Gnosis Safe or equivalent multisig.
    function emergencyRevokePaymaster() external {
        if (msg.sender != communityOwner) revert Unauthorized(msg.sender);

        address currentSP = SUPERPAYMASTER_ADDRESS;
        if (currentSP != address(0) && autoApprovedSpenders[currentSP]) {
            autoApprovedSpenders[currentSP] = false;
            emit AutoApprovedSpenderRemoved(currentSP);
        }

        // Record the compromised address so `unsetEmergencyDisabled` can
        // verify that address rotation has actually occurred before clearing
        // the emergency flag (P0-7 P2 review fix).
        emergencyRevokedAddress = currentSP;

        if (!emergencyDisabled) {
            emergencyDisabled = true;
            emit EmergencyDisabledSet(msg.sender);
        }
    }

    /// @notice Clear the emergency switch after the community has rotated
    ///         the SuperPaymaster (via `setSuperPaymasterAddress`) and is
    ///         ready to resume normal operation.
    /// @dev    Recovery flow: `emergencyRevokePaymaster` →
    ///         `setSuperPaymasterAddress(newSP)` → `unsetEmergencyDisabled`.
    ///         Calling this function before rotating the SP address reverts
    ///         with `RecoveryNotComplete` — this prevents the community owner
    ///         from accidentally re-trusting the compromised address.
    /// @dev SECURITY: communityOwner SHOULD be a multisig. A compromised EOA
    ///      communityOwner could call unsetEmergencyDisabled() immediately before
    ///      emergencyRevokePaymaster(), bypassing the emergency circuit breaker.
    ///      Deploy with communityOwner = Gnosis Safe or equivalent multisig.
    function unsetEmergencyDisabled() external {
        if (msg.sender != communityOwner) revert Unauthorized(msg.sender);
        if (!emergencyDisabled) return; // idempotent

        // P0-7 (P2 review): Enforce that the SP address has been rotated to a
        // different (non-compromised) address since `emergencyRevokePaymaster`
        // was called. If SUPERPAYMASTER_ADDRESS still equals the address that
        // was revoked, clearing the flag would immediately re-open every burn
        // path to the compromised SP.
        if (SUPERPAYMASTER_ADDRESS == emergencyRevokedAddress) revert RecoveryNotComplete();

        emergencyDisabled = false;
        emit EmergencyDisabledCleared(msg.sender);
    }

    /// @notice P1-16: update the owner-configurable single-tx limit.
    /// @dev    communityOwner only. `newLimit` must be > 0 and <= MAX_SINGLE_TX_LIMIT_CAP
    ///         to prevent a misconfigured or compromised owner from setting an
    ///         unbounded limit that negates the single-tx anti-bug safeguard.
    function setMaxSingleTxLimit(uint256 newLimit) external {
        if (msg.sender != communityOwner) revert Unauthorized(msg.sender);
        if (newLimit == 0 || newLimit > MAX_SINGLE_TX_LIMIT_CAP) revert InvalidParam();
        emit MaxSingleTxLimitUpdated(maxSingleTxLimit, newLimit);
        maxSingleTxLimit = newLimit;
    }

    // =====================================================================
    // CC-28: over-issue model (DVT audit rule ③)
    //
    // Two tiers a DVT auditor can read to detect an over-issuing community:
    //   tier-1  issuanceCap   — a community-set VOLUNTARY hard cap on totalSupply. Not the
    //                           auditor's tool (community can raise/clear it); a defensive
    //                           self-limit only.
    //   tier-2  value model   — issued USD value must stay within an effective cap of
    //                           (industry baseline) + (aPNTs staked in SuperPaymaster). This
    //                           is the auditor signal; its inputs are governance-controlled:
    //                             * category   → factory.tokenCategory (owner-assigned)
    //                             * baseline   → factory.industryScaleUSD/capRatioBps (owner)
    //                             * price      → factory.aPNTsPriceUSD (owner)
    //                             * backing SP → factory.SUPERPAYMASTER (owner, canonical)
    //                           so the audited community cannot spoof a false negative.
    //
    // Backing is aPNTs-stake-only for now; a future MyShop / IBackingSource can be added
    // additively without changing this ABI. isOverIssued() is what DVT calls per token.
    //
    // Residual, bounded evasions (documented, not exploitable for a clean pass):
    //   * exchangeRate re-pricing lowers issued value, but it is the real redemption rate and
    //     is bounded to +-20%/hr (EXCHANGE_RATE_DELTA_BPS) within [MIN,MAX] — devaluing the
    //     token genuinely lowers obligations, and DVT audits finalized snapshots.
    //   * renounceFactory() disables tier-2 (views degrade to tier-1); DVT should treat a
    //     factory-less token as unauditable/suspect at the enumeration layer.
    // =====================================================================

    /// @notice CC-28 tier-1: set the absolute hard cap on totalSupply (xPNTs). 0 = disabled.
    /// @dev    A voluntary community self-limit — DVT does not rely on this (see tier-2).
    function setIssuanceCap(uint256 newCap) external {
        if (msg.sender != communityOwner) revert Unauthorized(msg.sender);
        emit IssuanceCapUpdated(issuanceCap, newCap);
        issuanceCap = newCap;
    }

    /// @dev The governance-assigned category (factory.tokenCategory), else "default".
    ///      Never community-controlled — that would let the audited party pick its own baseline.
    function _categoryKey() internal view returns (string memory) {
        address f = FACTORY;
        if (f == address(0)) return "default";
        string memory c = IxPNTsFactoryCap(f).tokenCategory(address(this));
        return bytes(c).length == 0 ? "default" : c;
    }

    /// @notice CC-28: USD value (18 decimals) of all issued xPNTs.
    /// @dev    aPNTs-equivalent = totalSupply * 1e18 / exchangeRate; USD = aPNTs * price / 1e18.
    ///         Collapsed to totalSupply * price / exchangeRate. Rounded UP (Ceil) so a
    ///         community cannot sit exactly on the cap via a rounding-down false negative.
    ///         Returns 0 if the factory was renounced (price unknowable) — tier-2 then degrades.
    function issuedValueUSD() public view returns (uint256) {
        uint256 rate = exchangeRate;
        address f = FACTORY;
        if (rate == 0 || f == address(0) || totalSupply() == 0) return 0;
        return Math.mulDiv(totalSupply(), IxPNTsFactoryCap(f).aPNTsPriceUSD(), rate, Math.Rounding.Ceil);
    }

    /// @notice CC-28: USD value (18 decimals) of the community's aPNTs staked in SuperPaymaster.
    /// @dev    Reads ONLY the canonical, governance-set SuperPaymaster (factory.SUPERPAYMASTER),
    ///         never the token's community-mutable SUPERPAYMASTER_ADDRESS — otherwise a
    ///         community could point at a fake SP returning an inflated balance. Counts the
    ///         stake only when SP confirms the operator is configured AND linked to THIS token,
    ///         so unrelated operators' stake can't be borrowed as backing.
    function backingValueUSD() public view returns (uint256) {
        address f = FACTORY;
        if (f == address(0)) return 0;
        address sp = IxPNTsFactoryCap(f).SUPERPAYMASTER();
        if (sp == address(0)) return 0;
        (uint128 staked, bool isConfigured, , address linkedToken, , , , , ) =
            ISPStakeView(sp).operators(communityOwner);
        if (!isConfigured || linkedToken != address(this) || staked == 0) return 0;
        return Math.mulDiv(uint256(staked), IxPNTsFactoryCap(f).aPNTsPriceUSD(), 1e18);
    }

    /// @notice CC-28: effective issuance ceiling (USD, 18 dec) = industry baseline + aPNTs backing.
    function effectiveCapUSD() public view returns (uint256) {
        address f = FACTORY;
        if (f == address(0)) return 0;
        IxPNTsFactoryCap fc = IxPNTsFactoryCap(f);
        uint256 baseCap = Math.mulDiv(fc.industryScaleUSD(_categoryKey()), fc.capRatioBps(), 10_000);
        return baseCap + backingValueUSD();
    }

    /// @notice CC-28 rule ③: true when this community has over-issued xPNTs — either the
    ///         absolute issuanceCap (if set) is breached, or issued USD value exceeds the
    ///         effective cap (industry baseline + staked-aPNTs backing). DVT calls this.
    ///         Never reverts (safe for a DVT auditor).
    /// @dev    If the factory was renounced, tier-2 is unverifiable (no price/baseline/backing
    ///         source). We must NOT grant a clean pass — renouncing the factory would otherwise
    ///         be an over-issue escape hatch — so any live issuance is conservatively flagged.
    function isOverIssued() external view returns (bool) {
        if (issuanceCap != 0 && totalSupply() > issuanceCap) return true;
        if (FACTORY == address(0)) return totalSupply() > 0; // unverifiable → flag, never clear
        return issuedValueUSD() > effectiveCapUSD();
    }

    /// @notice CC-28: backing coverage as a 0-100 score (backing / issued value).
    /// @dev    100 when issuance is zero or fully backed; a low score flags thin backing.
    ///         Factory renounced => backing unverifiable => 0 (worst) if anything is issued.
    function credibilityScore() external view returns (uint8) {
        if (FACTORY == address(0)) return totalSupply() == 0 ? 100 : 0;
        uint256 issued = issuedValueUSD();
        if (issued == 0) return 100;
        uint256 score = Math.mulDiv(backingValueUSD(), 100, issued);
        return score >= 100 ? 100 : uint8(score);
    }

    /// @notice P0-8: tune the per-spender daily burn cap.
    /// @dev    Community-owner only. The cap applies to ANY non-self burn —
    ///         autoApproved facilitators, manually-approved spenders, etc.
    ///         A value of 0 effectively disables third-party burn entirely
    ///         (every burn would revert SpenderDailyCapExceeded).
    ///         The cap must not exceed type(uint128).max because
    ///         `SpenderRateLimit.dailyBurnTotal` is stored as uint128;
    ///         a larger cap would pass the newTotal > cap check but the
    ///         downcast `rl.dailyBurnTotal = uint128(newTotal)` would
    ///         truncate and silently reset the counter to 0.
    function setSpenderDailyCap(uint256 newCap) external {
        if (msg.sender != communityOwner) revert Unauthorized(msg.sender);
        // Guard: cap must fit in uint128 (storage type of dailyBurnTotal).
        // A cap > type(uint128).max would pass the `newTotal > cap` check
        // but the subsequent `uint128(newTotal)` downcast would truncate,
        // silently resetting the counter to 0 instead of reverting.
        if (newCap > type(uint128).max) revert SingleTxLimitExceeded();
        uint256 oldCap = spenderDailyCapTokens;
        spenderDailyCapTokens = newCap;
        emit SpenderDailyCapUpdated(oldCap, newCap);
    }

    /// @notice P0-12c: pin a per-spender daily burn cap that overrides the global
    ///         `spenderDailyCapTokens` for one autoApproved spender.
    /// @dev    Community-owner only. Intended to give a newer / less-audited
    ///         autoApproved spender (e.g. the standalone X402Facilitator) a TIGHTER
    ///         daily cap than the SP-shared global, shrinking the worst-case drain if
    ///         that spender is compromised. `newCap == 0` clears the override (the
    ///         spender reverts to the global cap); it does NOT disable the spender —
    ///         use `removeAutoApprovedSpender` for that. Same uint128 ceiling as the
    ///         global setter (storage type of `SpenderRateLimit.dailyBurnTotal`).
    function setSpenderDailyCapFor(address spender, uint256 newCap) external {
        if (msg.sender != communityOwner) revert Unauthorized(msg.sender);
        if (spender == address(0)) revert InvalidAddress(spender);
        if (newCap > type(uint128).max) revert SingleTxLimitExceeded();
        uint256 oldCap = spenderDailyCapOverride[spender];
        spenderDailyCapOverride[spender] = newCap;
        emit SpenderDailyCapForUpdated(spender, oldCap, newCap);
    }

    /// @dev P0-8: rolling 24-hour window per spender. Resets `dailyBurnTotal`
    ///      when the previous window has expired, then enforces the cap.
    ///      Self-burn (msg.sender == from) is NOT routed through here —
    ///      a holder burning their own balance is unrestricted.
    ///
    ///      Note: the SuperPaymaster `burnFromWithOpHash` path
    ///      (SUPERPAYMASTER_ADDRESS, gated on `msg.sender == SUPERPAYMASTER_ADDRESS`)
    ///      bypasses this rate limit entirely — it uses per-opHash replay
    ///      protection instead. P0-7 `emergencyDisabled` is the backstop for
    ///      that path: if the SuperPaymaster is compromised,
    ///      `emergencyRevokePaymaster()` halts `burnFromWithOpHash` in one tx.
    ///
    /// @dev KNOWN LIMITATION — Sybil bypass: an attacker controlling N approved-spender
    ///      addresses can collectively drain N × spenderDailyCapTokens per rolling
    ///      24-hour window.
    ///      Mitigations:
    ///      1. communityOwner (multisig) should periodically audit autoApprovedSpenders.
    ///      2. P0-7 emergencyRevokePaymaster() serves as the last-resort circuit breaker.
    ///      3. Per-spender cap is a speed bump, not an absolute guarantee.
    function _checkAndConsumeRateLimit(address spender, uint256 amount) internal {
        SpenderRateLimit storage rl = spenderRateLimit[spender];
        // Roll the rolling 24-hour window forward if 24h has elapsed (or no window yet).
        if (rl.windowStart == 0 || block.timestamp >= uint256(rl.windowStart) + 1 days) {
            rl.windowStart = uint64(block.timestamp);
            rl.dailyBurnTotal = 0;
            emit SpenderRateLimitWindowReset(spender, rl.windowStart);
        }
        // Cap check — uint128 sum is safe: setSpenderDailyCap enforces
        // newCap <= type(uint128).max, and MAX_SINGLE_TX_LIMIT = 5_000 ether
        // means a single call cannot push newTotal above uint128.max.
        uint256 newTotal = uint256(rl.dailyBurnTotal) + amount;
        // P0-12c: a non-zero per-spender override takes precedence over the global
        // cap — lets the community pin a tighter limit on a specific autoApproved
        // spender (e.g. X402Facilitator) than the SP-shared global default.
        uint256 cap = spenderDailyCapOverride[spender];
        if (cap == 0) cap = spenderDailyCapTokens;
        if (newTotal > cap) {
            revert SpenderDailyCapExceeded(
                spender,
                amount,
                cap > rl.dailyBurnTotal ? cap - rl.dailyBurnTotal : 0
            );
        }
        rl.dailyBurnTotal = uint128(newTotal);
    }

    /// @notice Add an address (e.g. SuperPaymaster) that can spend tokens without explicit approval.
    function addAutoApprovedSpender(address spender) external onlyFactoryOrOwner {
        if (spender == address(0)) {
            revert InvalidAddress(spender);
        }

        autoApprovedSpenders[spender] = true;
        emit AutoApprovedSpenderAdded(spender);
    }

    function removeAutoApprovedSpender(address spender) external {
        if (msg.sender != communityOwner) {
            revert Unauthorized(msg.sender);
        }

        autoApprovedSpenders[spender] = false;
        emit AutoApprovedSpenderRemoved(spender);
    }

    /**
     * @notice Authorize a facilitator to invoke
     *         `SuperPaymaster.settleX402PaymentDirect` against this xPNTs.
     * @dev    P0-12b (D4): community-controlled whitelist; only community
     *         owner can add/remove. AAStar's default facilitator is NOT
     *         auto-added by the factory — each community decides explicitly.
     *         A facilitator that is not in this set will be rejected by
     *         SuperPaymaster regardless of its `ROLE_PAYMASTER_SUPER` role.
     * @dev    Role separation: `approvedFacilitators` gates settle-call invocation
     *         only — it is NOT the allowance grant. Since v5.4 god-split, x402 lives
     *         in the standalone `X402Facilitator` contract, so the `transferFrom`
     *         inside `settleX402PaymentDirect` runs with `msg.sender = X402Facilitator`
     *         (not SP). The facilitator therefore MUST also be in `autoApprovedSpenders`
     *         to pull `from`'s xPNTs, and is bound by the same firewall (can only pull
     *         to itself, single-tx limit, emergencyDisabled, and the per-spender daily
     *         cap — `setSpenderDailyCapFor` can pin it tighter than the SP-shared
     *         global). The two whitelists are complementary: `approvedFacilitators`
     *         authorises the settle call, `autoApprovedSpenders` authorises the pull.
     * @dev SECURITY: communityOwner MUST be a multisig wallet (e.g., Gnosis Safe).
     *      A compromised single-EOA communityOwner can add arbitrary facilitators,
     *      enabling unauthorized token extraction. This contract cannot enforce
     *      multisig — the deployment process must ensure communityOwner != EOA.
     * @dev Prevents communityOwner from acting as both administrator and facilitator
     *      (conflict of interest: an owner-facilitator could exploit the auto-approved
     *      allowance they administer, bypassing the separation-of-duties guarantee).
     * @param facilitator Facilitator address to approve.
     */
    function addApprovedFacilitator(address facilitator) external {
        if (msg.sender != communityOwner) {
            revert Unauthorized(msg.sender);
        }
        if (facilitator == address(0)) {
            revert InvalidAddress(facilitator);
        }
        // Prevents communityOwner from acting as both administrator and facilitator
        // (conflict of interest)
        if (facilitator == communityOwner) {
            revert Unauthorized(facilitator);
        }
        approvedFacilitators[facilitator] = true;
        emit FacilitatorApproved(facilitator);
    }

    /**
     * @notice Revoke a facilitator's authorization (instant, no timelock).
     * @dev    P0-12b: incident-response primitive; community can yank a
     *         compromised facilitator without redeploying or upgrading SP.
     * @dev SECURITY: communityOwner MUST be a multisig wallet (e.g., Gnosis Safe).
     *      A compromised single-EOA communityOwner can add arbitrary facilitators,
     *      enabling unauthorized token extraction. This contract cannot enforce
     *      multisig — the deployment process must ensure communityOwner != EOA.
     * @param facilitator Facilitator address to remove.
     */
    function removeApprovedFacilitator(address facilitator) external {
        if (msg.sender != communityOwner) {
            revert Unauthorized(msg.sender);
        }
        approvedFacilitators[facilitator] = false;
        emit FacilitatorRemoved(facilitator);
    }

    // ====================================
    // Minting & Standard Burning
    // ====================================

    function mint(address to, uint256 amount) external onlyFactoryOrOwner {
        if (to == address(0)) {
            revert InvalidAddress(to);
        }

        _mint(to, amount);
    }

    /// @notice Burn `amount` tokens from `from`. When `msg.sender != from`,
    ///         allowance must be sufficient AND the spender's per-day burn
    ///         cap (P0-8) must not be exceeded.
    /// @dev    Security history:
    ///         - P0-7 (B4-H1): community emergency switch halts all third-party burns.
    ///         - P0-8 (B4-H2): spender path now uses canonical _spendAllowance
    ///           (instead of hand-rolled allowance arithmetic). Combined with
    ///           the per-spender daily rate limit, this closes the
    ///           "compromised facilitator drains many holders within
    ///           MAX_SINGLE_TX_LIMIT bursts" vector documented in T-14.
    ///         The autoApproved spender semantics are preserved: holders
    ///         still pay zero approval gas (allowance() returns max), but the
    ///         spender's cumulative burn is bounded by spenderDailyCapTokens.
    function burn(address from, uint256 amount) external {
        // P0-7: even autoApproved spenders (facilitators, etc.) are halted
        // by the community-level emergency switch. Self-burn (`burn(uint256)`)
        // remains available so users keep custody of their own balance.
        if (emergencyDisabled && msg.sender != from) revert EmergencyStop();

        // SECURITY: The SuperPaymaster is explicitly forbidden from using this function.
        if (msg.sender == SUPERPAYMASTER_ADDRESS) {
            revert MustUseBurnFromWithOpHash();
        }

        if (msg.sender != from) {
            // P0-8 part 1 (B4-H2 fix): canonical allowance enforcement.
            // For autoApproved spenders this is a no-op (allowance == max) by
            // the _spendAllowance override above — preserving zero user burden.
            // For everyone else, this reverts on insufficient allowance and
            // decrements the recorded allowance like a standard ERC20.
            uint256 allowed = allowance(from, msg.sender);
            if (allowed < amount) revert BurnExceedsAllowance();
            _spendAllowance(from, msg.sender, amount);

            // P0-8 part 2 (D8): per-spender daily burn cap. Applies to ALL
            // third-party spenders — both autoApproved and explicitly-
            // approved — so a compromised facilitator cannot iterate
            // burn(victim_i, $100) across many holders without bound.
            _checkAndConsumeRateLimit(msg.sender, amount);
        }
        _burn(from, amount);
    }

    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }

    // ... (rest of the original functions: updateExchangeRate, transferCommunityOwnership, getMetadata, etc.) ...
    
    /// @notice P0-11: bounds for `updateExchangeRate`. The xPNTs:aPNTs rate
    ///         is conceptually anchored to community service value, but
    ///         deploys vary widely. Allow 4 orders of magnitude on either
    ///         side of the 1:1 default and cap per-update drift to ±20%
    ///         (looser than SP's ±10% because per-community rates legitimately
    ///         move more than the protocol unit scale).
    uint256 public constant EXCHANGE_RATE_MIN = 1e14;        // 0.0001:1
    uint256 public constant EXCHANGE_RATE_MAX = 1e22;        // 10000:1
    uint256 public constant EXCHANGE_RATE_DELTA_BPS = 2000;  // 20%
    uint256 private constant BPS_DENOMINATOR = 10_000;
    /// @notice P1-14: minimum time between consecutive `updateExchangeRate` calls.
    ///         Prevents rapid sequential updates that compound the +/-20% delta
    ///         cap and move the rate far from its starting value within a short
    ///         window. A 1-hour cooldown limits drift to ~20% per hour.
    uint256 public constant EXCHANGE_RATE_COOLDOWN = 1 hours;

    /// @notice Update the xPNTs:aPNTs exchange rate.
    /// @dev P0-11 (B4-M2): pre-fix only checked `_newRate != 0`. Inline
    ///      bounds (absolute MIN/MAX + ±20% per-tx drift) bound the blast of
    ///      a misclick or compromised factory/owner. Delta check skipped on
    ///      the first set (the constructor default of 1e18 means oldRate is
    ///      already non-zero in practice; the guard is for robustness).
    function updateExchangeRate(uint256 _newRate) external onlyFactoryOrOwner {
        if (_newRate == 0) revert ExchangeRateCannotBeZero();
        if (_newRate < EXCHANGE_RATE_MIN || _newRate > EXCHANGE_RATE_MAX) revert ExchangeRateOutOfRange(_newRate, EXCHANGE_RATE_MIN, EXCHANGE_RATE_MAX);
        // P1-14: enforce cooldown between updates to prevent rapid compounding of the delta cap.
        if (exchangeRateUpdatedAt != 0 && block.timestamp < exchangeRateUpdatedAt + EXCHANGE_RATE_COOLDOWN) {
            revert ExchangeRateCooldownActive();
        }
        uint256 oldRate = exchangeRate;
        if (oldRate != 0) {
            uint256 lower = oldRate * (BPS_DENOMINATOR - EXCHANGE_RATE_DELTA_BPS) / BPS_DENOMINATOR;
            uint256 upper = oldRate * (BPS_DENOMINATOR + EXCHANGE_RATE_DELTA_BPS) / BPS_DENOMINATOR;
            if (_newRate < lower || _newRate > upper) revert ExchangeRateDeltaTooLarge(_newRate, oldRate, EXCHANGE_RATE_DELTA_BPS);
        }

        emit ExchangeRateUpdated(oldRate, _newRate);
        exchangeRate = _newRate;
        exchangeRateUpdatedAt = block.timestamp;
    }

    /// @dev The new owner SHOULD be a multisig. See addApprovedFacilitator for security rationale.
    function transferCommunityOwnership(address newOwner) external {
        if (msg.sender != communityOwner) {
            revert Unauthorized(msg.sender);
        }
        if (newOwner == address(0)) {
            revert InvalidAddress(newOwner);
        }

        address oldOwner = communityOwner;
        communityOwner = newOwner;

        emit CommunityOwnerUpdated(oldOwner, newOwner);
    }

    function getMetadata()
        external
        view
        returns (
            string memory _name,
            string memory _symbol,
            string memory _communityName,
            string memory _communityENS,
            address _communityOwner
        )
    {
        return (
            name(),
            symbol(),
            communityName,
            communityENS,
            communityOwner
        );
    }

    function needsApproval(address owner, address spender, uint256 amount)
        external
        view
        returns (bool)
    {
        uint256 currentAllowance = allowance(owner, spender);
        return currentAllowance < amount;
    }
}