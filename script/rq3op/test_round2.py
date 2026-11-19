import re
from unittest.mock import patch
from test_three_arm import ThreeArm, q, m, a, t

class Round2(ThreeArm):
    def setUp(self):
        super().setUp()
        self.cal['arms']['SP']['postOp']=400000

    def test_all_fields_use_factor(self):
        for i,arm in enumerate(m.ARMS):
            self.cal['arms'][arm]['paymasterVerification']=83001+i*170003
        pc=next(iter(self.build()['plans'].values()))['phaseC']
        for arm in m.ARMS:
            for field in q.CALIBRATION_FIELDS:
                self.assertEqual(pc['bounds'][arm][field],q.scale(self.cal['arms'][arm][field],self.inputs['gasFactor']))

    def test_postop_floor_applies_when_scaled_is_below(self):
        # DSR ruling (b): max(measured*gasFactor, minPostOpGas); the floor is recorded, not hidden.
        self.cal['arms']['SP']['postOp']=1
        pc=next(iter(self.build()['plans'].values()))['phaseC']
        floor=pc['gasTuple'][0]; rule=pc['spPostOpRule']
        self.assertEqual(pc['spPostOp'],floor)
        self.assertEqual((rule['scaled'],rule['chainFloor'],rule['limit'],rule['floorApplied']),(2,floor,floor,True))
        self.assertTrue(pc['gasSources']['SP']['postOp']['floorApplied'])

    def test_postop_floor_not_applied_when_scaled_is_above(self):
        pc=next(iter(self.build()['plans'].values()))['phaseC']
        rule=pc['spPostOpRule']
        self.assertEqual((rule['scaled'],rule['limit'],rule['floorApplied']),(600000,600000,False))
        self.assertGreater(rule['limit'],rule['chainFloor'])

    def test_postop_floor_must_be_positive(self):
        with self.assertRaises(a.Gate): q.sp_postop_limit(1,{'numerator':3,'denominator':2},0)

    def test_shared_postop_floor_applies(self):
        pin=t.pin(); pin['phaseC']=t.phase_c_pin(pin)
        c=t.phase_c_inputs(lambda *args: {})
        c['rehearsal']['arms']['SP']['postOp']=1
        self.assertEqual(m.phase_c_worksheet(pin,c,0,policy='fresh')['bounds']['SP']['postOp'],m.u.GAS[0])

    def test_balance_plan(self):
        pc=next(iter(self.build()['plans'].values()))['phaseC']
        self.assertEqual(pc['spBranch'],'balance')
        self.assertEqual(pc['creditPolicy'],0)
        self.assertEqual(pc['balanceLock']['taskToken'],pc['addresses']['T'])
        self.assertNotEqual(pc['balanceLock']['taskToken'],pc['addresses']['X'])

    def test_same_token_rejected(self):
        with patch.object(a,'create_address',return_value='0x'+'11'*20):
            self.stop('C_task_token_distinct',self.build)

    def test_real_operator_layout_and_enduser_encoding(self):
        source=(q.ROOT/'contracts/src/interfaces/ISuperPaymaster.sol').read_text()
        body=source.split('struct OperatorConfig {')[1].split('}')[0]
        fields=re.findall(r'^\s*(?:uint\d+|bool|address)\s+(\w+)\s*;',body,re.M)
        self.assertEqual(list(m.OPERATOR_FIELDS),fields)
        actual=dict(aPNTsBalance=123,isConfigured=1,isPaused=0,xPNTsToken=int('22'*20,16),
                    reputation=456,minTxInterval=789,treasury=int('33'*20,16),totalSpent=1011,totalTxSponsored=1213)
        values=[actual[field] for field in fields]
        decoded=m.u.uints('0x'+''.join(format(v,'064x') for v in values))
        self.assertEqual(decoded[m.OP['xPNTsToken']],int('22'*20,16))
        self.assertEqual(decoded[m.OP['aPNTsBalance']],123)
        result=self.build()
        step=next(s for s in result['steps'] if s['id']=='0/C7')
        encoded=a.cast('abi-encode','c(address,uint256)',self.inputs['genesis'],next(iter(result['plans'].values()))['phaseC']['endUserStake'])
        self.assertEqual(m.u.uints(encoded),[int(self.inputs['genesis'],16),next(iter(result['plans'].values()))['phaseC']['endUserStake']])
        self.assertEqual(m.u.uints('0x'+step['tx']['data'][-128:]),m.u.uints(encoded))
        self.assertEqual(step['tx']['from'],self.inputs['genesis'])
        registry=(q.ROOT/'contracts/src/core/Registry.sol').read_text()
        self.assertIn('struct EndUserRoleData { address community; uint256 stakeAmount; }',registry)
        self.assertIn('if (msg.sender != user) revert Unauthorized();',registry)
        self.assertEqual(step['tx']['data'],a.calldata('safeMintForRole(bytes32,address,bytes)',m.role_id('ENDUSER'),self.inputs['accounts'][0]['account'],encoded))

def load_tests(loader, tests, pattern):
    import unittest
    return unittest.TestSuite(Round2(name) for name in Round2.__dict__ if name.startswith("test_"))
