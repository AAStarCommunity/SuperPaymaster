"""PR D governance regressions; all RPC boundaries are simulated."""
import json
import re
import unittest
from pathlib import Path
import test_deploylive_postdeploy_check as fixture

ROOT = Path(__file__).resolve().parents[2]
def encoded(values):
    return '0x' + ''.join(f'{v:064x}' for v in values)

class PrD(unittest.TestCase):
    run_checker = fixture.CheckerTest.run_checker

    def test_release_values_bound_to_source(self):
        release = json.loads((ROOT/'docs/release/rq3-runtime-expectations.json').read_text())
        source = (ROOT/release['source']).read_text()
        init = (ROOT/'contracts/src/paymasters/superpaymaster/v3/SuperPaymaster.sol').read_text().split('function initialize(', 1)[1].split('fallback()', 1)[0]
        self.assertEqual(release['protocolFeeBPS'], int(re.search(r'protocolFeeBPS = (\d+);', init)[1]))
        price = re.search(r'aPNTsPriceUSD = ([\d.]+) ether;', init)[1]
        from decimal import Decimal
        self.assertEqual(release['aPNTsPriceUSD'], int(Decimal(price) * 10**18))
        for key, hours in [('OPERATOR_WITHDRAWAL_DELAY', 48), ('OPERATOR_WITHDRAWAL_WINDOW', 24)]:
            self.assertEqual(release[key], hours * 3600)
            self.assertRegex(source, rf'constant {key} = {hours} hours;')
        token_source = (ROOT/'contracts/src/tokens/v2/xPNTsV2Base.sol').read_text()
        self.assertEqual(release['POLICY_OFF'], int(re.search(r'constant POLICY_OFF = (\d+);', token_source)[1]))
        deploy = (ROOT/'contracts/script/v3/DeployLive.s.sol').read_text()
        self.assertNotRegex(deploy, r'\.(?:setAPNTSPrice|setProtocolFee)\(')

    def test_fee_price_periods_and_emergency_exact(self):
        for name, value in [('protocolFeeBPS',1000), ('aPNTsPriceUSD',20000000000000000),
                            ('OPERATOR_WITHDRAWAL_DELAY',172800), ('OPERATOR_WITHDRAWAL_WINDOW',86400),
                            ('priceMode',0), ('emergencyQueuedAt',0), ('emergencyActivatedAt',0), ('emergencyPendingPrice',0)]:
            for raw in [encoded([value+1]), '0x', encoded([value,0]), '<revert>']:
                with self.subTest(getter=name, raw=raw):
                    rc, out = self.run_checker(('superPaymaster', name+'()', [], raw))
                    self.assertEqual(rc, 1, out)
                    self.assertIn('FAIL  governance superPaymaster.'+name, out)

    def test_pending_and_keyed_queues_exact(self):
        rc, out = self.run_checker(('superPaymaster', 'pendingAPNTsTokenEta()', [], encoded([1])))
        self.assertEqual(rc, 1, out)
        from deploylive_governance import governance_specs
        from unittest.mock import patch
        specs = []
        def capture(cfg, tier_hash):
            rows = governance_specs(cfg, tier_hash)
            if tier_hash != '0x'+'00'*32: specs[:] = rows
            return rows
        with patch('deploylive_governance.governance_specs', side_effect=capture):
            rc, out = self.run_checker()
            self.assertEqual(rc, 0, out)
        for key, sig, args, expected in specs:
            if any(expected): continue
            for word in range(len(expected)):
                with self.subTest(key=key, sig=sig, args=args, word=word):
                    values = list(expected); values[word] = 1
                    rc, out = self.run_checker((key, sig, list(args), encoded(values)))
                    self.assertEqual(rc, 1, out)
                    self.assertIn('FAIL  governance '+key+'.'+sig.split('(')[0], out)

    def test_governance_pinned_replayed_and_counted(self):
        trace=[]
        rc, out = self.run_checker(op=True, check_blocks=True, request_trace=trace)
        self.assertEqual(rc, 0, out)
        for name in ['protocolFeeBPS','aPNTsPriceUSD','OPERATOR_WITHDRAWAL_DELAY','OPERATOR_WITHDRAWAL_WINDOW',
                     'pendingAPNTsTokenEta','pendingBLSAggEta','emergencyQueuedAt','priceMode','pendingFraudProofVerifierReadyAt']:
            calls=[(args, secondary) for args,secondary in trace if args[0]=='eth_call' and fixture.digest(name+'()') in args[1]]
            self.assertEqual({secondary for _,secondary in calls}, {False,True}, name)
        self.assertIn('PASS  governance ', out)
        self.assertEqual(len(re.findall(r'^PASS  governance ', out, re.M)), 48)

    def test_token_policy_and_all_pending_words(self):
        rc, out = self.run_checker(('xPNTsTokenV2Impl', 'pendingPolicyEta()', [], encoded([1])))
        self.assertEqual(rc, 1, out)
        from deploylive_governance import governance_specs, exact_words
        cfg=dict(superPaymaster=fixture.addr(2), pnts=fixture.addr(20),genesisOperator=fixture.addr(21),
                 deployer=fixture.addr(201),stakeAccounts=[],guardians=[])
        specs = governance_specs(cfg,'0x'+'ab'*32)
        from deploylive_readback import release_artifact
        for key, artifact in [('superPaymaster','SuperPaymaster'), ('registry','Registry'),
                              ('aPNTs','APNTsCapped'), ('blsAggregator','BLSAggregator'), ('pnts','xPNTsTokenV2')]:
            pending = {f['name']+'()' for f in release_artifact(artifact)['abi']
                       if f.get('type') == 'function' and not f['inputs']
                       and f.get('stateMutability') in ('view','pure')
                       and re.search(r'pending|Queued|Eta$', f['name'], re.I)}
            self.assertLessEqual(pending, {sig for target,sig,_,_ in specs if target == key})
        token=[s for s in specs if s[0]=='pnts' and not s[2]]
        self.assertEqual({s[1] for s in token}, {n+'()' for n in ('creditPolicy pendingPolicy hasPendingPolicy pendingPolicyEta pendingSP pendingSPEta pendingSPByFactory pendingStandby pendingStandbyEta pendingTierSource pendingTierSourceEta').split()})
        for _,sig,_,expected in token:
            self.assertTrue(exact_words(encoded(expected),expected),sig)
            self.assertFalse(exact_words(encoded([1]),expected),sig)
            self.assertFalse(exact_words('0x',expected),sig)

if __name__ == '__main__': unittest.main()
