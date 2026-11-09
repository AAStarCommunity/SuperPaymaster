#!/usr/bin/env python3
"""Per-label controls for finite Phase C and governance gate templates."""
import unittest
import test_manifest_phase_c as phase
import test_manifest_exec as manifest


class FiniteTemplateTests(phase.PhaseCTests):
    pass


# The fixture is shared; only the explicitly enumerated controls run in this file.
for name in dir(phase.PhaseCTests):
    if name.startswith('test_'):
        setattr(FiniteTemplateTests, name, None)


CASES = []


def add_build(gate, mutate, source_line):
    name = 'test_' + gate
    setattr(FiniteTemplateTests, name, phase.make_build_test(gate, mutate))
    CASES.append((FiniteTemplateTests, name, gate, source_line))


for label in ('bundler', 'accountOwner', 'verifyingSigner', 'account', 'accountImplementation'):
    add_build('phase_c_address_' + label,
              phase.data_case(['phaseC', label], phase.a.ZERO), 1383)
for label in phase.m.PC_RUNTIMES:
    add_build('phase_c_runtime_' + label,
              phase.data_case(['phaseC', 'runtimeKeccak', label], phase.a.EMPTY_KECCAK), 1392)
for label in phase.m.ARMS:
    add_build('phase_c_arm_fields_' + label,
              phase.data_case(['phaseC', 'rehearsal', 'arms', label, 'extra'], 1), 1405)
for label in ('owner', 'bundler', 'verifyingSigner'):
    add_build('phase_c_pin_identity_' + label,
              phase.pin_case(['phaseC', label, 'address'], '0x' + '99' * 20), 1478)
    add_build('phase_c_eoa_' + label,
              phase.pin_case(['phaseC', label, 'code'], '0x6000'), 1479)


class GovernanceTemplateTests(manifest.SafeGovernanceTests):
    pass


for name in dir(manifest.SafeGovernanceTests):
    if name.startswith('test_'):
        setattr(GovernanceTemplateTests, name, None)


def log_control(field):
    def test(self):
        log = self.chain['E755']['a']['receipt']['logs'][1]
        value = manifest.a.ZERO32 if field.endswith('Hash') else hex(manifest.a.qty(log[field]) + 2)
        self.stop('safe_gap_log_' + field, lambda: log.update({field: value}))
    return test


for label in ('transactionHash', 'blockHash', 'blockNumber', 'transactionIndex'):
    gate = 'safe_gap_log_' + label
    name = 'test_' + gate
    setattr(GovernanceTemplateTests, name, log_control(label))
    CASES.append((GovernanceTemplateTests, name, gate, 1678))


class ManifestTemplateTests(manifest.ManifestTests):
    pass


for name in dir(manifest.ManifestTests):
    if name.startswith('test_'):
        setattr(ManifestTemplateTests, name, None)


def add_manifest_control(gate, line, action):
    def test(self):
        action(self, gate)
    name = 'test_finite_' + gate
    setattr(ManifestTemplateTests, name, test)
    CASES.append((ManifestTemplateTests, name, gate, line))


def history_control(sid, kind):
    def action(self, gate):
        from collections import UserDict
        import copy
        from gate_assertions import assert_stop
        pin = copy.deepcopy(self.pin)
        if kind == 'status':
            pin['a3aHistory'][sid]['receipt']['status'] = '0x0'
        elif kind == 'history':
            pin['a3aHistory'][sid]['receipt'] = UserDict(pin['a3aHistory'][sid]['receipt'])
        if kind == 'reconcile':
            baseline = self.history_rpc()
            txhash = self.data['a3aPlan']['receipts'][sid]
            def rpc(method, params):
                value = baseline(method, params)
                return UserDict(value) if method == 'eth_getTransactionReceipt' and params == [txhash] else value
            with assert_stop(self, gate):
                manifest.m.reconcile_nonces(rpc, pin, self.inputs)
        else:
            with assert_stop(self, gate):
                manifest.m.validate_nonce_history(pin, self.inputs)
    return action


for sid in manifest.a.STEP_IDS:
    for kind, line in (('history', 1873), ('reconcile', 1899), ('status', 1876)):
        gate = ('a3a_status_' if kind == 'status' else 'a3a_mined_' + kind + '_') + sid
        add_manifest_control(gate, line, history_control(sid, kind))


def evidence_control(kind, suffix):
    def action(self, gate):
        from gate_assertions import assert_stop
        from pathlib import Path
        ref = dict(self.data['releaseEvidence'][kind])
        if suffix == '_path':
            # Path is usable by pathlib but rejected by the explicit wire-string guard.
            ref['path'] = Path(ref['path'])
        else:
            ref['sha256'] = 'invalid' if suffix == '_hash' else 'f' * 64
        with assert_stop(self, gate):
            manifest.m.evidence_file(ref, kind)
    return action


for kind in manifest.m.EVIDENCE_KINDS:
    for suffix in ('', '_hash', '_path'):
        add_manifest_control('evidence_' + kind + suffix, 132, evidence_control(kind, suffix))


def fraud_control(label, field):
    def action(self, gate):
        import copy
        from gate_assertions import assert_stop
        value = copy.deepcopy(self.export)
        row = next(n for n in value['export']['mustReject'] if n['id'] == label)
        row[field] = [manifest.ANNI] * 3 if field == 'guiltyGuardians' else '0x00'
        with assert_stop(self, gate):
            manifest.m.fraud_fixture(self.file_ref('finite-negative', value))
    return action


for label in ('N2', 'N3', 'N4'):
    add_manifest_control('fraud_' + label + '_guardians', 439, fraud_control(label, 'guiltyGuardians'))
for label in ('N1', 'N2', 'N4'):
    add_manifest_control('fraud_' + label + '_proof', 441, fraud_control(label, 'fraudProof'))


def detail_control(kind, label):
    def action(self, gate):
        import json
        from pathlib import Path
        from gate_assertions import assert_stop
        value = json.loads(Path(self.data['releaseEvidence'][kind]['path']).read_text())
        if kind == 'mutation':
            value['controls'][label]['restored'] = 'FAIL'
        else:
            value['suites'][label]['skipped'] = 1
        with assert_stop(self, gate):
            manifest.m.validate_evidence_details(value, kind)
    return action


for label in manifest.m.MUTATIONS:
    add_manifest_control('evidence_mutation_' + label, 203, detail_control('mutation', label))
for label in manifest.m.DVT_SUITES:
    add_manifest_control('evidence_suite_' + label, 211, detail_control('dvt-ci', label))


def gap_field_control(field):
    def test(self):
        tx = self.chain['A99']['a']['tx']
        replacement = manifest.a.DEPLOYER if field == 'from' else manifest.a.ZERO if field == 'to' else hex(manifest.a.qty(tx[field]) + 1)
        self.stop('safe_gap_' + field, lambda: tx.update({field: replacement}))
    return test


for label in ('from', 'to', 'nonce', 'gas', 'maxFeePerGas', 'maxPriorityFeePerGas', 'value', 'chainId'):
    gate = 'safe_gap_' + label
    name = 'test_finite_' + gate
    setattr(GovernanceTemplateTests, name, gap_field_control(label))
    CASES.append((GovernanceTemplateTests, name, gate, 1710))


def nonce_control(label, kind):
    def action(self, gate):
        import copy
        import json
        from pathlib import Path
        from gate_assertions import assert_stop
        pin, inputs = copy.deepcopy(self.pin), copy.deepcopy(self.inputs)
        plan = json.loads(Path(inputs['data']['a3aPlan']['path']).read_text())
        rows = [s for s in plan['steps'] if s['tx']['from'] == pin['senders'][label]['address']]
        last = max(rows, key=lambda s: manifest.a.qty(s['tx']['nonce']))
        if kind == 'last':
            last['id'] = 'wrong-final-step'
            inputs['data']['a3aPlan'].update(self.file_ref('finite-last', plan))
        else:
            start = manifest.a.qty(last['tx']['nonce']) + 1
            pin['senders'][label]['nonce'] = start + (1 if kind == 'nonce' else -1)
            inputs['data']['a3aPlan']['nonceGaps'] = []
            inputs['data']['safeGovernanceGaps'] = []
        with assert_stop(self, gate):
            manifest.m.nonce_expectations(pin, inputs)
    return action


for label in ('deployer', 'approver', 'executor'):
    for kind, prefix, line in (('last', 'a3a_last_', 1824), ('nonce', 'prepin_nonce_', 1831),
                               ('floor', 'prepin_nonce_floor_', 1832)):
        add_manifest_control(prefix + label, line, nonce_control(label, kind))


def pending_nonce_control(label):
    def test(self):
        import contextlib
        from unittest.mock import patch
        from gate_assertions import assert_stop
        target = {'owner': manifest.PC_OWNER, 'bundler': manifest.PC_BUNDLER,
                  'verifyingSigner': manifest.PC_SIGNER}[label]
        rpc, patches = self.collect_fixture()
        with contextlib.ExitStack() as stack:
            for p in patches:
                stack.enter_context(p)
            stack.enter_context(patch.object(phase.a, 'nonce', side_effect=lambda rpc, who, block:
                                            int(who == target and block == 'pending')))
            with assert_stop(self, 'phase_c_pending_nonce_' + label):
                phase.m.collect_phase_c(rpc, '0x100', self.inputs, self.pin)
    return test


for label in ('owner', 'bundler', 'verifyingSigner'):
    gate = 'phase_c_pending_nonce_' + label
    name = 'test_finite_' + gate
    setattr(FiniteTemplateTests, name, pending_nonce_control(label))
    CASES.append((FiniteTemplateTests, name, gate, 1438))


def rehearsal_control(failure, gate, runtime_target=None):
    """Specialize the existing complete fake-chain fixture to one exact subcase."""
    import ast
    import inspect
    import textwrap
    from gate_assertions import assert_stop
    tree = ast.parse(textwrap.dedent(inspect.getsource(manifest.ManifestTests.test_fraud_rehearsal_valid_invalid_and_restoration)))
    class Specialize(ast.NodeTransformer):
        def visit_For(self, node):
            if isinstance(node.target, ast.Name) and node.target.id == 'failure':
                node.iter = ast.Tuple(elts=[ast.Constant(failure)], ctx=ast.Load())
            return self.generic_visit(node)
        def visit_Call(self, node):
            if (isinstance(node.func, ast.Attribute) and node.func.attr == 'assertRaises'
                    and len(node.args) == 1 and ast.unparse(node.args[0]) == 'a.Gate'):
                return ast.copy_location(ast.Call(func=ast.Name(id='assert_stop', ctx=ast.Load()),
                    args=[ast.Name(id='self', ctx=ast.Load()), ast.Constant(gate)], keywords=[]), node)
            return self.generic_visit(node)
        def visit_IfExp(self, node):
            if runtime_target and ast.unparse(node.test) == "failure == 'runtime'":
                node.test = ast.BoolOp(op=ast.And(), values=[node.test,
                    ast.Compare(left=ast.Name(id='target', ctx=ast.Load()), ops=[ast.Eq()],
                                comparators=[ast.Name(id=runtime_target, ctx=ast.Load())])])
            return self.generic_visit(node)
    namespace = dict(manifest.__dict__, assert_stop=assert_stop)
    exec(compile(ast.fix_missing_locations(Specialize().visit(tree)), '<finite-rehearsal-fixture>', 'exec'), namespace)
    return namespace['test_fraud_rehearsal_valid_invalid_and_restoration']


for label, target in (('A7', 'agg'), ('A12a', 'verifier')):
    gate = 'fraud_runtime_' + label
    name = 'test_finite_' + gate
    setattr(ManifestTemplateTests, name, rehearsal_control('runtime', gate, target))
    CASES.append((ManifestTemplateTests, name, gate, 536))
for label in ('N1', 'N2', 'N3'):
    gate = 'fraud_revert_' + label
    name = 'test_finite_' + gate
    setattr(ManifestTemplateTests, name, rehearsal_control(label, gate))
    CASES.append((ManifestTemplateTests, name, gate, 592))


def runtime_control(label):
    def action(self, gate):
        import copy
        from unittest.mock import patch
        from gate_assertions import assert_stop
        if label == 'OverIssueFraudProofVerifier':
            artifact = copy.deepcopy(manifest.m.verifier_artifact(self.data['verifier']))
            artifact['runtimeIdentity'] = dict(artifactRuntime='0x', ranges=[])
            patched = patch.object(manifest.m, 'verifier_artifact', return_value=artifact)
        else:
            artifacts = copy.deepcopy(manifest.ART)
            artifacts['contracts'][label]['runtimeIdentity'] = dict(artifactRuntime='0x', ranges=[])
            patched = patch.object(manifest.m, 'rebuild', return_value=artifacts)
        with patched, assert_stop(self, gate):
            manifest.m.build_plan(self.pin, self.inputs)
    return action


for label in ('SuperPaymaster', 'GlobalTierSource', 'AOAProtocolRegistry', 'xPNTsTokenV2Ext',
              'xPNTsTokenV2', 'xPNTsFactoryV2', 'SuperPaymasterLens', 'Registry', 'BLSAggregator',
              'OverIssueFraudProofVerifier'):
    add_manifest_control('nonempty_runtime_' + label, 2211, runtime_control(label))


def baseline_commit_control(label):
    def action(self, gate):
        import copy
        from unittest.mock import patch
        from gate_assertions import assert_stop
        artifacts = copy.deepcopy(manifest.BASELINES)
        artifacts[label]['commit'] = 'f' * 40
        with patch.object(manifest.m, 'rebuild_baselines', return_value=artifacts), assert_stop(self, gate):
            manifest.m.build_plan(self.pin, self.inputs)
    return action


for label in ('F1TestToken', 'F1Oracle', 'VerifyingPaymaster', 'TokenPaymaster'):
    add_manifest_control('C_baseline_commit_' + label, 2366, baseline_commit_control(label))


def layout_control(contract, label):
    def action(self, gate):
        import copy
        from gate_assertions import assert_stop
        plan = copy.deepcopy(self.plan)
        entries = plan['rebuild']['contracts'][contract]['storageLayout']['storage']
        next(x for x in entries if x['label'] == label)['offset'] = 1
        with assert_stop(self, gate):
            manifest.m.layout_slot(plan, contract, label)
    return action


for label, contract in (('cachedPrice', 'SuperPaymaster'), ('_auto', 'xPNTsTokenV2'), ('_budget', 'xPNTsTokenV2')):
    add_manifest_control('C_control_layout_' + label, 3104, layout_control(contract, label))


def baseline_artifact_control(label, kind):
    def test(self):
        import contextlib
        import json
        from unittest.mock import patch
        from gate_assertions import assert_stop
        gate = 'baseline_' + kind + '_' + label
        with contextlib.ExitStack() as stack:
            for p in self.baseline_tree():
                stack.enter_context(p)
            original = phase.a.archive_commit.side_effect
            def archive(repo, commit, tree):
                original(repo, commit, tree)
                if kind == 'immutables':
                    path = tree / 'out/F1Fixtures.sol' / (label + '.json')
                    art = json.loads(path.read_text())
                    art['deployedBytecode']['immutableReferences'] = {'7': [dict(start=0, length=32)]}
                    path.write_text(json.dumps(art))
                else:
                    path = tree / phase.m.BASELINE_ARTIFACTS[label]
                    art = json.loads(path.read_text())
                    if kind == 'source':
                        art['sourceSha256'] = '0' * 64
                    else:
                        art['abi'] *= 2
                    path.write_text(json.dumps(art))
            stack.enter_context(patch.object(phase.a, 'archive_commit', side_effect=archive))
            if kind == 'immutables':
                stack.enter_context(patch.object(phase.a, 'immutable_identity', side_effect=lambda art, info, name, allowed:
                    dict(artifactRuntime=art['deployedBytecode']['object'],
                         ranges=[dict(name='unexpected', start=0, length=32)] if name == label else [dict(name='MINTER', start=0, length=32)])))
            with assert_stop(self, gate):
                phase.REAL_REBUILD_BASELINES.__wrapped__('a' * 40)
    return test


for kind, labels, line in (('immutables', ('F1TestToken', 'F1Oracle'), 1330),
                           ('source', ('VerifyingPaymaster', 'TokenPaymaster'), 1336),
                           ('constructor_count', ('VerifyingPaymaster', 'TokenPaymaster'), 1338)):
    for label in labels:
        gate = 'baseline_' + kind + '_' + label
        name = 'test_finite_' + gate
        setattr(FiniteTemplateTests, name, baseline_artifact_control(label, kind))
        CASES.append((FiniteTemplateTests, name, gate, line))


import test_old_owner_isolation as isolation


class IsolationTemplateTests(isolation.OldOwnerIsolationTests):
    pass


for name in dir(isolation.OldOwnerIsolationTests):
    if name.startswith('test_'):
        setattr(IsolationTemplateTests, name, None)


def owner_control(label, target):
    def test(self):
        from gate_assertions import assert_stop
        sig = 'daoMultisig()' if label == 'MySBT' else 'owner()'
        query = ('eth_call', str([dict(to=target, data=isolation.a.calldata(sig)), self.pin['stateBlock']]))
        rpc = isolation.fixture_rpc(self.pin, {query: isolation.raw([0])})
        with assert_stop(self, 'old_owner_control_' + label):
            isolation.o.audit(rpc, self.pin, isolation.inventory(), isolation.FIXTURE_CALLSITE_TARGETS)
    return test


for label, target in (('GTokenStaking', isolation.STAKING), ('GToken', isolation.GTOKEN),
                      ('xPNTsFactory', isolation.FACTORY), ('MySBT', isolation.SBT),
                      ('PaymasterFactory', isolation.o.PAYMASTER_FACTORY)):
    gate = 'old_owner_control_' + label
    name = 'test_finite_' + gate
    setattr(IsolationTemplateTests, name, owner_control(label, target))
    CASES.append((IsolationTemplateTests, name, gate, 733))


def safe_control(label):
    def test(self):
        from gate_assertions import assert_stop
        gate = 'old_owner_safe_' + label
        _, key, value = next(row for row in self.mutations() if row[0] == gate)
        with assert_stop(self, gate):
            isolation.o.audit(isolation.fixture_rpc(self.pin, {key: value}), self.pin,
                              isolation.inventory(), isolation.FIXTURE_CALLSITE_TARGETS)
    return test


for label in ('guard', 'fallback'):
    gate = 'old_owner_safe_' + label
    name = 'test_finite_' + gate
    setattr(IsolationTemplateTests, name, safe_control(label))
    CASES.append((IsolationTemplateTests, name, gate, 868))


def revalidated_control(label):
    def test(self):
        from gate_assertions import assert_stop
        section = isolation.evidence(self.pin)
        section['unexpected'] = True
        endpoints = section['endpointResults']
        section['endpointResults'] = {name: endpoints[name] for name in (label, 'secondary' if label == 'primary' else 'primary')}
        with assert_stop(self, 'old_owner_revalidated_' + label):
            isolation.o.validate(section, self.pin, isolation.inventory(), isolation.FIXTURE_CALLSITE_TARGETS)
    return test


for label in ('primary', 'secondary'):
    gate = 'old_owner_revalidated_' + label
    name = 'test_finite_' + gate
    setattr(IsolationTemplateTests, name, revalidated_control(label))
    CASES.append((IsolationTemplateTests, name, gate, 916))


def full_creation_control(label):
    def action(self, gate):
        import json
        from pathlib import Path
        from gate_assertions import assert_stop
        value = json.loads(Path(self.data['releaseEvidence']['reproducible-build']['path']).read_text())
        value['contracts'][label]['strippedCreationKeccak'] = manifest.a.ZERO32
        with assert_stop(self, gate):
            manifest.m.validate_evidence_details(value, 'reproducible-build')
    return action


for label in manifest.m.NAMES:
    add_manifest_control('evidence_full_creation_' + label, 295, full_creation_control(label))


def fraud_uint_control(label):
    def action(self, gate):
        import copy
        from gate_assertions import assert_stop
        value = copy.deepcopy(self.export)
        key = {'pid': 'proposalId', 'fraudProofId': 'fraudProofId', 'signerMask': 'signerMask'}[label]
        value['export']['valid'][key] = '0x0' if label == 'signerMask' else '0'
        if label == 'pid':
            value['export']['forkState']['commitment']['key'] = '0'
        with assert_stop(self, gate):
            manifest.m.fraud_fixture(self.file_ref('finite-uint', value))
    return action


for label in ('pid', 'fraudProofId', 'signerMask'):
    add_manifest_control('fraud_uint_' + label, 460, fraud_uint_control(label))


def pop_control(label):
    def action(self, gate):
        import copy
        from gate_assertions import assert_stop
        data = copy.deepcopy(self.data)
        first, second = data['pop'][:2]
        second[label] = first[label]
        index = 0 if label == 'validator' else 5
        offset = 10 + index * 64
        second['calldata'] = second['calldata'][:offset] + first['calldata'][offset:offset+64] + second['calldata'][offset+64:]
        with assert_stop(self, gate):
            manifest.m.validate_external(data)
    return action


for label in ('validator', 'slot'):
    add_manifest_control('pop_unique_' + label, 659, pop_control(label))


class TraceTemplateTests(unittest.TestCase):
    pass


def trace_control(label):
    def test(self):
        from gate_assertions import assert_stop
        step = dict(id='D.transfer', tx={'from': manifest.u.DEPLOYER, 'data': '0x1234'})
        trace = {'from': manifest.u.DEPLOYER, 'to': manifest.u.SAFE, 'input': '0x1234', 'type': 'CALL'}
        def rpc(method, params):
            self.assertEqual(method, 'debug_traceTransaction')
            return trace
        manifest.m.handover_trace(rpc, {}, step, {'transactionHash': manifest.a.ZERO32})
        trace[label] = '0x5678' if label == 'input' else manifest.a.ZERO
        with assert_stop(self, 'handover_trace_' + label):
            manifest.m.handover_trace(rpc, {}, step, {'transactionHash': manifest.a.ZERO32})
    return test


for label in ('from', 'to', 'input'):
    gate = 'handover_trace_' + label
    name = 'test_finite_' + gate
    setattr(TraceTemplateTests, name, trace_control(label))
    CASES.append((TraceTemplateTests, name, gate, 2597))


def handover_status_control(group, signature, gate):
    import ast
    import inspect
    import textwrap
    from gate_assertions import assert_stop
    tree = ast.parse(textwrap.dedent(inspect.getsource(manifest.ManifestTests.test_handover_controls_assert_reasons_success_and_restore)))
    target = {'sp': 'u.SP', 'aggregator': "self.plan['addresses']['BLSAggregator']", 'old_aggregator': 'm.OLD_AGGREGATOR'}[group]
    selected = ast.parse("failure == 'positive' and tx['to'] == " + target +
                         " and tx['data'][:10] == a.keccak(" + repr(signature) + ")[:10]", mode='eval').body
    class Specialize(ast.NodeTransformer):
        def visit_For(self, node):
            if isinstance(node.target, ast.Name) and node.target.id == 'failure':
                node.iter = ast.Tuple(elts=[ast.Constant('positive')], ctx=ast.Load())
            return self.generic_visit(node)
        def visit_Call(self, node):
            if (isinstance(node.func, ast.Attribute) and node.func.attr == 'assertRaises'
                    and len(node.args) == 1 and ast.unparse(node.args[0]) == 'a.Gate'):
                return ast.copy_location(ast.Call(func=ast.Name(id='assert_stop', ctx=ast.Load()),
                    args=[ast.Name(id='self', ctx=ast.Load()), ast.Constant(gate)], keywords=[]), node)
            return self.generic_visit(node)
        def visit_IfExp(self, node):
            if ast.unparse(node.test) == "failure == 'positive'":
                node.test = selected
            return self.generic_visit(node)
    namespace = dict(manifest.__dict__, assert_stop=assert_stop)
    exec(compile(ast.fix_missing_locations(Specialize().visit(tree)), '<finite-handover-fixture>', 'exec'), namespace)
    return namespace['test_handover_controls_assert_reasons_success_and_restore']


for group, signatures in (('sp', ('setProtocolFee(uint256)',)),
                          ('aggregator', ('setSlashThreshold(uint8,uint8)', 'setGuardianSlashBps(uint16)')),
                          ('old_aggregator', ('setSlashThreshold(uint8,uint8)', 'setGuardianSlashBps(uint16)'))):
    for signature in signatures:
        gate = 'handover_' + group + '_' + signature.split('(')[0] + '_status'
        name = 'test_finite_' + gate
        setattr(ManifestTemplateTests, name, handover_status_control(group, signature, gate))
        CASES.append((ManifestTemplateTests, name, gate, 2661))


def control_suffix(label, suffix):
    def test(self):
        import contextlib
        from unittest.mock import patch
        from gate_assertions import assert_stop
        chain = phase.Chain(self.plan, 'after_phase_c')
        original = phase.m.sp_attempt_precheck
        expected = 'precheck_allowance' if label == 'C_allowance_exhausted' else 'precheck_total'
        restores = 0
        def rpc(method, params):
            nonlocal restores
            result = chain(method, params)
            if method == 'evm_revert':
                restores += 1
                if suffix == '_restore' and restores == (1 if label == 'C_allowance_exhausted' else 2):
                    return False
            return result
        def check(*args, **kwargs):
            try:
                return original(*args, **kwargs)
            except phase.a.Gate as error:
                if suffix == '_gate' and error.record['gate'] == expected:
                    raise phase.a.Gate('different_control_gate', 0, 1) from None
                raise
        with contextlib.ExitStack() as stack:
            for p in chain.patches():
                stack.enter_context(p)
            stack.enter_context(patch.object(phase.m, 'sp_attempt_precheck', side_effect=check))
            with assert_stop(self, label + suffix):
                phase.m.phase_c_controls(rpc, self.plan, 'after_phase_c', [], chain.context)
    return test


for label in ('C_allowance_exhausted', 'C_total_exhausted'):
    for suffix in ('_gate', '_restore'):
        gate = label + suffix
        name = 'test_finite_' + gate
        setattr(FiniteTemplateTests, name, control_suffix(label, suffix))
        CASES.append((FiniteTemplateTests, name, gate, 3202))


def history_gap_control(label):
    def action(self, gate):
        import copy
        import json
        from pathlib import Path
        from gate_assertions import assert_stop
        inputs = copy.deepcopy(self.inputs)
        spec = inputs['data']['a3aPlan']
        plan = json.loads(Path(spec['path']).read_text())
        plan['nonceGaps'] = [{'from': manifest.a.SENDERS[label], 'nonce': '0x1', 'hash': '0x' + 'ab' * 32}]
        spec.update(self.file_ref('finite-gap', plan))
        with assert_stop(self, gate):
            manifest.m.history_steps(self.pin, inputs)
    return action


for label in ('approver', 'executor'):
    add_manifest_control('a3a_nonce_complete_' + label, 1848, history_gap_control(label))


def anni_fields_control(self, gate):
    import copy
    from gate_assertions import assert_stop
    pin = copy.deepcopy(self.pin)
    pin['senders']['anni']['extra'] = True
    with assert_stop(self, gate):
        manifest.m.build_plan(pin, self.inputs)


add_manifest_control('sender_fields_anni', 2148, anni_fields_control)


if __name__ == '__main__':
    unittest.main()
