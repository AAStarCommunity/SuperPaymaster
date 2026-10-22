#!/usr/bin/env python3
"""Execute ONE deployer-EOA step (S1, S2, S3, S4 or S7) of the A3a v4 packet on Sepolia, gated.

Usage (author go required; DSR CC-125 973964b6 execution boundary):
  RPC_A=<archive rpc> RPC_B=<second rpc> DEPLOYER_KEY_ENV=PRIVATE_KEY ENV_FILE=.env.sepolia \
    python3 script/evidence/a3a-live-step.py S1 [--dry-run]

Gate (any failure -> exit non-zero BEFORE signing):
  - packet step calldata keccak == packet calldataKeccak256; signer key derives to the packet sender;
  - both endpoints: chainId 11155111, deployer nonce latest == pending == the step's requiredSenderNonce;
  - step-specific pre-state read on both endpoints (see PRE);
  - eth_estimateGas on both endpoints succeeds and <= the packet's suggestedGasLimit;
  - the signed raw tx decodes to exactly (chainId, nonce, to/create, value 0, input, gas limit).
Then the identical raw tx is sent to both endpoints, the receipt is awaited on both (status 1,
same block hash), and the step-specific post-state is read on both endpoints at the receipt block.
A JSON record (no key, no RPC URL) is written to docs/release/a3a-exec-sepolia/<label>.json.
The private key is read from ENV_FILE by variable name and is only passed to `cast mktx`.
"""
import json, os, re, subprocess, sys, time, urllib.request

# QUARANTINED (DSR CC-125 d13dd9eb): kept only as failure evidence of the 2026-10-22 S1 stop.
# It lacks an R-AMS/fork-tier gate, under-checks S2/S3/S7, signs in --dry-run and passes the key via
# argv. It must not be used to broadcast; the reviewed executor is a separate R-AMS-3 deliverable.
sys.exit("a3a-live-step.UNREVIEWED.py is quarantined evidence; refusing to run")

CAST = os.path.expanduser("~/.foundry/bin/cast")
PACKET = "docs/release/a3a-precheck-v4/a3a-precheck.json"
OUTDIR = "docs/release/a3a-exec-sepolia"
CHAIN = 11155111
DEPLOYER = "0xb5600060e6de5e11d3636731964218e53caadf0e"
SAFE = "0x51edf11fdb0a4f66220efb8efa54eca77232e114"
SP = "0x09df0d2e3722ec0e401fe3819e64278a42ae4de9"
OLD_PENDING = "0xbb46321545a91db2f3b5c3e694f2f23abe259883"
TL = "0xccdf8e0d29fb2c3061910d79484a2b653757c34b"
CAPPED = "0x9eb17fac022557f64924aa2f9e018db3a330e1e7"
ZERO = "0x" + "0" * 40
SEL = {k: None for k in ("pendingAPNTsToken()", "owner()", "pendingOwner()", "APNTS_TOKEN()",
                         "getMinDelay()", "nonce()", "pendingAPNTsTokenEta()")}
MAX_FEE = "2gwei"
PRIO = "0.1gwei"


class Fail(Exception):
    pass


def rpc(url, method, params):
    body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    try:
        req = urllib.request.Request(url, body, {"Content-Type": "application/json", "User-Agent": "a3a-live-step"})
        with urllib.request.urlopen(req, timeout=60) as r:
            d = json.load(r)
    except Exception as e:
        raise Fail(f"{method}: transport error ({type(e).__name__})") from None
    if not isinstance(d, dict) or d.get("jsonrpc") != "2.0" or type(d.get("id")) is not int or d["id"] != 1:
        raise Fail(f"{method}: malformed envelope")
    if "error" in d:
        err = d["error"]
        msg = err.get("message", "") if isinstance(err, dict) else ""
        # Provider error messages for eth_sendRawTransaction ("already known", "nonce too low") are
        # needed to decide; strip anything URL-like before keeping them.
        return {"__error__": re.sub(r"https?://\S+", "<url>", str(msg))[:200]}
    return d.get("result")


def sig(name):
    out = subprocess.run([CAST, "sig", name], capture_output=True, text=True, check=True).stdout.strip()
    return out


def call(url, to, data, blk="latest"):
    r = rpc(url, "eth_call", [{"to": to, "data": data}, blk])
    if not isinstance(r, str) or not re.fullmatch(r"0x[0-9a-fA-F]{64}", r):
        raise Fail(f"eth_call {data[:10]}: bad result")
    return r


def addr(w):
    if w[2:26] != "0" * 24:
        raise Fail("address padding")
    return "0x" + w[-40:].lower()


def uint(w):
    return int(w, 16)


def code_len(url, a, blk="latest"):
    c = rpc(url, "eth_getCode", [a, blk])
    if not isinstance(c, str) or not re.fullmatch(r"0x([0-9a-fA-F]{2})*", c):
        raise Fail("eth_getCode: bad result")
    return (len(c) - 2) // 2


def both(urls, f):
    vals = {k: f(u) for k, u in urls.items()}
    if vals["A"] != vals["B"]:
        raise Fail(f"endpoints disagree: {vals}")
    return vals["A"]


def state(urls, blk="latest"):
    s = {}
    s["spPending"] = both(urls, lambda u: addr(call(u, SP, SEL["pendingAPNTsToken()"], blk)))
    s["spPendingEta"] = both(urls, lambda u: uint(call(u, SP, SEL["pendingAPNTsTokenEta()"], blk)))
    s["spAPNTS"] = both(urls, lambda u: addr(call(u, SP, SEL["APNTS_TOKEN()"], blk)))
    s["spOwner"] = both(urls, lambda u: addr(call(u, SP, SEL["owner()"], blk)))
    s["tlCode"] = both(urls, lambda u: code_len(u, TL, blk))
    s["cappedCode"] = both(urls, lambda u: code_len(u, CAPPED, blk))
    s["safeNonce"] = both(urls, lambda u: uint(call(u, SAFE, SEL["nonce()"], blk)))
    if s["tlCode"]:
        s["tlMinDelay"] = both(urls, lambda u: uint(call(u, TL, SEL["getMinDelay()"], blk)))
    if s["cappedCode"]:
        s["cappedOwner"] = both(urls, lambda u: addr(call(u, CAPPED, SEL["owner()"], blk)))
        s["cappedPendingOwner"] = both(urls, lambda u: addr(call(u, CAPPED, SEL["pendingOwner()"], blk)))
    return s


PRE = {
    "S1": lambda s: s["spPending"] == OLD_PENDING and s["spOwner"] == DEPLOYER and s["tlCode"] == 0 and s["cappedCode"] == 0,
    "S2": lambda s: s["spPending"] == ZERO and s["tlCode"] == 0 and s["cappedCode"] == 0,
    "S3": lambda s: s["tlCode"] > 0 and s.get("tlMinDelay") == 172800 and s["cappedCode"] == 0,
    "S4": lambda s: s["cappedCode"] > 0 and s.get("cappedOwner") == DEPLOYER and s.get("cappedPendingOwner") == ZERO,
    "S7": lambda s: s["spPending"] == ZERO and s.get("cappedOwner") == TL and s.get("cappedPendingOwner") == ZERO and s["safeNonce"] == 3,
}
POST = {
    "S1": lambda s: s["spPending"] == ZERO and s["spPendingEta"] == 0,
    "S2": lambda s: s["tlCode"] > 0 and s.get("tlMinDelay") == 172800,
    "S3": lambda s: s["cappedCode"] > 0 and s.get("cappedOwner") == DEPLOYER and s.get("cappedPendingOwner") == ZERO,
    "S4": lambda s: s.get("cappedOwner") == DEPLOYER and s.get("cappedPendingOwner") == TL,
    "S7": lambda s: s["spPending"] == CAPPED and s["spPendingEta"] > 0,
}


def load_key(env_file, var):
    for line in open(env_file):
        m = re.match(r"\s*(?:export\s+)?([A-Z0-9_]+)=(.*)", line)
        if m and m.group(1) == var:
            v = m.group(2).strip().strip("\"'")
            if re.fullmatch(r"(0x)?[0-9a-fA-F]{64}", v):
                return v
    raise Fail(f"key variable {var} not found in env file")


def main():
    sid, dry = sys.argv[1], "--dry-run" in sys.argv
    if sid not in PRE:
        raise Fail("only deployer steps S1 S2 S3 S4 S7 are supported")
    for k in SEL:
        SEL[k] = sig(k)
    urls = {"A": os.environ["RPC_A"], "B": os.environ["RPC_B"]}
    if urls["A"].rstrip("/") == urls["B"].rstrip("/"):
        raise Fail("RPC_A and RPC_B must differ")
    pk = json.load(open(PACKET))
    st = next(s for s in pk["steps"] if s["id"] == sid)
    data = st["calldata"]
    kk = subprocess.run([CAST, "keccak", data], capture_output=True, text=True, check=True).stdout.strip()
    if kk != st["calldataKeccak256"]:
        raise Fail("calldata keccak != packet")
    key = load_key(os.environ.get("ENV_FILE", ".env.sepolia"), os.environ.get("DEPLOYER_KEY_ENV", "PRIVATE_KEY"))
    who = subprocess.run([CAST, "wallet", "address", "--private-key", key], capture_output=True, text=True, check=True).stdout.strip().lower()
    if who != st["from"].lower() or who != DEPLOYER:
        raise Fail("signer key does not derive to the packet sender")
    need = st["requiredSenderNonce"]
    rec = {"step": sid, "label": st["label"], "packetCalldataKeccak256": kk, "requiredSenderNonce": need, "gate": {}}

    rec["gate"]["chainId"] = both(urls, lambda u: int(rpc(u, "eth_chainId", []), 16))
    if rec["gate"]["chainId"] != CHAIN:
        raise Fail("wrong chain")
    for tag in ("latest", "pending"):
        n = both(urls, lambda u: int(rpc(u, "eth_getTransactionCount", [DEPLOYER, tag]), 16))
        rec["gate"][f"nonce_{tag}"] = n
        if n != need:
            raise Fail(f"deployer nonce {tag} {n} != required {need}: ABORT (regenerate if identity-bearing)")
    pre = state(urls)
    rec["gate"]["preState"] = pre
    if not PRE[sid](pre):
        raise Fail(f"pre-state check failed: {pre}")
    tx = {"from": DEPLOYER, "data": data, "value": "0x0"}
    if st["to"]:
        tx["to"] = st["to"]
    est = {}
    for k, u in urls.items():
        g = rpc(u, "eth_estimateGas", [tx])
        if not isinstance(g, str):
            raise Fail(f"eth_estimateGas on {k} failed: {g}")
        est[k] = int(g, 16)
    rec["gate"]["estimateGas"] = est
    limit = int(st["suggestedGasLimit"])
    if max(est.values()) > limit:
        raise Fail(f"estimate {est} exceeds packet gas limit {limit}")

    args = [CAST, "mktx", "--private-key", key, "--rpc-url", urls["A"], "--chain", str(CHAIN), "--nonce", str(need),
            "--gas-limit", str(limit), "--gas-price", MAX_FEE, "--priority-gas-price", PRIO]
    args += (["--create", data] if not st["to"] else [st["to"], data])
    raw = subprocess.run(args, capture_output=True, text=True)
    if raw.returncode != 0:
        raise Fail("cast mktx failed")
    raw = raw.stdout.strip()
    dec = json.loads(subprocess.run([CAST, "decode-transaction", raw], capture_output=True, text=True, check=True).stdout)
    dec_to = (dec.get("to") or "").lower()
    ok = (int(str(dec.get("chainId")), 0) == CHAIN and int(str(dec.get("nonce")), 0) == need
          and int(str(dec.get("gas") or dec.get("gasLimit")), 0) == limit and int(str(dec.get("value")), 0) == 0
          and (dec.get("input") or dec.get("data") or "").lower() == data.lower()
          and (dec_to == st["to"].lower() if st["to"] else dec_to == ""))
    if not ok:
        raise Fail("signed tx does not decode to the packet step")
    txhash = subprocess.run([CAST, "keccak", raw], capture_output=True, text=True, check=True).stdout.strip()
    rec["txHash"] = txhash
    if dry:
        rec["dryRun"] = True
        print(json.dumps(rec, indent=1))
        return
    rec["broadcast"] = {k: rpc(u, "eth_sendRawTransaction", [raw]) for k, u in urls.items()}
    for k, v in rec["broadcast"].items():
        if isinstance(v, dict) and not re.search(r"already known|known transaction|already imported", v["__error__"], re.I):
            print(f"warning: endpoint {k} rejected broadcast: {v['__error__']}", file=sys.stderr)
        elif isinstance(v, str) and v.lower() != txhash.lower():
            raise Fail("endpoint returned a different tx hash")
    rcpt = {}
    deadline = time.time() + 600
    while time.time() < deadline and len(rcpt) < 2:
        for k, u in urls.items():
            if k not in rcpt:
                r = rpc(u, "eth_getTransactionReceipt", [txhash])
                if isinstance(r, dict) and r.get("blockHash"):
                    rcpt[k] = r
        time.sleep(6)
    if len(rcpt) < 2:
        raise Fail(f"receipt not seen on both endpoints within 600s (seen: {list(rcpt)}); tx {txhash}")
    a = rcpt["A"]
    if rcpt["B"]["blockHash"] != a["blockHash"] or a["status"] != "0x1":
        raise Fail(f"receipt mismatch or failed: status {a['status']}")
    rec["receipt"] = {"blockNumber": int(a["blockNumber"], 16), "blockHash": a["blockHash"], "status": 1,
                      "gasUsed": int(a["gasUsed"], 16), "contractAddress": a.get("contractAddress"),
                      "logs": [{"address": l["address"], "topic0": l["topics"][0] if l["topics"] else None} for l in a["logs"]]}
    if st.get("createdAddress") and (a.get("contractAddress") or "").lower() != st["createdAddress"].lower():
        raise Fail(f"created address {a.get('contractAddress')} != packet {st['createdAddress']}")
    post = state(urls, hex(int(a["blockNumber"], 16)))
    rec["postState"] = post
    rec["postOk"] = POST[sid](post)
    rec["nonceAfter"] = both(urls, lambda u: int(rpc(u, "eth_getTransactionCount", [DEPLOYER, a["blockNumber"]]), 16))
    os.makedirs(OUTDIR, exist_ok=True)
    json.dump(rec, open(f"{OUTDIR}/{st['label']}.json", "w"), indent=1)
    print(json.dumps({k: rec[k] for k in ("step", "txHash", "postOk", "nonceAfter")} | {"block": rec["receipt"]["blockNumber"]}))
    if not rec["postOk"] or rec["nonceAfter"] != need + 1:
        raise Fail("post-state check failed: STOP")


if __name__ == "__main__":
    try:
        main()
    except Fail as e:
        print(f"a3a-live-step: STOP: {e}", file=sys.stderr)
        sys.exit(2)
    except Exception as e:
        print(f"a3a-live-step: STOP: unexpected {type(e).__name__}", file=sys.stderr)
        sys.exit(3)
