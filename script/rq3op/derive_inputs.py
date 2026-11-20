#!/usr/bin/env python3
"""Read-only derivation of the reviewed per-account values the RQ3 planner needs.

Every value is read from BOTH providers at one EIP-1898 pinned block hash (requireCanonical) and
must agree, or is computed from a committed artifact whose SHA-256 equals the reviewed
`baselineSha256`. Nothing is signed or sent. RPC URLs are read from files and never printed.

Stage 1 (no --plan): writes inputs with clearly-labelled PROVISIONAL VerifyingPaymaster /
TokenPaymaster runtime keccaks (their constructor arguments contain plan-derived addresses).
Stage 2 (--plan <bundle>): reads plan 0's exact C12/C14 creation transactions, checks their
bytecode prefix equals the reviewed artifact and computes the runtime with a read-only
creation eth_call {from: experiment, data} at the pin on both providers.

Outputs (under --out-dir): inputs.<variant>.json per variant and derived-values.json with
"value / how derived / pinned block (hash, both providers equal)" for every derived value.
"""
import sys
sys.dont_write_bytecode = True
import argparse
import hashlib
import json
import re
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import plan_three_arm as q  # noqa: E402  (same commit as the planner; used only for pure helpers)

m, a = q.m, q.a
ROOT = HERE.parents[1]
EP = '0x0000000071727de22e5e9d8baf0edac6f37da032'
IMPL_SLOT = '0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc'
SIMPLE_ACCOUNT_INITIALIZED = 'SimpleAccountInitialized(address,address)'
LABEL = ('REHEARSAL ONLY: derived against the void attempt1 Sepolia deployment; '
         'must not be reused for the real run')


class Provider:
    def __init__(self, name, url_file):
        self.name = name
        self.url = Path(url_file).read_text().strip()
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def __call__(self, method, params):
        body = json.dumps(dict(jsonrpc='2.0', id=1, method=method, params=params)).encode()
        try:
            with self.opener.open(urllib.request.Request(self.url, body, {'Content-Type': 'application/json'}),
                                  timeout=60) as response:
                value = json.load(response)
        except Exception:
            raise SystemExit(f'STOP rpc transport failure on {self.name} ({method}); details redacted') from None
        if 'error' in value or 'result' not in value:
            message = str(value.get('error', {}).get('message', ''))[:160]
            message = re.sub(r'(?i)https?://\S+', '<redacted-url>', message)
            raise RpcError(self.name, method, message)
        return value['result']


class RpcError(Exception):
    def __init__(self, provider, method, message):
        super().__init__(f'{provider} {method}: {message}')
        self.provider, self.method, self.message = provider, method, message


class Pinned:
    """Two providers, one pinned block hash; every read must agree."""
    def __init__(self, left, right, number=None):
        self.providers = [left, right]
        tag = hex(number) if number is not None else None
        if tag is None:
            latest = a.qty(left('eth_blockNumber', []))
            tag = hex(latest - 3)          # a few confirmations behind head
        blocks = [p('eth_getBlockByNumber', [tag, False]) for p in self.providers]
        for key in ('number', 'hash', 'timestamp', 'parentHash'):
            if blocks[0][key] != blocks[1][key]:
                raise SystemExit(f'STOP pin disagreement on {key}')
        self.block = blocks[0]
        self.ref = dict(blockHash=self.block['hash'], requireCanonical=True)
        self.chain = [a.qty(p('eth_chainId', [])) for p in self.providers]
        if self.chain[0] != self.chain[1]:
            raise SystemExit('STOP chainId disagreement')

    def both(self, method, params):
        results = [p(method, params) for p in self.providers]
        if results[0] != results[1]:
            raise SystemExit(f'STOP provider disagreement on {method}')
        return results[0]

    def code(self, who):
        return self.both('eth_getCode', [who, self.ref]).lower()

    def call(self, to, sig, *args, sender=None):
        tx = dict(to=to, data=a.calldata(sig, *args))
        if sender: tx['from'] = sender
        return self.both('eth_call', [tx, self.ref])

    def address(self, to, sig, *args):
        return '0x' + self.call(to, sig, *args)[-40:].lower()

    def word(self, to, sig, *args):
        return int(self.call(to, sig, *args), 16)

    def storage(self, who, slot):
        return self.both('eth_getStorageAt', [who, slot, self.ref])

    def pin_record(self):
        return dict(number=a.qty(self.block['number']), numberHex=self.block['number'], hash=self.block['hash'],
                    timestamp=a.qty(self.block['timestamp']),
                    providers=[p.name for p in self.providers], bothProvidersEqual=True,
                    stateReads='EIP-1898 {blockHash, requireCanonical:true} on both providers; results compared byte-for-byte')


def keccak_code(code):
    if code == '0x':
        raise SystemExit('STOP empty code where runtime is required')
    return a.keccak(code)


def find_account_runtime(pin, impl, window=500, chunks=20):
    """Find SimpleAccount proxies initialised for EP v0.7 whose ERC1967 implementation slot is `impl`.

    Uses eth_getLogs by topic (SimpleAccountInitialized(entryPoint indexed, owner indexed)) in bounded
    ranges ending at the pin; never scans blocks one by one."""
    topic0 = a.keccak(SIMPLE_ACCOUNT_INITIALIZED)
    topic1 = '0x' + EP[2:].rjust(64, '0')
    hi = a.qty(pin.block['number'])
    for _ in range(chunks):
        lo = max(0, hi - window + 1)
        flt = dict(fromBlock=hex(lo), toBlock=hex(hi), topics=[topic0, topic1])
        logs = pin.both('eth_getLogs', [flt])
        seen = []
        for log in logs:
            who = log['address'].lower()
            if who in seen: continue
            seen.append(who)
            slot = pin.storage(who, IMPL_SLOT)
            if int(slot, 16) != int(impl, 16): continue
            code = pin.code(who)
            return dict(value=keccak_code(code), sample=who, sampleLogBlock=a.qty(log['blockNumber']),
                        sampleTx=log['transactionHash'], logRange=[lo, hi],
                        how=('keccak256(eth_getCode(sample)) at the pin; sample found by eth_getLogs topic0='
                             'SimpleAccountInitialized, topic1=EntryPoint v0.7, ERC1967 implementation slot == '
                             'factory.accountImplementation(). OZ v5 ERC1967Proxy runtime has no immutables, so every '
                             'account created by this factory shares this runtime.'))
        hi = lo - 1
    raise SystemExit('STOP no SimpleAccount sample found for the implementation')


def artifact(name, expected_sha):
    path = ROOT / m.BASELINE_ARTIFACTS[name]
    raw = path.read_bytes()
    digest = hashlib.sha256(raw).hexdigest()
    if digest != expected_sha:
        raise SystemExit(f'STOP {name} artifact sha256 {digest} != reviewed {expected_sha}')
    return json.loads(raw), m.BASELINE_ARTIFACTS[name], digest


def comparator_runtime(pin, plan_path, baseline_sha, experiment):
    bundle = json.loads(Path(plan_path).read_text())
    plan0 = next(p for p in bundle['plans'].values() if p['planIndex'] == 0)
    out = {}
    for name, sid in (('VerifyingPaymaster', 'C12'), ('TokenPaymaster', 'C14')):
        art, path, digest = artifact(name, baseline_sha[name])
        step = next(s for s in plan0['steps'] if s['id'] == sid)
        data = step['tx']['data'].lower()
        creation = art['bytecode'].lower()
        if not data.startswith(creation):
            raise SystemExit(f'STOP {sid} creation data does not start with the reviewed {name} bytecode')
        if step['tx']['from'].lower() != experiment.lower() or step['tx']['to'] is not None:
            raise SystemExit(f'STOP {sid} is not an experiment CREATE')
        args = '0x' + data[len(creation):]
        # TPM's constructor calls Q and the oracle, which plan 0 deploys earlier (C13.*). Their exact runtimes are
        # the plan's own C13 'code' readback expectations; supply them as eth_call state overrides at the pin.
        overrides = {}
        if name == 'TokenPaymaster':
            for dep in ('C13.token', 'C13.oracle'):
                prior = next(s for s in plan0['steps'] if s['id'] == dep)
                code = [p for p in prior['target'] if p['kind'] == 'code']
                if len(code) != 1: raise SystemExit(f'STOP {dep} has no exact code readback')
                overrides[code[0]['target']] = dict(code=code[0]['expected'])
        params = [{'from': experiment, 'data': data}, pin.ref] + ([overrides] if overrides else [])
        try:
            runtime = pin.both('eth_call', params).lower()
        except RpcError as error:
            raise SystemExit(f'STOP creation eth_call for {name} failed on {error.provider}: {error.message}')
        out[name] = dict(value=keccak_code(runtime), runtimeLength=(len(runtime) - 2) // 2,
                         artifact=path, artifactSha256=digest, reviewedSha256=baseline_sha[name],
                         creationKeccak=a.keccak(art['bytecode']), constructorArgs=args,
                         constructorArgsKeccak=a.keccak(args) if len(args) > 2 else None,
                         createsAt=step['creates'], planStep=sid,
                         stateOverrides={k: dict(codeKeccak=a.keccak(v['code']), source='plan0 C13 code readback expectation')
                                         for k, v in overrides.items()},
                         planSha256=hashlib.sha256(Path(plan_path).read_bytes()).hexdigest(),
                         how=('keccak256(eth_call({from: experiment, data: artifact.bytecode ++ plan0.' + sid +
                              ' constructor args}) at the pin on both providers): read-only creation call returns '
                              'the runtime with immutables as constructed'))
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--config', required=True)
    ap.add_argument('--rpc-a-file', required=True); ap.add_argument('--rpc-b-file', required=True)
    ap.add_argument('--provider-a', default='Alchemy'); ap.add_argument('--provider-b', default='Tenderly')
    ap.add_argument('--block', type=int, help='pin block number (default: head-3 on provider A)')
    ap.add_argument('--principals', required=True, help='JSON file: experiment, bundler, verifyingSigner, owners[], salts[], sdk, DSR inputs')
    ap.add_argument('--plan', help='provisional planner bundle (stage 2: comparator runtimes)')
    ap.add_argument('--out-dir', required=True)
    ap.add_argument('--calibration-path', default='cache/3arm/rehearsal/calibration.json')
    args = ap.parse_args()

    cfg = json.loads(Path(args.config).read_text())
    pr = json.loads(Path(args.principals).read_text())
    pin = Pinned(Provider(args.provider_a, args.rpc_a_file), Provider(args.provider_b, args.rpc_b_file), args.block)
    if pin.chain[0] != 11155111:
        raise SystemExit('STOP not Sepolia')
    rows = {}
    factory = cfg['simpleAccountFactory'].lower()
    factory_code = pin.code(factory)
    rows['accountFactory.runtimeKeccak'] = dict(value=keccak_code(factory_code), address=factory,
        how='keccak256(eth_getCode(config.simpleAccountFactory)) at the pin; planner gate C5_factory_runtime compares it with keccak(code(factory))')
    impl = pin.address(factory, 'accountImplementation()')
    rows['accountImplementation'] = dict(value=impl,
        how='factory.accountImplementation() at the pin; planner gate C5_factory_implementation')
    rows['accountImplementation.runtimeKeccak'] = dict(value=keccak_code(pin.code(impl)),
        how='keccak256(eth_getCode(accountImplementation)) at the pin; planner gate C5_implementation_runtime')
    impl_ep = pin.address(impl, 'entryPoint()')
    rows['accountImplementation.entryPoint'] = dict(value=impl_ep, check=impl_ep == EP,
        how='implementation.entryPoint() at the pin; planner gate C5_implementation_entrypoint requires EntryPoint v0.7')
    if impl_ep != EP:
        raise SystemExit('STOP implementation EntryPoint is not v0.7')
    rows['account.runtimeKeccak'] = find_account_runtime(pin, impl)

    accounts = []
    for i, (owner, salt) in enumerate(zip(pr['owners'], pr['salts'])):
        owner = owner.lower()
        s = pin.address(factory, 'getAddress(address,uint256)', owner, salt)
        code = pin.code(s)
        rows[f'accounts[{i}].account'] = dict(value=s, owner=owner, salt=salt, codeAtPin=code,
            how='factory.getAddress(owner, salt) at the pin; planner gate C5_counterfactual_pin')
        accounts.append(dict(account=s, accountOwner=owner, salt=salt, accountImplementation=impl,
                             runtimeKeccak=dict(accountFactory=rows['accountFactory.runtimeKeccak']['value'],
                                                accountImplementation=rows['accountImplementation.runtimeKeccak']['value'],
                                                account=rows['account.runtimeKeccak']['value'])))
    sdk = pr['sdk']
    sdk_s = pin.address(factory, 'getAddress(address,uint256)', sdk['owner'].lower(), sdk['salt'])
    rows['sdk.account'] = dict(value=sdk_s, expected=sdk['account'].lower(), check=sdk_s == sdk['account'].lower(),
        codeAtPin=pin.code(sdk_s), owner=sdk['owner'].lower(), salt=sdk['salt'],
        how='factory.getAddress(sdkOwner, salt) at the pin must equal the supplied SDK SimpleAccount')
    if sdk_s != sdk['account'].lower():
        raise SystemExit('STOP SDK account prediction mismatch')

    # SDK xAmount: the planner's own cost_bounds at the pinned SP pricing (plan_three_arm.sdk_live).
    sp = cfg['superPaymaster'].lower()
    price, fee_bps = pin.word(sp, 'aPNTsPriceUSD()'), pin.word(sp, 'protocolFeeBPS()')
    a0, amax, xmax = q.cost_bounds(pr['sdkMaxCostPerOp'], m.PC_PRICE_CAP, m.PC_PRICE_DECIMALS, price, fee_bps,
                                   m.PC_VALIDATION_BUFFER_BPS, m.PC_RATE)
    n = pr['sdkRuns'] * (4 + pr['sdkMaxOps'])
    floor, cap = (n + 1) * xmax, (n + m.PC_BETA) * xmax
    x_amount = cap
    rows['sdk.xAmount'] = dict(value=x_amount, perUserFloor=floor, perUserCap=cap, N=n, Xmax=xmax, Amax=amax, a0=a0,
        aPNTsPriceUSD=price, protocolFeeBPS=fee_bps, priceCap=m.PC_PRICE_CAP, validationBufferBPS=m.PC_VALIDATION_BUFFER_BPS,
        exchangeRate=m.PC_RATE, beta=m.PC_BETA, downstreamBudgetOk=(n + m.PC_BETA) * amax <= 5000 * 10**18,
        how=('plan_three_arm.cost_bounds(sdkMaxCostPerOp, PC_PRICE_CAP, 8, SP.aPNTsPriceUSD(), SP.protocolFeeBPS(), 1000, 1e18) '
             'with SP reads at the pin; N = sdkRuns*(4+sdkMaxOps) (plan_three_arm.py:83, not 3+sdkMaxOps); '
             'xAmount chosen = perUserCap = (N+PC_BETA)*Xmax, the same (n+beta)*Xmax rule as the S userTarget; '
             'pricing can change before planning, the planner re-checks rq3_sdk_amount at its own pin'))

    if args.plan:
        comps = comparator_runtime(pin, args.plan, pr['baselineSha256'], pr['experiment'])
        for name, row in comps.items():
            rows[f'{name}.runtimeKeccak'] = row
        provisional = False
    else:
        for name in ('VerifyingPaymaster', 'TokenPaymaster'):
            art, path, digest = artifact(name, pr['baselineSha256'][name])
            rows[f'{name}.runtimeKeccak'] = dict(value=a.keccak('0x' + f'REHEARSAL-PROVISIONAL-{name}'.encode().hex()),
                provisional=True, artifact=path, artifactSha256=digest,
                how='PROVISIONAL placeholder (stage 1): constructor args contain plan-derived addresses; rerun with --plan')
        provisional = True
    for acct in accounts:
        for name in ('VerifyingPaymaster', 'TokenPaymaster'):
            acct['runtimeKeccak'][name] = rows[f'{name}.runtimeKeccak']['value']

    base = dict(rehearsal=LABEL, experiment=pr['experiment'].lower(), genesis=cfg['genesisOperator'].lower(),
        bundler=pr['bundler'].lower(), verifyingSigner=pr['verifyingSigner'].lower(),
        gasFactor=pr['gasFactor'], feeFactor=pr['feeFactor'], priorityRule=pr['priorityRule'],
        feeCeiling=pr['feeCeiling'], stakeWei=pr['stakeWei'], unstakeDelay=pr['unstakeDelay'],
        calibration=args.calibration_path, fixturePins=pr['fixturePins'], baselineSha256=pr['baselineSha256'],
        accounts=accounts, minTxInterval=pr['minTxInterval'], sdkRuns=pr['sdkRuns'], sdkMaxOps=pr['sdkMaxOps'],
        priceHeadroomBPS=pr['priceHeadroomBPS'], sdkMaxCostPerOp=pr['sdkMaxCostPerOp'],
        sdkCostCapCommit=pr['sdkCostCapCommit'])
    extra = [dict(address=sdk_s, xAmount=x_amount)]
    variants = {
        'dsr': dict(base, taskRecipients=[dict(address=sdk_s, amount=pr['taskRecipientAmount'])], extraEndUsers=extra),
        'sdk-only': dict(base, rehearsalVariant='VARIANT: SDK account only in extraEndUsers; taskRecipients=[]',
                         taskRecipients=[], extraEndUsers=extra),
    }
    if not rows['sdk.xAmount']['downstreamBudgetOk']:
        # plan_three_arm.py:86 rq3_sdk_downstream_budget requires (N+PC_BETA)*Amax <= 5000e18. Find the
        # largest sdkMaxCostPerOp that passes (monotone in maxCost) so the rest of the planner can be exercised.
        lo, hi = 1, pr['sdkMaxCostPerOp']
        bounds = lambda c: q.cost_bounds(c, m.PC_PRICE_CAP, m.PC_PRICE_DECIMALS, price, fee_bps, m.PC_VALIDATION_BUFFER_BPS, m.PC_RATE)
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if (n + m.PC_BETA) * bounds(mid)[1] <= 5000 * 10**18: lo = mid
            else: hi = mid - 1
        _, vamax, vxmax = bounds(lo)
        rows['sdk.variantMaxCostPerOp'] = dict(value=lo, Amax=vamax, Xmax=vxmax, xAmount=(n + m.PC_BETA) * vxmax,
            how='VARIANT ONLY: largest sdkMaxCostPerOp with (N+PC_BETA)*Amax <= 5000e18 (rq3_sdk_downstream_budget) at the pinned pricing')
        variants['budget-variant'] = dict(variants['sdk-only'], sdkMaxCostPerOp=lo,
            extraEndUsers=[dict(address=sdk_s, xAmount=(n + m.PC_BETA) * vxmax)],
            rehearsalVariant=('VARIANT: SDK account only in extraEndUsers; taskRecipients=[]; sdkMaxCostPerOp lowered from '
                              f'{pr["sdkMaxCostPerOp"]} to {lo} so rq3_sdk_downstream_budget passes'))
    out = Path(args.out_dir); out.mkdir(parents=True, exist_ok=True)
    suffix = '.provisional' if provisional else ''
    written = {}
    for name, value in variants.items():
        raw = (json.dumps(value, indent=2) + '\n').encode()
        if re.search(rb'(?i)https?://', raw): raise SystemExit('STOP URL in output')
        path = out / f'inputs.{name}{suffix}.json'
        path.write_bytes(raw)
        written[path.name] = hashlib.sha256(raw).hexdigest()
    record = dict(label=LABEL, config=dict(path=args.config, sha256=hashlib.sha256(Path(args.config).read_bytes()).hexdigest(),
                                           commit=cfg['commit']),
                  pin=pin.pin_record(), chainId=pin.chain[0], provisional=provisional, values=rows, outputs=written,
                  notes=['All addresses are written lowercase because plan_three_arm.check_inputs applies '
                         'manifest_exec.pc_address (lowercase-only) to every identity.',
                         'Account salts are an operator choice (template 0/1/2); not supplied by DSR.'])
    raw = (json.dumps(record, indent=2) + '\n').encode()
    if re.search(rb'(?i)https?://', raw): raise SystemExit('STOP URL in output')
    (out / f'derived-values{suffix}.json').write_bytes(raw)
    print(json.dumps(dict(pin=record['pin'], outputs=written, derived=f'derived-values{suffix}.json'), indent=1))


if __name__ == '__main__':
    main()
