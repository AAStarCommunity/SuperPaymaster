import importlib.util, os
_spec = importlib.util.spec_from_file_location("m1", os.path.join(os.path.dirname(os.path.abspath(__file__)), "muts.py"))
m1 = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(m1)
SP, LENS, TOK, BASE, ALL, E, SIGFAIL = m1.SP, m1.LENS, m1.TOK, m1.BASE, m1.ALL, m1.E, m1.SIGFAIL
MUTATIONS = []


def M(id, *edits, tests=None, match=None):
    MUTATIONS.append(dict(id=id, edits=list(edits), tests=tests or ALL, match=match))


# new mutations (batch 2)
M("V_insufficient_as_balance", E(SP, "if (r == IxPNTsTokenV2.LockResult.OK) return MODE_BALANCE;",
                                 "if (r == IxPNTsTokenV2.LockResult.OK || r == IxPNTsTokenV2.LockResult.INSUFFICIENT) return MODE_BALANCE;"))
M("V_credit_result_ignored", E(SP, "return c == IxPNTsTokenV2.CreditResult.OK ? MODE_CREDIT : MODE_NONE;", "c; return MODE_CREDIT;"))
M("V_calc_floor", E(SP, "(10**uint256(cache.decimals)) * aPNTsPriceUSD,\n            Math.Rounding.Ceil",
                    "(10**uint256(cache.decimals)) * aPNTsPriceUSD,\n            Math.Rounding.Floor"))
M("P_charge_floor", E(SP, "uint256 charge = Math.mulDiv(aGas, BPS_DENOMINATOR + protocolFeeBPS, BPS_DENOMINATOR, Math.Rounding.Ceil);",
                      "uint256 charge = Math.mulDiv(aGas, BPS_DENOMINATOR + protocolFeeBPS, BPS_DENOMINATOR, Math.Rounding.Floor);"))
M("CFG_probe_accept_only_v2", E(SP, "if (v != 1) revert InvalidXPNTsToken();", "if (v != 2) revert InvalidXPNTsToken();"))
M("X_pause_write", E(SP, "operators[operator].isPaused = paused;", ""))
M("S_pendingDebts_public", E(SP, "mapping(address => mapping(address => uint256)) internal pendingDebts;",
                             "mapping(address => mapping(address => uint256)) public pendingDebts;"))
M("S_add_dryrun", E(SP, "    // dryRunValidation moved to SuperPaymasterLens in 5.5.0 (spec F1 / §5: EIP-170 headroom).\n",
                    "    function dryRunValidation(PackedUserOperation calldata, uint256) external pure returns (bool, bytes32) { return (true, bytes32(0)); }\n"))

# re-runs of batch-1 mutations against the strengthened tests
RERUN = ["V_notconfigured", "T_policy_off", "V_credit_on_any_lockfail", "V_inflight_live", "R_live_guard",
         "P_live_aprice", "V_a0_floor"]
for m in m1.MUTATIONS:
    if m["id"] in RERUN:
        MUTATIONS.append(dict(m, id=m["id"] + "__v2"))
