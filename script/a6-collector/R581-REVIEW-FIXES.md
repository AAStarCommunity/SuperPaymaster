# PR #581 review fixes

Changes are left in the working tree. The initial fix pass used no Git commands.
The follow-up adversarial challenge used read-only `git diff`; neither pass
changed Git state, committed, pushed, or ran Anvil.

| Finding | Change | Source locations |
|---|---|---|
| M-1 | Report `formal`; require formal mode for N50 conformance/acceptance. Export requires both the start marker and the validator's formal report. Legacy N50 remains exit 3. | `validate.mjs:434`, `validate.mjs:443`, `validate.mjs:480`; `to-aoa-m3-receive.mjs:115`, `to-aoa-m3-receive.mjs:218` |
| M-2 | Reject non-rehearsal chain 31337, require rehearsal chain 31337, and explicitly compare non-rehearsal chain with frozen target. Existing Passport/archive/config identity checks remain active. | `artifact-validate.mjs:131` |
| L-1 | Bind gas used and effective gas price to every included receipt observation on A and B. Bind the entire `tx.raw` object to viem-formatted archived transaction responses on both endpoints. `tx.raw` is transaction data, not receipt data. | `artifact-validate.mjs:225`, `artifact-validate.mjs:231`; `repair-fixture.mjs:67` |
| L-2 | Formal receipt-summary binding requires observed events and UOE log position even when older-shaped logs lack transactionHash. Existing preflight, revert-array, submission, fee and TPM trace bindings remain enforced. | `artifact-validate.mjs:169`; `derived-evidence.mjs:17`, `derived-evidence.mjs:46` |
| L-3 | Replace brittle line offsets with module/function references; distinguish diagnostic not_included from authorized replacement reasons. | `JOURNAL-DERIVATIONS.md:21`; `EVIDENCE-INDEX.md:9`, `EVIDENCE-INDEX.md:13` |
| L-4 | Require A6_FOUNDRY_NIGHTLY_DIR before rehearsal setup; reject documentation 2001:db8/32, 6to4 2002/16 and Teredo 2001::/32 addresses, including zero-padded forms. | `rehearsal-window.sh:6`; `formal.mjs:40` |
| Info | State formal-path scope and absence of external archive commitments; recommend externally committing raw-file digests at start and as files are produced. | `JOURNAL-DERIVATIONS.md:8` |

## Regression and revert evidence

`r581.test.mjs` adds the reviewer’s forged legacy N50 attack (missing and false
formal flags), independent exporter marker/report checks, chain-policy checks,
23 receipt/transaction field mutations, missing observed event/log-position
checks, IPv6 checks, and nightly configuration checks. Existing exporter tests
were corrected to refuse the old forged formal-candidate construction.

Each guard was replaced with its pre-fix source independently, the corresponding
tests were run, and the fixed bytes were restored in a finally block. All seven
revert runs exited 1. Exact failing test names are in `r581-red-results.json`:

| Reverted guard | Tests that went red |
|---|---|
| M-1 validator | 3: formal report plus missing/false-formal N50 attack |
| M-1 exporter | 3: missing start marker, false start marker, missing validator formal report |
| M-2 | 3: non-rehearsal 31337, rehearsal other chain, frozen target mismatch diagnostic |
| L-1 | 23: gasUsed, effectiveGasPrice, and all 21 emitted tx.raw fields in the fixture |
| L-2 | 2: deleting observedUserOpEvent; deleting userOpEvent.logIndex |
| L-4 IPv6 | 5: documentation, padded documentation, 6to4, Teredo, padded Teredo |
| L-4 nightly | 1: unset directory must fail before any rehearsal command |

The public IPv6 positive control remains green when the IPv6 fix is reverted.
Documentation changes have no runtime assertions. The existing derived-evidence
suite covers the other nonempty summary bindings.

Coverage limit: the positive exporter formal-candidate fixture uses a controlled
validator report to isolate its two independent gates. The legacy forgery tests
use the real validate CLI. This does **not** establish the separately requested
end-to-end test starting from a fully accepted formal CLI window and deleting
its formal flag; no such passing fixture was added.

## Final validation

The exact command `node --test script/a6-collector/` fails on Node v24.21.0 with
MODULE_NOT_FOUND because this Node version treats the directory as a module.
The explicit `*.test.mjs` equivalent is used for the full suite.

Final run: `node --test script/a6-collector/*.test.mjs` — **199 passed, 0 failed,
0 skipped** (Node v24.21.0). `bash -n script/a6-collector/rehearsal-window.sh`
also passed. The 40 new rejection/report tests all went red under their relevant
pre-fix guards; the remaining new test is the public IPv6 positive control.

## Follow-up challenge and head-read regression

See [r581-challenge.md](r581-challenge.md) for the per-finding challenge and
coverage limits. The opt-in advancing-head fixture preserves default behavior.
Four new head assertions cover the accepted shape, absent claimed head, and
inclusion equal to/below the highest archived head. All four fail under their
relevant old-rule/removed-guard mutations; results are in
[r581-red-results.json](r581-red-results.json), reproduced by the opt-in
`node script/a6-collector/r581-head-red.mjs` runner.

The follow-up also fixes the exporter's archive-directory loss when validating
captured journal bytes, and explicitly requires the target chain at the artifact
boundary. New probes cover legacy `formal:true` without archives, stripped
rehearsal markers through the real CLI, unchecked export, missing target chain,
and nine IPv4-embedded IPv6 forms.

Final follow-up validation: `node --test script/a6-collector/*.test.mjs` —
**215 passed, 0 failed, 0 skipped**. Shell syntax and read-only diff whitespace
checks passed. Verdict: **APPROVED** for the reviewed changes, subject to the
external-commitment and end-to-end coverage limits documented above.
