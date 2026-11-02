#!/usr/bin/env python3
"""Offline DVT CI guard mutations; never edit production code or contact CI."""
import contextlib
import copy
import hashlib
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch
import test_manifest_exec as tests

m, a = tests.m, tests.a
SCHEMA = Path(__file__).with_name('release-evidence.schema.json')


def run_test(name):
    suite = unittest.defaultTestLoader.loadTestsFromName('DvtCiEvidenceTests.' + name, tests)
    result = unittest.TextTestRunner(stream=io.StringIO()).run(suite)
    return dict(tests=result.testsRun, failures=len(result.failures), errors=len(result.errors),
                status='PASS' if result.wasSuccessful() else 'FAIL')


def main():
    original = json.loads(SCHEMA.read_text())
    read_text, need = Path.read_text, a.need
    cases = [
        ('duplicate JSON key rejection', 'test_duplicate_job_names_stop', 'duplicates', []),
        ('renamed failed job collides with exempt name', 'test_renamed_failed_job_stop', 'duplicates', []),
        ('exempt conclusion enums', 'test_exempt_conclusions_stop', 'conclusions', []),
        ('single-line acceptance reference', 'test_reference_single_line_stop', 'reference', []),
        ('nonempty jobs', 'test_empty_job_map_stop', 'nonempty', []),
        ('job name pattern', 'test_job_name_single_line_stop', 'names', []),
        ('accepted failure name const', 'test_wrong_acceptance_schema_stop', 'acceptance_name', []),
        ('acceptance list bound', 'test_duplicate_acceptance_schema_stop', 'acceptance_count', []),
        ('unaccepted job rejection (schema and semantic gate)', 'test_unaccepted_job_stop', 'ordinary', ['evidence_ci_unaccepted']),
        ('overall success consistency (schema and semantic gate)', 'test_success_with_failure_stop', 'overall_success', ['evidence_ci_overall']),
        ('derived failure needs accepted direct failure (schema and semantic gate)', 'test_derived_failure_alone_stop', 'overall_failure', ['evidence_ci_overall']),
        ('failed audit needs acceptance (schema and semantic gates)', 'test_failure_without_acceptance_stop', 'acceptance_required', ['evidence_ci_unaccepted', 'evidence_ci_overall']),
        ('run head binding', 'test_head_mismatch_stop', None, ['evidence_ci_head']),
    ]
    records = []
    for label, test, mutation, gates in cases:
        baseline = run_test(test)
        schema = copy.deepcopy(original)
        branch = next(b for b in schema['oneOf'] if b['properties']['kind']['const'] == 'dvt-ci')
        run = branch['properties']['ciRun']
        jobs = run['properties']['jobs']
        accepted = branch['properties']['acceptedFailures']
        if mutation == 'conclusions':
            for child in jobs['properties'].values(): child.pop('enum')
        elif mutation == 'reference': accepted['items']['properties']['reference'].pop('pattern')
        elif mutation == 'nonempty': jobs.pop('minProperties')
        elif mutation == 'names': jobs.pop('propertyNames')
        elif mutation == 'acceptance_name': accepted['items']['properties']['name'].pop('const')
        elif mutation == 'acceptance_count': accepted.pop('maxItems')
        elif mutation == 'ordinary': jobs['additionalProperties']['enum'].append('failure')
        elif mutation == 'overall_success': run['allOf'].pop(0)
        elif mutation == 'overall_failure': run['allOf'].pop(1)
        elif mutation == 'acceptance_required': branch.pop('allOf')
        def mutated_read(path, *args, **kwargs):
            return json.dumps(schema) if path == SCHEMA.resolve() or path == SCHEMA else read_text(path, *args, **kwargs)
        def mutated_need(gate, *args, **kwargs):
            if gate not in gates: return need(gate, *args, **kwargs)
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(Path, 'read_text', mutated_read))
            stack.enter_context(patch.object(a, 'need', mutated_need))
            if mutation == 'duplicates':
                stack.enter_context(patch.object(a, 'reject_duplicate_pairs', dict))
            mutated = run_test(test)
        restored = run_test(test)
        records.append(dict(guard=label, test='test_manifest_exec.DvtCiEvidenceTests.' + test,
                            baseline=baseline, mutated=mutated, restored=restored,
                            killed=baseline['status'] == restored['status'] == 'PASS' and
                            mutated['failures'] > 0 and mutated['errors'] == 0))
    report = dict(schema=1, scope='Offline supplied DVT CI evidence validation; no CI service authentication',
                  method='In-memory schema or parser mutation; compound mutations remove redundant schema and executor guards together. Each test runs before removal, with removal, and after restoration.',
                  command='PYTHONPATH=script/upgrade:script/a3a python3 script/upgrade/check_dvt_ci_mutants.py',
                  sources={str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in
                           map(Path, ['script/upgrade/manifest_exec.py', 'script/upgrade/release-evidence.schema.json',
                                      'script/upgrade/test_manifest_exec.py', 'script/a3a/a3a_exec.py'])},
                  mutants=records, total=len(records), killed=sum(x['killed'] for x in records))
    SCHEMA.with_name('DVT-CI-MUTANTS.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f"Mutants killed: {report['killed']}/{report['total']}")
    for record in records:
        if not record['killed']: print(record)
    return 0 if report['killed'] == report['total'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
