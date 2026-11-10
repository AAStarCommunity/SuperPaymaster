#!/usr/bin/env python3
"""Offline authority reads at pin, pre-send, and closing."""
import copy
import unittest
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
                    action = lambda: m.isolation.audit(rpc, self.pin, spec_inventory)
                    gate = 'old_owner_role_admin_'+role['name'] if args else 'old_owner_authority_Registry_'+owner_row['name']
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


if __name__ == '__main__':
    unittest.main()
