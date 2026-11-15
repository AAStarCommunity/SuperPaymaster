#!/usr/bin/env python3
"""Self-test for scripts/resolve_default_artifact.py (run: python3 -B scripts/test_resolve_default_artifact.py).

Each case builds a throwaway out/ tree in a temp directory. The positive control
(`test_picks_default_over_stale_unsuffixed`) is the rc.8 TimelockController shape: a
stale runs=200 `X.json` next to the real `X.default.json`.
"""
import importlib.util
import json
import os
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("resolver", os.path.join(HERE, "resolve_default_artifact.py"))
R = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(R)

SRC = "contracts/src/core/Widget.sol"
DEP = "contracts/src/core/WidgetBase.sol"


class ResolverTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.cwd = os.getcwd()
        os.chdir(self.tmp.name)
        os.makedirs("contracts/src/core")
        for path, body in ((SRC, b"contract Widget {}\n"), (DEP, b"contract WidgetBase {}\n")):
            with open(path, "wb") as fh:
                fh.write(body)
        R.SOURCES["Widget"] = SRC
        R._source_hash.clear()

    def tearDown(self):
        os.chdir(self.cwd)
        R.SOURCES.pop("Widget", None)
        R._source_hash.clear()
        self.tmp.cleanup()

    def artifact(self, rel, runs=500, evm="cancun", via_ir=True, solc="0.8.33+commit.x", code="0xaa",
                 src_hash=None, dep_hash=None):
        def h(p):
            with open(p, "rb") as fh:
                return "0x" + R.keccak256(fh.read())
        md = {
            "compiler": {"version": solc},
            "settings": {"compilationTarget": {SRC: "Widget"}, "optimizer": {"enabled": True, "runs": runs},
                         "viaIR": via_ir, "evmVersion": evm},
            "sources": {SRC: {"keccak256": src_hash or h(SRC)}, DEP: {"keccak256": dep_hash or h(DEP)}},
        }
        path = os.path.join("out", rel)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as fh:
            json.dump({"metadata": md, "deployedBytecode": {"object": code}}, fh)
        return path

    def test_picks_default_over_stale_unsuffixed(self):
        self.artifact("Widget.sol/Widget.json", runs=200, code="0x200")
        want = self.artifact("Widget.sol/Widget.default.json", runs=500, code="0x500")
        self.assertEqual(R.resolve("Widget"), (want, None))

    def test_registry_expects_its_restricted_runs(self):
        R.SOURCES["Registry"] = SRC
        try:
            self.artifact("Widget.sol/Registry.json", runs=500, code="0x500")
            want = self.artifact("Widget.sol/Registry.default.json", runs=200, code="0x200")
            self.assertEqual(R.resolve("Registry"), (want, None))
        finally:
            R.SOURCES["Registry"] = "contracts/src/core/Registry.sol"

    def test_prague_rebuild_is_not_default(self):
        self.artifact("Widget.sol/Widget.json", evm="prague")
        path, why = R.resolve("Widget")
        self.assertIsNone(path)
        self.assertIn("no profile.default build", why)

    def test_identical_copies_are_one_build(self):
        want = self.artifact("Widget.sol/Widget.json", code="0x500")
        self.artifact("Widget.sol/Widget.default.json", code="0x500")
        self.assertEqual(R.resolve("Widget"), (want, None))

    def test_two_different_default_builds_fail(self):
        self.artifact("Widget.sol/Widget.json", code="0x01")
        self.artifact("core/Widget.sol/Widget.default.json", code="0x02")
        path, why = R.resolve("Widget")
        self.assertIsNone(path)
        self.assertIn("ambiguous", why)

    def test_stale_import_is_rejected(self):
        self.artifact("Widget.sol/Widget.json", dep_hash="0x" + "00" * 32)
        self.assertIsNone(R.resolve("Widget")[0])

    def test_each_setting_is_checked(self):
        for kw in ({"via_ir": False}, {"solc": "0.8.30+commit.y"}, {"runs": 10000}):
            with self.subTest(**kw):
                self.artifact("Widget.sol/Widget.json", **kw)
                self.assertIsNone(R.resolve("Widget")[0])

    def test_unmapped_name_fails(self):
        path, why = R.resolve("NoSuchContract")
        self.assertIsNone(path)
        self.assertIn("no source mapping", why)

    def test_cli_exit_code_and_json(self):
        self.artifact("Widget.sol/Widget.default.json")
        self.assertEqual(R.main(["Widget"]), 0)
        self.assertEqual(R.main(["Widget", "NoSuchContract"]), 1)

    def test_pure_keccak_vectors(self):
        self.assertEqual(R.keccak256(b""), "c5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470")
        self.assertEqual(R.keccak256(b"abc"), "4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45")


if __name__ == "__main__":
    unittest.main()
