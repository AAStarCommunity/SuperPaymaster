#!/usr/bin/env python3
"""Read-only C4/C7 evidence, conditional on C1 and independent archive operators.

URLs are read only from files; output identifies hosts only. Agreement cannot prove
provider independence or detect identical omissions. Run a known-event positive control
before using live evidence. No C1/C2/C3/C5/C6/C8/C9 claim is made here.
Only eth_chainId, eth_getBlockByNumber, eth_getCode and eth_getLogs are used.
Exit 0: both pass; 1: fail or unverified; command/output-file errors are nonzero.
"""
import argparse, hashlib, json, sys, urllib.parse, urllib.request
from pathlib import Path

# Baseline: contracts/src/tokens/v2/xPNTsV2Base.sol. Computed with cast keccak
# and independently PyCryptodome Keccak-256 (NOT hashlib.sha3_256).
SIGNATURES = {
    "CreditPolicyExecuted": "CreditPolicyExecuted(uint8,uint32)",
    "CreditReserved": "CreditReserved(address,bytes32,address,uint256)",
    "CreditSettled": "CreditSettled(address,bytes32,uint256)",
    "CreditReleased": "CreditReleased(address,bytes32,uint256)",
}
TOPICS = dict(zip(SIGNATURES, (
    "0x4a53aec9f255b2d5bcb9ce63ec2e9263cd6094537eec19973e8708c1b1e35f02",
    "0xe7f1ceee255e2908b896f5fa254cb3bac9e538bdac389f75de2fc3446d2a7b69",
    "0xe24e7f4be2a6dcf7000d9d67421687e27dcf1f62554dbdeec78adb103aae6323",
    "0xdad6678c895f98939e7284e161055630849182add6c69672f905c25a73369269",
)))
UNVERIFIED = "未能验证"


class RpcFailure(Exception):
    pass


def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    try:
        req = urllib.request.Request(url, body, {"Content-Type": "application/json", "User-Agent": "a4-credit-logscan"})
        with urllib.request.urlopen(req, timeout=60) as r:
            d = json.load(r)
    except Exception:  # Exceptions and provider messages may contain credentials.
        raise RpcFailure(f"{method}: transport or JSON error") from None
    if not isinstance(d, dict) or d.get("jsonrpc") != "2.0" or type(d.get("id")) is not int \
            or d["id"] != 1 or "error" in d or d.get("result") is None:
        raise RpcFailure(f"{method}: rpc error or malformed envelope")
    return d["result"]


def hexstr(v, nbytes=None):
    if not isinstance(v, str) or not v.startswith("0x") or len(v) % 2 \
            or any(c not in "0123456789abcdefABCDEF" for c in v[2:]) \
            or (nbytes is not None and len(v) != 2 + 2 * nbytes):
        raise RpcFailure("malformed hex result")
    return v.lower()


def quantity(v):
    if not isinstance(v, str) or not v.startswith("0x") or len(v) < 3 \
            or any(c not in "0123456789abcdefABCDEF" for c in v[2:]) or (v[2] == "0" and v != "0x0"):
        raise RpcFailure("malformed quantity result")
    return int(v, 16)


def block(url, tag):
    d = rpc(url, "eth_getBlockByNumber", [tag, False])
    if not isinstance(d, dict):
        raise RpcFailure("malformed block result")
    n, h = quantity(d.get("number")), hexstr(d.get("hash"), 32)
    if tag != "finalized" and n != quantity(tag):
        raise RpcFailure("block number mismatch")
    return {"number": n, "hash": h}


def order(log):
    return log["blockNumber"], log["transactionIndex"], log["logIndex"], log["address"]


def canonical(logs):
    return json.dumps(logs, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()


def decode(log):
    topics = log["topics"]
    names = {v: k for k, v in TOPICS.items()}
    if not topics or topics[0] not in names:
        raise RpcFailure("unexpected event topic")
    name = names[topics[0]]
    nt, nb = (1, 64) if name == "CreditPolicyExecuted" else (4 if name == "CreditReserved" else 3, 32)
    if len(topics) != nt:
        raise RpcFailure("unexpected event topic count")
    data = hexstr(log["data"], nb)[2:]
    e = {"event": name, "address": log["address"], "blockNumber": log["blockNumber"],
         "transactionHash": log["transactionHash"], "logIndex": log["logIndex"]}
    if name == "CreditPolicyExecuted":
        policy, epoch = int(data[:64], 16), int(data[64:], 16)
        if policy >> 8 or epoch >> 32:
            raise RpcFailure("event uint overflow")
        e.update(policy=policy, epoch=epoch)
    else:
        if int(topics[1][2:26], 16) or (nt == 4 and int(topics[3][2:26], 16)):
            raise RpcFailure("dirty event address word")
        e.update(user="0x" + topics[1][-40:], opHash=topics[2])
        e["debtAdded" if name == "CreditSettled" else "amount"] = str(int(data, 16))
        if nt == 4:
            e["locker"] = "0x" + topics[3][-40:]
    return e


def logset(raw, token, lo, hi):
    if not isinstance(raw, list):
        raise RpcFailure("malformed log array")
    result, seen = [], set()
    for d in raw:
        if not isinstance(d, dict) or d.get("removed") is not False or not isinstance(d.get("topics"), list):
            raise RpcFailure("malformed or removed log")
        v = {k: quantity(d.get(k)) for k in ("blockNumber", "transactionIndex", "logIndex")}
        v.update({k: hexstr(d.get(k), n) for k, n in (("address", 20), ("blockHash", 32), ("transactionHash", 32))})
        v.update(topics=[hexstr(t, 32) for t in d["topics"]], data=hexstr(d.get("data")), removed=False)
        if v["address"] != token or not lo <= v["blockNumber"] <= hi:
            raise RpcFailure("log outside requested filter")
        key = v["blockNumber"], v["logIndex"]
        if key in seen:
            raise RpcFailure("duplicate log position")
        seen.add(key)
        decode(v)
        result.append(v)
    return sorted(result, key=order)


def replay(logs):
    policies, opened, anomalies = [], {}, []
    counts = {name: 0 for name in SIGNATURES if name != "CreditPolicyExecuted"}
    for log in sorted(logs, key=order):
        e = decode(log)
        name = e["event"]
        if name == "CreditPolicyExecuted":
            policies.append(e)
            continue
        counts[name] += 1
        key = (e["address"], e["user"], e["opHash"])
        if name == "CreditReserved":
            if key in opened:
                anomalies.append({"reason": "reservation already open", "event": e})
            else:
                opened[key] = e
        elif key not in opened:
            anomalies.append({"reason": "close without open reservation", "event": e})
        else:
            del opened[key]
    return {"C4": {"verdict": "fail" if any(e["policy"] != 0 for e in policies) else "pass", "events": policies},
            "C7": {"verdict": "fail" if opened or anomalies else "pass", "counts": counts,
                   "openCount": len(opened), "anomalyCount": len(anomalies),
                   "openReservations": list(opened.values()), "anomalies": anomalies}}


def endpoint_file(path):
    try:
        url = Path(path).read_text().strip()
        p = urllib.parse.urlsplit(url)
        if p.scheme not in ("http", "https") or not p.hostname or p.fragment:
            raise ValueError()
        return url, p.hostname
    except Exception:
        raise RpcFailure("invalid or unreadable RPC URL file") from None


def scan(urls, tokens, start, end, chunk_size=2000, hosts=None):
    out = {"tool": "a4-credit-logscan", "fromBlock": start, "toBlock": end,
           "endpoints": dict(zip(("A", "B"), hosts or ("redacted", "redacted"))),
           "chainId": None, "blockHashes": {}, "deployBlocks": {}, "archiveProbes": [],
           "chunks": [], "logs": [], "canonicalLogsSha256": None, "complete": False,
           "scope": "C4/C7 only; conditional on C1, independent archive providers and known-event positive control. "
                    "Identical omissions and provider independence cannot be established by this scan."}
    try:
        if len(urls) != 2 or urls[0] == urls[1]:
            raise RpcFailure("two distinct endpoints required")
        if start < 1 or end < start or chunk_size < 1:
            raise RpcFailure("invalid range; from-block must be >= 1 (genesis deployments unsupported)")
        tokens = sorted(set(hexstr(t, 20) for t in tokens))
        if not tokens:
            raise RpcFailure("at least one token required")
        ids = [quantity(rpc(u, "eth_chainId", [])) for u in urls]
        if ids[0] != ids[1]:
            raise RpcFailure("chain id disagreement")
        out["chainId"] = ids[0]
        finals = [block(u, "finalized") for u in urls]
        out["finalized"] = dict(zip(("A", "B"), finals))
        if any(end > f["number"] for f in finals):
            raise RpcFailure("to-block exceeds finalized")
        # Each endpoint's numbered view must contain its own finalized checkpoint; otherwise a stale or
        # inconsistent view could certify blocks that are not on the finalized chain.
        for u, f in zip(urls, finals):
            if block(u, hex(f["number"]))["hash"] != f["hash"]:
                raise RpcFailure("finalized block differs from the numbered block at that height")

        def agreed_block(n):
            pair = [block(u, hex(n)) for u in urls]
            if pair[0] != pair[1]:
                raise RpcFailure("block hash disagreement")
            return pair[0]["hash"]

        for label, n in (("from", start), ("to", end)):
            pair = [block(u, hex(n)) for u in urls]
            out["blockHashes"][label] = dict(zip(("A", "B"), (p["hash"] for p in pair)))
            if pair[0] != pair[1]:
                raise RpcFailure("pinned block disagreement")

        def code(token, n):
            pair = [hexstr(rpc(u, "eth_getCode", [token, hex(n)])) for u in urls]
            if pair[0] != pair[1]:
                raise RpcFailure("historical code disagreement")
            return pair[0] != "0x"

        for token in tokens:
            at_start, before = code(token, start), code(token, start - 1)
            out["archiveProbes"].append({"token": token, "blocks": [start - 1, start], "bothSucceeded": True})
            if before:
                raise RpcFailure("from-block is after deployment; history incomplete")
            if at_start:
                deploy = start
            else:
                if not code(token, end):
                    raise RpcFailure("token has no code at to-block")
                lo, hi = start, end
                while hi - lo > 1:
                    mid = (lo + hi) // 2
                    if code(token, mid):
                        hi = mid
                    else:
                        lo = mid
                deploy = hi
            # Bisection assumes persistent code, appropriate only after C1 verifies xPNTs v2.
            if not code(token, deploy) or code(token, deploy - 1):
                raise RpcFailure("deployment boundary unverified")
            out["deployBlocks"][token] = deploy
            lo, size = start, chunk_size
            while lo <= end:
                hi = min(lo + size - 1, end)
                attempt = {"token": token, "fromBlock": lo, "toBlock": hi}
                out["chunks"].append(attempt)
                filt = {"address": token, "fromBlock": hex(lo), "toBlock": hex(hi), "topics": [list(TOPICS.values())]}
                try:
                    raw = [rpc(u, "eth_getLogs", [filt]) for u in urls]
                except RpcFailure:
                    attempt["status"] = "rpc error; shrinking" if hi > lo else "rpc error; stopped"
                    if hi == lo:
                        raise RpcFailure("eth_getLogs failed at minimum chunk") from None
                    size = max(1, (hi - lo + 1) // 2)
                    continue
                pair = [logset(r, token, lo, hi) for r in raw]
                if pair[0] != pair[1]:
                    raise RpcFailure("endpoint log disagreement")
                hashes = {n: agreed_block(n) for n in sorted({lo, hi} | {v["blockNumber"] for v in pair[0]})}
                if any(v["blockHash"] != hashes[v["blockNumber"]] or v["blockNumber"] < deploy for v in pair[0]):
                    raise RpcFailure("log block inconsistent with history")
                attempt.update(status="agreed", count=len(pair[0]), boundaryHashes={"from": hashes[lo], "to": hashes[hi]})
                out["logs"].extend(pair[0])
                lo = hi + 1
        for label, n in (("from", start), ("to", end)):
            if agreed_block(n) != out["blockHashes"][label]["A"]:
                raise RpcFailure("pinned block changed during scan")
        out["logs"].sort(key=order)
        out["canonicalLogsSha256"] = hashlib.sha256(canonical(out["logs"])).hexdigest()
        out.update(replay(out["logs"]))
        out["complete"] = True
    except (RpcFailure, ValueError, TypeError, KeyError, IndexError, AttributeError) as e:
        reason = str(e) if isinstance(e, RpcFailure) else "malformed RPC answer"
        out.update({c: {"verdict": UNVERIFIED, "reason": reason} for c in ("C4", "C7")})
    return out


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--rpc-a-file", required=True)
    p.add_argument("--rpc-b-file", required=True)
    p.add_argument("--token", required=True, nargs="+", action="extend")
    p.add_argument("--from-block", required=True, type=int)
    p.add_argument("--to-block", required=True, type=int)
    p.add_argument("--chunk-size", type=int, default=2000)
    p.add_argument("--out", required=True)
    args = p.parse_args()
    try:
        endpoints = [endpoint_file(f) for f in (args.rpc_a_file, args.rpc_b_file)]
        out = scan([e[0] for e in endpoints], args.token, args.from_block, args.to_block,
                   args.chunk_size, [e[1] for e in endpoints])
    except RpcFailure as e:
        out = {c: {"verdict": UNVERIFIED, "reason": str(e)} for c in ("C4", "C7")}
    try:
        Path(args.out).write_text(json.dumps(out, indent=2, ensure_ascii=False) + "\n")
    except OSError:
        sys.exit("cannot write output file")
    return 0 if all(out[c]["verdict"] == "pass" for c in ("C4", "C7")) else 1


if __name__ == "__main__":
    sys.exit(main())
