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
_EVM_FAILURES = [
    ({-32003, -32015}, re.compile(r"out of gas: gas required exceeds: \d+")),                   # reth
    ({-32003, -32015}, re.compile(r"out of gas: gas exhausted during [a-z ]+: \d+")),            # reth
    ({-32000}, re.compile(r"intrinsic gas too low")),                                           # reth
    ({3, -32003, -32015}, re.compile(r"execution reverted(: .{0,200})?")),                      # reth / anvil
    ({-32003}, re.compile(r"EVM error (OutOfGas|MemoryOOG|MemoryLimitOOG|PrecompileOOG|"
                          r"InvalidOperandOOG|ReentrancySentryOOG)")),                           # anvil (revm halts)
    ({-32000}, re.compile(r"intrinsic gas too high -- (CallGasCostMoreThanGasLimit|GasFloorMoreThanGasLimit)")),  # anvil
]

HEXDATA = re.compile(r"0x([0-9a-fA-F]{2})*")
QTY = re.compile(r"0x(0|[1-9a-fA-F][0-9a-fA-F]*)")
HASH32 = re.compile(r"0x[0-9a-fA-F]{64}")


def classify(error):
    """Return "evm-failure" or "fault" for a JSON-RPC error object (already type-checked)."""
    code, msg = error.get("code"), error.get("message")
    if type(code) is not int or not isinstance(msg, str) or code in FAULT_CODES:
        return "fault"
    for codes, rx in _EVM_FAILURES:
        if code in codes and rx.fullmatch(msg):
            return "evm-failure"
    return "fault"
