#!/usr/bin/env python3
"""Negative controls for scripts/check_generic_selector_coverage.py (run: python3 -B scripts/test_check_generic_selector_coverage.py).

Each case copies the inputs the checker reads into a temp tree, applies one mutation that must be
caught (the counterexamples from the #633 Codex review among them), and asserts the checker fails
with the expected message. The unmutated copy must pass, so a red case is the mutation, not the copy.
"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHECK = ROOT / "scripts" / "check_generic_selector_coverage.py"
COPY = ["abis", "contracts/src", "contracts/script", "script/upgrade/manifest_exec.py"]
DL = "contracts/script/v3/DeployLive.s.sol"
ANCHOR = "        registry.setBLSAggregator(address(aggregator));\n"


def run_on(mutate):
    with tempfile.TemporaryDirectory() as tmp:
        for rel in COPY:
            src, dst = ROOT / rel, Path(tmp) / rel
            dst.parent.mkdir(parents=True, exist_ok=True)
            (shutil.copytree if src.is_dir() else shutil.copy)(src, dst)
        if mutate:
            mutate(Path(tmp))
        env = dict(os.environ, COVERAGE_CHECK_ROOT=tmp)
        r = subprocess.run([sys.executable, "-B", str(CHECK)], capture_output=True, text=True, env=env)
        return r.returncode, r.stdout + r.stderr


def edit(rel, old, new):
    def f(tmp):
        p = tmp / rel
        s = p.read_text()
        assert s.count(old) >= 1, f"anchor not found in {rel}: {old!r}"
        p.write_text(s.replace(old, new, 1))
    return f


def insert_dl(code):
    return edit(DL, ANCHOR, ANCHOR + code)


class NegativeControls(unittest.TestCase):
    def assertCaught(self, mutate, needle):
        rc, out = run_on(mutate)
        self.assertNotEqual(rc, 0, out)
        self.assertIn(needle, out, out)

    def test_unmutated_copy_passes(self):
        rc, out = run_on(None)
        self.assertEqual(rc, 0, out)

    def test_known_setter_on_unknown_receiver(self):
        self.assertCaught(insert_dl("        other.setReputationSource(address(aggregator), true);\n"),
                          "not a known contract")

    def test_unknown_identity_grant(self):
        self.assertCaught(insert_dl("        gtoken.setMinter(address(aggregator), true);\n"),
                          "grants an identity this check does not know")

    def test_ownership_via_alias(self):
        self.assertCaught(insert_dl("        address recipient = address(aggregator);\n"
                                    "        repSystem.transferOwnership(recipient);\n"), "transferOwnership")

    def test_ownership_via_encode_call(self):
        self.assertCaught(insert_dl("        (bool ok,) = address(repSystem).call(abi.encodeCall(Ownable.transferOwnership,"
                                    " (address(aggregator)))); ok;\n"), "transferOwnership")

    def test_owner_constructor_arg_multiline(self):
        self.assertCaught(insert_dl("        _deployDefault(\n            \"MicroPaymentChannel\", abi.encode(address(aggregator))\n        );\n"),
                          "initialOwner")

    def test_owner_helper_param(self):
        self.assertCaught(insert_dl("        _deployV54Contracts(address(registry), address(superPaymaster), address(xpntsFactory),"
                                    " address(aggregator), deployer, address(0));\n"), "governor")

    def test_python_multiline_grant(self):
        self.assertCaught(edit("script/upgrade/manifest_exec.py", "    inventory = pin['guardianInventory']\n",
                               "    call('X', u.REG, 'setAuthorizedSlasher(address,bool)',\n        (agg, 'true'), [])\n"
                               "    inventory = pin['guardianInventory']\n"), "lives on")

    def test_slasher_via_alias(self):
        self.assertCaught(insert_dl("        address recipient = address(aggregator);\n"
                                    "        staking.setAuthorizedSlasher(recipient, true);\n"), "no slasher role")

    def test_community_reputation_reader_on_write_line(self):
        self.assertCaught(edit("contracts/src/modules/reputation/ReputationSystem.sol",
                               "communityReputations[community][user] = score;",
                               "communityReputations[community][user] = score; entropyFactors[community] = "
                               "communityReputations[community][user];"), "reads communityReputations")

    def test_denylist_entry_removed(self):
        self.assertCaught(edit("contracts/src/modules/monitoring/BLSAggregator.sol",
                               'bytes4 private constant SEL_STAKING_SLASH_BY_DVT', 'bytes4 private constant X_STAKING_SLASH_BY_DVT'),
                          "missing from the H-1 denylist")


if __name__ == "__main__":
    unittest.main()
