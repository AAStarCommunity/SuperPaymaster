// RDR-6 ① deposit-floor guard (docs/design/aoa-balance-mode/03-final-spec.md §10.8 RDR-6;
// plan §10.1★3/§10.3-10.5, AOA_RepCredit_Sequencing_Plan_2026-09-13.md line ~405-406).
//
// F = B_max * (sum of the op's gas limits that draw on THIS paymaster's EntryPoint deposit)
//     * maxFeePerGas ceiling
//
// B_max is a DSR-owned sample-protocol parameter (plan §8.4) — there is no real default here,
// only a placeholder for mechanism dry-runs. The real value is DSR's deliverable, not derived
// by this file.
export const PLACEHOLDER_B_MAX = 1n; // dry-run only — DSR sets the real value

/**
 * Gas limits an EntryPoint deposit is drawn against for a single sponsored op (v0.7),
 * matching EntryPoint._getRequiredPrefund exactly (EntryPoint.sol:401-412 — verificationGasLimit
 * + callGasLimit + paymasterVerificationGasLimit + paymasterPostOpGasLimit + preVerificationGas).
 * Omitting preVerificationGas understates both F and the post-send balance estimate, letting the
 * guard approve an op that actually breaches the floor once EntryPoint's real draw is accounted for.
 */
export function opGasLimitSum({ verificationGasLimit, callGasLimit, paymasterVerificationGasLimit, paymasterPostOpGasLimit, preVerificationGas }) {
  return verificationGasLimit + callGasLimit + paymasterVerificationGasLimit + paymasterPostOpGasLimit + preVerificationGas;
}

/** F = B_max * gasLimitSum * maxFeePerGasCeiling. */
export function depositFloor({ bMax, gasLimitSum, maxFeePerGasCeiling }) {
  return bMax * gasLimitSum * maxFeePerGasCeiling;
}

/**
 * The guard itself: given the paymaster's current EntryPoint deposit and this specific op's
 * own estimated cost (gasLimitSum * maxFeePerGas of THIS op, not the ceiling used for F),
 * decide whether to send. "冻结条件是押金 >= F，不是押金不变" — the guard only ever compares
 * against the floor, never demands the deposit stay unchanged.
 *
 * Returns { allowed: true } or { allowed: false, reason: 'DEPOSIT_FLOOR', deposit, estimatedCost, floor }.
 */
export function checkDepositFloor({ deposit, estimatedCost, floor }) {
  const after = deposit - estimatedCost;
  if (after < floor) {
    return { allowed: false, reason: 'DEPOSIT_FLOOR', deposit: deposit.toString(), estimatedCost: estimatedCost.toString(), floor: floor.toString(), after: after.toString() };
  }
  return { allowed: true };
}
