# R2-F3 prerequisite: positive control for the reservoir regime (RR) on a local engine

> **Correction (2026-10-23, #526 review N2).** The first version of this file said the replay runs "every preceding tx
> of the block in order". That was not true for the original run: anvil orders its pool by fee by default. A rerun that
> records the local block order (`run2-fee-order/`) shows **9/10 blocks reordered**: the target landed at local index 75
> instead of 84, so some "preceding" txs ran after it. gasUsed still matched 10/10, but not in the chain's in-block state.
> The replay now runs anvil with `--order fifo` and counts a match only if the local block holds exactly the replayed
> txs in submission order **and** the target sits at the chain index. `run3-fifo/` (current): nightly **10/10** (order
> 10/10, index 10/10, 0 preceding errors); 1.8.6 10/10 (3 blocks with one preceding error); 1.7.1/prague 0/3. The top-level
> `replay-*.json` / `run.log` are the original run and are kept as produced.

DSR (CC-125, 2026-10-23) left R2-F3 open: every G/B gas result so far was taken in the R0 regime
(transaction gasLimit ≤ 2^24, so the starting reservoir is 0). Any bundler can submit `handleOps` with
gasLimit > 2^24, and then the state-gas reservoir (EIP-8037) is non-zero. SP proposed option (i): measure
RR end to end on the calibrated engine. That is only decidable if the engine first reproduces **real RR
transactions**. This directory is that prerequisite. It is **not** the RR measurement of SuperPaymaster.

## Method

1. `script/evidence/rams-rr-scan.py`: pinned Sepolia range **[11,974,600, 11,975,000)**, i.e. 400 blocks and
   44,711 txs. It found 351 txs with gasLimit > 2^24, of which **88 have receipt gasUsed > 2^24**. Under
   Amsterdam (EIP-7825 cap 2^24) gas used above 2^24 can only be drawn from the reservoir. The maximum gasUsed
   is 88,769,372. Ten txs are picked deterministically: the first four in block order, then distinct `to`.
2. `script/evidence/rams-rr-replay.py`: for each picked tx, fork at block−1 on a local anvil, set the block
   timestamp, replay **every preceding tx of the block in order** and then the target (impersonated), mine,
   and compare receipt gasUsed and status with the chain. The local tx hash must differ from the chain hash.
   This shows the receipt came from local execution and not from the fork's remote fallback.
3. `script/evidence/rams-rr-positive-control.sh` runs both scripts and writes `run.log` (with the header:
   commit, dirty count, range; RPC redacted).

## Results — original run (`run.log`, `replay-*.json`; superseded by `run3-fifo/`, same counts)

| engine | hardfork | match | preceding-tx replay errors | role |
|---|---|---|---|---|
| foundry nightly 926eb1d (the calibrated R-AMS engine) | amsterdam | **10/10** | 0 in all 10 blocks | engine under test |
| anvil 1.8.6 | amsterdam | 10/10 | 1 in 3 of 10 blocks | comparison |
| anvil 1.7.1 | prague | **0/3** (e.g. chain 33,054,869 vs engine 4,727,329) | — | instrument control: a pre-Amsterdam engine must not match |

## What this does and does not establish

- **Does:** on these 10 real RR txs (gasUsed 17,904,329–70,412,677; 88,769,372 is the maximum over all 88, not a replayed tx),
  nightly 926eb1d reproduces gasUsed and status exactly, in the real block order (`run3-fifo/`, see Correction). The comparison can fail: 1.7.1 fails it. So option (i) is decidable
  with this engine.
- **Does not:** discriminate nightly from 1.8.6 on the target txs. Both match. 1.8.6's known defect (it
  undercounts CREATE state gas in the R-AMS probe, 6/14) shows here only as errors replaying some
  *preceding* txs. The engine choice for R-AMS still rests on the earlier probe, not on this table.
- **Does not:** say anything about SuperPaymaster under RR, or about which of the replayed txs exercised
  reservoir refill or the `gasleft()` effects. That is the RR matrix (R2-F3 option (i)), which awaits DSR's ruling.
- Sample: 10 of 88 RR txs in one 400-block window. Before the first scan, `to` diversity was not designed
  for; the picks cluster on a few deployers.

Read-only: no transaction was signed or broadcast; local anvil forks only.
