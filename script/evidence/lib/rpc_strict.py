"""Shared strict JSON-RPC classification for the R-AMS gauges (R2-F1).

classify(error) -> "evm-failure" only for an explicit (code, full-message) whitelist of deterministic
EVM outcomes at a given gas limit, as emitted by reth (Sepolia endpoints) and foundry nightly anvil.
Known RPC-fault codes always win. Everything else is a fault and must abort the caller.
"""
import re

# JSON-RPC / provider fault codes that can never be an EVM outcome (rate limit, internal, method,
# params, resource, limit exceeded, request too large, HTTP-ish).
FAULT_CODES = {-32700, -32600, -32601, -32602, -32603, -32004, -32005, -32006, -32016, -32099, 429}

# (allowed codes, anchored full-message pattern)
# ASCII only: explicit [0-9] digit classes and printable-ASCII revert reasons, so Python and the JS
# mirror in script/b-layer/ams-calibrate.mjs accept exactly the same strings.
_A = re.ASCII
_EVM_FAILURES = [
    ({-32003, -32015}, re.compile(r"out of gas: gas required exceeds: [0-9]{1,20}", _A)),          # reth
    ({-32003, -32015}, re.compile(r"out of gas: gas exhausted during [a-z ]{1,40}: [0-9]{1,20}", _A)),  # reth
    ({-32000}, re.compile(r"intrinsic gas too low", _A)),                                          # reth
    ({3, -32003, -32015}, re.compile(r"execution reverted(: [\x20-\x7e]{0,200})?", _A)),             # reth / anvil
    ({-32003}, re.compile(r"EVM error (OutOfGas|MemoryOOG|MemoryLimitOOG|PrecompileOOG|"
                          r"InvalidOperandOOG|ReentrancySentryOOG)", _A)),                          # anvil (revm halts)
    ({-32000}, re.compile(r"intrinsic gas too high -- (CallGasCostMoreThanGasLimit|GasFloorMoreThanGasLimit)", _A)),  # anvil
]
# Only these methods may legitimately return an EVM execution failure; for any other method an
# "EVM-looking" error is a fault.
EVM_METHODS = {"eth_call", "eth_estimateGas"}

HEXDATA = re.compile(r"0x([0-9a-fA-F]{2})*", re.ASCII)
QTY = re.compile(r"0x(0|[1-9a-fA-F][0-9a-fA-F]{0,63})", re.ASCII)
HASH32 = re.compile(r"0x[0-9a-fA-F]{64}", re.ASCII)


def classify(error, method=None):
    """Return "evm-failure" or "fault" for a JSON-RPC error object. An EVM failure is only possible
    for EVM_METHODS (when method is given)."""
    code, msg = error.get("code"), error.get("message")
    if type(code) is not int or not isinstance(msg, str) or code in FAULT_CODES:
        return "fault"
    if method is not None and method not in EVM_METHODS:
        return "fault"
    for codes, rx in _EVM_FAILURES:
        if code in codes and rx.fullmatch(msg):
            return "evm-failure"
    return "fault"
