# SuperPaymaster 5.5.0 rc.1 / rc.2 creation-bytecode fixtures — provenance

Used by `contracts/test/v2/SuperPaymasterRc1Rc2MidBundle.t.sol` (spec 03 §6 "rc1 门槛的 fork 演练范围" item 5,
§10.7b C2: rc(n) → rc(n+1) bundle-mid-flight tests, forward and rollback). Each test deploys BOTH fixtures and
asserts `keccak256(fixture) == <creation keccak below>` before using them, so a wrong or edited fixture fails
the test (negative controls N3/N4 in `docs/design/aoa-balance-mode/data/d5b/a2-item5-midflight/`).

The fixtures are **creation** bytecode (forge `bytecode.object`), not runtime: the runtime embeds immutables
(`entryPoint`, `REGISTRY`, `ETH_USD_PRICE_FEED`, UUPS `__self`, `EXTENSION`) that depend on the deployment.
The core's constructor creates its `SuperPaymasterAdmin` extension (`new SuperPaymasterAdmin(...)`), so one
core creation fixture deploys the matching extension too; the test asserts both runtime sizes.

| Fixture | Tag → commit | Creation B | Creation keccak256 | Core runtime B / keccak (artifact, immutables zeroed) | Extension (SuperPaymasterAdmin) runtime B / keccak | File sha256 |
|---|---|---|---|---|---|---|
| `superpaymaster-5.5.0-rc.1-7ae5b340-impl.creation.hex` | `v5.5.0-rc.1` (tag object `a37c67b1…`) → `7ae5b3400308082928da4c180b8e3108ed00b288` | 34,372 | `0x7afad5dab61cff8ea1ac99d45527fff386fab4156e9f62d8fd579745262483cc` | 13,571 / `0xc3e96cf85978d0fabc2d3440858cffb495be1d4354e5a8d69f9e70c6c890c3e2` | 19,208 / `0x292491041269b4ee3e6df9e69af9f8c52dcda031070ed3114963ea107180b669` | see `EVIDENCE.sha256` in the evidence dir |
| `superpaymaster-5.5.0-rc.2-1ac0e1c5-impl.creation.hex` | `v5.5.0-rc.2` (tag object `250fb800…`) → `1ac0e1c595dc84e684b540ca6a936168e922194f` | 34,551 | `0x4edff578ddfb3875aa057f690fb68b85df24332aa0023a115aadad07107a0e4e` | 13,744 / `0xc9fe37f57b2bf4de56d8c87270660ce4a098692280ed642855c0a603d6b9d222` | 19,214 / `0xefc71c67b20fd21111e50808ee8d60bec6f1f47ec30aaa1729dcf293e7e178d2` | see `EVIDENCE.sha256` in the evidence dir |

**rc.2 equals the release attestation**: all four rc.2 values (core runtime/creation keccak, extension
runtime/creation keccak) are byte-identical to `docs/release/v5.5.0-rc.2-attestation.json`
(`SuperPaymaster.runtimeKeccak/creationKeccak`, `SuperPaymasterAdmin.runtimeKeccak/creationKeccak`).
**rc.1 has no attestation** (the rc.2 attestation declares `v5.5.0-rc.1` VOID: `2d66867f` and PR #442 changed
bytecode after it; `git diff 7ae5b340 1ac0e1c5 -- contracts/src` touches SuperPaymaster.sol,
SuperPaymasterAdmin.sol, SuperPaymasterStorage.sol among 10 files). rc.1 was never deployed to any public
network, so the spec's "check against the on-chain runtime codehash after A3b" cannot apply to it.

## Build

Toolchain: forge 1.7.1 (`4072e48705af9d93e3c0f6e29e93b5e9a40caed8`), solc 0.8.33+commit.64118f21,
`[profile.default]` of each tag's own `foundry.toml` (optimizer 500 runs, via_ir, evm cancun,
bytecode_hash none; Registry 200 runs — not relevant to SP).

Source tree: `git archive <tag>` into an empty directory (no working-tree files), plus the two submodules at
the gitlinks recorded in the tag (`contracts/lib/chainlink-brownie-contracts` @ `6e324d8a…`,
`contracts/lib/solady` @ `90db92ce…`; identical gitlinks at both tags). Then:

```
rm -rf cache out && forge build          # full default-profile build, as in the attestation
python3 -c "import json;print(json.load(open('out/SuperPaymaster.sol/SuperPaymaster.json'))['bytecode']['object'])" > fixture.hex
```

rc.1 was additionally rebuilt in a second independent extract with a sparse
`forge build contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol`; result recorded in
`docs/design/aoa-balance-mode/data/d5b/a2-item5-midflight/build-hashes.json`.

## The older C2 fixtures are NOT rc.1 (reproduced here)

| Existing fixture | Used by | Reproduced from | Creation keccak | Runtime B |
|---|---|---|---|---|
| `superpaymaster-5.5.0-impl.creation.hex` | `SuperPaymasterV55UpgradeRace.t.sol` | `1cb21fe8` (SuperPaymaster.sol keccak `0xab8309da…fe4`, the value the test header cites) | `0xfb170a13…db12f3` | 22,915 |
| `superpaymaster-5.5.0-c30854f9-impl.creation.hex` | `SuperPaymasterD5bUpgradeRace.t.sol`, `SuperPaymasterFeeSnapshot.t.sol` | `c30854f9` (matches `d5b-previous-release.provenance.json`) | `0xd2a9e92e…9e05e5b` | 23,568 |

Both pre-date the D5b core/extension split (single contract, 4 immutables) and differ from rc.1
(`0x7afad5da…`, 13,571 B core + 19,208 B extension).
