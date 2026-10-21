#!/usr/bin/env python3
"""Read-only, offline: compare an on-chain runtime (hex file from `cast code`) with a forge artifact's
deployedBytecode after zeroing the artifact's immutable reference ranges in the on-chain code.

Usage: python3 live-compare.py <artifact.json> <onchain.hex> [<fixture.creation.hex>]
Prints JSON: sizes, keccak of on-chain code (= on-chain codehash), keccak of the masked code, keccak of the
artifact runtime, equality, the immutable values found on chain, and (optionally) whether the artifact's
creation bytecode equals the given fixture file.
"""
import json, sys
from Crypto.Hash import keccak


def k(b):
    h = keccak.new(digest_bits=256)
    h.update(b)
    return "0x" + h.hexdigest()


art = json.load(open(sys.argv[1]))
chain = bytes.fromhex(open(sys.argv[2]).read().strip().removeprefix("0x"))
rt = bytes.fromhex(art["deployedBytecode"]["object"].removeprefix("0x"))
refs = art["deployedBytecode"].get("immutableReferences") or {}
masked = bytearray(chain)
imm = {}
for ast_id, ranges in refs.items():
    vals = set()
    for r in ranges:
        s, n = r["start"], r["length"]
        vals.add("0x" + chain[s:s + n].hex())
        masked[s:s + n] = b"\x00" * n
    imm[ast_id] = sorted(vals)
out = {
    "onchainBytes": len(chain), "artifactRuntimeBytes": len(rt),
    "onchainCodehash": k(chain), "maskedKeccak": k(bytes(masked)), "artifactRuntimeKeccak": k(rt),
    "equalAfterMaskingImmutables": bytes(masked) == rt,
    "immutableRefCount": len(refs), "immutableValuesOnChain": imm,
}
if len(sys.argv) > 3:
    fx = bytes.fromhex(open(sys.argv[3]).read().strip().removeprefix("0x"))
    cr = bytes.fromhex(art["bytecode"]["object"].removeprefix("0x"))
    out["fixtureEqualsArtifactCreation"] = fx == cr
    out["artifactCreationKeccak"] = k(cr)
print(json.dumps(out, indent=1))
sys.exit(0 if out["equalAfterMaskingImmutables"] else 1)
