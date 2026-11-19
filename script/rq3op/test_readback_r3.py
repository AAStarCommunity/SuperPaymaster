import json
import unittest
from unittest.mock import patch
import plan_three_arm as q

class ExactReleaseTest(unittest.TestCase):
    def test_L1_extra_or_missing_release_rejected(self):
        versions = json.loads((q.ROOT/'deployments/release-versions.rc8.json').read_text())
        for altered in (dict(versions, Obsolete='old'), {k:v for k,v in versions.items() if k != 'GToken'}):
            with self.subTest(keys=sorted(altered)), patch.object(q, 'load', return_value=altered):
                with self.assertRaisesRegex(q.a.Gate, 'rq3_release_versions'):
                    q.verify_system({}, lambda *args: '0x6000', '0x20')
