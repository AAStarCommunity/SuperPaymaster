"""Test-only driver: inject fake executables through internal function parameters."""
import importlib.util
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location('helper', Path(__file__).resolve().parents[1] / 'pty_keystore_sign.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
try:
    timeout, argv = helper.parse(sys.argv[2:])
    signature = helper.sign(timeout, argv, security_path=sys.argv[1])
except helper.Fail as e:
    sys.stderr.write('pty keystore signing failed: %s\n' % e.stage)
    sys.exit(e.code)
sys.stdout.write(signature.decode('ascii'))
