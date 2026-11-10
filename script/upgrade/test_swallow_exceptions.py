#!/usr/bin/env python3
"""Machine checks of broad exception handlers reachable from run_manifest."""
import ast
import unittest
from unittest.mock import patch
import swallow_audit as s
from gate_assertions import assert_stop


class SwallowTests(unittest.TestCase):
    def test_repository_closure(self):
        texts = s.sources()
        reached = s.assert_no_swallow(texts, s.reviewed_allowlist())
        for name in ('manifest_exec.pre_send', 'manifest_exec.dvt_closing',
                     'sp_upgrade_exec.measure_step', 'old_owner_isolation.registry_callsite_targets',
                     'a3a_exec.RPC.__call__', 'a3a_exec.RPC._post_with_deadline.work', 'rpc_strict.classify'):
            self.assertIn(name, reached)

    def test_unreviewed_handler(self):
        for clause in ('except Exception:', 'except BaseException:', 'except:'):
            texts = s.sources()
            tree = ast.parse(texts['manifest_exec'])
            function = next(n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == 'run_manifest')
            function.body.insert(0, ast.parse('try:\n    missing()\n'+clause+'\n    pass').body[0])
            texts['manifest_exec'] = ast.unparse(tree)
            with self.subTest(clause=clause), assert_stop(self, 'swallow_exception'):
                s.assert_no_swallow(texts, s.reviewed_allowlist())

    def test_cross_module_and_nested_closure(self):
        texts = {
            'manifest_exec': 'import helper as h\ndef run_manifest():\n    h.go()\n',
            'helper': 'def go():\n    def callback():\n        try:\n            missing()\n        except Exception:\n            pass\n    schedule(callback)\n',
        }
        with assert_stop(self, 'swallow_exception'):
            s.assert_no_swallow(texts, [])

    def test_partial_reraise_is_not_enough(self):
        for body in ('if flag:\n    raise', 'if flag:\n    return\nraise'):
            text = 'def run_manifest():\n    try:\n        missing()\n    except Exception:\n' + '\n'.join('        '+line for line in body.splitlines())
            with self.subTest(body=body), assert_stop(self, 'swallow_exception'):
                s.assert_no_swallow({'manifest_exec': text}, [])

    def test_changed_allowlisted_body(self):
        texts = s.sources()
        texts['a3a_exec'] = texts['a3a_exec'].replace("box['error'] = e", "box['error'] = None")
        with assert_stop(self, 'swallow_exception'):
            s.assert_no_swallow(texts, s.reviewed_allowlist())

    def test_allowlist_identity_ignores_line_numbers(self):
        texts = {name: '\n\n'+text for name, text in s.sources().items()}
        s.assert_no_swallow(texts, s.reviewed_allowlist())


class DeadlinePropagationTests(unittest.TestCase):
    def invoke(self, fault=None, elapsed=0, alive=False):
        # A response may be decoded before context-manager cleanup fails. This
        # supplies both body and error, just as the real worker can produce them.
        class Response:
            def __enter__(self):
                return self

            def read(self):
                return b'{"result": "decoded"}'

            def __exit__(self, *args):
                if fault is not None:
                    raise fault

        class Worker:
            def __init__(self, target, daemon):
                self.target = target

            def start(self):
                self.target()

            def join(self, timeout):
                pass

            def is_alive(self):
                return alive

        a = s.u.a
        with patch.object(a.urllib.request, 'urlopen', return_value=Response()), \
             patch.object(a.threading, 'Thread', Worker), \
             patch.object(a.time, 'monotonic', side_effect=[0, elapsed]):
            return a.RPC('http://offline.invalid')._post_with_deadline({})

    def test_worker_exception_identity(self):
        class WorkerFault(Exception):
            pass

        for fault in (KeyError('arbitrary'), WorkerFault('custom')):
            with self.subTest(kind=type(fault).__name__):
                with self.assertRaises(type(fault), msg='rpc_deadline_reraise') as caught:
                    self.invoke(fault=fault)
                self.assertIs(caught.exception, fault, 'rpc_deadline_reraise')

    def test_expired_deadline(self):
        for alive in (False, True):
            with self.subTest(alive=alive):
                with self.assertRaises(TimeoutError, msg='rpc_deadline_timeout'):
                    self.invoke(elapsed=s.u.a.RPC_TOTAL_DEADLINE_SECONDS + 1, alive=alive)

    def test_completed_response(self):
        self.assertEqual(self.invoke(), {'result': 'decoded'})


if __name__ == '__main__':
    unittest.main()
