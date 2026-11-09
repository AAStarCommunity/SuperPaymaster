#!/usr/bin/env python3
"""Focused controls for the formerly ambiguous proxy and calldata gate names."""
import types
import unittest
from unittest.mock import patch
from gate_assertions import assert_stop
import test_old_owner_isolation as base

o, a, u = base.o, base.a, base.u


class RenameControls(unittest.TestCase):
    def setUp(self):
        self.fixture = base.OldOwnerIsolationTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)

    def test_unexpected_proxy_other(self):
        self.fixture.test_unexpected_indirection_and_gate_removals()

    def test_unexpected_proxy_beacon(self):
        baseline, sources, build = self.fixture.source_fixture()
        pin = self.fixture.pin
        def rpc(method, params):
            if method == 'eth_getStorageAt' and params == [u.REG, o.BEACON_SLOT, pin['stateBlock']]:
                return base.raw([int(base.IMPL, 16)])
            return baseline(method, params)
        with patch.object(o, 'deployed_build', side_effect=build):
            with assert_stop(self, 'unexpected_proxy_beacon'):
                o.deployed_inventory(rpc, pin, sources)

    def test_old_owner_calldata_bytes_outer_tx(self):
        # Constructor bytecode is not interpreted as constructor arguments.
        # Deleting this guard therefore accepts the unchanged, well-formed fixture.
        bytecode = '0x60' + o.OLD[2:]
        step = dict(tx=dict(to=None, data=bytecode),
                    constructor=dict(bytecode=bytecode, signature='c()'))
        with assert_stop(self, 'old_owner_calldata_bytes_outer_tx'):
            o.assert_manifest_calldata([step], [])

    def test_old_owner_calldata_bytes_payload(self):
        # Unit-test the actual nested production helper, including all its guards.
        # An ordinary outer transaction reaches the outer bytes guard first.
        # Construct its closure without altering the production code object.
        code = next(item for item in o.assert_manifest_calldata.__code__.co_consts
                    if isinstance(item, types.CodeType) and item.co_name == 'inspect')
        signature = 'setOwner(address)'
        catalogue = {a.keccak(signature)[:10]: signature}
        def cell(value):
            return (lambda: value).__closure__[0]
        cells = {'catalogue': cell(catalogue), 'decoded': cell([]), 'inspect': cell(None)}
        inspect_payload = types.FunctionType(code, o.__dict__, 'inspect',
                                             (None, 0), tuple(cells[key] for key in code.co_freevars))
        cells['inspect'].cell_contents = inspect_payload
        with assert_stop(self, 'old_owner_calldata_bytes_payload'):
            inspect_payload(a.calldata(signature, o.OLD))

    def test_receipt_transaction_index_typed(self):
        import copy
        import test_manifest_exec as manifest
        fixture = manifest.SafeGovernanceTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        txhash = fixture.original_hashes['E755']['a']
        row = next(row for row in manifest.m.governance_entries(fixture.inputs) if row['entry']['hash'] == txhash)
        receipt = copy.deepcopy(fixture.chain['E755']['a']['receipt'])
        receipt['transactionIndex'] = 'invalid'
        for log in receipt['logs']:
            log['transactionIndex'] = 'invalid'
        with assert_stop(self, 'safe_gap_log_transactionIndex_typed'):
            manifest.m.governance_logs(receipt['logs'], row, receipt)


if __name__ == '__main__':
    unittest.main()
