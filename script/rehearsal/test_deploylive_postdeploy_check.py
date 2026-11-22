"""Offline checker tests: a simulated read-only RPC boundary; no subprocess executes."""
import os
from functools import lru_cache
import deploylive_runtime

@lru_cache(maxsize=None)
def _fixture_artifact(selector, name, directory):
    return selector(name) if directory is None else selector(name, directory)

def fixture_artifact(name, directory=None):
    return _fixture_artifact(deploylive_runtime.release_artifact, name, directory or FIXTURE_ARTIFACTS)
import contextlib
import hashlib
import io
import json
from pathlib import Path
import runpy
import re
import builtins
import sys
import subprocess
import unittest
import tempfile
from unittest.mock import patch
from types import SimpleNamespace

_read_fixture_text = Path.read_text

@lru_cache(maxsize=None)
def fixture_artifact_paths(glob, directory, pattern):
    return tuple(glob(directory, pattern))

@lru_cache(maxsize=None)
def fixture_artifact_json(path):
    # AST typing is tested against full build-info separately. RPC fixtures need
    # ABI/bytecode/metadata only; avoid reparsing the large AST on every RPC case.
    obj = json.loads(_read_fixture_text(path))
    obj.pop('ast', None)
    return json.dumps(obj)

CHECKER = Path(__file__).with_name("deploylive_postdeploy_check.py")
FIXTURE_ARTIFACTS = CHECKER.parents[2]/"contracts/test/fixtures/deploylive/release-artifacts"
ZERO = "0x" + "0" * 40

CHECKSUMMED = json.loads((CHECKER.parents[2] / "contracts/test/fixtures/deploylive/checksummed-addresses.json").read_text())

def addr(n):
    return CHECKSUMMED.get(str(n), "0x" + f"{n:040x}")

def digest(s):
    return "0x" + hashlib.sha256(s.encode()).hexdigest()

class CheckerTest(unittest.TestCase):
    def test_commit_gate(self):
        for mutation, op, dirty, expected in (
                (("config", "commit", "b" * 40), True, False, False),
                (None, True, True, False),
                ("missing_commit", True, False, False),
                (("config", "commit", ""), False, True, True),
                (None, True, False, True),
                (("config", "commit", "A" * 40), True, False, False),
                (("config", "commit", "abc"), True, False, False),
                (("config", "commit", "b" * 40), False, False, False)):
            with self.subTest(mutation=mutation, op=op, dirty=dirty):
                code, output = self.run_checker(mutation, op=op, git_dirty=dirty)
                self.assertIn(("PASS" if expected else "FAIL") + "  source commit", output)
                self.assertEqual(code, 0 if expected else 1, output)

    def test_OPDefaultsOffAndRejectsEitherLivePointer(self):
        code, output = self.run_checker(op=True)
        self.assertEqual(code, 0, output)
        for getter in ("agentIdentityRegistry", "agentReputationRegistry"):
            code, output = self.run_checker(("superPaymaster", getter + "()(address)", [], addr(999)), op=True)
            self.assertEqual(code, 1, output)
            self.assertIn("FAIL  external " + getter, output)

    def run_checker(self, mutation=None, safe_recovery=False, op=False, agents=False, real_proxy=False, git_dirty=False, release_versions=None, check_blocks=False, capture_record=None, primary_provider='Alchemy', secondary_provider='Infura', request_trace=None, expected_chain=None, env_rpc=False, argv_capture=None):
        proxy = json.loads((CHECKER.parents[2] / 'contracts/test/fixtures/deploylive/safe-proxy-v141.json').read_text())
        keys = "registry superPaymaster staking gToken xPNTsFactoryV2 aoaProtocolRegistry reputationSystem blsAggregator dvtValidator xPNTsFactory paymasterFactory paymasterV4Impl microPaymentChannel x402Facilitator aPNTs sbt policyRegistry timelockController handoverBootstrap pnts genesisOperator expectedGovernor expectedGuardian expectedSPGuardian registryImpl spImpl".split()
        keys += "spAdminImpl xPNTsTokenV1Impl xPNTsTokenV2Impl xPNTsTokenV2Ext globalTierSource superPaymasterLens".split()
        cfg = {k: addr(i + 1) for i, k in enumerate(keys)}
        cfg["commit"] = "a" * 40
        cfg.update(simpleAccountFactory=addr(101), agentValidationRegistry=addr(105) if agents else ZERO, enableAgentRegistries=agents, aPNTsPaymasterV4=ZERO, pnts=ZERO, deploymentStartBlock=1, deployerGTokenBalance=0, deployerGTokenAllowance=0, deployerSBTBalance=0, genesisIsConfigured=False, handoverBootstrapNonce=22, observedBootstrapNonce=22, expectedCap=1000, guardianN=2, minThreshold=2, defaultThreshold=2,
                   slashThreshold0=2, slashThreshold1=2, slashThreshold2=2, guardians=[addr(101), addr(102)])
        safe, deployer, tl, h = addr(200), addr(201), cfg["timelockController"], cfg["handoverBootstrap"]
        cfg.update(deployer=deployer, governanceOwner=safe, SLASH_POLICY_ADMIN=tl, X402_OWNER=safe, REPUTATION_OWNER=tl, MPC_OWNER=tl, PAYMASTER_FACTORY_OWNER=tl)
        cfg.update(deployerGTokenRecipient=safe, deployerGTokenTransferred=1985, deployerGTokenRecipientBefore=71,
                   ticketsToTreasury=71, treasuryGTokenBefore=0, deployerRemainderToRecipient=1985,
                   gTokenMintCount=2, gTokenMintRecipients=[deployer, deployer], gTokenMintAmounts=[2000, 166], gTokenTotalSupply=2166,
                   stakeAccounts=[deployer, cfg['genesisOperator'], cfg['genesisOperator'], *cfg['guardians']], stakeRoles=[digest('COMMUNITY'), digest('COMMUNITY'), digest('PAYMASTER_SUPER'), digest('DVT'), digest('DVT')], stakeAmounts=[0, 0, 50, 30, 30], ticketAmounts=[30, 30, 5, 3, 3], ticketTreasuries=[safe]*5,
                   registryImplOwner=deployer, spImplOwner=deployer)
        op_deps = json.loads((CHECKER.parents[2] / "deployments/external-deps.10.json").read_text())
        if op:
            cfg.update(simpleAccountFactory=op_deps["accountFactory"], agentValidationRegistry=op_deps["agentValidationRegistry"] if agents else ZERO)
        cfg['creationPinsSha256'] = '0x' + hashlib.sha256((CHECKER.parents[2] / f"deployments/creation-pins.{10 if op else 31337}.json").read_bytes()).hexdigest()
        from creation_pins import release_names
        cfg.update(artifactDirectory=str(FIXTURE_ARTIFACTS.relative_to(CHECKER.parents[2])), deployerCodeLength=0,
                   artifactCompileSettings={n: dict(evmVersion='cancun', viaIR=True, optimizerRuns=200 if n in ('Registry', 'TimelockHandoverBootstrap') else 500) for n in release_names()})
        cfg.update(priceFeed=op_deps['ethUsdFeed'] if op else addr(100), entryPoint=op_deps['entryPoint'],
                   agentIdentityRegistry=addr(103) if agents else ZERO, agentReputationRegistry=addr(104) if agents else ZERO,
                   paymasterV4ImplOwner=tl, spAdminImplOwner=ZERO)
        if op: cfg.pop('expectedGovernor')
        authority_bad = None
        if isinstance(mutation, tuple) and mutation[0] == "authority":
            cfg[mutation[1]] = addr(777)
            authority_bad = mutation[2]
        if isinstance(mutation, tuple) and len(mutation) == 3 and mutation[0] == "config": cfg[mutation[1]] = mutation[2]
        if mutation == "address_case":
            cfg['stakeAccounts'] = ['0x' + a[2:].upper() for a in cfg['stakeAccounts']]
        if mutation == "nonzero_recorded_balance": cfg["deployerGTokenBalance"] = 1
        if mutation == "sbt_recorded_nonzero": cfg["deployerSBTBalance"] = 1
        if mutation == "recipient_delta": cfg['deployerGTokenTransferred'] = 2058
        if mutation == "mint_sum": cfg['gTokenMintAmounts'] = [2000, 198]
        if mutation == "ticket_treasury": cfg['ticketTreasuries'] = [safe]
        if mutation in ("hex_numbers", "decimal_strings"): cfg["expectedCap"] = 2**200
        if mutation == "hex_numbers":
            cfg = {k: hex(v) if type(v) is int else v for k, v in cfg.items()}
        if mutation == "decimal_strings":
            cfg = {k: str(v) if type(v) is int else v for k, v in cfg.items()}
        if mutation == "wrong_deployer": cfg["deployer"] = addr(999)
        if mutation == "wrong_safe": cfg["governanceOwner"] = addr(999)
        if mutation == "bad_observed_nonce": cfg["observedBootstrapNonce"] = "1_0"
        if mutation == "malformed_number": cfg["expectedCap"] = "1_000"
        role_names = ("DEFAULT_ADMIN_ROLE", "PROPOSER_ROLE", "EXECUTOR_ROLE", "CANCELLER_ROLE")
        roles = {r: ("0x" + "0" * 64 if r == "DEFAULT_ADMIN_ROLE" else digest(r)) for r in role_names}
        membership = {roles[r]: {tl} if r == "DEFAULT_ADMIN_ROLE" else {safe} for r in role_names}
        if mutation == "half_handover":
            membership = {roles[r]: {tl} if r == "DEFAULT_ADMIN_ROLE" else {h} for r in role_names}
        if mutation == "unexpected_admin": membership[roles["DEFAULT_ADMIN_ROLE"]].add(addr(250))
        if mutation in role_names:
            membership[roles[mutation]].add(h)
        mapping = json.loads((CHECKER.parents[2]/"deployments/readback-artifacts.json").read_text())
        versions = json.loads((CHECKER.parents[2]/"deployments/release-versions.next.json").read_text())
        from deploylive_readback import PROXY_ABI
        runtime_codes = {}
        creation_hashes = {proxy['runtime']: proxy['codehash']} if real_proxy else {}
        pins = json.loads((CHECKER.parents[2]/'deployments/creation-pins.31337.json').read_text())
        reader = deploylive_runtime.release_artifact
        selected = lru_cache(maxsize=None)(lambda name, directory=None: reader(name, FIXTURE_ARTIFACTS)) if isinstance(mutation, tuple) and mutation[0] in ('creation', 'settings') else lambda name, directory=None: _fixture_artifact(reader, name, directory or FIXTURE_ARTIFACTS)
        # Use the checker's own artifact selection. A glob over out/<Name>.sol/*.json also matches other
        # contracts compiled from the same source file (out/Registry.sol/IGuardianExitGate.json has the
        # same runs/evmVersion); filesystem order then decided which runtime the fake chain served, and
        # on CI's Linux runner the interface won.
        for key, name in mapping.items():
            if name is None or cfg[key] == ZERO: continue
            obj = fixture_artifact(name)
            runtime_codes[cfg[key]] = obj['deployedBytecode']['object']
            if name in pins: creation_hashes[obj['bytecode']['object']] = pins[name]
        from runtime_pins import masked_code
        runtime_pins = json.loads((CHECKER.parents[2]/'deployments/runtime-pins.31337.json').read_text())['artifacts']
        for name, pin in runtime_pins.items():
            code = fixture_artifact(name)['deployedBytecode']['object']
            creation_hashes[code] = pin['rawRuntimeKeccak']
            creation_hashes[masked_code(pin, code)] = pin['maskedRuntimeKeccak']
        for name, pin in pins.items():
            creation_hashes[fixture_artifact(name)['bytecode']['object']] = pin
        if mutation == "missing_commit": del cfg["commit"]
        calldata_inputs = {}
        block_reads = []
        seen_reads = set()
        abi_signatures = {}
        from deploylive_readback import abi_type
        for key, name in mapping.items():
            name = PROXY_ABI.get(key, name)
            if name:
                for f in fixture_artifact(name)['abi']:
                    if f.get('type') == 'function':
                        input_sig = f['name'] + '(' + ','.join(map(abi_type, f['inputs'])) + ')'
                        abi_signatures[(cfg[key].lower(), input_sig)] = input_sig + ('(' + ','.join(map(abi_type, f['outputs'])) + ')' if f['outputs'] else '')
        # Getter simulation is independent of the committed policy.
        extra_addresses = {
            'EXTENSION': 'spAdminImpl', 'GTOKEN': 'gToken', 'GTOKEN_STAKING': 'staking', 'MYSBT': 'sbt',
            'REGISTRY': 'registry', 'SUPERPAYMASTER': 'superPaymaster', 'SUPER_PAYMASTER': 'superPaymaster',
            'BLS_AGGREGATOR': 'blsAggregator', 'blsAggregator': 'blsAggregator', 'DVT_VALIDATOR': 'dvtValidator',
            'mySBT': 'sbt', 'factory': 'xPNTsFactory', 'XPNTS_FACTORY': 'xPNTsFactory',
            'xpntsFactory': 'xPNTsFactoryV2', 'defaultTierSource': 'globalTierSource', 'PROTOCOL_REGISTRY': 'aoaProtocolRegistry'}
        immutable_sp = {'REGISTRY', 'ETH_USD_PRICE_FEED', 'entryPoint', 'EXTENSION'}
        # Constructor values are fixture facts, independent of the binding policy.
        for key, name in mapping.items():
            if not name or cfg[key] == ZERO: continue
            raw = bytearray.fromhex(runtime_codes[cfg[key]].removeprefix('0x'))
            for ref in runtime_pins[name]['immutableRanges']:
                field, kind = ref.get('name', ''), ref.get('type', '')
                if kind not in ('address', 'address payable') and not kind.startswith('contract ') and field not in ('_cachedThis', '_cap', '_cachedChainId') and not (isinstance(mutation, tuple) and mutation[:3] == ('immutable', name, field)): continue
                if isinstance(mutation, tuple) and mutation[:3] == ('immutable', name, field): value = mutation[3]
                elif field == '_cachedChainId': value = hex(10 if op else 31337)
                elif field == '_cap': value = hex(21_000_000 * 10**18)
                elif field in ('__self', '_cachedThis'): value = cfg[key]
                elif field == 'implementation': value = cfg['xPNTsTokenV2Impl' if key == 'xPNTsFactoryV2' else 'xPNTsTokenV1Impl']
                elif field == 'EXTENSION': value = cfg['xPNTsTokenV2Ext' if key == 'xPNTsTokenV2Impl' else 'spAdminImpl']
                elif field == 'ETH_USD_PRICE_FEED': value = op_deps['ethUsdFeed'] if op else addr(100)
                elif field == 'entryPoint': value = '0x0000000071727De22E5E9d8BAf0edAc6f37da032'
                elif field == 'timelock': value = tl
                elif field == 'registry': value = cfg['registry']
                elif field in extra_addresses: value = cfg[extra_addresses[field]]
                else: raise AssertionError('unmodeled fixture immutable: ' + name + '.' + field)
                if isinstance(mutation, tuple) and mutation[:3] == ('immutable', name, field): value = mutation[3]
                start, length = int(ref['start']), int(ref['length'])
                raw[start:start+length] = bytes.fromhex(value[2:].zfill(64))
            runtime_codes[cfg[key]] = '0x' + raw.hex()

        raw = bytearray.fromhex(runtime_codes[cfg['xPNTsFactoryV2']][2:])
        for ref in runtime_pins['xPNTsFactoryV2']['immutableRanges']:
            field = ref['name']
            if field not in ('implementationCodehash', 'extensionCodehash'): continue
            target = 'xPNTsTokenV2Impl' if field == 'implementationCodehash' else 'xPNTsTokenV2Ext'
            value = digest(runtime_codes.get(cfg[target], '0x'))
            if isinstance(mutation, tuple) and mutation[:3] == ('immutable', 'xPNTsFactoryV2', field): value = mutation[3]
            raw[int(ref['start']):int(ref['start']) + int(ref['length'])] = bytes.fromhex(value[2:])
        runtime_codes[cfg['xPNTsFactoryV2']] = '0x' + raw.hex()

        def fake_run(cmd, **kwargs):
            if cmd == ["cast", "--version"]:
                return SimpleNamespace(returncode=0, stdout="cast Version: 1.7.1-stable\n")
            if argv_capture is not None: argv_capture.append(list(sys.argv))
            if cmd[0] == "git":
                return SimpleNamespace(returncode=0, stdout=(" M file\n" if git_dirty else "") if cmd[-1] == "--porcelain" else "a" * 40 + "\n")
            self.assertEqual(cmd[0], "cast")
            self.assertNotIn("--rpc-url", cmd)
            self.assertIn(kwargs["env"]["ETH_RPC_URL"], ("https://secret.alchemy.com/private-token", "https://independent.infura.io/secret"))
            kind, args = cmd[1], [addr(int(a, 16)) if re.fullmatch(r"0x[0-9a-fA-F]{40}", a) else a for a in cmd[2:]]
            if request_trace is not None and kind == 'rpc':
                request_trace.append((list(args), kwargs['env']['ETH_RPC_URL'].startswith('https://independent')))
            if kind == 'rpc' and args[0] in ('eth_getCode', 'eth_getStorageAt', 'eth_getBalance', 'eth_call'):
                read_key = (kwargs['env']['ETH_RPC_URL'], *args)
                self.assertNotIn(read_key, seen_reads, 'state read collected more than once')
                seen_reads.add(read_key)
                self.assertEqual(json.loads(args[-1]), {'blockHash': '0x'+'12'*32, 'requireCanonical': True})
            if check_blocks and kind == 'rpc' and args[0] == 'eth_getLogs': self.assertEqual(json.loads(args[1])['toBlock'], '0x2a')
            def response(out, rc=0): return SimpleNamespace(returncode=rc, stdout=out if not rc else '', stderr=out if rc else '')
            if kind == 'rpc' and args[0] == 'eth_call' and mutation == 'second_call' and kwargs['env']['ETH_RPC_URL'].startswith('https://independent'):
                return response(json.dumps('0xff'))
            if kind == 'to-check-sum-address': return response(args[0])
            if kind == 'decode-abi':
                payload = json.loads(args[1])
                if '--json' in args:
                    if isinstance(payload, dict): return response(json.dumps(payload['values']))
                    value = payload
                    if value.startswith('"'): value = json.loads(value)
                    elif re.fullmatch(r'[0-9]+', value): value = int(value)
                    elif value.startswith('['): value = re.findall(r'0x[0-9a-fA-F]{40}', value)
                    return response(json.dumps([value]))
                return response(payload['text'] if isinstance(payload, dict) else payload)
            if kind == 'rpc' and args[0] in ('eth_getCode', 'eth_getStorageAt', 'eth_getBalance'):
                subkind = {'eth_getCode':'code', 'eth_getStorageAt':'storage', 'eth_getBalance':'balance'}[args[0]]
                result = fake_run(['cast', subkind, *[('0' if subkind == 'storage' and a == '0x0' else a) for a in args[1:-1]]], **kwargs)
                if result.returncode: return result
                return response(json.dumps(hex(int(result.stdout)) if subkind == 'balance' else result.stdout))
            if kind == 'rpc' and args[0] == 'eth_call' and 'from' not in json.loads(args[1]):
                q = json.loads(args[1]); target = q['to']; input_sig, *params = calldata_inputs[q['data']]
                sig = abi_signatures.get((target.lower(), input_sig), input_sig)
                safe_signatures = {'getThreshold()':'(uint256)', 'getOwners()':'(address[])', 'getModulesPaginated(address,uint256)':'(address[],address)', 'owner()':'(address)'}
                if input_sig in safe_signatures and (target.lower(),input_sig) not in abi_signatures: sig += safe_signatures[input_sig]
                if input_sig in ('getRoleConfig(bytes32)', 'operators(address)'): sig = input_sig
                result = fake_run(['cast','call',target,sig,*params], **kwargs)
                if result.returncode: return result
                # Raw ABI consumers keep their raw bytes; decoded consumers get a fixture envelope.
                encoded = result.stdout if input_sig in ('getRoleConfig(bytes32)', 'operators(address)') else json.dumps(result.stdout)
                if input_sig.startswith(('eip712Domain(', 'getMetadata(', 'getSupportedTokensInfo(')):
                    encoded = result.stdout
                return response(json.dumps(encoded))
            if mutation == "rpc_error" and kind not in ("keccak", "calldata", "sig"):
                return SimpleNamespace(returncode=1, stdout="", stderr="connection failed https://secret.alchemy.com/private-token")
            out, rc = "", 0
            if kind == 'calldata': calldata_inputs[digest('|'.join(args))] = args
            if kind in ("keccak", "calldata", "sig", "abi-encode"):
                out = creation_hashes.get(args[0], digest("|".join(args))) if kind == "keccak" else digest("|".join(args))
            elif kind == "code" and args[0] == deployer:
                out = '0xef0100' + '12'*20 if mutation == 'delegated_deployer' else '0x'
            elif kind == "balance": out = "0"
            elif kind == "storage" and args[0].lower() in (safe.lower(), addr(777).lower()) and (args[0].lower() == safe.lower() or authority_bad):
                slot = args[1]
                value = "d9db270c1b5e3bd161e8c8503c55ceabee709552" if slot == "0" else "f48f2b2d2a534e402487b3ee7c18c33aec0fe5e4" if slot == digest("fallback_manager.handler.address") else "0"
                if mutation == "safe_v141" and slot == "0": value = "29fcb43b46531bca003ddc8fcb67ffe91900c762"
                if mutation == "safe_singleton" and slot == "0": value = "777"
                if mutation == "safe_handler" and slot == digest("fallback_manager.handler.address"): value = "777"
                if mutation == "safe_guard" and slot == digest("guard_manager.guard.address"): value = "777"
                if args[0] == addr(777) and authority_bad == "guard" and slot == digest("guard_manager.guard.address"): value = "777"
                out = "0x" + value.zfill(64)
            elif kind == "storage" and mutation in ('slot_registry', 'slot_superPaymaster') and args[0] == cfg[mutation[5:]]: out = '0x'+'00'*32
            elif kind == "storage" and mutation == 'second_slot' and kwargs['env']['ETH_RPC_URL'].startswith('https://independent'): out = '0x'+'00'*32
            elif kind == "storage": out = "0x" + cfg["registryImpl" if args[0] == cfg["registry"] else "spImpl"][2:].zfill(64)
            elif kind == "code" and mutation == 'second_runtime' and kwargs['env']['ETH_RPC_URL'].startswith('https://independent'): out = '0x6001'
            elif kind == "code":
                out = "0x" if mutation in ("absent_h", "half_handover") and args[0] == h else "0x60806040525f80fd"
                if args[0] in runtime_codes:
                    out = runtime_codes[args[0]]
                    if mutation == "runtime_" + next(k for k in mapping if cfg[k] == args[0]): out = "0xff" + out[4:]
                if args[0] == safe or (args[0] == addr(777) and authority_bad): out = "0x6001" if mutation == "safe_codehash" or authority_bad == "codehash" else proxy["runtime"] if real_proxy else "0x6000"
                if args[0] == addr(777) and authority_bad == "eoa": out = "0x"
                if args[0] == addr(777) and authority_bad == "delegation": out = "0xef0100" + "00"*20
                if args[0] == h and mutation in ("absent_h", "half_handover"): out = "0x"
                if args[0] == safe and mutation == "delegated_safe": out = "0xef0100" + "00" * 20
            elif kind == "rpc":
                if args[0] == 'anvil_nodeInfo': return response(json.dumps({'forkConfig': {'forkUrl': 'https://untrusted.invalid'}}), 0)
                if args[0] in ("eth_getBlockByNumber", "eth_getBlockByHash"):
                    block_reads.append(args[1])
                    if mutation == 'reorg' and len(block_reads) > 1: return response(json.dumps(dict(number='0x2a', hash='0x'+'34'*32, timestamp='0x1234')))
                    if mutation == 'second_header' and kwargs['env']['ETH_RPC_URL'].startswith('https://independent'): return response(json.dumps(dict(number='0x2a', hash='0x'+'34'*32, timestamp='0x1234')))
                    return SimpleNamespace(returncode=0, stdout=json.dumps(dict(number='0x2a' if args[1] == 'latest' or args[0] == 'eth_getBlockByHash' else args[1], hash='0x'+'12'*32, timestamp='0x1234')), stderr='')
                if args[0] == "eth_chainId":
                    return SimpleNamespace(returncode=0, stdout=('"0xa"' if op else '"0x7a69"') if mutation != "unknown_chain" else '"0xf423f"', stderr="")
                if args[0] == "eth_call":
                    q = json.loads(args[1])
                    q["to"] = addr(int(q["to"], 16))
                    if q["to"] in (cfg["registryImpl"], cfg["spImpl"]):
                        error = "UUPSUnauthorizedCallContext()" if q["data"] == digest("|".join(["upgradeToAndCall(address,bytes)", q["to"], "0x"])) else "InvalidInitialization()"
                        rc, out = 1, digest(error)
                        if mutation == "implementation_unlocked": rc, out = 0, "0x"
                    elif q["to"] == cfg["gToken"]: rc, out = (0, "0x") if mutation == "mint_allowed" else (1, digest("OwnableUnauthorizedAccount(address)"))
                    elif q["to"] in (cfg["registry"], cfg["superPaymaster"]): rc, out = 1, digest("OwnableUnauthorizedAccount(address)")
                    else: rc, out = 1, digest("|".join(["ForbiddenGenericSelector(bytes4)", digest("slashByDVT(address,bytes32,uint256,string)")]))
                    # Each generic request embeds a different denied selector.
                    if q["to"] == cfg["blsAggregator"]:
                        for signature, arguments in (("batchUpdateGlobalReputation(uint256,address[],uint256[],uint256,bytes)", ["1", "[]", "[]", "1", "0x01"]), ("slash(address,uint256,string)", [deployer, "1", "x"]), ("slashByDVT(address,bytes32,uint256,string)", [deployer, "0x" + "00" * 32, "1", "x"])):
                            inner = digest("|".join([signature] + arguments))
                            if q["data"] == digest("|".join(["executeProposal(uint256,address,bytes,uint256,bytes)", "1", cfg["registry"], inner, "3", "0x00"])):
                                out = digest("|".join(["ForbiddenGenericSelector(bytes4)", digest(signature)]))
                else:
                    self.assertEqual(args[0], "eth_getLogs")
                    self.assertEqual(json.loads(args[1])["fromBlock"], "0x1")
                    if json.loads(args[1])["address"] == cfg['gToken']:
                        events = [dict(blockNumber='0x1', blockHash='0x'+'12'*32, topics=[digest('Transfer(address,address,uint256)'), '0x'+'00'*32, '0x'+deployer[2:].zfill(64)], data=hex(n)) for n in [2000, 166]]
                        if mutation == "mint_event": events[1]['data'] = hex(167)
                        return SimpleNamespace(returncode=0, stdout=json.dumps(events), stderr='')
                    logs = []
                    for rid, accounts in membership.items():
                        for a in sorted(accounts):
                            logs.append(dict(blockNumber="0x1", logIndex=hex(len(logs)), topics=[digest("RoleGranted(bytes32,address,address)"), rid, "0x" + a[2:].zfill(64)]))
                    for role in ("PROPOSER_ROLE", "EXECUTOR_ROLE", "CANCELLER_ROLE"):
                        rid = roles[role]
                        logs.append(dict(blockNumber="0x1", logIndex=hex(len(logs)), topics=[digest("RoleGranted(bytes32,address,address)"), rid, "0x" + h[2:].zfill(64)]))
                        if h not in membership[rid]:
                            logs.append(dict(blockNumber="0x1", logIndex=hex(len(logs)), topics=[digest("RoleRevoked(bytes32,address,address)"), rid, "0x" + h[2:].zfill(64)]))
                    targets = [cfg["registry"], cfg["superPaymaster"], cfg["aPNTs"]] + [tl] * 7
                    data = [digest("acceptOwnership()")] * 3
                    data += [digest("|".join(["grantRole(bytes32,address)", roles[r], safe])) for r in role_names[1:]]
                    data += [digest("|".join(["revokeRole(bytes32,address)", roles[r], h])) for r in role_names[1:]]
                    data += [digest("updateDelay(uint256)|172800")]
                    for scheduled in (True, False):
                        topic = digest("CallScheduled(bytes32,uint256,address,uint256,bytes,bytes32,uint256)" if scheduled else "CallExecuted(bytes32,uint256,address,uint256,bytes)")
                        for i in range(10):
                            signature = "f(address,uint256,bytes,bytes32,uint256)" if scheduled else "f(address,uint256,bytes)"
                            payload = [targets[i], "0", data[i]] + (["0x" + "00" * 32, "0"] if scheduled else [])
                            logs.append(dict(blockNumber="0x2", logIndex=hex(len(logs)), topics=[topic, digest("operation"), hex(i)], data=digest("|".join([signature] + payload))))
                    if mutation == "extra_operation": logs.append(dict(logs[-1], topics=[logs[-1]["topics"][0], digest("other"), "0x0"]))
                    if mutation == "missing_execution": logs.pop()
                    if mutation == "wrong_batch": logs[-1]["data"] = "0x00"
                    out = json.dumps([dict(log, blockHash='0x'+'12'*32) for log in logs])
            elif kind == "call":
                target, sig, *params = args
                if mutation == 'getter_revert' and target == cfg['globalTierSource'] and sig.startswith('REGISTRY('): return response('revert', 1)
                if mutation == 'version_revert' and target == cfg['staking'] and sig.startswith('version('): return response('revert', 1)
                getter = sig.split('(')[0]
                key = next((k for k in mapping if cfg[k].lower() == target.lower()), '')
                if getter == 'eip712Domain': out = json.dumps(dict(values=['0x0f', '', '1', 31337, target, '0x'+'00'*32, []], text='domain'))
                elif getter == 'getMetadata': out = json.dumps(dict(values=['', '', '', '', ZERO], text='metadata'))
                elif getter == 'getSupportedTokensInfo': out = json.dumps(dict(values=[[], [], []], text='tokens'))
                elif getter in ('getSupportedTokens', 'getAllTokens'): out = '[]'
                elif getter == 'ETH_SENTINEL': out = '0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE'
                elif getter == 'implementation': out = cfg['xPNTsTokenV2Impl' if key == 'xPNTsFactoryV2' else 'xPNTsTokenV1Impl']
                elif getter == 'EXTENSION' and key == 'xPNTsTokenV2Impl': out = cfg['xPNTsTokenV2Ext']
                elif getter in extra_addresses: out = cfg[extra_addresses[getter]]
                elif getter in ('FACTORY','SUPERPAYMASTER_ADDRESS','community','communityOwner','creditTierSource','emergencyRevokedAddress','pendingSP','pendingStandby','pendingTierSource','standbySP','reputationCalculator','pendingAPNTsToken','pendingBLSAgg','pendingFraudProofVerifier'): out = ZERO
                elif sig == "getModulesPaginated(address,uint256)(address[],address)": out = ("[" + addr(777) + "]" if mutation == "safe_modules" else "[]") + "\n" + addr(1)
                elif sig == "getThreshold()(uint256)": out = "1" if mutation == "threshold_one" else "2"
                elif sig == "getOwners()(address[])" and mutation == "owners_error":
                    rc, out = 1, "error " + addr(301) + " " + addr(302)
                elif sig == "getOwners()(address[])": out = "[" + (deployer if mutation == "deployer_safe_owner" else cfg["guardians"][0] if mutation == "overlap" else addr(301)) + ", " + addr(302) + "]"
                elif sig.startswith("hashOperationBatch"): out = digest("operation")
                elif sig == "isOperationDone(bytes32)(bool)": out = "true"
                elif sig == "allowance(address,address)(uint256)": out = "0"
                elif sig == "owner()(address)": out = deployer if target in (cfg["registryImpl"], cfg["spImpl"]) else safe if target in [cfg[k] for k in ("gToken", "blsAggregator", "dvtValidator", "xPNTsFactory", "xPNTsFactoryV2", "aoaProtocolRegistry", "x402Facilitator")] else tl
                elif sig == "pendingOwner()(address)": out = tl if mutation == "pending" else ZERO
                elif sig == "getRoleConfig(bytes32)": out = "0x" + "0" * (64 * 11) + tl[2:].zfill(64) + "0" * 64
                elif sig == "isReputationSource(address)(bool)": out = str(params[0] in (cfg["blsAggregator"], cfg["reputationSystem"])).lower()
                elif sig == "isValidator(address)(bool)": out = str(params[0] in cfg["guardians"]).lower()
                elif sig == "hasRole(bytes32,address)(bool)":
                    out = str(params[1] in membership.get(params[0], set()) if target == tl else params[1] == cfg["genesisOperator"]).lower()
                elif sig.split("(")[0] in role_names: out = roles[sig.split("(")[0]]
                elif sig == "getMinDelay()(uint256)": out = "0" if mutation == "delay" else "172800"
                elif sig in ("treasury()(address)", "daoMultisig()(address)", "minter()(address)", "capGuardian()(address)"): out = safe
                elif sig in ("slashPolicyAdmin()(address)", "timelock()(address)"): out = tl
                elif sig == "guardian()(address)": out = cfg["expectedSPGuardian"] if target == cfg["superPaymaster"] else cfg["expectedGuardian"]
                elif sig == "APNTS_TOKEN()(address)": out = cfg["aPNTs"]
                elif sig == "ethUsdPriceFeed()(address)": out = ZERO
                elif sig == "registry()(address)": out = cfg["registry"]
                elif sig == "cap()(uint256)": out = str(2**200) if mutation in ("hex_numbers", "decimal_strings") else "1000"
                elif sig == "priceStalenessThreshold()(uint256)": out = "4200"
                elif "Threshold" in sig or "Thresholds" in sig: out = "2"
                elif sig == "validatorAtSlot(uint8)(address)": out = cfg["guardians"][int(params[0]) - 1]
                elif sig == "operators(address)": out = "0x" + "0" * (64 * 9)
                elif sig == "ETH_USD_PRICE_FEED()(address)": out = op_deps["ethUsdFeed"] if op else addr(100)
                elif sig == "agentIdentityRegistry()(address)": out = addr(103) if agents else ZERO
                elif sig == "agentReputationRegistry()(address)": out = addr(104) if agents else ZERO
                elif sig == "entryPoint()(address)": out = "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
                elif sig == "pendingSBTBurn(address)(bool)": out = "true" if mutation == "pending_burn" else "false"
                elif sig == "getPaymasterByOperator(address)(address)": out = addr(999) if mutation == "aoa_present" else ZERO
                elif sig == "getUserRoles(address)(bytes32[])": out = "[]"
                elif sig == "authorizedSlashers(address)(bool)": out = "false"
                elif sig == "fraudProofVerifier()(address)": out = ZERO
                elif sig == "balanceOf(address)(uint256)": out = "2056" if target == cfg['gToken'] and params[0] == safe else "110" if target == cfg['gToken'] and params[0] == cfg['staking'] else "0"
                elif sig == "totalSupply()(uint256)": out = "2166"
                elif sig == "getLockedStake(address,bytes32)(uint256)": out = "50" if params[1] == digest("PAYMASTER_SUPER") else "30" if params[1] == digest("DVT") else "0"
                elif sig == "version()(string)": out = json.dumps(release_versions["SuperPaymaster"]) if release_versions and target==cfg["superPaymaster"] else json.dumps(versions.get(PROXY_ABI.get(next((k for k in mapping if cfg[k] == target), ''), mapping.get(next((k for k in mapping if cfg[k] == target), ''))), 'fixture'))
                else: self.fail(f"Unhandled {sig}")
                if mutation == 'getter_unaccounted' and key == 'globalTierSource' and getter == 'REGISTRY': out = addr(999)
                if key in ('spImpl','spAdminImpl') and getter not in immutable_sp | {'version'}: out = deployer if getter == 'owner' and key == 'spImpl' else ZERO
                if key == 'registryImpl' and getter in ('GTOKEN_STAKING','MYSBT','SUPER_PAYMASTER','blsAggregator'): out = ZERO
                if key == 'paymasterV4Impl' and getter in ('entryPoint','ethUsdPriceFeed','treasury'): out = ZERO
                if target == addr(777):
                    if authority_bad == "threshold" and sig == "getThreshold()(uint256)": out = "1"
                    if authority_bad == "owner" and sig == "getOwners()(address[])": out = "[" + deployer + ", " + addr(302) + "]"
                    if authority_bad == "modules" and sig.startswith("getModulesPaginated"): out = "[" + deployer + "]\n" + addr(1)
                if mutation == "sbt_recorded_nonzero" and target == cfg["sbt"] and sig == "balanceOf(address)(uint256)" and params[0] == deployer: out = "1"
                if mutation == "nonzero_recorded_balance" and target == cfg["gToken"] and sig == "balanceOf(address)(uint256)" and params[0] == deployer: out = "1"
                if isinstance(mutation, tuple) and len(mutation) == 4 and mutation[0] != "immutable":
                    key, changed_sig, changed_params, replacement = mutation
                    if target == cfg[key] and sig == changed_sig and params == changed_params:
                        out = replacement
                        if sig == "getRoleConfig(bytes32)": out = "0x" + "0" * (64 * 11) + replacement[2:].zfill(64) + "0" * 64
            else: self.fail(f"Non-read-only command: {kind}")
            if kind == "code" and isinstance(mutation, tuple) and mutation[0] == "delegation":
                target = cfg[mutation[1]] if mutation[1] in cfg else addr(301)
                if isinstance(target, list): target = target[0]
                if args[0].lower() == target.lower(): out = "0xef0100" + "12"*20
            return SimpleNamespace(returncode=rc, stdout=out if rc == 0 else "", stderr=out if rc else "")
        original_open = builtins.open
        def fixture_open(path, *args, **kwargs):
            if str(path) == "fixture.json": return io.StringIO(json.dumps(cfg))
            return original_open(path, *args, **kwargs)
        original_glob = Path.glob
        original_read = Path.read_text
        def fixture_read(path, *args, **kwargs):
            if path.name == 'second-fixture' and mutation == 'second_missing': raise OSError('missing fixture endpoint')
            raw = fixture_artifact_json(path) if path.parent.name.endswith('.sol') else original_read(path, *args, **kwargs)
            if mutation == 'missing_immutable_policy' and path.name == 'readback-policy.json':
                obj = json.loads(raw); obj.get('immutableBindings', {}).get('SuperPaymaster', {}).pop('EXTENSION', None); return json.dumps(obj)
            if path.name == 'safe-official.json' and not real_proxy:
                obj = json.loads(raw); obj['proxyCodehashes'] = [digest('0x6000')]; return json.dumps(obj)
            if isinstance(mutation, tuple) and mutation[0] == 'versions' and path.name == 'release-versions.next.json':
                obj = json.loads(raw); del obj[mutation[1]]; return json.dumps(obj)
            if mutation == 'missing_dep' and path.name == 'external-deps.31337.json':
                obj = json.loads(raw); del obj['ethUsdFeed']; return json.dumps(obj)
            if isinstance(mutation, tuple) and mutation[0] == 'creation' and path.parent.name == mutation[1] + '.sol':
                obj = json.loads(raw); obj['bytecode']['object'] = '0x00'; return json.dumps(obj)
            if isinstance(mutation, tuple) and mutation[0] == 'settings' and path.parent.name == mutation[1] + '.sol':
                obj = json.loads(raw); obj['metadata']['settings']['optimizer']['runs'] = 200; return json.dumps(obj)
            return raw
        endpoint_dir = tempfile.TemporaryDirectory(dir=CHECKER.parents[2]/'cache')
        endpoint_file = Path(endpoint_dir.name)/'second-fixture'
        endpoint_file.write_text('https://secret.alchemy.com/private-token' if mutation == 'second_same' else 'https://independent.infura.io/secret')
        output = io.StringIO()
        with endpoint_dir, patch.object(sys, "argv", [str(CHECKER)] + ([] if env_rpc else ["https://secret.alchemy.com/private-token"]) + ["fixture.json", deployer, safe] + (["--safe-recovery"] if safe_recovery else [])), patch("builtins.open", side_effect=fixture_open), patch("subprocess.run", side_effect=fake_run), patch.object(Path, "read_text", fixture_read), patch.object(Path, "glob", lambda path, pattern: iter(fixture_artifact_paths(original_glob, path, pattern))), patch('deploylive_runtime.artifact_directory', return_value=str(FIXTURE_ARTIFACTS.relative_to(CHECKER.parents[2]))), patch('deploylive_runtime.release_artifact', side_effect=selected), patch('deploylive_readback.release_artifact', side_effect=selected), patch('runtime_pins.release_artifact', side_effect=selected), patch('runtime_pins.keccak', side_effect=lambda code: creation_hashes.get(code, digest(code))), patch('deploylive_readback.checksum', side_effect=lambda a: addr(int(a,16))), patch('deploylive_readback.sha', return_value='0x'+'ab'*32), patch('deploylive_readback.keccak', side_effect=lambda code: creation_hashes.get(code, digest(code))), patch('deploylive_readback.write', side_effect=lambda path, record: capture_record.append(record) if capture_record is not None else None), patch.dict(os.environ, ETH_RPC_URL='https://secret.alchemy.com/private-token', DEPLOYLIVE_EXPECTED_CHAIN_ID=str(expected_chain if expected_chain is not None else (10 if op else 31337)), DEPLOYLIVE_EVIDENCE_DIR=str(CHECKER.parents[2]/'cache/readback/checker-fixture'), DEPLOYLIVE_ENDPOINT_PROVIDER=primary_provider, DEPLOYLIVE_SECOND_ENDPOINT_PROVIDER=secondary_provider, DEFAULT_ARTIFACTS_OUT=str(FIXTURE_ARTIFACTS.relative_to(CHECKER.parents[2])), DEPLOYLIVE_SECOND_RPC_FILE=str(endpoint_file)), contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            with self.assertRaises(SystemExit) as caught:
                runpy.run_path(str(CHECKER), run_name="__main__")
        self.assertNotIn("private-token", output.getvalue())
        return caught.exception.code, output.getvalue()

    def test_round9_all_release_pins(self):
        rc, out = self.run_checker(('creation', 'APNTsCapped'))
        self.assertEqual(rc, 1, out)
        self.assertIn('FAIL  release creation pins', out)

    def test_round9_directory(self):
        rc, out = self.run_checker(('config', 'artifactDirectory', 'wrong-out'))
        self.assertEqual(rc, 1, out)
        self.assertIn('FAIL  artifact directory', out)

    def test_round9_settings(self):
        rc, out = self.run_checker(('settings', 'SuperPaymaster'))
        self.assertEqual(rc, 1, out)
        self.assertIn('FAIL  artifact compile settings', out)

    def test_round9_recorded_settings(self):
        rc, out = self.run_checker(('config', 'artifactCompileSettings', {}))
        self.assertEqual(rc, 1, out)
        self.assertIn('FAIL  artifact compile settings', out)

    def test_round9_deployer_code(self):
        rc, out = self.run_checker('delegated_deployer')
        self.assertEqual(rc, 1, out)
        self.assertIn('FAIL  deployer has no code', out)

    def test_round9_recorded_code(self):
        rc, out = self.run_checker(('config', 'deployerCodeLength', 23))
        self.assertEqual(rc, 1, out)
        self.assertIn('FAIL  deployer has no code', out)

    def test_artifact_selection_independent_of_glob_order(self):
        # CI regression: out/Registry.sol/ also holds IGuardianExitGate.json with the same settings.
        # Serve every glob in reverse order (the order CI's runner produced); the run must still PASS.
        import pathlib
        original = pathlib.Path.glob
        with patch.object(pathlib.Path, 'glob', lambda self, pattern: iter(sorted(original(self, pattern), reverse=True))):
            rc, out = self.run_checker()
        self.assertEqual(rc, 0, out)
        self.assertIn('PASS  runtime registryImpl', out)

    def test_round8_real_proxy(self):
        proxy = json.loads((CHECKER.parents[2] / 'contracts/test/fixtures/deploylive/safe-proxy-v141.json').read_text())
        recorded = json.loads((CHECKER.parents[2] / proxy['source'].split(':')[0]).read_text())
        self.assertIn(proxy['runtime'], json.dumps(recorded))
        actual = subprocess.check_output(['cast', 'keccak', proxy['runtime']], text=True).strip()
        self.assertEqual(actual, proxy['codehash'])
        official = json.loads((CHECKER.parents[2] / 'deployments/safe-official.json').read_text())
        self.assertIn(actual, official['proxyCodehashes'])
        rc, out = self.run_checker(real_proxy=True)
        self.assertEqual(rc, 0, out)
        self.assertIn('PASS  Safe official proxy codehash', out)

    def test_round8_fake_proxy(self):
        rc, out = self.run_checker('safe_codehash', agents=True)
        self.assertEqual(rc, 1, out)
        self.assertIn('FAIL  Safe official proxy codehash', out)

    def test_round8_each_authority_proxy(self):
        for key in ("SLASH_POLICY_ADMIN", "X402_OWNER", "REPUTATION_OWNER", "MPC_OWNER", "PAYMASTER_FACTORY_OWNER", "deployerGTokenRecipient"):
            with self.subTest(key=key):
                rc, out = self.run_checker(('authority', key, 'codehash'), agents=True)
                self.assertEqual(rc, 1, out)
                self.assertIn('FAIL  ' + key + ' resolved contract', out)

    def test_round8_creation_pin(self):
        for name in ('Registry', 'SuperPaymaster', 'TimelockController'):
            with self.subTest(name=name):
                rc, out = self.run_checker(('creation', name), agents=True)
                self.assertEqual(rc, 1, out)
                self.assertIn('FAIL  release creation pins', out)
                key = {'Registry': 'registryImpl', 'SuperPaymaster': 'spImpl', 'TimelockController': 'timelockController'}[name]
                self.assertIn('FAIL  runtime ' + key, out)

    def test_round8_config_pins_sha(self):
        rc, out = self.run_checker(('config', 'creationPinsSha256', '0x' + '00'*32), agents=True)
        self.assertEqual(rc, 1, out)
        self.assertIn('FAIL  creationPinsSha256', out)

    def test_round8_missing_dep(self):
        rc, out = self.run_checker('missing_dep')
        self.assertEqual(rc, 1, out)
        self.assertIn('FAIL external dependencies: missing/invalid ethUsdFeed', out)

    def test_round8_agents_off(self):
        rc, out = self.run_checker()
        self.assertEqual(rc, 0, out)

    def test_round8_agents_on(self):
        rc, out = self.run_checker(agents=True)
        self.assertEqual(rc, 0, out)

    def test_round8_invalid_switch(self):
        rc, out = self.run_checker(('config', 'enableAgentRegistries', 'false'))
        self.assertEqual(rc, 1, out)
        self.assertIn('FAIL missing/invalid config boolean: enableAgentRegistries', out)

    def test_round7_each_unsafe_authority(self):
        for key in ("SLASH_POLICY_ADMIN", "X402_OWNER", "REPUTATION_OWNER", "MPC_OWNER", "PAYMASTER_FACTORY_OWNER", "deployerGTokenRecipient"):
            for bad in ("eoa", "delegation", "threshold", "owner", "modules", "guard"):
                with self.subTest(key=key, bad=bad):
                    rc, out = self.run_checker(("authority", key, bad))
                    self.assertEqual(rc, 1)
                    self.assertIn("FAIL  " + key + " resolved contract", out)

    def test_round7_explicit_authorities(self):
        for key in ("SLASH_POLICY_ADMIN", "X402_OWNER", "REPUTATION_OWNER", "MPC_OWNER", "PAYMASTER_FACTORY_OWNER", "deployerGTokenRecipient"):
            rc, out = self.run_checker(("config", key, addr(777)))
            self.assertEqual(rc, 1)
            self.assertIn("FAIL  " + key + " resolved contract", out)

    def test_round7_runtime_bytecode(self):
        for key in ("registryImpl", "spImpl", "timelockController"):
            with self.subTest(key=key): self.assertEqual(self.run_checker("runtime_" + key)[0], 1)

    def test_round7_external_dependencies(self):
        for mutation in ["unknown_chain", ("config", "simpleAccountFactory", addr(999)), ("config", "agentValidationRegistry", addr(999))] + [("superPaymaster", sig + "()(address)", [], addr(999)) for sig in ("ETH_USD_PRICE_FEED", "agentIdentityRegistry", "agentReputationRegistry", "entryPoint")]:
            with self.subTest(mutation=mutation):
                rc, out = self.run_checker(mutation)
                self.assertEqual(rc, 1)
                label = "external dependencies" if mutation == "unknown_chain" else "external accountFactory" if mutation[1] == "simpleAccountFactory" else "external validation registry recorded" if mutation[1] == "agentValidationRegistry" else "external " + {"ETH_USD_PRICE_FEED": "ethUsdFeed", "entryPoint": "entryPoint", "agentIdentityRegistry": "agentIdentityRegistry", "agentReputationRegistry": "agentReputationRegistry"}[mutation[1].split("(")[0]]
                self.assertRegex(out, r"FAIL +" + label)

    def test_round7_safe_v141(self):
        rc, out = self.run_checker("safe_v141")
        self.assertEqual(rc, 0, out)

    def test_round7_safe_security(self):
        for mutation in ("safe_singleton", "safe_handler", "safe_guard", "safe_modules"):
            with self.subTest(mutation=mutation):
                self.assertEqual(self.run_checker(mutation)[0], 1)

    def test_round7_absent_contract_checks(self):
        for mutation in ("aoa_present", ("config", "aPNTsPaymasterV4", None), ("config", "aPNTsPaymasterV4", addr(999)), ("config", "pnts", addr(999))):
            self.assertEqual(self.run_checker(mutation)[0], 1)

    def test_round7_sbt_zero_and_no_pending_burn(self):
        for mutation in ("pending_burn", "sbt_recorded_nonzero"):
            self.assertEqual(self.run_checker(mutation)[0], 1)

    def test_round7_address_case(self):
        rc, out = self.run_checker("address_case")
        self.assertEqual(rc, 0, out)

    def test_round7_owners_read_error(self):
        rc, out = self.run_checker("owners_error")
        self.assertEqual(rc, 1, out)
        self.assertIn("FAIL  Safe owners exclude deployer", out)

    def test_round6c_accounting(self):
        for mutation, label in [
            (("config", "ticketsToTreasury", 70), "GToken treasury tickets"),
            (("config", "treasuryGTokenBefore", 1), "GToken treasury tickets"),
            (("gToken", "balanceOf(address)(uint256)", [addr(200)], "2055"), "GToken treasury tickets"),
            (("config", "deployerRemainderToRecipient", 1984), "GToken conservation"),
            (("config", "ticketTreasuries", [addr(201)]*5), "GToken ticket ledger")]:
            with self.subTest(mutation=mutation):
                rc, out = self.run_checker(mutation)
                self.assertEqual(rc, 1, out)
                self.assertIn("FAIL  " + label, out)

    def test_round6b_each_added_checker_assertion(self):
        cases = []
        for key in ("SLASH_POLICY_ADMIN", "X402_OWNER", "REPUTATION_OWNER", "MPC_OWNER", "PAYMASTER_FACTORY_OWNER"):
            cases.append((("config", key, ZERO), key + " resolved contract"))
        cases += [(("gToken", "totalSupply()(uint256)", [], "1"), "GToken totalSupply == mints"),
                  (("gToken", "balanceOf(address)(uint256)", [addr(3)], "1"), "GToken conservation"),
                  (("config", "registryImplOwner", addr(999)), "registryImpl isolated"),
                  (("config", "spImplOwner", addr(999)), "spImpl isolated"),
                  ("recipient_delta", "GToken recipient exact delta"), ("mint_sum", "GToken mint ledger"),
                  ("ticket_treasury", "GToken ticket ledger"), ("mint_event", "GToken mint events == ledger"),
                  ("mint_allowed", "deployer GToken mint rejected"),
                  ("nonzero_recorded_balance", "deployer GToken balance == recorded")]
        accounts = [addr(201), addr(21), addr(21), addr(101), addr(102)]
        roles = ["COMMUNITY", "COMMUNITY", "PAYMASTER_SUPER", "DVT", "DVT"]
        for i, (account, role) in enumerate(zip(accounts, roles)):
            cases.append((("staking", "getLockedStake(address,bytes32)(uint256)", [account, digest(role)], "1"), f"GToken stake[{i}]"))
        for mutation, label in cases:
            with self.subTest(label=label):
                rc, out = self.run_checker(mutation)
                self.assertEqual(rc, 1, out)
                self.assertIn("FAIL  " + label, out)

    def test_round6b_new_numeric_inputs(self):
        for key in ("observedBootstrapNonce", "deployerGTokenTransferred", "deployerGTokenRecipientBefore", "gTokenMintCount", "gTokenTotalSupply", "ticketsToTreasury", "treasuryGTokenBefore", "deployerRemainderToRecipient"):
            with self.subTest(key=key):
                rc, out = self.run_checker(("config", key, "1_000"))
                self.assertEqual(rc, 1)
                self.assertIn("FAIL missing/invalid config integer: " + key, out)

    def test_round6b_integer_array_validation(self):
        for key in ("gTokenMintAmounts", "stakeAmounts", "ticketAmounts"):
            for value in ("1", ["1_000"], [True], [-1]):
                with self.subTest(key=key, value=value):
                    rc, out = self.run_checker(("config", key, value))
                    self.assertEqual(rc, 1)
                    self.assertIn("FAIL missing/invalid config integer array: " + key, out)

    def test_round6b_deployer_safe_owner(self):
        rc, out = self.run_checker("deployer_safe_owner")
        self.assertEqual(rc, 1, out)
        self.assertIn("FAIL  Safe owners exclude deployer", out)

    def test_round6b_overlap_info(self):
        rc, out = self.run_checker("overlap")
        self.assertEqual(rc, 0, out)
        self.assertIn("INFO  role overlap :: " + addr(101).lower() + " :: Safe owner[0], guardian[0]", out)
        self.assertIn("GOVERNANCE_OWNER", out)
        self.assertIn("DEPLOYER_GTOKEN_RECIPIENT", out)

    def test_complete_end_state(self):
        rc, out = self.run_checker()
        self.assertEqual(rc, 0, out)
        print(out.splitlines()[-1])

    def test_round6_accounting_mutations(self):
        for mutation in ("recipient_delta", "mint_sum", "ticket_treasury", "mint_event"):
            with self.subTest(mutation=mutation):
                self.assertEqual(self.run_checker(mutation)[0], 1)

    def test_round6_observed_nonce_numeric(self):
        self.assertEqual(self.run_checker("bad_observed_nonce")[0], 1)

    def test_round6_malformed_number(self):
        rc, out = self.run_checker("malformed_number")
        self.assertEqual(rc, 1)
        self.assertIn("FAIL missing/invalid config integer: expectedCap", out)

    def test_round6_absent_contracts_na(self):
        rc, out = self.run_checker()
        self.assertIn("PASS  AOA Paymaster absent", out)
        self.assertIn("PASS  config legacy pnts == zero", out)

    def test_cancelled_recovery_rejected(self):
        self.assertEqual(self.run_checker(safe_recovery=True)[0], 1)

    def test_numeric_serializations(self):
        for mutation in ("hex_numbers", "decimal_strings"):
            self.assertEqual(self.run_checker(mutation)[0], 0)

    def test_new_guards(self):
        for mutation in ("half_handover", "wrong_deployer", "wrong_safe", "delegated_safe", "threshold_one", "extra_operation", "missing_execution", "wrong_batch", "implementation_unlocked", "absent_h"):
            with self.subTest(mutation=mutation):
                rc, out = self.run_checker(mutation)
                self.assertEqual(rc, 1, out)

    def test_every_handover_slot_rejects_deployer_and_wrong_party(self):
        slots = [(k, "owner()(address)", [], f"owner({k}) == expected") for k in "superPaymaster registry staking gToken xPNTsFactoryV2 aoaProtocolRegistry reputationSystem blsAggregator dvtValidator xPNTsFactory paymasterFactory paymasterV4Impl microPaymentChannel x402Facilitator aPNTs".split()]
        slots += [("registry", "getRoleConfig(bytes32)", [digest(r)], f"roleConfigs[{r}].owner == timelock") for r in "COMMUNITY ENDUSER PAYMASTER_AOA PAYMASTER_SUPER DVT ANODE KMS".split()]
        for k, sig, name in (("superPaymaster", "treasury", "SP.treasury"), ("staking", "treasury", "staking.treasury"), ("sbt", "daoMultisig", "MySBT.daoMultisig"), ("blsAggregator", "slashPolicyAdmin", "aggregator.slashPolicyAdmin"), ("superPaymaster", "guardian", "SP.guardian"), ("policyRegistry", "guardian", "PolicyRegistry.guardian"), ("policyRegistry", "timelock", "PolicyRegistry.timelock"), ("aPNTs", "minter", "APNTsCapped.minter"), ("aPNTs", "capGuardian", "APNTsCapped.capGuardian"), ("superPaymaster", "APNTS_TOKEN", "SP.APNTS_TOKEN"), ("paymasterFactory", "registry", "pmFactory.registry")):
            slots.append((k, sig + "()(address)", [], name + " == expected"))
        for key, sig, params, check in slots:
            for bad in (addr(201), addr(999)):
                with self.subTest(slot=check, bad=bad):
                    rc, out = self.run_checker((key, sig, params, bad))
                    self.assertEqual(rc, 1, out)
                    self.assertIn("FAIL  " + check, out)

    def test_each_scalar_final_state_slot(self):
        slots = [("timelockController", "getMinDelay()(uint256)", [], "TL.minDelay == expected"),
                 ("aPNTs", "cap()(uint256)", [], "APNTsCapped.cap == expected"),
                 ("superPaymaster", "priceStalenessThreshold()(uint256)", [], "SP.priceStalenessThreshold == expected"),
                 ("blsAggregator", "minThreshold()(uint256)", [], "agg.minThreshold == expected"),
                 ("blsAggregator", "defaultThreshold()(uint256)", [], "agg.defaultThreshold == expected")]
        slots += [("blsAggregator", "slashThresholds(uint8)(uint8)", [str(i)], f"agg.slashThresholds[{i}] == input") for i in range(3)]
        for key, sig, params, label in slots:
            with self.subTest(label=label):
                rc, out = self.run_checker((key, sig, params, "1"))
                self.assertEqual(rc, 1)
                self.assertIn("FAIL  " + label, out)

    def test_pending_owners_each_fail(self):
        for key in ("registry", "superPaymaster", "aPNTs"):
            with self.subTest(key=key):
                rc, out = self.run_checker((key, "pendingOwner()(address)", [], addr(999)))
                self.assertEqual(rc, 1)
                self.assertIn(f"FAIL  pendingOwner({key}) == 0", out)

    def test_residue_each_fails(self):
        for key, sig, params, label in (("gToken", "balanceOf(address)(uint256)", [addr(201)], "GToken balance"), ("gToken", "allowance(address,address)(uint256)", [addr(201), addr(3)], "GToken allowance"), ("sbt", "balanceOf(address)(uint256)", [addr(201)], "SBT balance")):
            with self.subTest(label=label):
                rc, out = self.run_checker((key, sig, params, "1"))
                self.assertEqual(rc, 1)
                self.assertIn("FAIL  deployer " + label + " == recorded", out)

    def test_each_timelock_role_slot(self):
        for role in ("DEFAULT_ADMIN_ROLE", "PROPOSER_ROLE", "EXECUTOR_ROLE", "CANCELLER_ROLE"):
            rid = "0x" + "00" * 32 if role == "DEFAULT_ADMIN_ROLE" else digest(role)
            with self.subTest(role=role):
                rc, out = self.run_checker(("timelockController", "hasRole(bytes32,address)(bool)", [rid, addr(200)], "true" if role == "DEFAULT_ADMIN_ROLE" else "false"))
                self.assertEqual(rc, 1)
                self.assertIn(f"FAIL  TL.{role}(safe) == expected", out)
        rc, out = self.run_checker(("timelockController", "hasRole(bytes32,address)(bool)", ["0x" + "00" * 32, addr(18)], "false"))
        self.assertEqual(rc, 1)
        self.assertIn("FAIL  TL.DEFAULT_ADMIN_ROLE(timelock) == true", out)

    def test_each_guardian_and_genesis_state(self):
        for i in (1, 2):
            rc, out = self.run_checker(("blsAggregator", "validatorAtSlot(uint8)(address)", [str(i)], addr(999)))
            self.assertEqual(rc, 1)
            self.assertIn(f"FAIL  guardian[{i}] registered", out)
        rc, out = self.run_checker(("superPaymaster", "operators(address)", [addr(21)], "0x" + "0" * 64 + f"{1:064x}" + "0" * (64 * 7)))
        self.assertEqual(rc, 1)
        self.assertIn("FAIL  genesis isConfigured == false", out)

    def test_intermediate_states_fail(self):
        for mutation in ("delay", "pending", "PROPOSER_ROLE", "EXECUTOR_ROLE", "CANCELLER_ROLE", "DEFAULT_ADMIN_ROLE", "unexpected_admin", "rpc_error"):
            with self.subTest(mutation=mutation):
                rc, out = self.run_checker(mutation)
                self.assertEqual(rc, 1, out)

if __name__ == "__main__":
    unittest.main()

class DeployDayPrincipalTest(unittest.TestCase):
    run_checker = CheckerTest.run_checker
    def test_delegation_principal_kinds(self):
        for key in ('guardians', 'expectedGuardian', 'expectedSPGuardian', 'genesisOperator',
                    'deployerGTokenRecipient', 'SLASH_POLICY_ADMIN', 'X402_OWNER', 'REPUTATION_OWNER',
                    'MPC_OWNER', 'PAYMASTER_FACTORY_OWNER', 'safeOwner', 'stakeAccounts', 'ticketTreasuries', 'gTokenMintRecipients'):
            with self.subTest(principal=key):
                rc, out = self.run_checker(('delegation', key))
                self.assertEqual(rc, 1, out)
                self.assertRegex(out, r'FAIL  .*7702')

    def test_safe_code_control(self):
        rc, out = self.run_checker(real_proxy=True)
        self.assertEqual(rc, 0, out)
        self.assertIn('PASS  principals exclude EIP-7702', out)

    def test_readback_staking_runtime_tampered(self):
        code, output = self.run_checker('runtime_staking')
        self.assertEqual(code, 1, output)
        self.assertIn('FAIL  runtime staking', output)

    def test_readback_admin_runtime_tampered(self):
        code, output = self.run_checker('runtime_spAdminImpl')
        self.assertEqual(code, 1, output)
        self.assertIn('FAIL  runtime spAdminImpl', output)

    def test_readback_row_count(self):
        code, output = self.run_checker()
        self.assertEqual(code, 0, output)
        self.assertIn('SUMMARY 242 passed, 0 failed, 242 total', output)

    def test_readback_version_tampered(self):
        code, output = self.run_checker(('staking', 'version()(string)', [], '"wrong"'))
        self.assertEqual(code, 1, output)
        self.assertIn('FAIL  version staking', output)

    def test_readback_missing_version(self):
        code, output = self.run_checker(('versions', 'GTokenStaking'))
        self.assertEqual(code, 1, output)
        self.assertIn('FAIL  version staking', output)

    def test_readback_all_reads_pinned(self):
        code, output = self.run_checker(check_blocks=True)
        self.assertEqual(code, 0, output)
