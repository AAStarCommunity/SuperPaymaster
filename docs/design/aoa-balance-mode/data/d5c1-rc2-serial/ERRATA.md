# ERRATA for `d5c1-rc2-serial/` (PR #471, merge `25c33fea`)

Raised by the pr-daemon review of #471 (Low items). **None of these corrections changes any verdict**, but the README overstated or under-evidenced three points. The README itself is left unchanged because `EVIDENCE.sha256` pins it; this file supersedes the sentences named below.

## 1. Load during the run was understated

README §0 says the 1-minute load had a median of about 12 and was elevated only at the start, because of residue from the aborted run. **That is incomplete.** Computed from `run/load.log` (365 one-minute samples):

- median 12.3, p90 116.6, max 274.8;
- **90 of 365 samples above 50, in 16 separate episodes**, spread over the whole of step 1 (`run-all`, 16:43:21Z → 21:28:01Z), not just the beginning. The largest episodes were 18:30–18:40Z (max 274.8), 21:01–21:24Z (max 207.7) and 19:13–19:25Z (max 197.4).

These episodes come from Halmos' own solver fan-out, even at `jobs=1`. The verdict still holds: every partition that is required to PASS reached a terminal result inside the 600 s cap. The one marginal row (`check_I4B_coreAbi:transferFrom`, PASS at 588.1 s) is the one most exposed to this load.

## 2. Submodule provenance was asserted without evidence in the archive

README §0 says the submodules were copied "per the rc.2 gitlinks". The archive did not show this, and `run/0-ast-build.stdout` carries `revision mismatch … found 1ac0e1c5` and `Missing dependencies` warnings, because the copies have no `.git`. The evidence was produced afterwards from the same copied trees, which were unchanged since the run; see `../i9-rc2-final/SUBMODULE-PROVENANCE.txt`:

- For all six submodules, the copy source HEAD equals the rc.2 gitlink: solady `90db92ce`, chainlink `6e324d8a`, ercs `c6d2d5e3`, mpp-specs `0c438bdd`, permit2 `cc56ad0f`, x402 `b054f423`.
- The source working trees are clean.
- `diff -rq --exclude=.git` between source and copy is empty, except `standards/permit2/lib` and `standards/x402/contracts/evm/lib`. These are empty, uninitialised nested-submodule directories (0 files) and are absent from the copy. rc.2's `foundry.toml`, `contracts/src` and `contracts/test` do not reference `standards/`.

## 3. Redaction scope

The scratch-directory path (`/private/tmp/claude-502/-Users-<user>-…/<session>/…`) still appears in `run/steps.log`, `run/steps.tsv`, `run/0-ast-build.stdout` and `aborted-run-2/`. It is a local temporary path, not a secret. It is left in place so that the pinned hashes stay valid. The I9 archive (`../i9-rc2-final/`) replaces it with `$SCRATCH`.
