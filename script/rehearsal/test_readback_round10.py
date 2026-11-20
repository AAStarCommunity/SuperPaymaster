"""Offline Daybreak Round 10 regressions."""
import copy
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import deploylive_readback as r
import deploylive_runtime as runtime
import runtime_pins


class Round10(unittest.TestCase):
    def replay(self, method='eth_getCode', value='0x6000', other='0x6000', field=None, recorded_header=False, query=None):
        header = dict(number='0x2a', hash='0x'+'12'*32, timestamp='0x1234')
        forged = dict(header)
        if field: forged[field] = '0x2b' if field == 'number' else '0x1235'
        pin = json.dumps(dict(blockHash=header['hash'], requireCanonical=True))
        address = '0x'+'34'*20
        if method == 'eth_getLogs':
            args = (method, json.dumps(query or dict(address=address, fromBlock='0x0001', toBlock='0x002a', topics=['0xab'])))
        elif method == 'eth_call': args = (method, json.dumps(dict(to=address, data='0x12345678')), pin)
        elif method == 'eth_getStorageAt': args = (method, address, '0x0', pin)
        else: args = (method, address, pin)
        reads = {args: (0, json.dumps(value))}
        if recorded_header: reads[('eth_getBlockByNumber', '0x2a', 'false')] = (0, json.dumps(forged))
        def rpc(secondary):
            def call(*a):
                if a[0] == 'eth_getBlockByNumber':
                    h = dict(header if secondary or recorded_header else forged, number='0x1' if a[1] == '0x1' else header['number'])
                    if field == 'number' and not secondary and not recorded_header: h['number'] = forged['number']
                    return 0, json.dumps(h)
                return 0, json.dumps(other if secondary else value)
            return call
        return r.replay_snapshot(header if recorded_header else forged, reads, rpc(False), rpc(True), 'Infura')

    def test_data_leading_zero(self):
        for method in ('eth_getCode', 'eth_call', 'eth_getStorageAt'):
            with self.subTest(method=method), self.assertRaisesRegex(ValueError, 'mismatch'):
                value = '0x6000' if method == 'eth_getCode' else '0x60' + '00' * 31
                self.replay(method, value, '0x00' + value[2:])

    def test_log_data_and_topic_leading_zero(self):
        log = dict(blockNumber='0x1', blockHash='0x'+'12'*32, data='0xab', topics=['0x' + 'cd' * 32])
        for field in ('data', 'topics'):
            other = copy.deepcopy(log)
            other[field] = '0x00ab' if field == 'data' else ['0x00' + log['topics'][0][2:]]
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'mismatch'):
                self.replay('eth_getLogs', [log], [other])

    def test_quantity_leading_zero(self):
        self.assertTrue(self.replay('eth_getBalance', '0x0003', '0x3')['allEqual'])

    def test_primary_header_fields(self):
        for field in ('timestamp', 'number'):
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'header|canonical'):
                self.replay(field=field)

    def test_recorded_header_is_not_exempt(self):
        for field in ('timestamp', 'number'):
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, 'header|canonical'):
                self.replay(field=field, recorded_header=True)

    def test_log_diagnostic_query_identity(self):
        labels = []
        for topic in ('0xab', '0xcd'):
            with self.assertRaises(ValueError) as caught:
                self.replay('eth_getLogs', [], [dict(blockNumber='0x1', blockHash='0x'+'12'*32)], query=dict(address='0x'+'34'*20, fromBlock='0x0001', toBlock='0x002a', topics=[topic]))
            labels.append(str(caught.exception))
        for label in labels:
            self.assertIn('fromBlock=0x1 toBlock=0x2a topics=', label)
        self.assertNotEqual(*labels)

    def test_fixture_paths(self):
        with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[2] / 'cache') as tmp:
            root = Path(tmp)
            fixtures = root/'fixtures'; fixtures.mkdir()
            (root/'out').symlink_to(fixtures, target_is_directory=True)
            mixed = root/'Contracts'/'Test'/'build'; mixed.mkdir(parents=True)
            for path in (root/'out', mixed):
                for consumer in ('runtime', 'pins'):
                    with self.subTest(path=path.name, consumer=consumer), self.assertRaisesRegex(ValueError, 'fixture|symlink'):
                        if consumer == 'pins': runtime_pins.refuse_fixture_directory(path)
                        else:
                            with patch.object(runtime, 'ROOT', root), patch.dict('os.environ', DEFAULT_ARTIFACTS_OUT=str(path.relative_to(root))):
                                runtime.artifact_directory()


if __name__ == '__main__': unittest.main()
