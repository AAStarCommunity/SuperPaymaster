# A6 collector — mechanism (SP-owned half)

This is the implementation half of the "A6 collector" from CC-122's sequencing plan
(`AOA_RepCredit_Sequencing_Plan_2026-09-13.md` §7.7, §8.4; RDR-6 in
`docs/design/aoa-balance-mode/03-final-spec.md` §10.8). It is **not** the collector's final
form and its dry-run output is **not accepted evidence** — see "Division of labor" below.

## Division of labor (plan §8.4)

- **DSR owns the sample protocol**: sample size, failure-sample mix, baseline configuration
  choices, the "Passport" schema, evidence-registry fields. **Not delivered yet as of this
  commit.**
- **SP (this code) owns the implementation**: same harness/ABI/lens conventions as D7's
  `script/gasless-tests/`, baseline comparator paymasters, dry-run on anvil first.

`--count` and `--b-max` on `collector.mjs` are placeholders you pass explicitly — there is no
real default, because the real values are DSR's deliverable. Do not treat a dry-run of this code
as a real sample campaign; it proves the mechanism works, nothing about paymaster performance.

## What's here

- `deposit-guard.mjs` — RDR-6 ① deposit-floor guard as pure functions: `F = B_max *
  gasLimitSum * maxFeePerGasCeiling` (gasLimitSum includes `preVerificationGas`, matching
  EntryPoint's own `_getRequiredPrefund`); before every send, if `deposit - estimatedCost < F`,
  the op is withheld and recorded as `{skipped: true, reason: 'DEPOSIT_FLOOR'}`, never sent.
- `collector.mjs` also classifies every `handleOps` revert it observes (via a read-only
  `simulateContract` preflight before broadcasting, and a same-block replay if a tx is mined but
  reverted anyway) by decoding EntryPoint's `FailedOp`/`FailedOpWithRevert` reason string: only
  `"AA31 ..."` (deposit too low — the guard should have prevented this) is
  `{infraFailure: true, sponsorshipFailed: false}`, counted apart from a paymaster's own failure
  rate. Every other reason (`"AA33 reverted"`, `"AA34 signature error"`, etc.) is the paymaster's
  OWN validation decision — `{infraFailure: false, sponsorshipFailed: true, revertReason}` — and
  counts toward that paymaster's sponsorship failure rate, not infra. A revert whose reason can't
  be decoded at all falls back to `infraFailure: true` (never silently counted as "the paymaster
  said no" when we don't actually know that).
- `build-baseline.sh` — compiles an UNMODIFIED eth-infinitism v0.7 sample paymaster
  (`VerifyingPaymaster` or `TokenPaymaster`) in a throwaway foundry project, because
  `TokenPaymaster` imports `@uniswap/v3-periphery`, which this repo does not vendor and must
  not be forced to. Generalizes `script/b-layer/f1-build-tpm.sh`'s technique (kept there
  unmodified — existing F1 evidence reproduction depends on its exact invocation).
- `artifacts/` — the two compiled baseline artifacts (abi + creation bytecode + source sha256),
  produced by `build-baseline.sh`. Regenerate: see command block below.
- `deploy-baselines.mjs` — deploys both baselines on a local anvil, staked (1 ETH /
  86400s, matching this repo's own SP anvil convention) and deposited (10 ETH). Reads
  `entryPoint` from the target deploy's own `deployments/config.*.json` — a plain
  `deploy-core anvil` run does NOT put EntryPoint at the canonical singleton address
  (`0x0000...7da032`); that address only exists on chains that pre-fund the ERC-2470
  deterministic deployer at genesis (as `script/b-layer/`'s own fixtures do).
- `collector.mjs` — the driver: one-time sender setup (a `SimpleAccount`, funded with xPNTs and
  the TokenPaymaster's own test ERC-20, and made SP-sponsorship-eligible), then drives `--count`
  ops through SP, VerifyingPaymaster and TokenPaymaster in turn, guarding every send, writing one
  JSONL row per op to `--out`.

## Why sender setup is done here, not via `script/gasless-tests/`

`prepare-test anvil` provisions SP *operators* (deployer, Anni), not a sender smart account —
D7's own phase-2 fork hit the same gap. Rather than depend on D7's test-only fixtures (kept
untouched per this deliverable's scope), this collector creates and funds its own `SimpleAccount`
directly. SBT eligibility (`SuperPaymaster.sbtHolders`, set via `SuperPaymaster.updateSBTStatus`,
`onlyRegistry`) is granted by impersonating the Registry address on the local anvil and calling
the exact same setter the real `Registry.safeMintForRole` path would call — not a fabricated
storage write, just skipping the community/role/staking bootstrap that path also requires, which
is out of proportion for a mechanism smoke test.

## Dry-run (verified working end to end)

```bash
export PATH="$HOME/.foundry/bin:$PATH"
anvil &                                            # fresh local chain
./deploy-core anvil --force && ./prepare-test anvil

# Rebuild baseline artifacts only if singleton-paymaster's samples changed:
#   script/a6-collector/build-baseline.sh <workDir> VerifyingPaymaster script/a6-collector/artifacts/VerifyingPaymaster.json
#   script/a6-collector/build-baseline.sh <workDir> TokenPaymaster script/a6-collector/artifacts/TokenPaymaster.json <@uniswap node_modules dir>

node script/a6-collector/deploy-baselines.mjs http://127.0.0.1:8545 script/a6-collector/dryrun-output/baselines.anvil.json
node script/a6-collector/collector.mjs --rpc http://127.0.0.1:8545 --count 2 --b-max 1
```

Confirmed (2026-09-16, this branch): all three paymasters (`SP`, `VerifyingPaymaster`,
`TokenPaymaster`) sponsor a real `handleOps` call successfully and produce a correct JSONL row
each. The deposit-floor guard was deliberately forced (`--b-max` set high enough that `F` exceeds
every paymaster's 10 ETH deposit) and verified to withhold all three ops — confirmed both via the
JSONL log (`skipped: true, reason: 'DEPOSIT_FLOOR'`) and by checking on-chain that the block range
covering that run contains zero transactions to the EntryPoint address (nothing was broadcast).

One SP-side finding surfaced during the dry-run, unrelated to D7 but worth flagging for whoever
tunes real gas limits later: `TestAccountPrepare.s.sol` only deposits 1,000 aPNTs into the
deployer operator's SP collateral by default, which is INSUFFICIENT_BALANCE at this dry-run's
(deliberately generous) gas limits — `collector.mjs`'s sender setup tops it up to 5,000 aPNTs.

## Things DSR's sample protocol will need to define (not resolved here)

- Real `B_max` (this file's placeholder is `1`, chosen only so `F` is a nonzero, checkable
  number in a dry-run — it is not a considered value).
- Scenario / failure-injection mix (this dry-run only exercises the "everything succeeds" and
  "everything withheld by the guard" cases — no partial failures, no AA33/AA34 injected samples,
  no rate-limit/blocked-user scenarios).
- The "Passport" schema and evidence-registry fields (plan §8.4) — this file's JSONL schema
  extends `g2-*.jsonl` (`docs/design/aoa-balance-mode/data/README.md` §1) with real-chain fields
  (`txHash`, `blockNumber`, `blockHash`, `blockTimestamp`, `chainId`, `paymasterKind`) but has not
  been reconciled against whatever Passport/registry shape DSR settles on.
- Top-up bookkeeping (plan: "只能在窗口之间由协议账户按固定额度补充，每次补充都登记") is an
  operational/runbook step, not automated here.
