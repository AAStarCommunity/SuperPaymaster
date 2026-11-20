"""Offline regressions for the remaining clestons low findings."""
import contextlib
import io
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import deploylive_controls as c
import test_ddf5 as fixture


class ClestonsLows(unittest.TestCase):
    setUp = fixture.Ddf5Test.setUp
    driver = fixture.Ddf5Test.driver

    def test_relative_checker_path_stops_before_forge_outside_root(self):
        pin = self.root/'cast-1.7.1'
        (self.root/'cast').rename(pin)
        with tempfile.TemporaryDirectory() as tmp:
            outside = Path(tmp)
            (outside/'relative').mkdir()
            (outside/'relative/cast').symlink_to(pin)
            original = Path.cwd()
            try:
                os.chdir(outside)
                with self.assertRaisesRegex(RuntimeError, r'STOP checker PATH entry 1.*relative'):
                    self.driver(env_overrides={'CAST_1_7_1': str(pin), 'PATH': 'relative:/usr/bin:/bin'})
            finally:
                os.chdir(original)
            self.assertEqual(self.calls, [])

    def test_empty_checker_path_stops_before_forge(self):
        for value, index in (('', 1), (':/usr/bin', 1), ('/usr/bin:', 2), ('/usr/bin::/bin', 2)):
            with self.subTest(path=value):
                with self.assertRaisesRegex(RuntimeError, f'STOP checker PATH entry {index}.*empty'):
                    self.driver(env_overrides={'PATH': value})
                self.assertEqual(self.calls, [])

    def test_malformed_postbroadcast_gas_stops_without_equal_line(self):
        output = io.StringIO()
        with patch.object(c, 'gas_changes', side_effect=ValueError('malformed gas')) as gas:
            with contextlib.redirect_stdout(output):
                with self.assertRaisesRegex(RuntimeError, 'malformed post-broadcast gas record; deployment NOT successful'):
                    self.driver(env_overrides={'PATH': '/usr/bin:/bin'})
            gas.assert_called_once()
        self.assertTrue(any('--broadcast' in cmd for cmd in self.calls))
        self.assertNotIn('limits equal', output.getvalue())
        self.assertFalse(hasattr(self, 'checker_env'))
