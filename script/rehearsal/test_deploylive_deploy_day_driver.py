import deploylive_controls as controls
"""The actual driver must not report success merely because Forge wrote its config."""
import contextlib
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace
import deploylive_fork_deploy as f
import deploylive_deploy_day as d

(d.ROOT / 'cache/ddf').mkdir(parents=True, exist_ok=True)

class DriverTest(unittest.TestCase):
    def test_config_present_failing_checker(self):
        (d.ROOT/'cache/ddf').mkdir(parents=True, exist_ok=True)  # cache/ is gitignored: absent on a fresh checkout
        with tempfile.TemporaryDirectory(dir=d.ROOT/'cache/ddf') as tmp:
            root=Path(tmp)
            cfg=root/'config.json'; cfg.write_text('{}')
            stamp=root/'out.build-stamp.json'; stamp.write_text('{"forge":{}}')
            plan=root/'broadcast/DeployLive.s.sol/11155111/dry-run/run-latest.json'
            env=dict(DEPLOYLIVE_RPC='rpc', DEPLOYLIVE_SOURCE_RPC='rpc', DEPLOYLIVE_SECOND_RPC='other',
                     DEPLOYLIVE_HARDFORK='amsterdam', DEPLOYER_ACCOUNT='unused', GOVERNANCE_OWNER='safe',
                     DEPLOYLIVE_EVIDENCE_DIR=tmp, DEFAULT_ARTIFACTS_OUT=str(root/'out'))
            (root/'pop-request.json').write_text('{"pin":{"senders":{"deployer":{"nonce":0}}}}')
            (root/'guardians.hex').write_text('0x')
            calls=[]
            def run(command, **kwargs):
                calls.append(command)
                if 'script' in command:
                    plan.parent.mkdir(parents=True, exist_ok=True)
                    plan.write_text('{"transactions":[]}')
                    (plan.parent.parent/'run-latest.json').write_text(plan.read_text())
                    return SimpleNamespace(returncode=0, stdout='config written', stderr='')
                return SimpleNamespace(returncode=1, stdout='SUMMARY 187 passed, 1 failed, 188 total', stderr='')
            with patch.object(controls,'verify_manifest'), patch.object(controls,'verify_conversion',return_value='0x'), patch.object(controls,'deployment_rule'), patch.object(controls,'check_start_nonce'), patch.object(controls,'write_success'), patch.dict(os.environ, env), patch.object(sys, 'argv', ['driver','--production','deployer']), patch.object(f, 'ROOT', root), patch.object(f, 'clean_source_commit', return_value='a'*40), patch.object(f, 'guard_bls_verbosity'), patch.object(f, 'ReadOnlyRPC', return_value=lambda *a: '0xaa36a7'), patch.object(f, 'config_path', return_value=cfg), patch.object(f, 'build'), patch.object(f, 'verify_build', return_value='/forge'), patch.object(f, 'broadcast_gates', return_value=[]), patch.object(d, 'stamp_path', return_value=stamp), patch.object(f.subprocess, 'run', side_effect=run), contextlib.redirect_stdout(io.StringIO()) as output:
                with self.assertRaisesRegex(RuntimeError, 'checker'):
                    f.main()
                self.assertNotIn('PASS full deployment', output.getvalue())
                self.assertTrue(any('--broadcast' in c for c in calls))
