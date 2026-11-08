#!/usr/bin/env python3
"""Attempt remaining finite guards without bypassing preceding production gates."""
import copy
import json
from pathlib import Path
import re
import unittest
from unittest.mock import patch
import test_gate_template_controls as templates
import probe_phase_c_gates as driver
from gate_assertions import assert_stop, assertion_mentions
from gate_rename_ast_diff import ROOT

m, a, u = templates.manifest.m, templates.manifest.a, templates.manifest.u
iso = templates.isolation
CASES = []


class ManifestCandidates(templates.ManifestTemplateTests):
    pass


class IsolationCandidates(templates.IsolationTemplateTests):
    pass


for cls in (ManifestCandidates, IsolationCandidates):
    for name in dir(cls):
        if name.startswith('test_'):
            setattr(cls, name, None)


def add(cls, gate, action):
    def test(self):
        with assert_stop(self, gate):
            action(self)
    name = 'test_candidate_' + gate
    setattr(cls, name, test)
    CASES.append((cls, name, gate))


def zero_owner(offset):
    def action(self):
        value = copy.deepcopy(self.export)
        token = value['export']['forkState']['token']
        raw = bytearray.fromhex(token['runtimeBytecode'][2:])
        raw[offset] = 1
        token['runtimeBytecode'] = '0x' + raw.hex()
        m.fraud_fixture(self.file_ref('finite-zero-owner', value))
    return action


for offset in (130, 210):
    add(ManifestCandidates, 'fraud_token_zero_owner_' + str(offset), zero_owner(offset))


def verifier_digest(key):
    def action(self):
        data = copy.deepcopy(self.data)
        data['verifier'][key] = 'invalid'
        m.validate_external(data)
    return action


for key in ('ciSha256', 'buildSha256'):
    add(ManifestCandidates, 'verifier_' + key, verifier_digest(key))


def address_control(label, zero):
    def action(self):
        data = copy.deepcopy(self.data)
        data[label] = a.ZERO if zero else '0x' + data[label][2:].upper()
        m.validate_external(data)
    return action


for label in ('anni', 'dvt', 'committee'):
    for zero in (False, True):
        add(ManifestCandidates, ('nonzero_' if zero else 'canonical_') + label, address_control(label, zero))


def sender_control(label, fields):
    def action(self):
        pin = copy.deepcopy(self.pin)
        if fields:
            pin['senders'][label]['extra'] = True
        else:
            pin['senders'][label]['address'] = a.ZERO
        m.build_plan(pin, self.inputs)
    return action


for label in ('deployer', 'approver', 'executor'):
    add(ManifestCandidates, 'sender_fields_' + label, sender_control(label, True))
    add(ManifestCandidates, 'sender_' + label, sender_control(label, False))


def drain_control(label):
    def action(self):
        pin = copy.deepcopy(self.pin)
        value = pin['operatorBalances'].pop(pin['senders'][label]['address'])
        pin['totalTrackedBalance'] -= value
        if label == 'anni':
            who = pin['senders'][label]['address']
            for field in ('holders', 'historicalOperators', 'pauseList'):
                pin[field] = [address for address in pin[field] if address != who]
            # Rebuild dependent offline transcripts for the smaller inventory;
            # never bypass their production revalidation gates.
            pin['oldOwnerIsolation'] = iso.evidence(pin)
            pin['oldTimelock'] = m.old_timelock_holds_nothing(
                templates.manifest.old_timelock_rpc(pin, pin['stateBlock']), pin, pin['stateBlock'])
        m.build_plan(pin, self.inputs)
    return action


for label in ('deployer', 'anni'):
    add(ManifestCandidates, 'drain_operator_present_' + label, drain_control(label))


def target_control(label):
    def action(self):
        if label == 'PaymasterFactory':
            # A fixed deployment constant has no RPC-supplied value to mutate.
            with patch.object(iso.o, 'PAYMASTER_FACTORY', a.ZERO):
                iso.o.audit(iso.fixture_rpc(self.pin), self.pin, iso.inventory(), iso.FIXTURE_CALLSITE_TARGETS)
            return
        target, sig = {'GTokenStaking': (u.REG, 'GTOKEN_STAKING()'),
                       'GToken': (iso.STAKING, 'GTOKEN()'),
                       'xPNTsFactory': (u.SP, 'xpntsFactory()'),
                       'MySBT': (u.REG, 'MYSBT()')}[label]
        query = ('eth_call', str([dict(to=target, data=a.calldata(sig)), self.pin['stateBlock']]))
        baseline = iso.fixture_rpc(self.pin, {query: iso.raw([0])})
        expected = dict(iso.FIXTURE_CALLSITE_TARGETS)
        if label in ('GTokenStaking', 'MySBT'):
            expected['GTOKEN_STAKING' if label == 'GTokenStaking' else 'MYSBT'] = a.ZERO
        def rpc(method, params):
            # Assert a concrete forbidden downstream read, before the fixture's
            # sparse response table can raise an unrelated KeyError.
            if method == 'eth_call':
                tx = params[0]
                if label == 'GTokenStaking' and tx['to'] == a.ZERO and tx['data'] == a.calldata('GTOKEN()'):
                    # The aggregate target check occurs after this getter. Model
                    # its explicit return to reach the aggregate guard itself.
                    return iso.raw([int(iso.GTOKEN, 16)])
                if label in ('xPNTsFactory', 'GTokenStaking', 'MySBT'):
                    self.assertNotEqual(tx['to'], a.ZERO,
                                        'old_owner_target_' + label + ': queried a zero target')
                if label in ('GToken', 'GTokenStaking', 'MySBT') and tx['data'].startswith(a.keccak('hasRole(bytes32,address)')[:10]):
                    self.assertNotEqual(tx['data'][-64:], '0' * 64,
                                        'old_owner_target_' + label + ': queried membership for a zero target')
            return baseline(method, params)
        rpc.fork = baseline.fork
        iso.o.audit(rpc, self.pin, iso.inventory(), expected)
    return action


for label in ('GTokenStaking', 'GToken', 'xPNTsFactory', 'MySBT', 'PaymasterFactory'):
    add(IsolationCandidates, 'old_owner_target_' + label, target_control(label))


def main():
    report = []
    registry = json.loads((ROOT / 'script/upgrade/gate_templates.json').read_text())
    for cls, name, gate in CASES:
        definitions = [r for r in registry if gate in {p['gate'] for p in r['probes'].values()}]
        green, _, baseline = driver.run(cls, name)
        accepted, reached, mutant = driver.run(cls, name, gate) if green else (True, False, '')
        sites = len(driver.SITES.get((cls, name, gate), set()))
        good = len(definitions) == 1 and green and sites == 1 and reached and not accepted
        detail = [line for line in (baseline + mutant).splitlines()
                  if re.match(r'^(AssertionError:|[A-Za-z]+Error:|FAILED|OK)', line)]
        final = (f'FINITE_BOUNDARY {gate} {"PASS" if good else "BLOCKED"} definitions={len(definitions)} '
                 f'sites={sites} baseline={"green" if green else "RED"} '
                 f'failures={mutant.count("FAIL:")} errors={mutant.count("ERROR:")} '
                 f'named={assertion_mentions(mutant, gate)}')
        print(final, flush=True)
        print('\n'.join(detail), flush=True)
        report.append(dict(gate=gate, passed=good, final=final, details=detail,
                           baseline=baseline, mutant=mutant, cls=cls.__name__, method=name))
    Path('/tmp/commit6e-rulings/boundary-probes.json').write_text(json.dumps(report, indent=2)+'\n')
    passed = sum(r['passed'] for r in report)
    print(f'FINITE_BOUNDARY_PROBES {"PASS" if passed == len(report) else "FAIL"} {passed}/{len(report)} strict red')
    return int(passed != len(report))


if __name__ == '__main__':
    raise SystemExit(main())
