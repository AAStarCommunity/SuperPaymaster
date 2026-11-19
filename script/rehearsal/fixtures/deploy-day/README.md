# Deploy-day real evidence fixtures

Source run: head `e6f5c7a8`, fork block **12163279**.

The JSON transaction records preserve every source field and value. Keys in
records.verbatim.json are original zero-based indices: 45 (SP price), 96 (H),
0 (Registry implementation), 17 (another SP proxy CALL). plan.shape.json preserves
the full source object with only transaction.input removed for size and one top-level note.
Price tests overlay the retained verbatim inputs; the stripped shape alone cannot identify a selector.

Simulation files are JSON containers of **verbatim diagnostic text**. The supplied
sources do not contain full JSON-RPC success response bodies. Alchemy reports 97
successful calls and gas values for eight targets; tests parse those observations,
without presenting reconstructed responses as captured wire evidence.

## Source SHA256

- `driver-run1.dry-run.run-latest.json`: `3004b5808784617ddbc9a168e4b43ec394726089e9e3b93f5d002389480c0f42`
- `simulate-fullseq-alchemy.txt`: `b554ed54c9eada1afab7ff7861f51e917526ec13ac819b68e39ef823fbf4efd6`
- `simulate-fullseq-fork.txt`: `4e56ceee14dc6a349292236d22c23d860b3aa5c5c0915e483b6f0781b9dc59d2`
- `simulate-probe.txt`: `2ab8c8b95bbe596f6656e7380feea5561fc1d4a50c98fa55614c382c60b518f6`
