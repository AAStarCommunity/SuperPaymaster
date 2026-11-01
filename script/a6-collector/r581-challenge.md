# PR #581 adversarial challenge

Reviewed the full working-tree diff and `r581*.mjs/json/md` against the supplied
review. Used read-only `git diff`; no Git state changes, push, or Anvil execution.

| Finding | Challenge and disposition |
|---|---|
| M-1 | Missing/false formal legacy N50 forgery is refused. New real-CLI probe sets `formal:true` without an archive: missing index is reported and exit is nonzero. Checked export refuses it; `validate:false` produces only rehearsal. Exporter marker/report gates are independent. |
| M-2 | Synthetic archived window with all rehearsal markers absent on chain 31337 reaches the explicit chain-policy rejection through the real CLI. Frozen target absence already failed later config/identity checks; now the artifact boundary requires a positive safe-integer target explicitly, even before per-attempt validation. |
| L-1 | Gas used/effective price are compared against every included A/B receipt; all emitted `tx.raw` fields are compared against viem-formatted archived transactions. Existing 23 independent mutation tests cover these fields. |
| L-2 | Formal receipt summaries require observed UOE and log position. Index reconstruction, fixed-block state-call binding, and CLI A/B equality remain active. Evidence ranges are bounds, not externally authenticated exact collection boundaries; harmless unknown journal keys remain allowed. Neither is treated as independent authorization for measurements or acceptance. |
| L-3 | Documentation uses module/function references and correctly distinguishes diagnostic `not_included` from authorized replacement reasons. |
| L-4 | Nightly directory is explicit. Documentation/6to4/Teredo tests pass. Added nine mapped, compatible, NAT64, and padded IPv6 probes; all fail closed. Public global IPv6 positive control remains allowed. |
| Info | Documentation explicitly acknowledges that rewriting both journal and archive consistently is not prevented by local hashes. External commitments remain future operational work, not a guarantee of this validator. |

## Additional defect fixed

The exporter captured journal bytes into a temporary directory, then ran the
validator there without the original archive. A genuine formal window therefore
could never export successfully. `validate.mjs --window <archive-dir>` now
resolves archive files and rehearsal markers independently of the captured
journal location. The exporter supplies the source directory. It still validates
the exact journal bytes it exports. Tests check the exporter argument and run
the real validator against a captured journal with a separate archive directory.
This does not bypass any archive/journal/config binding.

## Head-read regression and isolation

`repairFixture(dir, count, {advanceHeadBeforeSend:true})` adds a later advanced
head while leaving inclusion above both heads. Defaults are unchanged. Tests
require acceptance of this shape and the exact archive diagnostics for an
unobserved claimed head and inclusion equal to or below the later head. A
journal-only height edit cannot override archived inclusion membership, A/B
receipt/transaction bindings, or the maximum pre-send head guard.

`node script/a6-collector/r581-head-red.mjs` temporarily restores the old
last-head membership rule, removes the membership guard, and removes the maximum
inclusion guard, each separately. Every new head assertion fails under its
corresponding mutation. Exact failure names and exit statuses are appended to
`r581-red-results.json`. The runner restores the original source in `finally`;
run it alone, never alongside other tests.

## Scope of evidence

The CLI chain-policy probe is a synthetic archived rejection fixture, not a
fully accepted N50 window. Exporter success gating uses a controlled validator
report; the archive-directory routing is also checked with the real CLI.
The existing `/private/tmp/a6-rehearsal.wYnQHw/window` was read without modification:
its current validation reports `artifact verification: artifact hash mismatch`.
It is not counted as an end-to-end successful formal export or acceptance test.

Final follow-up validation: `node --test script/a6-collector/*.test.mjs` —
**215 passed, 0 failed, 0 skipped**. Shell syntax and read-only diff whitespace
checks passed. Verdict: **APPROVED** for the reviewed changes, subject to the
external-commitment and end-to-end coverage limits documented above.
