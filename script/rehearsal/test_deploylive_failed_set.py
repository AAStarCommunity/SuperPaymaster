import importlib
import unittest
from unittest.mock import patch

class FailedSetTest(unittest.TestCase):
    def test_failed_set_inventory_and_external_value(self):
        m = importlib.import_module('deploylive_failed_set_check')
        cfg = {'registry': '0x'+'01'*20, 'gToken': '0x'+'02'*20, 'aPNTs': '0x'+'03'*20, 'handoverBootstrap': '0x'+'04'*20,
               'externalTokens': {'31337': [{'label': 'Fixture', 'address': '0x'+'88'*20, 'decimals': 18}]},
               'deploymentStartBlock': 1, 'guardians': [], 'genesisOperator': '0x'+'05'*20}
        class RPC:
            eth = 0
            foreign = 0
            def __call__(self, method, *args):
                if method == 'eth_chainId': return hex(31337)
                if method == 'eth_getCode': return '0x00'
                if method == 'eth_getBalance': return hex(self.eth)
                if method == 'eth_getLogs':
                    assert args[0]['fromBlock'] == '0x1', 'must start at deployment block'
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


class ExternalTokensTest(unittest.TestCase):
    def run_inventory(self, mode):
        m = importlib.import_module('deploylive_failed_set_check')
        token = '0x' + '88'*20
        cfg = {key: '0x'+f'{i+1:040x}' for i, key in enumerate(m.CONTRACT_KEYS)}
        cfg.update(deploymentStartBlock=1, guardians=[], genesisOperator='0x'+'77'*20,
                   externalTokens={'31337': [{'label': 'Fixture token', 'address': token, 'decimals': 6}]})
        if mode == 'empty_group': cfg['externalTokens']['31337'] = []
        if mode == 'label': cfg['externalTokens']['31337'][0]['label'] = ''
        if mode == 'address': cfg['externalTokens']['31337'][0]['address'] = '0x1'
        if mode == 'decimals': cfg['externalTokens']['31337'][0]['decimals'] = True
        reads = []
        class RPC:
            def __call__(self, method, *args):
                if method == 'eth_chainId': return hex(999 if mode == 'unknown' else 31337)
                if method == 'eth_getCode': return '0x' if mode == 'no_code' else '0x00'
                if method == 'eth_getBalance': return '0x0'
                if method == 'eth_getLogs': return []  # Token deliberately emits no Transfer.
                raise AssertionError(method)
            def call(self, target, sig, *args):
                if sig.startswith('getUserRoles'): return '0x'+f'{32:064x}{0:064x}'
                reads.append((target, args[0]))
                if target == token and mode == 'unreadable': return '0x'
                value = int(target == token and args[0] == cfg['spAdminImpl'] and mode == 'positive')
                return '0x'+f'{value:064x}'
        output = []
        with patch('deploylive_failed_set_check.cast', return_value='0xtopic'):
            ok = m.inventory(RPC(), cfg, output.append)
        if mode == 'zero':
            self.assertTrue(ok)
            self.assertEqual({a for t, a in reads if t == token}, {cfg[k] for k in m.CONTRACT_KEYS})
        else:
            self.assertFalse(ok)
            self.assertTrue(any(line.startswith('FAIL') for line in output))
        if mode == 'no_code': self.assertFalse(any(t == token for t, _ in reads))

    def test_all_zero(self): self.run_inventory('zero')
    def test_positive_without_transfer_log(self): self.run_inventory('positive')
    def test_unreadable(self): self.run_inventory('unreadable')
    def test_no_code(self): self.run_inventory('no_code')
    def test_unknown_chain(self): self.run_inventory('unknown')
    def test_empty_group(self): self.run_inventory('empty_group')
    def test_invalid_label(self): self.run_inventory('label')
    def test_invalid_address(self): self.run_inventory('address')
    def test_invalid_decimals(self): self.run_inventory('decimals')
