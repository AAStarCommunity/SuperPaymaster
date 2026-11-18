#!/usr/bin/env python3
"""Acceptance readback (read-only eth_call / eth_getLogs). usage: readback.py RPC CONFIG BROADCAST START_NONCE"""
import json, subprocess, sys
RPC, CFG, BC, START = sys.argv[1], json.load(open(sys.argv[2])), json.load(open(sys.argv[3])), int(sys.argv[4])
def cast(*a, rpc=True):
    r = subprocess.run(['cast', *map(str, a)] + (['--rpc-url', RPC] if rpc else []), capture_output=True, text=True)
    if r.returncode: raise SystemExit('cast failed: ' + ' '.join(map(str, a[:3])) + ' :: ' + r.stderr.strip()[-300:])
    return r.stdout.strip()
def rpc(m, *p): return json.loads(cast('rpc', m, *[json.dumps(x) if not isinstance(x, str) else x for x in p]))
dep = CFG['deployer']; TL = CFG['timelockController']; H = CFG['handoverBootstrap']; SAFE = CFG['governanceOwner']
txs, rcs = BC['transactions'], BC['receipts']
print('## transactions')
nonces = [int(t['transaction']['nonce'], 16) for t in txs]
assert nonces == list(range(START, START + len(txs))), 'nonce gap'
iH = next(i for i, t in enumerate(txs) if t['transactionType'] == 'CREATE' and (t.get('contractAddress') or '').lower() == H.lower())
iTL = next(i for i, t in enumerate(txs) if t['transactionType'] == 'CREATE' and (t.get('contractAddress') or '').lower() == TL.lower())
print(f'broadcast txs total={len(txs)} receipts={len(rcs)} all_status_1={all(int(r["status"],16)==1 for r in rcs)}')
print(f'tx before H CREATE (broadcast index of H) = {iH}; independently H nonce - start nonce = {nonces[iH]-START}')
print(f'start nonce={START} TL nonce={nonces[iTL]} H nonce={nonces[iH]} TL->H distance={nonces[iH]-nonces[iTL]}; config handoverBootstrapNonce={CFG["handoverBootstrapNonce"]} observedBootstrapNonce={CFG["observedBootstrapNonce"]}')
print(f'deployer chain nonce now={int(cast("nonce", dep))}')
# zero-value check
print('all txs value 0:', all(int(t['transaction'].get('value', '0x0'), 16) == 0 for t in txs))
hrc = next(r for r in rcs if r['transactionHash'] == txs[iH]['hash'])
hb = int(hrc['blockNumber'], 16)
print('## minDelay')
print(f'H block={hb} tx={txs[iH]["hash"]}')
print(f'minDelay at block {hb-1} (before H) = {cast("call", TL, "getMinDelay()(uint256)", "--block", hb-1)}')
print(f'minDelay at block {hb} (H block, after) = {cast("call", TL, "getMinDelay()(uint256)", "--block", hb)}')
print('## TL roles (eth_getLogs rebuild + hasRole)')
logs = rpc('eth_getLogs', {'address': TL, 'fromBlock': hex(int(CFG['deploymentStartBlock'])), 'toBlock': 'latest'})
G = cast('keccak', 'RoleGranted(bytes32,address,address)', rpc=False).lower(); R = cast('keccak', 'RoleRevoked(bytes32,address,address)', rpc=False).lower()
members, seen = {}, {}
for e in sorted(logs, key=lambda e: (int(e['blockNumber'], 16), int(e['logIndex'], 16))):
    t = e['topics']
    if t[0].lower() not in (G, R): continue
    a = '0x' + t[2][-40:].lower(); seen.setdefault(t[1].lower(), []).append(('grant' if t[0].lower() == G else 'revoke', a, int(e['blockNumber'], 16)))
    (members.setdefault(t[1].lower(), set()).add if t[0].lower() == G else members.setdefault(t[1].lower(), set()).discard)(a)
print(f'TL logs total={len(logs)} role events={sum(len(v) for v in seen.values())}')
for role in ('DEFAULT_ADMIN_ROLE', 'PROPOSER_ROLE', 'EXECUTOR_ROLE', 'CANCELLER_ROLE'):
    rid = cast('call', TL, role + '()(bytes32)').lower()
    m = sorted(members.get(rid, set()))
    hr = {a: cast('call', TL, 'hasRole(bytes32,address)(bool)', rid, a) for a in sorted({x[1] for x in seen.get(rid, [])})}
    extra = {n: cast('call', TL, 'hasRole(bytes32,address)(bool)', rid, a) for n, a in (('deployer', dep), ('H', H), ('safe', SAFE), ('TL', TL))}
    print(f'{role} {rid}: members(logs)={m}; history={seen.get(rid)}; hasRole(each seen)={hr}; hasRole(named)={extra}')
print('## owners')
for k in ('registry', 'superPaymaster', 'aPNTs'):
    print(f'{k} {CFG[k]} owner={cast("call", CFG[k], "owner()(address)")} pendingOwner={cast("call", CFG[k], "pendingOwner()(address)")}')
print(f'TL address={TL}; Safe={SAFE}')
print('## H code')
code = cast('code', H); print(f'H={H} code={code} bytes={(len(code)-2)//2}')
print('## GToken accounting')
gt, stk = CFG['gToken'], CFG['staking']
T = cast('keccak', 'Transfer(address,address,uint256)', rpc=False)
tl = rpc('eth_getLogs', {'address': gt, 'fromBlock': hex(int(CFG['deploymentStartBlock'])), 'toBlock': 'latest', 'topics': [T]})
mints = [int(e['data'], 16) for e in tl if int(e['topics'][1], 16) == 0]
toSafe = [(('0x' + e['topics'][1][-40:]), int(e['data'], 16)) for e in tl if ('0x' + e['topics'][2][-40:]).lower() == SAFE.lower()]
toStk = sum(int(e['data'], 16) for e in tl if ('0x' + e['topics'][2][-40:]).lower() == stk.lower())
fromStk = sum(int(e['data'], 16) for e in tl if ('0x' + e['topics'][1][-40:]).lower() == stk.lower())
burns = sum(int(e['data'], 16) for e in tl if int(e['topics'][2], 16) == 0)
E = 10**18
ts = int(cast('call', gt, 'totalSupply()(uint256)').split()[0])
stkBal = int(cast('call', gt, 'balanceOf(address)(uint256)', stk).split()[0])
safeBal = int(cast('call', gt, 'balanceOf(address)(uint256)', SAFE).split()[0])
depBal = int(cast('call', gt, 'balanceOf(address)(uint256)', dep).split()[0])
# The remainder is the single last deployer->Safe transfer of deployerGTokenTransferred; every other Safe receipt is a ticket.
last = max(i for i, (f, n) in enumerate(toSafe) if f.lower() == dep.lower())
assert toSafe[last][1] == int(CFG['deployerGTokenTransferred'])
remainder = [toSafe[last][1]]
tickets = [n for i, (f, n) in enumerate(toSafe) if i != last]
print('Safe receipts in order (from, amount):', [(f, n/E) for f, n in toSafe])
print(f'Transfer events={len(tl)} mints={[m/E for m in mints]} sum={sum(mints)/E} burns={burns/E}')
print(f'staking: in={toStk/E} out={fromStk/E} balance={stkBal/E}')
print(f'tickets to treasury={[t/E for t in tickets]} sum={sum(tickets)/E} (config ticketsToTreasury={int(CFG["ticketsToTreasury"])/E}); remainder to recipient={[r/E for r in remainder]} (config {int(CFG["deployerRemainderToRecipient"])/E})')
print(f'locked stakes per config={[int(x)/E for x in CFG["stakeAmounts"]]} sum={sum(int(x) for x in CFG["stakeAmounts"])/E}')
print(f'totalSupply={ts/E} SafeBalance={safeBal/E} deployerBalance={depBal/E} deployerAllowance(staking)={cast("call", gt, "allowance(address,address)(uint256)", dep, stk)}')
print(f'conservation: minted {sum(mints)/E} == staked {stkBal/E} + tickets {sum(tickets)/E} + remainder {sum(remainder)/E} = {(stkBal+sum(tickets)+sum(remainder))/E} ; == totalSupply {ts/E} : {sum(mints) == stkBal + sum(tickets) + sum(remainder) == ts}')
print('## agent registries')
sp = CFG['superPaymaster']
print(f'agentIdentityRegistry()={cast("call", sp, "agentIdentityRegistry()(address)")} agentReputationRegistry()={cast("call", sp, "agentReputationRegistry()(address)")}')
