#!/usr/bin/env python3
"""Offline DVT PoP export binding; pairing validation belongs to stage simulate."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile

import manifest_exec as m

GUARDIANS = {
    1: '0x5d870e132cc010e882e90f4afaacdc4f19c7eca3',
    2: '0x40f0b12128f256b62fa22b36d37012ee004bbd1f',
    3: '0xd904a706e355d6b48baedbec472ce94bc6981601',
}


class Stop(ValueError):
    """Invalid or unbound handoff data."""


def require(gate, condition):
    if not condition:
        raise Stop('STOP: '+gate)


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require('duplicate_json_key', key not in result)
        result[key] = value
    return result


def load_json(raw):
    try:
        return json.loads(raw, object_pairs_hook=unique_object)
    except RecursionError as error:
        raise Stop('STOP: json_nesting') from error


def atomic_write(path, text):
    path = Path(path)
    # mkstemp returns the name together with the descriptor, so the cleanup path knows the file as soon as it exists.
    # An interrupt landing between mkstemp's return and this assignment can still leave a dot-prefixed temporary; the
    # previous output is never touched.
    fd, name = tempfile.mkstemp(dir=path.parent, prefix='.'+path.name+'.')
    temporary = Path(name)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as output:
            output.write(text)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def hex_value(value, size, gate):
    require(gate, isinstance(value, str) and re.fullmatch(r'0x[0-9a-fA-F]{'+str(size*2)+'}', value) is not None)
    return value.lower()


def encode_registration(validator, public_key, slot, signature):
    """Use the executor's cast-backed ABI encoder, including static tuple layout."""
    return m.a.calldata(m.POP, validator, '('+','.join(public_key)+')', slot,
                        '('+','.join(signature)+')').lower()


def adapt(export_path, *, pin, stage_source, tool_commit):
    """Return {pop, exportSha256, exportBlock, toolCommit} bound to a supplied pin/A7 source.

    stage_source is A7-RUN/stage-source.json (plan plus fork readback). This
    offline comparison cannot authenticate a fork; retain simulation evidence.
    The SHA256 covers the original export bytes, including whitespace.
    """
    try:
        raw = Path(export_path).read_bytes()
        export = load_json(raw)
        require('tool_commit', isinstance(tool_commit, str) and re.fullmatch(r'[0-9a-f]{40}', tool_commit) is not None)
        plan, readback = stage_source['plan'], stage_source['readback']
        require('stage_a7', plan['stage'] == 'a7' and plan['final'] is False)
        require('stage_pin', plan['pin'] == pin)
        require('stage_prefix', readback['prefixDigest'] == plan['prefixDigest'])
        aggregator = hex_value(plan['addresses']['BLSAggregator'], 20, 'plan_aggregator')
        domain = hex_value(readback['domainSeparator'], 32, 'stage_domain_format')
        require('stage_domain', domain == hex_value(plan['expectedDomainSeparator'], 32, 'expected_domain'))
        pin_hash = hex_value(pin['blockHash'], 32, 'pin_hash')
        require('chain_id', type(export['chainId']) is int and export['chainId'] == 11155111)
        require('version', export['version'] == 'BLSAggregator-4.12.0')
        require('aggregator', hex_value(export['aggregator'], 20, 'aggregator_format') == aggregator)
        require('owner', hex_value(export['owner'], 20, 'owner_format') == m.u.DEPLOYER)
        require('domain', hex_value(export['domainSeparator'], 32, 'domain_format') == domain)
        require('block', type(export['block']) is int and export['block'] >= 0)

        if 'block' in plan['pin']:
            fork_block = plan['pin']['block']
            if isinstance(fork_block, str):
                require('fork_block', re.fullmatch(r'0x[0-9a-fA-F]+', fork_block) is not None)
                fork_block = int(fork_block, 16)
            require('fork_block', type(fork_block) is int and fork_block >= 0)
            require('export_block_before_fork', export['block'] >= fork_block)

        inventory = pin['guardianInventory']
        require('inventory_slots', isinstance(inventory, list) and
                all(type(x['slot']) is int for x in inventory) and
                [x['slot'] for x in inventory] == list(range(1, 14)))
        pinned = {x['slot']: hex_value(x['validator'], 20, 'inventory_validator') for x in inventory}
        pinned = {slot: who for slot, who in pinned.items() if who != m.a.ZERO}
        registrations = export['registrations']
        require('registration_count', isinstance(registrations, list) and len(registrations) == 3)
        result = []
        for item in registrations:
            validator = hex_value(item['validator'], 20, 'validator_format')
            slot = item['slot']
            require('slot', type(slot) is int and slot in (1, 2, 3))
            key, signature = item['publicKey'], item['popSignature']
            require('public_key', isinstance(key, list) and len(key) == 4)
            require('signature', isinstance(signature, list) and len(signature) == 8)
            key = [hex_value(word, 32, 'key_word') for word in key]
            signature = [hex_value(word, 32, 'signature_word') for word in signature]
            hex_value(item['popDigest'], 32, 'pop_digest')
            calldata = hex_value(item['calldata'], 4+14*32, 'calldata_length')
            require('selector', calldata[:10] == '0xaded17c5')
            require('calldata_binding', calldata == encode_registration(validator, key, slot, signature))
            result.append(dict(validator=validator, slot=slot, calldata=calldata,
                               aggregator=aggregator, pinBlockHash=pin_hash, domainSeparator=domain))
        actual = {item['slot']: item['validator'] for item in result}
        require('guardian_set', actual == GUARDIANS)
        require('pinned_inventory', actual == pinned)
        return dict(pop=sorted(result, key=lambda item: item['slot']),
                    exportSha256=hashlib.sha256(raw).hexdigest(), exportBlock=export['block'], toolCommit=tool_commit)
    except Stop:
        raise
    except (KeyError, TypeError, ValueError, OSError, RecursionError, m.a.Gate) as error:
        raise Stop('STOP: invalid_pop_input ('+type(error).__name__+')') from error


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--export', required=True, dest='export_path')
    parser.add_argument('--pin', required=True)
    parser.add_argument('--a7-source', required=True)
    parser.add_argument('--tool-commit', required=True)
    parser.add_argument('--out', required=True)
    args = parser.parse_args(argv)
    try:
        result = adapt(args.export_path, pin=load_json(Path(args.pin).read_bytes()),
                       stage_source=load_json(Path(args.a7_source).read_bytes()), tool_commit=args.tool_commit)
        atomic_write(args.out, json.dumps(result, indent=2)+'\n')
    except (Stop, OSError, ValueError, RecursionError) as error:
        print(str(error) if isinstance(error, Stop) else 'STOP: invalid_file', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
