SP = "contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol"
LENS = "contracts/src/paymasters/superpaymaster/v3/SuperPaymasterLens.sol"
TOK = "contracts/src/tokens/v2/xPNTsTokenV2.sol"
BASE = "contracts/src/tokens/v2/xPNTsV2Base.sol"

T = dict(
    admin="contracts/test/v3/SuperPaymasterV3_Admin.t.sol",
    pricing="contracts/test/v3/SuperPaymasterV3_Pricing.t.sol",
    v5f="contracts/test/v3/SuperPaymasterV5Features.t.sol",
    apnts="contracts/test/v3/SuperPaymaster_APNTs_Integration.t.sol",
    cov="contracts/test/v3/SuperPaymaster_Coverage.t.sol",
    bl="contracts/test/v3/BlacklistSync.t.sol",
    covs="contracts/test/v3/Coverage_Supplement.t.sol",
    blh="contracts/test/v3/Registry_BlacklistHardening.t.sol",
    m4="contracts/test/v3/SecurityFixes_M4_M5_M7.t.sol",
    uups="contracts/test/v3/UUPSUpgrade.t.sol",
    boost="contracts/test/v3/V3_Function_Boost.t.sol",
    c01="contracts/test/security/PoC_C01_CreditCeiling.t.sol",
    c04="contracts/test/security/PoC_C04_ForcedPostOpOOG.t.sol",
    dry="contracts/test/v3/DryRunValidation.t.sol",
    br="contracts/test/v3/SuperPaymaster_BurnRestore.t.sol",
    pf="contracts/test/v3/SuperPaymaster_PassiveFallback.t.sol",
    harden="contracts/test/paymasters/superpaymaster/v3/SuperPaymasterHardenVerification.t.sol",
    pv2="contracts/test/paymasters/superpaymaster/v3/SuperPaymasterPricingV2.t.sol",
    refund="contracts/test/paymasters/superpaymaster/v3/SuperPaymasterRefundTest.t.sol",
    v3="contracts/test/paymasters/superpaymaster/v3/SuperPaymasterV3.t.sol",
    query="contracts/test/paymasters/superpaymaster/v3/SuperPaymasterV3Query.t.sol",
    sec="contracts/test/paymasters/superpaymaster/v3/SuperPaymasterV3_Security.t.sol",
)
ALL = list(T.values())
SIGFAIL = 'return ("", _packValidationData(true, 0, 0));'

MUTATIONS = []


def M(id, *edits, tests=None, match=None):
    MUTATIONS.append(dict(id=id, edits=list(edits), tests=tests or ALL, match=match))


def E(f, old, new):
    return (f, old, new)


# ------------------------------------------------------------- configureOperator (SP 318-348)
M("CFG_probe_version", E(SP, "if (v != 1) revert InvalidXPNTsToken();", "v;"))
M("CFG_probe_catch", E(SP, "        } catch {\n            revert InvalidXPNTsToken();\n        }\n\n        OperatorConfig storage config",
                       "        } catch {\n        }\n\n        OperatorConfig storage config"))
M("CFG_factory_binding", E(SP, "if (validToken != xPNTsToken) revert InvalidXPNTsToken();", "validToken;"))
M("CFG_token_write", E(SP, "config.xPNTsToken = xPNTsToken;", ""))
M("CFG_treasury_write", E(SP, "config.treasury = _opTreasury;", ""))
M("CFG_configured_write", E(SP, "config.isConfigured = true;", ""))
M("VERSION", E(SP, 'return "SuperPaymaster-5.5.0";', 'return "SuperPaymaster-5.5.1";'))

# ------------------------------------------------------------- validatePaymasterUserOp (SP 1170-1278)
M("V_notconfigured", E(SP, "if (!config.isConfigured) {", "if (false) {"))
M("V_paused", E(SP, 'if (config.isPaused) {\n             return ("",', 'if (false) {\n             return ("",'))
M("V_eligible", E(SP, "if (!isEligibleForSponsorship(userOp.sender)) {", "if (false) {"))
M("V_postop_floor_minus1", E(SP, "if (pmPostOpGas < MIN_POST_OP_GAS) {", "if (pmPostOpGas < MIN_POST_OP_GAS - 1) {"))
M("V_postop_floor_off", E(SP, "if (pmPostOpGas < MIN_POST_OP_GAS) {", "if (false) {"))
M("V_blocked", E(SP, "if (userState.isBlocked) {", "if (false) {"))
M("V_validAfter", E(SP, "validAfter = lastTime + config.minTxInterval;", "validAfter = 0;"))
M("V_token_len", E(SP, "if (pmd.length < TOKEN_OFFSET + 20) " + SIGFAIL, ""))
M("V_token_binding", E(SP, "if (token != config.xPNTsToken) return", "if (false) return"))
M("V_both_flags", E(SP, "if (flags & (FLAG_SP_RENEW | FLAG_ACCOUNT_RENEW) == (FLAG_SP_RENEW | FLAG_ACCOUNT_RENEW)) {", "if (false) {"))
M("V_rate_commit", E(SP, "if (IxPNTsTokenV2(token).exchangeRate() > maxRate) {", "if (false) {"))
M("V_a0_no_buffer", E(SP, "uint256 totalRate = BPS_DENOMINATOR + protocolFeeBPS + VALIDATION_BUFFER_BPS;",
                      "uint256 totalRate = BPS_DENOMINATOR + protocolFeeBPS;"))
M("V_a0_no_fee", E(SP, "uint256 totalRate = BPS_DENOMINATOR + protocolFeeBPS + VALIDATION_BUFFER_BPS;",
                   "uint256 totalRate = BPS_DENOMINATOR + VALIDATION_BUFFER_BPS;"))
M("V_a0_floor", E(SP, "aPNTsAmount = Math.mulDiv(aPNTsAmount, totalRate, BPS_DENOMINATOR, Math.Rounding.Ceil);",
                  "aPNTsAmount = Math.mulDiv(aPNTsAmount, totalRate, BPS_DENOMINATOR, Math.Rounding.Floor);"))
_SOLV = ("        // 4. Operator solvency — checked BEFORE touching the token\n"
         "        if (uint256(config.aPNTsBalance) < aPNTsAmount) {\n"
         "             " + SIGFAIL + "\n        }\n\n"
         "        // 5. User side: escrow first, credit only on INSUFFICIENT (R-2)\n"
         "        uint8 mode = _reserveForOp(token, userOp.sender, userOpHash, aPNTsAmount, flags & FLAG_SP_RENEW != 0);\n"
         "        if (mode == MODE_NONE) " + SIGFAIL)
M("V_solvency_after_token", E(SP, _SOLV,
  "        uint8 mode = _reserveForOp(token, userOp.sender, userOpHash, aPNTsAmount, flags & FLAG_SP_RENEW != 0);\n"
  "        if (mode == MODE_NONE) " + SIGFAIL + "\n"
  "        if (uint256(config.aPNTsBalance) < aPNTsAmount) {\n             " + SIGFAIL + "\n        }\n"))
M("V_solvency_removed", E(SP, "        if (uint256(config.aPNTsBalance) < aPNTsAmount) {\n             " + SIGFAIL + "\n        }\n", ""))
M("V_mode_mislabel", E(SP, "if (r == IxPNTsTokenV2.LockResult.OK) return MODE_BALANCE;", "if (r == IxPNTsTokenV2.LockResult.OK) return MODE_CREDIT;"))
M("V_credit_fallback_off", E(SP, "return c == IxPNTsTokenV2.CreditResult.OK ? MODE_CREDIT : MODE_NONE;", "c; return MODE_NONE;"))
M("V_credit_on_any_lockfail", E(SP, "if (r != IxPNTsTokenV2.LockResult.INSUFFICIENT) return MODE_NONE;", ""))
M("V_operator_debit", E(SP, "config.aPNTsBalance -= uint128(aPNTsAmount); // Safe cast due to check above", ""))
M("V_totalSpent", E(SP, "config.totalSpent += aPNTsAmount;", ""))
M("V_inflight_write", E(SP, "_inflight[userOpHash] = Inflight(operator, uint96(aPNTsAmount));", ""))
M("V_inflight_live", E(SP, "_setInflightLive(userOpHash, true);", ""))
M("V_validUntil", E(SP, "uint48 validUntil = uint48(cachedPrice.updatedAt + priceStalenessThreshold);", "uint48 validUntil = 0;"))
M("V_ctx_callGas", E(SP, "callGas: uint128(uint256(userOp.accountGasLimits)),", "callGas: 0,"))
M("V_emit_in_validation", E(SP, "        PriceCache memory pc = cachedPrice;\n", "        emit OracleFallbackTriggered(block.timestamp);\n        PriceCache memory pc = cachedPrice;\n"))

# ------------------------------------------------------------- postOp (SP 1299-1346)
M("P_gas_bound", E(SP, "if (gasleft() < SETTLE_GAS_BOUND) revert PostOpGasTooLow();", ""))
M("P_ratelimit_write", E(SP, "userOpState[c.operator][c.user].lastTimestamp = uint48(block.timestamp);", ""))
M("P_idempotency", E(SP, "if (_settledDebtOps[c.opHash]) return;", ""))
M("P_live_price", E(SP, "(actualGasCost + bufWei) * uint256(c.price),", "(actualGasCost + bufWei) * uint256(cachedPrice.price),"))
M("P_live_aprice", E(SP, "(10 ** uint256(c.decimals)) * c.aPriceUSD, Math.Rounding.Ceil", "(10 ** uint256(c.decimals)) * aPNTsPriceUSD, Math.Rounding.Ceil"))
M("P_buf_callpct", E(SP, " + Math.ceilDiv((uint256(c.callGas) + c.postOpGas) * 10, 100)", ""))
M("P_buf_wrap", E(SP, "            + C_WRAP_GAS) * actualUserOpFeePerGas;", "            ) * actualUserOpFeePerGas;"))
M("P_buf_postop", E(SP, "uint256 bufWei = (uint256(c.postOpGas) + ", "uint256 bufWei = (0 + "))
M("P_fee", E(SP, "uint256 charge = Math.mulDiv(aGas, BPS_DENOMINATOR + protocolFeeBPS, BPS_DENOMINATOR, Math.Rounding.Ceil);",
             "uint256 charge = Math.mulDiv(aGas, BPS_DENOMINATOR, BPS_DENOMINATOR, Math.Rounding.Ceil);"))
M("P_cap", E(SP, "if (charge > c.a0) charge = c.a0;", ""))
M("P_settle_lock_a0", E(SP, "settleLocked(c.user, c.opHash, charge);", "settleLocked(c.user, c.opHash, c.a0);"))
M("P_settle_credit_a0", E(SP, "settleCredit(c.user, c.opHash, charge);", "settleCredit(c.user, c.opHash, c.a0);"))
M("P_mode_dispatch", E(SP, "if (c.mode == MODE_BALANCE) {", "if (c.mode != MODE_BALANCE) {"))
M("P_trycatch", E(SP, "IxPNTsTokenV2(c.token).settleLocked(c.user, c.opHash, charge);",
                  "try IxPNTsTokenV2(c.token).settleLocked(c.user, c.opHash, charge) {} catch {}"))
M("P_inflight_delete", E(SP, "delete _inflight[c.opHash];", ""))
M("P_live_off", E(SP, "_setInflightLive(c.opHash, false);", ""))
M("P_refund", E(SP, "operators[c.operator].aPNTsBalance += uint128(c.a0 - charge);", ""))
M("P_revenue_a0", E(SP, "protocolRevenue += charge;", "protocolRevenue += c.a0;"))
M("P_revenue_off", E(SP, "protocolRevenue += charge;", ""))
M("P_event_args", E(SP, "emit TransactionSponsored(c.operator, c.user, aGas, charge);", "emit TransactionSponsored(c.operator, c.user, charge, aGas);"))
M("P_skip_opReverted",
  E(SP, "        PostOpMode,\n        bytes calldata context,", "        PostOpMode pmode,\n        bytes calldata context,"),
  E(SP, "        _settledDebtOps[c.opHash] = true;\n", "        _settledDebtOps[c.opHash] = true;\n        if (pmode == PostOpMode.opReverted) return;\n"))
M("P_skip_blocked", E(SP, "        _settledDebtOps[c.opHash] = true;\n",
                      "        _settledDebtOps[c.opHash] = true;\n        if (userOpState[c.operator][c.user].isBlocked) return;\n"))
M("P_oracle_call", E(SP, "        OpCtx memory c = abi.decode(context, (OpCtx));\n",
                     "        OpCtx memory c = abi.decode(context, (OpCtx));\n        try ETH_USD_PRICE_FEED.latestRoundData() returns (uint80, int256, uint256, uint256, uint80) {} catch {}\n"))
M("P_cache_touch", E(SP, "        OpCtx memory c = abi.decode(context, (OpCtx));\n",
                     "        OpCtx memory c = abi.decode(context, (OpCtx));\n        cachedPrice.updatedAt = block.timestamp;\n"))
M("P_ctx_len", E(SP, "if (context.length == 0) return;", "if (context.length < 352) return;"))
M("P_nonreentrant", E(SP, "external override onlyEntryPoint nonReentrant {\n        if (context.length == 0) return;",
                      "external override onlyEntryPoint {\n        if (context.length == 0) return;"))

# ------------------------------------------------------------- misc SP
M("W_nonreentrant", E(SP, "function withdraw(uint256 amount) external nonReentrant {", "function withdraw(uint256 amount) external {"))
M("W_rev_buffer_check", E(SP, "if (amount > available) revert InsufficientRevenue();", ""))
M("R_restore", E(SP, "operators[f.operator].aPNTsBalance += uint128(f.a0);", ""))
M("R_delete", E(SP, "        delete _inflight[opHash];\n", ""))
M("R_live_guard", E(SP, "if (_isInflightLive(opHash)) revert SponsorshipInFlight();", ""))
M("G_no_reserved", E(SP, "uint256 used = t.debts(user) + t.creditReservedOf(user);", "uint256 used = t.debts(user);"))
M("G_no_debt", E(SP, "uint256 used = t.debts(user) + t.creditReservedOf(user);", "uint256 used = t.creditReservedOf(user);"))
M("S_slot37_shift", E(SP, "    mapping(bytes32 => Inflight) internal _inflight;\n\n    uint256[27] private __gap;",
                      "    uint256 private __m;\n    mapping(bytes32 => Inflight) internal _inflight;\n\n    uint256[26] private __gap;"))

# ------------------------------------------------------------- SuperPaymasterLens
M("L_version", E(LENS, "if (keccak256(bytes(s.version())) != EXPECTED_SP_VERSION) return (false, DRYRUN_VERSION_MISMATCH);", ""))
M("L_notconfigured", E(LENS, "if (!isConfigured) return (false, DRYRUN_OPERATOR_NOT_CONFIGURED);", ""))
M("L_paused", E(LENS, "if (isPaused) return (false, DRYRUN_OPERATOR_PAUSED);", ""))
M("L_eligible", E(LENS, "if (!s.isEligibleForSponsorship(userOp.sender)) return (false, DRYRUN_USER_NOT_ELIGIBLE);", ""))
M("L_postop_minus1", E(LENS, "< MIN_POST_OP_GAS) {", "< MIN_POST_OP_GAS - 1) {"))
M("L_blocked", E(LENS, "if (blocked) return (false, DRYRUN_USER_BLOCKED);", ""))
M("L_ratelimit_calc", E(LENS, "&& block.timestamp < uint256(lastTime) + uint256(minTxInterval);", "&& false;"))
M("L_ratelimit_first",
  E(LENS, "        if (rateLimited) return (false, DRYRUN_RATE_LIMITED);\n        return (true, DRYRUN_OK);", "        return (true, DRYRUN_OK);"),
  E(LENS, "&& block.timestamp < uint256(lastTime) + uint256(minTxInterval);\n",
          "&& block.timestamp < uint256(lastTime) + uint256(minTxInterval);\n        if (rateLimited) return (false, DRYRUN_RATE_LIMITED);\n"))
M("L_token_len", E(LENS, "if (pmd.length < TOKEN_OFFSET + 20) return (false, DRYRUN_TOKEN_MISMATCH);", ""))
M("L_token", E(LENS, "if (address(bytes20(pmd[TOKEN_OFFSET:TOKEN_OFFSET + 20])) != xToken) return (false, DRYRUN_TOKEN_MISMATCH);", ""))
M("L_flags", E(LENS, "if (flags & (FLAG_SP_RENEW | FLAG_ACCOUNT_RENEW) == (FLAG_SP_RENEW | FLAG_ACCOUNT_RENEW)) {", "if (false) {"))
M("L_rate", E(LENS, "if (IxPNTsTokenV2(xToken).exchangeRate() > abi.decode(", "if (false && IxPNTsTokenV2(xToken).exchangeRate() > abi.decode("))
M("L_stale_time", E(LENS, "if (updatedAt == 0 || price <= 0 || block.timestamp > updatedAt + s.priceStalenessThreshold()) {",
                    "if (updatedAt == 0 || price <= 0) {"))
M("L_stale_zero", E(LENS, "if (updatedAt == 0 || price <= 0 || block.timestamp > updatedAt + s.priceStalenessThreshold()) {",
                    "if (price <= 0 || block.timestamp > updatedAt + s.priceStalenessThreshold()) {"))
M("L_balance", E(LENS, "if (uint256(opBalance) < a0) return (false, DRYRUN_INSUFFICIENT_BALANCE);", ""))
M("L_a0_no_buffer", E(LENS, "BPS_DENOMINATOR + s.protocolFeeBPS() + VALIDATION_BUFFER_BPS", "BPS_DENOMINATOR + s.protocolFeeBPS()"))
M("L_lowbyte_lock", E(LENS, "return (false, DRYRUN_LOCK_REJECTED | bytes32(uint256(uint8(lr))));", "return (false, DRYRUN_LOCK_REJECTED);"))
M("L_lowbyte_credit", E(LENS, "return (false, DRYRUN_CREDIT_REJECTED | bytes32(uint256(uint8(cr))));", "return (false, DRYRUN_CREDIT_REJECTED);"))
M("L_credit_skip", E(LENS, "IxPNTsTokenV2.CreditResult cr = IxPNTsTokenV2(xToken).previewCredit(sp, userOp.sender, opHash, a0);",
                     "IxPNTsTokenV2.CreditResult cr = IxPNTsTokenV2.CreditResult.NO_CREDIT; opHash;"))

# ------------------------------------------------------------- xPNTs v2 token mechanisms claimed by migrated tests
M("T_x_rate", E(TOK, "x = Math.mulDiv(reserveAPNTs, exchangeRate, 1e18, Math.Rounding.Ceil);", "x = reserveAPNTs;"))
M("T_burn_rate", E(TOK, "xBurned = r.aReserved == 0 ? 0 : Math.mulDiv(charge, r.xLocked, r.aReserved, Math.Rounding.Ceil);", "xBurned = charge;"))
M("T_lock_invariant", E(BASE, "if (bal < value || bal - value < locked) revert BalanceLocked(from, locked);", ""))
M("T_cap_no_reserved", E(TOK, "if (debts[user] + creditReservedOf[user] + aPNTs > cap)", "if (debts[user] + aPNTs > cap)"))
M("T_cap_no_debt", E(TOK, "if (debts[user] + creditReservedOf[user] + aPNTs > cap)", "if (creditReservedOf[user] + aPNTs > cap)"))
M("T_cap_boundary", E(TOK, "if (debts[user] + creditReservedOf[user] + aPNTs > cap)", "if (debts[user] + creditReservedOf[user] + aPNTs >= cap)"))
M("T_policy_off", E(TOK, "if (p == POLICY_OFF) return 0;", ""))
M("T_tier", E(TOK, "if (tier < cap) cap = tier;", ""))
M("T_settle_debt", E(TOK, "debts[user] += debtAdded;", ""))
M("T_mint_repay", E(BASE, "if (debt > 0) {", "if (false) {"))
M("T_lock_write", E(TOK, "lockedOf[user] = locked + x;", "lockedOf[user] = locked;"))
M("T_settle_unlock", E(TOK, "        lockedOf[user] -= r.xLocked;\n        _setLive(user, opHash, LOCK_SEED, false);", "        _setLive(user, opHash, LOCK_SEED, false);"))
M("T_credit_write_on_fail", E(TOK, "        if (r != IxPNTsTokenV2.CreditResult.OK) return r;\n        creditReservedOf[user] += aPNTs;",
                              "        creditReservedOf[user] += aPNTs;\n        if (r != IxPNTsTokenV2.CreditResult.OK) return r;"))
