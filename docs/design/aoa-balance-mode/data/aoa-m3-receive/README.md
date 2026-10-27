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
  attempt's own receipt logs, matched by EntryPoint address, topic and expected `userOpHash`. The address topics
  must be canonically zero-padded. When the collector's verdict is success, the decoded event must equal the
  collector's record: `userOpEvent` hash, nonce, sender, paymaster, success, `actualGasCost` and `actualGasUsed`,
  plus the row's own sender, paymaster and nonce. Otherwise the export is refused.
- **Checks gas on every arm.**
  - For a successful UOE, `actualGasCost` must be an exact multiple of a positive `actualGasUsed`.
  - The per-gas price must be at most the op's `maxFeePerGas`.
  - The price must imply a basefee between 0 and the bundle transaction's effective price. When the price is
    capped at `maxFeePerGas`, the cap must be reachable.
  - A failed UOE can carry a prefund cost that need not divide, so it is excluded as `UOE_FAILED` without this
    check. EntryPoint v0.7 emits `success=false` with `actualGasCost = prefund` in that case: see
    `EntryPoint.sol:127-133` and `:732-737` in `singleton-paymaster/lib/account-abstraction-v7`.
  - The check follows the decoded UOE, not the collector's verdict.
  - Receipt `gasUsed`, `gasLimit` and `effectiveGasPrice` must be decimal strings, with
    0 < `gasUsed` ≤ `gasLimit`.
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
- **Controls, two kinds.**
  - **Per arm.** `entryPoint`, `target`, `calldataHash`, `accountImplementation` and `bundlerConfigHash` are
    derived from each attempt's own data, so the checker's per-group equality really compares the arms.
    - `accountImplementation` is the attempt's sender resolved against the passport, and must be the passport's
      account.
    - `bundlerConfigHash` covers the bundler, the bundle transaction's sender, the beneficiary, and the op's own
      gas limits and fee caps.
    - Paymaster gas limits differ by design between SP, VPM and TPM. They are recorded per row as `paymasterGas`,
      a necessary difference, and are not hashed.
  - **Run level.** `tokenStateProtocol`, `windowId` and `samplingProtocolHash` name the run's procedure and are
    equal by construction. The checker's equality says nothing about them.

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
| one arm's bundler configuration differs | FAIL | FAIL | mismatched bundlerConfigHash |

Each negative control passes only if the checker reports **that** diagnostic, not merely `FAIL`. A positive
control must report no error. A checker crash fails the row, even if valid JSON was printed first. Exit code 1 means FAIL, but an uncaught
Python exception also exits 1, so a crash is recognised by a traceback on stderr or by any exit code other than
0 and 1. A checker that prints no verdict at all is recorded as `NO_JSON` and fails its row. The remaining
controls still run. The duplicate-UserOp control reuses a hash across groups, which keeps every group
at exactly one SP/VPM/TPM, so duplicate detection is the only rule it can trip. The tamper edits are in
`script/a6-collector/aoa-m3-tamper.py`.

**Exporter-level controls** are in `script/a6-collector/to-aoa-m3-receive.test.mjs`, 24 tests, all passing. Three of them need `viem` (the topic
constant and the two `validate.mjs` tests) and are skipped without it.
They cover:
- UOE deleted from a success row;
- collector summary disagreeing with its log (`actualGasCost`, `actualGasUsed`, `success`);
- an inconsistent archive;
- passport (pin) drift and a missing passport;
- an unmatched triplet;
- inconsistent gas evidence on any arm (including an unreachable maxFee cap), and non-decimal receipt numbers;
- non-canonical address topics;
- a differing arm made visible to the checker, and a non-passport account;
- fixture rows kept;
- `runType` following `protocolConformant`;
- determinism;
- the topic constant;
- the non-empty output directory.

The n50 package is not committed: `receive.json` alone is about 280 KB, and it lists 452 raw files. All of it is
regenerated deterministically from the archived JSONL. The regenerated `receive.json` must have sha256
`9741d32ab8127dfc0f75ce39f04c8caae96e12aa4703f743b37a5f1741388911`, and two independent runs produced exactly
that value. `positive.receive.json`, the one-triplet package, is committed as a readable example.

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
