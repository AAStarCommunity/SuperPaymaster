"""The planner and its checker runner retain the operator's stable cast pin."""
import os
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch
from pinned_tools import PinnedTools
import test_checker_integration as fixture

class PlannerCastPin(unittest.TestCase):
    def test_checker_subprocess_resolves_stable_cast(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name, version in (('nightly', '1.7.1-nightly'), ('stable', '1.7.1-stable')):
                tool = root/name/'cast'; tool.parent.mkdir()
                tool.write_text('#!/bin/sh\necho "cast Version: '+version+'"\n'); tool.chmod(0o755)
            stable = str(root/'stable'/'cast')
            with patch.dict(os.environ, CAST_1_7_1=stable, PATH=str(root/'nightly')+os.pathsep+os.environ['PATH']):
                tools = PinnedTools()
            tools.env.update(DEPLOYLIVE_SECOND_RPC_FILE='unused', DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER='Infura')
            case = fixture.CheckerIntegration(); case.invoke(tools)
            env = case.calls[0][1]['env']
            self.assertEqual(shutil.which('cast', path=env['PATH']), stable)
            self.assertEqual(env['CAST_1_7_1'], stable)
            with patch.dict(os.environ, env, clear=True):
                child = PinnedTools()
            result = child.run(['cast', '--version'], capture_output=True, text=True)
            self.assertEqual(result.stdout.strip(), 'cast Version: 1.7.1-stable')
            checker = Path(__file__).resolve().parents[1]/'rehearsal/deploylive_postdeploy_check.py'
            result = child.run([sys.executable, '-B', str(checker)], capture_output=True, text=True)
            self.assertEqual(result.stdout, 'FAIL unknown checker option or missing arguments\n')
