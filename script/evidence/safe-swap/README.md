# Test Safe owner swap

`safe_swap_owner.py` builds the unsigned swap packet and rehearses approval and
execution on the pinned Amsterdam Anvil engine. It reads the live chain but
broadcasts only to its local fork. `SAFE_SWAP_ANVIL` can override the engine path;
the default remains `~/Dev/aastar/tools/foundry-rams/nightly-4e8874b/anvil`.

`send_swap.py` is the gated sender: it binds the reviewed packet SHA-256, checks
both endpoints and sender/Safe state, verifies decoded signed transactions, and
requires successful receipts and the expected final owner readback. It uses the
existing Foundry keystores. Do not rerun it to validate historical evidence.

The manifest's separate `safeGovernanceGaps` validator replays the public packet
and chain-read fixtures under `script/upgrade/fixtures/safe-governance/` offline.
The earlier void packet's approval reverted; its execution was never sent.
