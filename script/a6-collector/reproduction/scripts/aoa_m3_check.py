#!/usr/bin/env python3
"""Offline AOA candidate-package checks; never attests chain truth or authorization."""
import argparse
import hashlib
import json
import re
from collections import Counter, defaultdict
from pathlib import Path

HASH = re.compile(r"0x[0-9a-fA-F]{64}\Z")
SYSTEMS = {"SP", "VerifyingPaymaster", "TokenPaymaster"}
CONTROLS = ("entryPoint", "accountImplementation", "target", "calldataHash", "tokenStateProtocol", "bundlerConfigHash", "windowId", "samplingProtocolHash")


def check(package, root, expected=50):
    errors = []
    def require(ok, message):
        if not ok:
            errors.append(message)
    require(package.get("schema") == "aoa-m3-receive-v1", "unsupported schema")
    files = package.get("files", {})
    require(bool(files), "empty archive hash inventory")
    for name, digest in files.items():
        path = (root / name).resolve()
        require(path.is_relative_to(root.resolve()), f"archive path escapes root: {name}")
        if not path.is_relative_to(root.resolve()):
            continue
        require(path.is_file(), f"missing archive: {name}")
        if path.is_file():
            require(hashlib.sha256(path.read_bytes()).hexdigest() == digest, f"hash mismatch: {name}")
    attempts = package.get("attempts", [])
    require(bool(attempts), "no attempts")
    ids, ops = set(), set()
    groups = defaultdict(list)
    excluded = Counter()
    for i, row in enumerate(attempts):
        prefix = f"attempt[{i}]"
        aid = row.get("attemptId")
        require(isinstance(aid, str) and bool(aid) and aid not in ids, f"{prefix}: missing/duplicate attemptId")
        ids.add(aid)
        require(row.get("paymasterKind") in SYSTEMS, f"{prefix}: unknown system")
        require(type(row.get("included")) is bool, f"{prefix}: included must be boolean")
        if row.get("included") is not True:
            require(bool(row.get("exclusionReason")), f"{prefix}: excluded attempt lacks reason")
            excluded[str(row.get("exclusionReason"))] += 1
            continue
        pair = row.get("pairId")
        require(isinstance(pair, str) and bool(pair), f"{prefix}: missing pairId")
        groups[str(pair)].append(row)
        require(type(row.get("chainId")) is int and row["chainId"] > 0, f"{prefix}: chainId required")
        for field in ("txHash", "userOpHash", "blockHash", "runtimeCodeHash"):
            require(bool(HASH.fullmatch(str(row.get(field, "")))), f"{prefix}: invalid {field}")
        key = (row.get("chainId"), str(row.get("userOpHash")).lower())
        require(key not in ops, f"{prefix}: duplicate UserOp identity")
        ops.add(key)
        require(row.get("receiptStatus") == 1 and type(row.get("receiptStatus")) is int, f"{prefix}: receipt unsuccessful")
        require(row.get("userOpSuccess") is True, f"{prefix}: UOE not successful")
        require(row.get("settlementVerified") is True, f"{prefix}: settlement/state not verified")
        require(not row.get("injectedScenario"), f"{prefix}: injected sample in typical group")
        for field in ("actualGasUsed", "actualGasCostWei", "txGasUsed", "effectiveGasPriceWei"):
            value = row.get(field)
            require(isinstance(value, str) and value.isdecimal(), f"{prefix}: {field} requires nonnegative decimal string")
        for field in ("receiptFile", "uoeFile", "passportFile", "stateFile"):
            require(row.get(field) in files, f"{prefix}: unarchived {field}")
        for field in CONTROLS:
            require(isinstance(row.get(field), str) and bool(row[field]), f"{prefix}: missing control {field}")
    require(len(groups) == expected, f"expected {expected} matched groups, found {len(groups)}")
    for pair, rows in groups.items():
        require(Counter(r.get("paymasterKind") for r in rows) == Counter(SYSTEMS), f"{pair}: require exactly one SP/VPM/TPM")
        for field in CONTROLS + ("chainId",):
            require(len({json.dumps(r.get(field), sort_keys=True) for r in rows}) == 1, f"{pair}: mismatched {field}")
    return {"status": "FAIL" if errors else "OFFLINE_STRUCTURE_PASS", "errors": errors,
            "attempts": len(attempts), "included": len(ops), "matched_groups": len(groups),
            "excluded_reasons": dict(excluded),
            "limitation": "Does not decode raw events, prove complete attempt capture, verify RPC independence, final pin, governance, or authorize sampling."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("--expected", type=int, default=50, help="50 for formal candidates; lower only for synthetic checks")
    args = parser.parse_args()
    try:
        if args.expected <= 0:
            raise ValueError("expected must be positive")
        result = check(json.loads(args.package.read_text()), args.package.parent, args.expected)
    except (OSError, ValueError, TypeError, AttributeError, KeyError) as exc:
        result = {"status": "FAIL", "errors": [str(exc)]}
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return int(result["status"] == "FAIL")


if __name__ == "__main__":
    raise SystemExit(main())
