# Slither triage — `arbitrary-send-erc20` (per-line, not globally excluded)

The Stage 3 Slither gate runs with `fail-on: high`. The only High-severity detector that
fires on `contracts/src` is **`arbitrary-send-erc20`** ("uses arbitrary `from` in
`transferFrom`"). It is a **false positive at every site** — Slither cannot reason about
the access-control / signature guard that authorizes the `from`.

The detector is **NOT excluded globally** (that would hide any *future* unguarded
`transferFrom(param, …)`). Instead each known-safe site carries an inline
`// slither-disable-next-line arbitrary-send-erc20` with its justification, so the gate
still catches any new, un-triaged occurrence. After triage, `contracts/src` has **0 High**.

## The three flagged sites (all safe, all annotated inline)

| Site | Why the `from` is NOT arbitrary |
|---|---|
| `GTokenStaking.lockStakeWithTicket` (`safeTransferFrom(payer, …)`, 2 calls) | `onlyRegistry` — only the trusted Registry can call, and it supplies the registering account as `payer` (which must hold an allowance). |
| `GTokenStaking.topUpStake` (`safeTransferFrom(payer, …)`) | Same `onlyRegistry`, Registry-supplied `payer`. |
| `SuperPaymaster.settleX402PaymentDirect` (`safeTransferFrom(from, …)`) | **C-02 fix.** `from` must have signed an EIP-712 `X402PaymentAuthorization` over exactly `(from, to, asset, amount, maxFee, validBefore, nonce)`, verified by `_verifyX402Auth` (SignatureCheckerLib, EOA + ERC-1271) *immediately above* the transfer. The signature **is** the authorization. |

## Notes

- Slither is also `continue-on-error: true` (advisory) — it never hard-blocks merges; the
  inline triage just makes the check reflect real signal instead of known false positives.
- A *new* `transferFrom(param, …)` will trip the gate until it is reviewed and (if proven
  safe by an equivalent guard) annotated — the detector stays fully active.
- Re-run locally: `slither contracts/src --config-file slither.config.json --json out.json`
  then `jq '[.results.detectors[]|select(.impact=="High")]|length' out.json` → expect `0`.
