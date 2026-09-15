// SPDX-License-Identifier: Apache-2.0
// AAStar.io contribution with love from 2023
pragma solidity 0.8.33;
import "./SuperPaymasterStorage.sol";
import { SuperPaymasterAdmin } from "./SuperPaymasterAdmin.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin-v5.0.2/contracts/token/ERC20/utils/SafeERC20.sol";
import "src/interfaces/IVersioned.sol";
import "../../../tokens/v2/IxPNTsTokenV2.sol";
import "../../../interfaces/v3/IAgentIdentityRegistry.sol";
// Kept for source compatibility: dependents historically received these names through this file.
import "../../../interfaces/IxPNTsFactory.sol";
import "../../../interfaces/v3/IAgentReputationRegistry.sol";

/**
 * @title SuperPaymaster (CORE)
 * @notice SuperPaymaster - Unified Registry based Multi-Operator Paymaster
 * @dev    D5b split (D5b-design §2): this CORE holds every ERC-4337 hot path — validatePaymasterUserOp,
 *         postOp, the reservation (`_reserveForOp`, `_tokenWord`), `releaseStaleSponsorship`,
 *         `inflightOf` — plus operator deposit / withdraw, EntryPoint deposit / stake, UUPS
 *         (`upgradeToAndCall`, `proxiableUUID`, `_authorizeUpgrade`) and the GOV-2 two-step ownership
 *         overrides (inherited from Ownable2StepNamespaced). Governance, administration and
 *         non-hot-path views are served by `EXTENSION` (SuperPaymasterAdmin) through `fallback()`
 *         (DELEGATECALL: shared storage, msg.sender / msg.value / event emitter stay the proxy's).
 *         Validation and postOp never cross the fallback, so ERC-7562 behaviour is unchanged.
 *
 *         The extension is created in this constructor with the SAME immutables, and is replaced
 *         together with the implementation on every upgrade. It is non-upgradeable, has no
 *         initializer, and calling it directly only touches its own unused storage.
 *
 *         SDK: calls go to one address; use the merged ABI `abis/SuperPaymaster.full.json`.
 */
contract SuperPaymaster is SuperPaymasterStorage, IVersioned {
    using SafeERC20 for IERC20;

    /// @notice Administration / governance / views implementation (SuperPaymasterAdmin).
    address public immutable EXTENSION;

    /// @dev 5.5.0 postOp context (spec §3.2, R10-M3: price snapshot taken at validation).
    struct OpCtx {
        address token;
        address user;
        uint256 a0;
        bytes32 opHash;
        address operator;
        uint8 mode;
        uint128 callGas;
        uint128 postOpGas;
        int256 price;
        uint8 decimals;
        uint256 aPriceUSD;
    }
    // Context format (Part B, Codex rounds 1-3). OpCtx is an upgrade-compatibility surface in
    // BOTH directions; every word of OpCtx stays ABI-canonical for its 5.5.0 type (never pack into
    // a narrow-typed word: 5.5.0's decoder reverts on dirty bits).
    //   emitted : abi.encode(OpCtx) (the 11 5.5.0 words, 352 B) ‖ one trailing word (384 B total):
    //             the GasParams slot as validation saw it (minPostOpGas | settleGasBound << 32 |
    //             cWrap << 64 | cPostop << 96; never zero — defaults substituted).
    //             5.5.0's `abi.decode(context, (OpCtx))` ignores the trailing word (rollback).
    //   accepted: 384 B → snapshot; 352 B (a 5.5.0 context, forward upgrade) → LEGACY rules;
    //             word 12 is read ONLY when the length is exactly 384.
    /// @dev Emit-only layout: OpCtx's 11 words + the trailing snapshot word.
    struct OpCtxOut {
        address token;
        address user;
        uint256 a0;
        bytes32 opHash;
        address operator;
        uint8 mode;
        uint128 callGas;
        uint128 postOpGas;
        int256 price;
        uint8 decimals;
        uint256 aPriceUSD;
        uint256 gasSnap;
    }
    uint256 internal constant CTX_LEN = 384;
    /// @dev 5.5.0 values, applied ONLY to a context produced by the 5.5.0 implementation (no
    ///      snapshot) that is settled by this implementation after a mid-bundle upgrade.
    uint256 internal constant LEGACY_SETTLE_GAS_BOUND = 160_000;
    uint256 internal constant LEGACY_C_WRAP_GAS = 30_000;
    bytes32 internal constant INFLIGHT_SEED = keccak256("SP.v5.5.inflight.live");

    function version() external pure virtual override returns (string memory) {
        return "SuperPaymaster-5.5.0"; // v5.5.0: AOA balance mode (xPNTs v2 escrow + reservation credit), in-flight sponsorship accounting
    }

    // ====================================
    // Constructor & Initializer (UUPS)
    // ====================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        IEntryPoint _entryPoint,
        IRegistry _registry,
        address _ethUsdPriceFeed
    ) SuperPaymasterStorage(_entryPoint, _registry, _ethUsdPriceFeed) {
        // D5b-design §2.2: the extension mirrors this implementation's immutables by construction.
        EXTENSION = address(new SuperPaymasterAdmin(_entryPoint, _registry, _ethUsdPriceFeed));
    }

    /**
     * @notice Initialize the UUPS proxy state
     * @param _owner Contract owner
     * @param _apntsToken aPNTs token address
     * @param _protocolTreasury Treasury address for protocol fees
     * @param _priceStalenessThreshold Oracle staleness threshold in seconds
     */
    function initialize(
        address _owner,
        address _apntsToken,
        address _protocolTreasury,
        uint256 _priceStalenessThreshold
    ) external initializer {
        if (_owner == address(0)) revert InvalidOwner();
        __BasePaymaster_init(_owner);
        // Note: _apntsToken can be address(0) during staged deployment
        // (deployed later via setAPNTsToken which has its own zero-address check)
        APNTS_TOKEN = _apntsToken;
        treasury = _protocolTreasury != address(0) ? _protocolTreasury : _owner;
        uint256 staleness = _priceStalenessThreshold > 0 ? _priceStalenessThreshold : 3600;
        // Same range as PaymasterBase.setPriceStalenessThreshold. There is no setter here, so this is
        // the only write: an oversized value underflows `block.timestamp - threshold` in updatePrice
        // and truncates `uint48(updatedAt + threshold)` (validUntil).
        if (staleness < 60 || staleness > 86400) revert InvalidConfiguration();
        priceStalenessThreshold = staleness;
        // Default values must be set explicitly (proxy storage doesn't inherit implementation defaults)
        aPNTsPriceUSD = 0.02 ether;
        protocolFeeBPS = 1000;
    }

    // ====================================
    // Extension routing
    // ====================================

    /// @dev Every selector this core does not define is executed by EXTENSION against the proxy's
    ///      storage. NON-payable: plain ETH transfers are still rejected (there is no receive()).
    fallback() external {
        address ext = EXTENSION;
        assembly {
            calldatacopy(0, 0, calldatasize())
            let ok := delegatecall(gas(), ext, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch ok
            case 0 { revert(0, returndatasize()) }
            default { return(0, returndatasize()) }
        }
    }

    // ====================================
    // Operator deposits / withdrawals
    // ====================================

    /// @notice Deposit aPNTs from msg.sender into their own operator balance (pull mode).
    function deposit(uint256 amount) external nonReentrant {
        _requireSuperOperatorRoleFor(msg.sender);
        // This might revert if Token blocks transferFrom (Secure Token)
        IERC20(APNTS_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        _creditDeposit(msg.sender, amount);
    }

    /// @dev Shared deposit accounting: overflow-check, credit operator balance,
    ///      bump totalTrackedBalance, emit. Used by deposit/onTransferReceived/depositFor.
    function _creditDeposit(address operator, uint256 amount) internal {
        if (amount > type(uint128).max) revert AmountExceedsUint128();
        // forge-lint: disable-next-line(unsafe-typecast)
        operators[operator].aPNTsBalance += uint128(amount);
        totalTrackedBalance += amount;
        emit ISuperPaymaster.OperatorDeposited(operator, amount);
    }

    /**
     * @notice Handle ERC1363 transferAndCall (Push Mode)
     * @dev Safe deposit mechanism for tokens blocking transferFrom
     */
    function onTransferReceived(address, address from, uint256 value, bytes calldata) external nonReentrant returns (bytes4) {
        if (msg.sender != APNTS_TOKEN) revert Unauthorized();
        _requireSuperOperatorRoleFor(from);
        _creditDeposit(from, value);
        return this.onTransferReceived.selector;
    }

    /// @notice Deposit aPNTs on behalf of a specific operator address (must approve first).
    function depositFor(address targetOperator, uint256 amount) external nonReentrant {
        _requireSuperOperatorRoleFor(targetOperator);
        IERC20(APNTS_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        _creditDeposit(targetOperator, amount);
    }

    /**
     * @notice Withdraw aPNTs
     * @dev M-5: Reverts when a slash has been queued for this operator via queueSlash().
     */
    function withdraw(uint256 amount) external nonReentrant {
        if (_pendingSlash[msg.sender]) revert SlashPending();
        if (operators[msg.sender].aPNTsBalance < amount) {
            revert InsufficientBalance(operators[msg.sender].aPNTsBalance, amount);
        }
        operators[msg.sender].aPNTsBalance -= uint128(amount);
        totalTrackedBalance -= amount;
        IERC20(APNTS_TOKEN).safeTransfer(msg.sender, amount);
        emit ISuperPaymaster.OperatorWithdrawn(msg.sender, amount);
    }

    // ====================================
    // Paymaster Implementation
    // ====================================

    function _calculateAPNTsAmount(uint256 ethAmountWei) internal view returns (uint256) {
        PriceCache memory cache = cachedPrice;
        int256 ethUsdPrice = cache.price;
        if (ethUsdPrice <= 0) revert OracleError();
        return Math.mulDiv(
            ethAmountWei * uint256(ethUsdPrice),
            1e18,
            (10**uint256(cache.decimals)) * aPNTsPriceUSD,
            Math.Rounding.Ceil
        );
    }

    function validatePaymasterUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 maxCost
    ) external override onlyEntryPoint nonReentrant returns (bytes memory context, uint256 validationData) {
        // 0. GOV-2 global stop: checked BEFORE anything in the op is parsed, so every op —
        //    including a malformed one — gets SIG_FAILURE, never a revert. Reads SP's own slot.
        if (paused) return ("", _packValidationData(true, 0, 0));

        // 1. Extract Operator
        address operator = _extractOperator(userOp);

        ISuperPaymaster.OperatorConfig storage config = operators[operator];

        // 2. Validate Operator Role & Config (Pure Storage)
        // Check 1: Must be Configured (implies registered/valid)
        if (!config.isConfigured) {
             return ("", _packValidationData(true, 0, 0));
        }

        // Initialize Validation Times
        // V3.6 FIX: Return validUntil to enforce Staleness Check and validAfter for Rate Limit
        uint48 validUntil = uint48(cachedPrice.updatedAt + priceStalenessThreshold);
        uint48 validAfter = 0;

        // Check 2: Must not be Paused
        if (config.isPaused) {
             return ("", _packValidationData(true, 0, 0));
        }

        // V5.3: Dual-channel identity check (SBT holder OR ERC-8004 Agent NFT)
        if (!isEligibleForSponsorship(userOp.sender)) {
             return ("", _packValidationData(true, 0, 0));
        }

        // C-04: reject a paymasterPostOpGasLimit too low for postOp to complete.
        // Without this an attacker forces postOp OOG and the optimistic operator
        // debit (below) is never refunded → operator drain + revenue inflation.
        // GOV-5: one SLOAD of SP's own slot (staked, STO-031); snapshotted into the context.
        uint256 gpRaw = _gpRaw();
        if (userOp.paymasterAndData.length >= POSTOP_GAS_OFFSET + 16) {
            uint128 pmPostOpGas = uint128(bytes16(userOp.paymasterAndData[POSTOP_GAS_OFFSET:POSTOP_GAS_OFFSET + 16]));
            if (pmPostOpGas < uint32(gpRaw)) {
                return ("", _packValidationData(true, 0, 0));
            }
        }

        // V3.2 Security: Check Blocklist & Rate Limit
        // CONSOLIDATED SLOAD: Get user state (Block status + Timestamp)
        UserOperatorState memory userState = userOpState[operator][userOp.sender];

        if (userState.isBlocked) {
             return ("", _packValidationData(true, 0, 0));
        }

        // V3.4: Rate Limiting (Using same SLOAD data)
        if (config.minTxInterval > 0) {
            uint48 lastTime = userState.lastTimestamp;
            // V3.6 FIX: Use validAfter to enforce rate limit instead of reverting on block.timestamp
            if (lastTime != 0) {
                 validAfter = lastTime + config.minTxInterval;
            }
        }

        // 2.1 Token binding + rate commitment (R4-H1; rug-pull protection)
        bytes calldata pmd = userOp.paymasterAndData;
        if (pmd.length < TOKEN_OFFSET + 20) return ("", _packValidationData(true, 0, 0));
        address token = address(bytes20(pmd[TOKEN_OFFSET:TOKEN_OFFSET + 20]));
        if (token != config.xPNTsToken) return ("", _packValidationData(true, 0, 0));
        uint8 flags = pmd.length > FLAGS_OFFSET ? uint8(pmd[FLAGS_OFFSET]) : 0;
        if (flags & (FLAG_SP_RENEW | FLAG_ACCOUNT_RENEW) == (FLAG_SP_RENEW | FLAG_ACCOUNT_RENEW)) {
            return ("", _packValidationData(true, 0, 0));
        }
        uint256 maxRate = abi.decode(pmd[RATE_OFFSET:RATE_OFFSET + 32], (uint256));
        // §3.3: every token call fails CLOSED → sigFail (AA34), never a validation revert (AA33)
        (bool rateOk, uint256 rate) = _tokenWord(token, abi.encodeCall(IxPNTsTokenV2.exchangeRate, ()), true, 32);
        if (!rateOk || rate > maxRate) return ("", _packValidationData(true, 0, 0));

        // 3. Reservation a0 (spec §10.3): full maxCost at the cached price, + fee + validation buffer
        uint256 aPNTsAmount = _calculateAPNTsAmount(maxCost);
        uint256 totalRate = BPS_DENOMINATOR + protocolFeeBPS + VALIDATION_BUFFER_BPS;
        aPNTsAmount = Math.mulDiv(aPNTsAmount, totalRate, BPS_DENOMINATOR, Math.Rounding.Ceil);

        // 4. Operator solvency — checked BEFORE touching the token
        if (uint256(config.aPNTsBalance) < aPNTsAmount) {
             return ("", _packValidationData(true, 0, 0));
        }

        // 5. User side: escrow first, credit only on INSUFFICIENT (R-2)
        uint8 mode = _reserveForOp(token, userOp.sender, userOpHash, aPNTsAmount, flags & FLAG_SP_RENEW != 0);
        if (mode == MODE_NONE) return ("", _packValidationData(true, 0, 0));

        // 6. Operator side: a0 is IN FLIGHT, not revenue, until postOp settles (R10-M1b)
        config.aPNTsBalance -= uint128(aPNTsAmount); // Safe cast due to check above
        config.totalSpent += aPNTsAmount;
        _inflight[userOpHash] = Inflight(operator, uint96(aPNTsAmount));
        _setInflightLive(userOpHash, true);

        PriceCache memory pc = cachedPrice;
        context = abi.encode(OpCtxOut({
            token: token,
            user: userOp.sender,
            a0: aPNTsAmount,
            opHash: userOpHash,
            operator: operator,
            mode: mode,
            callGas: uint128(uint256(userOp.accountGasLimits)),
            postOpGas: uint128(bytes16(pmd[POSTOP_GAS_OFFSET:POSTOP_GAS_OFFSET + 16])),
            price: pc.price,
            decimals: pc.decimals,
            aPriceUSD: aPNTsPriceUSD,
            gasSnap: gpRaw
        }));
        return (context, _packValidationData(false, validUntil, validAfter));
    }

    /// @dev Escrow-then-credit decision (spec §1). Any token failure → no sponsorship (H3-1).
    function _reserveForOp(address token, address user, bytes32 opHash, uint256 a0, bool spRenew)
        internal returns (uint8)
    {
        (bool ok, uint256 r) = _tokenWord(token, abi.encodeCall(IxPNTsTokenV2.tryLockForGas, (user, opHash, a0, spRenew)), false, 64);
        if (!ok) return MODE_NONE;
        if (r == uint256(IxPNTsTokenV2.LockResult.OK)) return MODE_BALANCE;
        if (r != uint256(IxPNTsTokenV2.LockResult.INSUFFICIENT)) return MODE_NONE;
        (ok, r) = _tokenWord(token, abi.encodeCall(IxPNTsTokenV2.tryReserveCredit, (user, opHash, a0)), false, 32);
        return ok && r == uint256(IxPNTsTokenV2.CreditResult.OK) ? MODE_CREDIT : MODE_NONE;
    }

    /// @dev Validation-time token call that can only fail CLOSED (§3.3, Codex D3): a revert, a
    ///      return shorter than the function's full ABI return (`minLen`: 64 for tryLockForGas's
    ///      two words, 32 otherwise), or any out-of-range first word is reported as `ok = false`
    ///      or a value the caller rejects — never a revert in SP. Copies at most 32 bytes of
    ///      return data (no return-bomb). A typed `try … returns (…)` would still revert on
    ///      malformed success data, because its decoding happens in the caller outside the catch.
    function _tokenWord(address token, bytes memory data, bool isStatic, uint256 minLen)
        private returns (bool ok, uint256 w)
    {
        assembly ("memory-safe") {
            switch isStatic
            case 1 { ok := staticcall(gas(), token, add(data, 32), mload(data), 0, 32) }
            default { ok := call(gas(), token, 0, add(data, 32), mload(data), 0, 32) }
            if lt(returndatasize(), minLen) { ok := 0 }
            w := mload(0)
        }
    }

    // dryRunValidation moved to SuperPaymasterLens in 5.5.0 (spec F1 / §5: EIP-170 headroom).

    function postOp(
        PostOpMode,
        bytes calldata context,
        uint256 actualGasCost,
        uint256 actualUserOpFeePerGas
    ) external override onlyEntryPoint nonReentrant {
        // GOV-2: deliberately NO `paused` check — an op that was validated settles (or is released)
        // normally even if sponsorship is stopped afterwards.
        if (context.length == 0) return;
        // B-1 §10.1 ③: never START a settlement that could run out of gas half-way. Reverting here
        // rolls back the user's execution (EntryPoint v0.7 innerHandleOp), so nothing is kept unpaid.
        // GOV-5: the bound is the VALIDATION-time snapshot (trailing word 12), read before
        // decoding and ONLY for a 384-byte context; the admitted limit satisfied MIN_v >= SETTLE_v +
        // 20k, so a parameter change executed mid-bundle cannot move it. Any other length (a 5.5.0
        // context: 352 B) has no snapshot and keeps the 5.5.0 bound.
        uint256 snap;
        if (context.length == CTX_LEN) {
            assembly ("memory-safe") { snap := calldataload(add(context.offset, 352)) }
        }
        uint256 snapSettle = uint32(snap >> 32);
        if (gasleft() < (snapSettle == 0 ? LEGACY_SETTLE_GAS_BOUND : snapSettle)) revert PostOpGasTooLow();

        OpCtx memory c = abi.decode(context, (OpCtx));

        // V3.6: rate-limit timestamp ALWAYS (griefing defence), even if the op reverted.
        if (operators[c.operator].minTxInterval > 0) {
            userOpState[c.operator][c.user].lastTimestamp = uint48(block.timestamp);
        }

        // P1-17 idempotency guard: set before all accounting.
        if (_settledDebtOps[c.opHash]) return;
        _settledDebtOps[c.opHash] = true;
        operators[c.operator].totalTxSponsored++;

        // R10-M3: conservative charge in wei, priced at the VALIDATION-time snapshot.
        // snapshot: C_POSTOP + C_WRAP of the validation; 5.5.0 context: the 5.5.0 formula itself
        // (postOpGasLimit + LEGACY_C_WRAP), i.e. exactly what that op was admitted and quoted under.
        uint256 bufGas = snap == 0
            ? uint256(c.postOpGas) + LEGACY_C_WRAP_GAS
            : uint256(uint32(snap >> 96)) + uint32(snap >> 64);
        uint256 bufWei = (bufGas + Math.ceilDiv((uint256(c.callGas) + c.postOpGas) * 10, 100)) * actualUserOpFeePerGas;
        uint256 aGas = Math.mulDiv(
            (actualGasCost + bufWei) * uint256(c.price), 1e18, (10 ** uint256(c.decimals)) * c.aPriceUSD, Math.Rounding.Ceil
        );
        uint256 charge = Math.mulDiv(aGas, BPS_DENOMINATOR + protocolFeeBPS, BPS_DENOMINATOR, Math.Rounding.Ceil);
        if (charge > c.a0) charge = c.a0;

        // B-1 §10.1 ①: NO try/catch. A failed settlement reverts postOp → EntryPoint rolls back
        // the user's execution; the escrow/reservation is then released after the transaction.
        if (c.mode == MODE_BALANCE) {
            IxPNTsTokenV2(c.token).settleLocked(c.user, c.opHash, charge);
        } else {
            IxPNTsTokenV2(c.token).settleCredit(c.user, c.opHash, charge);
        }

        // R10-M1b: in-flight a0 → revenue c, refund (a0 − c) to the operator. No shared-pool clamp.
        delete _inflight[c.opHash];
        _setInflightLive(c.opHash, false);
        operators[c.operator].aPNTsBalance += uint128(c.a0 - charge);
        protocolRevenue += charge;

        emit ISuperPaymaster.TransactionSponsored(c.operator, c.user, aGas, charge);
    }

    /// @notice R10-M1b: after the original transaction, restore an operator's in-flight a0 whose
    ///         postOp never completed (a postOp revert also rolled back the user's execution).
    ///         Permissionless and idempotent. The EntryPoint ETH for that op stays spent (I10).
    ///         GOV-2: works while sponsorship is paused.
    function releaseStaleSponsorship(bytes32 opHash) external {
        Inflight memory f = _inflight[opHash];
        if (f.operator == address(0)) return;
        if (_isInflightLive(opHash)) revert SponsorshipInFlight();
        delete _inflight[opHash];
        operators[f.operator].aPNTsBalance += uint128(f.a0);
        emit SponsorshipReleased(opHash, f.operator, f.a0);
    }

    function inflightOf(bytes32 opHash) external view returns (address operator, uint256 a0) {
        Inflight memory f = _inflight[opHash];
        return (f.operator, f.a0);
    }

    function _inflightSlot(bytes32 opHash) private pure returns (bytes32) {
        return keccak256(abi.encode(opHash, INFLIGHT_SEED));
    }

    function _setInflightLive(bytes32 opHash, bool on) private {
        bytes32 slot = _inflightSlot(opHash);
        uint256 v = on ? 1 : 0;
        assembly { tstore(slot, v) }
    }

    function _isInflightLive(bytes32 opHash) private view returns (bool live) {
        bytes32 slot = _inflightSlot(opHash);
        assembly { live := tload(slot) }
    }

    function _extractOperator(PackedUserOperation calldata userOp) internal pure returns (address) {
        // paymasterAndData: [paymaster(20)] [gasLimits(32)] [operator(20)] ...
        if (userOp.paymasterAndData.length < 72) return address(0);
        return address(bytes20(userOp.paymasterAndData[PAYMASTER_DATA_OFFSET:PAYMASTER_DATA_OFFSET+20]));
    }

    // ====================================
    // F1: Agent Sponsorship Policy (read inside validation)
    // ====================================

    /// @notice V5.3: Dual-channel eligibility — SBT holder OR registered ERC-8004 agent
    function isEligibleForSponsorship(address user) public view returns (bool) {
        return sbtHolders[user] || isRegisteredAgent(user);
    }

    /// @notice Check if an address is a registered ERC-8004 agent
    /// @dev Called inside validatePaymasterUserOp. ERC-7562 §3.2 permits this
    ///      external call because isRegisteredAgent(account) reads only
    ///      sender-associated storage, satisfying the "associated storage" rule.
    ///      try/catch degrades gracefully if the registry is self-destructed or buggy.
    function isRegisteredAgent(address account) public view returns (bool) {
        address reg = agentIdentityRegistry;
        if (reg == address(0)) return false;
        try IAgentIdentityRegistry(reg).isRegisteredAgent(account) returns (bool registered) {
            return registered;
        } catch {
            return false;
        }
    }
}
