"""Synthetic binding checks and a real DVT encoding seam; no pairing or RPC."""
import copy
import hashlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import pop_adapter as p


class RealDvtExportTests(unittest.TestCase):
    def setUp(self):
        self.path = Path(__file__).with_name('fixtures')/'dvt-pop-rehearsal'/'rehearse-pop.json'
        self.sha256 = '305f1513034d0afa953ed34f01b8db4116540966da1e87c321715d94631162a7'
        raw = self.path.read_bytes()
        # Verify provenance before parsing or deriving any expectations.
        self.assertEqual(hashlib.sha256(raw).hexdigest(), self.sha256)
        self.export = json.loads(raw)
        self.assertEqual(self.export['owner'].lower(), p.m.u.DEPLOYER)
        guardians = {item['slot']: item['validator'].lower()
                     for item in self.export['registrations']}
        self.assertEqual(guardians, p.GUARDIANS)
        self.pin = dict(blockHash='0x'+'11'*32, guardianInventory=[
            dict(slot=i, validator=guardians.get(i, p.m.a.ZERO)) for i in range(1, 14)])
        self.source = dict(plan=dict(stage='a7', final=False, pin=copy.deepcopy(self.pin),
            addresses=dict(BLSAggregator=self.export['aggregator']),
            expectedDomainSeparator=self.export['domainSeparator'], prefixDigest='33'*32),
            readback=dict(prefixDigest='33'*32, domainSeparator=self.export['domainSeparator']))

    def adapt(self):
        return p.adapt(self.path, pin=self.pin, stage_source=self.source, tool_commit='a'*40)

    def test_real_export_encoding_seam(self):
        for item in self.export['registrations']:
            with self.subTest(slot=item['slot']):
                encoded = bytes.fromhex(p.encode_registration(item['validator'], item['publicKey'],
                    item['slot'], item['popSignature'])[2:])
                exported = bytes.fromhex(item['calldata'][2:])
                differences = [(offset, exported[offset:offset+1].hex(), encoded[offset:offset+1].hex())
                               for offset in range(max(len(exported), len(encoded)))
                               if exported[offset:offset+1] != encoded[offset:offset+1]]
                self.assertFalse(differences,
                    'calldata differences (zero-based byte offset, DVT byte, adapter byte): '+str(differences))
                self.assertEqual(len(encoded), 4+14*32)
        result = self.adapt()
        self.assertEqual(result['exportSha256'], self.sha256)
        self.assertEqual(len(result['pop']), 3)
        for actual, exported in zip(result['pop'], self.export['registrations']):
            self.assertEqual(actual, dict(validator=exported['validator'].lower(), slot=exported['slot'],
                calldata=exported['calldata'], aggregator=self.export['aggregator'],
                domainSeparator=self.export['domainSeparator'], pinBlockHash=self.pin['blockHash']))

    def test_real_export_rejects_different_plan_a7(self):
        self.source['plan']['addresses']['BLSAggregator'] = '0x'+'77'*20
        with self.assertRaisesRegex(p.Stop, '^STOP: aggregator$'):
            self.adapt()

    def test_real_export_rejects_different_stage_readback(self):
        self.source['readback']['domainSeparator'] = '0x'+'77'*32
        with self.assertRaisesRegex(p.Stop, '^STOP: stage_domain$'):
            self.adapt()

    def test_real_export_rejects_different_expected_and_readback_domain(self):
        self.source['plan']['expectedDomainSeparator'] = '0x'+'77'*32
        self.source['readback']['domainSeparator'] = '0x'+'77'*32
        with self.assertRaisesRegex(p.Stop, '^STOP: domain$'):
            self.adapt()


class PopAdapterTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)/'export.json'
        self.pin = dict(blockHash='0x'+'11'*32, guardianInventory=[
            dict(slot=i, validator=p.GUARDIANS.get(i, p.m.a.ZERO)) for i in range(1, 14)])
        self.source = dict(plan=dict(stage='a7', final=False, pin=copy.deepcopy(self.pin),
            addresses=dict(BLSAggregator='0x'+'ab'*20), expectedDomainSeparator='0x'+'22'*32,
            prefixDigest='33'*32), readback=dict(prefixDigest='33'*32, domainSeparator='0x'+'22'*32))
        self.export = dict(chainId=11155111, aggregator='0x'+'ab'*20,
            version='BLSAggregator-4.12.0', owner=p.m.u.DEPLOYER,
            domainSeparator='0x'+'22'*32, block=999, registrations=[])
        for slot, who in p.GUARDIANS.items():
            key = ['0x'+format(slot*10+i, '064x') for i in range(4)]
            sig = ['0x'+format(slot*100+i, '064x') for i in range(8)]
            # Independent static ABI construction, not the adapter's encoder.
            data = '0xaded17c5'+who[2:].zfill(64)+''.join(x[2:] for x in key)+format(slot, '064x')+''.join(x[2:] for x in sig)
            self.export['registrations'].append(dict(validator=who, slot=slot, publicKey=key,
                popSignature=sig, popDigest='0x'+'44'*32, calldata=data))
        self.commit = 'a'*40

    def run_adapter(self):
        self.path.write_text(json.dumps(self.export)+'\n')
        return p.adapt(self.path, pin=self.pin, stage_source=self.source, tool_commit=self.commit)

    def test_happy_path(self):
        self.export['registrations'].reverse()
        self.export['aggregator'] = '0x'+self.export['aggregator'][2:].upper()
        self.export['pinBlockHash'] = '0x'+'ff'*32
        result = self.run_adapter()
        self.assertEqual(result['exportSha256'], hashlib.sha256(self.path.read_bytes()).hexdigest())
        self.assertEqual(result['toolCommit'], self.commit)
        self.assertEqual([x['slot'] for x in result['pop']], [1, 2, 3])
        for item in result['pop']:
            self.assertEqual(set(item), {'validator', 'slot', 'calldata', 'aggregator', 'pinBlockHash', 'domainSeparator'})
            self.assertEqual(item['pinBlockHash'], self.pin['blockHash'])
            self.assertEqual(item['domainSeparator'], self.source['readback']['domainSeparator'])
            self.assertEqual(item['aggregator'], self.source['plan']['addresses']['BLSAggregator'])

    def test_cli(self):
        expected = self.run_adapter()
        pin, source, out = [Path(self.tmp.name)/name for name in ('pin.json', 'source.json', 'out.json')]
        pin.write_text(json.dumps(self.pin))
        source.write_text(json.dumps(self.source))
        args = ['--export', str(self.path), '--pin', str(pin), '--a7-source', str(source),
                '--tool-commit', self.commit, '--out', str(out)]
        self.assertEqual(p.main(args), 0)
        self.assertEqual(json.loads(out.read_text()), expected)
        out.unlink()
        self.path.write_text('{}')
        with patch('sys.stderr', new_callable=io.StringIO) as stderr:
            self.assertEqual(p.main(args), 1)
            self.assertIn('STOP:', stderr.getvalue())
        self.assertFalse(out.exists())

    def cli_files(self):
        self.path.write_text(json.dumps(self.export))
        pin, source, out = [Path(self.tmp.name)/name for name in ('pin.json', 'source.json', 'out.json')]
        pin.write_text(json.dumps(self.pin))
        source.write_text(json.dumps(self.source))
        args = ['--export', str(self.path), '--pin', str(pin), '--a7-source', str(source),
                '--tool-commit', self.commit, '--out', str(out)]
        return args, (self.path, pin, source), out

    def test_duplicate_json_keys(self):
        args, inputs, out = self.cli_files()
        for path in inputs:
            original = path.read_text()
            for extra in ('"duplicate":1,"duplicate":2,',
                          '"extra":{"nested":[{"x":1,"x":2}]},',
                          '"extra":{"x":1,"\\u0078":2},'):
                with self.subTest(path=path.name, extra=extra):
                    path.write_text('{'+extra+original[1:])
                    with patch('sys.stderr', new_callable=io.StringIO) as stderr:
                        self.assertEqual(p.main(args), 1)
                        self.assertIn('STOP: duplicate_json_key', stderr.getvalue())
                    self.assertFalse(out.exists())
            path.write_text(original)

    def test_deep_json_stops(self):
        args, inputs, out = self.cli_files()
        for path in inputs:
            original = path.read_text()
            path.write_text('{"extra":'+'['*100+'0'+']'*100+','+original[1:])
            with self.subTest(path=path.name), patch('sys.stderr', new_callable=io.StringIO) as stderr:
                self.assertEqual(p.main(args), 1)
                self.assertIn('STOP:', stderr.getvalue())
                self.assertNotIn('Traceback', stderr.getvalue())
                self.assertFalse(out.exists())
            path.write_text(original)
        self.path.write_text('['*2000+'0'+']'*2000)
        with self.assertRaisesRegex(p.Stop, 'STOP:'):
            p.adapt(self.path, pin=self.pin, stage_source=self.source, tool_commit=self.commit)

    def test_json_depth_bound_is_interpreter_independent(self):
        # 3.12's decoder parses this without RecursionError; the explicit bound must still stop it.
        for depth, ok in ((p.MAX_JSON_DEPTH, True), (p.MAX_JSON_DEPTH+1, False), (25000, False)):
            raw = '['*depth+'0'+']'*depth
            with self.subTest(depth=depth):
                if ok:
                    self.assertEqual(p.json_depth(raw), depth)
                    p.load_json(raw)
                else:
                    with self.assertRaisesRegex(p.Stop, '^STOP: json_nesting$'):
                        p.load_json(raw)
        # Brackets inside strings, including escaped quotes, do not count.
        self.assertEqual(p.json_depth('{"a":"[[[\\"[[[","b":[1]}'), 2)
        with self.assertRaisesRegex(p.Stop, '^STOP: json_encoding$'):
            p.load_json(b'\xff')

    def test_mutants_record_matches_source(self):
        record = json.loads((Path(p.__file__).parent/'POP-ADAPTER-MUTANTS.json').read_text())
        self.assertEqual(record['sourceSha256'], hashlib.sha256(Path(p.__file__).read_bytes()).hexdigest())

    def test_export_block_recorded(self):
        for block in (0, 999):
            self.export['block'] = block
            self.assertEqual(self.run_adapter().get('exportBlock'), block)

    def test_export_block_fork_boundary(self):
        for block in (999, '0x3e7'):
            self.pin['block'] = block
            self.source['plan']['pin'] = copy.deepcopy(self.pin)
            for exported in (999, 1000):
                self.export['block'] = exported
                self.run_adapter()
            self.export['block'] = 998
            with self.assertRaisesRegex(p.Stop, 'STOP: export_block_before_fork'):
                self.run_adapter()

    def test_invalid_fork_block(self):
        for block in (-1, True, 1.5, None, 'bad'):
            self.pin['block'] = block
            self.source['plan']['pin'] = copy.deepcopy(self.pin)
            with self.subTest(block=block), self.assertRaisesRegex(p.Stop, 'STOP: fork_block'):
                self.run_adapter()

    def test_atomic_output_failures(self):
        args, inputs, out = self.cli_files()
        real_replace = p.os.replace
        real_fdopen = p.os.fdopen
        def partial_file(*args, **kwargs):
            output = real_fdopen(*args, **kwargs)
            write = output.write
            def fail(text):
                write(text[:10])
                output.flush()
                raise OSError('partial write')
            output.write = fail
            return output
        def fail_replace(src, dst):
            self.assertEqual(Path(src).parent, out.parent)
            self.assertEqual(json.loads(Path(src).read_text())['exportBlock'], 999)
            raise OSError('replace failed')
        for existing in (False, True):
            for target, effect in (('os.fdopen', partial_file),
                                   ('os.fsync', OSError('flush failed')),
                                   ('os.replace', fail_replace)):
                with self.subTest(existing=existing, target=target):
                    out.unlink(missing_ok=True)
                    if existing:
                        out.write_bytes(b'previous output')
                    before = set(out.parent.iterdir())
                    with patch('pop_adapter.'+target, side_effect=effect), \
                         patch('sys.stderr', new_callable=io.StringIO) as stderr:
                        self.assertEqual(p.main(args), 1)
                        self.assertIn('STOP:', stderr.getvalue())
                    self.assertEqual(set(out.parent.iterdir()), before)
                    self.assertEqual(out.read_bytes() if existing else out.exists(),
                                     b'previous output' if existing else False)
        with patch('pop_adapter.os.replace', wraps=real_replace) as replace:
            self.assertEqual(p.main(args), 0)
            self.assertEqual(replace.call_count, 1)
        self.assertEqual(json.loads(out.read_text())['exportBlock'], 999)

    def test_readme_trust_boundary(self):
        readme = ' '.join(Path(__file__).with_name('README.md').read_text().split())
        self.assertIn("consistency of calldata with the export's own fields", readme)
        self.assertIn('not authenticity of the key or signature', readme)
        self.assertIn('stage simulate and A10 read-back', readme)

    def test_missing_fields(self):
        original = copy.deepcopy(self.export)
        for key in original:
            with self.subTest(key=key), self.assertRaisesRegex(p.Stop, 'STOP:'):
                self.export = copy.deepcopy(original)
                del self.export[key]
                self.run_adapter()
        for key in original['registrations'][0]:
            with self.subTest(key=key), self.assertRaisesRegex(p.Stop, 'STOP:'):
                self.export = copy.deepcopy(original)
                del self.export['registrations'][0][key]
                self.run_adapter()


def change_inventory(t):
    t.pin['guardianInventory'][0]['validator'] = '0x'+'77'*20
    t.source['plan']['pin'] = copy.deepcopy(t.pin)


def change_guardian(t):
    item = t.export['registrations'][0]
    item['validator'] = '0x'+'77'*20
    item['calldata'] = p.encode_registration(item['validator'], item['publicKey'], item['slot'], item['popSignature'])
    t.pin['guardianInventory'][0]['validator'] = item['validator']
    t.source['plan']['pin'] = copy.deepcopy(t.pin)


def change_slot_mapping(t):
    first, second = t.export['registrations'][:2]
    first['slot'], second['slot'] = second['slot'], first['slot']
    for item in (first, second):
        item['calldata'] = p.encode_registration(item['validator'], item['publicKey'], item['slot'], item['popSignature'])


def add_pinned_guardian(t):
    t.pin['guardianInventory'][3]['validator'] = '0x'+'77'*20
    t.source['plan']['pin'] = copy.deepcopy(t.pin)


CASES = {
    'chain_id': lambda t: t.export.update(chainId=1),
    'chain_type': lambda t: t.export.update(chainId='11155111'),
    'version': lambda t: t.export.update(version='BLSAggregator-4.11.0'),
    'aggregator': lambda t: t.export.update(aggregator='0x'+'77'*20),
    'owner': lambda t: t.export.update(owner='0x'+'77'*20),
    'domain': lambda t: t.export.update(domainSeparator='0x'+'77'*32),
    'stage_a7': lambda t: t.source['plan'].update(stage='b4'),
    'stage_final': lambda t: t.source['plan'].update(final=True),
    'stage_pin': lambda t: t.source['plan']['pin'].update(blockHash='0x'+'77'*32),
    'stage_prefix': lambda t: t.source['readback'].update(prefixDigest='77'*32),
    'stage_domain': lambda t: t.source['plan'].update(expectedDomainSeparator='0x'+'77'*32),
    'inventory_slots': lambda t: (t.pin['guardianInventory'].pop(), t.source['plan'].update(pin=copy.deepcopy(t.pin))),
    'pinned_inventory': change_inventory,
    'extra_pinned_guardian': add_pinned_guardian,
    'guardian_set': change_guardian,
    'slot_mapping': change_slot_mapping,
    'registration_count': lambda t: t.export['registrations'].pop(),
    'duplicate': lambda t: t.export['registrations'].__setitem__(1, copy.deepcopy(t.export['registrations'][0])),
    'slot': lambda t: t.export['registrations'][0].update(slot=4),
    'slot_bool': lambda t: t.export['registrations'][0].update(slot=True),
    'public_key': lambda t: t.export['registrations'][0]['publicKey'].pop(),
    'signature': lambda t: t.export['registrations'][0]['popSignature'].pop(),
    'key_word': lambda t: t.export['registrations'][0]['publicKey'].__setitem__(0, '0x12'),
    'signature_word': lambda t: t.export['registrations'][0]['popSignature'].__setitem__(0, '0x'+'zz'*32),
    'pop_digest': lambda t: t.export['registrations'][0].update(popDigest='0x12'),
    'calldata_length': lambda t: t.export['registrations'][0].update(calldata=t.export['registrations'][0]['calldata']+'00'),
    'calldata_short': lambda t: t.export['registrations'][0].update(calldata=t.export['registrations'][0]['calldata'][:-2]),
    'selector': lambda t: t.export['registrations'][0].update(calldata='0x00000000'+t.export['registrations'][0]['calldata'][10:]),
    'calldata_binding': lambda t: t.export['registrations'][0]['publicKey'].__setitem__(0, '0x'+'77'*32),
    'signature_binding': lambda t: t.export['registrations'][0]['popSignature'].__setitem__(0, '0x'+'77'*32),
    'validator_binding': lambda t: t.export['registrations'][0].update(validator='0x'+'77'*20),
    'slot_binding': lambda t: t.export['registrations'][0].update(slot=2),
    'address_padding': lambda t: t.export['registrations'][0].update(calldata=t.export['registrations'][0]['calldata'][:10]+'1'+t.export['registrations'][0]['calldata'][11:]),
    'tool_commit': lambda t: setattr(t, 'commit', ''),
    'block': lambda t: t.export.update(block=-1),
    'validator_format': lambda t: t.export['registrations'][0].update(validator='bad'),
    'pin_hash': lambda t: (t.pin.update(blockHash='bad'), t.source['plan'].update(pin=copy.deepcopy(t.pin))),
}


STOP_GATES = {
    'chain_type': 'chain_id', 'stage_final': 'stage_a7',
    'extra_pinned_guardian': 'pinned_inventory', 'slot_mapping': 'guardian_set',
    'duplicate': 'guardian_set', 'slot_bool': 'slot', 'calldata_short': 'calldata_length',
    'signature_binding': 'calldata_binding', 'validator_binding': 'calldata_binding',
    'slot_binding': 'calldata_binding', 'address_padding': 'calldata_binding',
}


def guard_test(name, change):
    def test(self):
        change(self)
        with self.assertRaisesRegex(p.Stop, '^STOP: '+STOP_GATES.get(name, name)+'$'):
            self.run_adapter()
    return test


for name, change in CASES.items():
    setattr(PopAdapterTests, 'test_guard_'+name, guard_test(name, change))


if __name__ == '__main__':
    unittest.main()
