# aoa-m3-receive-v1 workbench run (CC-127 / AOA-SP-02 item 2): rehearsal data, not A6

> **Local-anvil rehearsal only.** The inputs are the archived runs in `../a6-gauge-local/`, which carry
> `allowSameEndpointLocal: true` and `protocolConformant: false`. Every package here is `runType: rehearsal`.
> `OFFLINE_STRUCTURE_PASS` is the DSR checker's structure verdict. It is not A6 data and it is not M3 acceptance.
> Nothing was read from a chain, signed or broadcast.

This bundle shows the path DSR's work order asks for: archived collector run → exporter → DSR checker. The
exporter is `script/a6-collector/to-aoa-m3-receive.mjs`. The checker is `scripts/aoa_m3_check.py` in the DSR
repo; its input format is in `AOA_M3_Readiness_2026-10-26.md`. The bundle also shows that deleting events,
tampering hashes, duplicating operations and changing chain or pin are each refused.

## What the exporter does

- **Starts from a consistent run.** It runs `validate.mjs` first and requires `consistent`; otherwise nothing is
  written.
- **Decodes the event itself.** For every attempt it decodes the EntryPoint v0.7 `UserOperationEvent` from that
  attempt's own receipt logs, matched by EntryPoint address, topic and expected `userOpHash`. When the collector's
  verdict is success, the decoded event must equal the collector's `userOpEvent` record, or the export is refused.
- **Never upgrades an attempt.** An attempt is `included` only if all of these hold:
  - the verdict is `USEROP_SUCCESS`, and the row is not a fixture or collector exclusion;
  - the receipt succeeded and the decoded UOE reports success;
  - conservation was evaluated and held;
  - its triplet was matched.

  Every other attempt is kept, with its reasons joined in `exclusionReason`.
- **Writes the archive.** Raw per-attempt files (`receipt`, `uoe`, `state`), the run passport and a copy of the
  collector JSONL are written and listed with their SHA-256 in `files`.
- **Refuses drift.** It refuses passport drift between `run_start` and `run_end` (the pin), a run without a
  passport, and a non-empty output directory.
- **Controls.** The run-level controls (`accountImplementation`, `tokenStateProtocol`, `bundlerConfigHash`,
  `windowId`, `samplingProtocolHash`) are content hashes of the run's own passport and argv. So the checker's
  per-group equality tests the collector, not this view.

## Results (`results.tsv`, from `script/a6-collector/aoa-m3-receive-controls.sh`)

| control | expected | observed | reason reported |
|---|---|---|---|
| positive (1 triplet) | PASS | OFFLINE_STRUCTURE_PASS | |
| n50-mechanism (50 triplets, 150 attempts) | PASS | OFFLINE_STRUCTURE_PASS | |
| a-exec-revert / b-drop-op / c-wrong-hash | FAIL | FAIL | 0 matched groups; all 3 attempts kept, with `VERDICT:…;FIXTURE:…` reasons |
| d-tamper-b (stopped before read-back) | refused | EXPORT_REFUSED | no start/end passport |
| raw UOE file edited | FAIL | FAIL | hash mismatch |
| raw UOE file deleted | FAIL | FAIL | missing archive |
| duplicate UserOp | FAIL | FAIL | duplicate UserOp identity |
| chainId changed in one arm | FAIL | FAIL | mismatched chainId |
| one arm removed | FAIL | FAIL | require exactly one SP/VPM/TPM |
| injected scenario in typical | FAIL | FAIL | injected sample in typical group |
| settlement unverified | FAIL | FAIL | settlement/state not verified |

**Exporter-level controls** are in `script/a6-collector/to-aoa-m3-receive.test.mjs`, 13 tests, all passing.
They cover:
- UOE deleted from a success row;
- collector summary disagreeing with its log (`actualGasCost`, `actualGasUsed`, `success`);
- an inconsistent archive;
- passport (pin) drift and a missing passport;
- an unmatched triplet;
- fixture rows kept;
- `runType` following `protocolConformant`;
- determinism;
- the topic constant;
- the non-empty output directory.

`n50-mechanism.receive.json` is byte-identical when regenerated (sha256 `b637ec3d…5d503d07`). The 452 raw files
it lists are not committed. They are regenerated deterministically from the archived JSONL:

```sh
node script/a6-collector/to-aoa-m3-receive.mjs docs/design/aoa-balance-mode/data/a6-gauge-local/n50-mechanism.jsonl <empty-dir>
python3 <DSR>/scripts/aoa_m3_check.py <empty-dir>/receive.json --expected 50
script/a6-collector/aoa-m3-receive-controls.sh <DSR>/scripts/aoa_m3_check.py <empty-dir>   # all controls
```

## Found while building this

`validate.mjs` decodes receipt logs itself, but it **does not read** the collector's `userOpEvent` summary. When
that summary's `actualGasCost`, `actualGasUsed` or `success` was altered, `validate.mjs` still exited 0 and
reported `consistent`. Its verdicts were unaffected, because they come from the logs. Anything that consumes the
summary field directly was trusting unchecked data. The exporter compares the summary with the decoded log and
refuses a mismatch, as covered by the test `validate.mjs does not read the userOpEvent summary; the export
cross-check does`.

## Limits

- The checker does not know the pin. Pin drift is refused by the exporter, through the passport comparison, not
  by the checker.
- `settlementVerified` comes from the collector's conservation result. The raw read-backs are archived in each
  `state` file for DSR's own audit, as DSR's readiness note requires.
- The local A/B endpoints are one anvil, so independence of the read sources is not shown here.
- Items 1, 3, 4 and 5 of AOA-SP-02 are not part of this bundle. They are the SP/VPM/TPM adapter matrix, the A4
  Passport and permission template, the security-test mapping, and formal sampling after M2 and author
  authorisation.
