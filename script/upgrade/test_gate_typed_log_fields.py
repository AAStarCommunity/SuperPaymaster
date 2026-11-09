"""Malformed JSON-RPC log fields are injected before any production validation."""
import copy
import unittest
from unittest.mock import patch
import test_old_owner_isolation as f
import test_gate_template_controls as templates
from gate_assertions import assert_stop

a, u, o = f.a, f.u, f.o
m = templates.manifest.m
CASES = {}


class IsolationLogFields(f.OldOwnerIsolationTests):
    pass


class ManifestLogFields(templates.ManifestTemplateTests):
    pass


class DeltaLogFields(templates.manifest.DeltaTests):
    pass


def register(cls, gate, action):
    def test(self):
        with assert_stop(self, gate): action(self)
    name = 'test_' + gate
    setattr(cls, name, test)
    CASES[gate] = 'test_gate_typed_log_fields.' + cls.__name__ + '.' + name


def mutate_logs(baseline, mutate):
    def rpc(method, params):
        result = copy.deepcopy(baseline(method, params))
        if method == 'eth_getLogs':
            for log in result:
                mutate(log, params[0])
        return result
    if hasattr(baseline, 'fork'): rpc.fork = baseline.fork
    return rpc


for field in ('1', 'blockNumber', 'blockHash'):
    def audit(self, field=field):
        baseline = f.fixture_rpc(self.pin)
        topic = f.inventory()['Registry']['roleEventTopic']
        def mutate(log, query):
            if log['address'] == u.REG and log['topics'][0] == topic:
                if field == '1': log['topics'][1] = '0X' + log['topics'][1][2:]
                else: log[field] = '0X' + log[field][2:]
        o.audit(mutate_logs(baseline, mutate), self.pin, f.inventory(), f.FIXTURE_CALLSITE_TARGETS)
    register(IsolationLogFields, 'rpc_result_audit_' + field, audit)

for field in ('data', 'topic', 'blockNumber', 'transactionHash', 'transactionIndex', 'logIndex'):
    def history(self, field=field):
        baseline = f.fixture_rpc(self.pin)
        def mutate(log, query):
            if log['address'] != u.REG: return
            if field == 'data':
                if log['topics'][0] == a.keccak(o.REGISTERED):
                    log['data'] = '0X' + log['data'][2:]
            elif field == 'topic': log['topics'][1] = '0X' + log['topics'][1][2:]
            else: log[field] = '0X' + log[field][2:]
        o.role_history(mutate_logs(baseline, mutate), self.pin, u.REG, f.inventory()['Registry'], 1)
    register(IsolationLogFields, 'rpc_result_role_history_' + field, history)


def delta(self):
    baseline = self.rpc()
    rpc = mutate_logs(baseline, lambda log, query: log.update(blockNumber='0X' + log['blockNumber'][2:]))
    m.post_pin_delta(rpc, self.pin, self.block)


register(DeltaLogFields, 'rpc_result_scan_blockNumber', delta)


def approval(self):
    baseline, token, holder = self.approval_rpc(self.pin['stateBlock'], amount=0)
    def mutate(log, query):
        log['topics'][1] = '0X' + log['topics'][1][2:]
    m.old_timelock_holds_nothing(mutate_logs(baseline, mutate), self.pin, self.pin['stateBlock'])


register(ManifestLogFields, 'rpc_result_old_timelock_holds_nothing_1', approval)


for method, gate in [('eth_call', 'rpc_result_call_eth_call_3'),
                     ('eth_getStorageAt', 'rpc_result_storage_eth_getStorageAt')]:
    def audit_return(self, method=method):
        baseline = f.fixture_rpc(self.pin)
        def rpc(name, params):
            value = baseline(name, params)
            return '0X' + value[2:] if name == method else value
        rpc.fork = baseline.fork
        o.audit(rpc, self.pin, f.inventory(), f.FIXTURE_CALLSITE_TARGETS)
    register(IsolationLogFields, gate, audit_return)


for suffix, method, slot in [('eth_getCode', 'eth_getCode', None),
                             ('eth_getStorageAt', 'eth_getStorageAt', o.IMPLEMENTATION_SLOT),
                             ('eth_getStorageAt_2', 'eth_getStorageAt', o.BEACON_SLOT)]:
    def deployed(self, method=method, slot=slot):
        baseline, sources, build = self.source_fixture()
        def rpc(name, params):
            value = baseline(name, params)
            if name == method and params[-1] == self.pin['stateBlock'] and (slot is None or params[1] == slot):
                return '0X' + value[2:]
            return value
        with patch.object(o, 'deployed_build', side_effect=build):
            o.deployed_inventory(rpc, self.pin, sources)
    register(IsolationLogFields, 'rpc_result_deployed_inventory_' + suffix, deployed)

for is_storage, suffix in [(True, 'raw'), (False, 'raw_2')]:
    def fork_return(self, is_storage=is_storage):
        baseline = f.fixture_fork(self.pin)
        if is_storage:
            case = dict(sender=u.SAFE, gate='old_owner_safe_guard', guard=True,
                        transactions=[dict(target=u.SAFE, signature='setGuard(address)', args=['$ACCOUNT'])],
                        getter=dict(target=u.SAFE, slot=a.keccak('guard_manager.guard.address')))
        else:
            role = f.inventory()['TimelockController']['roles'][0]['value']
            case = dict(sender=u.TL, gate='fixture_role',
                        transactions=[dict(target=u.TL, signature='grantRole(bytes32,address)', args=[role,'$ACCOUNT'])],
                        getter=dict(target=u.TL, signature='hasRole(bytes32,address)', args=[role,'$ACCOUNT']))
        def rpc(method, params):
            value = baseline(method, params)
            if method == ('eth_getStorageAt' if is_storage else 'eth_call'):
                return '0X' + value[2:]
            return value
        rpc.local = True
        o.fork_probe(rpc, self.pin, case)
    register(IsolationLogFields, 'rpc_result_fork_probe_' + suffix, fork_return)


def load_tests(loader, tests, pattern):
    return unittest.TestSuite(loader.loadTestsFromName(name) for name in CASES.values())


if __name__ == '__main__':
    unittest.main()
