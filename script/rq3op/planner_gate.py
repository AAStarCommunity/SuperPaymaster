#!/usr/bin/env python3
"""Run an UNMODIFIED planner checkout's plan_three_arm.main() and report its exact result.

Usage (from the planner checkout root, with the production read environment loaded):
  python3 -B <this> <planner-root> <config> <inputs> <output> --rpc-a-file F --rpc-b-file F

On success prints `PASS <output> sha256=<hex>`. On a planner Gate prints `STOP <gate>` and the
gate record (observed/expected) with URLs redacted, exit 3. The planner itself is not changed.
"""
import sys
sys.dont_write_bytecode = True
import hashlib
import json
import re
from pathlib import Path


def main():
    root = Path(sys.argv[1]).resolve()
    sys.path.insert(0, str(root/'script/rq3op'))
    import plan_three_arm as q
    sys.argv = ['plan_three_arm.py', *sys.argv[2:]]
    output = sys.argv[3]
    try:
        q.main()
    except Exception as error:
        record = getattr(error, 'record', None)
        name = record['gate'] if record else type(error).__name__
        text = json.dumps(record if record else str(error), default=str)
        text = re.sub(r'(?i)(?:https?|wss?)://\S+', '<redacted-url>', text)
        Path(output + '.gate.json').write_text(text + '\n')
        print(f'STOP {name}')
        print(f'RECORD {text[:4000]}')
        sys.exit(3)
    raw = Path(output).read_bytes()
    print(f'PASS {output} sha256={hashlib.sha256(raw).hexdigest()}')


if __name__ == '__main__':
    main()
