#!/usr/bin/env python3
"""D5c-1 — one source mutation per property (applied temporarily, always reverted).

usage (repo root):
  python3 script/halmos/d5c1-mutations.py apply  <ID>   # edit contracts/src in place
  python3 script/halmos/d5c1-mutations.py revert <ID>   # restore the exact original bytes
  python3 script/halmos/d5c1-mutations.py list

Each mutation is an exact, unique text replacement; `apply` refuses if the anchor does not occur
exactly once, `revert` restores the pristine file content saved by `apply` and checks its sha256.
After every run: `git status --porcelain contracts/src` must be empty.
"""
import hashlib
import json
import os
import sys

SAVE_DIR = "cache/d5c1-mutations"

MUTATIONS = {
    # CAP-1: remove the enforced cap check in mint
    "M-CAP1": {
        "file": "contracts/src/tokens/APNTsCapped.sol",
        "old": "        if (amount > cap || supply > cap - amount) revert CapExceeded(supply, amount, cap);\n",
        "new": "        // D5c-1 M-CAP1: cap check removed\n",
    },
    # A-3: an SP-callable transferFrom-like path in the extension (reached via the fallback)
    "M-A3": {
        "file": "contracts/src/tokens/v2/xPNTsTokenV2Ext.sol",
        "old": "    function getMetadata() external view returns (\n",
        "new": (
            "    // D5c-1 M-A3: SP-callable pull\n"
            "    function spPull(address from, uint256 amount) external {\n"
            "        if (msg.sender != SUPERPAYMASTER_ADDRESS) revert Unauthorized(msg.sender);\n"
            "        _transfer(from, msg.sender, amount);\n"
            "    }\n\n"
            "    function getMetadata() external view returns (\n"
        ),
    },
    # I2: drop the per-(spender,user) + total remaining-cap admission check of tryLockForGas
    "M-I2": {
        "file": "contracts/src/tokens/v2/xPNTsTokenV2.sol",
        "old": (
            "        if (_remainingWith(spender, user, usedA, usedB) < reserveAPNTs) {\n"
            "            return (IxPNTsTokenV2.LockResult.INSUFFICIENT, 0, 0, 0, 0);\n"
            "        }\n"
        ),
        "new": "        // D5c-1 M-I2: remaining-cap admission check removed\n",
    },
    # F-D5c1-1 regression liveness: drop the initialize rate-range guard added by 3c28ec21
    "M-F1": {
        "file": "contracts/src/tokens/v2/xPNTsTokenV2.sol",
        "old": "        if (rate < _RATE_MIN || rate > _RATE_MAX) revert ExchangeRateOutOfRange(rate, _RATE_MIN, _RATE_MAX);\n",
        "new": "        // D5c-1 M-F1: initialize rate-range guard removed\n",
    },
    # liveness of the fuzz substitutes (D5c1BoundedFuzz): pull without the auto-allowance cap check
    "M-PULL": {
        "file": "contracts/src/tokens/v2/xPNTsTokenV2.sol",
        "old": "        if (_remaining(spender, owner) < a) revert AutoAllowanceExceeded();\n",
        "new": "        // D5c-1 M-PULL: auto-allowance cap check removed\n",
    },
    # liveness of the fuzz substitutes: settle burns the whole escrow whatever the charge
    "M-BURNALL": {
        "file": "contracts/src/tokens/v2/xPNTsTokenV2.sol",
        "old": "        if (xBurned > r.xLocked) xBurned = r.xLocked;\n",
        "new": "        xBurned = r.xLocked; // D5c-1 M-BURNALL: burn the whole escrow\n",
    },
    # liveness of the lemma-M fuzz substitute (MintRepayLemmaFuzzTest): the mint auto-repay burns
    # one xPNTs-wei more than ceil(repayAPNTs * rate / 1e18), so repayX can exceed the minted amount
    "M-REPAY": {
        "file": "contracts/src/tokens/v2/xPNTsV2Base.sol",
        "old": "                    uint256 repayXPNTs = (repayAPNTs * rate + 1e18 - 1) / 1e18;\n",
        "new": "                    uint256 repayXPNTs = (repayAPNTs * rate + 1e18 - 1) / 1e18 + 1; // D5c-1 M-REPAY\n",
    },
    # I6: the credit ceiling ignores the user's requestedCap (keeps the protocol ceiling + tier)
    "M-I6": {
        "file": "contracts/src/tokens/v2/xPNTsTokenV2.sol",
        "old": "        uint256 cap = r.requestedCap;\n",
        "new": "        uint256 cap = PROTOCOL_CREDIT_CEILING; // D5c-1 M-I6: requestedCap ignored\n",
    },
}


def sha(b):
    return hashlib.sha256(b).hexdigest()


def apply(mid):
    m = MUTATIONS[mid]
    with open(m["file"], "rb") as f:
        orig = f.read()
    text = orig.decode()
    n = text.count(m["old"])
    if n != 1:
        sys.exit(f"{mid}: anchor occurs {n} times in {m['file']} (need exactly 1)")
    os.makedirs(SAVE_DIR, exist_ok=True)
    with open(os.path.join(SAVE_DIR, f"{mid}.orig"), "wb") as f:
        f.write(orig)
    with open(os.path.join(SAVE_DIR, f"{mid}.json"), "w") as f:
        json.dump({"file": m["file"], "sha256": sha(orig)}, f)
    mutated = text.replace(m["old"], m["new"])
    with open(m["file"], "w") as f:
        f.write(mutated)
    import difflib
    d = "".join(difflib.unified_diff(text.splitlines(True), mutated.splitlines(True),
                                     "a/" + m["file"], "b/" + m["file"]))
    with open(os.path.join(SAVE_DIR, f"{mid}.diff"), "w") as f:
        f.write(d)
    print(f"applied {mid} to {m['file']} (pristine sha256 {sha(orig)}; diff in {SAVE_DIR}/{mid}.diff)")


def revert(mid):
    with open(os.path.join(SAVE_DIR, f"{mid}.json")) as f:
        meta = json.load(f)
    with open(os.path.join(SAVE_DIR, f"{mid}.orig"), "rb") as f:
        orig = f.read()
    assert sha(orig) == meta["sha256"]
    with open(meta["file"], "wb") as f:
        f.write(orig)
    with open(meta["file"], "rb") as f:
        assert sha(f.read()) == meta["sha256"]
    print(f"reverted {mid}: {meta['file']} sha256 {meta['sha256']}")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "list"
    if cmd == "list":
        for k, v in MUTATIONS.items():
            print(k, v["file"])
    elif cmd == "apply":
        apply(sys.argv[2])
    elif cmd == "revert":
        revert(sys.argv[2])
    else:
        sys.exit(__doc__)
