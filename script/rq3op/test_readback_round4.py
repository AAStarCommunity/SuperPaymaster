import os
import unittest
from unittest.mock import patch
from pinned_tools import PinnedTools

class EvidenceTest(unittest.TestCase):
    def setUp(self):
        import shutil
        self.enterContext(patch.dict("os.environ", CAST_1_7_1=shutil.which("cast")))

    def test_evidence_forwarded(self):
        with patch.dict(os.environ, DEPLOYLIVE_EVIDENCE_DIR='cache/readback/explicit'):
            self.assertEqual(PinnedTools().env.get('DEPLOYLIVE_EVIDENCE_DIR'), 'cache/readback/explicit')
