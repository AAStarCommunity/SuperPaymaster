# D5b full fork rehearsal — archived run at `b3e2d3eb`

| | |
|---|---|
| Script commit | `b3e2d3eb` (branch `d5c-2/rehearsal-evidence`) = `4d57a1c6` (PR #442, protocolFee snapshot — the SP bytecode under test) + `--slow` on every broadcasting `forge script` call |
| Fork | Sepolia block **11729160**, local anvil on `127.0.0.1:28571`. **Nothing was broadcast to any public network.** |
| Date | 2026-09-27, output files written 12:32–12:40 +0700 |
| Command | `./script/evidence/d5b-fork-rehearsal.sh .env.sepolia 11729160 docs/design/aoa-balance-mode/data/d5b/fork-rehearsal-full-11729160-b3e2d3eb all` |
| Toolchain | forge 1.7.1 / anvil 1.7.1, both commit `4072e48705af9d93e3c0f6e29e93b5e9a40caed8` |
| Exit code | 0 |
| Verdict | `REHEARSAL OK (all)` (`rehearsal.log` last line; printed only when `FAILURES == 0`, `script/evidence/d5b-fork-rehearsal.sh:585-590`) |
| `!!!` lines | 0 |
| Negative controls | 11 executions (9 `must_fail` call sites; two sit in the SP/REGISTRY loop), all logged `negative ok: … reverted`; 0 `NEGATIVE CONTROL FAILED` |

## Scope covered
Stage 0 (fork-level probes, operator + debt inventory), Stage I A1–A7 (runbook steps 0–7c incl. 5c: aPNTs → APNTsCapped migration through a fresh GOV-1-shaped timelock, SP 5.4.2 → 5.5.0 upgrade, Registry → 5.9.0, v2 token issuance, configure/unpause, one real UserOp through EntryPoint), Stage II (M1 two-step ownership handoff to the 48 h TimelockController, timelock-aware upgrade drill for SP and Registry, M2 guardian pause / timelock unpause).

Final state (`rehearsal.log`): SP owner = Registry owner = TimelockController `0x86C8…9564`, SP guardian = `0xb560…df0E`, `SuperPaymaster-5.5.0`, `Registry-5.9.0`.

## Mitigation applied (not a root-cause fix)
`--slow` on all broadcasting `forge script` calls. An earlier run on the same day stalled at Stage I/A3 with the owner's txs stuck as *queued* in anvil's txpool; the symptom matches the anvil admission race fixed upstream in foundry-rs/foundry#17021 (after anvil 1.7.1). A diagnostic re-run without `--slow` passed A3, i.e. the stall is intermittent and was not reproduced on demand. This run shows the rehearsal passes with `--slow`; it does not prove the stall cannot recur. See the comment block near the top of the script and the commit message of `b3e2d3eb`.

## Not evidence
Two earlier output directories from 2026-09-18 (stopped at A4, pre-fix) and 2026-09-27 (A3 stall, then corrupted by a manual owner transaction sent during diagnosis) were discarded and are not in the repository.

## Secrets check
All files scanned before commit: no RPC key, no value of any private-key variable from the env file (5 distinct values checked; the same matcher finds 5/5 in the env file itself as a positive control), no anvil default keys. The only `PRIVATE_KEY` match is the variable name `PRIVATE_KEY_ANNI` in a step title. Every remaining 64-hex string was classified by the label next to it: code hashes, timelock operation / batch ids, role ids, ABI-encoded return and revert words (`neg.log`), manifest digests, attested head block hashes, CLZ probe results, one timelock salt and one tx hash. None is a key.

`EVIDENCE.sha256` covers every file in this directory except itself (`shasum -a 256 -c EVIDENCE.sha256`).
