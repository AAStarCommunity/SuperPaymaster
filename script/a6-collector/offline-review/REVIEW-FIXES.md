# PR #477 reviewer repair

Historical repair scope: branch `cc125/a6-gauge`, starting HEAD `6b0a4261`. Those fixes were committed in `0988a589`; `58a8eb44` regenerated the archive from that collector. The N1–N5 follow-up is on `cc125/477-followups`, with no commits, pushes, RPC calls or contract edits in this follow-up. Run `node script/a6-collector/offline-review/run.mjs`; `review-results.tsv` records the old HEAD validator and current validator on identical synthetic inputs. Archive inputs are never repaired.

| Reviewer ID | Disposition and proof |
|---|---|
| F1 | FIXED. Triplet identity/distinctness uses sent rows only; empty/singleton identity sets are valid. Partial and all-unsent triplets change 1 -> 3; transaction reuse and bundler tampering remain 1. |
| F3 | FIXED in collector conservation, independent single-op validation and receipt attribution. CreditReserved is validation, not settlement. Reservation, inflight and totalSpent survive; debts, revenue, balances/supply and sponsorship count do not change. Direct, drop-op and wrong-hash credit-postOp controls change 1 -> 3; reservation/debt/user/locker tampering remains 1. Collector CREDIT-postOp and identity controls also pass. |
| F4 | FIXED. Nothing-sent is consistent but not accepted (3), including zero attempts (old 2). There is no tx readback to anchor; start/end balances must still agree, end height/hash must advance, passports remain complete and invariant. Balance tampering remains 1. Sent runs still require the start same-hash readback. |
| F7 | FIXED. Floor and packed-tail admission require a successful receipt with matching hash, sender, nonce and paymaster UOE. Honest withheld/tx-failed rows with floor above supplied gas change 1 -> 3; executed admission violations and unexplained failed-tx state deltas remain 1. Low maxRate withheld/executed paired controls also cover tail admission. Structural packed/row/passport bindings remain unconditional. |
| F5 | FIXED. README, ROUND5 and round4 archive table now describe the regenerated archive and 0/3/3/3/2/1/2/3 matrix. Local override mining is documented. |
| F6 | FIXED as a source-proven interval binding; exact equality to final UOE cost is rejected as unsound (see below). Positive remains 0; self-consistent zero aGas/charge changes 0 -> 1. Existing fee, charge, D1 and reservation identities remain mandatory. |
| R1-F3 Nit | FIXED. Continuity/uniqueness failures stop with EVIDENCE_CONTINUITY_MISMATCH (28); conservation failures retain 22. Production helper controls verify both branches and the no-failure case. |
| L1 | FIXED. The negative-control table generator now asserts collector/validator exits before generating the report; run.sh propagates table failure and replaces the report atomically only after success. Offline replay checks it on the current archive. |
| L2 | FIXED for known isolation/conservation stops: finalized rows include stoppedBy before the throw. |
| L3 | FIXED. Unexpected end-passport errors produce END_PASSPORT_ERROR (29) instead of COMPLETE/0. A previous nonzero stop remains authoritative. |
| (d) label | FIXED in the table generator: validator 2 means fails closed. The regenerated archive includes the corrected label. |

## Source evidence for F3 and F6

Read and asserted using `git show 1ac0e1c5:<path>` (line assertions in check-review):

- `contracts/src/tokens/v2/xPNTsTokenV2.sol:299-309`: credit reservation occurs in validation, increments creditReservedOf at 305, emits CreditReserved at 308. EntryPoint `:134-148` rolls back execution/postOp, preserving validation writes.
- `contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol:419-428`: aGas = ceil((callbackActualGasCost + bufferWei) * cachedPrice * 1e18 / (10^decimals * aPNTsPriceUSD)). Buffer gas is validation-snapshot cPostop + cWrap plus ceil((callGas + postOpGas)*10/100); multiply by actualUserOpFeePerGas. Lines 433-434 and 450 bind emitted charge to aGas and a0.
- `singleton-paymaster/lib/account-abstraction-v7/contracts/core/EntryPoint.sol:703-707`: callback cost is pre-postOp actualGas * gasPrice. Lines 716-730 then add wrapper/postOp gas and unused execution penalty before computing the final UOE actualGasCost. These two cost arguments are different. Line 672 includes preVerificationGas in preOpGas; lines 757-767 bound gas price by packed fees.
- `SuperPaymasterStorage.sol:192,200-203`, `SuperPaymasterAdmin.sol:297-301`: cPostop+cWrap is in [180000,2050000]. With positive denominators, callback gas >= preVerificationGas and callback cost <= final UOE cost. These facts give the implemented inclusive aGas bounds, using gasPrice = UOE actualGasCost / actualGasUsed (also checked for exact divisibility and packed fee bounds). No default configuration is fabricated.

Exact aGas recomputation is unavailable from the current JSONL: it lacks callback actualGasCost and the validation-time gas snapshot. Equating callback cost to final UOE cost would introduce another false rejection. The interval rejects zero/underpriced or excessively inflated aGas but cannot reject every in-range falsification; exact verification would need independently bound postOp calldata/trace evidence and a format change. This limitation is explicit, not an exact-equality claim.

## Archive and collector output

The `0988a589` repair preserved the top-level schema but changed collector output semantics: CREDIT-postOp rows gained evaluated CREDIT checks, known stop rows gained stoppedBy, continuity failures use code 28, and unexpected end-passport errors use code 29. The archive was subsequently regenerated in `58a8eb44` from collector `0988a589`. The N1–N5 follow-up leaves that archive unchanged and verifies 0/3/3/3/2/1/2/3. This follow-up changes only validator, offline controls, documentation and report publication; collector output is unchanged, so no archive regeneration is needed.

## PR body review-rule answers (local draft)

SZ-1/SZ-2/SZ-4: size is largely the recorded evidence archive and reproducible offline fixtures, retained for review. D1: negative-controls/run.sh cleanup kills only its own child processes. T1/T2: offline-review/run.mjs provides executable honest/tampered controls, including the missing withheld-op and CREDIT-postOp branches. B1: assertion-word comments in the frozen old collector are historical comparator evidence, not production assertions. C2: the A/B Promise.all contains read-only requests (reviewer explicitly waived this checker false positive). No remote PR body was edited.

The final N1–N5 follow-up dispositions and local review-response draft are in `FOLLOWUPS.md`; executable old/current proofs are in `followup-results.tsv`.
