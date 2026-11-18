"""SYNTHETIC export from GenuineBLS public scalars 1/2/3; no secret material."""
import copy
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
FIX = ROOT / 'script/rehearsal/fixtures/dvt-pop'
SCRIPT = ROOT / 'script/rehearsal/dvt_pop_to_guardians.py'

class ConverterTest(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('converter', SCRIPT)
        self.c = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.c)
        self.export = json.loads((FIX / 'SYNTHETIC.export.json').read_text())
        self.request = json.loads((FIX / 'SYNTHETIC.request.json').read_text())

    def test_round_trip_cast_and_local_fixture(self):
        expected = (FIX / 'SYNTHETIC.guardians.hex').read_text().strip()
        self.assertEqual(self.c.convert(self.export, self.request, ROOT), expected)
        tuples = []
        for entry in self.export['pop']:
            raw = entry['calldata'][10:]
            words = ['0x' + raw[i:i+64] for i in range(0, len(raw), 64)]
            tuples.append(f"({entry['validator']},({','.join(words[1:5])}),({','.join(words[6:])}))")
            encoded = subprocess.check_output(['cast', 'calldata', self.c.SIGNATURE,
                entry['validator'], '(' + ','.join(words[1:5]) + ')', str(entry['slot']),
                '(' + ','.join(words[6:]) + ')'], text=True).strip()
            self.assertEqual(encoded, entry['calldata'])
        encoded = subprocess.check_output(['cast', 'abi-encode', 'f((address,(bytes32,bytes32,bytes32,bytes32),(bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32,bytes32))[])', '[' + ','.join(tuples) + ']'], text=True).strip()
        self.assertEqual(expected, encoded)
        # The other half of the round trip (DeployLiveLocalBundle's GUARDIANS == this committed hex)
        # is asserted on Prague by DeployLivePopSyntheticTest; no cache file from an earlier run.

    def test_cli_hashes(self):
        args = ['python3', str(SCRIPT), str(FIX / 'SYNTHETIC.export.json'), str(FIX / 'SYNTHETIC.request.json'), '--sp-root', str(ROOT)]
        result = subprocess.run(args, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        for name in ['export.json', 'request.json']:
            self.assertIn(hashlib.sha256((FIX / ('SYNTHETIC.' + name)).read_bytes()).hexdigest(), result.stderr)
        self.assertEqual(result.stdout.strip(), (FIX / 'SYNTHETIC.guardians.hex').read_text().strip())

    def test_source_hash_compared_normalized(self):
        # DVT writes lowercase hex without 0x; a 0x prefix or upper case must not matter,
        # a different digest must still stop.
        good = self.export['popContext']['spAggregatorSourceSha256']
        expected = (FIX / 'SYNTHETIC.guardians.hex').read_text().strip()
        for variant in (good.upper(), '0x' + good, '0x' + good.upper()):
            self.export['popContext']['spAggregatorSourceSha256'] = variant
            self.assertEqual(self.c.convert(self.export, self.request, ROOT), expected)
        self.export['popContext']['spAggregatorSourceSha256'] = ('0' if good[0] != '0' else '1') + good[1:]
        with self.assertRaisesRegex(self.c.Stop, 'source_hash'):
            self.c.convert(self.export, self.request, ROOT)
        self.export['popContext']['spAggregatorSourceSha256'] = good[:-1]
        with self.assertRaisesRegex(self.c.Stop, 'source_hash_format'):
            self.c.convert(self.export, self.request, ROOT)

    def test_case_insensitive_addresses(self):
        for key in ['dvt', 'aggregator', 'registry', 'deployerAddress']:
            self.export['popContext'][key] = '0x' + self.export['popContext'][key][2:].upper()
        for entry in self.export['pop']:
            for key in ['validator', 'aggregator']:
                entry[key] = '0x' + entry[key][2:].upper()
        self.assertEqual(self.c.convert(self.export, self.request, ROOT),
                         (FIX / 'SYNTHETIC.guardians.hex').read_text().strip())

    def test_cli_invalid_usage_named_stop(self):
        result = subprocess.run(['python3', str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(result.returncode, 3)
        self.assertIn('STOP arguments', result.stderr)
        self.assertEqual(result.stdout, '')

    def test_reject_source_version_missing(self):
        with patch.object(Path, 'read_bytes', return_value=b'// missing version'):
            with self.assertRaisesRegex(self.c.Stop, 'STOP source_version'):
                self.c.convert(self.export, self.request, ROOT)

    def test_reject_source_file_missing(self):
        with patch.object(Path, 'read_bytes', side_effect=FileNotFoundError):
            with self.assertRaisesRegex(self.c.Stop, 'STOP source_file'):
                self.c.convert(self.export, self.request, ROOT)

    def test_reject_head_worktree_mismatch(self):
        current = (ROOT / self.c.SOURCE).read_bytes()
        head = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
        blob = subprocess.check_output(['git', 'show', f'{head}:{self.c.SOURCE}'], cwd=ROOT)
        self.request['spCommit'] = head
        self.export['popContext'].update(spCommit=head, spAggregatorSourceSha256=hashlib.sha256(blob).hexdigest())
        with patch.object(Path, 'read_bytes', return_value=current + b'// drift'):
            with self.assertRaisesRegex(self.c.Stop, 'STOP source_worktree'):
                self.c.convert(self.export, self.request, ROOT)

    def reject(self, mutate, gate):
        mutate(self.export, self.request)
        with self.assertRaisesRegex(self.c.Stop, 'STOP ' + gate):
            self.c.convert(self.export, self.request, ROOT)

def negative(name, mutation, gate):
    def test(self): self.reject(mutation, gate)
    setattr(ConverterTest, 'test_reject_' + name, test)

negative('top_extra', lambda e,r: e.update(extra=1), 'export_keys')
negative('top_missing', lambda e,r: e.pop('popContext'), 'export_keys')
negative('version', lambda e,r: e.update(aggregatorSourceVersion='BLSAggregator-0.0.0'), 'version')
negative('context_extra', lambda e,r: e['popContext'].update(extra=1), 'context_keys')
negative('context_missing', lambda e,r: e['popContext'].pop('dvt'), 'context_keys')
for field in ['dvt','aggregator','registry','chainId','deployerAddress','deployerNonce','pinBlock','pinBlockHash','spCommit']:
    negative('context_' + field, lambda e,r,f=field: e['popContext'].update({f: e['popContext'][f] + 1 if isinstance(e['popContext'][f], int) else 'f'*40 if f == 'spCommit' else '0x' + 'ef'*(32 if f == 'pinBlockHash' else 20)}), 'context_' + field)
negative('source_hash', lambda e,r: e['popContext'].update(spAggregatorSourceSha256='00'*32), 'source_hash')
negative('commit_missing', lambda e,r: (r.update(spCommit='0'*40), e['popContext'].update(spCommit='0'*40)), 'source_commit')
negative('count', lambda e,r: e['pop'].pop(), 'pop_count')
negative('entry_extra', lambda e,r: e['pop'][0].update(extra=1), 'pop_keys')
negative('entry_missing', lambda e,r: e['pop'][0].pop('slot'), 'pop_keys')
for field in ['aggregator', 'pinBlockHash', 'domainSeparator']:
    negative('entry_' + field, lambda e,r,f=field: e['pop'][0].update({f:'0x'+'cd'*(20 if f == 'aggregator' else 32)}), 'pop_' + field)
negative('selector', lambda e,r: e['pop'][0].update(calldata='0x00000000'+e['pop'][0]['calldata'][10:]), 'calldata_selector')
negative('length', lambda e,r: e['pop'][0].update(calldata=e['pop'][0]['calldata'][:-2]), 'calldata_length')
negative('validator', lambda e,r: e['pop'][0].update(validator='0x'+'ef'*20), 'calldata_validator')
negative('slot', lambda e,r: e['pop'][0].update(slot=2), 'calldata_slot')
negative('order', lambda e,r: e['pop'].reverse(), 'slot_order')
negative('duplicate', lambda e,r: (e['pop'][1].update(validator=e['pop'][0]['validator']), e['pop'][1].update(calldata=e['pop'][1]['calldata'][:10]+e['pop'][0]['calldata'][10:74]+e['pop'][1]['calldata'][74:])), 'validator_distinct')
negative('digests', lambda e,r: e['popContext']['popDigests'].pop(), 'pop_digests')
negative('request_schema', lambda e,r: r.update(schema='bad'), 'request_schema')
negative('request_chain', lambda e,r: r.update(chainId=True), 'request_chain')
negative('request_commit', lambda e,r: r.update(spCommit='ABC'), 'request_commit')
negative('request_fields', lambda e,r: r.pop('pin'), 'request_fields')
negative('request_count', lambda e,r: r.update(guardianCount=True), 'request_count')

def write_synthetic_fixtures():
    """SYNTHETIC field comment: every pop key/signature uses public scalar slot=1/2/3.

    Keep comments here, not in JSON: DVT's exact-key format forbids extra fields.
    Input guardians.txt is produced by DeployLiveLocalBundle, never by this encoder.
    """
    import dvt_pop_to_guardians as c
    addresses = json.loads((ROOT / 'cache/dlpop/SYNTHETIC.addresses.json').read_text())
    addresses['DVTValidator'] = subprocess.check_output(['cast', 'compute-address', '0x0000000000000000000000000000000000123456', '--nonce', '35'], text=True).strip().split()[-1]
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    source = subprocess.check_output(['git', 'show', f'{commit}:{c.SOURCE}'], cwd=ROOT)
    request = dict(schema='deploylive-pop-request/1', chainId=31337, spCommit=commit,
        addresses=addresses, pin={'block': 123, 'blockHash': '0x'+'ab'*32,
        'senders': {'deployer': {'address':'0x0000000000000000000000000000000000123456', 'nonce':7}}}, guardianCount=3)
    domain = c.keccak(c.keccak(b'SuperPaymaster.BLSConsensus.v1') + c.word(31337)
        + bytes(12) + bytes.fromhex(addresses['BLSAggregator'][2:])
        + bytes(12) + bytes.fromhex(addresses['Registry'][2:]))
    encoded = (ROOT / 'cache/dlpop/guardians.txt').read_text().strip()
    data = bytes.fromhex(encoded[2:])[64:]
    entries, digests = [], []
    for i in range(3):
        row = data[i*416:(i+1)*416]
        words = ['0x'+row[j:j+32].hex() for j in range(0,416,32)]
        validator = '0x'+row[12:32].hex()
        calldata = subprocess.check_output(['cast','calldata',c.SIGNATURE,validator,
            '('+','.join(words[1:5])+')',str(i+1),'('+','.join(words[5:])+')'],text=True).strip()
        # SYNTHETIC pop field: public GenuineBLS scalar i+1, never a node secret.
        entries.append(dict(validator=validator,slot=i+1,calldata=calldata,aggregator=addresses['BLSAggregator'],
            pinBlockHash=request['pin']['blockHash'],domainSeparator='0x'+domain.hex()))
        digests.append('0x'+c.keccak(domain+c.keccak(b'SuperPaymaster.BLS.PoP.v1')+row[:160]).hex())
    context = dict(dvt=addresses['DVTValidator'],aggregator=addresses['BLSAggregator'],registry=addresses['Registry'],
        chainId=31337,deployerAddress=request['pin']['senders']['deployer']['address'],deployerNonce=7,pinBlock=123,
        pinBlockHash=request['pin']['blockHash'],spCommit=commit,spAggregatorSourceSha256=hashlib.sha256(source).hexdigest(),popDigests=digests)
    export = dict(pop=entries,aggregatorSourceVersion=c.source_version(source),popContext=context)
    FIX.mkdir(parents=True,exist_ok=True)
    for name,obj in [('request',request),('export',export)]:
        (FIX / ('SYNTHETIC.'+name+'.json')).write_text(json.dumps(obj,indent=2)+'\n')
    (FIX / 'SYNTHETIC.guardians.hex').write_text(encoded+'\n')

if __name__ == '__main__':
    import sys
    if sys.argv[1:] == ['--write-synthetic-fixtures']:
        write_synthetic_fixtures()
    else:
        unittest.main()
