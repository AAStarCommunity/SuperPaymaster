"""Direct offline malformed-return fixtures for reusable typed boundaries."""
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import sp_upgrade_exec as u
import old_owner_isolation as o
import a3a_send as send
from gate_assertions import assert_stop

a = u.a
GOOD_HASH = '0x' + '11' * 32
BAD_HASH = '0X' + '11' * 32


def keccak():
    with patch.object(a, 'cast', return_value=BAD_HASH):
        a.keccak('0x00')


def calldata():
    with patch.object(a, 'cast', return_value='0X00'):
        a.calldata('owner()')


def call():
    with patch.object(a, 'cast', return_value='0x00'):
        a.call(lambda method, params: '0X00', a.ZERO, 'owner()')


def local_keccak():
    with patch.object(send, 'signer_env', return_value={}), patch.object(
            send.subprocess, 'run', return_value=SimpleNamespace(returncode=0, stdout=BAD_HASH)):
        send.local_keccak('0x00')


def signed_hash():
    tx = dict(nonce='0x0', gas='0x5208', maxFeePerGas='0x1', maxPriorityFeePerGas='0x1',
              value='0x0', to=a.ZERO, data='0x', **{'from': a.DEPLOYER})
    decoded = {k: tx[k] for k in ('nonce', 'gas', 'maxFeePerGas', 'maxPriorityFeePerGas', 'value', 'to')}
    decoded.update(type='0x2', chainId=hex(a.CHAIN), input='0x', accessList=[], signer=a.DEPLOYER,
                   hash=BAD_HASH)
    send.check_signed(decoded, tx)


ACTIONS = {
    'rpc_result_qty_value': lambda: a.qty('0X0'),
    'rpc_result_keccak_keccak': keccak,
    'rpc_result_rpc_keccak_data': lambda: a.rpc_keccak(lambda method, params: GOOD_HASH, '0X00'),
    'rpc_result_rpc_keccak_web3_sha3': lambda: a.rpc_keccak(lambda method, params: BAD_HASH, '0x00'),
    'rpc_result_calldata_calldata': calldata,
    'rpc_result_call_eth_call': call,
    'rpc_result_block_data_hash': lambda: a.block_data(
        lambda method, params: dict(hash=BAD_HASH, number='0x1', timestamp='0x1'), '0x1'),
    'rpc_result_cbor_tail_code': lambda: a.cbor_tail('0X6000a00001'),
    'rpc_result_require_deployed_eth_getCode': lambda: a.require_deployed(lambda method, params: '0X00', a.ZERO),
    'rpc_result_local_keccak_value': local_keccak,
    'rpc_result_check_signed_hash': signed_hash,
    'rpc_result_uints_raw': lambda: u.uints('0X' + '00' * 32),
    'rpc_result_code_eth_getCode': lambda: u.code(lambda method, params: '0X00', a.ZERO, '0x1'),
    'rpc_result_clone_implementation_code': lambda: o.clone_implementation(
        '0X363d3d373d3d3d363d73' + '11' * 20 + '5af43d82803e903d91602b57fd5bf3'),
}


class TypedBoundaryTests(unittest.TestCase):
    pass


def control(gate, action):
    def test(self):
        with assert_stop(self, gate):
            action()
    return test


for gate, action in ACTIONS.items():
    setattr(TypedBoundaryTests, 'test_' + gate, control(gate, action))


if __name__ == '__main__':
    unittest.main()
