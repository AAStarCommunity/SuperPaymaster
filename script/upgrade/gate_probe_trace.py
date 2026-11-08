"""Record a primitive gate's real production caller chain in a focused baseline."""
import inspect
from pathlib import Path
from unittest.mock import patch
import probe_phase_c_gates as driver


def baseline_trace(cls, name):
    original = driver.a.need
    traces = {}
    def record(gate, *args, **kwargs):
        try:
            return original(gate, *args, **kwargs)
        except driver.a.Gate:
            frame = inspect.currentframe().f_back
            while frame:
                if Path(frame.f_code.co_filename).name in ('manifest_exec.py', 'old_owner_isolation.py'):
                    traces.setdefault(gate, set()).add((str(Path(frame.f_code.co_filename).resolve()), frame.f_lineno))
                frame = frame.f_back
            raise
    with patch.object(driver.a, 'need', side_effect=record):
        green, _, log = driver.run(cls, name)
    return green, log, traces
