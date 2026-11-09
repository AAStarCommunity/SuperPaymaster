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

3. **TPM event charge and verified refund constant.** Amount and marked price
   come from `UserOperationSponsored`, not a supplied summary
   (`vendor/TokenPaymaster@661d058c.sol.txt:46,191`; `extract.mjs:135`).
   Both archived RPCs must contain the exact `tokenPaymasterConfig()` and
   `cachedPrice()` requests at receipt block hash with
   `{blockHash,requireCanonical:true}`; raw ABI replies must agree
   (`evidence.mjs:17`; `extract.mjs:205`). The config getter fields are defined
   at `vendor/TokenPaymaster@661d058c.sol.txt:30-53`.
   Require `actualTokenCharge = floor((actualGasCost + refundPostopCost*p_op)*10^26/markedPrice)`
   exactly (`vendor/TokenPaymaster@661d058c.sol.txt:171-172`;
   `vendor/UniswapHelper@661d058c.sol.txt:78-79`). A mismatch is
   `collector_corruption`; disagreeing RPC replies are `rpc_mismatch`.
   `refundPostopCost` is no longer UNVERIFIED (`export.py:19`).

   **Pre-markup price is not always uniquely recoverable.** Let `U=10^26`,
   logged price `m`, hash-bound markup `M`. From `m=floor(price*U/M)`, the
   candidates are `[ceil(m*M/U), ceil((m+1)*M/U)-1]`
   (`vendor/TokenPaymaster@661d058c.sol.txt:162-169`). Require the block-end
   cache to reproduce the logged price exactly. Only a singleton interval
   can verify `tokenChargeWei=floor(amount*price/U)`; otherwise this column stays
   UNVERIFIED and exports empty by default (`extract.mjs:215-220`; `export.py:19`).
   A later cache update can select another member of that interval; a block-end
   read alone does not identify the earlier postOp value. Cache updates are
   public and can replace the stored price
   (`singleton-paymaster/lib/account-abstraction-v7/contracts/samples/utils/OracleHelper.sol:88,118-121`).
   Integer scaling is exactly `vendor/UniswapHelper@661d058c.sol.txt:74-79`.
   Verification additionally requires a single-transaction block and no config
   setter call anywhere in its archived callTracer tree (`extract.mjs:219-224`).
   Otherwise even a singleton remains UNVERIFIED: block-end markup alone
   does not identify the markup used earlier in postOp.

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

6. **SP settlement reconciliation.** Exact source names:
   `TransactionSponsored(operator,user,aPNTsCost,debtAPNTs)`
   (`contracts/src/interfaces/ISuperPaymaster.sol:53`),
   `LockCreated(user,opHash,locker,xLocked,aReserved)` and
   `LockSettled(user,opHash,xBurned,aCharged)`
   (`contracts/src/tokens/v2/xPNTsV2Base.sol:134-135`).
   `extract.mjs:175-196` requires exactly one matching lock pair by user/opHash,
   the paymaster as locker, and all of:
   - `aPNTsCost=aGas`; `debtAPNTs=min(a0,c_hat)`
     (`vendor/SuperPaymaster@8de39026.sol.txt:425-434,450`).
   - `charge'=min(debtAPNTs,aReserved)`; `aCharged=charge'=debtAPNTs`.
   - `xBurned = aReserved==0 ? 0 : ceil(charge'*xLocked/aReserved)`, clamped to
     `xLocked` (`contracts/src/tokens/v2/xPNTsTokenV2.sol:258-268`).
   - Operator reserve delta `=-debtAPNTs`: validation deducts `a0`; postOp
     refunds `a0-charge` (`vendor/SuperPaymaster@8de39026.sol.txt:322,447`).
     Read `operators(operator).aPNTsBalance` at parent and receipt hashes on
     both RPCs. Getter field order: `contracts/src/interfaces/ISuperPaymaster.sol:13-36`.

   Any failed reconciliation gives `collector_corruption` plus a diagnostic.
   **DSR confirmation point:** `aReserved < debtAPNTs` is corruption under
   DSR's extra equality, although the token contract itself caps the charge
   (`contracts/src/tokens/v2/xPNTsTokenV2.sol:258`).

## Remaining / evidence limits

- SP operator-reserve delta (DSR ruling 6) is checked only when the op's transaction is the
  sole transaction of its block (`extract.mjs:190-201`); a mismatch there is
  `collector_corruption`. In a shared block the parent-to-block delta is not attributable to
  the op, so the check is skipped and recorded as `reserveDeltaVerified=false` (exported),
  never reported as corruption. On OP Mainnet most blocks are shared: DSR to decide whether
  the reserve check must hold on every row (needs a transaction-level state adapter) or the
  log-level checks (debtAPNTs == min(a0, c_hat) == aCharged, xBurned formula) suffice.
- TPM general block-end reads cannot establish the postOp markup. Config can
  change through `setTokenPaymasterConfig`
  (`vendor/TokenPaymaster@661d058c.sol.txt:93-99`). Without block isolation and
  the no-setter trace check, `tokenChargeWei` stays UNVERIFIED, even when the
  inverse at the supplied markup is unique. In a shared block a later transaction may
  also move `cachedPrice` (`OracleHelper.sol:88,118-121`), so a charge or price mismatch
  there leaves `refundPostopCost`/`tokenChargeWei` empty and UNVERIFIED; only in an isolated
  block is a mismatch `collector_corruption`. `refundPostopCost` is verified whenever the exact
  integer charge equation (`TokenPaymaster.sol:171-172`) reproduces the logged charge.
- Every successful arm, VPM included, needs its trace: the penalty inversion (ruling 1) applies
  to all arms. A data check that fails yields a `collector_corruption` row, not an aborted run.
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
runtime, legacy stops, SP lock matching/burn/charge/reserve delta. Synthetic
examples remain 52 consumed slots, 155 attempts, 49 complete blocks; the separate
positive gate control reaches 50 (`test_rq3.py:285`).
