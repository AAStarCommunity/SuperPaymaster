import importlib
import unittest
from unittest.mock import patch

class FailedSetTest(unittest.TestCase):
    def test_failed_set_inventory_and_external_value(self):
        m = importlib.import_module('deploylive_failed_set_check')
        cfg = {'registry': '0x'+'01'*20, 'gToken': '0x'+'02'*20, 'aPNTs': '0x'+'03'*20, 'handoverBootstrap': '0x'+'04'*20,
               'deploymentStartBlock': 1, 'guardians': [], 'genesisOperator': '0x'+'05'*20}
        class RPC:
            eth = 0
            foreign = 0
            def __call__(self, method, *args):
                if method == 'eth_getBalance': return hex(self.eth)
                if method == 'eth_getLogs':
                    if args[0].get('address'): return []
                    return [{'address': '0x'+'99'*20}]
                raise AssertionError(method)
            def call(self, token, sig, *args):
                if sig.startswith('balanceOf'): return '0x'+f'{self.foreign if token.endswith("99"*20) else 0:064x}'
                if sig.startswith('getUserRoles'): return '0x'+f'{32:064x}{0:064x}'
                raise AssertionError(sig)
        cfg.update({key: cfg['registry'] for key in m.CONTRACT_KEYS if key not in cfg})
        rpc = RPC(); output = []
        with patch('deploylive_failed_set_check.cast', return_value='0xtopic'):
            self.assertTrue(m.inventory(rpc, cfg, output.append))
            self.assertTrue(any('REGISTRATIONS' in line for line in output))
            rpc.eth = 1; self.assertFalse(m.inventory(rpc, cfg, output.append))
            rpc.eth = 0; rpc.foreign = 1; self.assertFalse(m.inventory(rpc, cfg, output.append))
            del cfg['spAdminImpl']
            with self.assertRaises(ValueError): m.inventory(rpc, cfg, output.append)
