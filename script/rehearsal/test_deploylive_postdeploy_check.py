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
    def run_checker(self, mutation=None, safe_recovery=False):
        keys = "registry superPaymaster staking gToken xPNTsFactoryV2 aoaProtocolRegistry reputationSystem blsAggregator dvtValidator xPNTsFactory paymasterFactory paymasterV4Impl microPaymentChannel x402Facilitator aPNTs sbt policyRegistry timelockController handoverBootstrap pnts genesisOperator expectedGovernor expectedGuardian expectedSPGuardian registryImpl spImpl".split()
        cfg = {k: addr(i + 1) for i, k in enumerate(keys)}
        cfg.update(deploymentStartBlock=1, deployerGTokenBalance=0, deployerGTokenAllowance=0, deployerSBTBalance=0, genesisIsConfigured=False, handoverBootstrapNonce=22, expectedCap=1000, guardianN=2, minThreshold=2, defaultThreshold=2,
                   slashThreshold0=2, slashThreshold1=2, slashThreshold2=2, guardians=[addr(101), addr(102)])
        safe, deployer, tl, h = addr(200), addr(201), cfg["timelockController"], cfg["handoverBootstrap"]
        cfg.update(deployer=deployer, governanceOwner=safe)
        if mutation in ("hex_numbers", "decimal_strings"): cfg["expectedCap"] = 2**200
        if mutation == "hex_numbers":
            cfg = {k: hex(v) if type(v) is int else v for k, v in cfg.items()}
        if mutation == "decimal_strings":
            cfg = {k: str(v) if type(v) is int else v for k, v in cfg.items()}
        if mutation == "wrong_deployer": cfg["deployer"] = addr(999)
        if mutation == "wrong_safe": cfg["governanceOwner"] = addr(999)
        role_names = ("DEFAULT_ADMIN_ROLE", "PROPOSER_ROLE", "EXECUTOR_ROLE", "CANCELLER_ROLE")
        roles = {r: ("0x" + "0" * 64 if r == "DEFAULT_ADMIN_ROLE" else digest(r)) for r in role_names}
        membership = {roles[r]: {tl} if r == "DEFAULT_ADMIN_ROLE" else {safe} for r in role_names}
        if mutation == "half_handover":
            membership = {roles[r]: {tl} if r == "DEFAULT_ADMIN_ROLE" else {h} for r in role_names}
        if mutation == "unexpected_admin": membership[roles["DEFAULT_ADMIN_ROLE"]].add(addr(250))
        if mutation in role_names:
            membership[roles[mutation]].add(h)
        def fake_run(cmd, **kwargs):
            self.assertEqual(cmd[0], "cast")
            kind, args = cmd[1], cmd[2:]
            if mutation == "rpc_error" and kind not in ("keccak", "calldata", "sig"):
                return SimpleNamespace(returncode=1, stdout="", stderr="connection failed https://secret.invalid/private-token")
            out, rc = "", 0
            if kind in ("keccak", "calldata", "sig", "abi-encode"):
                out = digest("|".join(args))
            elif kind == "balance": out = "0"
            elif kind == "storage": out = "0x" + cfg["registryImpl" if args[0] == cfg["registry"] else "spImpl"][2:].zfill(64)
            elif kind == "code":
                out = "0x" if mutation in ("absent_h", "half_handover") and args[0] == h else "0x60806040525f80fd"
                if args[0] == safe and mutation == "delegated_safe": out = "0xef0100" + "00" * 20
            elif kind == "rpc":
                if args[0] == "eth_call":
                    q = json.loads(args[1])
                    if q["to"] in (cfg["registryImpl"], cfg["spImpl"]):
                        error = "UUPSUnauthorizedCallContext()" if q["data"] == digest("|".join(["upgradeToAndCall(address,bytes)", q["to"], "0x"])) else "InvalidInitialization()"
                        rc, out = 1, digest(error)
                        if mutation == "implementation_unlocked": rc, out = 0, "0x"
                    elif q["to"] in (cfg["registry"], cfg["superPaymaster"]): rc, out = 1, digest("OwnableUnauthorizedAccount(address)")
                    else: rc, out = 1, digest("|".join(["ForbiddenGenericSelector(bytes4)", digest("slashByDVT(address,bytes32,uint256,string)")]))
                    # Each generic request embeds a different denied selector.
                    if q["to"] == cfg["blsAggregator"]:
                        for signature, arguments in (("batchUpdateGlobalReputation(uint256,address[],uint256[],uint256,bytes)", ["1", "[]", "[]", "1", "0x01"]), ("slash(address,uint256,string)", [deployer, "1", "x"]), ("slashByDVT(address,bytes32,uint256,string)", [deployer, "0x" + "00" * 32, "1", "x"])):
                            inner = digest("|".join([signature] + arguments))
                            if q["data"] == digest("|".join(["executeProposal(uint256,address,bytes,uint256,bytes)", "1", cfg["registry"], inner, "3", "0x00"])):
                                out = digest("|".join(["ForbiddenGenericSelector(bytes4)", digest(signature)]))
                else:
                    self.assertEqual(args[0], "eth_getLogs")
                    self.assertEqual(json.loads(args[1])["fromBlock"], "0x1")
                    logs = []
                    for rid, accounts in membership.items():
                        for a in sorted(accounts):
                            logs.append(dict(blockNumber="0x1", logIndex=hex(len(logs)), topics=[digest("RoleGranted(bytes32,address,address)"), rid, "0x" + a[2:].zfill(64)]))
                    for role in ("PROPOSER_ROLE", "EXECUTOR_ROLE", "CANCELLER_ROLE"):
                        rid = roles[role]
                        logs.append(dict(blockNumber="0x1", logIndex=hex(len(logs)), topics=[digest("RoleGranted(bytes32,address,address)"), rid, "0x" + h[2:].zfill(64)]))
                        if h not in membership[rid]:
                            logs.append(dict(blockNumber="0x1", logIndex=hex(len(logs)), topics=[digest("RoleRevoked(bytes32,address,address)"), rid, "0x" + h[2:].zfill(64)]))
                    targets = [cfg["registry"], cfg["superPaymaster"], cfg["aPNTs"]] + [tl] * 7
                    data = [digest("acceptOwnership()")] * 3
                    data += [digest("|".join(["grantRole(bytes32,address)", roles[r], safe])) for r in role_names[1:]]
                    data += [digest("|".join(["revokeRole(bytes32,address)", roles[r], h])) for r in role_names[1:]]
                    data += [digest("updateDelay(uint256)|172800")]
                    for scheduled in (True, False):
                        topic = digest("CallScheduled(bytes32,uint256,address,uint256,bytes,bytes32,uint256)" if scheduled else "CallExecuted(bytes32,uint256,address,uint256,bytes)")
                        for i in range(10):
                            signature = "f(address,uint256,bytes,bytes32,uint256)" if scheduled else "f(address,uint256,bytes)"
                            payload = [targets[i], "0", data[i]] + (["0x" + "00" * 32, "0"] if scheduled else [])
                            logs.append(dict(blockNumber="0x2", logIndex=hex(len(logs)), topics=[topic, digest("operation"), hex(i)], data=digest("|".join([signature] + payload))))
                    if mutation == "extra_operation": logs.append(dict(logs[-1], topics=[logs[-1]["topics"][0], digest("other"), "0x0"]))
                    if mutation == "missing_execution": logs.pop()
                    if mutation == "wrong_batch": logs[-1]["data"] = "0x00"
                    out = json.dumps(logs)
            elif kind == "call":
                target, sig, *params = args
                if sig == "getThreshold()(uint256)": out = "1" if mutation == "threshold_one" else "2"
                elif sig == "getOwners()(address[])": out = "[" + addr(301) + ", " + addr(302) + "]"
                elif sig.startswith("hashOperationBatch"): out = digest("operation")
                elif sig == "isOperationDone(bytes32)(bool)": out = "true"
                elif sig == "allowance(address,address)(uint256)": out = "0"
                elif sig == "owner()(address)": out = deployer if target in (cfg["registryImpl"], cfg["spImpl"]) else safe if target == cfg["gToken"] else tl
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
                elif sig == "cap()(uint256)": out = str(2**200) if mutation in ("hex_numbers", "decimal_strings") else "1000"
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
                if isinstance(mutation, tuple):
                    key, changed_sig, changed_params, replacement = mutation
                    if target == cfg[key] and sig == changed_sig and params[:-2] == changed_params:
                        out = replacement
                        if sig == "getRoleConfig(bytes32)": out = "0x" + "0" * (64 * 11) + replacement[2:].zfill(64) + "0" * 64
            else: self.fail(f"Non-read-only command: {kind}")
            return SimpleNamespace(returncode=rc, stdout=out if rc == 0 else "", stderr=out if rc else "")
        output = io.StringIO()
        with patch.object(sys, "argv", [str(CHECKER), "https://secret.invalid/private-token", "fixture.json", deployer, safe] + (["--safe-recovery"] if safe_recovery else [])), patch("builtins.open", return_value=io.StringIO(json.dumps(cfg))), patch("subprocess.run", side_effect=fake_run), contextlib.redirect_stdout(output):
            with self.assertRaises(SystemExit) as caught:
                runpy.run_path(str(CHECKER), run_name="__main__")
        self.assertNotIn("private-token", output.getvalue())
        return caught.exception.code, output.getvalue()

    def test_complete_end_state(self):
        rc, out = self.run_checker()
        self.assertEqual(rc, 0, out)
        print(out.splitlines()[-1])

    def test_cancelled_recovery_rejected(self):
        self.assertEqual(self.run_checker(safe_recovery=True)[0], 1)

    def test_numeric_serializations(self):
        for mutation in ("hex_numbers", "decimal_strings"):
            self.assertEqual(self.run_checker(mutation)[0], 0)

    def test_new_guards(self):
        for mutation in ("half_handover", "wrong_deployer", "wrong_safe", "delegated_safe", "threshold_one", "extra_operation", "missing_execution", "wrong_batch", "implementation_unlocked", "absent_h"):
            with self.subTest(mutation=mutation):
                rc, out = self.run_checker(mutation)
                self.assertEqual(rc, 1, out)

    def test_every_handover_slot_rejects_deployer_and_wrong_party(self):
        slots = [(k, "owner()(address)", [], f"owner({k}) == expected") for k in "superPaymaster registry staking gToken xPNTsFactoryV2 aoaProtocolRegistry reputationSystem blsAggregator dvtValidator xPNTsFactory paymasterFactory paymasterV4Impl microPaymentChannel x402Facilitator aPNTs".split()]
        slots += [("registry", "getRoleConfig(bytes32)", [digest(r)], f"roleConfigs[{r}].owner == timelock") for r in "COMMUNITY ENDUSER PAYMASTER_AOA PAYMASTER_SUPER DVT ANODE KMS".split()]
        for k, sig, name in (("superPaymaster", "treasury", "SP.treasury"), ("staking", "treasury", "staking.treasury"), ("sbt", "daoMultisig", "MySBT.daoMultisig"), ("blsAggregator", "slashPolicyAdmin", "aggregator.slashPolicyAdmin"), ("superPaymaster", "guardian", "SP.guardian"), ("policyRegistry", "guardian", "PolicyRegistry.guardian"), ("policyRegistry", "timelock", "PolicyRegistry.timelock"), ("aPNTs", "minter", "APNTsCapped.minter"), ("aPNTs", "capGuardian", "APNTsCapped.capGuardian"), ("superPaymaster", "APNTS_TOKEN", "SP.APNTS_TOKEN"), ("paymasterFactory", "registry", "pmFactory.registry")):
            slots.append((k, sig + "()(address)", [], name + " == expected"))
        for key, sig, params, check in slots:
            for bad in (addr(201), addr(999)):
                with self.subTest(slot=check, bad=bad):
                    rc, out = self.run_checker((key, sig, params, bad))
                    self.assertEqual(rc, 1, out)
                    self.assertIn("FAIL  " + check, out)

    def test_each_scalar_final_state_slot(self):
        slots = [("timelockController", "getMinDelay()(uint256)", [], "TL.minDelay == expected"),
                 ("aPNTs", "cap()(uint256)", [], "APNTsCapped.cap == expected"),
                 ("superPaymaster", "priceStalenessThreshold()(uint256)", [], "SP.priceStalenessThreshold == expected"),
                 ("blsAggregator", "minThreshold()(uint256)", [], "agg.minThreshold == expected"),
                 ("blsAggregator", "defaultThreshold()(uint256)", [], "agg.defaultThreshold == expected")]
        slots += [("blsAggregator", "slashThresholds(uint8)(uint8)", [str(i)], f"agg.slashThresholds[{i}] == input") for i in range(3)]
        for key, sig, params, label in slots:
            with self.subTest(label=label):
                rc, out = self.run_checker((key, sig, params, "1"))
                self.assertEqual(rc, 1)
                self.assertIn("FAIL  " + label, out)

    def test_pending_owners_each_fail(self):
        for key in ("registry", "superPaymaster", "aPNTs"):
            with self.subTest(key=key):
                rc, out = self.run_checker((key, "pendingOwner()(address)", [], addr(999)))
                self.assertEqual(rc, 1)
                self.assertIn(f"FAIL  pendingOwner({key}) == 0", out)

    def test_residue_each_fails(self):
        for key, sig, params, label in (("gToken", "balanceOf(address)(uint256)", [addr(201)], "GToken balance"), ("gToken", "allowance(address,address)(uint256)", [addr(201), addr(3)], "GToken allowance"), ("sbt", "balanceOf(address)(uint256)", [addr(201)], "SBT balance")):
            with self.subTest(label=label):
                rc, out = self.run_checker((key, sig, params, "1"))
                self.assertEqual(rc, 1)
                self.assertIn("FAIL  deployer " + label + " == recorded", out)

    def test_each_timelock_role_slot(self):
        for role in ("DEFAULT_ADMIN_ROLE", "PROPOSER_ROLE", "EXECUTOR_ROLE", "CANCELLER_ROLE"):
            rid = "0x" + "00" * 32 if role == "DEFAULT_ADMIN_ROLE" else digest(role)
            with self.subTest(role=role):
                rc, out = self.run_checker(("timelockController", "hasRole(bytes32,address)(bool)", [rid, addr(200)], "true" if role == "DEFAULT_ADMIN_ROLE" else "false"))
                self.assertEqual(rc, 1)
                self.assertIn(f"FAIL  TL.{role}(safe) == expected", out)
        rc, out = self.run_checker(("timelockController", "hasRole(bytes32,address)(bool)", ["0x" + "00" * 32, addr(18)], "false"))
        self.assertEqual(rc, 1)
        self.assertIn("FAIL  TL.DEFAULT_ADMIN_ROLE(timelock) == true", out)

    def test_each_guardian_and_genesis_state(self):
        for i in (1, 2):
            rc, out = self.run_checker(("blsAggregator", "validatorAtSlot(uint8)(address)", [str(i)], addr(999)))
            self.assertEqual(rc, 1)
            self.assertIn(f"FAIL  guardian[{i}] registered", out)
        rc, out = self.run_checker(("superPaymaster", "operators(address)", [addr(21)], "0x" + "0" * 64 + f"{1:064x}" + "0" * (64 * 7)))
        self.assertEqual(rc, 1)
        self.assertIn("FAIL  genesis isConfigured == false", out)

    def test_intermediate_states_fail(self):
        for mutation in ("delay", "pending", "PROPOSER_ROLE", "EXECUTOR_ROLE", "CANCELLER_ROLE", "DEFAULT_ADMIN_ROLE", "unexpected_admin", "rpc_error"):
            with self.subTest(mutation=mutation):
                rc, out = self.run_checker(mutation)
                self.assertEqual(rc, 1, out)

if __name__ == "__main__":
    unittest.main()
