"""Offline tests for pty_keystore_sign.py.

Never touches the real login keychain or a real keystore: a fake `security` and a fake
`cast` are written into a temp dir that is prepended to PATH. Run with
`python3 -m unittest script/a6-collector/test_pty_keystore_sign.py`.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HELPER = Path(__file__).resolve().parent / 'pty_keystore_sign.py'
PASSWORD = 'Pw-7f3c9a1e-SENTINEL-do-not-leak'
SIG = '0x' + 'ab' * 65
HASH = '0x' + '11' * 32

FAKES = Path(__file__).resolve().parent / 'pty-fakes'


class Env:
    def __init__(self, keychain):
        self.tmp = tempfile.TemporaryDirectory(prefix='pty-keystore-')
        self.dir = Path(self.tmp.name)
        (self.dir / 'records').mkdir()
        for name in ('security', 'cast'):
            p = self.dir / name
            p.write_text((FAKES / ('fake_%s.py' % name)).read_text())
            p.chmod(0o755)
        (self.dir / 'keychain.json').write_text(json.dumps(keychain))

    def run(self, account='rq3-bundler', mode='normal', extra=(), timeout=60):
        env = dict(os.environ, PATH='%s:%s' % (self.dir, os.environ['PATH']),
                   FAKE_DIR=str(self.dir), FAKE_CAST_MODE=mode, FAKE_CAST_SIG=SIG)
        argv = [sys.executable, '-I', '-B', str(HELPER), *extra,
                'cast', 'wallet', 'sign', '--account', account, '--no-hash', HASH]
        p = subprocess.run(argv, env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout)
        return p, argv, env

    def records(self, prefix):
        return [json.loads(p.read_text()) for p in sorted((self.dir / 'records').glob(prefix + '-*.json'))]

    def close(self):
        self.tmp.cleanup()


def assert_no_password(tc, *blobs):
    for blob in blobs:
        text = blob if isinstance(blob, str) else (blob.decode('utf8', 'replace') if isinstance(blob, bytes) else json.dumps(blob))
        tc.assertNotIn(PASSWORD, text)
        tc.assertNotIn(PASSWORD.encode().hex(), text)


class PtyKeystoreSignTest(unittest.TestCase):
    def setUp(self):
        self.env = Env({'aastar-rq3-keystore|rq3-bundler': PASSWORD})

    def tearDown(self):
        self.env.close()

    def test_a_password_written_once_only_after_echo_off(self):
        p, argv, env = self.env.run()
        self.assertEqual(p.returncode, 0)
        self.assertEqual(p.stdout, (SIG + '\n').encode())
        [cast] = self.env.records('cast')
        self.assertFalse(cast['early_input'], 'password arrived while ECHO was still on')
        import hashlib
        self.assertEqual(cast['password_sha256'], hashlib.sha256(PASSWORD.encode()).hexdigest())
        self.assertEqual(cast['argv'][1:], ['wallet', 'sign', '--account', 'rq3-bundler', '--no-hash', HASH])
        [sec] = self.env.records('security')
        self.assertEqual(sec['argv'][1:], ['find-generic-password', '-s', 'aastar-rq3-keystore', '-a', 'rq3-bundler', '-w'])

    def test_b_password_never_in_outputs_argv_or_env(self):
        for mode in ('normal', 'leaky', 'leaky-stdout', 'fail'):
            with self.subTest(mode=mode):
                for f in (self.env.dir / 'records').iterdir():
                    f.unlink()
                p, argv, env = self.env.run(mode=mode)
                assert_no_password(self, p.stdout, p.stderr, argv, env)
                self.assertEqual(p.returncode == 0, mode in ('normal', 'leaky'))
                if p.returncode == 0:
                    self.assertEqual(p.stdout, (SIG + '\n').encode())
                else:
                    self.assertEqual(p.stdout, b'')
                for r in self.env.records('cast') + self.env.records('security'):
                    assert_no_password(self, r['argv'], r['env'])

    def test_c_missing_keychain_entry_fails_closed_without_cast(self):
        p, _, _ = self.env.run(account='not-in-keychain')
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(p.stdout, b'')
        self.assertEqual(self.env.records('cast'), [], 'cast must not be spawned without a keychain entry')
        self.assertEqual(len(self.env.records('security')), 1)
        assert_no_password(self, p.stderr)
        self.assertNotIn(b'could not be found', p.stderr)

    def test_c_empty_keychain_entry_fails_closed(self):
        self.env.close()
        self.env = Env({'aastar-rq3-keystore|rq3-bundler': ''})
        p, _, _ = self.env.run()
        self.assertNotEqual(p.returncode, 0)
        self.assertEqual(self.env.records('cast'), [])

    def test_e_timeouts_fail_closed(self):
        for mode in ('noprompt', 'echo-stays-on', 'hang-after'):
            with self.subTest(mode=mode):
                for f in (self.env.dir / 'records').iterdir():
                    f.unlink()
                p, _, _ = self.env.run(mode=mode, extra=('--timeout', '2'), timeout=20)
                self.assertNotEqual(p.returncode, 0)
                self.assertEqual(p.stdout, b'')
                assert_no_password(self, p.stderr)
                [cast] = self.env.records('cast')
                if mode != 'hang-after':
                    self.assertNotIn('password_sha256', cast, 'password must not be written before prompt+ECHO off')

    def test_rejects_any_other_argv_shape(self):
        for bad in (['cast', 'wallet', 'sign', '--account', 'rq3-bundler', HASH],
                    ['sh', 'wallet', 'sign', '--account', 'rq3-bundler', '--no-hash', HASH],
                    ['cast', 'wallet', 'sign', '--account', 'rq3-bundler', '--no-hash', HASH, '--password', 'x'],
                    ['cast', 'wallet', 'sign', '--account', '../x', '--no-hash', HASH],
                    ['cast', 'wallet', 'sign', '--account', 'rq3-bundler', '--no-hash', '0x12']):
            with self.subTest(bad=bad):
                env = dict(os.environ, PATH='%s:%s' % (self.env.dir, os.environ['PATH']), FAKE_DIR=str(self.env.dir))
                p = subprocess.run([sys.executable, '-I', '-B', str(HELPER), *bad], env=env, stdin=subprocess.DEVNULL, capture_output=True, timeout=20)
                self.assertNotEqual(p.returncode, 0)
                self.assertEqual(self.env.records('security'), [])
                self.assertEqual(self.env.records('cast'), [])

    def test_helper_has_no_password_argv_or_env_input(self):
        src = HELPER.read_text()
        self.assertNotIn('os.environ', src)
        self.assertNotIn('getenv', src)
        self.assertNotIn('--password', src)


if __name__ == '__main__':
    unittest.main()
