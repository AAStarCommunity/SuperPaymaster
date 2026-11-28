#!/usr/bin/env python3
"""REHEARSAL calibration of the RQ3 three-arm planner on a LOCAL ANVIL FORK of the configured chain.

Never sends to a real chain: every write goes to an anvil process this tool starts itself on
127.0.0.1 (fork upstream: provider B / Tenderly, URL passed via file and never printed), killed
by PID at exit. The upstream chain is only READ, by the planner's own checker (subcommand `checker`).

Breaking the plan <-> calibration cycle (see README "Calibration on a fork"):
  1. `provisional` writes a deliberately generous, clearly labelled calibration (kind "estimate").
  2. `run --mode measure`: fork at the pin, fork-only funding/price refresh, the planner's pure
     `build()` on the fork with that calibration, then every Safe transaction and every queued
     setup step executed in order through the setup gate code (setup_state.precheck_state,
     plan_three_arm.pre_send, manifest_exec.phase_c_pre_send, manifest_exec.check_predicate), then
     UserOperations per arm per sender (calibrate_ops.mjs, collector op construction).
  3. `assemble` turns the measurements into calibration.json + evidence (kind "measured",
     blockHash = the fork pin's real chain hash) with a fork transaction for every number.
  4. `run --mode verify` re-plans with the measured calibration on a fresh fork and repeats the
     whole sequence with the frozen limits, so the limits are shown to be sufficient.
"""
import sys
sys.dont_write_bytecode = True
import argparse
import copy
import hashlib
import json
import os
import re
import signal
import subprocess
import threading
import time
import urllib.request
from pathlib import Path
from calibration_safety import read_upstream, redact, choose_port, require_fork

HERE = Path(__file__).resolve().parent
ANVIL_171 = Path.home()/'.foundry/versions/v1.7.1/anvil'
ANVIL_NIGHTLY = Path.home()/'Dev/aastar/tools/foundry-rams/nightly-4e8874b/anvil'
FORK_PARAMETERS = {
    11155111: dict(hardfork='amsterdam', flags=[]),
    11155420: dict(hardfork='op:karst', flags=['--optimism']),
}


def fork_parameters(chain):
    if chain not in FORK_PARAMETERS:
        raise SystemExit(f'STOP unsupported chainId {chain}')
    return copy.deepcopy(FORK_PARAMETERS[chain])


def rehearsal_label(config, chain):
    raw = Path(config).read_bytes()
    fork_parameters(chain)
    name = 'OP Sepolia' if chain == 11155420 else 'Sepolia'
    return f'REHEARSAL ONLY / fork measurement; {name} chainId={chain}; config sha256={sha(raw)}; not for reuse'

NEUTRAL_KEEPER = '0x000000000000000000000000000000000000c0de'


def load_planner(root):
    root = Path(root).resolve()
    sys.path.insert(0, str(root/'script/rq3op'))
    import plan_three_arm as q
    import setup_state
    import gate_worker
    return q, setup_state, gate_worker


class Fork:
    def __init__(self, port):
        self.url = f'http://127.0.0.1:{port}'
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        self.proc = None

    def __call__(self, method, params):
        body = json.dumps(dict(jsonrpc='2.0', id=1, method=method, params=params)).encode()
        try:
            with self.opener.open(urllib.request.Request(self.url, body, {'Content-Type': 'application/json'}), timeout=120) as r:
                value = json.load(r)
        except Exception:
            raise RuntimeError('RPC transport failure; details redacted') from None
        if 'error' in value:
            message = redact(value['error'], opaque=True)
            raise ForkError(method, message, None)
        return value['result']

    def start(self, upstream_file, pin, log, chain):
        parameters = fork_parameters(chain)
        upstream = read_upstream(upstream_file)
        for anvil in (ANVIL_171, ANVIL_NIGHTLY):
            port = str(choose_port())
            self.url = f'http://127.0.0.1:{port}'
            log.parent.mkdir(parents=True, exist_ok=True)
            self.proc = subprocess.Popen([str(anvil), '--fork-url', upstream, '--fork-block-number', str(pin),
                '--chain-id', str(chain), '--hardfork', parameters['hardfork'], *parameters['flags'], '--port', port, '--host', '127.0.0.1',
                '--no-rate-limit'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            # anvil prints its fork endpoint (which carries the provider key): redact every line before it is written.
            def pump(stream, path):
                with open(path, 'ab') as sink:
                    for line in stream:
                        sink.write((redact(line, opaque=True) + '\n').encode()); sink.flush()
            threading.Thread(target=pump, args=(self.proc.stdout, log), daemon=True).start()
            for _ in range(300):
                if self.proc.poll() is not None: break
                try:
                    observed = int(self('eth_chainId', []), 16)
                    if observed != chain:
                        self.stop()
                        raise SystemExit('STOP fork chainId mismatch')
                    try:
                        require_fork(self.proc, self, pin)
                    except SystemExit:
                        self.stop()
                        raise
                    self.anvil = str(anvil); return
                except Exception: time.sleep(0.2)
            self.stop()
        raise SystemExit('STOP cannot start anvil fork (see log; URL redacted there? check before sharing)')

    def stop(self):
        if self.proc and self.proc.poll() is None:
            os.kill(self.proc.pid, signal.SIGTERM)
            try: self.proc.wait(10)
            except subprocess.TimeoutExpired: os.kill(self.proc.pid, signal.SIGKILL)
        self.proc = None


class ForkError(Exception):
    def __init__(self, method, message, data):
        super().__init__(f'{method}: {message}')
        self.method, self.message, self.data = method, message, data


def sha(raw): return hashlib.sha256(raw).hexdigest()


def write_json(path, value):
    raw = (json.dumps(value, indent=2, sort_keys=True) + '\n').encode()
    if re.search(rb'(?i)(?:https?|wss?)://', raw): raise SystemExit(f'STOP URL found in {path}')
    Path(path).parent.mkdir(parents=True, exist_ok=True)
    Path(path).write_bytes(raw)
    return sha(raw)


# ---------------------------------------------------------------------------------------------
def cmd_provisional(args):
    """Generous, explicitly provisional calibration. Values are NOT measurements."""
    setup_ids = ['C2.approve', 'C2.deposit', 'C3.deploy', 'C3.configure', 'C3.limits', 'C5', 'C6', 'C7', 'C8', 'C20',
                 'C9.allowance', 'C9.total', 'C9.mode', 'C18.approve', 'C10', 'C11.S', 'C11.R', 'C11.extra.0',
                 'C12', 'C13.token', 'C13.oracle', 'C14', 'C15', 'C16.vpm', 'C16.tpm', 'C17.sp', 'C17.vpm', 'C17.tpm',
                 'C18.mint', 'C19', 'C8.extra.0.approve', 'C8.extra.0.role', 'C8.extra.0.mint']
    # Generous but within the Amsterdam per-transaction gas cap (EIP-7825, 2**24) after gasFactor 3/2.
    creates = {'C10': 8_000_000, 'C12': 8_000_000, 'C13.token': 8_000_000, 'C13.oracle': 8_000_000, 'C14': 10_000_000,
               'C3.deploy': 5_000_000, 'C5': 2_000_000, 'C7': 5_000_000, 'C8.extra.0.role': 5_000_000}
    setup = {k: creates.get(k, 2_000_000) for k in setup_ids}
    prep = {k: 1_000_000 for k in ('C9.allowance', 'C9.total', 'C9.mode', 'C18.approve')}
    arms = {arm: dict(call=1_000_000, verification=1_500_000, paymasterVerification=1_500_000,
                      postOp=0 if arm == 'VPM' else 1_500_000, outer=8_000_000) for arm in ('SP', 'VPM', 'TPM')}
    safe = {k: 2_000_000 for k in ('C1', 'GToken.transfer', 'SP.stake.schedule', 'SP.stake.execute')}
    cfg = json.loads(Path(args.config).read_text())
    fork_parameters(args.chain)
    evidence = dict(label='PROVISIONAL (generous, not measured): bootstrap only; ' + rehearsal_label(args.config, args.chain), chainId=args.chain, fork=fork_parameters(args.chain),
                    superPaymaster=cfg['superPaymaster'], commit=cfg['commit'], blockNumber=hex(args.pin),
                    blockHash=args.pin_hash, arms=arms, setup=setup, ownerPreparation=prep, ownerMaintenance=[],
                    bundlerMaintenance=[], safeTransactions=safe)
    digest = write_json(args.evidence, evidence)
    cal = dict(source=dict(kind='estimate', blockHash=args.pin_hash, evidenceSha256=digest, evidenceFile=args.evidence_rel),
               arms=arms, setup=setup, ownerPreparation=prep, ownerMaintenance=[], bundlerMaintenance=[], safeTransactions=safe)
    print(json.dumps(dict(calibration=write_json(args.out, cal), evidence=digest)))


# ---------------------------------------------------------------------------------------------
def cmd_checker(args):
    fork_parameters(args.chain)
    q, _, _ = load_planner(args.planner_root)
    cfg = json.loads(Path(args.config).read_text())
    url = read_upstream(args.rpc_a_file)
    tools = q.pinned_tools()
    with tools.active():
        result = q.run_checker(args.config, cfg, url, args.chain, block=args.pin_hash, tools=tools)
    print(json.dumps(dict(record=write_json(args.out, result), summary=result['summary'], snapshot=result['snapshotBlockHash'])))


# ---------------------------------------------------------------------------------------------
class Runner:
    def __init__(self, args):
        fork_parameters(args.chain)
        self.args = args
        self.q, self.state, self.gw = load_planner(args.planner_root)
        self.m, self.a = self.q.m, self.q.a
        self.fork = Fork(args.port)
        self.log = []          # every fork transaction with provenance
        self.notes = []

    # -- fork primitives -------------------------------------------------------------------
    def rpc(self, method, params):
        if method.startswith(('anvil_', 'evm_')) or method == 'eth_sendTransaction':
            require_fork(self.fork.proc, self.fork, self.args.pin)
        return self.fork(method, params)

    def send(self, tx, label, impersonate=True, check_status=True):
        who = tx['from']
        if impersonate: self.rpc('anvil_impersonateAccount', [who])
        est = None
        try:
            est = self.a.qty(self.rpc('eth_estimateGas', [{k: tx[k] for k in ('from', 'to', 'data', 'value') if k in tx and tx[k] is not None}]))
        except ForkError as error:
            est = None; estimate_error = error.message
        else: estimate_error = None
        body = {k: v for k, v in tx.items() if v is not None and k in ('from', 'to', 'data', 'value', 'gas', 'nonce', 'maxFeePerGas', 'maxPriorityFeePerGas')}
        h = self.rpc('eth_sendTransaction', [body])
        receipt = None
        for _ in range(600):
            receipt = self.rpc('eth_getTransactionReceipt', [h])
            if receipt: break
            time.sleep(0.1)
        if not receipt: raise SystemExit(f'STOP no receipt for {label}')
        block = self.rpc('eth_getBlockByNumber', [receipt['blockNumber'], False])
        row = dict(label=label, hash=h, sender=who, to=tx.get('to'), blockNumber=self.a.qty(receipt['blockNumber']),
                   blockTimestamp=self.a.qty(block['timestamp']), status=receipt['status'],
                   gasUsed=self.a.qty(receipt['gasUsed']), gasLimit=self.a.qty(tx['gas']) if tx.get('gas') else None,
                   estimate=est, estimateError=estimate_error)
        self.log.append(row)
        if check_status and receipt['status'] != '0x1':
            try:
                trace = self.rpc('debug_traceTransaction', [h, {'tracer': 'callTracer'}])
                def deepest(f):
                    bad = [c for c in f.get('calls', []) if c.get('error')]
                    return deepest(bad[-1]) if bad else f
                d = deepest(trace)
                detail = dict(error=redact(d.get('error'), opaque=True), output=d.get('output'), to=d.get('to'), input=d.get('input', '')[:10])
            except ForkError as error: detail = error.message
            row['failure'] = detail
            raise SystemExit(f'STOP fork transaction failed: {label} {h} {json.dumps(detail)} estimateError={estimate_error}')
        return row, receipt

    def snapshot(self): return self.rpc('evm_snapshot', [])
    def revert(self, sid): assert self.rpc('evm_revert', [sid]) is True

    # -- fork-only preparation -------------------------------------------------------------
    def prepare(self, cfg, inputs):
        a = self.a
        fund = hex(self.args.fund_wei)
        for who in (inputs['experiment'], inputs['genesis']):
            self.rpc('anvil_setBalance', [who, fund])
            self.notes.append(f'fork-only anvil_setBalance {who} = {self.args.fund_wei} wei (real balance at pin is 0)')
        # Safe owners execute Safe transactions on the fork; the Safe holds the SP stake value.
        safe = cfg['governanceOwner']
        for who in self.safe_owners(safe):
            self.rpc('anvil_setBalance', [who, hex(10**18)])
        self.rpc('anvil_setBalance', [safe, hex(inputs['stakeWei'])])
        self.notes.append(f'fork-only anvil_setBalance Safe {safe} = stakeWei; Safe owners 1 ETH each for execTransaction gas')
        self.refresh_price(cfg)

    def refresh_price(self, cfg):
        sp = cfg['superPaymaster']
        self.rpc('anvil_setBalance', [NEUTRAL_KEEPER, hex(10**18)])
        row, _ = self.send(dict({'from': NEUTRAL_KEEPER}, to=sp, data=self.a.calldata('updatePrice()'), gas=hex(300000)),
                           'fork-only SP.updatePrice() (permissionless keeper call; refresh the configured SP price at the pin)')
        return row

    def safe_owners(self, safe):
        raw = self.a.call(self.rpc, safe, 'getOwners()')
        words = [raw[2+64*i:2+64*(i+1)] for i in range((len(raw)-2)//64)]
        n = int(words[1], 16)
        return ['0x'+w[-40:] for w in words[2:2+n]]

    # -- planning ----------------------------------------------------------------------------
    def plan(self, cfg, inputs, cal, checker):
        q = self.q
        internal = dict(checker, stdout='PASS verified checker execution\n'+checker['summary'])
        head = self.a.block_data(self.rpc, 'latest')
        frozen = lambda method, params: head if method == 'eth_getBlockByNumber' and params[0] == 'latest' else self.rpc(method, params)
        q.verify_calibration(cfg, cal, self.args.chain, self.rpc)
        result = q.build(cfg, inputs, frozen, internal, cal, q.load_baselines(cfg, inputs))
        result['checker'] = checker
        for plan in result['plans'].values(): plan['checker'] = checker
        return q.output_bytes(result), head

    # -- Safe transactions -------------------------------------------------------------------
    def exec_safe(self, safe, inner, label):
        a = self.a
        owners = sorted(self.safe_owners(safe), key=lambda x: int(x, 16))
        threshold = a.word(self.rpc, safe, 'getThreshold()')
        signers = owners[:threshold]
        nonce = a.word(self.rpc, safe, 'nonce()')
        to, value, data = inner['to'], a.qty(inner['value']), inner['data']
        h = a.call(self.rpc, safe, 'getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)',
                   to, value, data, 0, 0, 0, 0, a.ZERO, a.ZERO, nonce)
        executor = signers[0]
        for who in signers[1:]:
            self.send({'from': who, 'to': safe, 'data': a.calldata('approveHash(bytes32)', h), 'gas': hex(200000)},
                      f'fork Safe approveHash by owner (pre-validated signature) for {label}')
        sigs = '0x' + ''.join(w[2:].rjust(64, '0') + '0'*64 + '01' for w in signers)
        data_exec = a.calldata('execTransaction(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,bytes)',
                               to, value, data, 0, 0, 0, 0, a.ZERO, a.ZERO, sigs)
        inner_estimate = None
        try:
            self.rpc('anvil_impersonateAccount', [safe])
            inner_estimate = a.qty(self.rpc('eth_estimateGas', [dict({'from': safe}, to=to, data=data, value=hex(value))]))
        except ForkError: pass
        row, receipt = self.send({'from': executor, 'to': safe, 'data': data_exec, 'gas': hex(3_000_000)},
                                 f'Safe.execTransaction {label} (threshold {threshold}, pre-validated signatures)')
        success = a.keccak('ExecutionSuccess(bytes32,uint256)')
        ok = [l for l in receipt['logs'] if l['address'].lower() == safe.lower() and l['topics'][0] == success]
        if len(ok) != 1: raise SystemExit(f'STOP Safe inner call failed: {label}')
        row.update(safeTxHash=h, innerEstimate=inner_estimate, safeNonce=nonce)
        return row

    # -- setup queue -------------------------------------------------------------------------
    def run_steps(self, bundle, mode, expected_codehash_mismatch=()):
        a, m, q = self.a, self.m, self.q
        results = []
        for index, step in enumerate(bundle['steps']):
            plan, local = self.gw.associated_plan(bundle, index)
            status = self.state.precheck_state(self.rpc, local)
            if status['status'] != 'initial': raise SystemExit(f'STOP {step["id"]} not initial: {status}')
            q.pre_send(self.rpc, plan, local)
            m.phase_c_pre_send(self.rpc, plan, local, {}, deployment=plan['deploymentContext'])
            m.owner_gas_gate(local)
            tx = copy.deepcopy(local['tx'])
            chain_nonce = a.nonce(self.rpc, tx['from'], 'latest')
            if chain_nonce != a.qty(tx['nonce']): raise SystemExit(f'STOP nonce drift at {step["id"]}')
            row, receipt = self.send(tx, f'plan step {step["id"]}')
            failures = []
            for p in local['target']:
                try: m.check_predicate(self.rpc, p, row['blockTimestamp'])
                except a.Gate as error:
                    observed = self.state.observe(self.rpc, p)
                    if mode == 'measure' and p['kind'] == 'codeHash' and local['id'] in expected_codehash_mismatch:
                        failures.append(dict(predicate=p, observed=observed, tolerated='provisional comparator runtime keccak'))
                    else:
                        raise SystemExit(f'STOP readback {step["id"]}: {error} observed={observed}')
            if receipt.get('contractAddress') and local.get('creates') and receipt['contractAddress'].lower() != local['creates'].lower():
                raise SystemExit(f'STOP {step["id"]} created at an unplanned address')
            row.update(step=step['id'], planIndex=plan['planIndex'], sid=local['id'], senderRole=local['sender'],
                       readbacks=len(local['target']), toleratedReadbackMismatch=failures)
            results.append(row)
        return results

    # -- whole run ---------------------------------------------------------------------------
    def run(self):
        args, a, q, m = self.args, self.a, self.q, self.m
        cfg = json.loads(Path(args.config).read_text())
        inputs = json.loads(Path(args.inputs).read_text())
        cal = json.loads(Path(args.calibration).read_text())
        checker = json.loads(Path(args.checker_record).read_text())
        out = Path(args.out_dir).resolve(); out.mkdir(parents=True, exist_ok=True)
        self.fork.start(args.upstream_file, args.pin, out/'anvil.log', args.chain)
        try:
            head = a.block_data(self.rpc, 'latest')
            if a.qty(head['number']) != args.pin or head['hash'] != args.pin_hash:
                raise SystemExit('STOP fork head is not the configured chain pin')
            self.prepare(cfg, inputs)
            raw, plan_head = self.plan(cfg, inputs, cal, checker)
            plan_path = out/f'rq3-three-arm.{args.mode}.json'
            plan_path.write_bytes(raw)
            bundle = json.loads(raw)
            record = dict(label=rehearsal_label(args.config, args.chain), mode=args.mode, anvil=self.fork.anvil, pin=dict(number=args.pin, hash=args.pin_hash, chainId=args.chain), fork=fork_parameters(args.chain),
                          planHead=dict(number=a.qty(plan_head['number']), hash=plan_head['hash']),
                          plan=dict(path=str(plan_path), sha256=sha(raw)), inputsSha256=sha(Path(args.inputs).read_bytes()),
                          calibrationSha256=sha(Path(args.calibration).read_bytes()), configSha256=sha(Path(args.config).read_bytes()))
            # Safe transactions first (README: Safe prerequisites execute before the local C steps).
            safe = cfg['governanceOwner']
            safe_rows = {}
            for tx in bundle['safeTransactions']:
                if tx['id'] == 'SP.stake.execute':
                    snap = self.snapshot()
                    delay = bundle['timelockOperation']['delay']
                    self.rpc('evm_increaseTime', [delay + 1]); self.rpc('evm_mine', [])
                    status = self.state.precheck_state(self.rpc, tx)
                    if status['status'] != 'initial': raise SystemExit(f'STOP Safe {tx["id"]} not initial after delay')
                    row = self.exec_safe(safe, tx, tx['id'])
                    for p in tx['target']: m.check_predicate(self.rpc, p, row['blockTimestamp'])
                    row['note'] = 'measured after evm_increaseTime(delay+1) inside a snapshot; snapshot reverted afterwards'
                    safe_rows[tx['id']] = row
                    self.revert(snap)
                    # Equivalent end state without moving fork time 48 h (price staleness): TL is SP's owner.
                    tl = cfg['timelockController']
                    self.rpc('anvil_setBalance', [tl, hex(inputs['stakeWei'] + 10**18)])
                    tl_row, _ = self.send({'from': tl, 'to': cfg['superPaymaster'], 'data': a.calldata('addStake(uint32)', inputs['unstakeDelay']),
                                           'value': hex(inputs['stakeWei']), 'gas': hex(500000)},
                                          'fork-only equivalent of SP.stake.execute: impersonated TL (SP owner) addStake(unstakeDelay){stakeWei}')
                    ep_pred = tx['target'][1]
                    m.check_predicate(self.rpc, ep_pred)
                    continue
                status = self.state.precheck_state(self.rpc, tx)
                if status['status'] != 'initial': raise SystemExit(f'STOP Safe {tx["id"]} not initial')
                row = self.exec_safe(safe, tx, tx['id'])
                for p in tx['target']: m.check_predicate(self.rpc, p, row['blockTimestamp'])
                safe_rows[tx['id']] = row
            self.refresh_price(cfg)
            steps = self.run_steps(bundle, args.mode, expected_codehash_mismatch=('C12', 'C14') if args.mode == 'measure' else ())
            extra = []
            if not bundle['plans'][next(iter(bundle['plans']))]['taskRecipients'] and args.extra_task_recipient:
                who, amount = args.extra_task_recipient.split(':')
                plan0 = next(p for p in bundle['plans'].values() if p['planIndex'] == 0)
                T = plan0['phaseC']['addresses']['T']
                limit = self.q.scale(cal['setup']['C11.extra.0'], inputs['gasFactor'])
                row, _ = self.send({'from': inputs['experiment'], 'to': T, 'data': a.calldata('mint(address,uint256)', who, int(amount)),
                                    'gas': hex(limit), 'maxFeePerGas': hex(plan0['phaseC']['feeCap']),
                                    'maxPriorityFeePerGas': hex(plan0['phaseC']['priorityCap'])}, 'not a plan step (sdk-only variant): the C11.extra.0 calldata T.mint(SDK, 301) for the DSR inputs')
                m.check_predicate(self.rpc, m.word_pred(T, 'balanceOf(address)', int(amount), who))
                row['sid'] = 'C11.extra.0'; extra.append(row)
            # C9.mode is omitted by the planner when renewalMode is already 0 (no state change), but build() reads
            # cal['setup']['C9.mode'] and cal['ownerPreparation']['C9.mode'] before deciding to omit it, and the owner
            # budget includes it. Measure the identical call (not a plan step) from each owner.
            for key, plan in bundle['plans'].items():
                if any(s['id'] == 'C9.mode' for s in plan['steps']): continue
                pc = plan['phaseC']; owner = plan['externalInputs']['data']['phaseC']['accountOwner']
                inner = a.calldata('setRenewalMode(uint8)', 0)
                row, _ = self.send({'from': owner, 'to': pc['addresses']['S'], 'gas': hex(pc['ownerPreparation']['C9.mode']),
                                    'maxFeePerGas': hex(pc['feeCap']), 'maxPriorityFeePerGas': hex(pc['priorityCap']),
                                    'data': a.calldata('execute(address,uint256,bytes)', pc['addresses']['X'], 0, inner)},
                                   'not a plan step (planner omits the no-op C9.mode): S.execute(X,0,setRenewalMode(0)) from O')
                m.check_predicate(self.rpc, m.word_pred(pc['addresses']['X'], 'renewalMode(address)', 0, pc['addresses']['S']))
                row['sid'] = 'C9.mode'; extra.append(row)
            gates = {}
            for key, plan in bundle['plans'].items():
                gates[key] = dict(funding_gate=str(m.funding_gate(self.rpc, plan)), sp_attempt_precheck=m.sp_attempt_precheck(self.rpc, plan),
                                  pre_send=q.pre_send(self.rpc, plan))
            self.refresh_price(cfg)
            plan0 = next(p for p in bundle['plans'].values() if p['planIndex'] == 0)
            request = dict(forkUrl=self.fork.url, forkPid=self.fork.proc.pid, forkPin=args.pin, bundlePath=str(plan_path), bundleSha256=sha(raw), rounds=args.rounds,
                           search=args.mode == 'measure', gasFactor=inputs['gasFactor'], spPostOpFloor=plan0['phaseC']['gasTuple'][0],
                           out=str(out/f'ops.{args.mode}.json'))
            # The only URL here is the local fork (127.0.0.1); it is not a credential.
            (out/f'ops-request.{args.mode}.json').write_text(json.dumps(request, indent=2) + '\n')
            ops = subprocess.run(['node', str(HERE/'calibrate_ops.mjs'), str(out/f'ops-request.{args.mode}.json')],
                                 capture_output=True, text=True, cwd=str(HERE.parents[1]))
            (out/f'ops.{args.mode}.stdout').write_text(redact(ops.stdout + ops.stderr, opaque=True))
            if ops.returncode: raise SystemExit(f'STOP calibrate_ops failed: {redact(ops.stdout+ops.stderr, opaque=True)}')
            ops_out = json.loads((out/f'ops.{args.mode}.json').read_text())
            if args.mode == 'verify': check_verify_ops(ops_out['ops'])
            record.update(safe=safe_rows, steps=steps, extraSteps=extra, postSetupGates=gates, notes=self.notes,
                          forkTransactions=self.log, ops=ops_out)
            print(json.dumps(dict(measurements=write_json(out/f'measurements.{args.mode}.json', record), plan=sha(raw))))
        finally:
            write_json(out/f'fork-transactions.{args.mode}.json', dict(label=rehearsal_label(args.config, args.chain), notes=self.notes, transactions=self.log))
            self.fork.stop()


def check_verify_ops(ops):
    """Verify-mode gate: every op row must be USEROP_SUCCESS with tx status 0x1 and uoe.success, and per sender the key-0 nonces of its rows must be consecutive in send order (each successful op consumed exactly one nonce)."""
    expected = {}
    for op in ops:
        sender, arm, round = op.get('sender'), op.get('arm'), op.get('round')
        tx, uoe = op.get('tx') or {}, op.get('uoe') or {}
        if op.get('verdict') != 'USEROP_SUCCESS' or tx.get('status') != '0x1' or uoe.get('success') is not True:
            raise SystemExit(f'STOP verify op not successful: sender={sender} arm={arm} round={round} verdict={op.get("verdict")} txStatus={tx.get("status")} uoeSuccess={uoe.get("success")}')
        nonce = int(op['nonce'])
        if sender not in expected: expected[sender] = nonce
        if nonce != expected[sender]: raise SystemExit(f'STOP verify nonce not conserved: sender={sender} arm={arm} round={round} nonce={nonce} expected={expected[sender]}')
        expected[sender] = nonce + 1


def cmd_run(args):
    Runner(args).run()


# ---------------------------------------------------------------------------------------------
def cmd_assemble(args):
    rec = json.loads(Path(args.measurements).read_text())
    cfg = json.loads(Path(args.config).read_text())
    fork_parameters(args.chain)
    if rec['pin'].get('chainId') != args.chain or rec['configSha256'] != sha(Path(args.config).read_bytes()):
        raise SystemExit('STOP measurement/config identity mismatch')
    prov = {}
    def put(group, key, value, source):
        cur = prov.setdefault(group, {}).setdefault(key, dict(value=0, sources=[]))
        cur['sources'].append(source)
        cur['value'] = max(cur['value'], value)
    owner_ids = ('C9.allowance', 'C9.total', 'C9.mode', 'C18.approve')
    for row in rec['steps'] + rec['extraSteps']:
        value = max(row['gasUsed'], row['estimate'] or 0)
        src = dict(forkTx=row['hash'], step=row.get('step', row['sid']), gasUsed=row['gasUsed'], estimate=row['estimate'])
        put('setup', row['sid'], value, src)
        if row['sid'] in owner_ids: put('ownerPreparation', row['sid'], value, src)
    for sid, row in rec['safe'].items():
        put('safeTransactions', sid, max(row['gasUsed'], row['estimate'] or 0),
            dict(forkTx=row['hash'], gasUsed=row['gasUsed'], estimate=row['estimate'], innerEstimate=row['innerEstimate'],
                 rule='Safe.execTransaction gasUsed (outer, >= inner call)', note=row.get('note')))
    for op in rec['ops']['ops']:
        if op['verdict'] != 'USEROP_SUCCESS': raise SystemExit(f'STOP op not successful: {op["arm"]} {op["sender"]}')
        if not op['minima']: continue  # warm-up pass (round -1): sent at the frozen bounds, not measured
        for field in ('call', 'verification', 'paymasterVerification', 'postOp', 'outer'):
            put('arms', op['arm']+'.'+field, op['minima'][field], dict(forkTx=op['tx']['hash'], sender=op['sender'], round=op['round'],
                frameGasUsed=op['measurement'][field],
                rule=('smallest limit for which EntryPoint accepts this exact op and it succeeds (binary search, each candidate re-signed '
                      'and sent inside evm_snapshot/evm_revert at the state of forkTx)') if field != 'outer' else
                     ('smallest handleOps gas limit for which this op succeeds with the other limits at measured x gasFactor '
                      '(SP postOp at max(scaled, minPostOpGas))'),
                outerWithLimits=op['minima'].get('outerWithLimits') if field == 'outer' else None))
    # Round -1 SP warm-up rows (search on) carry warmupMinima.verification, measured at EntryPoint key-0
    # nonce 0 before the warm-up op was sent; the collector --first-use sends each sender's first op
    # (SP arm, nonce 0) at the frozen plan limits, so SP.verification = max(nonce0, nonceAtLeast1).
    warmup_sp = [op for op in rec['ops']['ops'] if op.get('warmup') and op['arm'] == 'SP' and op.get('warmupMinima')]
    if not warmup_sp: raise SystemExit('STOP no SP warm-up (round -1) row with warmupMinima.verification in the measurements (run --mode measure with search on)')
    nonce_at_least_1 = prov['arms'].get('SP.verification', dict(value=0))['value']
    nonce0 = max(int(op['warmupMinima']['verification']) for op in warmup_sp)
    for op in warmup_sp:
        put('arms', 'SP.verification', int(op['warmupMinima']['verification']),
            dict(forkTx=op['tx']['hash'], sender=op['sender'], round=op['round'],
                 rule='smallest EntryPoint-accepted verificationGasLimit for this exact op measured at EntryPoint key-0 nonce 0 (binary search before the warm-up op was sent); covers the first-use op, collector.mjs --first-use'))
    sp_minima = dict(nonce0=nonce0, nonceAtLeast1=nonce_at_least_1, rule='SP.verification = max(nonce0, nonceAtLeast1)')
    arms = {arm: {f: prov['arms'][arm+'.'+f]['value'] for f in ('call', 'verification', 'paymasterVerification', 'postOp', 'outer')}
            for arm in ('SP', 'VPM', 'TPM')}
    setup = {k: v['value'] for k, v in sorted(prov['setup'].items())}
    prep = {k: prov['ownerPreparation'][k]['value'] for k in owner_ids}
    safe = {k: prov['safeTransactions'][k]['value'] for k in ('C1', 'GToken.transfer', 'SP.stake.schedule', 'SP.stake.execute')}
    block_number = hex(rec['pin']['number'])
    variants = {}
    for label, sp in (('', cfg['superPaymaster']), ('.lowercase', cfg['superPaymaster'].lower())):
        evidence = dict(label=rehearsal_label(args.config, args.chain), kind='measured', chainId=args.chain, superPaymaster=sp, commit=cfg['commit'], blockNumber=block_number,
                        blockHash=rec['pin']['hash'], arms=arms, setup=setup, ownerPreparation=prep, ownerMaintenance=[],
                        bundlerMaintenance=[], safeTransactions=safe, provenance=prov, spVerificationMinima=sp_minima,
                        method=dict(fork=dict(anvil=rec['anvil'], **fork_parameters(args.chain), upstream='Tenderly (rpcb)', pin=rec['pin']),
                                    measurementPlanSha256=rec['plan']['sha256'], notes=rec['notes'],
                                    value='setup/safe: max(receipt gasUsed, eth_estimateGas) across senders; arms: max over senders and rounds of the smallest EntryPoint-accepted limit per field (binary search on the fork); outer: smallest handleOps gas limit with the scaled limits; preVerification not calibrated (rule)'))
        ev_path = Path(args.out_dir)/f'calibration-evidence{label}.json'
        digest = write_json(ev_path, evidence)
        cal = dict(source=dict(kind='measured', blockHash=rec['pin']['hash'], evidenceSha256=digest,
                               evidenceFile=str(Path(args.evidence_prefix)/ev_path.name)),
                   arms=arms, setup=setup, ownerPreparation=prep, ownerMaintenance=[], bundlerMaintenance=[], safeTransactions=safe,
                   spVerificationMinima=sp_minima)
        variants[label or 'checksum'] = dict(calibration=write_json(Path(args.out_dir)/f'calibration{label}.json', cal), evidence=digest)
    print(json.dumps(dict(arms=arms, setup=setup, ownerPreparation=prep, safeTransactions=safe, files=variants), indent=1))


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    p = sub.add_parser('provisional'); p.add_argument('--config', required=True); p.add_argument('--pin', type=int, required=True)
    p.add_argument('--pin-hash', required=True); p.add_argument('--out', required=True); p.add_argument('--evidence', required=True)
    p.add_argument('--evidence-rel', required=True); p.set_defaults(fn=cmd_provisional)
    p = sub.add_parser('checker'); p.add_argument('--planner-root', required=True); p.add_argument('--config', required=True)
    p.add_argument('--rpc-a-file', required=True); p.add_argument('--pin-hash', required=True); p.add_argument('--out', required=True)
    p.set_defaults(fn=cmd_checker)
    p = sub.add_parser('run')
    for k in ('--planner-root', '--config', '--inputs', '--calibration', '--checker-record', '--upstream-file', '--out-dir', '--pin-hash'):
        p.add_argument(k, required=True, help='KEYLESS upstream only: URL is visible in the anvil process command line' if k == '--upstream-file' else None)
    p.add_argument('--pin', type=int, required=True); p.add_argument('--mode', choices=('measure', 'verify'), required=True)
    p.add_argument('--port', type=int, default=18555, help='Deprecated compatibility option; the tool selects a free port'); p.add_argument('--rounds', type=int, default=2)
    p.add_argument('--fund-wei', type=int, default=1000*10**18); p.add_argument('--extra-task-recipient')
    p.set_defaults(fn=cmd_run)
    p = sub.add_parser('assemble'); p.add_argument('--measurements', required=True); p.add_argument('--config', required=True)
    p.add_argument('--out-dir', required=True); p.add_argument('--evidence-prefix', required=True); p.set_defaults(fn=cmd_assemble)
    for command in sub.choices.values():
        command.add_argument('--chain', type=int, required=True)
    args = ap.parse_args()
    fork_parameters(args.chain)
    try:
        args.fn(args)
    except (Exception, SystemExit) as error:
        record = getattr(error, 'record', None)
        if record is not None:
            text = redact(json.dumps(record, default=str), opaque=True)
            print('GATE ' + text, file=sys.stderr)
        raise SystemExit(redact(error)) from None


if __name__ == '__main__':
    main()
