import importlib
import unittest


class ReadbackTest(unittest.TestCase):
    def test_addresses_and_unreadable(self):
        m = importlib.import_module('deploylive_readback')
        address = '0x' + '12' * 20
        abi = [{'type': 'function', 'name': name, 'inputs': [], 'stateMutability': 'view',
                'outputs': [{'type': 'address'}]} for name in ('target', 'reverting')]
        def read(sig):
            if sig.startswith('reverting'): raise ValueError('reverted')
            return [address]
        values, unreadable = m.address_getters(abi, read, {})
        self.assertEqual(values['target'], {'value': address, 'resolvesTo': None})
        self.assertEqual(values['reverting'], {'value': None, 'resolvesTo': None})
        self.assertEqual(unreadable, ['reverting'])

    def test_tuple_array_shape(self):
        m = importlib.import_module('deploylive_readback')
        address = '0x' + '12' * 20
        field = {'type': 'tuple[]', 'components': [{'name': 'who', 'type': 'address'}, {'name': 'count', 'type': 'uint256'}]}
        self.assertEqual(m.project(field, [[address, 7]], {address: 'config:registry'}),
                         ([{'who': address}], [{'who': 'config:registry'}]))

    def test_provider_rejects_url(self):
        m = importlib.import_module('deploylive_readback')
        with self.assertRaises(ValueError): m.provider_name('https://private.invalid')
        self.assertEqual(m.provider_name('Alchemy'), 'Alchemy')

class ArchiveReadbackTest(unittest.TestCase):
    def test_changed_readback_refused(self):
        import tempfile
        import json
        from pathlib import Path
        from unittest.mock import patch
        import deploylive_controls as c
        with tempfile.TemporaryDirectory(dir=c.ROOT/'cache') as tmp:
            root = Path(tmp)
            config, broadcast = root/'config.json', root/'broadcast.json'
            for p in (config, broadcast, root/'readback.json', root/'gated-plan.json'): p.write_text('{}')
            with patch.object(c, 'manifest_digest', return_value='manifest'):
                c.write_success(root, {'ENV': 'test'}, config, broadcast, {})
                (root/'readback.json').write_text('{"changed": true}')
                with self.assertRaisesRegex(RuntimeError, 'readback.*changed|record changed'):
                    c.archive_records(root)

class RuntimeRowsTest(unittest.TestCase):
    def test_new_contract_bad_runtime_fails(self):
        m = importlib.import_module('deploylive_readback')
        from runtime_pins import runtime_pin
        pin = runtime_pin({'object': '0x600000', 'immutableReferences': {'1': [{'start': 1, 'length': 1}]}}, 500)
        rows = m.runtime_rows({'staking': '0x' + '12' * 20}, {'staking': 'GTokenStaking'},
                              {'GTokenStaking': pin}, lambda address: '0x61aa00')
        self.assertEqual(rows, [('staking', False)])

class CollectTest(unittest.TestCase):
    def test_complete_readback(self):
        import json
        import tempfile
        from pathlib import Path
        from unittest.mock import patch
        import deploylive_readback as m
        from runtime_pins import runtime_pin
        mapping = json.loads((m.ROOT/'deployments/readback-artifacts.json').read_text())
        config = {key: '0x' + f'{i + 1:040x}' for i, key in enumerate(mapping)}
        config.update(commit='a'*40, governanceOwner='0x' + '12'*20)
        abi = [{'type': 'function', 'name': name, 'inputs': [], 'outputs': [{'type': 'address'}], 'stateMutability': 'view'} for name in ('owner', 'reverting', 'unknown')]
        abi += [{'type': 'function', 'name': 'version', 'inputs': [], 'outputs': [{'type': 'string'}], 'stateMutability': 'pure'}]
        def cast(kind, *args):
            if kind == 'code': return 0, '0x6000'
            if kind == 'storage': return 0, '0x' + '00'*32
            if kind == 'decode-abi': return 0, args[1]
            if kind == 'call':
                sig = args[1]
                if sig == 'reverting()': return 1, 'revert'
                value = 'fixture' if sig == 'version()' else 4200 if sig in ('priceStalenessThreshold()', 'getMinDelay()') else '0x' + '34'*20 if sig == 'unknown()' else config['governanceOwner']
                return 0, json.dumps([value])
            self.fail(kind)
        with tempfile.TemporaryDirectory(dir=m.ROOT/'cache') as tmp:
            cfg, pins, output = [Path(tmp)/n for n in ('config.json', 'pins.json', 'readback.json')]
            cfg.write_text(json.dumps(config))
            pin = runtime_pin({'object': '0x6000'}, 500)
            pins.write_text(json.dumps({'artifacts': {name: pin for name in mapping.values() if name}}))
            with patch.object(m, 'release_artifact', return_value={'abi': abi}):
                result = m.collect(cfg, config, 31337, dict(number='0x2a', hash='0x'+'12'*32, timestamp='0x1234'), 'Fixture', {}, pins, cast)
            m.write(output, result)
            self.assertEqual(result['schema'], 'deploylive-readback/1')
            self.assertEqual({r['configKey'] for r in result['contracts']}, set(mapping))
            for item in result['contracts']:
                if item['configKey'] == 'spAdminImpl':
                    for field in ('immutables', 'version', 'addressGetters', 'unreadable'): self.assertIsNone(item[field])
                if item['artifact']:
                    self.assertTrue(item['maskedMatchesPin'])
                    self.assertEqual(item['addressGetters']['unknown']['resolvesTo'], None)
                    self.assertEqual(item['unreadable'], ['reverting'])
                if item['configKey'] in ('superPaymaster', 'registry'): self.assertTrue(item['addressGetters'])
            self.assertEqual(result['chainId'], '31337')
            self.assertEqual(result['block']['number'], '42')
            self.assertEqual(result['wiring']['TL.minDelay'], '4200')
            self.assertNotIn('://', output.read_text())
