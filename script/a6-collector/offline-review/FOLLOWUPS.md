# PR #477 final Low findings

Follow-up branch: `cc125/477-followups`, based on `feat` after #477 merged.
Comparator: reviewed head `58a8eb44`. Archive: regenerated in `58a8eb44` from
collector `0988a589`. This follow-up performs no chain operations, contract source
edits, commits or pushes. No remote PR body was edited; the text below is the local
review response for the follow-up.

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
current-validator copies; the direct N1 probes never normalize summaries. Archive
validation reads the tracked JSONL unchanged.

Collector output does not change in this follow-up: collector.mjs and gauge-lib.mjs
are untouched. No archive regeneration is required. The archive exit matrix remains
**0/3/3/3/2/1/2/3** (positive / a / b / c / d / e-injected / e-missing / N=50).

Verification: all ten suites in `run.mjs` passed (exit 0), including 33 final follow-up controls. Direct `validate.mjs` replay of all eight tracked archive JSONL files matched 0/3/3/3/2/1/2/3; `followup-archives.tsv` records those unchanged-input results. `bash -n` and `git diff --check` also passed. The temporary dependency symlink was removed after testing.
