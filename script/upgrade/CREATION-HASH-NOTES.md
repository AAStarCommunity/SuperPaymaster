# Creation hashes and compiler evidence

## Hash policy

SP contracts require full creation-bytecode keccak equality. Nothing is stripped or interpreted as metadata. `strippedCreationKeccak` is retained for schema compatibility and equals `fullCreationKeccak` for every SP contract. The schema documents this meaning; evidence validation enforces equality and build comparison independently requires the full hash. An SP metadata difference is a reproducibility failure.

Only `OverIssueFraudProofVerifier` permits metadata normalization. `VERIFIER_METADATA_LAYOUT` pins 3300 total bytes and exactly one segment at offset 3247, length 53, including the two-byte length suffix. The pinned compiler artifact has a 2981-byte runtime, occupying the final creation data object starting at offset 319. Its terminal length is 51. Segment location uses this boundary and trailing length, never a whole-byte pattern search. `fixtures/dvt-creation.json` preserves the local compiler artifact's creation/runtime bytes and layout; its full creation hash matches the existing `VERIFIER_CREATION` pin:

`0x736520628b9e5ed4163f440e4e7b5d064b4e4cb4571c29d926941964e038e3ab`

Both builds must satisfy the same layout before comparison. The segment must fully decode as a CBOR map with exactly `ipfs` and `solc`, a SHA-256 multihash, and solc 0.8.33. The stripped digest covers every byte outside the segment; any difference outside it fails. The two-build producer additionally compares those remaining bytes directly. The reviewed verifier artifact retains its full-hash provenance pin. Rebuilt verifier code must match the pinned stripped hash `0x697b97795dfc4547e615c048a5583d31f4c7f9a969b53d85d5ecb9e42e218d54`; artifact-to-rebuild comparison checks every nonmetadata byte, allowing only validated metadata differences. Generated manifest packets carry `creationMetadataLayouts`, checked against the derived packet by plan validation. Reproducible-build audit output records the same layout.

The fraud drill's mock-token check is a separate runtime check: its full-runtime pin and existing terminal runtime CBOR validation remain enforced. It does not use creation normalization.

## Requirement 4: offline compiler proof

Commands executed in this worktree, without git or network, for all five contracts below:

```sh
$HOME/.foundry/bin/forge inspect <Contract> assembly --offline
$HOME/.foundry/bin/forge inspect <Contract> legacyAssembly --offline
$HOME/.foundry/bin/forge inspect <Contract> bytecode --offline
```

Forge reports 1.7.1, commit `4072e48705af9d93e3c0f6e29e93b5e9a40caed8`. All five inspected creation bytecodes equal the supplied rc.6 fixtures byte for byte. The fixture index records source commit `adce0ec88f1f9a5fb38e467599f72323fcd25ccd`; no git command was used to infer or verify source provenance.

The premise needs one correction: three contracts have exactly 32 bytes after the final CBOR, but SuperPaymasterAdmin has 96 and SuperPaymaster has 128. All five end with the 32-byte Initializable constant. Offsets below are zero-based; CBOR includes its two-byte length suffix.

| Contract | Creation bytes | Final CBOR offset | Bytes after final CBOR | Last constant offset |
| --- | ---: | ---: | ---: | ---: |
| SuperPaymaster | 34551 | 34411 | 128 | 34519 |
| SuperPaymasterAdmin | 20013 | 19905 | 96 | 19981 |
| xPNTsTokenV2 | 22172 | 22128 | 32 | 22140 |
| xPNTsTokenV2Ext | 24143 | 24099 | 32 | 24111 |
| Registry | 23670 | 23626 | 32 | 23638 |

The compiler's `legacyAssembly` output for all five has this root `.data` entry, a string-valued literal data block separate from object-valued code subobjects:

```json
{
  ".data": {
    "E28A5566B8A884201AB44E2D991177CE8B88325E02E52CBC3DA6E67B3ECF29C6": "f0c57e16840df040f15088dc2f81fe391c3923bec73e23a9662efc9c229c6a00"
  }
}
```

SuperPaymaster `.data/0/.auxdata` is `a164736f6c6343000821000a`; `.data/0/.data` also contains the constant. Creation assembly references the named block at stdout lines 136 and 307:

```text
codecopy(0x00, data_e28a5566b8a884201ab44e2d991177ce8b88325e02e52cbc3da6e67b3ecf29c6, 0x20)
mload(0x00)
swap1
0x00
mstore
```

The first sequence proceeds to `sload` and the source-mapped `Initializable.sol` check `if ($._initializing)`; the second proceeds to `sstore` and `Initialized(type(uint64).max)`. Assembly line 379 declares the named data block. OpenZeppelin source `singleton-paymaster/lib/openzeppelin-contracts-v5.0.2/contracts/proxy/utils/Initializable.sol:77` declares `INITIALIZABLE_STORAGE`; line 225 assigns `$.slot := INITIALIZABLE_STORAGE`. The compiler data boundaries, references and source mappings establish that these bytes support initialization storage access, rather than being metadata padding.

SuperPaymasterAdmin's root `.data` has two additional literal blocks:

- `3E760FB1C22BC3A34D2708A3A7CF8019591C72E54CB26B43799BF7BD92CE42CF`: `db5a3168abaa6147a9f3a4cb66016161119d4d50b6393344d27120286f742a00` (Ownable2Step storage).
- `9C064737B570A74C2BAC5D21056D93AC53115214216CD14D4A0FC9B60BE81231`: `8be0079c531659141344cd1fd0a4f28419497f9722a3daafe3b4186f6b6457e0` (OwnershipTransferred event).

SuperPaymaster embeds that object's code/data at `.data/1`; its `.data/1/.data` contains those two blocks and the Initializable block. Its own root Initializable block follows, explaining the four trailing words after the last embedded CBOR. The other three contracts have only the final root Initializable word after CBOR.

## Tests and guard removal

`RealCreationTests` uses all ten rc.6 manifest fixtures, including AOAProtocolRegistry, and the real pinned verifier. It rejects changes outside metadata, forged CBOR patterns in code, wrong segment count/position, appended data, malformed lengths and unexpected keys. It accepts an IPFS-only verifier change and records it as metadata-only. `RealReproducibleTests` drives the evidence producer with real bytes and confirms an SP change stops it.

Negative tests were rerun with individual `a.need` guards disabled in memory and then restored: full-SP equality, verifier executable equality, pinned layout, and total length each turn red when removed and green when restored. Removing the expected-key guard also turns the test red (an unexpected KeyError instead of the required controlled Gate). No repository source mutation was used.

Assembly stdout SHA-256 (for reproducing the compiler evidence):

- SuperPaymaster: `ab7dcbeb4b9e3173cfc5ca88be7a0a311bd2bb0f2da7b36910a61e1459d40833`
- SuperPaymasterAdmin: `f4b813ace5695d6179257c52ce0619bd10f6640ef7e52e06b96cf073a62b73ff`
- xPNTsTokenV2: `5485bf727b7e2fe05046ae59554ae1ccd23a3dbd18dd996bd2058c16a1aea52b`
- xPNTsTokenV2Ext: `70b3938bdb483d9db9eed33c2217d770b48c08dfce476c3b91f27c5b8391a1b1`
- Registry: `16c2efc097ad424de19c993d2385ec3090bad014b4c1478e9b44a01786c73c5b`

Final verification (all commands used `A3A_ENGINE_DIR=$HOME/.foundry/bin` and `python3 -B`):

- `script/upgrade/test_manifest_exec.py`: 150 passed.
- `script/upgrade/test_release_evidence.py`: 35 passed.
- `script/a3a/test_a3a_exec.py`: 100 passed.
- Five guard-removal controls: red with guard removed, green after restoration.

No git commands or network access were used. Compiler inspection was offline in this worktree; tests used mocked build/archive operations and real local bytecode fixtures.
