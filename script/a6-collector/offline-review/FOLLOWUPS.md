# PR #477 final Low findings

DSR selected scope (a), Seeder `dc7d0fab` (2026-10-15). The rejection proofs
below concern the listed offline mutations. They do not claim that the validator
rejects round-6 coherent whole-row forgery with recomputed hashes; those items are
outside its scope and controlled by on-chain re-fetch. See the
[decided scope](../README.md#信任根与范围) and [formal SOP](../A6-SOP.md).
Merged #477/#479 local Anvil runs prove gauge mechanics only, remain outside
real-chain A6 evidence, and do not block A2. A3a is NO-GO.

Follow-up branch: `cc125/477-followups`, based on `feat` after #477 merged.
Comparator: reviewed head `58a8eb44`. Archive: regenerated in `58a8eb44` from
collector `0988a589`. The initial follow-up was committed as `64246042` for
PR #479. The R1 repair below is local and offline; this document is the local
review-response draft.

Run `node script/a6-collector/offline-review/run.mjs`. Its final suite,
`check-followups.mjs`, asserts the old/current results and specific rejection
proofs in `followup-results.tsv`. Honest controls remain valid where the old
behavior was already correct; false acceptance and false rejection probes assert
an explicit change in exit code.

| ID | Result | Proof |
|---|---|---|
| N1 | FIXED | Honest NOT_SENT remains 3; receipt/log/readback/invalid-reason contradictions change 3 to 1. COMPLETE attempts after target and forged tally/triplets/target change 0 to 1. Honest COMPLETE remains 0. Summaries follow the collector loop: a thrown stopped attempt is written but not tallied; its interrupted triplet is not emitted. |
| N2 | FIXED | The actual publication tail of run.sh is replayed offline. Honest table remains byte-identical, exit 0. Wrong recorded verdict changes shell exit 0 to 1, preserves the previous report and prints no success message. A temporary report is moved into place only after table.mjs succeeds. |
| N3 | FIXED | README, ROUND5 and REVIEW-FIXES identify archive commit 58a8eb44 and collector 0988a589, distinguish the historical repair from this follow-up and remove stale regeneration claims. Restoring each old document fails the provenance assertion. This file supplies the current local review-response draft. |
| N4 | FIXED | Honest single-UOE receipt remains 0. Orphan CreditReserved, LockCreated, LockSettled and CreditSettled each change 0 to 1 with receipt.orphan_token_event. Bound-event identity tampering remains 1. |
| N5 | FIXED | Honest stop 28 with an intervening external same-key nonce advance changes 1 to 3 (consistent, not accepted). Block gap without nonce gap remains 3. Unstopped nonce gaps, stop labels without a block gap, event-nonce tampering and stopped block-hash tampering remain 1. |

The nonce exception requires an EVIDENCE_CONTINUITY_MISMATCH row and run-end stop
28 with an independently recorded intervening block. It does not waive packed
nonce/hash/event binding, block bracketing or SP conservation.

Historical suites retain their frozen validator inputs. `synthetic-summary.mjs`
updates summaries only for generated accounting scenarios whose rows/verdicts are
changed. Historical appended accounting probes use an unfinished target in their
current-validator copies. Direct N1 row-mutation probes also use syntheticSummary;
summary-tampering probes preserve their forged summaries. M1 controls replay the
collector loop over returned rows without syntheticSummary. Archive validation
reads the tracked JSONL unchanged.

Collector output does not change in this follow-up: collector.mjs and gauge-lib.mjs
are untouched. No archive regeneration is required. The archive exit matrix remains
**0/3/3/3/2/1/2/3** (positive / a / b / c / d / e-injected / e-missing / N=50).

Verification: all ten suites in `run.mjs` passed (exit 0), including 80 final follow-up controls. Direct `validate.mjs` replay of all eight tracked archive JSONL files matched 0/3/3/3/2/1/2/3; `followup-archives.tsv` records those unchanged-input results. `bash -n` and `git diff --check` also passed. The temporary dependency symlink was removed after testing.

## PR #479 R1 repair (reviewed head `64246042`)

| ID | Result | Proof |
|---|---|---|
| M1 | FIXED | The final unstopped row may be tallied or untallied only for stops other than 0/10. Tally, triplets and matchedTriplets must match one coherent summary. Twelve crash-after-write controls (positive/N=50 × SP/VPM/TPM × CRASH/PASSPORT_DRIFT) change reviewed-head exit 1 to 3, including the TPM matched-count case. Twelve tallied controls remain 3; twelve contradictory NOT_SENT controls remain 1. Mixed summaries and untallied COMPLETE/MAX_ATTEMPTS summaries reject. The collector and archive are unchanged. |
| L2 / N3 | FIXED | Removed historical claims about publication and commit state; documented which N1 probes normalize summaries. The prose assertion includes FOLLOWUPS and rejects uppercase, lowercase and mixed-case stale claims. Historical stale-document controls still reject. |
| Nit 1 | FIXED | A stopped nonce+2 row with an intervening block but run-end MAX_ATTEMPTS/10 remains 1. Removing the N5 run-end guard makes this control fail (actual 3, expected 1). |
| Nit 2 | FIXED | Orphan passport-token events are checked on baseline arms too. VPM/TPM orphan CreditReserved controls change 0 to 1; honest positive remains 0. |
| R4 null passport | FIXED | RPC_DISAGREEMENT with a null end passport remains exit 2, now reports a missing field without a TypeError. |
| Info: A-only stop gap | REJECTED (change) | Retained the existing stopped-row evidence policy: A/B agreement is deliberately not enforced on interrupted rows. A stop-28 run cannot be accepted. |

M1 comparisons use `64246042`; the original N1–N5 and Nit 2 comparisons use
`58a8eb44`. M1 controls explicitly replay returned rows from collector:606–617,
set the end balance from the written crash row, and never call syntheticSummary.
All N1 receipt/log/readback/reason, after-target and summary tamper controls still
reject. The full ten-suite offline run passed with 80 follow-up controls; direct
archive replay retained 0/3/3/3/2/1/2/3, and both old-* inputs retained exit 2.

PR body draft, review-level rule answers: SZ-1/SZ-2: the existing PR includes the
review evidence archive and generated fixtures; this local R1 repair adds validator
logic, executable controls and proof rows without regenerating that archive.
T1/T2: all ten offline suites pass, with honest crash-after-write and tampered
controls; no contract behavior changes, so Forge is outside this repair's scope.
B1: synthetic-summary.mjs is used only by synthetic row-mutation scenarios; archive replay and summary-tampering controls do not call it. N2-wrong-verdict executes the real publication tail and proves the check applies before report replacement, at the action itself (T2/S3).
The checker examines committed `base...HEAD` only; its result does not include the
uncommitted R1 edits. This response stays local under the no-commit/no-push instruction.

Checker: `pre-pr-check --base b6c0f08f`, rules 1.3.5, exit 0; 0 block,
5 review/info (SZ-1, SZ-2, T1, T2, B1), committed range 669 lines / 100 files.
The external checker reports its own checkout as dirty; it was not modified here.
