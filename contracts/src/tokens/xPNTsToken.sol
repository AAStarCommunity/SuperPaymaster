// SPDX-License-Identifier: Apache-2.0
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;
import "@openzeppelin-v5.0.2/contracts/proxy/utils/Initializable.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "../interfaces/IERC1363.sol";
import { IVersioned } from "src/interfaces/IVersioned.sol";


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

    // --- Added for Clone Compatibility ---
    string private _tokenName;
    string private _tokenSymbol;

    /// @notice User debt balance in xPNTs
    mapping(address => uint256) public debts;

    /// @dev Internal reentrancy status for clone-safe nonReentrant guard
    uint256 private _reentrancyStatus;

    /// @notice Maximum allowed single transaction amount (anti-bug safeguard)
    /// @dev Prevents catastrophic losses from code bugs while maintaining flexibility
    uint256 public constant MAX_SINGLE_TX_LIMIT = 5_000 ether; // $100 @ $0.02/aPNTs

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

    function version() external pure override returns (string memory) {
        return "XPNTs-3.1.0-spender-daily-cap"; // P0-8: per-spender daily burn cap
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
    /// @notice P0-8: emitted when a spender's daily window rolls over and counter resets.
    event SpenderRateLimitWindowReset(address indexed spender, uint64 newWindowStart);
    event FacilitatorApproved(address indexed facilitator);
    event FacilitatorRemoved(address indexed facilitator);


    // ====================================
    // Errors
    // ====================================

    error Unauthorized(address caller);
    error InvalidAddress(address addr);
    error OperationAlreadyProcessed(bytes32 userOpHash);
    error UnauthorizedRecipient();
    error SingleTxLimitExceeded();
    error SuperPaymasterNotConfigured();
    error NoDebtToRepay();
    error RepayExceedsDebt();
    error BurnExceedsBalance();
    error MustUseBurnFromWithOpHash();
    error BurnExceedsAllowance();
    error ExchangeRateCannotBeZero();
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

            // Single transaction limit (anti-bug safeguard)
            if (value > MAX_SINGLE_TX_LIMIT) {
                revert SingleTxLimitExceeded();
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
     * @param amount The amount of tokens to burn.
     * @param userOpHash The unique hash of the UserOperation, preventing replays.
     */
    function burnFromWithOpHash(address from, uint256 amount, bytes32 userOpHash) external {
        // P0-7: gate before any state read so a compromised SP can't slip in
        // between revoke and rotation.
        if (emergencyDisabled) revert EmergencyStop();

        // 1. Identity Check: Only the registered SuperPaymaster can call this.
        if (msg.sender != SUPERPAYMASTER_ADDRESS) {
            revert Unauthorized(msg.sender);
        }

        // 2. Replay Protection: Ensure this UserOp hasn't been processed.
        if (usedOpHashes[userOpHash]) {
            revert OperationAlreadyProcessed(userOpHash);
        }

        // 3. Mark Hash as used
        usedOpHashes[userOpHash] = true;

        // 4. Single transaction limit (anti-bug safeguard)
        if (amount > MAX_SINGLE_TX_LIMIT) {
            revert SingleTxLimitExceeded();
        }

        // 5. Execute Burn
        _burn(from, amount);
    }


    
    // ====================================
    // Debt Management (V3.2)
    // ====================================

    /**
     * @notice Record user debt (only SuperPaymaster)
     */
    function recordDebt(address user, uint256 amountXPNTs) external {
        // P0-7: emergency stop applies to debt accrual too — debts get auto-
        // repaid on next mint, so leaving this open during a compromise
        // would let the rogue SP create artificial liabilities.
        if (emergencyDisabled) revert EmergencyStop();

        if (SUPERPAYMASTER_ADDRESS == address(0)) revert SuperPaymasterNotConfigured();
        if (msg.sender != SUPERPAYMASTER_ADDRESS) {
            revert Unauthorized(msg.sender);
        }

        // Single transaction limit (anti-bug safeguard)
        if (amountXPNTs > MAX_SINGLE_TX_LIMIT) {
            revert SingleTxLimitExceeded();
        }

        debts[user] += amountXPNTs;
        emit DebtRecorded(user, amountXPNTs);
    }

    
    /**
     * @notice Manually repay debt using user's xPNTs balance
     */
    function repayDebt(uint256 amount) external {
        uint256 currentDebt = debts[msg.sender];
        if (amount == 0) return;
        if (currentDebt == 0) revert NoDebtToRepay();
        if (amount > currentDebt) revert RepayExceedsDebt();
        if (balanceOf(msg.sender) < amount) revert BurnExceedsBalance();

        debts[msg.sender] = currentDebt - amount;
        _burn(msg.sender, amount);
        emit DebtRepaid(msg.sender, amount, debts[msg.sender]);
    }
    
    function getDebt(address user) external view returns (uint256) {
        return debts[user];
    }
    
    /**
     * @notice Override _update to implement Auto-Repayment
     */
    function _update(address from, address to, uint256 value) internal virtual override {
        // Feature: Auto-Repayment ONLY on MINT (Income from Community/Protocol)
        // This preserves ERC20 standard behavior for regular user-to-user transfers.
        if (from == address(0) && to != address(0) && value > 0) {
            uint256 debt = debts[to];
            if (debt > 0) {
                // Auto-Repay Logic
                uint256 repayAmount = value > debt ? debt : value;
                
                // 1. Reduce Debt
                debts[to] -= repayAmount;
                
                // 2. Process Mint (Full amount first for standard event emitting)
                super._update(from, to, value); 
                
                // 3. Immediately burn the repaid amount from 'to'
                if (repayAmount > 0) {
                    _burn(to, repayAmount);
                    emit DebtRepaid(to, repayAmount, debts[to]);
                }
                return;
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
     * @dev Once renounced, FACTORY can no longer call restricted functions (mint, updateExchangeRate, etc.)
     */
    function renounceFactory() external {
        if (msg.sender != communityOwner) revert Unauthorized(msg.sender);
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
        uint256 cap = spenderDailyCapTokens;
        if (newTotal > cap) {
            revert SpenderDailyCapExceeded(
                spender,
                amount,
                cap > rl.dailyBurnTotal ? cap - rl.dailyBurnTotal : 0
            );
        }
        rl.dailyBurnTotal = uint128(newTotal);
    }

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
     * @param facilitator Facilitator address to approve.
     */
    function addApprovedFacilitator(address facilitator) external {
        if (msg.sender != communityOwner) {
            revert Unauthorized(msg.sender);
        }
        if (facilitator == address(0)) {
            revert InvalidAddress(facilitator);
        }
        approvedFacilitators[facilitator] = true;
        emit FacilitatorApproved(facilitator);
    }

    /**
     * @notice Revoke a facilitator's authorization (instant, no timelock).
     * @dev    P0-12b: incident-response primitive; community can yank a
     *         compromised facilitator without redeploying or upgrading SP.
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

    /// @notice Update the xPNTs:aPNTs exchange rate.
    /// @dev P0-11 (B4-M2): pre-fix only checked `_newRate != 0`. Inline
    ///      bounds (absolute MIN/MAX + ±20% per-tx drift) bound the blast of
    ///      a misclick or compromised factory/owner. Delta check skipped on
    ///      the first set (the constructor default of 1e18 means oldRate is
    ///      already non-zero in practice; the guard is for robustness).
    function updateExchangeRate(uint256 _newRate) external onlyFactoryOrOwner {
        if (_newRate == 0) revert ExchangeRateCannotBeZero();
        if (_newRate < EXCHANGE_RATE_MIN || _newRate > EXCHANGE_RATE_MAX) revert ExchangeRateCannotBeZero();
        uint256 oldRate = exchangeRate;
        if (oldRate != 0) {
            uint256 lower = oldRate * (10000 - EXCHANGE_RATE_DELTA_BPS) / 10000;
            uint256 upper = oldRate * (10000 + EXCHANGE_RATE_DELTA_BPS) / 10000;
            if (_newRate < lower || _newRate > upper) revert ExchangeRateCannotBeZero();
        }

        emit ExchangeRateUpdated(oldRate, _newRate);
        exchangeRate = _newRate;
    }

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