"""Named STOP assertions for gate-deletion controls (test code only)."""
from contextlib import contextmanager
from types import SimpleNamespace
import sp_upgrade_exec as u


@contextmanager
def assert_stop(test, gate):
    caught = SimpleNamespace(exception=None)
    try:
        yield caught
    except u.a.Gate as fault:
        caught.exception = fault
        test.assertEqual(fault.record['gate'], gate, gate)
    except Exception as fault:
        test.fail(f'{gate}: expected STOP before {type(fault).__name__}: {fault}')
    else:
        test.fail(f'{gate}: Gate not raised')


def assertion_mentions(log, gate):
    """Inspect exception messages, including multiline unittest diffs, not traceback source."""
    in_message = False
    for line in log.splitlines():
        if line.startswith(('=====', '-----', 'FAIL:', 'ERROR:', 'Traceback (')):
            in_message = False
        if line.startswith('AssertionError:'):
            in_message = True
        if in_message and gate in line:
            return True
    return False
