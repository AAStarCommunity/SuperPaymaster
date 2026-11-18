# Frozen three-arm collector mode

Use Node 24 (lossless JSON number reviver context). Add these options to the
existing formal collector invocation:

```
--frozen-plan rq3-three-arm.<chainId>.json --bundle-sha256 <approved-file-sha256>
```

The file is the planner's bundle (`plans` keyed by S). `--formal-config`'s
`sender` selects one S. Keep the normal formal RPC identity, archive, signer,
deployment and comparator inputs. Their identities must match the selected
plan. Set `--max-attempts` to no more than `phaseC.attempts` (34/33/33 in the
fixture), and set `--count` within that budget. Indices are zero-based per S.
The SHA-256 is over the exact bundle bytes; each selected whole-plan digest
uses the planner's sorted, compact, ASCII-escaped JSON encoding. Large JSON
integers are preserved without floating-point rounding.

Gas, paymaster gas, outer transaction gas and fees come from the plan.
Account creation is refused: complete the plan's setup before collection.
Before sending, both archived endpoints read chain ID, gasParams and SP stake
at the refreshed fixed block. Base fee plus priority must fit feeCap, itself
bounded by feeRule.ceiling. Neither fee history nor gas estimates are rerun.
Every attempt row includes planDigest, bundleSha256, gasSources for its arm,
spPostOpRule, feeRule and allocation. The receipt path retains raw receipt and
observed settlement branch before a mismatch stops the run.

The adapter retains the existing formal runtime's fixed-block archive checks,
endpoint identity checks, development-method refusal and credential filtering.
Legacy invocations still use formalConfig and its fixed 5/1-gwei rules.
The existing standalone A6 validators still enforce that legacy fee policy
and 50-triplet protocol; they are not a validator for this new plan mode.

Offline tests generate a bundle with the real planner and ThreeArm fake chain,
then inject send/read/receipt transports. No Anvil, RPC or keystore is used.
Fail-first and guard-removal outputs are retained under cache/adapter/.
