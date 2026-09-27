# ERRATA-1 (2026-09-27) — README.md line 21, cause attribution

README.md (frozen, covered by EVIDENCE.sha256, not edited) says the A3 stall "matches the anvil
admission race fixed upstream" in foundry-rs/foundry#17021. That overstates it.

- #17021 ("fix(anvil): drop dependent transactions", merged 2026-09-24T08:06:20Z) changes how anvil
  derives pool dependency markers (from on-chain state at final admission instead of the pending nonce,
  while preventing mining from changing that state). Its **stated symptom** is `anvil_dropTransaction`
  leaving nonce-dependent transactions behind — not transactions stuck as *queued*.
- The link between #17021 and our queued-forever stall is **inferred from the shared mechanism**, not
  confirmed: the stall could not be reproduced on demand, and a later identical run passed A3 without
  `--slow`.
- Consequently `--slow` is a mitigation matched to that inferred mechanism. This run passing is an
  observation, not a guarantee the stall cannot recur.

Nothing else in this directory is affected; the run's verdict (`REHEARSAL OK (all)`, 0 `!!!`,
11/11 negative controls reverted) stands as recorded.
