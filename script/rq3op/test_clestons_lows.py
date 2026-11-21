"""Raw, pre-normalization config binding for timelock and shared output."""
import hashlib
import json
import unittest
import test_three_arm as fixture
from test_three_arm import q, a


class ClestonsLows(unittest.TestCase):
    setUp = fixture.ThreeArm.setUp
    build = fixture.ThreeArm.build

    def test_raw_config_digest_binds_timelock_salt_and_shared(self):
        for key in q.CONFIG_ADDRESSES:
            self.cfg[key] = a.cast('to-check-sum-address', self.cfg[key])
        self.assertTrue(any(value != value.lower() for key, value in self.cfg.items() if key in q.CONFIG_ADDRESSES))
        raw = json.dumps(self.cfg, sort_keys=True, separators=(',', ':')).encode()
        raw_digest = hashlib.sha256(raw).hexdigest()
        normalized, _ = q.normalized_addresses(self.cfg, self.inputs)
        self.assertNotEqual(raw_digest, q.digest(normalized))
        self.evidence['configSha256'] = raw_digest
        result = self.build()
        expected_salt = a.keccak('rq3/' + raw_digest + '/' + q.digest(self.inputs))
        with self.subTest(field='timelockOperation.salt'):
            self.assertEqual(result['timelockOperation']['salt'], expected_salt)
        with self.subTest(field='shared.configSha256'):
            self.assertEqual(result['shared']['configSha256'], raw_digest)
