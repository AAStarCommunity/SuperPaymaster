#!/usr/bin/env python3
"""Read-only dual-endpoint listing of the legacy OP-mainnet paymaster exposure (author decision W-2).

Usage:
  RPC_A=<op mainnet rpc> RPC_B=<second op mainnet rpc, other operator> \
    python3 script/evidence/w2-op-mainnet-exposure.py [<block>] > out.json

W-2 (author, 2026-10-27) leaves the legacy V3 SuperPaymaster and the factory-deployed V4 paymasters on
OP mainnet untouched and states them as outside the research deployment, listing their existing
deposits. This script produces that listing at one pinned block: for the legacy SP and every paymaster
the legacy PaymasterFactory reports, the EntryPoint v0.7 deposit info, owner, whether the owner has code,
and version(). Both endpoints must agree on chain id, block hash and every value.

Scope limit: V4 instances are enumerated from the legacy factory only; a paymaster deployed outside it
is not found here. Endpoint agreement shows two operators returned the same answer, not that their
backends are independent.
Methods used: eth_chainId, eth_blockNumber, eth_getBlockByNumber, eth_call, eth_getCode. Nothing is signed or sent.
Exits 1 on any endpoint disagreement or malformed answer.
"""
import json, os, sys, urllib.request

CHAIN_ID = 10
ENTRYPOINT = "0x0000000071727de22e5e9d8baf0edac6f37da032"
LEGACY_SP = "0xa2c9a6e95f19f5d2a364cbcbb5f0b32b1b4d140e"        # deployments/config.optimism.json superPaymaster
LEGACY_FACTORY = "0x58a7f6e44a57028a255794119f8b37124c9a7eb8"   # deployments/config.optimism.json paymasterFactory
SEL = {"getDepositInfo": "0x5287ce12", "owner": "0x8da5cb5b", "version": "0x54fd4d50",
       "getPaymasterCount": "0x14b1c401", "getPaymasterList": "0xd1255313"}


class RpcFailure(Exception):
    pass


def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    try:
        req = urllib.request.Request(url, body, {"Content-Type": "application/json", "User-Agent": "w2-exposure"})
        with urllib.request.urlopen(req, timeout=60) as r:
            d = json.load(r)
    except Exception as e:  # never echo the exception text: it can carry the URL
        raise RpcFailure(f"{method}: transport error ({type(e).__name__})") from None
    if not isinstance(d, dict) or d.get("id") != 1 or "error" in d or d.get("result") is None:
        raise RpcFailure(f"{method}: rpc error or malformed envelope")
    return d["result"]


def word(v):
    return hex(v)[2:].rjust(64, "0") if isinstance(v, int) else v.lower().removeprefix("0x").rjust(64, "0")


def words(hexdata, n_min):
    h = hexstr(hexdata)[2:]
    if len(h) % 64 or len(h) // 64 < n_min:
        raise RpcFailure("eth_call: unexpected return length")
    return [h[i:i + 64] for i in range(0, len(h), 64)]


def hexstr(v, nbytes=None):
    """A 0x-prefixed even-length hex string (exactly nbytes long when given), lowercased."""
    if not isinstance(v, str) or not v.startswith("0x") or len(v) % 2 \
            or any(c not in "0123456789abcdefABCDEF" for c in v[2:]) \
            or (nbytes is not None and len(v) != 2 + 2 * nbytes):
        raise RpcFailure("malformed hex result")
    return v.lower()


def quantity(v):
    """A JSON-RPC quantity: 0x followed by hex digits, no leading zero (except 0x0 itself)."""
    if not isinstance(v, str) or not v.startswith("0x") or len(v) < 3 \
            or any(c not in "0123456789abcdefABCDEF" for c in v[2:]) or (v[2] == "0" and v != "0x0"):
        raise RpcFailure("malformed quantity result")
    return int(v, 16)


def uint(w, bits=256):
    v = int(w, 16)
    if v >> bits:
        raise RpcFailure(f"eth_call: value exceeds uint{bits}")
    return v


def boolean(w):
    v = int(w, 16)
    if v > 1:
        raise RpcFailure("eth_call: dirty bool word")
    return v == 1


def dynamic(w, n_items):
    """Word index of a single dynamic return's length word; it must be the canonical head offset 32."""
    if int(w[0], 16) != 32:
        raise RpcFailure("eth_call: non-canonical dynamic offset")
    n = int(w[1], 16)
    if len(w) - 2 < n_items(n):
        raise RpcFailure("eth_call: dynamic data shorter than its length")
    return n


def addr(w):
    if int(w[:24], 16):
        raise RpcFailure("eth_call: dirty address word")
    return "0x" + w[24:]


def read(url, blk):
    tag = hex(blk)
    call = lambda to, data: rpc(url, "eth_call", [{"to": to, "data": data}, tag])

    def string(to):
        w = words(call(to, SEL["version"]), 2)
        n = dynamic(w, lambda n: (n + 31) // 32)
        try:
            return bytes.fromhex("".join(w[2:])[:2 * n]).decode()
        except UnicodeDecodeError:
            raise RpcFailure("eth_call: version is not utf-8") from None

    def paymaster(a):
        d = words(call(ENTRYPOINT, SEL["getDepositInfo"] + word(a)), 5)
        owner = addr(words(call(a, SEL["owner"]), 1)[0])
        return {"address": a,
                "depositInfo": {"depositWei": str(uint(d[0])), "staked": boolean(d[1]),
                                "stakeWei": str(uint(d[2], 112)), "unstakeDelaySec": uint(d[3], 32),
                                "withdrawTime": uint(d[4], 48)},
                "owner": owner, "ownerHasCode": hexstr(rpc(url, "eth_getCode", [owner, tag])) != "0x",
                "version": string(a)}

    count = uint(words(call(LEGACY_FACTORY, SEL["getPaymasterCount"]), 1)[0])
    lw = words(call(LEGACY_FACTORY, SEL["getPaymasterList"] + word(0) + word(count)), 2)
    n = dynamic(lw, lambda n: n)
    if n != count:
        raise RpcFailure("getPaymasterList: length does not match getPaymasterCount")
    v4 = [addr(x) for x in lw[2:2 + n]]
    return {"chainId": quantity(rpc(url, "eth_chainId", [])),
            "blockHash": hexstr(rpc(url, "eth_getBlockByNumber", [tag, False])["hash"], 32),
            "legacySuperPaymaster": paymaster(LEGACY_SP),
            "factory": {"address": LEGACY_FACTORY, "paymasterCount": count},
            "v4Paymasters": [paymaster(a) for a in v4]}


def main():
    a, b = os.environ.get("RPC_A"), os.environ.get("RPC_B")
    if not a or not b or a == b:
        sys.exit("RPC_A and RPC_B must both be set and differ")
    try:
        blk = int(sys.argv[1]) if len(sys.argv) > 1 else quantity(rpc(a, "eth_blockNumber", [])) - 64
        ra, rb = read(a, blk), read(b, blk)
    except RpcFailure as e:
        sys.exit(f"FAIL {e}")
    except (ValueError, TypeError, KeyError, IndexError, AttributeError) as e:  # never echo: a result can carry the URL
        sys.exit(f"FAIL malformed rpc answer ({type(e).__name__})")
    checks = {"chainIdIsOpMainnet": ra["chainId"] == CHAIN_ID, "endpointsAgree": ra == rb}
    total = [ra["legacySuperPaymaster"]] + ra["v4Paymasters"]
    out = {"tool": "w2-op-mainnet-exposure", "block": blk, "checks": checks, "observation": ra,
           "totals": {"paymasters": len(total),
                      "depositWei": str(sum(int(p["depositInfo"]["depositWei"]) for p in total)),
                      "stakeWei": str(sum(int(p["depositInfo"]["stakeWei"]) for p in total))},
           "diffB": None if ra == rb else rb}
    print(json.dumps(out, indent=1))
    sys.exit(0 if all(checks.values()) else 1)


if __name__ == "__main__":
    main()
