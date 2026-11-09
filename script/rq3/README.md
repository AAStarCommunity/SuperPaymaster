# RQ3 offline sampler/collector draft

This directory has no RPC transport, signer, deployment, or send implementation.
It does not import the executable A6 collector or upgrade executor. Existing A6
behavior and contracts are unchanged. All fixtures are synthetic, not measurements.

## Implemented

- `schedule.py:18`: public-seed SHA256-ranked batches of all six permutations;
  60 slots, permutation counts 8/9 in the first 50; cyclic three-account exposure
  17/17/16. JSON includes SHA256 of canonical UTF-8 `payload` (sorted keys, compact
  separators). Defaults are illustrative: 30-second period, 20-second maximum
  elapsed bound. The conservative spacing check is `3*period-maxElapsed >= 60`.
  `precheck.py:96` checks observed timing/order against that bound.
- `precheck.py:15`: invoke an injected `sp_attempt_precheck` once on each of two
  injected RPCs, even after the first refuses. Archive each block number/hash,
  flags, outcome, and accepted helper evidence. Refusals archive only the gate
  name, observed and expected values; exception text and extra fields are omitted.
  Only an executor `Gate` whose name is in `POLICY_GATES` counts as a policy
  refusal; all other Gates and exceptions propagate. A refusal before any head
  read retains an empty anchor, and the second endpoint still runs using its own
  `latest`. `endpoint_pins` records whether each endpoint had an incoming pin.
  Acceptance without an anchor raises. When available, the first head's number
  pins the second endpoint. After acceptance or refusal with a head, each endpoint
  re-reads that number and checks the hash; a change sets `chain_reorg` and refuses.
  Otherwise differing records set `rpc_mismatch`. Every state read (`eth_call`, `eth_getCode`, `eth_getStorageAt`) is rewritten to the anchor
  HASH (EIP-1898 `{blockHash, requireCanonical: true}`); a read naming any other block, or made
  before the anchor head read, raises. An endpoint that ignores EIP-1898 is not detected here.
  Source audit: `manifest_exec.py:2710,2716–2725` names `SP_RENEW_never`,
  `precheck_renewal_mode`, `precheck_allowance_cap`, `precheck_total_cap`,
  `precheck_allowance`, `precheck_total`; `price_gate` at lines 2610–2611 names
  `C_price_decimals`, `C_price_bound`; `POLICY_GATES` is exactly these eight. The
  `phase_c_state` gates (lines 2615–2631) are not reachable from the attempt helper.
  `a3a_exec.py:74–77` defines
  the Gate record; its exception type alone does not identify a policy refusal.
- `extract.mjs:56`: raw receipt log decoding, unique UserOperationEvent binding,
  receipt-status/UOE-success checks and exactly one bound settlement event for
  SP/TPM (independent of trace availability; VPM needs none),
  ERC20 transfer calldata/event checks, callTracer postOp calldata decoding,
  context decoding, SP charge reconciliation, and TPM integer conversion. Receipt
  and trace bind to one transaction/block; innerHandleOp binds sender, nonce,
  paymaster, hash and limits. Missing evidence stays null, exported as empty cells.
- `export.py:18`: every pinned REQUIRED_COLUMN plus schedule/prior, feeBps,
  sender, refusal and optional metrics. Unsuccessful attempts require a separate
  `failure_reason`; timeout is **not** an invented invalid code. Gate invalid codes
  remain only `rpc_mismatch|chain_reorg|collector_corruption`. Exclusion reasons
  use the actual gate's `expected_exclusion`. SP postOp limit must be >=480000.
  Each block/arm has at most one formal attempt. A retry needs an earlier
  incomplete block and a fresh slot/pair/hash; same-window retry references are
  checked. Cross-window retry annotations are currently rejected (see below).
- `export.py:78`: cross-window inventory includes CSV SHA256, window and experiment
  IDs, all consumed slots and per-arm attempt identities. Rebuild it from the
  ordered original CSVs to verify declared prior counts; gaps, reused pair/hash,
  duplicate windows, and mixed experiments fail. An incomplete consumed slot
  needs at least one row. First window has prior=0; consumed slots are cumulative.
  The inventory has its own canonical payload hash. Hashes establish consistency,
  not independent proof that an earlier window was never omitted.
- `precheck.py:78`: stop after three consecutive infrastructure failures, or >5%
  cumulative failures from attempt 20 onward. All formal attempts, including
  refusals, enter the denominator; failure classification must be explicit.
  Other protocol stops are injected as `stop_reason`. `account_available` keeps a
  timed-out account locked until late inclusion or proven drop. Late receipts
  cannot replace the timeout row; keep their costs in a supplemental archive.

## Archive interface and limitations

`extract.mjs` accepts an array of archives as demonstrated by `fixtures.mjs:10`:
`metadata`, `operation`, `transactionHash`, raw `receipt`, optional `trace`,
`validationContext`, `task`, and `state`. `trace` is a callTracer result wrapped
with its transactionHash/blockHash. `operation` contains the expected sender,
nonce, paymaster, EntryPoint, UserOperation hash, calldata and frozen gas limits.
`task` names token, amount, recipient and archived pre-window recipient balance.
State values are normalized archived snapshots with phase=`postOp`, transaction
and block anchors. No latest-state read is substituted. An archive adapter must
supply and retain the raw state evidence proving those snapshots; this draft
checks anchors and event arithmetic, not a storage proof or full source-map replay.
**Export rule: TPM `tokenChargeWei` / `refundPostopCost` and SP live `feeBps`
when `feeSnap=0` are UNVERIFIED supplied-state values.** Any SP formula outputs
using that live fee are likewise UNVERIFIED. `export.py` writes these columns EMPTY by default and names them in
`unverified_columns` (`--include-unverified` keeps the values, still named). CSV presence and a passing gate do
not certify their provenance; consumers must retain this designation until a
proof adapter exists.
The exporter does not certify schedule execution, passport invariants, funding,
confirmation depth, or dual-RPC receipt consensus. Those remain sampler duties.

`cPreWei` comes only from the actual postOp call input, not receipt costs or a
formula. `preOpGas` comes from innerHandleOp's UserOpInfo word 14. **G remains
empty for callTracer archives**, because this trace does not expose EntryPoint's
internal actualGas after postOp and before penalty. No inverse estimate from
actualGasUsed is accepted. This intentionally differs from A6's inverse/bounded
analysis (`../a6-collector/gas-decomposition.mjs:46`), which remains unchanged.
A qualified opcode/source-map extractor for G is not implemented. The gate checks
`actualGasUsed-G = floor(10*max(0,Lcall+LpostOp-(G-GpreOp))/100)` whenever all values
exist; the negative controls deliberately inject a wrong G to exercise that check.

Raw receipt logs, including PostOpRevertReason, remain in the archive. SP charges
come from TransactionSponsored, TPM amounts from UserOperationSponsored. A
missing sponsorship event sets `success=false`,
`failure_reason=missing_settlement_event` and leaves collected charge fields empty.
Settlement binds to the paymaster and sender under the single-UOE transaction rule;
trace-backed arithmetic additionally checks the SP operator and TPM gas cost. Full token settlement reconciliation
and automatic A6 journal-to-archive adaptation are not implemented here.

## Formula/source audit

Exact source fixtures and hashes are in `vendor/SHA256SUMS.json`. The DSR gate
is byte-for-byte `82453054:scripts/gate/paired_stats.py`; SHA256 is
`af4ef5d3b7dc34861b5c211e195f359f4fd9a629ed4a6f598ec419aa370d8fe6`.
No constants or gate validation rules were changed.

SP source below is `8de39026:contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol`,
vendored as `vendor/SuperPaymaster@8de39026.sol.txt` with original line numbers:

| Quantity | Source lines | Implemented calculation |
|---|---|---|
| Context layout | 40–82, 393–407 | 11 words / 352 B; optional 12th word / CTX_LEN=384 |
| Snapshot gas | 56–59, 422–424 | C_POSTOP bits 96..127 + C_WRAP bits 64..95 |
| Legacy buffer | 86, 422–424 | postOpGasLimit + 30000 when snap is zero; C_POSTOP left empty |
| Fee snapshot | 82, 340, 431–432 | snap >> 128; zero uses postOp-live fee, else feeSnap-1 |
| bufWei | 425 | (bufGas + ceil((Lcall+LpostOp)*10/100))*p_op |
| P | 426–427 | exact rational price*10^18 / (10^decimals*aPriceUSD) |
| aGas | 426–428 | ceil((C_pre+bufWei)*P) |
| c_hat | 433 | ceil(aGas*(10000+feeBps)/10000) |
| charge | 434, 450 | min(a0,c_hat); compare TransactionSponsored's debtAPNTs |

`extract.test.mjs` checks a literal large-number vector plus a small vector where
nested ceilings matter: C_pre=3, buffer gas=2, limits total=11, p_op=7, P=1/3,
fee=250 bps gives bufWei=28, aGas=11, c_hat=12, capped charge=10 for a0=10.

TPM is the repository-pinned eth-infinitism v0.7 source at `661d058c`, not a
network fetch: `singleton-paymaster/lib/account-abstraction-v7/contracts/samples/TokenPaymaster.sol`.
Its SHA256 matches `script/a6-collector/artifacts/TokenPaymaster.json:3`.
`vendor/TokenPaymaster@661d058c.sol.txt:167–172` updates cachedPrice, divides it by
markup using scale 10^26, then charges `(C_pre + refundPostopCost*p_op)` at that
marked price. Line 191 emits the token amount. `vendor/UniswapHelper@661d058c.sol.txt:74–79`
defines `tokenToWei(amount,price)=floor(amount*price/10^26)` and the inverse
integer conversion. `tokenChargeWei` uses the **updated pre-markup** cached price;
it is left empty if that snapshot is absent. The event's marked price alone
cannot be inverted exactly to recover the original price.

EntryPoint source at the same repository pin:
`singleton-paymaster/lib/account-abstraction-v7/contracts/core/EntryPoint.sol:703–707`
passes C_pre and p_op; lines 716–726 add postOp execution gas then the floored
unused-gas penalty. C_pre/p_op is therefore not G.

## Offline commands and tests

Use the repository's locked viem dependency; do not fetch packages in this task.
Python needs only the standard library. From the repository root:

```sh
python3 -B script/rq3/schedule.py --seed public-beacon-20261010 --accounts A B C > /tmp/rq3-schedule.json
node script/rq3/fixtures.mjs /tmp/rq3-records.json
python3 -B script/rq3/export.py --records /tmp/rq3-records.json --csv /tmp/rq3-window.csv --inventory /tmp/rq3-inventory.json
nice -n 10 python3 -B script/rq3/vendor/paired_stats@82453054.py --design aoa --csv /tmp/rq3-window.csv --out /tmp/rq3-stats.json
nice -n 10 node --test script/rq3/extract.test.mjs
nice -n 10 python3 -B -m unittest discover -s script/rq3 -p 'test_*.py' -v
nice -n 10 node --test script/a6-collector/gas-decomposition.test.mjs
```

`examples/synthetic-window.csv`, `examples/attempt-inventory.json`, and
`examples/schedule.json` are reviewable examples generated entirely offline.
The fixture generator follows that schedule's arm order and sender rotation.
Rebuilding the inventory from the CSV must reproduce its hash.

The fixture has 52 consumed slots, 155 attempts, one SP refusal, one TPM timeout,
one missing TPM arm, and a fresh retry block. It yields 49 complete blocks and
CLI exit 3 INCOMPLETE. A separate 53-slot positive control yields 50 complete
blocks and CLI exit 0 PASS. Tests invoke the unchanged CLI (10,000 bootstrap
resamples); internal exporter validation uses 100 resamples solely for structural
checks, and never publishes those results as paper statistics. Negative controls
assert specific diagnostic substrings in both CLI stderr (exit 2) and exporter
rejection for refusal broadcast fields, wrong
exclusion, penalty, c_hat, out-of-range slot and duplicate block/arm attempts.

## Open decisions for DSR before any live implementation

1. **Three-account precheck plans:** `script/upgrade/manifest_exec.py:2704–2712`
   binds to phaseC.addresses.S. `precheck.py:15` requires separately frozen plans
   for all senders, without rewriting the original plan. Decide the audited
   multi-account funding/Amax plan format and how it is signed/frozen.
2. **Exact G tracer:** qualify an opcode trace/source-map/bytecode pin at
   EntryPoint.sol:716–726; `extract.mjs:131–134` deliberately exports no G from
   callTracer. Trace method, node support, and reverted/fallback paths need
   qualification before penalty statistics can be claimed.
3. **Timeout and confirmations:** DSR `82453054` paper `main.tex:553` requires a
   frozen timeout but supplies no numeric value. Choose timeout and confirmation
   depth, head alignment/reorg policy and evidence for a provably dropped op.
   `precheck.py:112` implements only the pure account-lock decision.
4. **PostOp state provenance:** `extract.mjs:141–177` requires the state at postOp,
   especially TPM's updated cache and legacy SP live fee. Decide the qualified
   trace/storage proof adapter; block-end state is insufficient if later calls
   changed the slot. No automatic adapter or proof verifier is claimed. TPM
   `tokenChargeWei` / `refundPostopCost` and the legacy-SP live fee come from a
   supplied snapshot whose provenance is not proven and remain **UNVERIFIED**.
   The review scaled `postOpCachedPrice` and `priceMarkup` proportionally with
   identical logs/trace, changing `tokenChargeWei` from 3,608,004 to 5,412,006.
   DSR must confirm the proof adapter before these columns can be treated as verified.
5. **Cadence, stop classification, window handoff:** freeze public seed, period,
   elapsed bound, pilot limits, infrastructure-failure taxonomy and every
   non-infrastructure stop from paper `main.tex:547–558`. `schedule.py:18` and
   `precheck.py:78` implement mechanics only. `export.py:51` currently restricts
   retry annotations to the current window; agree a cross-window reference
   format before enabling those annotations. All earlier CSVs must be available
   for inventory verification (`export.py:78`).

6. **Cadence on the qualification chain:** the default 20-second elapsed bound per
   block assumes OP Mainnet's 2-second blocks. Three sequential single-op
   transactions on Sepolia (12-second blocks) cannot finish inside 20 s, so the
   Sepolia qualification run needs its own frozen period/bound.

7. **Timeout invalid code:** REQUIREMENTS #1.4 says timeout rows carry an
   "invalid code", but the pinned gate permits only
   `rpc_mismatch|chain_reorg|collector_corruption`. The draft records
   `success=false` plus `failure_reason=receipt_timeout` per `main.tex:553`.
   DSR: please confirm this representation or revise the pinned gate/specification.
8. **SP token settlement:** reconciliation required by `main.tex:569` is not
   implemented. DSR must define and qualify the token-settlement evidence adapter;
   TransactionSponsored charge arithmetic alone does not establish settlement.

The sole send entry point is `precheck.py:74` (`broadcast_disabled`), which always
raises. There is no live sampler loop. No chain, keystore, environment credential
file, or remote RPC was used to produce this draft.
