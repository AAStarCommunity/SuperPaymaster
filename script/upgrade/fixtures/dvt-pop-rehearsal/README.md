# TEST DATA ONLY — not release input

`rehearse-pop.json` is an output of DVT's `--export-pop` (`deploy/reregister-guardians.mjs`), supplied by DVT on 2026-11-02 and copied byte for byte.
sha256: `305f1513034d0afa953ed34f01b8db4116540966da1e87c321715d94631162a7`.

It comes from a throwaway local fork rehearsal against BLSAggregator 4.12.0 bytecode, deployed at `0xb2f013e6…b38a`. The constructor arguments (Registry, SP, DVTValidator) were read from the old 4.11.0 aggregator, so its `aggregator` and `domainSeparator` are not the manifest's A7 values.

It is used as a format fixture for `pop_adapter.py`:
- The positive test supplies matching expectations.
- A negative test proves that, with the real plan's A7 and domain expectations, this file is rejected and cannot enter a formal plan.

The file contains no private keys. It holds only guardian addresses, BLS public keys and PoP signatures, all of which are public on-chain data.
