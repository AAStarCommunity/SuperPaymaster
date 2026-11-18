#!/usr/bin/env python3
"""Offline removal-red probes: each safety gate must be needed by its regression test."""
import io
import unittest
from unittest.mock import patch
import plan_three_arm as q
import test_daybreak as tests

PROBES={
    'rq3_source_commit':'Daybreak.test_dirty_or_wrong_commit_refused',
    'rq3_checker_execution':'Daybreak.test_checker_is_executed_and_exact_count_required',
    'rq3_system_code':'DeploymentIdentity.test_versions_and_nonempty_code_for_every_system',
    'rq3_version_source':'SourceVersion.test_unparseable_version_refused',
    'rq3_system_version':'DeploymentIdentity.test_versions_and_nonempty_code_for_every_system',
    'rq3_calibration_hash':'Daybreak.test_calibration_file_binding',
    'rq3_calibration_identity':'Daybreak.test_calibration_file_binding',
    'rq3_calibration_block':'Daybreak.test_calibration_file_binding',
    'rq3_calibration_measurements':'Daybreak.test_calibration_file_binding',
    'rq3_positive_limits':'AdditionalGates.test_calibration_positive_all_groups',
    'rq3_gas_bounds':'Daybreak.test_zero_arm_limit',
    'rq3_safe_gas':'AdditionalGates.test_safe_zero',
    'rq3_output_credentials':'Daybreak.test_output_credentials_refused',
}

def main():
    folder=q.ROOT/'cache/3arm/fix';folder.mkdir(parents=True,exist_ok=True)
    need=q.a.need
    for gate,name in PROBES.items():
        def suppressed(key,*args,**kwargs):
            if key!=gate:return need(key,*args,**kwargs)
        stream=io.StringIO()
        suite=unittest.defaultTestLoader.loadTestsFromName(name,tests)
        with patch.object(q.a,'need',side_effect=suppressed):
            result=unittest.TextTestRunner(stream=stream,verbosity=2).run(suite)
        (folder/(gate+'-red.txt')).write_text(stream.getvalue())
        if result.wasSuccessful():raise AssertionError('gate suppression survived: '+gate)
        print(gate+': RED')

if __name__=='__main__':main()
