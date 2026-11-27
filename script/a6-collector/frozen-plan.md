# Frozen three-arm collector windows

Use Node 24 (lossless JSON number reviver context) and Python 3. Add these
options to the existing formal collector invocation:

```
--frozen-plan rq3-three-arm.<chainId>.json --bundle-sha256 <approved-file-sha256> \
--seed <public-seed> --count 50 --max-attempts 20 --window-index <1|2|3>
```

One invocation loads all three per-sender plans from the planner bundle
(`plans` keyed by S). In `--formal-config`, provide `senders` in the public
schedule's account order, each with `sender`, `salt`, and `owner: {name,address}`.
The shared operator, factory, bundler, verifying signer, task, deployment,
comparator and RPC identity inputs remain the normal formal inputs. Each
sender identity and owner must match its frozen plan. Addresses are normalized
to checksum form before generating the schedule. All accounts must already
exist and be prepared; account creation is refused during collection.

The collector uses the public seed, ordered accounts and frozen chain
qualification in `chain-params.json` to generate 60 slots: ten batches of all
six arm permutations, ordered by SHA-256 of seed, batch and permutation. Each
slot rotates accounts across SP/VPM/TPM by its global slot number. The provisional
OP slot period is 120 seconds with a 100-second elapsed bound. Sepolia uses
130/120 seconds. `manifest.json` records
the complete schedule payload and its SHA-256, qualification payload and hash,
all three plan SHA-256s, approved bundle hash, the selected slice and its start
timestamp.

Run the three windows in order with the same seed and ordered accounts. Window 1
covers slots 0–19, window 2 covers 20–39, and window 3 covers 40–59. Each window is
a separate collector run with its own start and end passports. Refresh the price
externally before each window. The price may change only between windows. Slot
starts and deadlines are measured from the start of that window.

Every slot in each slice is attempted in order with no optional stopping,
result-based retries, replacements, reordering or extensions. After all 20 slots
and successful end checks, the window reports `EXHAUSTED` and exits 0 even if it
has incomplete triplets. Fail-closed stops report `STOPPED`, retain partial slots,
and list unreached slots within that slice as `unusedSlots`. The `window` record
in `run_end` and `trailer.json` identifies the slice and reports local slot and
triplet counts. Each sender uses 20 scheduled allocations per arm across all
three windows, within the existing plans' 34/33/33 per-arm budgets.

`--count 50` records the collection target. The later evidence aggregate is
`COMPLETE` with at least 50 complete triplets across all three valid windows and
`INCOMPLETE` below 50. A missing or void slice yields `INVALID-INTERRUPTED`. A
void or interrupted slice must never be rerun under the same registration. The
collector refuses a window directory that already contains `raw/`, `index.ndjson`
or `manifest.json`. It also refuses a non-empty output file. The aggregate
refuses a duplicate slice range, even when the runs have distinct IDs.

No pilot/warmup attempts run in this mode. `warmupAttempts` is zero
and every formal attempt row has `warmup:false`. Do any pilot in a separate run;
its rows must be marked warmup and must not be inserted into this schedule.

## First use before collection

Run the collector with `--first-use --frozen-plan` and the approved bundle
digest, formal configuration, deployment configuration, baselines, RPC
registry, pins, RPC URL files, and keystore password source. Give it a separate
`--run-id` and `--out` directory with a `run.jsonl` path. Omit
`--window-index`.

The collector compares key-0 EntryPoint nonces at a common pinned block, then
runs one frozen SP attempt for each zero-nonce sender in bundle order. Each
attempt has a separate 180-second wait and submission limit, also bounded by
the cached price expiry. The journal records the two nonce readings before
signing and at inclusion. A signed transaction awaiting reconciliation leaves
a sender marker in the collector lock directory. The setup journal cannot be
used as window evidence.

## Window gates and traces

A sent TPM operation in a frozen window takes both debug traces from RPC A.
RPC A and B still agree on the receipt. A `TokenPriceUpdated` log emitted by
the TPM paymaster requires the trace-derived refresh flag to be true.

Known gap: TPM postOp trace from one provider; byte-identical callTracer and prestateTracer results on two further providers for tx 0x62318b209aca40c80e67c6d4e21a3c1cd42bc2dfcde8ecb34023cf155490809b (probe 2026-11-27)

Before an SP attempt, both archived endpoints read `operators(operator)` and
`userOpState(operator,sender)` at a common fixed block. The collector waits for
`block.timestamp >= lastTimestamp + minTxInterval`, rereading both values at
each pin. It also waits for the slot start, and refuses submission explicitly
if the pin or required validAfter exceeds the slot deadline. `spWait` records
seconds, blocks, values read, validAfter and pin; `slotChecks` retains each gate
result. A second gate runs at submission, before fresh fee and pending-nonce
checks. This proves readiness at the observed pin, not a guarantee about future
inclusion or concurrent external activity. The sampler's 60-second spacing
qualification does not replace the chain-read rate limit.

A sent row's inclusion block timestamp is not required to be at or before the slot deadline. The registered gate is on submission: the collector refuses to submit when the pinned block at the submit gate is past the deadline; inclusion follows by block production and can fall after it. The row records the inclusion block and its timestamp, and they are reported as collected.

No real window may be treated as evidence before the slice-evidence PR (schedule regeneration from the registered seed and hash, exact slice traversal, three-window aggregate) lands.

Every attempt row and evidence index records `block_slot`, `pair_id`, `seed`,
`schedule_sha256`, and `sender`. Attempt rows also retain exact plan-derived gas,
fees, plan/bundle digests and allocation. `allocation.tripletIndex` is the
cumulative zero-based index for that sender and arm over the full schedule.
The bundle SHA-256 covers exact bytes;
whole-plan hashes use the planner's sorted, compact, ASCII-escaped JSON encoding.
Large integers remain lossless. Bundle/plan integrity, chain, gas parameters,
operator interval and stake are checked before sending. No gas estimate or fee
history is recalculated, and no funding or allowance changes occur mid-window.

The schedule generator lives beside the collector because the collector owns
window execution; the port contains only schedule generation and the frozen
chain-parameter qualification it reads. The planner is unchanged. Fixed SP
allowance/total caps remain a separate resource constraint; see the resource
audit in `cache/sched/REPORT.md` rather than assuming an attempt budget alone
proves allowance sufficiency.

Store the journal at `<window-dir>/run.jsonl`. Validate each slice and aggregate the
three directories with the registered seed and schedule SHA-256 from the
registration:

```sh
node script/a6-collector/validate.mjs <window-dir>/run.jsonl --frozen-plan <bundle> \
  --registered-seed <seed> --registered-schedule-sha256 <hex>
node script/a6-collector/aggregate-windows.mjs <window-1> <window-2> <window-3> \
  --frozen-plan <bundle> --registered-seed <seed> --registered-schedule-sha256 <hex>
```

The evidence writer retains incomplete slots without applying the legacy
replacement-exclusion policy.

Offline tests use the real planner with its fake chain, injected chain clocks,
RPC transports and signers. No live RPC, Anvil or keystore is used.
