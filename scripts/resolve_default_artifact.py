#!/usr/bin/env python3
"""Resolve the profile.default compiler artifact of a contract by its OWN metadata.

Python mirror of contracts/script/v3/DefaultArtifacts.sol (`_defaultArtifactImpl` /
`_isDefaultBuild`), the resolver every deploy script ships bytecode from. The ABI
bundle (extract_v3_abis.sh) and its gate (check-abi-bundle.mjs) must pick the SAME
file the deployment does; picking "whichever file has the expected name" exported a
stale runs=200 TimelockController.json into abis/ on the rc.8 BLS branch while the
deploy path (TimelockController.default.json, runs=500) was correct.

File names prove nothing: forge writes `X.json` when one compiler profile built X and
`X.default.json` / `X.registry-size.json` when both did, nests the directory when source
names collide, and the unsuffixed file is whatever compiled last (a Prague test build
included). A candidate is accepted only if its metadata carries every [profile.default]
setting: compilation target == the mapped source, solc 0.8.33, optimizer on with runs 500
(Registry: 200, its compilation_restrictions), viaIR, evmVersion cancun, and every
first-party source (contracts/src/**) keccak256-equal to the file on disk. Zero matches,
or two matches with different runtime bytecode, is an error -- never a guess.

Usage: resolve_default_artifact.py [--out DIR] [--json] NAME...
  prints one artifact path per NAME (with --json: {"found": {name: path},
  "failed": {name: reason}}); exits 1 naming every NAME that did not resolve to
  exactly one build.
"""
import json
import os
import sys

DEFAULT_RUNS = 500
REGISTRY_RUNS = 200
SOLC_PREFIX = "0.8.33+"
EVM = "cancun"

OZ = "singleton-paymaster/lib/openzeppelin-contracts-v5.0.2/contracts/"
AA = "singleton-paymaster/lib/account-abstraction-v7/contracts/"
V3 = "contracts/src/paymasters/superpaymaster/v3/"

# Same mapping as DefaultArtifacts._sourceOf, plus GToken (exported to abis/, deployed
# only as GTokenAuthorization by DeployLive).
SOURCES = {
    "Registry": "contracts/src/core/Registry.sol",
    "GTokenStaking": "contracts/src/core/GTokenStaking.sol",
    "PolicyRegistry": "contracts/src/core/PolicyRegistry.sol",
    "LivenessRegistry": "contracts/src/core/LivenessRegistry.sol",
    "GToken": "contracts/src/tokens/GToken.sol",
    "GTokenAuthorization": "contracts/src/tokens/GTokenAuthorization.sol",
    "MySBT": "contracts/src/tokens/MySBT.sol",
    "xPNTsFactory": "contracts/src/tokens/xPNTsFactory.sol",
    "APNTsCapped": "contracts/src/tokens/APNTsCapped.sol",
    "xPNTsToken": "contracts/src/tokens/xPNTsToken.sol",
    "AOAProtocolRegistry": "contracts/src/tokens/v2/AOAProtocolRegistry.sol",
    "GlobalTierSource": "contracts/src/tokens/v2/GlobalTierSource.sol",
    "xPNTsTokenV2Ext": "contracts/src/tokens/v2/xPNTsTokenV2Ext.sol",
    "xPNTsTokenV2": "contracts/src/tokens/v2/xPNTsTokenV2.sol",
    "xPNTsFactoryV2": "contracts/src/tokens/v2/xPNTsFactoryV2.sol",
    "ReputationSystem": "contracts/src/modules/reputation/ReputationSystem.sol",
    "DVTValidator": "contracts/src/modules/monitoring/DVTValidator.sol",
    "BLSAggregator": "contracts/src/modules/monitoring/BLSAggregator.sol",
    "SuperPaymaster": V3 + "SuperPaymaster.sol",
    "SuperPaymasterAdmin": V3 + "SuperPaymasterAdmin.sol",
    "SuperPaymasterLens": V3 + "SuperPaymasterLens.sol",
    "MicroPaymentChannel": V3 + "MicroPaymentChannel.sol",
    "X402Facilitator": V3 + "X402Facilitator.sol",
    "PaymasterFactory": "contracts/src/paymasters/v4/core/PaymasterFactory.sol",
    "Paymaster": "contracts/src/paymasters/v4/Paymaster.sol",
    "ERC1967Proxy": OZ + "proxy/ERC1967/ERC1967Proxy.sol",
    "TimelockController": OZ + "governance/TimelockController.sol",
    "EntryPoint": AA + "core/EntryPoint.sol",
    "SimpleAccountFactory": AA + "samples/SimpleAccountFactory.sol",
    "SimpleAccount": AA + "samples/SimpleAccount.sol",
}

# --- keccak256 (Ethereum, pre-NIST padding); stdlib only so CI needs no extra package ---
_RC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]
_ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61],
        [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]
_M = (1 << 64) - 1


def _f(a):
    for rc in _RC:
        c = [a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4] for x in range(5)]
        d = [c[(x - 1) % 5] ^ (((c[(x + 1) % 5] << 1) | (c[(x + 1) % 5] >> 63)) & _M) for x in range(5)]
        a = [[a[x][y] ^ d[x] for y in range(5)] for x in range(5)]
        b = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                r = _ROT[x][y]
                b[y][(2 * x + 3 * y) % 5] = ((a[x][y] << r) | (a[x][y] >> (64 - r))) & _M if r else a[x][y]
        a = [[b[x][y] ^ ((~b[(x + 1) % 5][y]) & b[(x + 2) % 5][y]) for y in range(5)] for x in range(5)]
        a[0][0] ^= rc
    return a


def keccak256(data):
    try:  # pycryptodome when present (faster); same digest
        from Crypto.Hash import keccak as _k
        return _k.new(digest_bits=256, data=data).hexdigest()
    except ImportError:
        pass
    rate = 136
    msg = bytearray(data) + b"\x01"
    msg += b"\x00" * (-len(msg) % rate)
    msg[-1] |= 0x80
    a = [[0] * 5 for _ in range(5)]
    for off in range(0, len(msg), rate):
        for i in range(rate // 8):
            a[i % 5][i // 5] ^= int.from_bytes(msg[off + 8 * i:off + 8 * i + 8], "little")
        a = _f(a)
    out = b"".join(a[i % 5][i // 5].to_bytes(8, "little") for i in range(4))
    return out.hex()


_source_hash = {}


def _disk_hash(path):
    if path not in _source_hash:
        try:
            with open(path, "rb") as fh:
                _source_hash[path] = keccak256(fh.read())
        except OSError:
            _source_hash[path] = None
    return _source_hash[path]


def is_default_build(artifact, src, runs):
    """Mirror of DefaultArtifacts._isDefaultBuild + _localImportsFresh."""
    md = artifact.get("metadata")
    if isinstance(md, str):
        md = json.loads(md)
    if not isinstance(md, dict):
        return False
    st = md.get("settings", {})
    if src not in st.get("compilationTarget", {}):
        return False
    opt = st.get("optimizer", {})
    if opt.get("runs") != runs or opt.get("enabled") is not True:
        return False
    if st.get("viaIR") is not True or st.get("evmVersion") != EVM:
        return False
    if not str(md.get("compiler", {}).get("version", "")).startswith(SOLC_PREFIX):
        return False
    sources = md.get("sources", {})
    if src not in sources:
        return False
    for key, meta in sources.items():
        if key != src and not key.startswith("contracts/src/"):
            continue
        want = str(meta.get("keccak256", "")).lower().removeprefix("0x")
        if not want or _disk_hash(key) != want:
            return False
    return True


def candidates(out_dir, name, src):
    parts = src.split("/")
    file, d1, d2 = parts[-1], (parts[-2] if len(parts) > 1 else ""), (parts[-3] if len(parts) > 2 else "")
    dirs = [os.path.join(out_dir, file), os.path.join(out_dir, d1, file), os.path.join(out_dir, d2, d1, file)]
    return [os.path.join(d, name + suffix) for d in dirs for suffix in (".json", ".default.json")]


def resolve(name, out_dir="out"):
    """Return (path, None) for exactly one profile.default build, else (None, reason)."""
    src = SOURCES.get(name)
    if src is None:
        return None, f"no source mapping for {name} (add it to SOURCES, as in DefaultArtifacts._sourceOf)"
    runs = REGISTRY_RUNS if name == "Registry" else DEFAULT_RUNS
    pick, pick_code = None, None
    for path in candidates(out_dir, name, src):
        if not os.path.isfile(path):
            continue
        with open(path) as fh:
            artifact = json.load(fh)
        if not is_default_build(artifact, src, runs):
            continue
        code = artifact.get("deployedBytecode", {}).get("object", "")
        if pick is None:
            pick, pick_code = path, code
        elif code != pick_code:
            return None, f"ambiguous profile.default builds of {name}: {pick} vs {path}"
    if pick is None:
        return None, f"no profile.default build of {name} from {src} under {out_dir}/ (run a plain `forge build`)"
    return pick, None


def main(argv):
    out_dir, as_json, names = "out", False, []
    it = iter(argv)
    for a in it:
        if a == "--out":
            out_dir = next(it)
        elif a == "--json":
            as_json = True
        else:
            names.append(a)
    if not names:
        print(__doc__.strip().splitlines()[-4], file=sys.stderr)
        return 2
    found, failed = {}, {}
    for n in names:
        path, why = resolve(n, out_dir)
        if path:
            found[n] = path
        else:
            failed[n] = why
    for why in failed.values():
        print(f"FAIL: {why}", file=sys.stderr)
    if as_json:
        print(json.dumps({"found": found, "failed": failed}))
    else:
        for n in names:
            if n in found:
                print(found[n])
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
