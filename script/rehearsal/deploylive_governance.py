"""Exact fresh-deployment governance values, read through the pinned checker transport."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOKEN_EMPTY = ('creditPolicy pendingPolicy hasPendingPolicy pendingPolicyEta pendingSP pendingSPEta '
               'pendingSPByFactory pendingStandby pendingStandbyEta pendingTierSource pendingTierSourceEta').split()


def governance_specs(cfg, tier_hash):
    """(config target, input signature, arguments, exact ABI words).

    Mapping scope is deployment-defined: registered stake accounts, genesis operator,
    committee guardians, and the two V55Bootstrap allowlist keys. No arbitrary key scan.
    """
    release = json.loads((ROOT/'docs/release/rq3-runtime-expectations.json').read_text())
    empty = release['EMPTY_GOVERNANCE_WORD']
    specs = []
    def add(key, name, expected=None, args=(), inputs=''):
        specs.append((key, name+'('+inputs+')', tuple(args), tuple(expected if expected is not None else (empty,))))
    for name in ('protocolFeeBPS', 'aPNTsPriceUSD', 'OPERATOR_WITHDRAWAL_DELAY', 'OPERATOR_WITHDRAWAL_WINDOW'):
        add('superPaymaster', name, (release[name],))
    for name in ('pendingOwner pendingAPNTsToken pendingAPNTsTokenEta pendingBLSAgg pendingBLSAggEta '
                 'priceMode emergencyQueuedAt emergencyActivatedAt emergencyPendingPrice').split():
        add('superPaymaster', name, (release['PRICE_MODE_NORMAL'],) if name == 'priceMode' else None)
    for key in ('registry', 'aPNTs'):
        add(key, 'pendingOwner')
    for name in ('pendingFraudProofVerifier', 'pendingFraudProofVerifierReadyAt'):
        add('blsAggregator', name)
    for name, words in [('pendingWithdrawals', 2), ('slashQueues', 3), ('isSlashPending', 1)]:
        add('superPaymaster', name, (empty,)*words, (cfg['genesisOperator'],), 'address')
    subjects = sorted({a.lower() for a in [cfg['deployer'], cfg['genesisOperator'], *cfg['stakeAccounts'], *cfg['guardians']]})
    for subject in subjects:
        for name in ('pendingSBTBurn', 'pendingMembershipCleanup'):
            add('registry', name, args=(subject,), inputs='address')
    for guardian in cfg['guardians']:
        for name, words in [('pendingGuardianSlashCount',1), ('guardianExitRequests',2), ('guardianExitCooldownUntil',1)]:
            add('blsAggregator', name, (empty,)*words, (guardian,), 'address')
    add('aoaProtocolRegistry', 'pendingAt', args=('0', '0x'+cfg['superPaymaster'][2:].lower().zfill(64)), inputs='uint8,bytes32')
    add('aoaProtocolRegistry', 'pendingAt', args=('2', tier_hash), inputs='uint8,bytes32')
    for key in ['xPNTsTokenV2Impl'] + (['pnts'] if int(cfg['pnts'], 16) else []):
        for name in TOKEN_EMPTY:
            add(key, name, (release['POLICY_OFF'],) if name == 'creditPolicy' else (empty,))
        # The factory initializes SP as the sole automatic spender; no queued activation.
        add(key, 'spenderActivatesAt', args=(cfg['superPaymaster'],), inputs='address')
    return specs


def exact_words(raw, expected):
    """Reject revert/error text, extra/truncated words and noncanonical bool/address encodings."""
    return bool(re.fullmatch(r'0x[0-9a-fA-F]{'+str(64*len(expected))+'}', raw)) and tuple(
        int(raw[i:i+64],16) for i in range(2,len(raw),64)) == tuple(expected)


def governance_rows(cfg, call, tier_hash):
    for key, sig, args, expected in governance_specs(cfg, tier_hash):
        label = key+'.'+sig + ('['+','.join(args)+']' if args else '')
        yield label, exact_words(call(cfg[key], sig, *args), expected), expected
