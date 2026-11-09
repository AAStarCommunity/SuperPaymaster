#!/usr/bin/env python3
"""Offline authority reads at pin, pre-send, and closing."""
import copy
import unittest
from pathlib import Path
from unittest.mock import patch
import test_manifest_exec as t
from gate_assertions import assert_stop

m, a, u = t.m, t.a, t.u


class AuthorityCheckpointTests(unittest.TestCase):
    setUpClass = classmethod(t.DiscoveryTests.setUpClass.__func__)
    setUp = t.DiscoveryTests.setUp
    rpc = t.DiscoveryTests.rpc
    closing = t.DiscoveryTests.closing
    pre = t.DiscoveryTests.pre

    def checkpoint(self, timepoint, holder):
        spec = self.pin['oldOwnerIsolation']['inventory']['Registry']
        role = spec['roles'][0]
        owner_row = next(row for row in spec['authorities'] if row['signature'] == 'owner()')
        for signature, args in (('owner()', []), ('getRoleConfig(bytes32)', [role['value']])):
            values = [int(holder, 16)]
            if args:
                values = [32]+[0]*13
                values[10], values[11] = 384, int(holder, 16)
            if timepoint == 'pin':
                if holder == m.isolation.OLD:
                    key = ('eth_call', str([dict(to=u.REG, data=a.calldata(signature, *args)), self.pin['stateBlock']]))
                    rpc = t.isolation_tests.fixture_rpc(copy.deepcopy(self.pin), {key: t.isolation_tests.raw(values)})
                    spec_inventory = self.pin['oldOwnerIsolation']['inventory']
                    action = lambda: m.isolation.audit(rpc, self.pin, spec_inventory, t.isolation_tests.FIXTURE_CALLSITE_TARGETS)
                    gate = 'old_owner_role_admin_declared_'+role['name'] if args else 'old_owner_authority_member_Registry_'+owner_row['name']
                else:
                    rpc = t.old_timelock_rpc(self.pin, self.pin['stateBlock'], (u.REG, signature, args, t.isolation_tests.raw(values)))
                    action = lambda: m.old_timelock_holds_nothing(rpc, self.pin, self.pin['stateBlock'])
                    gate = 'old_timelock_authority'
            else:
                base = self.rpc()
                def rpc(method, params):
                    if method == 'eth_call' and params[0] == dict(to=u.REG, data=a.calldata(signature, *args)):
                        self.assertEqual(params[1], self.block)
                        return t.isolation_tests.raw(values)
                    return base(method, params)
                rpc.local = True
                action = lambda: self.closing(rpc) if timepoint == 'closing' else self.pre(rpc)
                gate = 'discovery_old_authority' if holder == m.isolation.OLD else 'old_timelock_authority'
            with self.subTest(timepoint=timepoint, holder=holder, signature=signature), assert_stop(self, gate):
                action()

    def test_pin_old(self):
        self.checkpoint('pin', m.isolation.OLD)

    def test_pin_old_timelock(self):
        self.checkpoint('pin', m.isolation.OLD_TIMELOCK)

    def test_pre_old(self):
        self.checkpoint('pre_send', m.isolation.OLD)

    def test_pre_old_timelock(self):
        self.checkpoint('pre_send', m.isolation.OLD_TIMELOCK)

    def test_closing_old(self):
        self.checkpoint('closing', m.isolation.OLD)

    def test_closing_old_timelock(self):
        self.checkpoint('closing', m.isolation.OLD_TIMELOCK)

    def closing_packet_role(self, holder):
        # Isolate the closing authority consumer from inventory validation. The
        # producer's returned inventory models a role first configured by a packet
        # step, rather than quietly adding the role to the original pin.
        role = a.keccak('CLOSING_PACKET_ROLE')
        section = self.pin['oldOwnerIsolation']
        self.assertNotIn(role, section['configuredRoles'])
        self.assertNotIn(role, section['roleHistory'].get(u.REG, []))
        self.assertNotIn(role, {r['value'] for r in section['inventory']['Registry']['roles']})
        data = u.freeze_calldata(self.pin['roleConfig'])
        self.plan['expectedDiscoveryAfter']['test.configureRole'] = copy.deepcopy(
            self.plan['expectedDiscoveryAfter'][self.plan['steps'][-1]['id']])
        self.plan['steps'].append(dict(id='test.configureRole', tx=dict(
            to=u.REG, data=data[:10]+role[2:]+data[74:])))
        self.assertEqual(self.plan['steps'][-1]['tx']['data'][10:74], role[2:])
        base = self.rpc()
        config_data = a.calldata('getRoleConfig(bytes32)', role)
        reads = []
        def rpc(method, params):
            if method == 'eth_call' and params[0]['to'] == u.REG:
                if params[0]['data'] == config_data:
                    self.assertEqual(params[1], self.block)
                    reads.append(params[1])
                    values = [32]+[0]*13
                    values[10], values[11] = 384, int(holder, 16)
                    return t.isolation_tests.raw(values)
                if params[0]['data'] in [a.calldata('hasRole(bytes32,address)', role, h)
                                        for h in (m.isolation.OLD, m.isolation.OLD_TIMELOCK)]:
                    # A config owner need not be a member. This is also the real
                    # mapping's answer when deletion continues to the next audit.
                    return t.isolation_tests.raw([0])
            return base(method, params)
        rpc.local = True
        def inventory(rpc_arg, coverage, block):
            self.assertEqual(block, self.block)
            self.assertNotIn(role, coverage['oldOwnerIsolation']['configuredRoles'])
            closing = copy.deepcopy(coverage)
            closing['oldOwnerIsolation']['configuredRoles'].append(role)
            return closing
        with patch.object(m, 'closing_timelock_inventory', side_effect=inventory):
            result = self.closing(rpc)
        self.assertGreaterEqual(len(reads), 2)
        return result

    def test_closing_packet_role_clean(self):
        self.closing_packet_role(u.DEPLOYER)

    def test_closing_packet_role_old(self):
        with assert_stop(self, 'discovery_old_authority'):
            self.closing_packet_role(m.isolation.OLD)

    def test_closing_packet_role_old_timelock(self):
        with assert_stop(self, 'old_timelock_authority'):
            self.closing_packet_role(m.isolation.OLD_TIMELOCK)


class RealRegistryAuthorityRowsTests(unittest.TestCase):
    def test_real_registry_authority_union(self):
        o = m.isolation
        tree = Path('/private/tmp/l1-builds')/o.REGISTRY_SOURCE_COMMIT
        inventory = o.extract(tree, ('Registry',))
        standard = {r['value'] for r in inventory['Registry']['roles']}
        event_role, history_role = a.keccak('EVENT_ONLY_ROLE'), a.keccak('HISTORY_ONLY_ROLE')
        self.assertTrue(standard)
        self.assertTrue({event_role, history_role}.isdisjoint(standard))
        event = dict(topics=[inventory['Registry']['roleEventTopic'], event_role])
        section = dict(inventory=inventory, targets=dict(Registry=u.REG), xpnts=[],
                       configuredRoles=[event['topics'][1]], roleHistory={u.REG: [history_role]})
        rows = o.authority_rows(section)
        self.assertIn((u.REG, 'owner()', [], 'address'), rows, 'Registry inherited owner()')
        configs = [args[0] for target, sig, args, kind in rows
                   if target == u.REG and sig == 'getRoleConfig(bytes32)' and kind == 'config']
        self.assertEqual(set(configs), standard | {event_role, history_role},
                         'Registry config rows: standard union RoleConfigured union roleHistory')
        self.assertEqual(len(configs), len(set(configs)), 'Registry config rows are unique')


if __name__ == '__main__':
    unittest.main()
