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
collector refuses an existing window directory. Running the same slice in a new
directory produces a second result for that range, which the aggregate must
refuse as a duplicate.

No pilot/warmup attempts run in this mode. `warmupAttempts` is zero
and every formal attempt row has `warmup:false`. Do any pilot in a separate run;
its rows must be marked warmup and must not be inserted into this schedule.

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

Slice validation and aggregation are pending in the evidence PR. The schedule
evidence writer retains incomplete slots without applying the legacy
replacement-exclusion policy.

Offline tests use the real planner with its fake chain, injected chain clocks,
RPC transports and signers. No live RPC, Anvil or keystore is used.
