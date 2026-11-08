"""DSR ruling 2: exact-name shadow controls for the eighteen blocked inputs."""
import inspect
import copy
import json
import re
from pathlib import Path
import unittest
from unittest.mock import patch
import probe_finite_gate_blockers as candidates
import test_gate_extra_finite as extra
from gate_assertions import assert_stop

# Non-canonical means outside the approved role identities, not malformed hex.
SENDER_INPUTS = {role: '0x' + format(0xd5a200 + i, '040x')
                 for i, role in enumerate(('deployer', 'approver', 'executor'), 1)}


def rebuilt_sender_control(role):
    def action(self):
        m, a = candidates.m, candidates.a
        pin, inputs = copy.deepcopy(self.pin), copy.deepcopy(self.inputs)
        who, replacement = pin['senders'][role]['address'], SENDER_INPUTS[role]
        known = set(re.findall(r'0x[0-9a-fA-F]{40}(?![0-9a-fA-F])',
                               json.dumps([pin, inputs, candidates.templates.manifest.ART])))
        known.update(v for v in vars(a).values() if isinstance(v, str))
        self.assertNotIn(replacement.lower(), {v.lower() for v in known})
        self.assertNotEqual(replacement, a.ZERO)
        spec = inputs['data']['a3aPlan']
        plan = json.loads(Path(spec['path']).read_text())
        pin['senders'][role]['address'] = replacement
        if role == 'deployer':
            # Keep the existing inventory and total, with all funds held by the
            # other authorized drain sender; the old deployer has zero balance.
            amount = pin['operatorBalances'][who]
            pin['operatorBalances'][who] = 0
            pin['operatorBalances'][pin['senders']['anni']['address']] += amount
        for step in plan['steps']:
            if step['tx']['from'] == who:
                step['tx']['from'] = replacement
                pin['a3aHistory'][step['id']]['transaction']['from'] = replacement
        # This fixture has contiguous nonces and no gap evidence to rebind.
        self.assertFalse(plan.get('nonceGaps'))
        self.assertFalse(spec.get('nonceGaps'))
        self.assertFalse(pin['a3aGapReads'])
        spec.update(self.file_ref('dsr2-sender-' + role, plan))
        inputs = m.external(Path(self.file_ref('dsr2-input-' + role, inputs['data'])['path']))
        m.validate_nonce_history(pin, inputs)
        m.build_plan(pin, inputs)
    return action


# Source line numbers refer to the preserved 6e worktree, not HEAD.
CASES = []
for cls, name, gate in candidates.CASES:
    if gate.startswith('fraud_token_zero_owner_'):
        earlier, line = 'fraud_token_pinned_runtime', 494
    elif gate.startswith('verifier_'):
        earlier, line = ('evidence_dvt-ci_hash' if gate.endswith('ciSha256') else 'verifier_build_identity'), 640
    elif gate.startswith(('canonical_', 'nonzero_')):
        earlier, line = 'fixed_' + gate.split('_', 1)[1], 644 if gate.startswith('canonical_') else 645
    elif gate.startswith('sender_fields_'):
        earlier, line = 'sender', 2148
    elif gate.startswith('sender_'):
        earlier, line = 'sender_identity', 2155
    elif gate == 'drain_operator_present_deployer':
        earlier, line = 'drain_inventory', 2300
    else:
        continue
    action = inspect.getclosurevars(getattr(cls, name)).nonlocals['action']
    if gate in {'sender_' + role for role in SENDER_INPUTS}:
        action = rebuilt_sender_control(gate.removeprefix('sender_'))
    CASES.append(dict(gate=gate, earlier=earlier, file='manifest_exec.py', line=line, action=action))

CASES.append(dict(gate='old_owner_extraction_roles_Registry', earlier='old_owner_role_init_ids',
                  file='old_owner_isolation.py', line=530, action=None))


SECOND = {
    'fraud_token_zero_owner_130': ('fraud_token_stripped_runtime', 'manifest_exec.py', 491),
    'fraud_token_zero_owner_210': ('fraud_token_stripped_runtime', 'manifest_exec.py', 491),
    'verifier_ciSha256': ('evidence_dvt-ci', 'manifest_exec.py', 82),
}


class ShadowTests(candidates.templates.ManifestTemplateTests):
    pass


class RegistryShadowTests(unittest.TestCase):
    pass


def control(row, expected):
    def test(self):
        if row['action'] is None:
            # Replace only the test's expectation; production predicates remain intact.
            with patch.object(extra, 'assert_stop', side_effect=lambda obj, gate: assert_stop(obj, expected)):
                extra.extract_control(530, 'Registry', row['gate'])(self)
        else:
            with assert_stop(self, expected):
                row['action'](self)
    return test


for row in CASES:
    cls = RegistryShadowTests if row['action'] is None else ShadowTests
    row['class'] = cls.__name__
    if row['gate'] in SECOND:
        setattr(cls, 'test_second_' + row['gate'], control(row, SECOND[row['gate']][0]))
    for mode in ('shadow', 'target'):
        setattr(cls, 'test_' + mode + '_' + row['gate'], control(row, row['earlier'] if mode == 'shadow' else row['gate']))


def load_tests(loader, tests, pattern):
    # Only real-tree shadow controls belong to the normal suite. Target controls
    # are invoked explicitly by the temporary-tree paired probe runner.
    return unittest.TestSuite(cls('test_shadow_' + row['gate']) for row in CASES
                              for cls in (RegistryShadowTests if row['action'] is None else ShadowTests,))


if __name__ == '__main__':
    unittest.main()
