# RQ3 offline collector basis

DSR rulings applied **2026-11-09**, including the clarified settlement names.
Offline only; fixtures are synthetic. Broadcasting remains disabled
(`precheck.py:89`). No network, chain, keystore, or commit was used.

## Implemented / DSR rulings

1. **Invert the penalty; no opcode trace.** `evidence.mjs:48` solves
   `A = G + floor(max(0,L-(G-preOpGas))/10)` for integer `G >= preOpGas`.
   Source: `singleton-paymaster/lib/account-abstraction-v7/contracts/core/EntryPoint.sol:716-726`.
   Success cannot use the prefund cap: the capped branch emits failure, while
   the other low-prefund branch reverts (`EntryPoint.sol:730-747`, same path).
   For `B=L+preOpGas`, `q=B-A>0`, positive unused gas `d=B-G` satisfies
   `10*(q-1) < 9*d <= 10*q`. This interval has width `10/9`, hence at most
   two integer solutions. The no-penalty branch is `G=A >= B`, including equality;
   it cannot overlap the positive-penalty inverse branch.
   Export `unusedGasPenaltyMin/Max` and semicolon-separated
   `gasBeforePenaltyCandidates`. `gasBeforePenalty` is empty unless unique;
   the unchanged gate rechecks a populated value. No solution gives
   `invalid_reason=collector_corruption`. Exhaustive tests enumerate small
   `preOpGas`, limits, observed gas and all candidate G, including `L=G-preOpGas`
   (`extract.test.mjs:101`).

2. **Freeze three sender plans before slot 1.** `manifests.py:28` builds a
   canonical-JSON SHA256 envelope binding schedule, qualification, baseline,
   and each of three phaseC plans. `validate_window` rebuilds it; every
   `before_sp_attempt` requires its manifest and checks the actual plan hash
   and `phaseC.addresses.S` before invoking either endpoint
   (`manifests.py:48,54`; `precheck.py:23`). Explicit window stops:
   `plan_sender_mismatch`, `plan_sender_missing`, `plan_hash_mismatch`,
   `three_sender_plans_required`, `window_manifest_mismatch`.
   Never rewrite S inside an existing plan. Hashes establish consistency;
   the operator must archive the freeze before the first attempt.

3. **TPM (decision C, 2026-11-09).** `window.mjs:36` validates an archived
   window before per-row use (`extract.mjs:219`). `tpmWindow` binds `window_id`,
   address, first/last block hashes, contiguous numbered parent-linked `blocks`,
   `configFirst`, and `configLast`. Each block carries two distinct RPC archives
   of `eth_getLogs({address,blockHash})`, without topic/range filters; replies must
   agree and every log must match that address/hash. Every block is required,
   including endpoints. Config reads are raw `eth_call` replies from both RPCs
   with `{blockHash,requireCanonical:true}` at the window endpoints. The row's
   receipt must belong to the window. These are archive assertions, not live reads.

   Equal endpoint configs plus no `ConfigUpdated` verify `priceMarkup` and
   `refundPostopCost` for the window. An event (even change-and-restore), or differing
   endpoint configs, stops with `baseline_config_changed`. Missing/malformed
   evidence is corruption; disagreeing RPCs give `rpc_mismatch`.
   Source: `singleton-paymaster/lib/account-abstraction-v7/contracts/samples/TokenPaymaster.sol:44,93-99`:
   the only config assignment is in the setter, which emits the event, including
   constructor initialization (`:87`). Canonical signature:
   `ConfigUpdated((uint256,uint128,uint48,uint48))`.

   No per-row isolation, setter-trace inference, refund-constant inversion, or
   block-end `cachedPrice` read remains. `refundPostopCost` is read directly.
   The event charge must equal
   `floor((actualGasCost + refundPostopCost*p_op)*10^26/markedPrice)`.
   `_postOp` updates the cached price (`TokenPaymaster.sol:167`), divides it by
   markup (`:169`), and emits that marked price (`:191`). Conversion uses
   `samples/utils/UniswapHelper.sol:74-79`; public cache changes are at
   `samples/utils/OracleHelper.sol:88,118-121`.

   **Protocol conversion:** for `U=10^26`, event price `m`, verified markup `M`,
   the pre-markup price interval is `[ceil(m*M/U), ceil((m+1)*M/U)-1]`.
   A singleton verifies `tokenChargeWei=floor(actualTokenCharge*price/U)`.
   Otherwise it remains empty/UNVERIFIED with `pre_markup_price_ambiguous`.
   Export the interval, `priceMarkup`, and the separate event-only conversion
   `eventTokenChargeWei=floor(actualTokenCharge*m/U)`; never substitute that for
   the protocol column. See **Open for DSR** below.

   **Baseline runtime binding.** `baseline.mjs:5` pins the SHA256 of the frozen
   v0.7 sample artifact. `runtimeFor` interprets only its straight-line runtime
   return block, patches the four constructor immutables, and hashes the exact
   runtime. `evidence.mjs:30` checks both hash-bound `eth_getCode` archives
   against that result and the manifest's `tpm_runtime_codehash` and
   `frozen_build_sha256`. This is offline bytecode processing, not deployment.
   Immutable assignments: `singleton-paymaster/lib/account-abstraction-v7/contracts/core/BasePaymaster.sol:23-25`
   and `vendor/UniswapHelper@661d058c.sol.txt:36-45`.
   The frozen artifact is `script/a6-collector/artifacts/TokenPaymaster.json:1`;
   its exact return-block offsets are documented in `baseline.mjs:11-14`.

   **Legacy SP contexts stop the window.** Both 352-byte contexts and 384-byte
   contexts with `feeSnap==0` produce `legacy_sp_context`; no live-fee adapter
   remains (`extract.mjs:21`; `export.py:25`). Source context and fee behavior:
   `vendor/SuperPaymaster@8de39026.sol.txt:393-407,429-434`.

4. **Timeout / confirmation.** REQUIREMENTS #1.4 is superseded by DSR:
   `success=false`, `failure_reason=receipt_timeout`; timeout is not an invalid
   code. OP: 120 s from broadcast, depth >=10; Sepolia: 180 s, depth >=3.
   At depth, re-read the inclusion block hash; mismatch gives `chain_reorg`.
   A late receipt is supplemental only and cannot add analysed gas/charges.
   Frozen parameters: `chain-params.json:2-3`; enforcement:
   `manifests.py:65`, `evidence.mjs:76`, `extract.mjs:85`.
   An unresolved timed-out account remains locked (`precheck.py:127`).

5. **Qualification elapsed bounds.** Ten block periods: OP 2 s -> 20 s;
   Sepolia 12 s -> 120 s. Qualification manifest and schedule bind these
   values. Default slot periods are respectively 30 s and 130 s; observed
   timing uses the schedule's deadline (`chain-params.json:2-3`;
   `manifests.py:17`; `schedule.py:18`; `precheck.py:111`). These numbers are
   DSR's frozen protocol parameters, not measured chain-performance claims.

6. **SP settlement (decision A, 2026-11-09).** Verified with
   `git show 8de39026:contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol`:
   `:349` passes exactly `a0` to `tryLockForGas`; `:434` caps charge at `a0`.
   `extract.mjs:190` checks `aPNTsCost=aGas`, `debtAPNTs=min(a0,c_hat)`,
   `LockCreated.aReserved=a0`, `aCharged=debtAPNTs`, and
   `xBurned=min(xLocked,ceil(debtAPNTs*xLocked/a0))` (zero when `a0=0`).
   Token rounding: pinned `contracts/src/tokens/v2/xPNTsTokenV2.sol:258-268`.
   Every such mismatch is `WindowStop settlement_mismatch`, with row identity
   and diagnostic, not `collector_corruption`. Missing/ambiguous or malformed
   logs and wrong bindings remain evidence errors. `export.py:130` writes the
   CSV before raising a stop carrying `rows`, `diagnostic`, and `stop_reason`;
   stopped windows cannot reach the gate or accepted inventory.

## Open for DSR

**B: reserve attribution stopped at the requested source audit (2026-11-09).**
The complete balance-write search at `8de39026` found seven write sites (including
storage alias `config`); no whole-operator replacement/deletion was found.
Paths below are under `contracts/src/paymasters/superpaymaster/v3/`:

| Writer | Emission / result |
| --- | --- |
| `SuperPaymaster.sol:172` deposit credit (deposit, depositFor, onTransferReceived) | `OperatorDeposited` at `:174` |
| `SuperPaymaster.sol:204` withdrawal | `OperatorWithdrawn` at `:207` |
| `SuperPaymaster.sol:322` validation debit | **No event**; interface `ISuperPaymaster.sol:56` explicitly notes validation cannot emit |
| `SuperPaymaster.sol:447` postOp refund | **Unlisted** `TransactionSponsored` at `:450` |
| `SuperPaymaster.sol:462` stale sponsorship release | `SponsorshipReleased` at `:463` |
| `SuperPaymasterAdmin.sol:637` slash decrement | `OperatorSlashed` at `:655`; BLS caller also emits `SlashExecutedWithProof` at `:609` |
| `SuperPaymasterAdmin.sol:641` slash zeroing | Same emissions as `:637` |

Pinned ABI signatures: `OperatorDeposited(address,uint256)`,
`OperatorWithdrawn(address,uint256)`, `OperatorSlashed(address,uint256,uint8)`
(operator indexed; `contracts/src/interfaces/ISuperPaymaster.sol:49-54`);
`SponsorshipReleased(bytes32,address,uint256)` (opHash/operator indexed;
`SuperPaymasterStorage.sol:258`);
`SlashExecutedWithProof(address,uint8,uint256,bytes32,uint256)` (operator indexed;
`SuperPaymasterStorage.sol:236-242`). The unlisted signature is
`TransactionSponsored(address,address,uint256,uint256)` (operator/user indexed;
`ISuperPaymaster.sol:53`). Admin `:599,601` are reads, not writers.

Per B's explicit instruction, the unlogged/unlisted writers stop this part.
No SP log attribution adapter was invented. The obsolete sole-transaction check
is removed; rows say `reserveDeltaVerified=false` and
`reserveDeltaDiagnostic=reserve_attribution_blocked_source_audit`.
Inventory exports `reserve_delta_verified_count` (`export.py:103`), currently zero.
Dedicated-operator and full dual-RPC SP/EntryPoint block-log attribution, and its
reserve-mismatch stop, remain unimplemented pending a revised event coverage rule.

**C: event-only conversion conflicts with the protocol definition.** The supplied
`82453054 main.tex sec:gas` definition requires pre-markup price so markup appears
in `s_c`; the event logs the price after markup. This definition was supplied in
this task; no DSR repository/network access was used. The implementation follows
that protocol definition when the pre-markup price is exactly recoverable.

Fixture (`extract.test.mjs`, event-only conversion control): `U=10^26`,
`actualGasCost=3000004`, refund `40000`, `p_op=7`, markup `1.1U`, price `3U`.
The event logs `m=272727272727272727272727272` and amount `1202668`.
Event-only conversion gives **3280003 wei**, approximately the native charge
`3280004`, hiding markup. The protocol conversion gives **3608004 wei**.
With verified markup `2U` and the same event, the pre-markup interval is
`[545454545454545454545454544,545454545454545454545]`: two prices fit exactly.
We do not invent which was used, even if rounding may make their converted wei
coincide. The interval/diagnostic remains exported and `tokenChargeWei` stays
UNVERIFIED. Thus C's unconditional “never UNVERIFIED from the event alone” is
not implemented; its explicit protocol-conflict exception is applied.

## Remaining / evidence limits

- Every successful arm, VPM included, needs its trace: the penalty inversion (ruling 1) applies
  to all arms. Binding/decoding failures yield a `collector_corruption` row; A/C stops retain identity and diagnostics.
- A finalised timeout (`finalTimeout`) must carry `timeoutDeclaredAt` at or after the frozen
  deadline; a flag alone cannot shorten the timeout.
- This directory validates injected/archived evidence. It has no receipt polling,
  live freeze publication, signing, funding, or archival transport. Raw request
  archives do not prove an RPC honored EIP-1898. No live qualification is claimed
  (`precheck.py:23,89`; `evidence.mjs:17`).
- Credit-mode SP settlement is outside this lock-based ruling: the contract uses
  `settleCredit` instead of `settleLocked` for that mode
  (`vendor/SuperPaymaster@8de39026.sol.txt:438-442`). Missing lock evidence fails
  closed; no invented LockSettled event is substituted.
- Cross-window inventory remains supported; retry annotations still reference
  earlier incomplete blocks within the same window (`export.py:68,95`).

## Fixtures / verification

Examples include schedule, three sender plans, qualification and window manifests,
synthetic CSV and inventory. Canonical JSON is sorted keys, compact separators,
UTF-8 (`schedule.py:10`). The pinned gate under `vendor/` is unchanged.
Source bytes for SP match `8de39026`; vendored TPM and UniswapHelper match the
local v0.7 source files. Existing SHA256 pins remain in `vendor/SHA256SUMS.json:1`.

```sh
python3 -B -m unittest discover -s script/rq3 -p 'test_*.py' -v
node --test script/rq3/extract.test.mjs
```

Tests cover positive cases and diagnostic-specific negative controls for penalty
inversion, manifests, sender binding, timing, receipt depth/reorg, TPM reads and
runtime, legacy stops, SP lock matching/burn/charge, reserve-audit blocking, config windows and stopped exports. Synthetic
examples remain 52 consumed slots, 155 attempts, 49 complete blocks; the separate
positive gate control reaches 50 (`test_rq3.py:285`).
