# Slither triage — `arbitrary-send-erc20` excluded (with rationale)

The Stage 3 Slither gate runs with `fail-on: high`. The only High-severity detector that
fires on `contracts/src` is **`arbitrary-send-erc20`** ("uses arbitrary `from` in
`transferFrom`"). It is excluded via `detectors_to_exclude` in `slither.config.json`
because **every instance is a deliberate, guarded transfer** — Slither cannot reason about
the access-control / signature guard that authorizes the `from`, so it is a false positive
in each case. After excluding it, `contracts/src` has **0 High** findings (only Low /
Medium / Optimization remain, which are advisory).

## The three flagged sites (all safe)

| Site | Why the `from` is NOT arbitrary |
|---|---|
| `GTokenStaking.lockStakeWithTicket` (`GTOKEN.safeTransferFrom(payer, …)`) | Pre-existing. Called only by `Registry` during role registration; `payer` is the registering account that initiated the staking flow. Access-controlled. |
| `GTokenStaking.topUpStake` (`GTOKEN.safeTransferFrom(payer, …)`) | Pre-existing. Same Registry-driven flow. |
| `SuperPaymaster.settleX402PaymentDirect` (`IERC20(asset).safeTransferFrom(from, …)`) | **C-02 fix.** `from` must have signed an EIP-712 `X402PaymentAuthorization` over exactly `(from, to, asset, amount, maxFee, validBefore, nonce)`, verified by `_verifyX402Auth` (SignatureCheckerLib, EOA + ERC-1271) *before* the transfer. The signature **is** the authorization — the `from` is the consenting payer, not an arbitrary victim. (This is precisely the C-02 vulnerability's fix.) |

## Notes

- Slither remains **advisory** (`continue-on-error: true`) — it never blocks merges; this
  exclusion only removes a known false positive so the check reflects real signal.
- `arbitrary-send-erc20` is excluded **globally** rather than per-line so the config stays
  in one place; if a *new* `transferFrom(param, …)` is added it should be reviewed for an
  authorization guard equivalent to the three above (e.g. a signature or role check).
- Re-run locally: `slither contracts/src --config-file slither.config.json --json out.json`
  then `jq '[.results.detectors[]|select(.impact=="High")]|length' out.json` → expect `0`.
