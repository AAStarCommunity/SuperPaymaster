# A4 C4 log-scanner positive control (local anvil)

**Local anvil only. Endpoint B is `script/a6-collector/rpc-proxy.mjs` in front of the same anvil, so this tests
the instrument (selectors, decoding, chunking, verdicts), not provider independence or archive completeness.**
Scanner: `script/evidence/a4-credit-logscan.py` at HEAD `bdff68a7`, dirty 0 (`token.txt`). Driver:
`scan-run.sh.txt` (anvil dev key redacted). Chain built like `../a6-gauge-credit/`: deploy-core, prepare-test,
then the operator token `0xdc17…20f4` (deployed in block 54, found by the scanner's code bisection).

| step | expected | result |
|---|---|---|
| before any policy change, scan [1, 99] | C4 pass, C7 pass, complete | `pre.json`: complete, C4 pass, C7 pass, 0 policy events; exit 0 |
| `queueCreditPolicy(2)`, +48 h, `executeCreditPolicy()` (`queue.log`, `execute.log`), scan [1, 172] | C4 fail with policy 2 found | `post.json`: complete, C4 **fail**, event `CreditPolicyExecuted` policy 2 epoch 1, block 166; control script exit 0 (`control.out`) |

The pair is the control: the same scanner on the same token says pass before and fail after, and the only chain
change between them is the policy execution.

## Not verified here

- **C7 on a chain**: no credit reservations were made on this chain, so C7 = pass is vacuous here. C7's replay logic
  is covered only by the offline tests (`script/evidence/test_a4_credit_logscan.py`, reserve/settle/re-reserve,
  open reservation, orphan close, duplicate open).
- Two independent archive providers, finality on a public chain, and identical omissions by both providers.
  **The scanner cannot establish provider independence**: it only refuses two identical URL strings, so two URLs
  served by the same backend (as here, through the proxy) can still yield `pass`. Independence of the two
  endpoints is a prerequisite the operator must establish and record separately; without it a `pass` says only
  that one backend's view is self-consistent.
- Criteria other than C4/C7 (C1, C6, C8, C9 are separate work).
