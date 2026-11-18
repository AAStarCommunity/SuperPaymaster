#!/usr/bin/env python3
"""Fail-first evidence: suppress one named gate and require its negative test to go red."""
import io
import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch
import plan_three_arm as q
import test_three_arm as t
import test_artifacts as artifacts

OUT=q.ROOT/'cache/3arm/gate-reds'

def flatten(suite):
    for test in suite:
        if isinstance(test,unittest.TestSuite): yield from flatten(test)
        else: yield test

def main():
    OUT.mkdir(parents=True,exist_ok=True)
    original=q.a.need; coverage={}
    for module in (t,artifacts):
        for case in flatten(unittest.defaultTestLoader.loadTestsFromModule(module)):
            hits=[]
            def trace(gate,observed,expected):
                if observed!=expected: hits.append(gate)
                return original(gate,observed,expected)
            result=unittest.TestResult()
            with patch.object(q.a,'need',side_effect=trace): case.run(result)
            if not result.wasSuccessful():
                raise RuntimeError('control is not green: '+case.id()+str(result.errors+result.failures))
            if not hits: continue
            gate=hits[-1]
            if gate in coverage: continue
            def suppress(name,observed,expected):
                if name!=gate: return original(name,observed,expected)
            stream=io.StringIO()
            with patch.object(q.a,'need',side_effect=suppress):
                red=unittest.TextTestRunner(stream=stream,verbosity=2).run(type(case)(case._testMethodName))
            (OUT/(gate+'.log')).write_text('Suppressed gate: '+gate+'\n'+stream.getvalue())
            if red.wasSuccessful(): raise RuntimeError('surviving mutation: '+gate)
            coverage[gate]=case.id()
    (OUT/'index.json').write_text(json.dumps(coverage,indent=2,sort_keys=True)+'\n')
    print('Killed',len(coverage),'gate suppressions; named red outputs:',OUT.relative_to(q.ROOT))

if __name__=='__main__': main()
