# Frozen three-arm collector window

Use Node 24 (lossless JSON number reviver context) and Python 3. Add these
options to the existing formal collector invocation:

```
--frozen-plan rq3-three-arm.<chainId>.json --bundle-sha256 <approved-file-sha256> \
--seed <public-seed> --count 50 --max-attempts 60
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
slot rotates accounts across SP/VPM/TPM. The OP slot period is 30 seconds with
a 20-second elapsed bound; Sepolia uses 130/120 seconds. `manifest.json` records
the complete schedule payload and its SHA-256, qualification payload and hash,
all three plan SHA-256s, approved bundle hash and window start timestamp.

The collector always traverses the fixed 60 slots, even if it reaches the
50-complete-triplet target earlier. Each sender is allocated 20 attempts on each
arm, within the existing plans' 34/33/33 per-arm budgets. Incomplete slots stay
in the count; there are no result-based retries, replacements, reorderings or
extensions. Integrity failures can stop the window early and retain partial
slot counts. No pilot/warmup attempts run in this mode: `warmupAttempts` is zero
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
fees, plan/bundle digests and allocation. The bundle SHA-256 covers exact bytes;
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

Known gap: `validate.mjs` and `evidence-validate.mjs` do not accept this plan
mode. The schedule evidence writer retains incomplete slots without applying
the legacy replacement-exclusion policy; this does not add validator support.
Legacy invocations retain the existing formal configuration and protocol.

Offline tests use the real planner with its fake chain, injected chain clocks,
RPC transports and signers. No live RPC, Anvil or keystore is used.
