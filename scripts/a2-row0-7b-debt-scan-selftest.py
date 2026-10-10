#!/usr/bin/env python3
"""Offline self-test for scripts/a2-row0-7b-debt-scan.py (no network).

T1 strict getter decoding: word() accepts exactly one 32-byte ABI word and rejects '0x', '', short, long,
   multi-word, non-hex and non-string (revert object) answers. A '0x' answer must never decode to zero.
T2 replay ordering: a same-block DebtRecorded -> DebtRepaid pair whose REPAY tx hash sorts BEFORE the record tx
   hash reconciles under execution order (blockNumber, logIndex). Discrimination: the old key
   (blockNumber, txHash, logIndex) on the same input replays the repay first and the check goes red.
T3 replay rejects malformed event data (DebtRecorded with 0 or 2 words, DebtRepaid with 1 word).
Exit 0 only if every case behaves as stated.
"""
import importlib.util, os, sys

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('scan', os.path.join(here, 'a2-row0-7b-debt-scan.py'))
scan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(scan)  # main() is not run on import

FAILS = []


def expect(cond, what):
    print(('PASS ' if cond else 'FAIL ') + what)
    if not cond:
        FAILS.append(what)


# ---- T1 -------------------------------------------------------------------------------------------
one = '0x' + '00' * 31 + '2a'
expect(scan.word(one) == 42, 'T1 one 32-byte word decodes (42)')
expect(scan.word('0x' + '0' * 64) == 0, 'T1 an explicit zero word decodes to 0')
for bad, label in [('0x', "'0x'"), ('', "''"), ('0x' + '00' * 31, '31 bytes'), ('0x' + '00' * 33, '33 bytes'),
                   ('0x' + '00' * 64, 'two words'), ('0x' + 'zz' * 32, 'non-hex'), ('00' * 32, 'no 0x prefix'),
                   ({'__error__': {'code': 3}}, 'revert object'), (None, 'None')]:
    try:
        scan.word(bad)
        expect(False, 'T1 rejects %s' % label)
    except ValueError:
        expect(True, 'T1 rejects %s' % label)
expect(scan.u('0x') == 0, "T1 (context) the lenient u() still maps '0x' to 0 -> getters must not use it")

# ---- T2 -------------------------------------------------------------------------------------------
TR, TP = scan.T['DebtRecorded'], scan.T['DebtRepaid']
USER = '0x' + '00' * 12 + 'f7bf79acb7f3702b9dbd397d8140ac9de6ce642c'
amt = '%064x' % (400 * 10 ** 18)
rec = {'blockNumber': hex(100), 'logIndex': hex(5), 'transactionHash': '0x' + 'ff' * 32,
       'topics': [TR, USER], 'data': '0x' + amt}
rep = {'blockNumber': hex(100), 'logIndex': hex(9), 'transactionHash': '0x' + '00' * 32,
       'topics': [TP, USER], 'data': '0x' + amt + '0' * 64}
bal, res = scan.replay_token_debt([rep, rec], TR, TP)   # input deliberately in the wrong order
expect(all(ok for ok, _ in res) and bal == {'0x' + USER[-40:]: 0},
       'T2 same-block record(logIndex 5, tx 0xff..) -> repay(logIndex 9, tx 0x00..) reconciles: %s'
       % [m for _, m in res])
old_order = sorted([rep, rec], key=lambda l: (int(l['blockNumber'], 16), l['transactionHash'],
                                              int(l['logIndex'], 16)))
expect(old_order[0] is rep, 'T2 discrimination: the old (block, txHash, logIndex) key puts the repay first')
run = 0
old_ok = True
for l in old_order:
    if l['topics'][0] == TR:
        run += int(l['data'][2:66], 16)
    else:
        run -= int(l['data'][2:66], 16)
        old_ok = old_ok and int(l['data'][66:130], 16) == run
expect(not old_ok and run == 0, 'T2 discrimination: under the old key the repay check is red (balance -400e18 at repay)')
expect([scan.ord_key(l) for l in sorted([rep, rec], key=scan.ord_key)] == [(100, 5), (100, 9)],
       'T2 ord_key = (blockNumber, logIndex)')

# ---- T3 -------------------------------------------------------------------------------------------
for data, top, label in [('0x', TR, 'DebtRecorded with empty data'), ('0x' + amt * 2, TR, 'DebtRecorded with 2 words'),
                         ('0x' + amt, TP, 'DebtRepaid with 1 word')]:
    _, res = scan.replay_token_debt([{'blockNumber': hex(1), 'logIndex': hex(0), 'transactionHash': '0x' + '11' * 32,
                                      'topics': [top, USER], 'data': data}], TR, TP)
    expect(any(not ok for ok, _ in res), 'T3 replay rejects %s' % label)

print('SELFTEST', 'FAIL (%d)' % len(FAILS) if FAILS else 'OK')
sys.exit(1 if FAILS else 0)
