"""Offline Round 9 regression tests."""
import unittest
import deploylive_readback as r


class Round9(unittest.TestCase):
    def test_wrong_suffix(self):
        with self.assertRaisesRegex(ValueError, 'provider.*binding'):
            r.independent_providers('Alchemy', 'Infura', 'https://rpc.infura.io/key', 'https://rpc.infura.io/other')

    def test_same_provider(self):
        with self.assertRaisesRegex(ValueError, 'distinct approved'):
            r.independent_providers('Alchemy', 'alchemy', 'https://a.alchemy.com', 'https://b.alchemy.com')

    def test_label_boundary(self):
        with self.assertRaisesRegex(ValueError, 'provider.*binding'):
            r.independent_providers('Alchemy', 'Infura', 'https://evilalchemy.com/key', 'https://rpc.infura.io/key')

    def test_trim_names(self):
        r.independent_providers('  ALCHEMY  ', '  Infura  ', 'https://ETH.alchemy.com/key', 'https://rpc.infura.io/key')
        self.assertEqual(r.provider_name('  Alchemy  '), 'alchemy')

    def test_nested_config(self):
        for value in ({'owners': ['0x' + '12' * 20]}, [[1]], [1]):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, 'nested config'):
                r.validate_config({'recovery': value}, {}, {}, [])

class Replay(unittest.TestCase):
    def setUp(self):
        import json
        self.json = json
        self.hash = '0x' + '12' * 32
        self.addr = '0x' + '34' * 20
        self.block = dict(number='42', hash=self.hash, timestamp='4660')
        self.pin = json.dumps(dict(blockHash=self.hash, requireCanonical=True))
        self.log = dict(blockNumber='0x1', blockHash=self.hash, address=self.addr, topics=['0xab'], data='0x00', logIndex='0x0')
        self.requests = [
            ('eth_call', json.dumps(dict(to=self.addr, data='0x12345678')), self.pin),
            ('eth_getStorageAt', self.addr, '0x7', self.pin),
            ('eth_getBalance', self.addr, self.pin),
            ('eth_getCode', self.addr, self.pin),
            ('eth_getLogs', json.dumps(dict(address=self.addr, fromBlock='0x1', toBlock='0x2a')))]
        self.values = ['0x01', '0x02', '0x03', '0x6000', [self.log]]

    def run_replay(self, mutation=None, side=1):
        reads = dict(zip(self.requests, [(0, self.json.dumps(v)) for v in self.values]))
        counts = [{}, {}]
        def rpc(provider):
            def read(*args):
                if args[0] == 'eth_getBlockByNumber':
                    n = args[1]; counts[provider][n] = counts[provider].get(n, 0) + 1
                    bad = provider == side and ((mutation == 'canonical' and n == '0x1') or (mutation == 'end' and n == '0x2a' and counts[provider][n] > 1))
                    return 0, self.json.dumps(dict(number=n, timestamp='0x1234', hash='0x'+'ff'*32 if bad else self.hash))
                self.assertIn(args, self.requests)
                value = self.values[self.requests.index(args)]
                if provider == side and args[0] == mutation:
                    value = [] if mutation == 'eth_getLogs' else '0xff'
                if provider == side and mutation == 'extra' and args[0] == 'eth_getLogs': value = value + value
                if mutation == 'equal' and args[0] == 'eth_getCode': value = '0x006000'
                if mutation == 'quantity_equal' and args[0] == 'eth_getBalance': value = '0x0003'
                if mutation == 'quantity_equal' and args[0] == 'eth_getLogs': value = [dict(reversed(list(dict(self.log, topics=['0xAB'], logIndex='0x0000').items())))]
                return 0, self.json.dumps(value)
            return read
        result = r.replay_snapshot(self.block, reads, rpc(0), rpc(1), 'Infura')
        self.assertEqual(result, dict(name='infura', requests=5, allEqual=True, blockHashMatches=True))
        for count in counts: self.assertEqual(count['0x1'], 1)

    def test_unreplayed_stateful_method_fails(self):
        # A recorded state read outside the replay set must not be skipped silently.
        self.requests.append(('eth_getTransactionCount', self.addr, self.pin)); self.values.append('0x5')
        with self.assertRaisesRegex(ValueError, 'unreplayed snapshot request: eth_getTransactionCount'): self.run_replay()

    def test_equal_replay_and_snapshot_hash(self):
        with self.assertRaisesRegex(ValueError, 'eth_getCode'): self.run_replay('equal')
    def test_quantity_equal_replay(self): self.run_replay('quantity_equal')
    def test_call_difference(self):
        with self.assertRaisesRegex(ValueError, 'eth_call.*'+self.addr+'.*0x12345678'): self.run_replay('eth_call')
    def test_storage_difference(self):
        with self.assertRaisesRegex(ValueError, 'eth_getStorageAt.*'+self.addr+'.*0x7'): self.run_replay('eth_getStorageAt')
    def test_balance_difference(self):
        with self.assertRaisesRegex(ValueError, 'eth_getBalance.*'+self.addr): self.run_replay('eth_getBalance')
    def test_code_difference(self):
        with self.assertRaisesRegex(ValueError, 'eth_getCode.*'+self.addr): self.run_replay('eth_getCode')
    def test_missing_log(self):
        with self.assertRaisesRegex(ValueError, 'eth_getLogs.*'+self.addr): self.run_replay('eth_getLogs')
    def test_extra_log(self):
        with self.assertRaisesRegex(ValueError, 'eth_getLogs.*'+self.addr): self.run_replay('extra')
    def test_log_canonical_hash_both_providers(self):
        for side in (0, 1):
            with self.subTest(side=side), self.assertRaisesRegex(ValueError, 'block 0x1'): self.run_replay('canonical', side)
    def test_range_end_changes_both_providers(self):
        for side in (0, 1):
            with self.subTest(side=side), self.assertRaisesRegex(ValueError, 'block 0x2a'): self.run_replay('end', side)

class CheckerReplay(unittest.TestCase):
    def test_secondary_call_is_replayed(self):
        from test_deploylive_postdeploy_check import CheckerTest
        rc, output = CheckerTest().run_checker('second_call', op=True)
        self.assertNotEqual(rc, 0, output)
        self.assertRegex(output, r'FAIL.*eth_call.*0x[0-9a-f]+.*0x[0-9a-f]{8}')
        self.assertNotIn('https://', output)


if __name__ == '__main__':
    unittest.main()
