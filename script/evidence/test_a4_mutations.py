#!/usr/bin/env python3
"""In-memory guard removal; records failures vs errors without editing production files."""
import contextlib
import io
import json
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch
import test_a4_credit_logscan as scan
import test_a4_state_check as state

HERE=Path(__file__).resolve().parent

def execute(module, source, changes, case, name):
    original=module.m
    mutant=types.ModuleType('a4_mutant'); mutant.__file__=str(HERE/name)
    for old,new in changes:
        if old not in source: raise RuntimeError('missing mutation anchor: '+old)
        source=source.replace(old,new,1)
    exec(compile(source,name,'exec'),mutant.__dict__)
    module.m=mutant
    try:
        result=unittest.TestResult()
        with patch('urllib.request.urlopen',side_effect=RuntimeError('offline only')):
            case.run(result)
        return {'killed':bool(result.failures) and not result.errors,'assertionFailures':len(result.failures),'errors':len(result.errors)}
    finally: module.m=original


def main():
    rows=[]
    source=scan.SCANNER.read_text()
    for name,(old,new) in scan.MUTATIONS.items():
        target=scan.SELECTOR_MUTANTS[name][1] if name in scan.SELECTOR_MUTANTS else name
        rows.append(dict(name='logscan.'+name,test='test_'+target,**execute(scan,source,[(old,new)],scan.Controls('test_'+target),'a4-credit-logscan.py')))
    for name,old,new,test in [
        ('split_consistency','if split != pair:', 'if False:', 'test_split_consistency'),
        ('sampling_bound','ranked[:k]', 'ranked', 'test_sampling_bound_and_seed'),
        ('provider_cap','len(r) in (1000, 5000, 10000) or len(r) > max_logs','False','test_cap_shrinks'),
        ('configured_max','or len(r) > max_logs','or False','test_configured_max_shrinks'),
        ('receipt_content','if receipt_logs != [expected, expected]:','if False:','test_receipt_equal_count_disagreement'),
        ('receipt_shared_substitution','if receipt_logs != [expected, expected]:','if False:','test_receipt_shared_substitution'),
        ('receipt_truncation','if receipt_logs != [expected, expected]:','if False:','test_identical_truncation_receipts')]:
        rows.append(dict(name='logscan.'+name,test=test,**execute(scan,source,[(old,new)],scan.Controls(test),'a4-credit-logscan.py')))
    source=(HERE/'a4_state_check.py').read_text()
    for c,test in [('C1','c1_wrong_implementation'),('C2','c2_policy_on'),('C3','c3_queued'),('C5','c5_reserved'),('C6','c6_zero_amount_record'),('C8','c8_debt'),('C9','c9_inflight')]:
        old="'pass' if fn() else 'fail'"; new=f"'pass' if c == '{c}' or fn() else 'fail'"
        rows.append(dict(name='state.'+c,test='test_'+test,**execute(state,source,[(old,new)],state.StateControls('test_'+test),'a4_state_check.py')))
    for c,test in [('C4','c4_ever_on'),('C7','c7_reopened')]:
        rows.append(dict(name='state.'+c,test='test_'+test,**execute(state,source,[("{'result': scan[c]['verdict']}",f"{{'result': 'pass' if c == '{c}' else scan[c]['verdict']}}")],state.StateControls('test_'+test),'a4_state_check.py')))
    for name,old,new,test in [
        ('read_agreement',"if pair[0] != pair[1]:\n                raise logs.RpcFailure('byte-for-byte disagreement')","if False:\n                raise logs.RpcFailure('byte-for-byte disagreement')",'read_bytes_must_agree'),
        ('unverified_blocks',"controls[c] = {'result': 'unverified', 'reason': reason}","controls[c] = {'result': 'pass', 'reason': reason}",'history_unavailable')]:
        rows.append(dict(name='state.'+name,test='test_'+test,**execute(state,source,[(old,new)],state.StateControls('test_'+test),'a4_state_check.py')))
    for name, old, new, test in [
        ('inventory_omission', "if 'knownOperations' in config and not discovered <= known:", 'if False:', 'inventory_omissions_stop'),
        ('credit_discovery', "discovered = {e['opHash'] for e in events if 'opHash' in e}", 'discovered = set()', 'inventory_omissions_stop'),
        ('lock_discovery', 'discovered |= lock_ops | sp_ops', 'discovered |= sp_ops', 'inventory_omissions_stop'),
        ('sp_discovery', 'discovered |= lock_ops | sp_ops', 'discovered |= lock_ops', 'inventory_omissions_stop'),
        ('discovery_complete', 'if not discovery_complete:', 'if False:', 'inventory_partial_scan_blocks'),
        ('ep_discovery', 'inflight_ops = sorted(known | discovered | ep_ops)', 'inflight_ops = sorted(known | discovered)', 'ep_discovered_nonzero'),
        ('ep_complete', "if not ep_evidence['complete']:", 'if False:', 'ep_incomplete'),
        ('ep_start_required', "if not ep_evidence['complete']:", 'if False:', 'ep_start_pin'),
        ('ep_start_hash', "if 'blockHash' in start and logs.hexstr(start['blockHash'], 32) != start_hash:", 'if False:', 'ep_start_pin'),
        ('ep_paymaster_filter', "indexed_topics={3: '0x'+word(sp)}", 'indexed_topics={}', 'ep_foreign_paymaster'),
        ('ep_selector', "topic = logs.hexstr(cast('keccak', USER_OPERATION_EVENT), 32)", "topic = cast('keccak', 'WrongEvent(bytes32)')", 'ep_discovered_nonzero')]:
        rows.append(dict(name='state.'+name, test='test_'+test,
                         **execute(state, source, [(old,new)], state.StateControls('test_'+test), 'a4_state_check.py')))
    for name, old, new, test in [
        ('sp_start_boundary', "not 1 <= start['block'] <= created", "not 1 <= start['block'] <= config['block']", 'late_sp_start'),
        ('creation_agreement', "if pair[0] != pair[1]:", "if False:", 'creation_archive_and_disagreement'),
        ('creation_predecessor', "start == 0 or code(start - 1) or not code(start)", "start == 0 or not code(start)", 'creation_boundary'),
        ('creation_record', "{'token': created_t, 'sp': created_sp}", "{'token': 0, 'sp': 0}", 'creation_evidence'),
        ('ep_binding', "if values != ['0x'+word(ep)] * 2:", 'if False:', 'ep_substitution'),
        ('ep_historical_binding', "{created, config['block']} | {v['blockNumber'] for v in upgrades['logs']}", "{config['block']}", 'ep_binding_history'),
        ('ep_upgrade_complete', "if not upgrades['complete'] or upgrades['blockHashes']['to']['A'] != end_hash:", 'if False:', 'upgrade_receipt_omission')]:
        rows.append(dict(name='state.'+name, test='test_'+test,
                         **execute(state, source, [(old,new)], state.StateControls('test_'+test), 'a4_state_check.py')))
    log_source = scan.SCANNER.read_text()
    normalization = 'topics=[hexstr(t, 32) for t in log.get("topics", [])]'
    rows.append(dict(name='logscan.receipt_hex_normalization', test='test_receipt_hex_case',
                     **execute(scan, log_source, [(normalization, 'topics=log.get("topics", [])')],
                               scan.Controls('test_receipt_hex_case'), 'a4-credit-logscan.py')))
    mutated_logs = log_source.replace(normalization, 'topics=log.get("topics", [])')
    rows.append(dict(name='state.ep_receipt_hex_normalization', test='test_ep_hex_case',
                     **execute(state, source, [('spec.loader.exec_module(logs)',
                               'exec('+repr(mutated_logs)+', logs.__dict__)')],
                               state.StateControls('test_ep_hex_case'), 'a4_state_check.py')))
    for name, old, new, test in [
        ('filtered_default', '50000 if indexed_topics else 2000', '2000', 'filtered_chunk_defaults'),
        ('filtered_ceiling', 'min(chunk_size, 50000)', 'chunk_size', 'filtered_chunk_defaults'),
        ('all_hit_receipts', 'sorted({v["blockNumber"] for v in pair[0]} | set(matching + empty))', 'sorted(matching + empty)', 'all_hit_receipts_and_coverage'),
        ('pacing', "session['last'].get(url, -float('inf')) + session['interval']", "session['last'].get(url, -float('inf'))", 'rpc_pacing_backoff_and_records'),
        ('backoff', '0.25 * 2 ** retry', '0.25', 'rpc_pacing_backoff_and_records'),
        ('retry_limit', "retries = session['retries'] if session else 5", 'retries = 0', 'rpc_exhaustion_stays_failure'),
        ('rpc_record', "session['calls'].append(record)", 'pass', 'rpc_pacing_backoff_and_records')]:
        rows.append(dict(name='logscan.'+name, test='test_'+test,
                         **execute(scan, log_source, [(old,new)], scan.Controls('test_'+test), 'a4-credit-logscan.py')))
    for name, old, new, test in [
        ('expected_hits', "if ep_evidence.get('positiveControl', {}).get('result') == 'fail':", 'if False:', 'expected_entrypoint_hits'),
        ('expected_head', "if v['blockNumber'] <= expected['head']", 'if True', 'expected_entrypoint_head'),
        ('new_hits', "if decode(v)['opHash'] not in hashes", 'if False', 'expected_entrypoint_hits'),
        ('inflight_selector', "if cast('sig', 'inflightOf(bytes32)')[2:].lower() not in runtime[2:]:", 'if False:', 'inflight_implementation_absent'),
        ('inflight_empty_probe', 'if not inflight_ops:', 'if False:', 'inflight_implementation_absent')]:
        rows.append(dict(name='state.'+name, test='test_'+test,
                         **execute(state, source, [(old,new)], state.StateControls('test_'+test), 'a4_state_check.py')))
    # Schema guard removals: test the public validator with real file hashing and refs.
    sys.path.insert(0,str(HERE.parent/'upgrade'))
    import test_manifest_exec as manifest
    original=manifest.m
    base=json.loads((HERE/'a4-conformance-record.template.json').read_text())
    base.update(subjectCommit='a'*40,result='PASS',counts=dict(passed=1,failed=0,skipped=0))
    for control in base['controls'].values(): control['result']='PASS'
    def rejected(value):
        try: original.validate_evidence_details(value,'conformance')
        except original.a.Gate: return True
        return False
    schema=json.loads((HERE.parent/'upgrade/release-evidence.schema.json').read_text())
    import copy
    for name,change,mutate in [
        ('scope',lambda e:e.update(scope='wrong'),lambda s:s['oneOf'][0]['properties'].update(scope={})),
        ('negative',lambda e:e['controls']['C1']['negativeControl'].clear(),lambda s:s['oneOf'][0]['properties']['controls']['properties']['C1']['properties']['negativeControl'].update(minItems=0))]:
        bad=copy.deepcopy(base); change(bad)
        baseline=rejected(bad)
        modified=copy.deepcopy(schema); mutate(modified)
        real=Path.read_text
        with patch.object(Path,'read_text',lambda p,*a,**kw:json.dumps(modified) if p.name=='release-evidence.schema.json' else real(p,*a,**kw)):
            survived=rejected(bad)
        rows.append(dict(name='manifest.'+name,killed=baseline and not survived,errors=0,assertionFailures=int(baseline and not survived)))
    bad=copy.deepcopy(base); bad['controls']['C1']['test']='test_absent'
    baseline=rejected(bad)
    real_need=original.a.need
    with patch.object(original.a,'need',lambda gate,*args:None if gate=='evidence_test_name' else real_need(gate,*args)):
        survived=rejected(bad)
    rows.append(dict(name='manifest.test_exists',killed=baseline and not survived,errors=0,assertionFailures=int(baseline and not survived)))
    report={'scope':'checker-logic-offline','mutations':rows,'killed':sum(r['killed'] for r in rows),'total':len(rows),
            'survivorsExplanation':'Three legacy single-guard mutants are now blocked by independent receipt checks: missing_chunk_log, log_hash, outside_filter. No runtime errors are counted as kills.'}
    (HERE/'a4-guard-mutations.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k!='mutations'},indent=2))
    expected_survivors={'logscan.missing_chunk_log','logscan.log_hash','logscan.outside_filter'}
    return int(any(r['errors'] for r in rows) or {r['name'] for r in rows if not r['killed']} != expected_survivors)
if __name__=='__main__': raise SystemExit(main())
