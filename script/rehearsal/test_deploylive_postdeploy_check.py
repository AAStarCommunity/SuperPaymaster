"""Offline checker tests: a simulated read-only RPC boundary; no subprocess executes."""
import contextlib
import hashlib
import io
import json
from pathlib import Path
import runpy
import sys
import unittest
from unittest.mock import patch
from types import SimpleNamespace

CHECKER = Path(__file__).with_name("deploylive_postdeploy_check.py")
ZERO = "0x" + "0" * 40

def addr(n):
    return "0x" + f"{n:040x}"

def digest(s):
    return "0x" + hashlib.sha256(s.encode()).hexdigest()

class CheckerTest(unittest.TestCase):
    def run_checker(self, mutation=None):
        keys = "registry superPaymaster staking gToken xPNTsFactoryV2 aoaProtocolRegistry reputationSystem blsAggregator dvtValidator xPNTsFactory paymasterFactory paymasterV4Impl microPaymentChannel x402Facilitator aPNTs sbt policyRegistry timelockController handoverBootstrap pnts genesisOperator expectedGovernor expectedGuardian expectedSPGuardian".split()
        cfg = {k: addr(i + 1) for i, k in enumerate(keys)}
        cfg.update(expectedCap=1000, guardianN=2, minThreshold=2, defaultThreshold=2,
                   slashThreshold0=2, slashThreshold1=2, slashThreshold2=2, guardians=[addr(101), addr(102)])
        safe, deployer, tl, h = addr(200), addr(201), cfg["timelockController"], cfg["handoverBootstrap"]
        role_names = ("DEFAULT_ADMIN_ROLE", "PROPOSER_ROLE", "EXECUTOR_ROLE", "CANCELLER_ROLE")
        roles = {r: ("0x" + "0" * 64 if r == "DEFAULT_ADMIN_ROLE" else digest(r)) for r in role_names}
        membership = {roles[r]: {tl} if r == "DEFAULT_ADMIN_ROLE" else {safe} for r in role_names}
        if mutation == "unexpected_admin": membership[roles["DEFAULT_ADMIN_ROLE"]].add(addr(250))
        if mutation in role_names:
            membership[roles[mutation]].add(h)
        def fake_run(cmd, **kwargs):
            self.assertEqual(cmd[0], "cast")
            kind, args = cmd[1], cmd[2:]
            if mutation == "rpc_error" and kind not in ("keccak", "calldata", "sig"):
                return SimpleNamespace(returncode=1, stdout="", stderr="connection failed https://secret.invalid/private-token")
            out, rc = "", 0
            if kind in ("keccak", "calldata", "sig"):
                out = digest(args[0])
            elif kind == "balance": out = "0"
            elif kind == "code": out = "0x60806040525f80fd"
            elif kind == "rpc":
                if args[0] == "eth_call":
                    rc, out = 1, digest("ForbiddenGenericSelector(bytes4)")
                else:
                    self.assertEqual(args[0], "eth_getLogs")
                    logs = []
                    for rid, accounts in membership.items():
                        for a in sorted(accounts):
                            logs.append(dict(blockNumber="0x1", logIndex=hex(len(logs)), topics=[digest("RoleGranted(bytes32,address,address)"), rid, "0x" + a[2:].zfill(64)]))
                    for role in ("PROPOSER_ROLE", "EXECUTOR_ROLE", "CANCELLER_ROLE"):
                        rid = roles[role]
                        logs.append(dict(blockNumber="0x1", logIndex=hex(len(logs)), topics=[digest("RoleGranted(bytes32,address,address)"), rid, "0x" + h[2:].zfill(64)]))
                        if h not in membership[rid]:
                            logs.append(dict(blockNumber="0x1", logIndex=hex(len(logs)), topics=[digest("RoleRevoked(bytes32,address,address)"), rid, "0x" + h[2:].zfill(64)]))
                    out = json.dumps(logs)
            elif kind == "call":
                target, sig, *params = args
                if sig == "owner()(address)": out = safe if target == cfg["gToken"] else tl
                elif sig == "pendingOwner()(address)": out = tl if mutation == "pending" else ZERO
                elif sig == "getRoleConfig(bytes32)": out = "0x" + "0" * (64 * 11) + tl[2:].zfill(64) + "0" * 64
                elif sig == "isReputationSource(address)(bool)": out = str(params[0] in (cfg["blsAggregator"], cfg["reputationSystem"])).lower()
                elif sig == "isValidator(address)(bool)": out = str(params[0] in cfg["guardians"]).lower()
                elif sig == "hasRole(bytes32,address)(bool)":
                    out = str(params[1] in membership.get(params[0], set()) if target == tl else params[1] == cfg["genesisOperator"]).lower()
                elif sig.split("(")[0] in role_names: out = roles[sig.split("(")[0]]
                elif sig == "getMinDelay()(uint256)": out = "0" if mutation == "delay" else "172800"
                elif sig in ("treasury()(address)", "daoMultisig()(address)", "minter()(address)", "capGuardian()(address)"): out = safe
                elif sig in ("slashPolicyAdmin()(address)", "timelock()(address)"): out = tl
                elif sig == "guardian()(address)": out = cfg["expectedSPGuardian"] if target == cfg["superPaymaster"] else cfg["expectedGuardian"]
                elif sig == "APNTS_TOKEN()(address)": out = cfg["aPNTs"]
                elif sig == "registry()(address)": out = cfg["registry"]
                elif sig == "cap()(uint256)": out = "1000"
                elif sig == "priceStalenessThreshold()(uint256)": out = "4200"
                elif "Threshold" in sig or "Thresholds" in sig: out = "2"
                elif sig == "validatorAtSlot(uint8)(address)": out = cfg["guardians"][int(params[0]) - 1]
                elif sig == "operators(address)": out = "0x" + "0" * (64 * 9)
                elif sig == "getUserRoles(address)(bytes32[])": out = "[]"
                elif sig == "authorizedSlashers(address)(bool)": out = "false"
                elif sig == "fraudProofVerifier()(address)": out = ZERO
                elif sig == "balanceOf(address)(uint256)": out = "0"
                elif sig == "version()(string)": out = '"fixture"'
                else: self.fail(f"Unhandled {sig}")
            else: self.fail(f"Non-read-only command: {kind}")
            return SimpleNamespace(returncode=rc, stdout=out if rc == 0 else "", stderr=out if rc else "")
        output = io.StringIO()
        with patch.object(sys, "argv", [str(CHECKER), "https://secret.invalid/private-token", "fixture.json", deployer, safe]), patch("builtins.open", return_value=io.StringIO(json.dumps(cfg))), patch("subprocess.run", side_effect=fake_run), contextlib.redirect_stdout(output):
            with self.assertRaises(SystemExit) as caught:
                runpy.run_path(str(CHECKER), run_name="__main__")
        self.assertNotIn("private-token", output.getvalue())
        return caught.exception.code, output.getvalue()

    def test_complete_end_state(self):
        rc, out = self.run_checker()
        self.assertEqual(rc, 0, out)
        print(out.splitlines()[-1])

    def test_intermediate_states_fail(self):
        for mutation in ("delay", "pending", "PROPOSER_ROLE", "EXECUTOR_ROLE", "CANCELLER_ROLE", "DEFAULT_ADMIN_ROLE", "unexpected_admin", "rpc_error"):
            with self.subTest(mutation=mutation):
                rc, out = self.run_checker(mutation)
                self.assertEqual(rc, 1, out)

if __name__ == "__main__":
    unittest.main()
